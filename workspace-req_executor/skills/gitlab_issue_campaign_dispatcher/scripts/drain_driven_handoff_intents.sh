#!/usr/bin/env bash
# drain_driven_handoff_intents.sh — recover project-local scheduler handoffs.
#
# The campaign state is the durable transaction boundary: Phase 6 drains its
# pending entry and stores a complete canonical handoff intent in one atomic
# state write. This script snapshots those intents under the project campaign
# lock, then releases the lock before materializing handoffs or invoking the
# executor-wide scheduler importer. An imported intent is deleted only after
# reacquiring the project lock and confirming its bytes are unchanged.

set -euo pipefail

: "${PROJECT:?drain_driven_handoff_intents.sh: PROJECT must be set}"
: "${GROUP:?drain_driven_handoff_intents.sh: GROUP must be set}"
: "${GITLAB_TOKEN:?drain_driven_handoff_intents.sh: GITLAB_TOKEN must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

EVENT_FILTER="${DRIVEN_HANDOFF_EVENT_ID:-}"
if [ -n "${EVENT_FILTER}" ] \
    && ! [[ "${EVENT_FILTER}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*:claim-[0-9]+:terminal-1$ ]]; then
  echo "drain_driven_handoff_intents.sh: invalid DRIVEN_HANDOFF_EVENT_ID" >&2
  exit 2
fi

# Snapshot only. No handoff file or scheduler state is touched while this lock
# is held, so an importer can never inherit project-lock ownership.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc --arg event_id "${EVENT_FILTER}" '{
    status:"lock_held",
    event_id:(if $event_id == "" then null else $event_id end),
    intent_count:0,
    results:[]
  }'
  exit 0
fi
STATE_JSON="$(load_state)"
if ! INTENT_ENTRIES="$(printf '%s' "${STATE_JSON}" | jq -ceS \
    --arg event_id "${EVENT_FILTER}" '
    if has("driven_handoff_intents")
        and (.driven_handoff_intents | type != "object")
    then error("driven_handoff_intents must be an object")
    else [(.driven_handoff_intents // {}) | to_entries[]
      | select($event_id == "" or .key == $event_id)]
    end
  ')"; then
  flock -u 9
  exec 9>&-
  echo "drain_driven_handoff_intents.sh: invalid durable intent map" >&2
  exit 3
fi
flock -u 9
exec 9>&-

# Validate the complete snapshot before performing any external work. A bad
# entry therefore cannot cause a partial import of other entries in this run.
CANONICAL_ENTRIES='[]'
while IFS= read -r entry_json; do
  [ -n "${entry_json}" ] || continue
  entry_key="$(jq -r '.key' <<<"${entry_json}")"
  if ! canonical_intent="$(phase6_canonicalize_driven_handoff_intent \
      "$(jq -c '.value' <<<"${entry_json}")")"; then
    echo "drain_driven_handoff_intents.sh: invalid durable intent: ${entry_key}" >&2
    exit 3
  fi
  if [ "$(jq -r '.handoff.event_id' <<<"${canonical_intent}")" != "${entry_key}" ]; then
    echo "drain_driven_handoff_intents.sh: intent key does not match stable event: ${entry_key}" >&2
    exit 3
  fi
  CANONICAL_ENTRIES="$(jq -ce \
    --arg key "${entry_key}" \
    --argjson value "${canonical_intent}" \
    '. + [{key:$key,value:$value}]' <<<"${CANONICAL_ENTRIES}")"
done < <(jq -c '.[]' <<<"${INTENT_ENTRIES}")

clear_intent_if_unchanged() {
  local event_id="$1" expected_intent="$2"
  local current_state updated_state

  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    exec 9>&-
    return 1
  fi
  current_state="$(load_state)"
  if ! updated_state="$(printf '%s' "${current_state}" | jq -ce \
      --arg event_id "${event_id}" \
      --argjson expected "${expected_intent}" '
      if has("driven_handoff_intents")
          and (.driven_handoff_intents | type != "object")
      then error("driven_handoff_intents must be an object")
      elif ((.driven_handoff_intents // {}) | has($event_id) | not)
      then .
      elif .driven_handoff_intents[$event_id] != $expected
      then error("durable intent changed during import")
      else
        del(.driven_handoff_intents[$event_id])
        | if (.driven_handoff_intents | length) == 0
          then del(.driven_handoff_intents)
          else .
          end
      end
    ')"; then
    flock -u 9
    exec 9>&-
    return 2
  fi
  if [ "$(jq -cS . <<<"${updated_state}")" != "$(jq -cS . <<<"${current_state}")" ]; then
    persist_state "${updated_state}"
  fi
  flock -u 9
  exec 9>&-
  return 0
}

RESULTS='[]'
while IFS= read -r entry_json; do
  [ -n "${entry_json}" ] || continue
  event_id="$(jq -r '.key' <<<"${entry_json}")"
  intent_json="$(jq -c '.value' <<<"${entry_json}")"
  handoff_path=""
  materialize_rc=0

  # Deterministic, side-effect-free failure injection for the regression test.
  # The intent remains authoritative, so even accidental activation is safe.
  if [ "${DRIVEN_HANDOFF_TEST_FAULT:-}" = fail_materialize ]; then
    materialize_rc=73
    wrapper_log followup \
      "driven handoff materialization fault injected event_id=${event_id}"
  else
    set +e
    handoff_path="$(phase6_write_driven_handoff_intent "${intent_json}" \
      2>>"${DISPATCHER_LOG_DIR}/wrapper.log")"
    materialize_rc=$?
    set -e
  fi

  if [ "${materialize_rc}" -ne 0 ]; then
    result_json="$(jq -nc --arg event_id "${event_id}" '{
      event_id:$event_id,
      status:"materialize_pending",
      handoff_path:null,
      importer_rc:null,
      intent_cleared:false
    }')"
    RESULTS="$(jq -ce --argjson result "${result_json}" \
      '. + [$result]' <<<"${RESULTS}")"
    continue
  fi

  HANDOFF_IMPORTER="${DRIVEN_HANDOFF_IMPORTER:-${SCRIPT_DIR}/import_driven_handoff.sh}"
  set +e
  HANDOFF_FILE="${handoff_path}" \
    bash "${HANDOFF_IMPORTER}" >/dev/null \
    2>>"${DISPATCHER_LOG_DIR}/wrapper.log"
  importer_rc=$?
  set -e
  if [ "${importer_rc}" -ne 0 ]; then
    wrapper_log followup \
      "handoff import pending event_id=${event_id} rc=${importer_rc} path=${handoff_path}; durable intent retained"
    result_json="$(jq -nc \
      --arg event_id "${event_id}" \
      --arg handoff_path "${handoff_path}" \
      --argjson importer_rc "${importer_rc}" '{
      event_id:$event_id,
      status:"import_pending",
      handoff_path:$handoff_path,
      importer_rc:$importer_rc,
      intent_cleared:false
    }')"
    RESULTS="$(jq -ce --argjson result "${result_json}" \
      '. + [$result]' <<<"${RESULTS}")"
    continue
  fi

  intent_cleared=false
  result_status="imported_cleanup_pending"
  if clear_intent_if_unchanged "${event_id}" "${intent_json}"; then
    intent_cleared=true
    result_status="imported"
  else
    clear_rc=$?
    wrapper_log followup \
      "handoff imported but intent cleanup pending event_id=${event_id} rc=${clear_rc}"
  fi
  wrapper_log followup \
    "handoff import completed event_id=${event_id} path=${handoff_path} intent_cleared=${intent_cleared}"
  result_json="$(jq -nc \
    --arg event_id "${event_id}" \
    --arg status "${result_status}" \
    --arg handoff_path "${handoff_path}" \
    --argjson intent_cleared "${intent_cleared}" '{
    event_id:$event_id,
    status:$status,
    handoff_path:$handoff_path,
    importer_rc:0,
    intent_cleared:$intent_cleared
  }')"
  RESULTS="$(jq -ce --argjson result "${result_json}" \
    '. + [$result]' <<<"${RESULTS}")"
done < <(jq -c '.[]' <<<"${CANONICAL_ENTRIES}")

jq -nc \
  --argjson intent_count "$(jq -r 'length' <<<"${CANONICAL_ENTRIES}")" \
  --argjson results "${RESULTS}" '{
    status:"drained",
    intent_count:$intent_count,
    results:$results
  }'
