#!/usr/bin/env bash
# Find one pending entry by RUN_ID, or by executor correlation_id when the
# callback channel does not carry the runtime run_id.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

RUN_ID="${RUN_ID:-}"
CORRELATION_ID="${CORRELATION_ID:-}"

if [ -z "${RUN_ID}" ] && [ -z "${CORRELATION_ID}" ]; then
  echo "find_pending: RUN_ID or CORRELATION_ID required" >&2
  exit 2
fi

exec 9>"${LOCK_FILE}"
flock 9

if [ -n "${RUN_ID}" ]; then
  entry="$(jq -c --arg rid "${RUN_ID}" '.pending[$rid] // empty' "${PENDING_FILE}")"
else
  entry="$(jq -c --arg cid "${CORRELATION_ID}" \
    '[.pending | to_entries[] | select(.value.correlation_id == $cid) | .value][0] // empty' \
    "${PENDING_FILE}")"
fi

flock -u 9

if [ -z "${entry}" ]; then
  exit 1
fi

printf '%s\n' "${entry}"
