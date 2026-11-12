#!/usr/bin/env bash
# run-tests.sh — 对 pick-fastest.sh 做「分情况」验证
# 全部走 mock：不碰真实 mihomo、不产生真实下载、不消耗真实流量
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/pick-fastest.sh"
MOCK="$ROOT/tests/mock_server.py"
API_PORT=19092
SITE_PORT=18080
URL="http://127.0.0.1:${SITE_PORT}/sample.bin"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mfn-test.XXXXXX")"
DL_DIR="$OUT_DIR/dl"
mkdir -p "$DL_DIR"

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
PASS_N=0; FAIL_N=0
declare -a FAILED_CASES=()

ok()   { PASS_N=$((PASS_N+1)); printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { FAIL_N=$((FAIL_N+1)); FAILED_CASES+=("$1 :: $2"); printf '    %s✗%s %s %s(%s)%s\n' "$RED" "$RESET" "$1" "$DIM" "$2" "$RESET"; }

mock_pid=""
start_mock() {
  python3 "$MOCK" --suite "$1" --api-port "$API_PORT" --site-port "$SITE_PORT" \
    >"$OUT_DIR/mock.log" 2>&1 &
  mock_pid=$!
  local i
  for i in $(seq 1 60); do
    if python3 - "$API_PORT" <<'PY' 2>/dev/null
import socket,sys
s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except Exception:
    sys.exit(1)
PY
    then return 0; fi
    sleep 0.1
  done
  echo "mock 启动失败"; cat "$OUT_DIR/mock.log"; return 1
}
stop_mock() { [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null; mock_pid=""; }

run_script() { # run_script <outfile> [额外参数...]
  local out="$1"; shift
  env -u SKIP_DIRECT \
    MIHOMO_API="http://127.0.0.1:$API_PORT" \
    MIHOMO_PROXY="http://127.0.0.1:$SITE_PORT" \
    XDG_STATE_HOME="$OUT_DIR/state" \
    TARGET_DIR="$DL_DIR" \
    DRY_RUN=1 START_DOWNLOAD=0 ASSUME_NO_PROMPT=1 TIMEOUT=6 SAMPLE_MB=1 \
    MAX_TRAFFIC_MB=30 \
    bash "$SCRIPT" "$@" >"$out" 2>&1
  echo $?
}

has() { grep -qF -- "$2" "$1"; }

# ============================================================
case_all_pass() {
  echo "▶ 用例 1/7：全部可用，G1 明显最快（验证早停）"
  start_mock all_pass || return
  local out="$OUT_DIR/c1.txt" rc
  rc=$(run_script "$out" "$URL")
  [ "$rc" = "0" ] && ok "退出码 0" || bad "退出码应为 0" "实际 $rc"
  has "$out" '早停' && ok "触发早停（领先 ≥3 倍）" || bad "应触发早停" "未见「早停」"
  has "$out" 'RESULT_JSON={"ok":true' && ok "输出 RESULT_JSON ok:true" || bad "缺 RESULT_JSON" ""
  has "$out" '"best":"G1"' && ok "冠军 = G1" || bad "冠军应为 G1" "$(grep -o '"best":"[^"]*"' "$out" | head -1)"
  [ "$(grep -c '✅' "$out")" -ge 5 ] && ok "5 个候选全部 PASS" || bad "应有 5 个 ✅" "实际 $(grep -c '✅' "$out")"
  stop_mock
}

case_mixed() {
  echo "▶ 用例 2/7：混合故障（403 / 挑战页 / 429），只有 G4 与直连可用"
  start_mock mixed || return
  local out="$OUT_DIR/c2.txt" rc
  rc=$(run_script "$out" "$URL")
  [ "$rc" = "0" ] && ok "退出码 0" || bad "退出码应为 0" "实际 $rc"
  has "$out" 'BLOCKED_403' && ok "识别 403 → BLOCKED_403" || bad "未识别 403" ""
  has "$out" 'CHALLENGE'   && ok "识别挑战页 → CHALLENGE"   || bad "未识别挑战页" ""
  has "$out" 'RATE_429'    && ok "识别 429 → RATE_429"      || bad "未识别 429" ""
  has "$out" '"tested":5'  && ok "5 个候选都测了"           || bad "候选数不对" "$(grep -o '"tested":[0-9]*' "$out")"
  has "$out" '"usable":2'  && ok "可用数 = 2（直连+G4）"    || bad "可用数应为 2" "$(grep -o '"usable":[0-9]*' "$out")"
  local best; best=$(grep -o '"best":"[^"]*"' "$out" | head -1)
  case "$best" in *G4*|*DIRECT*) ok "冠军来自可用集合（$best）";; *) bad "冠军不应是故障组" "$best";; esac
  stop_mock
}

case_all_blocked() {
  echo "▶ 用例 3/7：全灭（403/挑战/401/网页），应拒绝下载并退出码 3"
  start_mock all_blocked || return
  local out="$OUT_DIR/c3.txt" rc
  rc=$(run_script "$out" "$URL")
  [ "$rc" = "3" ] && ok "退出码 3（无可用通道）" || bad "退出码应为 3" "实际 $rc"
  has "$out" '"ok":false' && ok "RESULT_JSON ok:false" || bad "应为 ok:false" ""
  has "$out" 'AUTH_401'   && ok "识别 401 → AUTH_401"  || bad "未识别 401" ""
  has "$out" '没有任何可用通道' && ok "打印了排查建议"   || bad "缺排查建议" ""
  stop_mock
}

case_direct_blocked() {
  echo "▶ 用例 4/7：直连被 403，代理可用 → 应选代理"
  start_mock direct_blocked || return
  local out="$OUT_DIR/c4.txt"
  run_script "$out" "$URL" >/dev/null
  has "$out" 'DIRECT' && ok "直连参与了测试" || bad "直连未测试" ""
  local direct_line; direct_line=$(grep '\[1/5\] DIRECT' "$out")
  case "$direct_line" in *BLOCKED_403*) ok "直连被判 403";; *) bad "直连应为 BLOCKED_403" "$direct_line";; esac
  local best; best=$(grep -o '"best":"[^"]*"' "$out" | head -1)
  case "$best" in *G3*) ok "冠军 = G3（delay 最小）";; *) bad "冠军应为 G3" "$best";; esac
  stop_mock
}

