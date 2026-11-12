#!/usr/bin/env bash
# pick-fastest.sh — 下载通道选优：直连 + 各代理组同台实测，选最快且可用的那条
#
# 用法:
#   bash pick-fastest.sh <URL> [组名,组名,...]
#   bash pick-fastest.sh "<URL>" --restore        # 恢复上次记录的原节点
#
# 设计要点:
#   1. 一次请求同时拿「可用性判定」和「速度」，不做二次探测
#   2. 只对 Proxy 组的成员切组，切换后校验 HTTP 码 + 回读 now，失败即剔除
#   3. 采样用 1MB + 6 秒上限，慢链路自动省流量；前 2 名才精测
#   4. 只暂停命令行里含目标 URL 的下载进程，不误杀别人
#   5. 全程 trap，异常退出自动恢复原节点

set -uo pipefail

# ---------------- 默认参数 ----------------
API="${MIHOMO_API:-http://127.0.0.1:9092}"
PROXY="${MIHOMO_PROXY:-http://127.0.0.1:7890}"
GROUP="${GROUP:-}"                    # 可切换的入口组，空=自动探测
SAMPLE_MB="${SAMPLE_MB:-1}"           # 第一轮每组采样
PRECISE_MB="${PRECISE_MB:-8}"         # 精测采样
TIMEOUT="${TIMEOUT:-6}"               # 单次请求超时(秒)
EARLY_EXIT_RATIO="${EARLY_EXIT_RATIO:-3}"  # 领先倍数达到即早停
MAX_TRAFFIC_MB="${MAX_TRAFFIC_MB:-30}"
SKIP_DIRECT_ENV="${SKIP_DIRECT-__unset__}"
SKIP_DIRECT="${SKIP_DIRECT:-0}"
TARGET_DIR="${TARGET_DIR:-$PWD}"
START_DOWNLOAD="${START_DOWNLOAD:-1}"
ASSUME_NO_PROMPT="${ASSUME_NO_PROMPT:-0}"
DRY_RUN="${DRY_RUN:-0}"
CONCURRENCY="${CONCURRENCY:-16}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mihomo-fast-node"
STATE_FILE="$STATE_DIR/state.env"
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/mfn.XXXXXX")"

# ---------------- 运行时状态 ----------------
PHASE="init"
ORIG=""
BEST_GROUP=""
BEST_SPEED=0
BEST_STATUS=""
BEST_HTTP=""
TRAFFIC_BYTES=0
declare -a PAUSED_PIDS=()
declare -a RESULTS=()
declare -a CANDIDATES=()

# ---------------- 工具函数 ----------------
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn "❌ $*"; exit "${2:-1}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# 交互提问：仅当 stdin 是终端且未强制非交互
INTERACTIVE=0
[ -t 0 ] && [ "$ASSUME_NO_PROMPT" != "1" ] && INTERACTIVE=1

ask() { # ask "问题" "默认值" -> 打印答案
  local q="$1" def="$2" ans=""
  if [ "$INTERACTIVE" = "1" ] && [ -r /dev/tty ]; then
    printf '%s [%s]: ' "$q" "$def" > /dev/tty
    read -r ans < /dev/tty || ans=""
    printf '%s\n' "${ans:-$def}"
  else
    printf '%s\n' "$def"
  fi
}

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }

bytes_to_mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

# ---------------- 清理与恢复 ----------------
restore_orig() {
  [ -z "$ORIG" ] && return 0
  [ "$PHASE" = "downloading" ] && return 0   # 下载在跑，不能把节点切走
  curl -s -o /dev/null --max-time 3 -X PUT "$API/proxies/$GROUP" \
       -d "{\"name\":\"$(json_esc "$ORIG")\"}" 2>/dev/null
}

resume_paused() {
  local p
  for p in "${PAUSED_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -CONT "$p" 2>/dev/null
  done
}

cleanup() {
  local rc=$?
  restore_orig
  resume_paused
  rm -rf "$TMPDIR_RUN" 2>/dev/null
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------- 参数解析 ----------------
URL="${1:-}"
SHIFT_EXTRA="${2:-}"

if [ "$URL" = "--restore" ]; then
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ -n "${SAVED_ORIG:-}" ] || die "状态文件里没有记录原节点"
    G="${SAVED_GROUP:-Proxy}"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT \
      "$API/proxies/$G" -d "{\"name\":\"$(json_esc "$SAVED_ORIG")\"}")
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
      say "✅ 已恢复节点: $SAVED_ORIG (组: $G)"
      exit 0
    fi
    die "恢复失败，HTTP $code" 3
  fi
  die "没有找到状态文件 $STATE_FILE" 3
