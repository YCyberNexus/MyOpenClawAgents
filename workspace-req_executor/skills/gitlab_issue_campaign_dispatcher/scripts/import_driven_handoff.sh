#!/usr/bin/env bash
# Import one project-local Phase 6 handoff into the executor scheduler's
# durable receipt and per-membership callback outbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
HANDOFF_FILE="${HANDOFF_FILE:-}"
IMPORTED_AT="${NOW_EPOCH:-$(date +%s)}"
RECORD_SCRIPT="${DRIVEN_RECORD_SCRIPT:-${SCRIPT_DIR}/record_driven_batch_launch.sh}"

import_die() {
  echo "import_driven_handoff.sh: $1" >&2
  exit "${2:-2}"
}

atomic_write_json() {
  local destination="$1"
  local json="$2"
  local destination_dir destination_name candidate

  destination_dir="$(dirname "${destination}")"
  destination_name="$(basename "${destination}")"
  candidate="$(mktemp "${destination_dir}/.${destination_name}.XXXXXX")"
  printf '%s\n' "${json}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null \
    || import_die "refusing to publish invalid JSON for ${destination_name}" 3
  mv "${candidate}" "${destination}"
}

case "${IMPORTED_AT}" in
  ''|*[!0-9]*) import_die "NOW_EPOCH must be a non-negative integer" ;;
esac
[ -n "${HANDOFF_FILE}" ] || import_die "HANDOFF_FILE is required"
[ -f "${HANDOFF_FILE}" ] || import_die "handoff file does not exist: ${HANDOFF_FILE}" 3