case_direct_best() {
  echo "▶ 用例 5/7：代理全封、直连可用 → 应选直连（核心立场验证）"
  start_mock direct_best || return
  local out="$OUT_DIR/c5.txt"
  run_script "$out" "$URL" >/dev/null
  has "$out" '"best":"DIRECT"' && ok "冠军 = DIRECT" || bad "冠军应为 DIRECT" "$(grep -o '"best":"[^"]*"' "$out" | head -1)"
  has "$out" '"mode":"direct"' && ok "下载模式 = direct（不带 --all-proxy）" || bad "模式应为 direct" ""
  stop_mock
}

case_close_race() {
  echo "▶ 用例 6/7：前两名接近（< 3 倍）→ 应进入精测而非早停"
  start_mock close_race || return
  local out="$OUT_DIR/c6.txt"
  run_script "$out" "$URL" >/dev/null
  has "$out" '精测' && ok "触发精测（领先不足 3 倍）" || bad "应进入精测" ""
  has "$out" '早停' && bad "不应早停" "却出现早停" || ok "未误触发早停"
  stop_mock
}

case_non_member() {
  echo "▶ 用例 7/7：手动指定非成员组 → 应被 API 拒绝并剔除（最初那个 bug 的回归测试）"
  start_mock all_pass || return
  local out="$OUT_DIR/c7.txt"
  run_script "$out" "$URL" "下载专线" >/dev/null
  has "$out" '切换被拒' && ok "识别切换被拒" || bad "未识别切换失败" ""
  has "$out" 'HTTP 400' && ok "记录 HTTP 400" || bad "应记录 400" ""
  has "$out" 'SWITCH_FAIL' && ok "标记 SWITCH_FAIL 并排除出排名" || bad "缺 SWITCH_FAIL" ""
  grep -q '"best":"下载专线"' "$out" && bad "不应把失败组当冠军" "" || ok "失败组未进冠军位"
  stop_mock
}

case_restore() {
  echo "▶ 补测：--restore 子命令"
  start_mock all_pass || return
  local out="$OUT_DIR/c8.txt"
  # 先跑一次留下 state
  run_script "$out" "$URL" >/dev/null
  # 切走
  curl -s -o /dev/null -X PUT "http://127.0.0.1:$API_PORT/proxies/Proxy" -d '{"name":"G3"}'
  local before; before=$(curl -s "http://127.0.0.1:$API_PORT/proxies/Proxy" | python3 -c 'import json,sys;print(json.load(sys.stdin)["now"])')
  [ "$before" = "G3" ] && ok "已人工切到 G3（制造偏差）" || bad "准备状态失败" "now=$before"
  MIHOMO_API="http://127.0.0.1:$API_PORT" XDG_STATE_HOME="$OUT_DIR/state" \
    bash "$SCRIPT" --restore >"$OUT_DIR/c8r.txt" 2>&1
  local after; after=$(curl -s "http://127.0.0.1:$API_PORT/proxies/Proxy" | python3 -c 'import json,sys;print(json.load(sys.stdin)["now"])')
  [ "$after" = "G1" ] && ok "--restore 把节点还原成 G1" || bad "--restore 未还原" "now=$after"
  stop_mock
}

echo "=============================================="
echo " pick-fastest.sh 分情况验证（全 mock，不碰真实网络）"
echo "=============================================="
case_all_pass
case_mixed
case_all_blocked
case_direct_blocked
case_direct_best
case_close_race
case_non_member
case_restore

echo "=============================================="
printf ' 结果：%s 通过 %d%s，%s失败 %d%s\n' "$GREEN" "$PASS_N" "$RESET" "$RED" "$FAIL_N" "$RESET"
if [ "$FAIL_N" -gt 0 ]; then
  printf ' 失败项：\n'
  for f in "${FAILED_CASES[@]}"; do printf '   - %s\n' "$f"; done
fi
echo " 产物目录：$OUT_DIR"
echo "=============================================="
[ "$FAIL_N" -eq 0 ]
