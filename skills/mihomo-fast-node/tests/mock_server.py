#!/usr/bin/env python3
"""mock_server.py — 给 pick-fastest.sh 做「分情况」测试用的双服务模拟器。

一个进程里同时起：
  1) mock mihomo 控制接口（默认 :19092）—— 复刻 GET /proxies、GET/PUT /proxies/Proxy
     成功切换返回 **204**（与真实 mihomo 一致），非成员返回 **400** + 相同错误体
  2) mock 目标站点（默认 :18080）—— 同时充当 HTTP 代理：
     - 请求行是相对路径（/case）        => 视为「直连」
     - 请求行是绝对 URI（http://host/case）=> 视为「经代理」，用当前切到的组决定场景

两个服务共享内存里的 STATE，所以脚本一 PUT 切组，站点立刻按新组的场景响应。

用法: python3 mock_server.py --suite <name> [--api-port 19092] [--site-port 18080]
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

MB = 1024 * 1024
CHUNK = 64 * 1024

# ---------------- 测试套件 ----------------
# 每个组映射到一种响应形态；speed 用 sleep 近似（1MB 采样的目标速率）
SUITES = {
    # 全部可用，G1 明显最快 -> 应触发早停
    "all_pass": {
        "DIRECT": ("pass", 0.60, 1024),   # ~1.7 MB/s
        "G1":     ("pass", 0.05, 1024),   # ~20 MB/s
        "G2":     ("pass", 0.80, 1024),   # ~1.25 MB/s
        "G3":     ("pass", 1.20, 1024),   # ~0.8 MB/s
        "G4":     ("pass", 2.00, 1024),   # ~0.5 MB/s
    },
    # 混合故障：只有 G4 和直连可用
    "mixed": {
        "DIRECT": ("pass", 0.40, 1024),
        "G1":     ("forbidden", 0, 0),
        "G2":     ("challenge", 0, 0),
        "G3":     ("ratelimit", 0, 0),
        "G4":     ("pass", 0.30, 1024),
    },
    # 全灭：覆盖 403 / 401 / 挑战页 / 网页
    "all_blocked": {
        "DIRECT": ("forbidden", 0, 0),
        "G1":     ("forbidden", 0, 0),
        "G2":     ("challenge", 0, 0),
        "G3":     ("auth", 0, 0),
        "G4":     ("html", 0, 0),
    },
    # 直连被封、代理可用（验证「直连也是候选」的反面）
    "direct_blocked": {
        "DIRECT": ("forbidden", 0, 0),
        "G1":     ("pass", 0.50, 1024),
        "G2":     ("pass", 0.90, 1024),
        "G3":     ("pass", 0.20, 1024),
        "G4":     ("pass", 1.50, 1024),
    },
    # 直连可用、代理全封（验证直连应该夺冠）
    "direct_best": {
        "DIRECT": ("pass", 0.05, 1024),
        "G1":     ("forbidden", 0, 0),
        "G2":     ("forbidden", 0, 0),
        "G3":     ("ratelimit", 0, 0),
        "G4":     ("challenge", 0, 0),
    },
    # 只有 G3 和 G4 接近（验证「差距不足 -> 进入精测」分支）
    "close_race": {
        "DIRECT": ("pass", 2.50, 1024),
        "G1":     ("pass", 3.00, 1024),
        "G2":     ("forbidden", 0, 0),
        "G3":     ("pass", 0.50, 1024),
        "G4":     ("pass", 0.45, 1024),
    },
}

STATE = {
    "now": "G1",
    "members": ["G1", "G2", "G3", "G4"],
    "outsiders": ["下载专线", "OpenAI-选择"],  # 存在但不是成员，用来验证剔除逻辑
    "suite": "all_pass",
    "lock": threading.Lock(),
}

CHALLENGE_HTML = (
    "<!DOCTYPE html><html><head><title>Just a moment...</title></head>"
    "<body><h2>Checking your browser before accessing</h2>"
    '<div id="cf-chl-widget"></div></body></html>'
).encode()
PLAIN_HTML = b"<html><head><title>Access denied</title></head><body>blocked</body></html>"


class MihomoHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/proxies":
            d = {}
            with STATE["lock"]:
                d["Proxy"] = {
                    "type": "Selector",
                    "now": STATE["now"],
                    "all": list(STATE["members"]),
                }
                for m in STATE["members"]:
                    d[m] = {"type": "Fallback", "now": f"node-{m}", "all": [f"node-{m}"]}
                for o in STATE["outsiders"]:
                    d[o] = {"type": "URLTest", "now": f"node-{o}", "all": [f"node-{o}"]}
            d["GLOBAL"] = {"type": "Selector", "now": "Proxy", "all": ["Proxy"]}
            self._send_json({"proxies": d})
        elif path == "/proxies/Proxy":
            with STATE["lock"]:
                self._send_json(
                    {"type": "Selector", "now": STATE["now"], "all": list(STATE["members"])}
                )
        elif path.startswith("/proxies/"):
            name = path[len("/proxies/"):]
            self._send_json({"type": "Fallback", "now": f"node-{name}", "all": []})
        else:
            self._send_json({"message": "not found"}, 404)

    def do_PUT(self):
        path = self.path.split("?")[0]
        if path != "/proxies/Proxy":
            self._send_json({"message": "not found"}, 404)
            return
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            name = json.loads(raw).get("name", "")
        except Exception:
            self._send_json({"message": "bad body"}, 400)
            return
        with STATE["lock"]:
            if name in STATE["members"]:
                STATE["now"] = name
                self.send_response(204)   # 与真实 mihomo 一致
                self.end_headers()
            else:
                self._send_json({"message": "Selector update error: proxy not exist"}, 400)


class SiteHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _header_bytes(self, handler):
        return 0

    def do_GET(self):
        raw = self.path
        is_proxy = raw.startswith("http://") or raw.startswith("https://")
        if is_proxy:
            path = urlparse(raw).path
            with STATE["lock"]:
                who = STATE["now"]
        else:
            path = raw.split("?")[0]
            who = "DIRECT"

        suite = SUITES[STATE["suite"]]
        kind, delay, _kb = suite.get(who, ("pass", 0.5, 1024))

        rng = self.headers.get("Range") or ""
        limit = 1024 * 1024
        if rng.startswith("bytes=0-"):
            try:
                limit = int(rng.split("-")[1]) + 1
            except ValueError:
                pass
        limit = max(1, min(limit, 32 * MB))

        if kind == "forbidden":
            self._plain(403, "text/html", PLAIN_HTML)
        elif kind == "auth":
            self._plain(401, "text/html", PLAIN_HTML)
        elif kind == "ratelimit":
            self._plain(429, "text/html", PLAIN_HTML)
        elif kind == "notfound":
            self._plain(404, "text/html", PLAIN_HTML)
        elif kind == "challenge":
            time.sleep(0.02)
            self._plain(200, "text/html", CHALLENGE_HTML)
        elif kind == "html":
            time.sleep(0.02)
            self._plain(200, "text/html", PLAIN_HTML)
        elif kind == "tiny":
            self._plain(200, "application/octet-stream", b"x" * 100)
        else:  # pass
            self._stream_bytes(206 if rng else 200, limit, delay)

    # ---- 辅助 ----
    def _plain(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _stream_bytes(self, code, total, delay):
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(total))
        if code == 206 or total:
            self.send_header("Content-Range", f"bytes 0-{total - 1}/{total}")
        self.end_headers()
        block = b"\x00" * CHUNK
        sent = 0
        # 用「整体延迟 + 分块写出」近似目标速率，避免 sleep 太碎
        if delay > 0:
            time.sleep(delay)
        while sent < total:
            n = min(CHUNK, total - sent)
            try:
                self.wfile.write(block[:n])
            except (BrokenPipeError, ConnectionResetError):
                return
            sent += n


def serve(handler, port, ready):
    srv = ThreadingHTTPServer(("127.0.0.1", port), handler)
    srv.daemon_threads = True
    ready.append(srv)
    srv.serve_forever()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", default="all_pass", choices=sorted(SUITES))
    ap.add_argument("--api-port", type=int, default=19092)
    ap.add_argument("--site-port", type=int, default=18080)
    args = ap.parse_args()

    STATE["suite"] = args.suite
    ready = []
    threading.Thread(target=serve, args=(MihomoHandler, args.api_port, ready), daemon=True).start()
    threading.Thread(target=serve, args=(SiteHandler, args.site_port, ready), daemon=True).start()
    time.sleep(0.4)
    print(f"mock ready suite={args.suite} api={args.api_port} site={args.site_port}", flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
