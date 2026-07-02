#!/usr/bin/env bash
# ops_notify.sh — best-effort 运维失败告警。
#
# 由 orchestrator 在失败路径、drain/ledger 写入之后调用：接入路径下游调用三次仍败
# (launch_failed)、git_issuer 返回失败 (git_issuer_failed)、接入路径开头
# evict_stuck 驱逐到超时 pending (stuck_evicted)。把失败事件推给运维 channel。
#
# 与 Global Rule #1 不冲突：本脚本用 curl 仅向 OPS_NOTIFY_CHANNEL（企业微信群机器人
# webhook）发一条运维告警，**不碰 GitLab、不建 issue、不打标签**——那条红线限定的是
# "用 curl 去碰 GitLab"。本脚本被 SKILL/references 显式登记，是 No-Fallback 白名单
# 内的合法流程；要换通知形态就改本脚本，而非在 orchestrator 里临场拼命令。
#
# best-effort 语义（仿 acpx post_result_note.sh）：通知是锦上添花，绝不能让失败路径
# 因"发告警"再失败、也绝不静默丢需求（需求由 pending/ledger 兜底，本脚本不碰 state）：
#   - OPS_NOTIFY_CHANNEL 为空 → no-op，exit 0（SKILL/config：留空则不通知）。
#   - 缺 curl / 缺 jq / 网络超时 / webhook 非 2xx → stderr 记 warning，仍 exit 0。
#   - 缺 EVENT（必填未给）→ exit 1（调用方 bug，与兄弟脚本 :? 惯例一致）。
#   - 仅"部署配置形态错误"（EVENT 非法 / channel 非 http(s) URL）→ exit 2，
#     让运维知道配错了（这不属 best-effort 范畴，是部署期 pin 写错）。
#
# 入参（env）：
#   OPS_NOTIFY_CHANNEL  企业微信群机器人 webhook URL（http/https）；空＝no-op。
#                       来自 config/dispatcher.env（调用方 source 后透传）。
#   EVENT               必填：launch_failed | git_issuer_failed | stuck_evicted
# 可选：
#   RUN_ID              相关 run_id（launch_failed / git_issuer_failed）
#   REASON              失败原因摘要
#   COUNT               stuck_evicted 被驱逐条数
set -euo pipefail

CHANNEL="${OPS_NOTIFY_CHANNEL:-}"
# 留空＝部署期未配 channel：no-op、成功退出（SKILL：留空则不通知）。
if [ -z "${CHANNEL}" ]; then
  echo "ops_notify: OPS_NOTIFY_CHANNEL empty; skip" >&2
  exit 0
fi

: "${EVENT:?ops_notify: EVENT required}"
case "${EVENT}" in
  launch_failed|git_issuer_failed|stuck_evicted) ;;
  *) echo "ops_notify: EVENT must be launch_failed|git_issuer_failed|stuck_evicted, got: ${EVENT}" >&2; exit 2 ;;
esac

# 仅接受 http(s) webhook URL；形态不符＝部署配置写错（非 best-effort 范畴），显式失败。
case "${CHANNEL}" in
  http://*|https://*) ;;
  *) echo "ops_notify: OPS_NOTIFY_CHANNEL must be an http(s) webhook URL" >&2; exit 2 ;;
esac

RUN_ID="${RUN_ID:-}"
REASON="${REASON:-}"
COUNT="${COUNT:-}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 缺 curl 或 jq → best-effort 跳过，不阻断失败路径。jq 虽是全脚本硬依赖（上游
# drain/evict 必先用到、缺则在那里就先致命），这里仍自守，使 best-effort 不变量
# 不依赖"上游先跑 jq"的调用顺序假设。
for _bin in curl jq; do
  if ! command -v "${_bin}" >/dev/null 2>&1; then
    echo "ops_notify: ${_bin} not found; skip (event=${EVENT} run_id=${RUN_ID:-?})" >&2
    exit 0
  fi
done

# 人读告警正文（紧凑单行；详细证据已在 ledger.jsonl）。
CONTENT="[req_dispatcher] ${EVENT}"
[ -n "${RUN_ID}" ] && CONTENT="${CONTENT} run_id=${RUN_ID}"
[ -n "${COUNT}" ]  && CONTENT="${CONTENT} count=${COUNT}"
[ -n "${REASON}" ] && CONTENT="${CONTENT} reason=${REASON}"
CONTENT="${CONTENT} at ${TS}"

# 企业微信群机器人文本消息；jq 保证 JSON 转义（reason 可能含引号/换行/中文）。
PAYLOAD="$(jq -nc --arg c "${CONTENT}" '{msgtype:"text", text:{content:$c}}')"

# best-effort POST：限时、失败不致命（隔离 curl 退出码，绝不让 set -e 冒泡）。
set +e
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST -H 'Content-Type: application/json' \
  --data "${PAYLOAD}" "${CHANNEL}" 2>/dev/null)"
RC=$?
set -e
if [ "${RC}" -ne 0 ]; then
  echo "ops_notify: curl failed rc=${RC} event=${EVENT} run_id=${RUN_ID:-?} (non-fatal)" >&2
  exit 0
fi
case "${HTTP_CODE}" in
  2??) echo "ops_notify: sent event=${EVENT} run_id=${RUN_ID:-?} http=${HTTP_CODE}" >&2 ;;
  *)   echo "ops_notify: webhook returned http=${HTTP_CODE} event=${EVENT} run_id=${RUN_ID:-?} (non-fatal)" >&2 ;;
esac
exit 0
