#!/usr/bin/env bash
# Reserve executor-wide driven batch slots with a persistent strict
# round-robin cursor. The scheduler lock covers JSON state transitions only;
# this script never calls GitLab, clone helpers, project wrappers, or OpenClaw.
set -euo pipefail

RESERVE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESERVED_AT="${NOW_EPOCH:-$(date +%s)}"
PREPARING_LEASE_SECONDS="${DRIVEN_PREPARING_LEASE_SECONDS:-1800}"

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

migrate_legacy_scheduler_state() {
  local persisted_state=""
  local migration_target=""
  local pending_mode=false
  local migration_needed=""
  local migrated_state=""
  local migration_batch_states='{}'
  local legacy_job_id=""
  local legacy_job=""
  local owner_batch_id=""
  local owner_snapshot_index=""
  local owner_state_file=""
  local owner_state=""
  local marker_state=""
  local -a legacy_preparing_job_ids=()

  persisted_state="$(jq -ce '
    def valid_launch_failed_receipts:
      (has("launch_failed_receipts") | not)
      or (.launch_failed_receipts | type == "object"
        and (to_entries | all(. as $entry |
          ($entry.value | type == "object")
          and ($entry.value | keys | sort) == [
            "action","claim_generation","claim_token_sha256",
            "job_id","recorded_at","version"
          ]
          and $entry.value.version == 1
          and $entry.value.job_id == $entry.key
          and ($entry.value.job_id | type == "string" and length > 0)
          and ($entry.value.claim_generation | type == "number"
            and . == floor and . > 0)
          and ($entry.value.claim_token_sha256 | type == "string"
            and test("^[0-9a-f]{64}$"))
          and $entry.value.action == "launch_failed"
          and ($entry.value.recorded_at | type == "number"
            and . == floor and . >= 0))));
    if type == "object"
      and .version == 1
      and ((.round_robin_cursor == null) or (.round_robin_cursor | type == "string"))
      and (.active_jobs | type == "object")
      and (.batch_order | type == "array")
      and (.batch_order | all(
        type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
      and ((.batch_order | length) == (.batch_order | unique | length))
      and valid_launch_failed_receipts
    then .
    else error("invalid version=1 scheduler state")
    end
  ' "${SCHEDULER_STATE_FILE}")" || reserve_die "scheduler state is invalid" 3

  if jq -e 'has("pending_transaction")' <<<"${persisted_state}" >/dev/null; then
    pending_mode=true
    migration_target="$(jq -ce '
      def valid_launch_failed_receipts:
        (has("launch_failed_receipts") | not)
        or (.launch_failed_receipts | type == "object"
          and (to_entries | all(. as $entry |
            ($entry.value | type == "object")
            and ($entry.value | keys | sort) == [
              "action","claim_generation","claim_token_sha256",
              "job_id","recorded_at","version"
            ]
            and $entry.value.version == 1
            and $entry.value.job_id == $entry.key
            and ($entry.value.job_id | type == "string" and length > 0)
            and ($entry.value.claim_generation | type == "number"
              and . == floor and . > 0)
            and ($entry.value.claim_token_sha256 | type == "string"
              and test("^[0-9a-f]{64}$"))
            and $entry.value.action == "launch_failed"
            and ($entry.value.recorded_at | type == "number"
              and . == floor and . >= 0))));
      .pending_transaction
      | if type == "object"
          and .version == 1
          and (.scheduler_state | type == "object")
          and .scheduler_state.version == 1
          and ((.scheduler_state.round_robin_cursor == null)
            or (.scheduler_state.round_robin_cursor | type == "string"))
          and (.scheduler_state.active_jobs | type == "object")
          and (.scheduler_state.batch_order | type == "array")
          and (.scheduler_state | valid_launch_failed_receipts)
          and (.scheduler_state | has("pending_transaction") | not)
          and (.batch_states | type == "object")
        then .scheduler_state
        else error("invalid legacy pending transaction")
        end
    ' <<<"${persisted_state}")" || reserve_die "pending scheduler transaction is invalid" 3
  else
    migration_target="${persisted_state}"
  fi

  migration_needed="$(jq -r '
    any(.active_jobs[];
      (has("reservation_seq") | not)
      or (has("claim_generation") | not)
      or (has("claim_token") | not)
      or (has("auto_merge") | not)
      or (has("merge_target_branch") | not))
  ' <<<"${migration_target}")"
  [ "${migration_needed}" = true ] || return 0

  migration_target="$(jq -ce '
    if (.batch_order | all(
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
        and (.value.entry_mode == "auto"
          or .value.entry_mode == "fresh"
          or .value.entry_mode == "continue")
        and (.value.force_rerun_pr | type == "boolean")
        and ((.value | has("auto_merge") | not)
          or (.value.auto_merge | type == "boolean"))
        and ((.value | has("merge_target_branch") | not)
          or .value.merge_target_branch == null
          or (.value.merge_target_branch | type == "string" and length > 0))
        and (((.value.auto_merge // false) == false)
          or ((.value.merge_target_branch // null)
            | type == "string" and length > 0))
        and (.value.status == "reserved"
          or .value.status == "preparing"
          or .value.status == "running")
        and (.value.reserved_at | type == "number" and . == floor and . >= 0)
        and (.value.updated_at | type == "number" and . == floor and . >= 0)
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
    then . else error("invalid legacy active job") end
  ' <<<"${migration_target}")" || reserve_die "legacy scheduler state is invalid" 3

  mapfile -t legacy_preparing_job_ids < <(jq -r '
    .active_jobs | to_entries[]
    | select(.value.status == "preparing"
      and ((.value | has("claim_generation") | not)
        or (.value | has("claim_token") | not)))
    | .key
  ' <<<"${migration_target}")
  for legacy_job_id in "${legacy_preparing_job_ids[@]}"; do
    legacy_job="$(jq -c --arg job_id "${legacy_job_id}" \
      '.active_jobs[$job_id]' <<<"${migration_target}")"
    owner_batch_id="$(jq -r '.owner.batch_id' <<<"${legacy_job}")"
    owner_snapshot_index="$(jq -r '.owner.snapshot_index' <<<"${legacy_job}")"
    owner_state_file="${BATCHES_ROOT}/${owner_batch_id}/state.json"
    if jq -e --arg batch_id "${owner_batch_id}" '.[$batch_id] != null' \
      <<<"${migration_batch_states}" >/dev/null; then
      owner_state="$(jq -c --arg batch_id "${owner_batch_id}" \
        '.[$batch_id]' <<<"${migration_batch_states}")"
    elif [ "${pending_mode}" = true ] \
      && jq -e --arg batch_id "${owner_batch_id}" \
        '.pending_transaction.batch_states[$batch_id] != null' \
        <<<"${persisted_state}" >/dev/null; then
      owner_state="$(jq -c --arg batch_id "${owner_batch_id}" \
        '.pending_transaction.batch_states[$batch_id]' <<<"${persisted_state}")"
    else
      [ -f "${owner_state_file}" ] || \
        reserve_die "legacy preparing owner batch state is missing: ${owner_batch_id}" 3
      owner_state="$(jq -c . "${owner_state_file}")"
    fi
    owner_state="$(jq -ce \
      --arg batch_id "${owner_batch_id}" \
      --arg index "${owner_snapshot_index}" \
      --arg job_id "${legacy_job_id}" '
      if type == "object"
        and .version == 1
        and .batch_id == $batch_id
        and (.memberships | type == "object")
        and .memberships[$index].job_id == $job_id
        and .memberships[$index].status == "preparing"
      then .memberships[$index].status = "reserved" | .status = "running"
      else error("inconsistent legacy preparing owner membership")
      end
    ' <<<"${owner_state}")" || \
      reserve_die "legacy preparing owner membership is invalid: ${owner_batch_id}/${owner_snapshot_index}" 3
    migration_batch_states="$(jq -c \
      --arg batch_id "${owner_batch_id}" \
      --slurpfile batch_state <(printf '%s\n' "${owner_state}") '
      .[$batch_id] = $batch_state[0]
    ' <<<"${migration_batch_states}")"
  done

  migrated_state="$(jq -c '
    .active_jobs |= with_entries(
      .value |= (
        if has("auto_merge") then . else .auto_merge = false end
        | if has("merge_target_branch") then . else .merge_target_branch = null end))
    | ([.active_jobs | to_entries[]
        | select(.value | has("reservation_seq"))
        | .value.reservation_seq
        | select(type == "number" and . == floor and . > 0)]
      | max // 0) as $max_sequence
    | ([.active_jobs | to_entries[]
        | select(.value | has("reservation_seq") | not)]
      | sort_by(.value.reserved_at, .key)) as $missing_sequences
    | reduce range(0; ($missing_sequences | length)) as $index (.;
        .active_jobs[$missing_sequences[$index].key].reservation_seq =
          ($max_sequence + $index + 1))
    | reduce (.active_jobs | keys[]) as $job_id (.;
        if ((.active_jobs[$job_id] | has("claim_generation"))
            and (.active_jobs[$job_id] | has("claim_token")))
        then .
        elif .active_jobs[$job_id].status == "running"
        then .active_jobs[$job_id].claim_generation = 0
          | .active_jobs[$job_id].claim_token = null
          | .active_jobs[$job_id].legacy_running = true
        else .active_jobs[$job_id].status = "reserved"
          | .active_jobs[$job_id].claim_generation = 0
          | .active_jobs[$job_id].claim_token = null
          | del(.active_jobs[$job_id].legacy_running)
        end)
  ' <<<"${migration_target}")"
  if [ "${pending_mode}" = true ]; then
    marker_state="$(jq -c \
      --slurpfile final_scheduler_state <(printf '%s\n' "${migrated_state}") \
      --slurpfile batch_states <(printf '%s\n' "${migration_batch_states}") '
      .pending_transaction.scheduler_state = $final_scheduler_state[0]
      | .pending_transaction.batch_states =
          (.pending_transaction.batch_states + $batch_states[0])
    ' <<<"${persisted_state}")"
  else
    marker_state="$(jq -c \
      --slurpfile final_scheduler_state <(printf '%s\n' "${migrated_state}") \
      --slurpfile batch_states <(printf '%s\n' "${migration_batch_states}") '
      .pending_transaction = {
        version:1,
        scheduler_state:$final_scheduler_state[0],
        batch_states:$batch_states[0]
      }
    ' <<<"${persisted_state}")"
  fi
  atomic_write_json "${SCHEDULER_STATE_FILE}" "${marker_state}"
}

recover_pending_transaction() {
  local persisted_state=""
  local transaction_json=""
  local final_scheduler_state=""
  local batch_state_json=""
  local transaction_batch_id=""
  local -a transaction_batch_ids=()

  persisted_state="$(jq -ce '
    def valid_launch_failed_receipts:
      (has("launch_failed_receipts") | not)
      or (.launch_failed_receipts | type == "object"
        and (to_entries | all(. as $entry |
          ($entry.value | type == "object")
          and ($entry.value | keys | sort) == [
            "action","claim_generation","claim_token_sha256",
            "job_id","recorded_at","version"
          ]
          and $entry.value.version == 1
          and $entry.value.job_id == $entry.key
          and ($entry.value.job_id | type == "string" and length > 0)
          and ($entry.value.claim_generation | type == "number"
            and . == floor and . > 0)
          and ($entry.value.claim_token_sha256 | type == "string"
            and test("^[0-9a-f]{64}$"))
          and $entry.value.action == "launch_failed"
          and ($entry.value.recorded_at | type == "number"
            and . == floor and . >= 0))));
    if type == "object"
      and .version == 1
      and (.batch_order | type == "array")
      and (.batch_order | all(
        type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
      and ((.batch_order | length) == (.batch_order | unique | length))
      and valid_launch_failed_receipts
    then .
    else error("scheduler state must be a valid object")
    end
  ' \
    "${SCHEDULER_STATE_FILE}")" || reserve_die "scheduler state is invalid" 3
  if ! jq -e 'has("pending_transaction")' <<<"${persisted_state}" >/dev/null; then
    return 0
  fi

  transaction_json="$(jq -ce '
    def valid_launch_failed_receipts:
      (has("launch_failed_receipts") | not)
      or (.launch_failed_receipts | type == "object"
        and (to_entries | all(. as $entry |
          ($entry.value | type == "object")
          and ($entry.value | keys | sort) == [
            "action","claim_generation","claim_token_sha256",
            "job_id","recorded_at","version"
          ]
          and $entry.value.version == 1
          and $entry.value.job_id == $entry.key
          and ($entry.value.job_id | type == "string" and length > 0)
          and ($entry.value.claim_generation | type == "number"
            and . == floor and . > 0)
          and ($entry.value.claim_token_sha256 | type == "string"
            and test("^[0-9a-f]{64}$"))
          and $entry.value.action == "launch_failed"
          and ($entry.value.recorded_at | type == "number"
            and . == floor and . >= 0))));
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
            and . == floor and . >= 0)
          and (.value.claim_generation | type == "number"
            and . == floor and . >= 0)
          and ((.value.claim_token == null)
            or (.value.claim_token | type == "string" and length > 0))
          and (if (.value | has("legacy_running"))
            then .value.legacy_running == true
              and .value.status == "running"
              and .value.claim_generation == 0
              and .value.claim_token == null
            elif .value.status == "reserved"
            then .value.claim_token == null
            else (.value.status == "preparing" or .value.status == "running")
              and (.value.claim_token | type == "string" and length > 0)
            end)))
        and (([.scheduler_state.active_jobs[].reservation_seq] | length)
          == ([.scheduler_state.active_jobs[].reservation_seq] | unique | length))
        and (.scheduler_state.batch_order | type == "array")
        and (.scheduler_state | valid_launch_failed_receipts)
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
case "${PREPARING_LEASE_SECONDS}" in
  ''|*[!0-9]*) reserve_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer" ;;
esac
if [[ "${PREPARING_LEASE_SECONDS}" =~ ^0+$ ]]; then
  reserve_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer"
fi

# scheduler_env.sh validates deployment settings, initializes the scheduler
# layout if needed, and exports all runtime paths. Its own short initialization
# lock is released before this scheduler transaction begins.
# shellcheck disable=SC1091
source "${RESERVE_SCRIPT_DIR}/scheduler_env.sh" >/dev/null

exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"

migrate_legacy_scheduler_state
recover_pending_transaction
# An upgraded pending transaction may have republished the former hot
# launch_failed tombstone map. Compact it to direct cold receipts before this
# scheduling pass loads or rewrites scheduler_state.json.
scheduler_migrate_hot_launch_failed_receipts

SCHEDULER_STATE="$(jq -ce '
  def valid_launch_failed_receipts:
    (has("launch_failed_receipts") | not)
    or (.launch_failed_receipts | type == "object"
      and (to_entries | all(. as $entry |
        ($entry.value | type == "object")
        and ($entry.value | keys | sort) == [
          "action","claim_generation","claim_token_sha256",
          "job_id","recorded_at","version"
        ]
        and $entry.value.version == 1
        and $entry.value.job_id == $entry.key
        and ($entry.value.job_id | type == "string" and length > 0)
        and ($entry.value.claim_generation | type == "number"
          and . == floor and . > 0)
        and ($entry.value.claim_token_sha256 | type == "string"
          and test("^[0-9a-f]{64}$"))
        and $entry.value.action == "launch_failed"
        and ($entry.value.recorded_at | type == "number"
          and . == floor and . >= 0))));
  if type == "object"
    and .version == 1
    and ((.round_robin_cursor == null) or (.round_robin_cursor | type == "string"))
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
    and (.batch_order | all(
      type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
    and ((.batch_order | length) == (.batch_order | unique | length))
    and valid_launch_failed_receipts
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
      and (.value.auto_merge | type == "boolean")
      and ((.value.merge_target_branch == null)
        or (.value.merge_target_branch | type == "string" and length > 0))
      and ((.value.auto_merge == false)
        or (.value.merge_target_branch | type == "string" and length > 0))
      and (.value.status == "reserved" or .value.status == "preparing" or .value.status == "running")
      and (.value.reservation_seq | type == "number" and . == floor and . > 0)
      and (.value.reserved_at | type == "number" and . == floor and . >= 0)
      and (.value.updated_at | type == "number" and . == floor and . >= 0)
      and (.value.claim_generation | type == "number" and . == floor and . >= 0)
      and ((.value.claim_token == null)
        or (.value.claim_token | type == "string" and length > 0))
      and (if (.value | has("legacy_running"))
        then .value.legacy_running == true
          and .value.status == "running"
          and .value.claim_generation == 0
          and .value.claim_token == null
        elif .value.status == "reserved"
        then .value.claim_token == null
        else (.value.status == "preparing" or .value.status == "running")
          and (.value.claim_token | type == "string" and length > 0)
        end)
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
    and (([.active_jobs[].reservation_seq] | length)
      == ([.active_jobs[].reservation_seq] | unique | length))
  then .
  else error("invalid scheduler state")
  end
' "${SCHEDULER_STATE_FILE}")" || reserve_die "scheduler state is invalid" 3
BASE_SCHEDULER_STATE="${SCHEDULER_STATE}"
if [ "${DRIVEN_SCHEDULER_MIGRATION_ONLY:-0}" = 1 ]; then
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  exit 0
fi
SCHEDULER_CHANGED=false

# `batch_order` is the hot runnable index, not an audit log. Compact terminal
# batches under the scheduler lock before the fairness loop; their immutable
# directories remain addressable by batch_id for acceptance/idempotency but are
# never opened by later ticks. This one-file transition is independently atomic
# and therefore does not need the cross-file pending_transaction marker.
ACTIVE_BATCH_ORDER='[]'
while IFS= read -r registered_batch_id; do
  [ -n "${registered_batch_id}" ] || continue
  registered_state_file="${BATCHES_ROOT}/${registered_batch_id}/state.json"
  [ -f "${registered_state_file}" ] \
    || reserve_die "registered batch state is missing: ${registered_batch_id}" 3
  registered_status="$(jq -er '
    .status | select(. == "queued" or . == "running"
      or . == "completed" or . == "failed")
  ' "${registered_state_file}")" \
    || reserve_die "registered batch state is invalid: ${registered_batch_id}" 3
  case "${registered_status}" in
    completed|failed) ;;
    *)
      ACTIVE_BATCH_ORDER="$(jq -c --arg batch_id "${registered_batch_id}" \
        '. + [$batch_id]' <<<"${ACTIVE_BATCH_ORDER}")"
      ;;
  esac
done < <(jq -r '.batch_order[]' <<<"${SCHEDULER_STATE}")
if [ "$(jq -c '.batch_order' <<<"${SCHEDULER_STATE}")" != "${ACTIVE_BATCH_ORDER}" ]; then
  SCHEDULER_STATE="$(jq -c --argjson active_order "${ACTIVE_BATCH_ORDER}" '
    .round_robin_cursor as $cursor
    | .batch_order = $active_order
    | if $cursor != null
        and ($active_order | index($cursor)) == null
      then .round_robin_cursor = null else . end
  ' <<<"${SCHEDULER_STATE}")"
  atomic_write_json "${SCHEDULER_STATE_FILE}" "${SCHEDULER_STATE}"
  BASE_SCHEDULER_STATE="${SCHEDULER_STATE}"
fi

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
      and ((has("auto_merge") | not) or (.auto_merge | type == "boolean"))
      and ((has("merge_target_branch") | not)
        or .merge_target_branch == null
        or (.merge_target_branch | type == "string" and length > 0))
      and (((.auto_merge // false) == false)
        or ((.merge_target_branch // null)
          | type == "string" and length > 0))
      and ((has("entry_mode") | not)
        or .entry_mode == "auto"
        or .entry_mode == "fresh"
        or .entry_mode == "continue")
    then (if has("auto_merge") then . else .auto_merge = false end
      | if has("merge_target_branch") then . else .merge_target_branch = null end)
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
      and .terminal_counts_version == 1
        and (.done_count | type == "number" and . == floor and . >= 0)
        and (.failed_count | type == "number" and . == floor and . >= 0)
        and (.timeout_count | type == "number" and . == floor and . >= 0)
        and (.skipped_count | type == "number" and . == floor and . >= 0)
        and (.memberships | all(
          if .status == "terminal" then
            (.terminal_status == "done"
              or .terminal_status == "failed"
              or .terminal_status == "timeout"
              or .terminal_status == "skipped")
          else
            (has("terminal_status") | not)
          end))
        and (.terminal_count == ([.memberships[]
          | select(.status == "terminal" or .status == "skipped")] | length))
        and (.done_count == ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "done")] | length))
        and (.failed_count == ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "failed")] | length))
        and (.timeout_count == ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "timeout")] | length))
        and (.skipped_count == ([.memberships[]
          | select(.status == "skipped"
            or (.status == "terminal" and .terminal_status == "skipped"))] | length))
        and (.terminal_count == (.done_count + .failed_count
          + .timeout_count + .skipped_count))
    then .
    else error("invalid state")
    end
  ' "${batch_dir}/state.json")" || reserve_die "batch state is invalid: ${batch_id}" 3

  BATCH_REQUESTS["${batch_id}"]="${request_json}"
  BATCH_SNAPSHOTS["${batch_id}"]="${snapshot_json}"
  BATCH_STATES["${batch_id}"]="${state_json}"
}

mapfile -t EXPIRED_PREPARING_JOB_IDS < <(jq -r \
  --argjson now "${RESERVED_AT}" \
  --arg lease_seconds "${PREPARING_LEASE_SECONDS}" '
  ($lease_seconds | tonumber) as $lease
  | [.active_jobs | to_entries[]
      | select(.value.status == "preparing"
        and (.value.finalization // null) == null
        and (($now - .value.updated_at) >= $lease))]
  | sort_by(.value.reservation_seq)
  | .[].key
' <<<"${SCHEDULER_STATE}")
for expired_job_id in "${EXPIRED_PREPARING_JOB_IDS[@]}"; do
  expired_job="$(jq -c \
    --arg job_id "${expired_job_id}" \
    '.active_jobs[$job_id]' \
    <<<"${SCHEDULER_STATE}")"
  expired_batch_id="$(jq -r '.owner.batch_id' <<<"${expired_job}")"
  expired_snapshot_index="$(jq -r '.owner.snapshot_index' <<<"${expired_job}")"
  load_batch "${expired_batch_id}"
  expired_batch_state="${BATCH_STATES[${expired_batch_id}]}"
  if ! jq -e \
    --arg index "${expired_snapshot_index}" \
    --arg job_id "${expired_job_id}" '
    .memberships[$index].job_id == $job_id
    and .memberships[$index].status == "preparing"
  ' <<<"${expired_batch_state}" >/dev/null; then
    reserve_die \
      "expired preparing owner membership is inconsistent: ${expired_batch_id}/${expired_snapshot_index}" \
      3
  fi

  expired_batch_state="$(jq -c \
    --arg index "${expired_snapshot_index}" '
    .memberships[$index].status = "reserved"
    | .status = "running"
  ' <<<"${expired_batch_state}")"
  SCHEDULER_STATE="$(jq -c \
    --arg job_id "${expired_job_id}" \
    --argjson recorded_at "${RESERVED_AT}" '
    .active_jobs[$job_id].status = "reserved"
    | .active_jobs[$job_id].updated_at = $recorded_at
    | .active_jobs[$job_id].claim_token = null
  ' <<<"${SCHEDULER_STATE}")"
  BATCH_STATES["${expired_batch_id}"]="${expired_batch_state}"
  CHANGED_BATCHES["${expired_batch_id}"]=1
  SCHEDULER_CHANGED=true
done

ACTIVE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
SCHEDULER_MAX_CONCURRENCY="$(jq -er \
  --argjson configured_max "${EXECUTOR_MAX_CONCURRENCY}" '
  (.max_concurrency // $configured_max)
  | if type == "number" and . == floor and . > 0
    then . else error("invalid max_concurrency") end
' <<<"${SCHEDULER_STATE}")" \
  || reserve_die "scheduler max_concurrency is invalid" 3
if [ "${ACTIVE_COUNT}" -ge "${SCHEDULER_MAX_CONCURRENCY}" ]; then
  AVAILABLE_SLOTS=0
else
  AVAILABLE_SLOTS=$((SCHEDULER_MAX_CONCURRENCY - ACTIVE_COUNT))
fi
NEXT_RESERVATION_SEQ="$(jq -r \
  '[.active_jobs[].reservation_seq] | (max // 0) + 1' \
  <<<"${SCHEDULER_STATE}")"
# A persisted `reserved` job has not yet been acknowledged as `preparing`, or
# its previous preparing claim exceeded the recoverable lease. Re-emit the
# stable public grant without exposing its internal reservation sequence.
GRANTS_JSON="$(jq -c '
  [.active_jobs | to_entries[]
    | select(.value.status == "reserved"
      and (.value.finalization // null) == null)
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
        auto_merge,
        merge_target_branch,
        reservation_seq
      }]
  | sort_by(.reservation_seq)
  | map(del(.reservation_seq))
' <<<"${SCHEDULER_STATE}")"

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

    request_json="${BATCH_REQUESTS[${batch_id}]}"
    snapshot_json="${BATCH_SNAPSHOTS[${batch_id}]}"
    project="$(jq -r '.project' <<<"${request_json}")"
    branch_json="$(jq -c '.branch // null' <<<"${request_json}")"
    entry_mode="$(jq -r '.entry_mode // "auto"' <<<"${request_json}")"
    force_rerun_pr="$(jq -r '.force_rerun_pr' <<<"${request_json}")"
    auto_merge="$(jq -r '.auto_merge' <<<"${request_json}")"
    merge_target_branch_json="$(jq -c '.merge_target_branch' <<<"${request_json}")"

    # A blocked low-index membership must not hide a later runnable item. Scan
    # pending and still-lazy snapshot indices in order, but stop after the first
    # attach or grant so each batch still advances at most once per round.
    mapfile -t CANDIDATE_INDICES < <(jq -r '
      ([.memberships | to_entries[]
          | select(.value.status == "pending")
          | (.key | tonumber)]
        + [range(.next_snapshot_index; .matched_count)])
      | unique
      | sort
      | .[]
    ' <<<"${batch_state}")
    [ "${#CANDIDATE_INDICES[@]}" -gt 0 ] || continue

    for pending_index in "${CANDIDATE_INDICES[@]}"; do
      candidate_is_new="$(jq -r \
        --arg index "${pending_index}" \
        '.memberships | has($index) | not' \
        <<<"${batch_state}")"
      iid="$(jq -r --argjson index "${pending_index}" '.iids[$index]' <<<"${snapshot_json}")"

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
        --argjson force_rerun_pr "${force_rerun_pr}" \
        --argjson auto_merge "${auto_merge}" \
        --argjson merge_target_branch "${merge_target_branch_json}" '
        (.[0].value.branch == $branch)
        and (.[0].value.entry_mode == $entry_mode)
        and (.[0].value.force_rerun_pr == $force_rerun_pr)
        and (.[0].value.auto_merge == $auto_merge)
        and (.[0].value.merge_target_branch == $merge_target_branch)
      ' <<<"${matching_jobs}")"
      finalization_present="$(jq -r \
        '.[0].value.finalization != null' <<<"${matching_jobs}")"

      if [ "${finalization_present}" = true ]; then
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
        continue
      elif [ "${same_intent}" = true ]; then
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
        break
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
        continue
      fi
    fi

    # A new physical job consumes a global slot. If no slot is free, leave a
    # lazy snapshot item untouched so next_snapshot_index remains a true claim
    # cursor rather than merely a scan cursor.
      if [ "${AVAILABLE_SLOTS}" -le 0 ]; then
        break
      fi

    job_id="${batch_id}:snapshot-${pending_index}"
    if jq -e --arg job_id "${job_id}" '.active_jobs[$job_id] != null' \
      <<<"${SCHEDULER_STATE}" >/dev/null; then
      reserve_die "generated job_id already exists: ${job_id}" 3
    fi
    physical_key="${project}#${iid}"
    reservation_seq="${NEXT_RESERVATION_SEQ}"
    NEXT_RESERVATION_SEQ=$((NEXT_RESERVATION_SEQ + 1))
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
      --argjson auto_merge "${auto_merge}" \
      --argjson merge_target_branch "${merge_target_branch_json}" \
      --argjson reservation_seq "${reservation_seq}" \
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
        auto_merge:$auto_merge,
        merge_target_branch:$merge_target_branch,
        status:"reserved",
        reservation_seq:$reservation_seq,
        claim_generation:0,
        claim_token:null,
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
      --argjson force_rerun_pr "${force_rerun_pr}" \
      --argjson auto_merge "${auto_merge}" \
      --argjson merge_target_branch "${merge_target_branch_json}" '
      . + [{
        job_id:$job_id,
        batch_id:$batch_id,
        snapshot_index:$snapshot_index,
        project:$project,
        iid:$iid,
        branch:$branch,
        entry_mode:$entry_mode,
        force_rerun_pr:$force_rerun_pr,
        auto_merge:$auto_merge,
        merge_target_branch:$merge_target_branch
      }]
    ' <<<"${GRANTS_JSON}")"
    BATCH_STATES["${batch_id}"]="${batch_state}"
    CHANGED_BATCHES["${batch_id}"]=1
    SCHEDULER_CHANGED=true
    PASS_PROGRESS=true
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
      AVAILABLE_SLOTS=$((AVAILABLE_SLOTS - 1))
      break
    done
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
  --argjson max_concurrency "${SCHEDULER_MAX_CONCURRENCY}" \
  '{
    status:$status,
    grants:$grants,
    active_count:$active_count,
    available_slots:$available_slots,
    max_concurrency:$max_concurrency
  }'
