#!/usr/bin/env bash
# Rebuild the exact req_dispatcher I1 public receipt from durable executor
# scheduler state. This is the only batch acceptance object that may be the
# final compact JSON line of an agent turn.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

acceptance_die() {
  echo "emit_driven_batch_acceptance.sh: $1" >&2
  exit "${2:-2}"
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    acceptance_die "no SHA-256 command is available"
  fi
}

: "${BATCH_ID:?emit_driven_batch_acceptance.sh: BATCH_ID required}"
if ! [[ "${BATCH_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  acceptance_die "BATCH_ID must be a safe batch identifier"
fi

# scheduler_env preserves explicit process overrides, validates the configured
# root, and exports all derived scheduler paths.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null

BATCH_DIR="${BATCHES_ROOT}/${BATCH_ID}"

# The scheduler lock makes registration plus batch state one coherent read.
# A pending transaction is deliberately rejected: a later replay/tick first
# recovers it, after which this emitter can produce an unambiguous receipt.
exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"

[ -d "${BATCH_DIR}" ] \
  || acceptance_die "registered batch directory is missing: ${BATCH_ID}" 3
for required_name in request.json snapshot.json state.json; do
  [ -f "${BATCH_DIR}/${required_name}" ] \
    || acceptance_die "registered batch is incomplete: ${BATCH_ID}/${required_name}" 3
done

SCHEDULER_JSON="$(jq -ce --arg batch_id "${BATCH_ID}" '
  if type == "object"
    and .version == 1
    and (.batch_order | type == "array")
    and ([.batch_order[] | select(. == $batch_id)] | length) <= 1
    and (.active_jobs | type == "object")
    and (has("pending_transaction") | not)
  then .
  else error("batch is not durably and uniquely registered")
  end
' "${SCHEDULER_STATE_FILE}" 2>/dev/null)" \
  || acceptance_die "scheduler registration is not safe to acknowledge: ${BATCH_ID}" 3
SCHEDULER_REGISTRATION_COUNT="$(jq -r --arg batch_id "${BATCH_ID}" \
  '[.batch_order[] | select(. == $batch_id)] | length' <<<"${SCHEDULER_JSON}")"

REQUEST_JSON="$(jq -ceS --arg batch_id "${BATCH_ID}" '
  def printable:
    type == "string"
    and length > 0
    and (explode | all(. >= 32 and . != 127));
  def selector:
    type == "object"
    and (
      (.type == "single"
        and (keys | sort) == ["iid","type"]
        and (.iid | type == "number" and . == floor and . > 0))
      or (.type == "range"
        and (keys | sort) == ["iid_max","iid_min","type"]
        and (.iid_min | type == "number" and . == floor and . > 0)
        and (.iid_max | type == "number" and . == floor and . > 0)
        and .iid_max >= .iid_min)
      or (.type == "open_unfinished" and keys == ["type"])
      or (.type == "open_label"
        and (keys | sort) == ["label","type"]
        and (.label | printable))
    );
  if type == "object"
    and ((keys - [
      "batch_id","branch","callback_nonce","correlation_id",
      "dispatcher_callback_target","entry_mode","executor_agent",
      "force_rerun_pr","project","selector","version"
    ]) | length == 0)
    and .version == 1
    and .batch_id == $batch_id
    and (.correlation_id | printable)
    and (.project | type == "string"
      and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    and (.selector | selector)
    and (.force_rerun_pr | type == "boolean")
    and (.dispatcher_callback_target | printable)
    and (.executor_agent | type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
    and (.callback_nonce | type == "string" and test("^[0-9a-f]{64}$"))
    and ((.branch == null) or (.branch | printable))
    and ((has("entry_mode") | not)
      or .entry_mode == "auto"
      or .entry_mode == "fresh"
      or .entry_mode == "continue")
  then .
  else error("invalid request")
  end
' "${BATCH_DIR}/request.json" 2>/dev/null)" \
  || acceptance_die "batch request is invalid: ${BATCH_ID}" 3

PROJECT="$(jq -r '.project' <<<"${REQUEST_JSON}")"
SNAPSHOT_JSON="$(jq -ceS --arg project "${PROJECT}" '
  if type == "object"
    and (keys | sort) == ["iids","project","version"]
    and .version == 1
    and .project == $project
    and (.iids | type == "array")
    and (.iids | all(type == "number" and . == floor and . > 0))
    and (.iids == (.iids | sort | unique))
  then .
  else error("invalid snapshot")
  end
' "${BATCH_DIR}/snapshot.json" 2>/dev/null)" \
  || acceptance_die "batch snapshot is invalid: ${BATCH_ID}" 3

MATCHED_COUNT="$(jq -r '.iids | length' <<<"${SNAPSHOT_JSON}")"
REQUEST_DIGEST="$(printf '%s' "${REQUEST_JSON}" | sha256_text)"
SNAPSHOT_DIGEST="$(printf '%s' "${SNAPSHOT_JSON}" | sha256_text)"

STATE_JSON="$(jq -ce \
  --arg batch_id "${BATCH_ID}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --argjson snapshot_iids "$(jq -c '.iids' <<<"${SNAPSHOT_JSON}")" '
  if type == "object"
    and .version == 1
    and .batch_id == $batch_id
    and (.status == "queued" or .status == "running" or .status == "completed")
    and .matched_count == $matched_count
    and .request_digest == $request_digest
    and .snapshot_digest == $snapshot_digest
    and (.terminal_count | type == "number" and . == floor
      and . >= 0 and . <= $matched_count)
    and (.done_count | type == "number" and . == floor and . >= 0)
    and (.failed_count | type == "number" and . == floor and . >= 0)
    and (.timeout_count | type == "number" and . == floor and . >= 0)
    and (.skipped_count | type == "number" and . == floor and . >= 0)
    and (.next_snapshot_index | type == "number" and . == floor
      and . >= 0 and . <= $matched_count)
    and (.memberships | type == "object")
    and (.memberships | to_entries | all(
      (.key | test("^(0|[1-9][0-9]*)$"))
      and ((.key | tonumber) < $matched_count)
      and (.value | type == "object")
      and .value.snapshot_index == (.key | tonumber)
      and .value.iid == $snapshot_iids[(.key | tonumber)]
      and (.value.status == "pending"
        or .value.status == "attached"
        or .value.status == "reserved"
        or .value.status == "preparing"
        or .value.status == "running"
        or .value.status == "retry_wait"
        or .value.status == "terminal"
        or .value.status == "skipped")
    ))
    and (if $matched_count == 0 then
      .status == "completed"
      and .terminal_count == 0
      and .next_snapshot_index == 0
      and (.memberships | length) == 0
    elif .status == "completed" then
      .terminal_count == $matched_count
      and .next_snapshot_index == $matched_count
    else true end)
  then .
  else error("invalid state")
  end
' "${BATCH_DIR}/state.json" 2>/dev/null)" \
  || acceptance_die "batch state is invalid or disagrees with its immutable snapshot: ${BATCH_ID}" 3

SCHEDULER_STATUS="$(jq -r '.status' <<<"${STATE_JSON}")"
if [ "${SCHEDULER_REGISTRATION_COUNT}" -eq 0 ] \
    && [ "${SCHEDULER_STATUS}" != completed ]; then
  acceptance_die "non-terminal batch is absent from the runnable index: ${BATCH_ID}" 3
fi

flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-

# Exact five-field public contract. Do not add rich orchestration fields,
# frozen IIDs, scheduler internals, or credential material here.
jq -cn \
  --arg batch_id "${BATCH_ID}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  --arg scheduler_status "${SCHEDULER_STATUS}" '{
    status:"success",
    batch_id:$batch_id,
    matched_count:$matched_count,
    snapshot_digest:$snapshot_digest,
    scheduler_status:$scheduler_status
  }'