fi

[ -z "$URL" ] && die "用法: bash $0 <URL> [组名,组名,...] | --restore" 2
case "$URL" in http://*|https://*) ;; *) die "URL 必须以 http:// 或 https:// 开头: $URL" 2;; esac

GROUPS_ARG=""
if [ -n "$SHIFT_EXTRA" ] && [ "${SHIFT_EXTRA#--}" = "$SHIFT_EXTRA" ]; then
  GROUPS_ARG="$SHIFT_EXTRA"
fi

say "目标文件: $URL"
say "采样: ${SAMPLE_MB}MB / ${TIMEOUT}s | 精测: ${PRECISE_MB}MB | 流量上限: ${MAX_TRAFFIC_MB}MB"

# ---------------- 阶段 0：依赖与环境 ----------------
have curl    || die "缺少 curl"
have python3 || die "缺少 python3（用于解析 mihomo API 返回的 JSON）"
ARIA=0; have aria2c && ARIA=1

if ! curl -s --max-time 5 "$API/proxies" -o "$TMPDIR_RUN/proxies.json"; then
  die "连不上 mihomo 控制接口: $API （检查 external-controller 与 secret）"
fi

# TUN 检测：有 tun 网卡说明全局代理开着，直连测试无意义
TUN=0
if ip -br link 2>/dev/null | grep -qiE '^(tun|utun|wg)'; then TUN=1; fi
if [ "$TUN" = "1" ] && [ "$SKIP_DIRECT_ENV" = "__unset__" ]; then
  say "⚠️  检测到 TUN（虚拟网卡全局代理），直连测试无意义 → 自动跳过直连"
  say "   （想强制测直连：显式传 SKIP_DIRECT=0）"
  SKIP_DIRECT=1
fi

# 探测可切换的入口组
if [ -z "$GROUP" ]; then
  GROUP=$(python3 - "$TMPDIR_RUN/proxies.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))["proxies"]
pref=["Proxy","PROXY","proxy","节点选择","选择节点","手动切换","GLOBAL"]
cands=[k for k,v in d.items()
       if v.get("type")=="Selector" and k!="GLOBAL" and len(v.get("all") or [])>=2]
for p in pref:
    if p in cands: print(p); raise SystemExit
print(cands[0] if cands else "")
PY
)
fi
[ -z "$GROUP" ] && die "找不到可切换的 Selector 组，请用 GROUP=组名 指定"

if ! curl -s --max-time 5 "$API/proxies/$GROUP" -o "$TMPDIR_RUN/group.json"; then
  die "读不到组 $GROUP"
fi

ORIG=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("now",""))' "$TMPDIR_RUN/group.json")
say "入口组: $GROUP   当前节点: ${ORIG:-未知}"

# ---------------- 阶段 1：候选列表（只取该组的成员）----------------
if [ -n "$GROUPS_ARG" ]; then
  IFS=',' read -ra CANDIDATES <<< "$GROUPS_ARG"
else
  mapfile -t CANDIDATES < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get("all",[]): print(x)
' "$TMPDIR_RUN/group.json")
fi
[ "${#CANDIDATES[@]}" -eq 0 ] && die "组 $GROUP 没有可用成员"

say "候选: 直连 + ${#CANDIDATES[@]} 个成员  （均按「目标 URL」实测，结论仅对本次 URL 有效）"
say "----------------------------------------"

# ---------------- 阶段 2：暂停相关下载 ----------------
pause_related() {
  local pid cmd
  for bin in aria2c curl wget; do
    for pid in $(pgrep -x "$bin" 2>/dev/null); do
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
      case "$cmd" in
        *"$URL"*) kill -STOP "$pid" 2>/dev/null && PAUSED_PIDS+=("$pid") ;;
      esac
    done
  done
  [ "${#PAUSED_PIDS[@]}" -gt 0 ] && say "已暂停 ${#PAUSED_PIDS[@]} 个相关下载进程（结束后恢复）"
}
pause_related

