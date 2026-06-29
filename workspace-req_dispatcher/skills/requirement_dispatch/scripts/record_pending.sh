#!/usr/bin/env bash
# 接入/编排路径：spawn 下游 agent 成功后，记一条 pending（主键 = RUN_ID）。
# 一条需求经历两段异步 spawn：先 git_issuer 段、再 executor 段，各记一条 pending（各自 run_id）。
# 入参（env）：
#   RUN_ID(必), STAGE(必: git_issuer|executor),
#   ORIGIN_JSON?(紧凑 JSON 对象 {channel,user,conversation}，经 --argjson 注入；空则 null),
#   PROJECT?, IID?(正整数), CORRELATION_ID?, CHILD_SESSION_KEY?, REQ_DIGEST?
# entry 形状（I3）见 references/state_schema.md。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${RUN_ID:?RUN_ID required}"
: "${STAGE:?STAGE required (git_issuer|executor)}"
case "${STAGE}" in
  git_issuer|executor) ;;
  *) echo "STAGE must be one of: git_issuer|executor (got: ${STAGE})" >&2; exit 1 ;;
esac
ORIGIN_JSON="${ORIGIN_JSON:-}"
PROJECT="${PROJECT:-}"
IID="${IID:-}"
CORRELATION_ID="${CORRELATION_ID:-}"
CHILD_SESSION_KEY="${CHILD_SESSION_KEY:-}"
REQ_DIGEST="${REQ_DIGEST:-}"
# IID 给定时必须是正整数（git_issuer IID 无前导零、无符号）。
if [ -n "${IID}" ]; then
  [[ "${IID}" =~ ^[1-9][0-9]*$ ]] || { echo "IID must be a positive integer (got: ${IID})" >&2; exit 1; }
fi
# ORIGIN_JSON 给定时必须是合法 JSON（经 --argjson 注入，非法会让 jq 报错；提前校验给清晰退出）。
if [ -n "${ORIGIN_JSON}" ]; then
  printf '%s' "${ORIGIN_JSON}" | jq -e . >/dev/null 2>&1 \
    || { echo "ORIGIN_JSON is not valid JSON: ${ORIGIN_JSON}" >&2; exit 1; }
fi
SPAWNED_AT="$(date -u +%s)"
[[ "${SPAWNED_AT}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${SPAWNED_AT}" >&2; exit 1; }

exec 9>"${LOCK_FILE}"
flock 9
tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
jq --arg rid "${RUN_ID}" \
   --arg stage "${STAGE}" \
   --argjson origin "${ORIGIN_JSON:-null}" \
   --arg proj "${PROJECT}" \
   --arg iid "${IID}" \
   --arg csk "${CHILD_SESSION_KEY}" \
   --arg cid "${CORRELATION_ID}" \
   --arg dig "${REQ_DIGEST}" \
   --argjson ts "${SPAWNED_AT}" \
   '.pending[$rid] = {
      run_id:$rid,
      stage:$stage,
      origin:$origin,
      project:($proj|select(.!="")//null),
      iid:(if $iid=="" then null else ($iid|tonumber) end),
      correlation_id:($cid|select(.!="")//null),
      child_session_key:($csk|select(.!="")//null),
      spawned_at:$ts,
      req_digest:$dig
    }' \
   "${PENDING_FILE}" > "${tmp}"
mv "${tmp}" "${PENDING_FILE}"
flock -u 9
printf 'recorded run_id=%s stage=%s\n' "${RUN_ID}" "${STAGE}"
