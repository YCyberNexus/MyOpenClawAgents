#!/usr/bin/env bash
# Persist launch acknowledgements and physical-job release transitions for the
# executor-wide driven scheduler. No network or project operation is performed.
set -euo pipefail

RECORD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDED_AT="${NOW_EPOCH:-$(date +%s)}"

record_die() {
  echo "record_driven_batch_launch.sh: $1" >&2
  exit "${2:-2}"
}

atomic_write_json() {
  local destination="$1"
  local json="$2"
  local destination_dir=""
  local destination_name=""
  local candidate=""

  destination_dir="$(dirname "${destination}")"
  destination_name="$(basename "${destination}")"
  candidate="$(mktemp "${destination_dir}/.${destination_name}.XXXXXX")"
  printf '%s\n' "${json}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null || record_die "refusing to publish invalid JSON for ${destination_name}"
  mv "${candidate}" "${destination}"
}

recover_pending_transaction() {
  local persisted_state=""
  local transaction_json=""
  local final_scheduler_state=""
  local batch_state_json=""
  local transaction_batch_id=""
  local -a transaction_batch_ids=()

  persisted_state="$(jq -ce '
    if type == "object"
      and .version == 1
      and (.batch_order | type == "array")
      and (.batch_order | all(
        type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
      and ((.batch_order | length) == (.batch_order | unique | length))
    then .
    else error("scheduler state must be a valid object")
    end
  ' \
    "${SCHEDULER_STATE_FILE}")" || record_die "scheduler state is invalid" 3
  if ! jq -e 'has("pending_transaction")' <<<"${persisted_state}" >/dev/null; then
    return 0
  fi

  transaction_json="$(jq -ce '
    .pending_transaction
    | if type == "object"
        and .version == 1
        and (.scheduler_state | type == "object")
        and .scheduler_state.version == 1
        and ((.scheduler_state.round_robin_cursor == null)
          or (.scheduler_state.round_robin_cursor | type == "string"))
        and (.scheduler_state.active_jobs | type == "object")
        and (.scheduler_state.active_jobs | to_entries | all(
          (.value.reservation_seq | type == "number"
            and . == floor and . > 0)
          and (.value.updated_at | type == "number"
            and . == floor and . >= 0)))
        and (([.scheduler_state.active_jobs[].reservation_seq] | length)
          == ([.scheduler_state.active_jobs[].reservation_seq] | unique | length))
        and (.scheduler_state.batch_order | type == "array")
        and (.scheduler_state | has("pending_transaction") | not)
        and (.batch_states | type == "object")
        and (.batch_states | to_entries | all(
          (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
          and (.value | type == "object")
          and .value.version == 1
          and .value.batch_id == .key
          and (.value.memberships | type == "object")))
      then .
      else error("invalid pending transaction")
      end
  ' <<<"${persisted_state}")" || record_die "pending scheduler transaction is invalid" 3
  final_scheduler_state="$(jq -c \
    --slurpfile persisted <(printf '%s\n' "${persisted_state}") '
    .scheduler_state
    | .batch_order = (.batch_order + ($persisted[0].batch_order - .batch_order))
  ' <<<"${transaction_json}")"

  mapfile -t transaction_batch_ids < <(jq -r '.batch_states | keys[]' <<<"${transaction_json}")
  if [ "${#transaction_batch_ids[@]}" -gt 0 ]; then
    for transaction_batch_id in "${transaction_batch_ids[@]}"; do
      [ -d "${BATCHES_ROOT}/${transaction_batch_id}" ] || \
        record_die "pending transaction batch directory is missing: ${transaction_batch_id}" 3
      batch_state_json="$(jq -c --arg batch_id "${transaction_batch_id}" '.batch_states[$batch_id]' \
        <<<"${transaction_json}")"
      atomic_write_json "${BATCHES_ROOT}/${transaction_batch_id}/state.json" "${batch_state_json}"
    done
  fi
  atomic_write_json "${SCHEDULER_STATE_FILE}" "${final_scheduler_state}"
}

JOB_ID="${JOB_ID:-}"
STATUS="${STATUS:-}"
[ -n "${JOB_ID}" ] || record_die "JOB_ID is required"
case "${JOB_ID}" in
  *$'\n'*|*$'\r'*|*$'\t'*) record_die "JOB_ID contains control characters" ;;
esac
case "${STATUS}" in
  preparing|spawned|launch_failed|terminal) ;;
  *) record_die "STATUS must be preparing, spawned, launch_failed, or terminal" ;;
esac
case "${RECORDED_AT}" in
  ''|*[!0-9]*) record_die "NOW_EPOCH must be a non-negative integer" ;;
esac

# shellcheck disable=SC1091
source "${RECORD_SCRIPT_DIR}/scheduler_env.sh" >/dev/null

exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"

recover_pending_transaction

SCHEDULER_STATE="$(jq -ce '
  if type == "object"
    and .version == 1
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
  then .
  else error("invalid scheduler state")
  end
' "${SCHEDULER_STATE_FILE}")" || record_die "scheduler state is invalid" 3
BASE_SCHEDULER_STATE="${SCHEDULER_STATE}"

if ! jq -e --arg job_id "${JOB_ID}" '.active_jobs[$job_id] != null' \
  <<<"${SCHEDULER_STATE}" >/dev/null; then
  record_die "unknown active JOB_ID: ${JOB_ID}" 3
fi

JOB_JSON="$(jq -ce --arg job_id "${JOB_ID}" '
  .active_jobs[$job_id]
  | if type == "object"
      and .job_id == $job_id
      and (.project | type == "string"
        and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
      and (.iid | type == "number" and . == floor and . > 0)
      and (.physical_key == (.project + "#" + (.iid | tostring)))
      and (.status == "reserved" or .status == "preparing" or .status == "running")
      and (.reservation_seq | type == "number" and . == floor and . > 0)
      and (.updated_at | type == "number" and . == floor and . >= 0)
      and (.owner | type == "object")
      and (.owner.batch_id | type == "string")
      and (.owner.snapshot_index | type == "number" and . == floor and . >= 0)
      and (.memberships | type == "array" and length > 0)
      and (.memberships | all(
        (.batch_id | type == "string"
          and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (.snapshot_index | type == "number" and . == floor and . >= 0)))
    then .
    else error("invalid active job")
    end
' <<<"${SCHEDULER_STATE}")" || record_die "active job state is invalid: ${JOB_ID}" 3
CURRENT_STATUS="$(jq -r '.status' <<<"${JOB_JSON}")"
SHOULD_SPAWN=false

case "${STATUS}:${CURRENT_STATUS}" in
  preparing:reserved|preparing:preparing|spawned:reserved|spawned:preparing|spawned:running|launch_failed:reserved|launch_failed:preparing|terminal:*) ;;
  *) record_die "invalid job status transition: ${CURRENT_STATUS} -> ${STATUS}" 3 ;;
esac

case "${STATUS}" in
  preparing) NEXT_JOB_STATUS=preparing ;;
  spawned) NEXT_JOB_STATUS=running ;;
  launch_failed) NEXT_JOB_STATUS=launch_failed ;;
  terminal) NEXT_JOB_STATUS=terminal ;;
esac

if [ "${STATUS}" = preparing ] && [ "${CURRENT_STATUS}" = reserved ]; then
  SHOULD_SPAWN=true
elif [ "${STATUS}" = preparing ] && [ "${CURRENT_STATUS}" = preparing ]; then
  # The lock makes the first reserved -> preparing transition the sole spawn
  # claim. A duplicate caller observes the existing claim without refreshing
  # its timestamp, so a crashed claimant can still be recovered by its lease.
  ACTIVE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  jq -cn \
    --arg job_id "${JOB_ID}" \
    --arg job_status "${NEXT_JOB_STATUS}" \
    --argjson active_count "${ACTIVE_COUNT}" \
    --argjson should_spawn false \
    '{status:"recorded",job_id:$job_id,job_status:$job_status,
      active_count:$active_count,should_spawn:$should_spawn}'
  exit 0
fi

declare -A BATCH_STATES=()
declare -A CHANGED_BATCHES=()
owner_batch_id="$(jq -r '.owner.batch_id' <<<"${JOB_JSON}")"
owner_snapshot_index="$(jq -r '.owner.snapshot_index' <<<"${JOB_JSON}")"