# ---------------- 阶段 3：单次探测 ----------------
# 输出: 状态|速度Bps|http码|content_type|说明
probe_once() { # probe_once <direct|proxy> <group_name> <sample_mb> <timeout>
  local mode="$1" g="$2" mb="$3" tmo="$4"
  local bytes=$(( mb * 1024 * 1024 - 1 ))
  local body="$TMPDIR_RUN/body.bin"
  local hdr="$TMPDIR_RUN/hdr.txt"
  local out code ctype size ttime speed
  local -a extra=()
  rm -f "$body" "$hdr"

  # 关键：环境里的 no_proxy 会让 -x 被静默绕过，导致「代理测试」实际是直连测试。
  # 代理模式强制清空 no_proxy；直连模式强制绕过一切代理。
  if [ "$mode" = "proxy" ]; then
    extra=(-x "$PROXY" --noproxy "")
  else
    extra=(--noproxy "*")
  fi

  out=$(curl -sS -L "${extra[@]}" --max-time "$tmo" -r "0-$bytes" \
        -D "$hdr" -o "$body" \
        -w '%{http_code}|%{content_type}|%{size_download}|%{time_total}|%{speed_download}' \
        "$URL" 2>"$TMPDIR_RUN/curlerr.txt")
  local rc=$?

  if [ -z "$out" ]; then
    echo "NET_ERROR|0|000|-|curl 退出码 $rc"
    return
  fi
  code="${out%%|*}"; out="${out#*|}"
  ctype="${out%%|*}"; out="${out#*|}"
  size="${out%%|*}";  out="${out#*|}"
  ttime="${out%%|*}"; speed="${out#*|}"

  TRAFFIC_BYTES=$(( TRAFFIC_BYTES + ${size%%.*} ))

  case "$code" in
    000) echo "NET_ERROR|0|000|-|连接失败（退出码 $rc）"; return ;;
    401) echo "AUTH_401|0|401|$ctype|需要鉴权/token"; return ;;
    403) echo "BLOCKED_403|0|403|$ctype|出口 IP 被站点拒绝"; return ;;
    404) echo "NOT_FOUND|0|404|$ctype|URL 不存在"; return ;;
    429) echo "RATE_429|0|429|$ctype|该出口被限流"; return ;;
    5??) echo "SERVER_5XX|0|$code|$ctype|目标服务器错误"; return ;;
  esac

  case "$code" in
    200|206) ;;
    *) echo "HTTP_$code|0|$code|$ctype|非预期状态码"; return ;;
  esac

  # 200/206 之下再判「返回的是不是文件」
  # 顺序很重要：先判 HTML（网页永远不是你要的文件，且挑战页可能只有几百字节），
  # 再判「太小」；反过来会让 Cloudflare 挑战页被误标成 SUSPECT_TOO_SMALL。
  local sz=${size%%.*}
  case "$ctype" in
    *text/html*|*text/plain*)
      local head3
      head3=$(head -c 4096 "$body" 2>/dev/null | tr -d '\0')
      if printf '%s' "$head3" | grep -qiE 'just a moment|cf-chl|attention required|cf-error-details|checking your browser|verify you are human'; then
        echo "CHALLENGE|0|$code|$ctype|Cloudflare 人机验证页"; return
      fi
      echo "SUSPECT_HTML|0|$code|$ctype|返回网页而非文件"; return
      ;;
  esac
  if [ "$sz" -lt 512 ] 2>/dev/null; then
    echo "SUSPECT_TOO_SMALL|0|$code|$ctype|只返回 $sz 字节，可能是错误页"; return
  fi

  local sp=${speed%%.*}; [ -z "$sp" ] && sp=0
  echo "PASS|$sp|$code|$ctype|ok"
}

status_ok() { [ "$1" = "PASS" ]; }

fmt_speed() { awk -v b="$1" 'BEGIN{ if(b>=1048576) printf "%.1f MB/s", b/1048576; else printf "%.0f KB/s", b/1024 }'; }

traffic_exceeded() {
  awk -v b="$TRAFFIC_BYTES" -v m="$MAX_TRAFFIC_MB" 'BEGIN{exit !(b/1048576 > m)}'
}

