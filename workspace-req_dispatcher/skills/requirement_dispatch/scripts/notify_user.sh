#!/usr/bin/env bash
# notify_user.sh — best-effort 把执行结果/失败结论推回企微发起人（origin）。
#
# 由 orchestrator 在 executor 回调路径终态（result：done/failed/timeout 推结论）或
# git_issuer 返回失败 / 路由查不到 / executor 调用耗尽等失败路径（failure）调用，
# 在 drain/ledger 写入之后执行。这是 req_dispatcher 首次主动给用户推「实质结论」
# （受理 ack 之外）——见设计稿 §4.3/§4.5。
#
# 与薄派发器红线不冲突：本脚本只经反向网关把结果信封推给 114 接收 agent，
# 由接收 agent 负责企微最后一跳；**不碰 GitLab、不建 issue、不打标签、不解析需求**。
#
# best-effort 语义（仿 ops_notify.sh / acpx post_result_note.sh）：推送是终态锦上添花，
# 绝不能让回调路径因「推用户」再失败、也绝不静默丢结论（结论由 pending/ledger 兜底）：
#   - REPLY_GATEWAY_URL / REPLY_GATEWAY_TOKEN / 目标 agent 任一为空 → 不推，
#     但**记一条 ledger 留痕**（user_notify_skipped），exit 0（config：留空则不推用户；
#     留痕保证「漏推」可审计、不静默丢）。
#   - 三项均配置 → 拼结构化信封 + 人读文案，用 `openclaw agent run` 投给 114 接收 agent；
#     openclaw 缺失 / 非零退出 / 超时均只记 user_notify_failed，exit 0。
#   - 缺 EVENT（必填未给）→ exit 1（调用方 bug，与兄弟脚本 :? 惯例一致）。
#   - 仅「部署配置形态错误」（EVENT 非法 / 超时配置非正整数）→ exit 2，让运维知道配错了
#     （这不属 best-effort 范畴，是调用点/部署期写错）。
#
# 入参（env）：
#   EVENT               必填：result | failure
#   REPLY_GATEWAY_URL  114 OpenClaw 网关 ws:// URL；空＝回落到旧 ZHIBAN_GATEWAY_URL，
#                      仍空则不推、仅 ledger 留痕。
#   REPLY_GATEWAY_TOKEN 114 OpenClaw 网关 token；空＝回落到旧 ZHIBAN_GATEWAY_TOKEN，
#                       仍空则不推、仅 ledger 留痕。
#   DEFAULT_REPLY_AGENT 默认接收结果的 114 agent 名；ORIGIN_JSON.reply_agent 为空时使用。
#                       空＝回落到旧 ZHIBAN_AGENT。这些字段来自 config/dispatcher.env
#                       或部署期 local env（调用方 source 后透传）。
# 可选：
#   STATUS              done | failed | timeout（result 事件据此选文案；其它值按通用文案）
#   IID                 issue IID（拼入文案）
#   MR_URL              done 文案的 MR 链接
#   WIKI_URL            failed 文案的详情链接
#   REASON              failed 文案的原因摘要 / failure 事件的失败说明
#   ORIGIN_JSON         origin 元数据（channel/user/conversation/reply_agent）紧凑 JSON；
#                       reply_agent 优先作为 114 接收结果的 agent 名，其余字段原样留痕。
#   REPLY_NOTIFY_TIMEOUT_SECONDS
#                       openclaw 反向投递超时秒数；空＝回落到旧
#                       ZHIBAN_NOTIFY_TIMEOUT_SECONDS，再空默认 30；须为正整数。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${EVENT:?notify_user: EVENT required}"
case "${EVENT}" in
  result|failure) ;;
  *) echo "notify_user: EVENT must be result|failure, got: ${EVENT}" >&2; exit 2 ;;
esac

GW_URL="${REPLY_GATEWAY_URL:-${ZHIBAN_GATEWAY_URL:-}}"
GW_TOKEN="${REPLY_GATEWAY_TOKEN:-${ZHIBAN_GATEWAY_TOKEN:-}}"
DEFAULT_AGENT="${DEFAULT_REPLY_AGENT:-${ZHIBAN_AGENT:-}}"
NOTIFY_TIMEOUT_SECONDS="${REPLY_NOTIFY_TIMEOUT_SECONDS:-${ZHIBAN_NOTIFY_TIMEOUT_SECONDS:-30}}"
STATUS="${STATUS:-}"
IID="${IID:-}"
MR_URL="${MR_URL:-}"
WIKI_URL="${WIKI_URL:-}"
REASON="${REASON:-}"
ORIGIN_JSON="${ORIGIN_JSON:-}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "${NOTIFY_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*) echo "notify_user: REPLY_NOTIFY_TIMEOUT_SECONDS must be a positive integer" >&2; exit 2 ;;
esac
case "${NOTIFY_TIMEOUT_SECONDS}" in
  *[1-9]*) ;;
  *) echo "notify_user: REPLY_NOTIFY_TIMEOUT_SECONDS must be a positive integer" >&2; exit 2 ;;
