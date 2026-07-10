#!/usr/bin/env bash
# Reserve executor-wide driven batch slots with a persistent strict
# round-robin cursor. The scheduler lock covers JSON state transitions only;
# this script never calls GitLab, clone helpers, project wrappers, or OpenClaw.
set -euo pipefail

RESERVE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESERVED_AT="${NOW_EPOCH:-$(date +%s)}"

reserve_die() {
  echo "reserve_driven_batch_items.sh: $1" >&2
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
  jq -e . "${candidate}" >/dev/null || reserve_die "refusing to publish invalid JSON for ${destination_name}"
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
    "${SCHEDULER_STATE_FILE}")" || reserve_die "scheduler state is invalid" 3
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
  ' <<<"${persisted_state}")" || reserve_die "pending scheduler transaction is invalid" 3
  # create_driven_batch.sh may safely register another frozen batch after a
  # crashed writer releases the lock. Preserve those appended registrations
  # while finishing the older transaction.
  final_scheduler_state="$(jq -c \
    --slurpfile persisted <(printf '%s\n' "${persisted_state}") '
    .scheduler_state
    | .batch_order = (.batch_order + ($persisted[0].batch_order - .batch_order))
  ' <<<"${transaction_json}")"

  mapfile -t transaction_batch_ids < <(jq -r '.batch_states | keys[]' <<<"${transaction_json}")
  if [ "${#transaction_batch_ids[@]}" -gt 0 ]; then
    for transaction_batch_id in "${transaction_batch_ids[@]}"; do
      [ -d "${BATCHES_ROOT}/${transaction_batch_id}" ] || \
        reserve_die "pending transaction batch directory is missing: ${transaction_batch_id}" 3
      batch_state_json="$(jq -c --arg batch_id "${transaction_batch_id}" '.batch_states[$batch_id]' \
        <<<"${transaction_json}")"
      atomic_write_json "${BATCHES_ROOT}/${transaction_batch_id}/state.json" "${batch_state_json}"
    done
  fi
  atomic_write_json "${SCHEDULER_STATE_FILE}" "${final_scheduler_state}"
}

case "${RESERVED_AT}" in
  ''|*[!0-9]*) reserve_die "NOW_EPOCH must be a non-negative integer" ;;
esac

# scheduler_env.sh validates deployment settings, initializes the scheduler
# layout if needed, and exports all runtime paths. Its own short initialization
# lock is released before this scheduler transaction begins.
# shellcheck disable=SC1091
source "${RESERVE_SCRIPT_DIR}/scheduler_env.sh" >/dev/null

exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"

recover_pending_transaction

