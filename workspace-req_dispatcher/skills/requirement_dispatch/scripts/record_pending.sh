#!/usr/bin/env bash
# 接入路径：spawn git_issuer 成功后，记一条 pending（主键 = RUN_ID）。
# 入参（env）：RUN_ID(必), CHILD_SESSION_KEY?, CORRELATION_ID?, REQ_DIGEST?
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${RUN_ID:?RUN_ID required}"
CHILD_SESSION_KEY="${CHILD_SESSION_KEY:-}"
CORRELATION_ID="${CORRELATION_ID:-}"
REQ_DIGEST="${REQ_DIGEST:-}"
SPAWNED_AT="$(date -u +%s)"
[[ "${SPAWNED_AT}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${SPAWNED_AT}" >&2; exit 1; }

exec 9>"${LOCK_FILE}"
flock 9
tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
jq --arg rid "${RUN_ID}" \
   --arg csk "${CHILD_SESSION_KEY}" \
   --arg cid "${CORRELATION_ID}" \
   --arg dig "${REQ_DIGEST}" \
   --argjson ts "${SPAWNED_AT}" \
   '.pending[$rid] = {child_session_key:($csk|select(.!="")//null), correlation_id:($cid|select(.!="")//null), spawned_at:$ts, req_digest:$dig}' \
   "${PENDING_FILE}" > "${tmp}"
mv "${tmp}" "${PENDING_FILE}"
flock -u 9
printf 'recorded run_id=%s\n' "${RUN_ID}"