esac

# IID 前缀：有则用 "#<iid>"，无则退化为通用「任务」。文案与设计稿 §4.3 逐字一致。
issue_ref="任务"
[ -n "${IID}" ] && issue_ref="#${IID}"

# 拼人读文案（CONTENT）。result 事件按 STATUS 三态映射；failure 事件给通用失败说明。
if [ "${EVENT}" = "result" ]; then
  case "${STATUS}" in
    done)    CONTENT="${issue_ref} 已处理完成，MR：${MR_URL}" ;;
    failed)
      CONTENT="${issue_ref} 处理未通过：${REASON:-未说明原因}"
      # 失败路径通常不发 Wiki（WIKI_URL 常为空）——仅当确有链接才追加，避免「详情见 」尾随空。
      [ -n "${WIKI_URL}" ] && CONTENT="${CONTENT}，详情见 ${WIKI_URL}"
      ;;
    timeout) CONTENT="${issue_ref} 处理超时未完成，已停放待人工处理" ;;
    # result 事件理应带 done/failed/timeout 之一；缺/异常 STATUS 不致命（best-effort），
    # 退化为通用结论 + 留痕，绝不静默丢。
    *)       CONTENT="${issue_ref} 已结束（status=${STATUS:-?}）" ;;
  esac
else
  # failure 事件：建 issue 失败 / 路由未接入 / 启动执行失败等流程性失败统一推这句。
  CONTENT="${issue_ref} 流程未能完成：${REASON:-未知原因}"
fi

# 缺 jq → best-effort 跳过，不阻断回调路径。jq 虽是全脚本硬依赖（上游 drain/record 必先
# 用到、缺则在那里就先致命），这里仍自守，使 best-effort 不变量不依赖调用顺序假设。
if ! command -v jq >/dev/null 2>&1; then
  echo "notify_user: jq not found; skip (event=${EVENT} iid=${IID:-?})" >&2
  exit 0
fi

# 安全求值 origin：ORIGIN_JSON 由上游（114→orchestrator）透传，可能为空 / 合法 JSON /
# 畸形。best-effort 下绝不能因 origin 畸形而丢结论——空→null；合法 JSON→原样；
# 畸形→降级为 {raw:"<原文>"} 字符串包装并 warn，仍照常留痕。
if [ -z "${ORIGIN_JSON}" ]; then
  ORIGIN_ARG='null'
elif printf '%s' "${ORIGIN_JSON}" | jq empty >/dev/null 2>&1; then
  # 用 `jq empty`（仅按解析成败设退出码）判 ORIGIN_JSON 是否合法 JSON，而非 `jq -e .`
  # （后者按 filter 输出真值设退出码，会把合法的 false/null 标量误判为非法）。
  ORIGIN_ARG="${ORIGIN_JSON}"
else
  echo "notify_user: ORIGIN_JSON not valid JSON; wrapping as raw (event=${EVENT})" >&2
  ORIGIN_ARG="$(jq -nc --arg raw "${ORIGIN_JSON}" '{raw:$raw}')"
fi

REPLY_AGENT="$(jq -r 'if type=="object" and (.reply_agent|type=="string") then .reply_agent else "" end' <<<"${ORIGIN_ARG}")"
TARGET_AGENT="${REPLY_AGENT:-${DEFAULT_AGENT}}"

