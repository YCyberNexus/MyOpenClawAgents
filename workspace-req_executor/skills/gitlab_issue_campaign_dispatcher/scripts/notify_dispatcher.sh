#!/usr/bin/env bash
# notify_dispatcher.sh — best-effort Phase 6 结果回调 (active-orchestration 设计稿).
#
# 在 driven 路径（req_dispatcher 经 RUN_SINGLE_ISSUE 派来的单 issue 执行）的
# Phase 6 终态由 dispatch_followup.sh 调用：把执行器 final_status 经 I2 信封回投给
# req_dispatcher，使其按 correlation_id 匹配 pending、推结果给发起需求的用户。
#
# 仅在 final_status ∈ {done,failed,timeout} 时调用（blocked 不回调，见设计稿 §I2）。
#
# 设计为 best-effort：调用方用 `set +e` 隔离并忽略其退出码，所以本脚本失败绝不影响
# Phase 6。它**只**拼 I2 JSON 并把信封交给跨 agent send 原语；不读/写任何 state
# 文件、不碰 glab、不打标签、不碰 MR。通道未配置或发送失败一律 exit 0 + 留痕，绝不
# 静默丢；仅入参/发送形态写错才非零退出（status 非法 exit 2）。
#
# 跨 agent send 原语：当前本地对齐形态使用 `openclaw agent` 把
# RUN_EXECUTOR_RESULT_CALLBACK 投回 dispatcher 目标 session；同时继续把信封 JSON
# 追加到 dispatcher_callbacks.jsonl 留痕（仿 post_result_note.sh 的 best-effort 语义）。
#
# 入参（env，I4 契约）：
#   必填：
#     CORRELATION_ID                 回显 RUN_SINGLE_ISSUE 的关联 token
#     IID                            目标 issue IID（正整数）
#     STATUS                         done | failed | timeout（= 执行器 final_status）
#   可选：
#     DISPATCHER_CALLBACK_TARGET     回调目标；空则 no-op exit 0
#                                    支持 agent:req_dispatcher:main 或裸 agent 名
#     DISPATCHER_CALLBACK_TIMEOUT_SECONDS  openclaw agent 超时，默认 300
#     PROJECT                        group/project（信封 project 字段）
#     MR_URL                         成功时的 MR URL（信封 mr_url）
#     WIKI_URL                       Wiki URL（信封 wiki_url）
#     REASON                         失败/超时原因（信封 reason）
#
# 注意：本脚本**不**强制 source env_paths.sh —— 它是纯本地留痕、不碰 glab，不应被
# env_paths.sh 的 PROJECT/GROUP/GITLAB_TOKEN 强制要求与 glab 鉴权拖累。日志目录优先
# 复用调用方（dispatch_followup.sh 已 source env_paths.sh）透传进来的 WORK_ROOT，
# 缺失时退回 /tmp（见设计稿 Task A3）。
set -euo pipefail

# ─── 1. 校验必填 + status 取值（仿 post_result_note.sh） ──────────────
: "${CORRELATION_ID:?notify_dispatcher: CORRELATION_ID required}"
: "${IID:?notify_dispatcher: IID required}"
: "${STATUS:?notify_dispatcher: STATUS required}"
case "${IID}" in
  *[!0-9]*|"") echo "notify_dispatcher: IID must be a positive integer, got: ${IID}" >&2; exit 2 ;;
esac
case "${STATUS}" in
  done|failed|timeout) ;;
  *) echo "notify_dispatcher: STATUS must be done|failed|timeout, got: ${STATUS}" >&2; exit 2 ;;
esac

DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}"
PROJECT="${PROJECT:-}"
MR_URL="${MR_URL:-}"
WIKI_URL="${WIKI_URL:-}"
REASON="${REASON:-}"

# ─── 2. 通道未配置 → no-op（留痕到 stderr，exit 0） ──────────────────
# 回调目标为待对齐占位；未配置时不是错误（cron 路径不带 target），直接 no-op。
if [ -z "${DISPATCHER_CALLBACK_TARGET}" ]; then
  echo "notify_dispatcher: no DISPATCHER_CALLBACK_TARGET; skip callback for iid=${IID} status=${STATUS}" >&2
  exit 0
