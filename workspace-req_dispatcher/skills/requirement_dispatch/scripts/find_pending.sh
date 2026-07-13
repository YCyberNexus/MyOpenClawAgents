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
  match_json="$(jq -c --arg rid "${RUN_ID}" '
    if .pending | has($rid)
    then {key:$rid,value:.pending[$rid]}
    else null
    end
  ' "${PENDING_FILE}")"
else
  matches_json="$(jq -c --arg cid "${CORRELATION_ID}" '
    [.pending | to_entries[] | select(.value.correlation_id == $cid)]
  ' "${PENDING_FILE}")"
  [ "$(jq -r 'length' <<<"${matches_json}")" -le 1 ] \
    || { echo "find_pending: correlation_id matches multiple pending entries" >&2; exit 3; }
  match_json="$(jq -c '.[0] // null' <<<"${matches_json}")"
fi

if [ "${match_json}" = null ]; then
  flock -u 9
  exit 1
fi
entry_key="$(jq -r '.key' <<<"${match_json}")"
entry="$(jq -c '.value' <<<"${match_json}")"

if [ "$(jq -r '.stage // ""' <<<"${entry}")" = executor ]; then
  active="$(jq -c '.active // null' "${EXECUTOR_QUEUE_FILE}")"
  if ! jq -en \
    --argjson pending "${entry}" \
    --argjson active "${active}" '
      $active != null
      and $pending.stage == "executor"
      and ($pending.callback_auth_mode == null
        or $pending.callback_auth_mode == "legacy_pre_upgrade")
      and (($pending | has("callback_nonce")) | not)
      and ($pending.callback_nonce_sha256 // null) == null
      and ($active.driven_callback_auth_mode == null
        or $active.driven_callback_auth_mode == "legacy_pre_upgrade")
      and (($active | has("callback_nonce")) | not)
      and ($active.driven_callback_nonce_sha256 // null) == null
      and ($active.launch_state // "launched") == "launched"
      and ($pending.run_id | type == "string" and length > 0)
      and $pending.run_id == $active.run_id
      and $pending.correlation_id == $active.correlation_id
      and $pending.project == $active.project
      and $pending.iid == $active.iid
    ' >/dev/null; then
    echo "find_pending: executor callback is not an authorized legacy I2" >&2
    exit 3
  fi

  next_pending="$(jq -c --arg rid "${entry_key}" '
    .pending[$rid] += {
      callback_auth_mode:"legacy_pre_upgrade",
      callback_nonce_sha256:null
    }
  ' "${PENDING_FILE}")"
  next_queue="$(jq -c '
    .active += {
      driven_callback_auth_mode:"legacy_pre_upgrade",
      driven_callback_nonce_sha256:null
    }
  ' "${EXECUTOR_QUEUE_FILE}")"
  pending_candidate="$(mktemp "${DISPATCHER_DIR}/.pending.legacy-i2.XXXXXX")"
  queue_candidate="$(mktemp "${DISPATCHER_DIR}/.executor_queue.legacy-i2.XXXXXX")"
  printf '%s\n' "${next_pending}" >"${pending_candidate}"
  printf '%s\n' "${next_queue}" >"${queue_candidate}"
  jq -e . "${pending_candidate}" >/dev/null \
    && jq -e . "${queue_candidate}" >/dev/null \
    || { echo "find_pending: refusing invalid legacy I2 migration" >&2; exit 3; }
  mv "${pending_candidate}" "${PENDING_FILE}"
  mv "${queue_candidate}" "${EXECUTOR_QUEUE_FILE}"
  entry="$(jq -c --arg rid "${entry_key}" '.pending[$rid]' "${PENDING_FILE}")"
fi

flock -u 9

printf '%s\n' "${entry}"