while IFS=$'\t' read -r batch_id snapshot_index; do
  [ -n "${batch_id}" ] || continue
  batch_state_file="${BATCHES_ROOT}/${batch_id}/state.json"
  [ -f "${batch_state_file}" ] || record_die "job membership batch state is missing: ${batch_id}" 3

  if [ "${BATCH_STATES[${batch_id}]+x}" = x ]; then
    batch_state="${BATCH_STATES[${batch_id}]}"
  else
    batch_state="$(jq -ce --arg batch_id "${batch_id}" '
      if type == "object"
        and .version == 1
        and .batch_id == $batch_id
        and (.memberships | type == "object")
        and (.matched_count | type == "number" and . == floor and . >= 0)
        and (.terminal_count | type == "number" and . == floor and . >= 0)
        and (.next_snapshot_index | type == "number" and . == floor and . >= 0)
      then .
      else error("invalid batch state")
      end
    ' "${batch_state_file}")" || record_die "job membership batch state is invalid: ${batch_id}" 3
  fi

  membership_job_id="$(jq -r --arg index "${snapshot_index}" '.memberships[$index].job_id // empty' <<<"${batch_state}")"
  [ "${membership_job_id}" = "${JOB_ID}" ] || \
    record_die "batch membership does not reference JOB_ID: ${batch_id}/${snapshot_index}" 3

  if [ "${STATUS}" = preparing ] || [ "${STATUS}" = spawned ]; then
    if [ "${batch_id}" = "${owner_batch_id}" ] && [ "${snapshot_index}" = "${owner_snapshot_index}" ]; then
      batch_state="$(jq -c \
        --arg index "${snapshot_index}" \
        --arg status "${NEXT_JOB_STATUS}" '
        .memberships[$index].status = $status
        | .status = "running"
      ' <<<"${batch_state}")"
    fi
  elif [ "${STATUS}" = launch_failed ]; then
    batch_state="$(jq -c \
      --arg index "${snapshot_index}" '
      .memberships[$index].status = "pending"
      | del(.memberships[$index].job_id, .memberships[$index].blocked_by_job_id)
      | if ([.memberships[]
          | select(.status == "reserved"
            or .status == "preparing"
            or .status == "running"
            or .status == "attached")] | length) > 0
        then .status = "running"
        else .status = "queued"
        end
    ' <<<"${batch_state}")"
  else
    batch_state="$(jq -c \
      --arg index "${snapshot_index}" '
      .memberships[$index].status = "terminal"
      | del(.memberships[$index].blocked_by_job_id)
      | .terminal_count = ([.memberships[]
          | select(.status == "terminal" or .status == "skipped")] | length)
      | if .terminal_count == .matched_count
          and .next_snapshot_index == .matched_count
        then .status = "completed"
        elif ([.memberships[]
          | select(.status == "reserved"
            or .status == "preparing"
            or .status == "running"
            or .status == "attached")] | length) > 0
        then .status = "running"
        else .status = "queued"
        end
    ' <<<"${batch_state}")"
  fi

  BATCH_STATES["${batch_id}"]="${batch_state}"
  CHANGED_BATCHES["${batch_id}"]=1
done < <(jq -r '.memberships[] | [.batch_id, (.snapshot_index | tostring)] | @tsv' <<<"${JOB_JSON}")

if [ "${STATUS}" = preparing ] || [ "${STATUS}" = spawned ]; then
  SCHEDULER_STATE="$(jq -c \
    --arg job_id "${JOB_ID}" \
    --arg status "${NEXT_JOB_STATUS}" \
    --argjson recorded_at "${RECORDED_AT}" '
    .active_jobs[$job_id].status = $status
    | .active_jobs[$job_id].updated_at = $recorded_at
  ' <<<"${SCHEDULER_STATE}")"
else
  SCHEDULER_STATE="$(jq -c --arg job_id "${JOB_ID}" 'del(.active_jobs[$job_id])' <<<"${SCHEDULER_STATE}")"
fi

TRANSACTION_BATCH_STATES='{}'
for changed_batch_id in "${!CHANGED_BATCHES[@]}"; do
  TRANSACTION_BATCH_STATES="$(jq -c \
    --arg batch_id "${changed_batch_id}" \
    --slurpfile batch_state <(printf '%s\n' "${BATCH_STATES[${changed_batch_id}]}") '
    .[$batch_id] = $batch_state[0]
  ' <<<"${TRANSACTION_BATCH_STATES}")"
done
SCHEDULER_STATE="$(jq -c 'del(.pending_transaction)' <<<"${SCHEDULER_STATE}")"
TRANSACTION_MARKER_STATE="$(jq -c \
  --slurpfile final_scheduler_state <(printf '%s\n' "${SCHEDULER_STATE}") \
  --slurpfile batch_states <(printf '%s\n' "${TRANSACTION_BATCH_STATES}") '
  .pending_transaction = {
    version:1,
    scheduler_state:$final_scheduler_state[0],
    batch_states:$batch_states[0]
  }
' <<<"${BASE_SCHEDULER_STATE}")"
atomic_write_json "${SCHEDULER_STATE_FILE}" "${TRANSACTION_MARKER_STATE}"
for changed_batch_id in "${!CHANGED_BATCHES[@]}"; do
  atomic_write_json \
    "${BATCHES_ROOT}/${changed_batch_id}/state.json" \
    "${BATCH_STATES[${changed_batch_id}]}"
done
atomic_write_json "${SCHEDULER_STATE_FILE}" "${SCHEDULER_STATE}"

ACTIVE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-

jq -cn \
  --arg job_id "${JOB_ID}" \
  --arg job_status "${NEXT_JOB_STATUS}" \
  --argjson active_count "${ACTIVE_COUNT}" \
  --argjson should_spawn "${SHOULD_SPAWN}" \
  '{status:"recorded",job_id:$job_id,job_status:$job_status,
    active_count:$active_count,should_spawn:$should_spawn}'