# 通道未配置：不推，但写一条 ledger 留痕（user_notify_skipped），保证漏推可审计、不静默丢。
# ledger 为 append-only 审计（与 drain_pending.sh 一致），单行 JSON 原子追加，无需 flock。
if [ -z "${GW_URL}" ] || [ -z "${GW_TOKEN}" ] || [ -z "${TARGET_AGENT}" ]; then
  jq -nc --arg ev "${EVENT}" --arg st "${STATUS}" --arg iid "${IID}" \
     --arg content "${CONTENT}" --arg ts "${TS}" --arg channel "${TARGET_AGENT}" \
     --argjson origin "${ORIGIN_ARG}" \
     '{kind:"user_notify_skipped", event:$ev,
       status:($st|select(.!="")//null),
       iid:(if $iid=="" then null else ($iid|tonumber? // $iid) end),
       content:$content, origin:$origin,
       channel:($channel|select(.!="")//null),
       skipped_at:$ts,
       reason:"114 gateway pins empty or reply agent empty"}' \
     >> "${LEDGER_FILE}" \
     || { echo "notify_user: failed to write ledger (event=${EVENT})" >&2; exit 1; }
  echo "notify_user: 114 gateway pins or reply agent empty; skip push, ledger 留痕 (event=${EVENT} iid=${IID:-?})" >&2
  exit 0
fi

ENVELOPE="$(jq -nc --arg ev "${EVENT}" --arg st "${STATUS}" --arg iid "${IID}" \
   --arg content "${CONTENT}" --arg mr "${MR_URL}" --arg wiki "${WIKI_URL}" \
   --arg rsn "${REASON}" --arg ts "${TS}" --argjson origin "${ORIGIN_ARG}" \
   '{kind:"req_result_push", event:$ev,
     status:($st|select(.!="")//null),
     iid:(if $iid=="" then null else ($iid|tonumber? // $iid) end),
     content:$content, origin:$origin,
     mr_url:($mr|select(.!="")//null),
     wiki_url:($wiki|select(.!="")//null),
     reason:($rsn|select(.!="")//null),
     ts:$ts}')"

NOTIFY_LOG="${LOG_DIR}/user_notify.jsonl"
append_notify_log() {
  _delivered="$1"
  jq -nc --argjson envelope "${ENVELOPE}" --arg channel "${TARGET_AGENT}" --arg ts "${TS}" \
     --arg delivered "${_delivered}" \
     '$envelope + {kind:"user_notify", channel:$channel,
       delivered:($delivered=="true"), notified_at:$ts}' \
     >> "${NOTIFY_LOG}" \
     || echo "notify_user: failed to write ${NOTIFY_LOG} (event=${EVENT}) (non-fatal)" >&2
}

append_push_failure_ledger() {
  _reason="$1"
  jq -nc --argjson envelope "${ENVELOPE}" --arg reason "${_reason}" --arg ts "${TS}" \
     '$envelope + {kind:"user_notify_failed", reason:$reason, failed_at:$ts}' \
     >> "${LEDGER_FILE}" \
     || echo "notify_user: failed to write user_notify_failed ledger (event=${EVENT}) (non-fatal)" >&2
}

run_openclaw_with_timeout() {
  _start_seconds=${SECONDS}
  openclaw --gateway-url "${GW_URL}" --gateway-token "${GW_TOKEN}" \
    agent run "${ENVELOPE}" --agent "${TARGET_AGENT}" >/dev/null &
  _pid=$!
  (
    sleep "${NOTIFY_TIMEOUT_SECONDS}"
    kill "${_pid}" >/dev/null 2>&1 || exit 0
    sleep 2
    kill -KILL "${_pid}" >/dev/null 2>&1 || true
  ) &
  _watchdog_pid=$!

  wait "${_pid}"
  _rc=$?
  _elapsed=$((SECONDS - _start_seconds))
  if kill -0 "${_watchdog_pid}" >/dev/null 2>&1; then
    kill "${_watchdog_pid}" >/dev/null 2>&1 || true
    wait "${_watchdog_pid}" >/dev/null 2>&1 || true
  else
    wait "${_watchdog_pid}" >/dev/null 2>&1 || true
  fi

  case "${_rc}" in
    137|143)
      if [ "${_elapsed}" -ge "${NOTIFY_TIMEOUT_SECONDS}" ]; then
        return 124
      fi
      return "${_rc}"
      ;;
    *) return "${_rc}" ;;
  esac
}

if ! command -v openclaw >/dev/null 2>&1; then
  append_push_failure_ledger "openclaw not found"
  echo "notify_user: openclaw not found; skip push (event=${EVENT} iid=${IID:-?})" >&2
  exit 0
fi

set +e
run_openclaw_with_timeout
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  append_notify_log false
  if [ "${RC}" -eq 124 ]; then
    append_push_failure_ledger "gateway agent run timeout"
  else
    append_push_failure_ledger "gateway agent run non-zero"
  fi
  echo "notify_user: push failed rc=${RC} (event=${EVENT} iid=${IID:-?}) (non-fatal)" >&2
  exit 0
fi

append_notify_log true
echo "notify_user: pushed to 114 agent (event=${EVENT} status=${STATUS:-?} iid=${IID:-?}) -> ${TARGET_AGENT}" >&2
exit 0
