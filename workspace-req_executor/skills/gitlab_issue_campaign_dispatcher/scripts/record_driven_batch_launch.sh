#!/usr/bin/env bash
# Persist launch acknowledgements and physical-job release transitions for the
# executor-wide driven scheduler. No network or project operation is performed.
set -euo pipefail

RECORD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDED_AT="${NOW_EPOCH:-$(date +%s)}"
PREPARING_LEASE_SECONDS="${DRIVEN_PREPARING_LEASE_SECONDS:-1800}"
CLAIM_TOKEN_INPUT="${CLAIM_TOKEN:-}"
CLAIM_GENERATION_INPUT="${CLAIM_GENERATION:-}"
FINALIZATION_EVENT_ID_INPUT="${FINALIZATION_EVENT_ID:-}"

record_die() {
  echo "record_driven_batch_launch.sh: $1" >&2
  exit "${2:-2}"
}

generate_claim_token() {
  local job_id="$1"
  local generation="$2"

  printf 'claim-v1:%s:%s:%s:%s:%04x%04x%04x%04x%04x%04x%04x%04x' \
    "${job_id}" "${generation}" "${RECORDED_AT}" "$$" \
    "${RANDOM}" "${RANDOM}" "${RANDOM}" "${RANDOM}" \
    "${RANDOM}" "${RANDOM}" "${RANDOM}" "${RANDOM}"
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    record_die "no SHA-256 command is available"
  fi
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
STATUS_INPUT="${STATUS:-}"
ACTION_INPUT="${ACTION:-}"
[ -n "${JOB_ID}" ] || record_die "JOB_ID is required"
case "${JOB_ID}" in
  *$'\n'*|*$'\r'*|*$'\t'*) record_die "JOB_ID contains control characters" ;;
esac
if [ -n "${STATUS_INPUT}" ] && [ -n "${ACTION_INPUT}" ]; then
  record_die "set exactly one of STATUS or ACTION"
fi
ACTION_MODE=false
RECOVERED_SPAWNED=false
if [ -n "${ACTION_INPUT}" ]; then
  ACTION_MODE=true
  if [ "${ACTION_INPUT}" = recovered_spawned ]; then
    STATUS=spawned
    RECOVERED_SPAWNED=true
  else
    STATUS="${ACTION_INPUT}"
  fi
else
  STATUS="${STATUS_INPUT}"
fi
case "${STATUS}" in
  preparing|spawned|launch_failed|terminal) ;;
  *) record_die "STATUS/ACTION must be preparing, spawned, recovered_spawned, launch_failed, or terminal" ;;
esac
case "${RECORDED_AT}" in
  ''|*[!0-9]*) record_die "NOW_EPOCH must be a non-negative integer" ;;
esac
case "${PREPARING_LEASE_SECONDS}" in
  ''|*[!0-9]*) record_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer" ;;
esac
if [[ "${PREPARING_LEASE_SECONDS}" =~ ^0+$ ]]; then
  record_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer"
fi
case "${CLAIM_TOKEN_INPUT}" in
  *$'\n'*|*$'\r'*|*$'\t'*) record_die "CLAIM_TOKEN contains control characters" ;;
esac
if [ -n "${CLAIM_GENERATION_INPUT}" ]; then
  case "${CLAIM_GENERATION_INPUT}" in
    *[!0-9]*) record_die "CLAIM_GENERATION must be a positive integer" ;;
  esac
fi
if [ "${RECOVERED_SPAWNED}" = true ] \
    && { [ -z "${CLAIM_GENERATION_INPUT}" ] \
      || [[ "${CLAIM_GENERATION_INPUT}" =~ ^0+$ ]]; }; then
  record_die "ACTION=recovered_spawned requires a positive CLAIM_GENERATION"