fi

# ─── 3. 拼 I2 信封 JSON（一行紧凑；空字段落 null） ───────────────────
# {"correlation_id","iid","project","status","mr_url","wiki_url","reason"}
ENVELOPE="$(jq -nc \
  --arg correlation_id "${CORRELATION_ID}" \
  --argjson iid "${IID}" \
  --arg project "${PROJECT}" \
  --arg status "${STATUS}" \
  --arg mr_url "${MR_URL}" \
  --arg wiki_url "${WIKI_URL}" \
  --arg reason "${REASON}" '
  {correlation_id:$correlation_id,
   iid:$iid,
   project:($project|select(.!="")//null),
   status:$status,
   mr_url:($mr_url|select(.!="")//null),
   wiki_url:($wiki_url|select(.!="")//null),
   reason:($reason|select(.!="")//null)}')"

# ─── 4. 跨 agent send（openclaw agent + 留痕，绝不静默丢） ───────────
# 日志目录：优先复用调用方透传的 WORK_ROOT（dispatch_followup.sh 已 source
# env_paths.sh → WORK_ROOT=${RESULT_ROOT}/_dispatcher），缺失时退回 /tmp。
LOG_DIR="${WORK_ROOT:-/tmp}/log"
mkdir -p "${LOG_DIR}"
CALLBACK_LOG="${LOG_DIR}/dispatcher_callbacks.jsonl"

printf '%s\n' "${ENVELOPE}" >>"${CALLBACK_LOG}"
echo "notify_dispatcher: callback envelope recorded iid=${IID} status=${STATUS} target=${DISPATCHER_CALLBACK_TARGET} -> ${CALLBACK_LOG}" >&2

DISPATCHER_CALLBACK_TIMEOUT_SECONDS="${DISPATCHER_CALLBACK_TIMEOUT_SECONDS:-300}"
case "${DISPATCHER_CALLBACK_TIMEOUT_SECONDS}" in
  *[!0-9]*|"") echo "notify_dispatcher: DISPATCHER_CALLBACK_TIMEOUT_SECONDS must be a positive integer, got: ${DISPATCHER_CALLBACK_TIMEOUT_SECONDS}" >&2; exit 2 ;;
  0) echo "notify_dispatcher: DISPATCHER_CALLBACK_TIMEOUT_SECONDS must be positive" >&2; exit 2 ;;
esac

TARGET_AGENT="${DISPATCHER_CALLBACK_TARGET}"
TARGET_SESSION_KEY=""
case "${DISPATCHER_CALLBACK_TARGET}" in
  agent:*:*)
    TARGET_SESSION_KEY="${DISPATCHER_CALLBACK_TARGET}"
    rest="${DISPATCHER_CALLBACK_TARGET#agent:}"
    TARGET_AGENT="${rest%%:*}"
    ;;
esac

if [ -z "${TARGET_AGENT}" ]; then
  echo "notify_dispatcher: empty callback target agent in DISPATCHER_CALLBACK_TARGET=${DISPATCHER_CALLBACK_TARGET}" >&2
  exit 2
fi

if ! command -v openclaw >/dev/null 2>&1; then
  echo "notify_dispatcher: openclaw command not found; callback recorded only" >&2
  exit 0
fi

CALLBACK_MESSAGE="$(printf 'RUN_EXECUTOR_RESULT_CALLBACK\nworker_result_json=%s\n' "${ENVELOPE}")"
openclaw_args=(agent --agent "${TARGET_AGENT}")
if [ -n "${TARGET_SESSION_KEY}" ]; then
  openclaw_args+=(--session-key "${TARGET_SESSION_KEY}")
fi
openclaw_args+=(--message "${CALLBACK_MESSAGE}" --timeout "${DISPATCHER_CALLBACK_TIMEOUT_SECONDS}")

if ! openclaw "${openclaw_args[@]}" >/dev/null; then
  echo "notify_dispatcher: openclaw callback failed; envelope remains recorded in ${CALLBACK_LOG}" >&2
  exit 0
fi

echo "notify_dispatcher: callback sent iid=${IID} status=${STATUS} target=${DISPATCHER_CALLBACK_TARGET}" >&2
exit 0
