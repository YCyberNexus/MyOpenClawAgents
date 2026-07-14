#!/usr/bin/env bash
# Import one project-local Phase 6 handoff into the executor scheduler's
# durable receipt and per-membership callback outbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
HANDOFF_FILE="${HANDOFF_FILE:-}"
IMPORTED_AT="${NOW_EPOCH:-$(date +%s)}"
PREPARING_LEASE_SECONDS="${DRIVEN_PREPARING_LEASE_SECONDS:-1800}"
MIGRATION_SCRIPT="${DRIVEN_MIGRATION_SCRIPT:-${SCRIPT_DIR}/reserve_driven_batch_items.sh}"
RECORD_SCRIPT="${DRIVEN_RECORD_SCRIPT:-${SCRIPT_DIR}/record_driven_batch_launch.sh}"
RECONCILE_COUNTS_SCRIPT="${DRIVEN_RECONCILE_COUNTS_SCRIPT:-${SCRIPT_DIR}/reconcile_driven_terminal_counts.sh}"
MIGRATION_RECOVERY_LIMIT=3

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

locate_outbox_file() {
  local event_id="$1"
  local hot_file="${CALLBACK_OUTBOX}/${event_id}.json"
  local archive_file="${CALLBACK_ARCHIVE}/${event_id}.json"
  if [ -e "${hot_file}" ] && [ -e "${archive_file}" ]; then
    import_die "outbox event exists in both hot and archive storage: ${event_id}" 3
  elif [ -e "${archive_file}" ]; then
    printf '%s\n' "${archive_file}"
  else
    printf '%s\n' "${hot_file}"
  fi
}

acquire_callback_event_locks() {
  local event_id="$1" lock_digest
  unset CALLBACK_EVENT_LEGACY_LOCK_FD CALLBACK_EVENT_LOCK_FD
  if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ]; then
    exec {CALLBACK_EVENT_LEGACY_LOCK_FD}>"${CALLBACK_OUTBOX}/.${event_id}.lock"
    flock -x "${CALLBACK_EVENT_LEGACY_LOCK_FD}"
  fi
  lock_digest="$(printf '%s' "${event_id}" | scheduler_sha256_text)"
  exec {CALLBACK_EVENT_LOCK_FD}>"${CALLBACK_LOCKS}/${lock_digest}.lock"
  flock -x "${CALLBACK_EVENT_LOCK_FD}"
}

release_callback_event_locks() {
  flock -u "${CALLBACK_EVENT_LOCK_FD}" 2>/dev/null || true
  exec {CALLBACK_EVENT_LOCK_FD}>&-
  unset CALLBACK_EVENT_LOCK_FD
  if [ -n "${CALLBACK_EVENT_LEGACY_LOCK_FD:-}" ]; then
    flock -u "${CALLBACK_EVENT_LEGACY_LOCK_FD}" 2>/dev/null || true
    exec {CALLBACK_EVENT_LEGACY_LOCK_FD}>&-
    unset CALLBACK_EVENT_LEGACY_LOCK_FD
  fi
}

run_scheduler_migration() {
  CONFIG_DIR="${CONFIG_DIR}" \
  NOW_EPOCH="${IMPORTED_AT}" \
  DRIVEN_PREPARING_LEASE_SECONDS="${PREPARING_LEASE_SECONDS}" \
  DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
  bash "${MIGRATION_SCRIPT}" >/dev/null \
    || import_die "scheduler migration-only recovery failed" 3
}