fi
if [ "${ACTION_MODE}" = true ] && [ "${STATUS}" = launch_failed ]; then
  if ! [[ "${CLAIM_GENERATION_INPUT}" =~ ^[1-9][0-9]*$ ]]; then
    record_die "ACTION=launch_failed requires a positive CLAIM_GENERATION"
  fi
  [ -n "${CLAIM_TOKEN_INPUT}" ] \
    || record_die "ACTION=launch_failed requires CLAIM_TOKEN"
fi
case "${FINALIZATION_EVENT_ID_INPUT}" in
  *$'\n'*|*$'\r'*|*$'\t'*) record_die "FINALIZATION_EVENT_ID contains control characters" ;;
esac

# shellcheck disable=SC1091
source "${RECORD_SCRIPT_DIR}/scheduler_env.sh" >/dev/null

# Keep the migration implementation single-sourced in reserve. Its private
# migration-only entry point takes and releases the same scheduler lock, runs
# no scheduling pass, and leaves a strictly validated state for record.
CONFIG_DIR="${CONFIG_DIR}" \
  NOW_EPOCH="${RECORDED_AT}" \
  DRIVEN_PREPARING_LEASE_SECONDS="${PREPARING_LEASE_SECONDS}" \
  DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
  bash "${RECORD_SCRIPT_DIR}/reserve_driven_batch_items.sh" >/dev/null

exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"

recover_pending_transaction

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
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
    and valid_launch_failed_receipts
    and (.active_jobs | to_entries | all(
      (.value.reservation_seq | type == "number" and . == floor and . > 0)
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
        end)))
    and (([.active_jobs[].reservation_seq] | length)
      == ([.active_jobs[].reservation_seq] | unique | length))
  then .
  else error("invalid scheduler state")
  end
' "${SCHEDULER_STATE_FILE}")" || record_die "scheduler state is invalid" 3
BASE_SCHEDULER_STATE="${SCHEDULER_STATE}"

if ! jq -e --arg job_id "${JOB_ID}" '.active_jobs[$job_id] != null' \
  <<<"${SCHEDULER_STATE}" >/dev/null; then
  if [ "${ACTION_MODE}" = true ] && [ "${STATUS}" = launch_failed ]; then
    LAUNCH_FAILED_RECEIPT="$(jq -c --arg job_id "${JOB_ID}" \
      '.launch_failed_receipts[$job_id] // null' <<<"${SCHEDULER_STATE}")"
    if [ "${LAUNCH_FAILED_RECEIPT}" != null ]; then
      CLAIM_TOKEN_SHA256="$(printf '%s' "${CLAIM_TOKEN_INPUT}" | sha256_text)"
      if ! jq -e \
          --arg job_id "${JOB_ID}" \
          --argjson generation "${CLAIM_GENERATION_INPUT}" \
          --arg token_sha256 "${CLAIM_TOKEN_SHA256}" '
          .job_id == $job_id
          and .claim_generation == $generation
          and .claim_token_sha256 == $token_sha256
          and .action == "launch_failed"
        ' <<<"${LAUNCH_FAILED_RECEIPT}" >/dev/null; then
        record_die "launch_failed ACTION conflicts with durable receipt: ${JOB_ID}" 3
      fi
      ACTIVE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
      flock -u "${SCHEDULER_LOCK_FD}"
      exec {SCHEDULER_LOCK_FD}>&-
      jq -cn \
        --arg job_id "${JOB_ID}" \
        --argjson active_count "${ACTIVE_COUNT}" '{
        status:"recorded",job_id:$job_id,job_status:"launch_failed",
        active_count:$active_count,should_spawn:false,
        claim_generation:null,claim_token:null
      }'
      exit 0
    fi
  fi
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
      and (.claim_generation | type == "number" and . == floor and . >= 0)
      and ((.claim_token == null) or (.claim_token | type == "string" and length > 0))
      and (if has("legacy_running")
        then .legacy_running == true
          and .status == "running"
          and .claim_generation == 0
          and .claim_token == null
        elif .status == "reserved"
        then .claim_token == null
        else (.status == "preparing" or .status == "running")
          and (.claim_token | type == "string" and length > 0)
        end)
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
CURRENT_CLAIM_GENERATION="$(jq -r '.claim_generation' <<<"${JOB_JSON}")"
CURRENT_CLAIM_TOKEN="$(jq -r '.claim_token // empty' <<<"${JOB_JSON}")"
IS_LEGACY_RUNNING="$(jq -r '.legacy_running // false' <<<"${JOB_JSON}")"
FINALIZATION_JSON="$(jq -c '.finalization // null' <<<"${JOB_JSON}")"
if [ -n "${FINALIZATION_EVENT_ID_INPUT}" ] && [ "${FINALIZATION_JSON}" = null ]; then
  record_die "FINALIZATION_EVENT_ID requires an active finalization fence: ${JOB_ID}" 3