SCHEDULER_STATE="$(jq -ce '
  if type == "object"
    and .version == 1
    and ((.round_robin_cursor == null) or (.round_robin_cursor | type == "string"))
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
    and (.batch_order | all(
      type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
    and ((.batch_order | length) == (.batch_order | unique | length))
    and (.active_jobs | to_entries | all(
      (.key | type == "string" and length > 0)
      and (.value | type == "object")
      and .value.job_id == .key
      and (.value.project | type == "string"
        and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
      and (.value.iid | type == "number" and . == floor and . > 0)
      and (.value as $job
        | $job.physical_key == ($job.project + "#" + ($job.iid | tostring)))
      and ((.value.branch == null) or (.value.branch | type == "string"))
      and (.value.entry_mode == "auto" or .value.entry_mode == "fresh" or .value.entry_mode == "continue")
      and (.value.force_rerun_pr | type == "boolean")
      and (.value.status == "reserved" or .value.status == "preparing" or .value.status == "running")
      and (.value.reserved_at | type == "number" and . == floor and . >= 0)
      and (.value.owner | type == "object")
      and (.value.owner.batch_id | type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and (.value.owner.snapshot_index | type == "number" and . == floor and . >= 0)
      and (.value.memberships | type == "array" and length > 0)
      and (.value.memberships | all(
        (.batch_id | type == "string"
          and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (.snapshot_index | type == "number" and . == floor and . >= 0)))
    ))
  then .
  else error("invalid scheduler state")
  end
' "${SCHEDULER_STATE_FILE}")" || reserve_die "scheduler state is invalid" 3
BASE_SCHEDULER_STATE="${SCHEDULER_STATE}"

ACTIVE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
if [ "${ACTIVE_COUNT}" -gt "${EXECUTOR_MAX_CONCURRENCY}" ]; then
  reserve_die "active job count exceeds EXECUTOR_MAX_CONCURRENCY" 3
fi
AVAILABLE_SLOTS=$((EXECUTOR_MAX_CONCURRENCY - ACTIVE_COUNT))
# A persisted `reserved` job has not yet been acknowledged as `preparing` by
# the orchestrator. Re-emit its stable grant after a process/output failure;
# once preparing is recorded, later reserve calls no longer return it.
GRANTS_JSON="$(jq -c '
  [.active_jobs | to_entries[]
    | select(.value.status == "reserved")
    | .value
    | {
        job_id,
        batch_id:.owner.batch_id,
        snapshot_index:.owner.snapshot_index,
        project,
        iid,
        branch,
        entry_mode,
        force_rerun_pr,
        reserved_at
      }]
  | sort_by(.reserved_at, .job_id)
  | map(del(.reserved_at))
' <<<"${SCHEDULER_STATE}")"
SCHEDULER_CHANGED=false

mapfile -t BATCH_ORDER < <(jq -r '.batch_order[]' <<<"${SCHEDULER_STATE}")
declare -A BATCH_STATES=()
declare -A BATCH_REQUESTS=()
declare -A BATCH_SNAPSHOTS=()
declare -A CHANGED_BATCHES=()

load_batch() {
  local batch_id="$1"
  local batch_dir="${BATCHES_ROOT}/${batch_id}"
  local request_json=""
  local snapshot_json=""
  local state_json=""

  if [ "${BATCH_STATES[${batch_id}]+x}" = x ]; then
    return 0
  fi
  [ -d "${batch_dir}" ] || reserve_die "registered batch directory is missing: ${batch_id}" 3
  for required_file in request.json snapshot.json state.json; do
    [ -f "${batch_dir}/${required_file}" ] || \
      reserve_die "registered batch is incomplete: ${batch_id}/${required_file}" 3
  done

  request_json="$(jq -ce --arg batch_id "${batch_id}" '
    if type == "object"
      and .version == 1
      and .batch_id == $batch_id
      and (.project | type == "string"
        and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
      and (.force_rerun_pr | type == "boolean")
      and ((.branch == null) or (.branch | type == "string"))
      and ((has("entry_mode") | not)
        or .entry_mode == "auto"
        or .entry_mode == "fresh"
        or .entry_mode == "continue")
    then .
    else error("invalid request")
    end
  ' "${batch_dir}/request.json")" || reserve_die "batch request is invalid: ${batch_id}" 3

  snapshot_json="$(jq -ce --arg project "$(jq -r '.project' <<<"${request_json}")" '
    if type == "object"
      and .version == 1
      and .project == $project
      and (.iids | type == "array")
      and (.iids | all(type == "number" and . == floor and . > 0))
      and (.iids == (.iids | sort | unique))
    then .
    else error("invalid snapshot")
    end
  ' "${batch_dir}/snapshot.json")" || reserve_die "batch snapshot is invalid: ${batch_id}" 3

  state_json="$(jq -ce \
    --arg batch_id "${batch_id}" \
    --argjson matched_count "$(jq -r '.iids | length' <<<"${snapshot_json}")" '
    if type == "object"
      and .version == 1
      and .batch_id == $batch_id
      and (.status == "queued" or .status == "running" or .status == "completed" or .status == "failed")
      and .matched_count == $matched_count
      and (.terminal_count | type == "number" and . == floor and . >= 0 and . <= $matched_count)
      and (.next_snapshot_index | type == "number" and . == floor and . >= 0 and . <= $matched_count)
      and (.memberships | type == "object")
      and (.memberships | to_entries | all(
        (.key | test("^(0|[1-9][0-9]*)$"))
        and ((.key | tonumber) < $matched_count)
        and (.value | type == "object")
        and .value.snapshot_index == (.key | tonumber)
        and (.value.iid | type == "number" and . == floor and . > 0)
        and (.value.status == "pending"
          or .value.status == "attached"
          or .value.status == "reserved"
          or .value.status == "preparing"
          or .value.status == "running"
          or .value.status == "retry_wait"
          or .value.status == "terminal"
          or .value.status == "skipped")
      ))
    then .
    else error("invalid state")
    end
  ' "${batch_dir}/state.json")" || reserve_die "batch state is invalid: ${batch_id}" 3

  BATCH_REQUESTS["${batch_id}"]="${request_json}"
  BATCH_SNAPSHOTS["${batch_id}"]="${snapshot_json}"
  BATCH_STATES["${batch_id}"]="${state_json}"
}

batch_order_length="${#BATCH_ORDER[@]}"
while [ "${batch_order_length}" -gt 0 ]; do
  PASS_PROGRESS=false
  CURSOR="$(jq -r '.round_robin_cursor // empty' <<<"${SCHEDULER_STATE}")"
  start_index=0
  if [ -n "${CURSOR}" ]; then
    cursor_found=false
    for ((i = 0; i < batch_order_length; i++)); do
      if [ "${BATCH_ORDER[${i}]}" = "${CURSOR}" ]; then
        start_index=$(((i + 1) % batch_order_length))
        cursor_found=true
        break
      fi
    done
    if [ "${cursor_found}" = false ]; then
      start_index=0
    fi
  fi

  for ((offset = 0; offset < batch_order_length; offset++)); do
    order_index=$(((start_index + offset) % batch_order_length))
    batch_id="${BATCH_ORDER[${order_index}]}"
    load_batch "${batch_id}"
    batch_state="${BATCH_STATES[${batch_id}]}"
    batch_status="$(jq -r '.status' <<<"${batch_state}")"
    case "${batch_status}" in
      completed|failed) continue ;;
    esac

    pending_index="$(jq -r '
      [.memberships | to_entries[]
        | select(.value.status == "pending")
        | (.key | tonumber)]
      | if length == 0 then empty else min end
    ' <<<"${batch_state}")"
    candidate_is_new=false
    if [ -z "${pending_index}" ]; then
      next_index="$(jq -r '.next_snapshot_index' <<<"${batch_state}")"
      matched_count="$(jq -r '.matched_count' <<<"${batch_state}")"
      if [ "${next_index}" -ge "${matched_count}" ]; then
        continue
      fi
      pending_index="${next_index}"
      candidate_is_new=true
    fi

    request_json="${BATCH_REQUESTS[${batch_id}]}"
    snapshot_json="${BATCH_SNAPSHOTS[${batch_id}]}"
    project="$(jq -r '.project' <<<"${request_json}")"
    iid="$(jq -r --argjson index "${pending_index}" '.iids[$index]' <<<"${snapshot_json}")"
    branch_json="$(jq -c '.branch // null' <<<"${request_json}")"
    entry_mode="$(jq -r '.entry_mode // (if .force_rerun_pr then "fresh" else "auto" end)' <<<"${request_json}")"
    force_rerun_pr="$(jq -r '.force_rerun_pr' <<<"${request_json}")"

    matching_jobs="$(jq -c \
      --arg project "${project}" \
      --argjson iid "${iid}" '
      [.active_jobs | to_entries[]
        | select(.value.project == $project and .value.iid == $iid)]
    ' <<<"${SCHEDULER_STATE}")"
    matching_job_count="$(jq -r 'length' <<<"${matching_jobs}")"
    if [ "${matching_job_count}" -gt 1 ]; then
      reserve_die "multiple active jobs hold the same physical Issue: ${project}#${iid}" 3
    fi

    if [ "${matching_job_count}" -eq 1 ]; then
      active_job_id="$(jq -r '.[0].key' <<<"${matching_jobs}")"
      same_intent="$(jq -r \
        --argjson branch "${branch_json}" \
        --arg entry_mode "${entry_mode}" \
        --argjson force_rerun_pr "${force_rerun_pr}" '
        (.[0].value.branch == $branch)
        and (.[0].value.entry_mode == $entry_mode)
        and (.[0].value.force_rerun_pr == $force_rerun_pr)
      ' <<<"${matching_jobs}")"

      if [ "${same_intent}" = true ]; then
        batch_state="$(jq -c \
          --arg index "${pending_index}" \
          --argjson snapshot_index "${pending_index}" \
          --argjson iid "${iid}" \
          --arg job_id "${active_job_id}" \
          --argjson candidate_is_new "${candidate_is_new}" '
          .memberships[$index] = {
            snapshot_index:$snapshot_index,
            iid:$iid,
            status:"attached",
            job_id:$job_id
          }
          | if $candidate_is_new then .next_snapshot_index += 1 else . end
          | .status = "running"
        ' <<<"${batch_state}")"
        SCHEDULER_STATE="$(jq -c \
          --arg job_id "${active_job_id}" \
          --arg batch_id "${batch_id}" \
          --argjson snapshot_index "${pending_index}" '
          .active_jobs[$job_id].memberships = (
            (.active_jobs[$job_id].memberships + [{batch_id:$batch_id,snapshot_index:$snapshot_index}])
            | unique_by(.batch_id, .snapshot_index)
          )
          | .round_robin_cursor = $batch_id
        ' <<<"${SCHEDULER_STATE}")"
        BATCH_STATES["${batch_id}"]="${batch_state}"
        CHANGED_BATCHES["${batch_id}"]=1
        SCHEDULER_CHANGED=true
        PASS_PROGRESS=true
      else
        old_blocker="$(jq -r --arg index "${pending_index}" '.memberships[$index].blocked_by_job_id // empty' <<<"${batch_state}")"
        if [ "${candidate_is_new}" = true ] || [ "${old_blocker}" != "${active_job_id}" ]; then
          batch_state="$(jq -c \
            --arg index "${pending_index}" \
            --argjson snapshot_index "${pending_index}" \
            --argjson iid "${iid}" \
            --arg job_id "${active_job_id}" \
            --argjson candidate_is_new "${candidate_is_new}" '
            .memberships[$index] = {
              snapshot_index:$snapshot_index,
              iid:$iid,
              status:"pending",
              blocked_by_job_id:$job_id
            }
            | if $candidate_is_new then .next_snapshot_index += 1 else . end
          ' <<<"${batch_state}")"
          BATCH_STATES["${batch_id}"]="${batch_state}"
          CHANGED_BATCHES["${batch_id}"]=1
        fi
      fi
      continue
    fi

    # A new physical job consumes a global slot. If no slot is free, leave a
    # lazy snapshot item untouched so next_snapshot_index remains a true claim
    # cursor rather than merely a scan cursor.
    if [ "${AVAILABLE_SLOTS}" -le 0 ]; then
      continue
    fi

    job_id="${batch_id}:snapshot-${pending_index}"
    if jq -e --arg job_id "${job_id}" '.active_jobs[$job_id] != null' \
      <<<"${SCHEDULER_STATE}" >/dev/null; then
      reserve_die "generated job_id already exists: ${job_id}" 3
    fi
    physical_key="${project}#${iid}"
    batch_state="$(jq -c \
      --arg index "${pending_index}" \
      --argjson snapshot_index "${pending_index}" \
      --argjson iid "${iid}" \
      --arg job_id "${job_id}" \
      --argjson candidate_is_new "${candidate_is_new}" '
      .memberships[$index] = {
        snapshot_index:$snapshot_index,
        iid:$iid,
        status:"reserved",
        job_id:$job_id
      }
      | if $candidate_is_new then .next_snapshot_index += 1 else . end
      | .status = "running"
    ' <<<"${batch_state}")"
    SCHEDULER_STATE="$(jq -c \
      --arg job_id "${job_id}" \
      --arg physical_key "${physical_key}" \
      --arg project "${project}" \
      --argjson iid "${iid}" \
      --argjson branch "${branch_json}" \
      --arg entry_mode "${entry_mode}" \
      --argjson force_rerun_pr "${force_rerun_pr}" \
      --argjson reserved_at "${RESERVED_AT}" \
      --arg batch_id "${batch_id}" \
      --argjson snapshot_index "${pending_index}" '
      .active_jobs[$job_id] = {
        job_id:$job_id,
        physical_key:$physical_key,
        project:$project,
        iid:$iid,
        branch:$branch,
        entry_mode:$entry_mode,
        force_rerun_pr:$force_rerun_pr,
        status:"reserved",
        reserved_at:$reserved_at,
        updated_at:$reserved_at,
        owner:{batch_id:$batch_id,snapshot_index:$snapshot_index},
        memberships:[{batch_id:$batch_id,snapshot_index:$snapshot_index}]
      }
      | .round_robin_cursor = $batch_id
    ' <<<"${SCHEDULER_STATE}")"
    GRANTS_JSON="$(jq -c \
      --arg job_id "${job_id}" \
      --arg batch_id "${batch_id}" \
      --argjson snapshot_index "${pending_index}" \
      --arg project "${project}" \
      --argjson iid "${iid}" \
      --argjson branch "${branch_json}" \
      --arg entry_mode "${entry_mode}" \
      --argjson force_rerun_pr "${force_rerun_pr}" '
      . + [{
        job_id:$job_id,
        batch_id:$batch_id,
        snapshot_index:$snapshot_index,
        project:$project,
        iid:$iid,
        branch:$branch,
        entry_mode:$entry_mode,
        force_rerun_pr:$force_rerun_pr
      }]
    ' <<<"${GRANTS_JSON}")"
    BATCH_STATES["${batch_id}"]="${batch_state}"
    CHANGED_BATCHES["${batch_id}"]=1
    SCHEDULER_CHANGED=true
    PASS_PROGRESS=true
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    AVAILABLE_SLOTS=$((AVAILABLE_SLOTS - 1))
  done

  [ "${PASS_PROGRESS}" = true ] || break
done

if [ "${SCHEDULER_CHANGED}" = true ]; then
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
elif [ "${#CHANGED_BATCHES[@]}" -gt 0 ]; then
  # Materializing a blocked pending membership does not change a slot or the
  # fairness cursor, so this single-file update needs no cross-file marker.
  for changed_batch_id in "${!CHANGED_BATCHES[@]}"; do
    atomic_write_json \
      "${BATCHES_ROOT}/${changed_batch_id}/state.json" \
      "${BATCH_STATES[${changed_batch_id}]}"
  done
fi

flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-

grant_count="$(jq -r 'length' <<<"${GRANTS_JSON}")"
if [ "${grant_count}" -gt 0 ]; then
  result_status=ready
elif [ "${AVAILABLE_SLOTS}" -eq 0 ]; then
  result_status=at_capacity
else
  result_status=idle
fi

jq -cn \
  --arg status "${result_status}" \
  --argjson grants "${GRANTS_JSON}" \
  --argjson active_count "${ACTIVE_COUNT}" \
  --argjson available_slots "${AVAILABLE_SLOTS}" \
  '{
    status:$status,
    grants:$grants,
    active_count:$active_count,
    available_slots:$available_slots
  }'