release_delivery_gate() {
  local ready_at membership event_id target callback_auth_mode executor_agent callback_nonce body outbox_file
  local current_entry next_entry

  ready_at="$(date +%s)"
  RECEIPT_JSON="$(jq -c '.terminal_recorded = true' <<<"${RECEIPT_JSON}")"
  atomic_write_json "${RECEIPT_FILE}" "${RECEIPT_JSON}"

  while IFS= read -r membership; do
    event_id="$(jq -r '.event_id' <<<"${membership}")"
    target="$(jq -r '.target' <<<"${membership}")"
    callback_auth_mode="$(jq -r '.callback_auth_mode' <<<"${membership}")"
    executor_agent="$(jq -r '.executor_agent // empty' <<<"${membership}")"
    callback_nonce="$(jq -r '.callback_nonce // empty' <<<"${membership}")"
    body="$(jq -c '.body' <<<"${membership}")"
    acquire_callback_event_locks "${event_id}"
    # The drainer can move hot -> archive at any time before this event lock is
    # held. Locate only after locking so validation and update use one stable
    # path for the whole critical section.
    outbox_file="$(locate_outbox_file "${event_id}")"
    current_entry="$(jq -ce \
      --arg event_id "${event_id}" \
      --arg target "${target}" \
      --arg callback_auth_mode "${callback_auth_mode}" \
      --arg executor_agent "${executor_agent}" \
      --arg callback_nonce "${callback_nonce}" \
      --argjson body "${body}" '
      if type == "object"
        and .version == 1
        and .event_id == $event_id
        and .target == $target
        and ((.callback_auth_mode //
          (if has("executor_agent") or has("callback_nonce")
           then "nonce_v1" else "legacy_pre_upgrade" end)) == $callback_auth_mode)
        and (if $callback_auth_mode == "nonce_v1"
          then .executor_agent == $executor_agent
            and .callback_nonce == $callback_nonce
          else (has("executor_agent") | not) and (has("callback_nonce") | not)
          end)
        and .body == $body
        and ((.ready_at == null)
          or (.ready_at | type == "number" and . == floor and . >= 0))
      then . + {callback_auth_mode:$callback_auth_mode}
      else error("outbox changed before delivery release")
      end
    ' "${outbox_file}")" \
      || import_die "outbox entry changed before delivery release: ${event_id}" 3
    if [ "${outbox_file%/*}" = "${CALLBACK_ARCHIVE}" ]; then
      jq -e '.delivered_at != null' <<<"${current_entry}" >/dev/null \
        || import_die "archived outbox entry is not delivered: ${event_id}" 3
      release_callback_event_locks
      continue
    fi
    next_entry="$(jq -c \
      --argjson ready_at "${ready_at}" '
      .ready_at = (.ready_at // $ready_at)
      | .updated_at = $ready_at
    ' <<<"${current_entry}")"
    atomic_write_json "${outbox_file}" "${next_entry}"
    release_callback_event_locks
  done < <(jq -c '.memberships[]' <<<"${RECEIPT_JSON}")
}

case "${IMPORTED_AT}" in
  ''|*[!0-9]*) import_die "NOW_EPOCH must be a non-negative integer" ;;
esac
case "${PREPARING_LEASE_SECONDS}" in
  ''|*[!0-9]*) import_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer" ;;
esac
if [[ "${PREPARING_LEASE_SECONDS}" =~ ^0+$ ]]; then
  import_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer"