fi
if [ "${FINALIZATION_JSON}" != null ] && [ "${STATUS}" != terminal ]; then
  record_die "finalizing job only accepts terminal: ${JOB_ID}" 3
fi
if [ "${FINALIZATION_JSON}" != null ]; then
  FINALIZATION_JSON="$(jq -ce --arg job_id "${JOB_ID}" '
    if type == "object"
      and (.claim_generation | type == "number" and . == floor and . >= 0)
      and ((.claim_token == null)
        or (.claim_token | type == "string" and length > 0))
      and .event_id == ($job_id + ":claim-"
        + (.claim_generation | tostring) + ":terminal-1")
      and (.membership_keys | type == "array" and length > 0)
      and (.membership_keys | all(
        type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}:snapshot-(0|[1-9][0-9]*)$")))
      and .membership_keys == (.membership_keys | sort | unique)
    then .
    else error("invalid finalization fence")
    end
  ' <<<"${FINALIZATION_JSON}")" \
    || record_die "active job finalization fence is invalid: ${JOB_ID}" 3
  EXPECTED_FINALIZATION_EVENT_ID="$(jq -r '.event_id' <<<"${FINALIZATION_JSON}")"
  CURRENT_MEMBERSHIP_KEYS="$(jq -c '
    [.memberships[]
      | (.batch_id + ":snapshot-" + (.snapshot_index | tostring))]
    | sort
  ' <<<"${JOB_JSON}")"
  if [ "${FINALIZATION_EVENT_ID_INPUT}" != "${EXPECTED_FINALIZATION_EVENT_ID}" ]; then
    record_die "FINALIZATION_EVENT_ID does not match finalization fence: ${JOB_ID}" 3
  fi
  if ! jq -e \
    --argjson claim_generation "${CURRENT_CLAIM_GENERATION}" \
    --argjson claim_token "$(jq -c '.claim_token' <<<"${JOB_JSON}")" \
    --argjson membership_keys "${CURRENT_MEMBERSHIP_KEYS}" '
    .claim_generation == $claim_generation
    and .claim_token == $claim_token
    and .membership_keys == $membership_keys
  ' <<<"${FINALIZATION_JSON}" >/dev/null; then
    record_die "finalization fence no longer matches active job: ${JOB_ID}" 3
  fi
fi
SHOULD_SPAWN=false
RESPONSE_CLAIM_TOKEN=""
NEXT_CLAIM_GENERATION="${CURRENT_CLAIM_GENERATION}"
NEXT_CLAIM_TOKEN="${CURRENT_CLAIM_TOKEN}"

if [ "${CURRENT_STATUS}" = preparing ] && [ "${FINALIZATION_JSON}" = null ]; then
  claim_expired="$(jq -nr \
    --argjson now "${RECORDED_AT}" \
    --argjson updated_at "$(jq -r '.updated_at' <<<"${JOB_JSON}")" \
    --arg lease_seconds "${PREPARING_LEASE_SECONDS}" '
    ($lease_seconds | tonumber) as $lease
    | (($now - $updated_at) >= $lease)
  ')"
  if [ "${claim_expired}" = true ]; then
    record_die "preparing claim lease expired: ${JOB_ID}" 3
  fi
fi

if [ "${IS_LEGACY_RUNNING}" = true ]; then
  if [ "${STATUS}" != terminal ] || [ -n "${CLAIM_TOKEN_INPUT}" ]; then
    record_die "legacy running job only accepts terminal without CLAIM_TOKEN: ${JOB_ID}" 3
  fi
else
  case "${STATUS}:${CURRENT_STATUS}" in
    preparing:reserved|preparing:preparing) ;;
    preparing:running)
      [ "${ACTION_MODE}" = true ] \
        || record_die "invalid job status transition: ${CURRENT_STATUS} -> ${STATUS}" 3
      ;;
    spawned:reserved)
      [ "${RECOVERED_SPAWNED}" = true ] \
        || record_die "invalid job status transition: ${CURRENT_STATUS} -> ${STATUS}" 3
      ;;
    spawned:preparing|spawned:running) ;;
    launch_failed:reserved|launch_failed:preparing) ;;
    terminal:reserved|terminal:preparing|terminal:running) ;;
    *) record_die "invalid job status transition: ${CURRENT_STATUS} -> ${STATUS}" 3 ;;
  esac

  case "${STATUS}" in
    spawned)
      if [ "${RECOVERED_SPAWNED}" = true ]; then
        [ "${CURRENT_STATUS}" = reserved ] \
          && [ "${CURRENT_CLAIM_GENERATION}" -eq "${CLAIM_GENERATION_INPUT}" ] \
          && [ -z "${CURRENT_CLAIM_TOKEN}" ] \
          && [ -n "${CLAIM_TOKEN_INPUT}" ] || \
          record_die "recovered_spawned does not match the fenced generation: ${JOB_ID}" 3
      else
        [ -n "${CURRENT_CLAIM_TOKEN}" ] \
          && [ "${CLAIM_TOKEN_INPUT}" = "${CURRENT_CLAIM_TOKEN}" ] || \
          record_die "CLAIM_TOKEN does not match current claim: ${JOB_ID}" 3
      fi
      ;;
    launch_failed|terminal)
      if [ "${CURRENT_STATUS}" = preparing ] || [ "${CURRENT_STATUS}" = running ]; then
        [ -n "${CURRENT_CLAIM_TOKEN}" ] \
          && [ "${CLAIM_TOKEN_INPUT}" = "${CURRENT_CLAIM_TOKEN}" ] || \
          record_die "CLAIM_TOKEN does not match current claim: ${JOB_ID}" 3
        if [ "${STATUS}" = launch_failed ] && [ "${ACTION_MODE}" = true ]; then
          [ "${CLAIM_GENERATION_INPUT}" -eq "${CURRENT_CLAIM_GENERATION}" ] \
            || record_die "CLAIM_GENERATION does not match current claim: ${JOB_ID}" 3
        fi
      elif [ "${CURRENT_CLAIM_GENERATION}" -ne 0 ] || [ -n "${CLAIM_TOKEN_INPUT}" ]; then
        record_die "reserved job has no current claim: ${JOB_ID}" 3
      fi
      ;;
  esac