HANDOFF_JSON="$(jq -ce '
  def safe_id:
    type == "string"
    and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$");
  def safe_project:
    type == "string"
    and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$");
  if type == "object"
    and ((.version // 1) == 1)
    and (.event_id | safe_id)
    and (.job_id | safe_id)
    and .event_id == (.job_id + ":terminal-1")
    and .memberships == []
    and .memberships_source == "scheduler_active_job"
    and (.project | safe_project)
    and (.iid | type == "number" and . == floor and . > 0)
    and (.status == "done" or .status == "failed"
      or .status == "timeout" or .status == "skipped")
    and ((.mr_url == null) or (.mr_url | type == "string"))
    and ((.reason == null) or (.reason | type == "string"))
  then {
    version:1,
    event_id,
    job_id,
    memberships:[],
    memberships_source,
    project,
    iid,
    status,
    mr_url,
    reason
  }
  else error("invalid driven handoff")
  end
' "${HANDOFF_FILE}")" || import_die "handoff JSON is invalid" 3

JOB_ID="$(jq -r '.job_id' <<<"${HANDOFF_JSON}")"
HANDOFF_EVENT_ID="$(jq -r '.event_id' <<<"${HANDOFF_JSON}")"

# Task4 owns scheduler migration and pending-transaction recovery. Run only
# that entry point before reading scheduler state; it takes and releases its
# own scheduler lock and performs no reservation pass.
CONFIG_DIR="${CONFIG_DIR}" \
NOW_EPOCH="${IMPORTED_AT}" \
DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
bash "${SCRIPT_DIR}/reserve_driven_batch_items.sh" >/dev/null \
  || import_die "scheduler migration-only recovery failed" 3

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null

RECEIPT_FILE="${CALLBACK_INBOX}/${HANDOFF_EVENT_ID}.json"

exec {IMPORT_SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${IMPORT_SCHEDULER_LOCK_FD}"

SCHEDULER_STATE="$(jq -ce '
  if type == "object"
    and .version == 1
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
  then .
  else error("invalid scheduler state")
  end
' "${SCHEDULER_STATE_FILE}")" || import_die "scheduler state is invalid" 3

ACTIVE_JOB="$(jq -c --arg job_id "${JOB_ID}" \
  '.active_jobs[$job_id] // null' <<<"${SCHEDULER_STATE}")"
EXISTING_RECEIPT=null
if [ -f "${RECEIPT_FILE}" ]; then
  EXISTING_RECEIPT="$(jq -ce '
    if type == "object"
      and .version == 1
      and (.event_id | type == "string")
      and (.job_id | type == "string")
      and (.project | type == "string")
      and (.iid | type == "number" and . == floor and . > 0)
      and (.status == "done" or .status == "failed"
        or .status == "timeout" or .status == "skipped")
      and ((.mr_url == null) or (.mr_url | type == "string"))
      and ((.reason == null) or (.reason | type == "string"))
      and .memberships_source == "scheduler_active_job"
      and (.scheduler_status == "reserved"
        or .scheduler_status == "preparing"
        or .scheduler_status == "running")
      and ((.claim_token == null)
        or (.claim_token | type == "string" and length > 0))
      and (.legacy_running | type == "boolean")
      and (.memberships | type == "array" and length > 0)
      and (.memberships | all(
        (.batch_id | type == "string")
        and (.snapshot_index | type == "number" and . == floor and . >= 0)
        and (.target | type == "string" and length > 0)
        and (.event_id | type == "string" and length > 0)
        and (.body | type == "object")))
      and (.created_at | type == "number" and . == floor and . >= 0)
    then .
    else error("invalid import receipt")
    end
  ' "${RECEIPT_FILE}")" \
    || import_die "existing import receipt is invalid" 3

  jq -e --argjson handoff "${HANDOFF_JSON}" '
    .event_id == $handoff.event_id
    and .job_id == $handoff.job_id
    and .project == $handoff.project
    and .iid == $handoff.iid
    and .status == $handoff.status
    and .mr_url == $handoff.mr_url
    and .reason == $handoff.reason
    and .memberships_source == $handoff.memberships_source
  ' <<<"${EXISTING_RECEIPT}" >/dev/null \
    || import_die "handoff conflicts with existing import receipt" 3
fi

if [ "${ACTIVE_JOB}" = null ] && [ "${EXISTING_RECEIPT}" = null ]; then
  import_die "active scheduler job is missing and no import receipt exists: ${JOB_ID}" 3
fi

TERMINAL_RECORD_NEEDED=false
if [ "${ACTIVE_JOB}" != null ]; then
  ACTIVE_JOB="$(jq -ce --arg job_id "${JOB_ID}" \
    --arg project "$(jq -r '.project' <<<"${HANDOFF_JSON}")" \
    --argjson iid "$(jq -r '.iid' <<<"${HANDOFF_JSON}")" '
    if type == "object"
      and .job_id == $job_id
      and .project == $project
      and .iid == $iid
      and (.status == "reserved" or .status == "preparing" or .status == "running")
      and (.memberships | type == "array" and length > 0)
      and (.memberships | all(
        (.batch_id | type == "string"
          and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (.snapshot_index | type == "number" and . == floor and . >= 0)))
      and (([.memberships[] | [.batch_id,.snapshot_index]] | length)
        == ([.memberships[] | [.batch_id,.snapshot_index]] | unique | length))
      and (.claim_generation | type == "number" and . == floor and . >= 0)
      and ((.claim_token == null)
        or (.claim_token | type == "string" and length > 0))
      and (if (.legacy_running // false) == true
        then .status == "running"
          and .claim_generation == 0
          and .claim_token == null
        elif .status == "reserved"
        then .claim_token == null
        else (.claim_token | type == "string" and length > 0)
        end)
    then .
    else error("invalid active job")
    end
  ' <<<"${ACTIVE_JOB}")" || import_die "active scheduler job is invalid: ${JOB_ID}" 3

  MEMBERSHIPS_JSON='[]'
  while IFS=$'\t' read -r batch_id snapshot_index; do
    [ -n "${batch_id}" ] || continue
    request_file="${BATCHES_ROOT}/${batch_id}/request.json"
    [ -f "${request_file}" ] \
      || import_die "membership batch request is missing: ${batch_id}" 3
    request_json="$(jq -ce --arg batch_id "${batch_id}" '
      if type == "object"
        and .version == 1
        and .batch_id == $batch_id
        and (.dispatcher_callback_target | type == "string" and length > 0)
        and (.dispatcher_callback_target | explode | all(. >= 32 and . != 127))
      then .
      else error("invalid callback target")
      end
    ' "${request_file}")" \
      || import_die "membership batch request is invalid: ${batch_id}" 3
    callback_target="$(jq -r '.dispatcher_callback_target' <<<"${request_json}")"
    membership_event_id="${batch_id}:snapshot-${snapshot_index}:terminal-1"
    public_body="$(jq -cnS \
      --arg event_id "${membership_event_id}" \
      --arg batch_id "${batch_id}" \
      --argjson snapshot_index "${snapshot_index}" \
      --arg project "$(jq -r '.project' <<<"${HANDOFF_JSON}")" \
      --argjson iid "$(jq -r '.iid' <<<"${HANDOFF_JSON}")" \
      --arg status "$(jq -r '.status' <<<"${HANDOFF_JSON}")" \
      --argjson mr_url "$(jq -c '.mr_url' <<<"${HANDOFF_JSON}")" \
      --argjson reason "$(jq -c '.reason' <<<"${HANDOFF_JSON}")" '{
        event_id:$event_id,
        batch_id:$batch_id,
        snapshot_index:$snapshot_index,
        project:$project,
        iid:$iid,
        status:$status,
        mr_url:$mr_url,
        reason:$reason
      }')"
    MEMBERSHIPS_JSON="$(jq -c \
      --arg batch_id "${batch_id}" \
      --argjson snapshot_index "${snapshot_index}" \
      --arg target "${callback_target}" \
      --arg event_id "${membership_event_id}" \
      --argjson body "${public_body}" '
      . + [{
        batch_id:$batch_id,
        snapshot_index:$snapshot_index,
        target:$target,
        event_id:$event_id,
        body:$body
      }]
    ' <<<"${MEMBERSHIPS_JSON}")"
  done < <(jq -r '.memberships[] | [.batch_id, (.snapshot_index | tostring)] | @tsv' \
    <<<"${ACTIVE_JOB}")

  CREATED_AT="${IMPORTED_AT}"
  if [ "${EXISTING_RECEIPT}" != null ]; then
    CREATED_AT="$(jq -r '.created_at' <<<"${EXISTING_RECEIPT}")"
  fi
  RECEIPT_JSON="$(jq -cnS \
    --argjson handoff "${HANDOFF_JSON}" \
    --arg scheduler_status "$(jq -r '.status' <<<"${ACTIVE_JOB}")" \
    --argjson claim_token "$(jq -c '.claim_token' <<<"${ACTIVE_JOB}")" \
    --argjson legacy_running "$(jq -r '.legacy_running // false' <<<"${ACTIVE_JOB}")" \
    --argjson memberships "${MEMBERSHIPS_JSON}" \
    --argjson created_at "${CREATED_AT}" '{
      version:1,
      event_id:$handoff.event_id,
      job_id:$handoff.job_id,
      project:$handoff.project,
      iid:$handoff.iid,
      status:$handoff.status,
      mr_url:$handoff.mr_url,
      reason:$handoff.reason,
      memberships_source:$handoff.memberships_source,
      scheduler_status:$scheduler_status,
      claim_token:$claim_token,
      legacy_running:$legacy_running,
      memberships:$memberships,
      created_at:$created_at
    }')"
  TERMINAL_RECORD_NEEDED=true
else
  RECEIPT_JSON="${EXISTING_RECEIPT}"
fi

# Fail closed before changing the receipt if an existing event carries a
# different public body or a different fixed delivery target.
while IFS= read -r membership; do
  event_id="$(jq -r '.event_id' <<<"${membership}")"
  target="$(jq -r '.target' <<<"${membership}")"
  body="$(jq -c '.body' <<<"${membership}")"
  outbox_file="${CALLBACK_OUTBOX}/${event_id}.json"
  if [ -f "${outbox_file}" ]; then
    jq -e \
      --arg event_id "${event_id}" \
      --arg target "${target}" \
      --argjson body "${body}" '
      type == "object"
      and .version == 1
      and .event_id == $event_id
      and .target == $target
      and .body == $body
      and (.attempts | type == "number" and . == floor and . >= 0)
      and ((.last_error == null) or (.last_error | type == "string"))
      and ((.delivered_at == null)
        or (.delivered_at | type == "number" and . == floor and . >= 0))
    ' "${outbox_file}" >/dev/null \
      || import_die "outbox event conflicts with persisted body: ${event_id}" 3
  fi
done < <(jq -c '.memberships[]' <<<"${RECEIPT_JSON}")

# Receipt is intentionally durable before any outbox creation. It contains all
# parsed memberships and targets, so a crash can replay missing entries without
# an active scheduler job.
atomic_write_json "${RECEIPT_FILE}" "${RECEIPT_JSON}"

while IFS= read -r membership; do
  event_id="$(jq -r '.event_id' <<<"${membership}")"
  target="$(jq -r '.target' <<<"${membership}")"
  body="$(jq -c '.body' <<<"${membership}")"
  outbox_file="${CALLBACK_OUTBOX}/${event_id}.json"
  if [ -f "${outbox_file}" ]; then
    continue
  fi
  outbox_json="$(jq -cnS \
    --arg event_id "${event_id}" \
    --arg target "${target}" \
    --argjson body "${body}" \
    --argjson created_at "${IMPORTED_AT}" '{
      version:1,
      event_id:$event_id,
      target:$target,
      body:$body,
      attempts:0,
      last_error:null,
      delivered_at:null,
      created_at:$created_at,
      updated_at:$created_at
    }')"
  atomic_write_json "${outbox_file}" "${outbox_json}"
done < <(jq -c '.memberships[]' <<<"${RECEIPT_JSON}")

OUTBOX_COUNT="$(jq -r '.memberships | length' <<<"${RECEIPT_JSON}")"
CLAIM_TOKEN="$(jq -r '.claim_token // empty' <<<"${RECEIPT_JSON}")"
LEGACY_RUNNING="$(jq -r '.legacy_running' <<<"${RECEIPT_JSON}")"

flock -u "${IMPORT_SCHEDULER_LOCK_FD}"
exec {IMPORT_SCHEDULER_LOCK_FD}>&-

if [ "${TERMINAL_RECORD_NEEDED}" = true ]; then
  set +e
  if [ -n "${CLAIM_TOKEN}" ]; then
    RECORD_OUTPUT="$(
      CONFIG_DIR="${CONFIG_DIR}" \
      JOB_ID="${JOB_ID}" \
      STATUS=terminal \
      CLAIM_TOKEN="${CLAIM_TOKEN}" \
      bash "${RECORD_SCRIPT}"
    )"
    RECORD_RC=$?
  else
    RECORD_OUTPUT="$(
      env -u CLAIM_TOKEN \
      CONFIG_DIR="${CONFIG_DIR}" \
      JOB_ID="${JOB_ID}" \
      STATUS=terminal \
      bash "${RECORD_SCRIPT}"
    )"
    RECORD_RC=$?
  fi
  set -e
  [ "${RECORD_RC}" -eq 0 ] \
    || import_die "terminal record failed after receipt/outbox persistence for ${JOB_ID}" 3
  jq -e --arg job_id "${JOB_ID}" '
    .status == "recorded"
    and .job_id == $job_id
    and .job_status == "terminal"
  ' <<<"${RECORD_OUTPUT}" >/dev/null \
    || import_die "terminal record returned an invalid acknowledgement for ${JOB_ID}" 3
  IMPORT_STATUS=imported
else
  # The active job is already absent. A validated receipt is authoritative for
  # this replay window; all missing outbox files were recreated above.
  IMPORT_STATUS=replayed
fi

jq -cn \
  --arg status "${IMPORT_STATUS}" \
  --arg job_id "${JOB_ID}" \
  --arg receipt_file "${RECEIPT_FILE}" \
  --argjson outbox_count "${OUTBOX_COUNT}" \
  --argjson terminal_recorded true \
  --argjson legacy_running "${LEGACY_RUNNING}" '{
    status:$status,
    job_id:$job_id,
    receipt_file:$receipt_file,
    outbox_count:$outbox_count,
    terminal_recorded:$terminal_recorded,
    legacy_running:$legacy_running
  }'