fi
case "${MIGRATION_SCRIPT}" in
  /*) ;;
  *) import_die "DRIVEN_MIGRATION_SCRIPT must be an absolute path" ;;
esac
case "${MIGRATION_SCRIPT}" in
  *$'\n'*|*$'\r'*|*$'\t'*) import_die "DRIVEN_MIGRATION_SCRIPT contains control characters" ;;
esac
[ -f "${MIGRATION_SCRIPT}" ] && [ -x "${MIGRATION_SCRIPT}" ] \
  || import_die "DRIVEN_MIGRATION_SCRIPT must be an executable regular file"
case "${RECONCILE_COUNTS_SCRIPT}" in
  /*) ;;
  *) import_die "DRIVEN_RECONCILE_COUNTS_SCRIPT must be an absolute path" ;;
esac
case "${RECONCILE_COUNTS_SCRIPT}" in
  *$'\n'*|*$'\r'*|*$'\t'*) import_die "DRIVEN_RECONCILE_COUNTS_SCRIPT contains control characters" ;;
esac
[ -f "${RECONCILE_COUNTS_SCRIPT}" ] && [ -x "${RECONCILE_COUNTS_SCRIPT}" ] \
  || import_die "DRIVEN_RECONCILE_COUNTS_SCRIPT must be an executable regular file"
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
    and (.claim_generation | type == "number" and . == floor and . >= 0)
    and ((.claim_token == null)
      or (.claim_token | type == "string" and length > 0))
    and (if .claim_generation == 0
      then .claim_token == null
      else (.claim_token | type == "string" and length > 0)
      end)
    and .event_id == (.job_id + ":claim-"
      + (.claim_generation | tostring) + ":terminal-1")
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
    claim_generation,
    claim_token,
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

# Task4 owns scheduler migration and pending-transaction recovery. Use only
# its migration-only entry point: first before reading state, then again only
# after releasing our lock if the locked read observes a newer transaction.
run_scheduler_migration

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null

RECEIPT_FILE="${CALLBACK_INBOX}/${HANDOFF_EVENT_ID}.json"

MIGRATION_RECOVERY_COUNT=0
while :; do
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

  if ! jq -e 'has("pending_transaction")' \
      <<<"${SCHEDULER_STATE}" >/dev/null; then
    break
  fi

  # Migration owns pending-transaction recovery and needs this same lock.
  # Never install a fence into the stale outer state and never call migration
  # while holding scheduler.lock.
  flock -u "${IMPORT_SCHEDULER_LOCK_FD}"
  exec {IMPORT_SCHEDULER_LOCK_FD}>&-
  if [ "${MIGRATION_RECOVERY_COUNT}" -ge "${MIGRATION_RECOVERY_LIMIT}" ]; then
    import_die "scheduler transaction recovery retry limit exhausted" 3
  fi
  MIGRATION_RECOVERY_COUNT=$((MIGRATION_RECOVERY_COUNT + 1))
  run_scheduler_migration
done

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
      and (.claim_generation | type == "number"
        and . == floor and . >= 0)
      and (.scheduler_status == "reserved"
        or .scheduler_status == "preparing"
        or .scheduler_status == "running")
      and ((.claim_token == null)
        or (.claim_token | type == "string" and length > 0))
      and (.legacy_running | type == "boolean")
      and (.terminal_recorded | type == "boolean")
      and (.memberships | type == "array" and length > 0)
      and (.memberships | all(
        (.batch_id | type == "string")
        and (.snapshot_index | type == "number" and . == floor and . >= 0)
        and (.target | type == "string"
          and test("^agent:req_dispatcher:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
        and (
          (((.callback_auth_mode //
              (if has("executor_agent") or has("callback_nonce")
               then "nonce_v1" else "legacy_pre_upgrade" end)) == "nonce_v1")
            and (.executor_agent | type == "string"
              and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
            and (.callback_nonce | type == "string" and test("^[0-9a-f]{64}$")))
          or
          (((.callback_auth_mode // "legacy_pre_upgrade") == "legacy_pre_upgrade")
            and (has("executor_agent") | not)
            and (has("callback_nonce") | not)))
        and (.event_id | type == "string" and length > 0)
        and (.body | type == "object")))
      and (.created_at | type == "number" and . == floor and . >= 0)
    then .memberships |= map(
      if has("callback_auth_mode") then .
      elif has("executor_agent") or has("callback_nonce")
      then . + {callback_auth_mode:"nonce_v1"}
      else . + {callback_auth_mode:"legacy_pre_upgrade"}
      end)
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
    and .claim_generation == $handoff.claim_generation
    and .claim_token == $handoff.claim_token
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
    --argjson iid "$(jq -r '.iid' <<<"${HANDOFF_JSON}")" \
    --argjson expected_claim_generation "$(jq -r '.claim_generation' <<<"${HANDOFF_JSON}")" \
    --argjson expected_claim_token "$(jq -c '.claim_token' <<<"${HANDOFF_JSON}")" '
    if type == "object"
      and .job_id == $job_id
      and .project == $project
      and .iid == $iid
      and (.status == "reserved" or .status == "preparing" or .status == "running")
      and (.updated_at | type == "number" and . == floor and . >= 0)
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
      and .claim_generation == $expected_claim_generation
      and .claim_token == $expected_claim_token
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

  EXISTING_FINALIZATION="$(jq -c '.finalization // null' <<<"${ACTIVE_JOB}")"
  if [ "$(jq -r '.status' <<<"${ACTIVE_JOB}")" = preparing ] \
      && [ "${EXISTING_FINALIZATION}" = null ]; then
    claim_expired="$(jq -nr \
      --argjson now "${IMPORTED_AT}" \
      --argjson updated_at "$(jq -r '.updated_at' <<<"${ACTIVE_JOB}")" \
      --arg lease_seconds "${PREPARING_LEASE_SECONDS}" '
      ($lease_seconds | tonumber) as $lease
      | (($now - $updated_at) >= $lease)
    ')"
    if [ "${claim_expired}" = true ]; then
      import_die "preparing claim lease expired: ${JOB_ID}" 3
    fi
  fi

  MEMBERSHIPS_JSON='[]'
  while IFS=$'\t' read -r batch_id snapshot_index; do
    [ -n "${batch_id}" ] || continue
    request_file="${BATCHES_ROOT}/${batch_id}/request.json"
    [ -f "${request_file}" ] \
      || import_die "membership batch request is missing: ${batch_id}" 3
    request_json="$(jq -ce \
      --arg batch_id "${batch_id}" \
      --arg pinned_target "${DISPATCHER_CALLBACK_TARGET}" \
      --arg pinned_executor "${EXECUTOR_AGENT}" '
      if type == "object"
        and .version == 1
        and .batch_id == $batch_id
        and (has("callback_auth_mode") | not)
        and (
          (.dispatcher_callback_target == $pinned_target
            and .executor_agent == $pinned_executor
            and (.callback_nonce | type == "string" and test("^[0-9a-f]{64}$")))
          or
          ((has("executor_agent") | not)
            and (has("callback_nonce") | not)
            and (.dispatcher_callback_target | type == "string"
              and test("^agent:req_dispatcher:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))))
      then . + {callback_auth_mode:
        (if has("executor_agent") then "nonce_v1" else "legacy_pre_upgrade" end)}
      else error("invalid callback target")
      end
    ' "${request_file}")" \
      || import_die "membership batch request is invalid: ${batch_id}" 3
    callback_target="$(jq -r '.dispatcher_callback_target' <<<"${request_json}")"
    callback_auth_mode="$(jq -r '.callback_auth_mode' <<<"${request_json}")"
    executor_agent="$(jq -r '.executor_agent // empty' <<<"${request_json}")"
    callback_nonce="$(jq -r '.callback_nonce // empty' <<<"${request_json}")"
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
      --arg callback_auth_mode "${callback_auth_mode}" \
      --arg executor_agent "${executor_agent}" \
      --arg callback_nonce "${callback_nonce}" \
      --arg event_id "${membership_event_id}" \
      --argjson body "${public_body}" '
      . + [{
        batch_id:$batch_id,
        snapshot_index:$snapshot_index,
        target:$target,
        callback_auth_mode:$callback_auth_mode,
        event_id:$event_id,
        body:$body
      } + (if $callback_auth_mode == "nonce_v1"
        then {executor_agent:$executor_agent,callback_nonce:$callback_nonce}
        else {} end)]
    ' <<<"${MEMBERSHIPS_JSON}")"
  done < <(jq -r '.memberships[] | [.batch_id, (.snapshot_index | tostring)] | @tsv' \
    <<<"${ACTIVE_JOB}")

  MEMBERSHIP_KEYS="$(jq -c '
    [.memberships[]
      | (.batch_id + ":snapshot-" + (.snapshot_index | tostring))]
    | sort
  ' <<<"${ACTIVE_JOB}")"
  FINALIZATION_JSON="$(jq -cnS \
    --arg event_id "$(jq -r '.event_id' <<<"${HANDOFF_JSON}")" \
    --argjson claim_generation "$(jq -r '.claim_generation' <<<"${HANDOFF_JSON}")" \
    --argjson claim_token "$(jq -c '.claim_token' <<<"${HANDOFF_JSON}")" \
    --argjson membership_keys "${MEMBERSHIP_KEYS}" '{
      event_id:$event_id,
      claim_generation:$claim_generation,
      claim_token:$claim_token,
      membership_keys:$membership_keys
    }')"
  if [ "${EXISTING_FINALIZATION}" = null ]; then
    SCHEDULER_STATE="$(jq -c \
      --arg job_id "${JOB_ID}" \
      --argjson finalization "${FINALIZATION_JSON}" '
      .active_jobs[$job_id].finalization = $finalization
    ' <<<"${SCHEDULER_STATE}")"
    atomic_write_json "${SCHEDULER_STATE_FILE}" "${SCHEDULER_STATE}"
    ACTIVE_JOB="$(jq -c --arg job_id "${JOB_ID}" \
      '.active_jobs[$job_id]' <<<"${SCHEDULER_STATE}")"
  elif [ "$(jq -cS . <<<"${EXISTING_FINALIZATION}")" \
      != "$(jq -cS . <<<"${FINALIZATION_JSON}")" ]; then
    import_die "active scheduler job carries a conflicting finalization fence: ${JOB_ID}" 3
  fi

  CREATED_AT="${IMPORTED_AT}"
  TERMINAL_RECORDED=false
  if [ "${EXISTING_RECEIPT}" != null ]; then
    CREATED_AT="$(jq -r '.created_at' <<<"${EXISTING_RECEIPT}")"
    TERMINAL_RECORDED="$(jq -r '.terminal_recorded' <<<"${EXISTING_RECEIPT}")"
  fi
  RECEIPT_JSON="$(jq -cnS \
    --argjson handoff "${HANDOFF_JSON}" \
    --arg scheduler_status "$(jq -r '.status' <<<"${ACTIVE_JOB}")" \
    --argjson legacy_running "$(jq -r '.legacy_running // false' <<<"${ACTIVE_JOB}")" \
    --argjson memberships "${MEMBERSHIPS_JSON}" \
    --argjson terminal_recorded "${TERMINAL_RECORDED}" \
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
      claim_generation:$handoff.claim_generation,
      scheduler_status:$scheduler_status,
      claim_token:$handoff.claim_token,
      legacy_running:$legacy_running,
      terminal_recorded:$terminal_recorded,
      memberships:$memberships,
      created_at:$created_at
    }')"
  TERMINAL_RECORD_NEEDED=true
else
  RECEIPT_JSON="${EXISTING_RECEIPT}"
fi

# The scheduler-locked finalization fence above freezes the exact memberships
# and claim identity. Event locks are independent durability locks and can be
# occupied by a rolling old drainer across its network timeout, so never wait
# for one while holding the global scheduler lock. A crash from this point is
# replayable from the active job plus finalization fence (or existing receipt).
flock -u "${IMPORT_SCHEDULER_LOCK_FD}"
exec {IMPORT_SCHEDULER_LOCK_FD}>&-

# Fail closed before changing the receipt if an existing event carries a
# different public body or a different fixed delivery target.
while IFS= read -r membership; do
  event_id="$(jq -r '.event_id' <<<"${membership}")"
  target="$(jq -r '.target' <<<"${membership}")"
  callback_auth_mode="$(jq -r '.callback_auth_mode' <<<"${membership}")"
  executor_agent="$(jq -r '.executor_agent // empty' <<<"${membership}")"
  callback_nonce="$(jq -r '.callback_nonce // empty' <<<"${membership}")"
  body="$(jq -c '.body' <<<"${membership}")"
  acquire_callback_event_locks "${event_id}"
  outbox_file="$(locate_outbox_file "${event_id}")"
  if [ -f "${outbox_file}" ]; then
    existing_outbox="$(jq -ce \
      --arg event_id "${event_id}" \
      --arg target "${target}" \
      --arg callback_auth_mode "${callback_auth_mode}" \
      --arg executor_agent "${executor_agent}" \
      --arg callback_nonce "${callback_nonce}" \
      --argjson body "${body}" '
      if type == "object"
      and .version == 1
      and .event_id == $event_id
      and .target == $target
      and ((.callback_auth_mode //
        (if has("executor_agent") or has("callback_nonce")
         then "nonce_v1" else "legacy_pre_upgrade" end)) == $callback_auth_mode)
      and (if $callback_auth_mode == "nonce_v1"
        then .executor_agent == $executor_agent and .callback_nonce == $callback_nonce
        else (has("executor_agent") | not) and (has("callback_nonce") | not)
        end)
      and .body == $body
      and (.attempts | type == "number" and . == floor and . >= 0)
      and ((.last_error == null) or (.last_error | type == "string"))
      and ((.delivered_at == null)
        or (.delivered_at | type == "number" and . == floor and . >= 0))
      and ((.ready_at == null)
        or (.ready_at | type == "number" and . == floor and . >= 0))
      then . + {callback_auth_mode:$callback_auth_mode}
      else error("conflicting outbox") end
    ' "${outbox_file}")" \
      || import_die "outbox event conflicts with persisted body: ${event_id}" 3
    atomic_write_json "${outbox_file}" "${existing_outbox}"
  fi
  release_callback_event_locks
done < <(jq -c '.memberships[]' <<<"${RECEIPT_JSON}")

# Receipt is intentionally durable before any outbox creation. It contains all
# parsed memberships and targets, so a crash can replay missing entries without
# an active scheduler job.
atomic_write_json "${RECEIPT_FILE}" "${RECEIPT_JSON}"

while IFS= read -r membership; do
  event_id="$(jq -r '.event_id' <<<"${membership}")"
  target="$(jq -r '.target' <<<"${membership}")"
  callback_auth_mode="$(jq -r '.callback_auth_mode' <<<"${membership}")"
  executor_agent="$(jq -r '.executor_agent // empty' <<<"${membership}")"
  callback_nonce="$(jq -r '.callback_nonce // empty' <<<"${membership}")"
  body="$(jq -c '.body' <<<"${membership}")"
  acquire_callback_event_locks "${event_id}"
  outbox_file="$(locate_outbox_file "${event_id}")"
  if [ -f "${outbox_file}" ]; then
    release_callback_event_locks
    continue
  fi
  outbox_json="$(jq -cnS \
    --arg event_id "${event_id}" \
    --arg target "${target}" \
    --arg callback_auth_mode "${callback_auth_mode}" \
    --arg executor_agent "${executor_agent}" \
    --arg callback_nonce "${callback_nonce}" \
    --argjson body "${body}" \
    --argjson created_at "${IMPORTED_AT}" '{
      version:1,
      event_id:$event_id,
      target:$target,
      callback_auth_mode:$callback_auth_mode,
      body:$body,
      attempts:0,
      last_error:null,
      delivered_at:null,
      ready_at:null,
      next_attempt_at:null,
      created_at:$created_at,
      updated_at:$created_at
    }
    + (if $callback_auth_mode == "nonce_v1"
      then {executor_agent:$executor_agent,callback_nonce:$callback_nonce}
      else {} end)')"
  atomic_write_json "${outbox_file}" "${outbox_json}"
  release_callback_event_locks
done < <(jq -c '.memberships[]' <<<"${RECEIPT_JSON}")

RECONCILE_SCOPE="$(jq -c '[.memberships[].batch_id] | unique | sort' <<<"${RECEIPT_JSON}")"
RECONCILE_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON="${RECONCILE_SCOPE}" \
  bash "${RECONCILE_COUNTS_SCRIPT}"
)" || import_die "terminal outcome counter reconciliation failed" 3
jq -e '
  type == "object"
  and .status == "reconciled"
  and (.scanned | type == "number" and . == floor and . >= 1)
  and (.repaired | type == "number" and . == floor and . >= 0)
  and .unresolved == 0
' <<<"${RECONCILE_OUTPUT}" >/dev/null \
  || import_die "terminal outcome counter reconciliation is incomplete" 3

OUTBOX_COUNT="$(jq -r '.memberships | length' <<<"${RECEIPT_JSON}")"
CLAIM_TOKEN="$(jq -r '.claim_token // empty' <<<"${RECEIPT_JSON}")"
LEGACY_RUNNING="$(jq -r '.legacy_running' <<<"${RECEIPT_JSON}")"

if [ "${TERMINAL_RECORD_NEEDED}" = true ]; then
  set +e
  if [ -n "${CLAIM_TOKEN}" ]; then
    RECORD_OUTPUT="$(
      CONFIG_DIR="${CONFIG_DIR}" \
      JOB_ID="${JOB_ID}" \
      STATUS=terminal \
      TERMINAL_STATUS="$(jq -r '.status' <<<"${RECEIPT_JSON}")" \
      CLAIM_TOKEN="${CLAIM_TOKEN}" \
      FINALIZATION_EVENT_ID="${HANDOFF_EVENT_ID}" \
      bash "${RECORD_SCRIPT}"
    )"
    RECORD_RC=$?
  else
    RECORD_OUTPUT="$(
      env -u CLAIM_TOKEN \
      CONFIG_DIR="${CONFIG_DIR}" \
      JOB_ID="${JOB_ID}" \
      STATUS=terminal \
      TERMINAL_STATUS="$(jq -r '.status' <<<"${RECEIPT_JSON}")" \
      FINALIZATION_EVENT_ID="${HANDOFF_EVENT_ID}" \
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

# Only a completed terminal transition opens delivery. This also repairs the
# crash window where record removed active_jobs but the process stopped before
# receipt/outbox readiness was published.
release_delivery_gate

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