fi

case "${STATUS}" in
  preparing) NEXT_JOB_STATUS=preparing ;;
  spawned) NEXT_JOB_STATUS=running ;;
  launch_failed) NEXT_JOB_STATUS=launch_failed ;;
  terminal) NEXT_JOB_STATUS=terminal ;;
esac

if [ "${RECOVERED_SPAWNED}" = true ]; then
  NEXT_CLAIM_TOKEN="${CLAIM_TOKEN_INPUT}"
fi

if [ "${STATUS}" = preparing ] \
    && { [ "${CURRENT_STATUS}" = reserved ] \
      || { [ "${ACTION_MODE}" = true ] && [ "${CURRENT_STATUS}" = running ]; }; }; then
  SHOULD_SPAWN=true
  NEXT_CLAIM_GENERATION=$((CURRENT_CLAIM_GENERATION + 1))
  NEXT_CLAIM_TOKEN="$(generate_claim_token "${JOB_ID}" "${NEXT_CLAIM_GENERATION}")"
  RESPONSE_CLAIM_TOKEN="${NEXT_CLAIM_TOKEN}"
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
    --argjson claim_generation null \
    --argjson claim_token null \
    '{status:"recorded",job_id:$job_id,job_status:$job_status,
      active_count:$active_count,should_spawn:$should_spawn,
      claim_generation:$claim_generation,claim_token:$claim_token}'
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