# ---------------- 阶段 4：跑完所有候选 ----------------
IDX=0
TOTAL=$(( ${#CANDIDATES[@]} + 1 ))

run_one() { # run_one <label> <mode> <member|__DIRECT__>
  local label="$1" mode="$2" member="$3"
  IDX=$(( IDX + 1 ))
  printf '  [%d/%d] %-18s ' "$IDX" "$TOTAL" "$label"

  if [ "$mode" = "proxy" ]; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -X PUT \
           "$API/proxies/$GROUP" -d "{\"name\":\"$(json_esc "$member")\"}")
    if [ "$code" != "200" ] && [ "$code" != "204" ]; then
      printf '⏭ SWITCH_FAIL      切换被拒 HTTP %s（该名字不是 %s 的成员）\n' "$code" "$GROUP"
      RESULTS+=("0|$label|SWITCH_FAIL|$code|-|切换被 API 拒绝")
      return
    fi
    # 回读校验，防止「切了但没生效」
    local now
    now=$(curl -s --max-time 3 "$API/proxies/$GROUP" \
          | python3 -c 'import json,sys;print(json.load(sys.stdin).get("now",""))' 2>/dev/null)
    if [ "$now" != "$member" ]; then
      printf '⏭ SWITCH_NOEFFECT  切换后 now=%s（未生效）\n' "${now:-?}"
      RESULTS+=("0|$label|SWITCH_NOEFFECT|$code|-|切换后 now 不一致")
      return
    fi
  fi

  local res st sp hc ct note
  res=$(probe_once "$mode" "$member" "$SAMPLE_MB" "$TIMEOUT")
  st="${res%%|*}"; res="${res#*|}"
  sp="${res%%|*}"; res="${res#*|}"
  hc="${res%%|*}"; res="${res#*|}"
  ct="${res%%|*}"; note="${res#*|}"

  if [ "$st" = "PASS" ]; then
    printf '✅ %-12s %-26s %s\n' "$hc" "${ct:0:26}" "$(fmt_speed "$sp")"
  else
    printf '⛔ %-12s %-26s %s\n' "$hc" "$st" "$note"
  fi
  RESULTS+=("$sp|$label|$st|$hc|$ct|$note")
}

[ "$SKIP_DIRECT" != "1" ] && run_one "DIRECT" direct "__DIRECT__"

for m in "${CANDIDATES[@]}"; do
  traffic_exceeded && { say "  ⚠️  已达流量上限 ${MAX_TRAFFIC_MB}MB，停止后续测试"; break; }
  run_one "$m" proxy "$m"
done

# ---------------- 阶段 5：排名 ----------------
say "----------------------------------------"
OK_COUNT=$(printf '%s\n' "${RESULTS[@]}" | awk -F'|' '$3=="PASS"' | wc -l | tr -d ' ')

if [ "$OK_COUNT" -eq 0 ]; then
  say "❌ 没有任何可用通道。可能原因："
  say "   1) 目标站点封了本机所有出口 IP → 试镜像站或换出口"
  say "   2) 需要鉴权（401）→ 提供 token / cookie"
  say "   3) URL 本身失效（404）→ 先手工 curl 确认"
  say 'RESULT_JSON={"ok":false,"reason":"no_usable_channel","url":"'"$(json_esc "$URL")"'"}'
  exit 3
fi

say "排名（仅列出可用通道）:"
printf '%s\n' "${RESULTS[@]}" | awk -F'|' '$3=="PASS"' | sort -t'|' -k1 -rn \
  | awk -F'|' '{printf "  #%d  %-18s %8.1f MB/s  (HTTP %s)\n", NR, $2, $1/1048576, $4}'

TOP=$(printf '%s\n' "${RESULTS[@]}" | awk -F'|' '$3=="PASS"' | sort -t'|' -k1 -rn)
BEST_SPEED="${TOP%%|*}"; rest="${TOP#*|}"
BEST_GROUP="${rest%%|*}"; rest="${rest#*|}"
BEST_STATUS="${rest%%|*}"; rest="${rest#*|}"
BEST_HTTP="${rest%%|*}"

SECOND=$(printf '%s\n' "${TOP}" | sed -n '2p')
SECOND_SPEED="${SECOND%%|*}"; [ -z "$SECOND_SPEED" ] && SECOND_SPEED=0
SECOND_GROUP=$(printf '%s\n' "$SECOND" | cut -d'|' -f2)

say "----------------------------------------"
say "最快: $BEST_GROUP  ($(fmt_speed "$BEST_SPEED"))"

# ---------------- 阶段 6：早停 / 精测 ----------------
need_precise() {
  [ -z "$SECOND_GROUP" ] && return 1
  [ "$SECOND_SPEED" -le 0 ] 2>/dev/null && return 1
  awk -v a="$BEST_SPEED" -v b="$SECOND_SPEED" -v r="$EARLY_EXIT_RATIO" \
      'BEGIN{exit !(a < b*r)}'
}

if need_precise; then
  say "领先幅度不足 ${EARLY_EXIT_RATIO} 倍（第2名 $SECOND_GROUP），对前 2 名精测 ${PRECISE_MB}MB..."
  for m in "$BEST_GROUP" "$SECOND_GROUP"; do
    traffic_exceeded && { say "  ⚠️  流量上限，跳过精测"; break; }
    [ "$m" = "DIRECT" ] && mode=direct || mode=proxy
    res=$(probe_once "$mode" "$m" "$PRECISE_MB" $(( TIMEOUT * 2 )))
    st="${res%%|*}"; res="${res#*|}"; sp="${res%%|*}"
    if [ "$st" = "PASS" ]; then
      printf '  %-18s %s\n' "$m" "$(fmt_speed "$sp")"
      RESULTS+=("$sp|$m|PASS_PRECISE|$BEST_HTTP|-|precise")
    else
      printf '  %-18s ⛔ %s（保留首轮成绩）\n' "$m" "$st"
    fi
  done
  TOP=$(printf '%s\n' "${RESULTS[@]}" | grep -E '\|PASS(_PRECISE)?\|' | sort -t'|' -k1 -rn)
  BEST_SPEED="${TOP%%|*}"; rest="${TOP#*|}"
  BEST_GROUP="${rest%%|*}"; rest="${rest#*|}"
  BEST_STATUS="${rest%%|*}"; rest="${rest#*|}"
  BEST_HTTP="${rest%%|*}"
  say "精测后最快: $BEST_GROUP  ($(fmt_speed "$BEST_SPEED"))"
else
  say "早停：领先第 2 名超过 ${EARLY_EXIT_RATIO} 倍，跳过精测"
fi

# ---------------- 阶段 7：切换 + 起下载 ----------------
FILENAME=$(basename "${URL%%\?*}")
[ -z "$FILENAME" ] || [ "$FILENAME" = "/" ] && FILENAME="download.bin"

MODE="proxy"; [ "$BEST_GROUP" = "DIRECT" ] && MODE="direct"

if [ "$MODE" = "proxy" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT \
    "$API/proxies/$GROUP" -d "{\"name\":\"$(json_esc "$BEST_GROUP")\"}")
  say "已切换 $GROUP → $BEST_GROUP（HTTP $code）"
fi

mkdir -p "$STATE_DIR" 2>/dev/null
{
  printf 'SAVED_ORIG=%q\n' "$ORIG"
  printf 'SAVED_GROUP=%q\n' "$GROUP"
  printf 'SAVED_URL=%q\n' "$URL"
} > "$STATE_FILE" 2>/dev/null

STARTED_PID=""
LOG="$TARGET_DIR/.download-$FILENAME.log"

build_cmd() {
  local -a cmd=(aria2c -c -x "$CONCURRENCY" -s "$CONCURRENCY" -k 8M
    --file-allocation=none --max-tries=0 --retry-wait=3 --summary-interval=30
    -d "$TARGET_DIR" -o "$FILENAME")
  [ "$MODE" = "proxy" ] && cmd+=(--all-proxy="$PROXY")
  cmd+=("$URL")
  printf '%s' "${cmd[*]}"
}

CMD_LINE=""
if [ "$ARIA" = "1" ]; then
  CMD_LINE=$(build_cmd)
else
  CMD_LINE="curl -L -C - -o '$TARGET_DIR/$FILENAME' $([ "$MODE" = "proxy" ] && echo "-x $PROXY") '$URL'"
fi

say "----------------------------------------"
say "下载命令（通道: $MODE）:"
say "  $CMD_LINE"

if [ "$START_DOWNLOAD" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$TARGET_DIR" 2>/dev/null || die "目标目录不可写: $TARGET_DIR" 4
  PHASE="downloading"
  if [ "$ARIA" = "1" ]; then
    nohup bash -c "$CMD_LINE" >"$LOG" 2>&1 &
    STARTED_PID=$!
  else
    nohup bash -c "$CMD_LINE" >"$LOG" 2>&1 &
    STARTED_PID=$!
  fi
  sleep 1
  if kill -0 "$STARTED_PID" 2>/dev/null; then
    say "✅ 下载已启动  PID=$STARTED_PID"
    say "   日志: $LOG"
    say "   恢复原节点: bash $0 --restore"
  else
    PHASE="testing"
    say "⚠️  下载进程启动即退出，检查日志: $LOG"
  fi
else
  say "（DRY_RUN=1 或 START_DOWNLOAD=0，未启动下载）"
fi

# ---------------- 阶段 8：机器可读结果 ----------------
say '----------------------------------------'
printf 'RESULT_JSON={"ok":true,"url":"%s","best":"%s","mode":"%s","speed_bps":%s,"speed":"%s","status":"%s","http_code":"%s","tested":%s,"usable":%s,"traffic_mb":%s,"sample_mb":%s,"group":"%s","started_pid":"%s","log":"%s"}\n' \
  "$(json_esc "$URL")" "$(json_esc "$BEST_GROUP")" "$MODE" "$BEST_SPEED" "$(fmt_speed "$BEST_SPEED")" \
  "$BEST_STATUS" "$BEST_HTTP" "$IDX" "$OK_COUNT" "$(bytes_to_mb "$TRAFFIC_BYTES")" "$SAMPLE_MB" \
  "$(json_esc "$GROUP")" "$STARTED_PID" "$(json_esc "$LOG")"

exit 0
