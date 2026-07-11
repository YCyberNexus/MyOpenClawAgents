#!/usr/bin/env bash
# Durably record the compact executor acceptance before building local projections.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

: "${BATCH_ID:?BATCH_ID required}"
: "${EXECUTOR_AGENT:?EXECUTOR_AGENT required}"
: "${MATCHED_COUNT:?MATCHED_COUNT required}"
: "${SNAPSHOT_DIGEST:?SNAPSHOT_DIGEST required}"
: "${SCHEDULER_STATUS:?SCHEDULER_STATUS required}"
case "${MATCHED_COUNT}" in ''|*[!0-9]*) executor_batch_outbox_die "MATCHED_COUNT must be a non-negative integer" ;; esac
case "${SCHEDULER_STATUS}" in queued|running|completed) ;; *) executor_batch_outbox_die "invalid SCHEDULER_STATUS" ;; esac
[ "${MATCHED_COUNT}" -ne 0 ] || [ "${SCHEDULER_STATUS}" = completed ] \
  || executor_batch_outbox_die "zero-match receipt must be completed"
if ! jq -en --arg value "${SNAPSHOT_DIGEST}" '
  ($value | length > 0) and ($value | explode | all(. >= 32 and . != 127))
' >/dev/null; then
  executor_batch_outbox_die "SNAPSHOT_DIGEST must be printable"
fi

scheduler_rank() {
  case "$1" in queued) printf '1\n' ;; running) printf '2\n' ;; completed) printf '3\n' ;; esac
}

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exec 9>"${LOCK_FILE}"
flock 9
outbox_json="$(load_executor_batch_outbox_locked)"
matches="$(jq -c --arg batch_id "${BATCH_ID}" \
  '[.requests[] | select(.batch_id == $batch_id)]' <<<"${outbox_json}")"
match_count="$(jq -r 'length' <<<"${matches}")"
[ "${match_count}" -eq 1 ] \
  || executor_batch_outbox_die "receipt batch_id is missing or duplicated: ${BATCH_ID}" 3
entry_json="$(jq -c '.[0]' <<<"${matches}")"

persisted_executor="$(jq -r '.executor_agent' <<<"${entry_json}")"
[ "${persisted_executor}" = "${EXECUTOR_AGENT}" ] \
  || executor_batch_outbox_die "receipt executor_agent conflicts with intent" 3
entry_status="$(jq -r '.status' <<<"${entry_json}")"
receipt_status=accepted

case "${entry_status}" in
  waiting_for_legacy_drain|queued)
    next_scheduler_status="${SCHEDULER_STATUS}"
    ;;
  received|accepted)
    persisted_matched="$(jq -r '.matched_count' <<<"${entry_json}")"
    persisted_snapshot="$(jq -r '.snapshot_digest' <<<"${entry_json}")"
    persisted_scheduler="$(jq -r '.scheduler_status' <<<"${entry_json}")"
    [ "${persisted_matched}" = "${MATCHED_COUNT}" ] \
      || executor_batch_outbox_die "receipt matched_count conflicts with durable receipt" 3
    [ "${persisted_snapshot}" = "${SNAPSHOT_DIGEST}" ] \
      || executor_batch_outbox_die "receipt snapshot_digest conflicts with durable receipt" 3
    [ "$(scheduler_rank "${SCHEDULER_STATUS}")" -ge "$(scheduler_rank "${persisted_scheduler}")" ] \
      || executor_batch_outbox_die "receipt scheduler_status moved backwards" 3
    next_scheduler_status="${SCHEDULER_STATUS}"
    receipt_status=duplicate
    ;;
  *) executor_batch_outbox_die "intent status cannot accept a receipt: ${entry_status}" 3 ;;
esac

next_outbox="$(jq -c \
  --arg batch_id "${BATCH_ID}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  --arg scheduler_status "${next_scheduler_status}" \
  --arg now "${now}" '
  .requests |= map(
    if .batch_id == $batch_id then
      .status = (if .status == "accepted" then "accepted" else "received" end)
      | .matched_count = $matched_count
      | .snapshot_digest = $snapshot_digest
      | .scheduler_status = $scheduler_status
      | .received_at = (.received_at // $now)
      | .last_error = null
      | .updated_at = $now
    else . end
  )
' <<<"${outbox_json}")"
publish_executor_batch_outbox_locked "${next_outbox}"
flock -u 9

jq -cn \
  --arg status "${receipt_status}" \
  --arg batch_id "${BATCH_ID}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  --arg scheduler_status "${next_scheduler_status}" '{
    status:$status,
    batch_id:$batch_id,
    matched_count:$matched_count,
    snapshot_digest:$snapshot_digest,
    scheduler_status:$scheduler_status
  }'