if [ "${STATUS}" = preparing ]; then
  SCHEDULER_STATE="$(jq -c \
    --arg job_id "${JOB_ID}" \
    --arg status "${NEXT_JOB_STATUS}" \
    --argjson recorded_at "${RECORDED_AT}" \
    --argjson claim_generation "${NEXT_CLAIM_GENERATION}" \
    --arg claim_token "${NEXT_CLAIM_TOKEN}" '
    .active_jobs[$job_id].status = $status
    | .active_jobs[$job_id].updated_at = $recorded_at
    | .active_jobs[$job_id].claim_generation = $claim_generation
    | .active_jobs[$job_id].claim_token = $claim_token
  ' <<<"${SCHEDULER_STATE}")"
elif [ "${STATUS}" = spawned ]; then
  if [ "${RECOVERED_SPAWNED}" = true ]; then
    SCHEDULER_STATE="$(jq -c \
      --arg job_id "${JOB_ID}" \
      --arg status "${NEXT_JOB_STATUS}" \
      --argjson recorded_at "${RECORDED_AT}" \
      --arg claim_token "${NEXT_CLAIM_TOKEN}" '
      .active_jobs[$job_id].status = $status
      | .active_jobs[$job_id].updated_at = $recorded_at
      | .active_jobs[$job_id].claim_token = $claim_token
    ' <<<"${SCHEDULER_STATE}")"
  else
    SCHEDULER_STATE="$(jq -c \
      --arg job_id "${JOB_ID}" \
      --arg status "${NEXT_JOB_STATUS}" \
      --argjson recorded_at "${RECORDED_AT}" '
      .active_jobs[$job_id].status = $status
      | .active_jobs[$job_id].updated_at = $recorded_at
    ' <<<"${SCHEDULER_STATE}")"
  fi
elif [ "${STATUS}" = launch_failed ]; then
  SCHEDULER_STATE="$(jq -c --arg job_id "${JOB_ID}" 'del(.active_jobs[$job_id])' <<<"${SCHEDULER_STATE}")"
  if [ "${ACTION_MODE}" = true ]; then
    CLAIM_TOKEN_SHA256="$(printf '%s' "${CLAIM_TOKEN_INPUT}" | sha256_text)"
    LAUNCH_FAILED_RECEIPT="$(jq -cnS \
      --arg job_id "${JOB_ID}" \
      --argjson claim_generation "${CLAIM_GENERATION_INPUT}" \
      --arg claim_token_sha256 "${CLAIM_TOKEN_SHA256}" \
      --argjson recorded_at "${RECORDED_AT}" '{
      version:1,
      job_id:$job_id,
      claim_generation:$claim_generation,
      claim_token_sha256:$claim_token_sha256,
      action:"launch_failed",
      recorded_at:$recorded_at
    }')"
    SCHEDULER_STATE="$(jq -c \
      --arg job_id "${JOB_ID}" \
      --argjson receipt "${LAUNCH_FAILED_RECEIPT}" '
      .launch_failed_receipts = (.launch_failed_receipts // {})
      | .launch_failed_receipts[$job_id] = $receipt
    ' <<<"${SCHEDULER_STATE}")"
  fi
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
  --argjson claim_generation "${NEXT_CLAIM_GENERATION}" \
  --arg claim_token "${RESPONSE_CLAIM_TOKEN}" \
  '{status:"recorded",job_id:$job_id,job_status:$job_status,
    active_count:$active_count,should_spawn:$should_spawn,
    claim_generation:(if $should_spawn then $claim_generation else null end),
    claim_token:(if $should_spawn then $claim_token else null end)}'
