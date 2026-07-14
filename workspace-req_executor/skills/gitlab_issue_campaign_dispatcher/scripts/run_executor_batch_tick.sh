#!/usr/bin/env bash
# Recovery-first fixed executor batch tick. Shell owns deterministic scans,
# imports, outbox delivery, reservation, project topup, claim fencing and bind.
# It deliberately stops before sessions_spawn and returns only safe spawn grants.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"

SCHEDULER_ENV_CMD="${SCHEDULER_ENV_CMD:-${SCRIPT_DIR}/scheduler_env.sh}"
RESOLVE_REPO_CMD="${RESOLVE_REPO_CMD:-${SCRIPT_DIR}/resolve_driven_repo_path.sh}"
DRAIN_HANDOFF_CMD="${DRAIN_HANDOFF_CMD:-${SCRIPT_DIR}/drain_driven_handoff_intents.sh}"
DRAIN_OUTBOX_CMD="${DRAIN_OUTBOX_CMD:-${SCRIPT_DIR}/drain_driven_outbox.sh}"
RECONCILE_COUNTS_CMD="${RECONCILE_COUNTS_CMD:-${SCRIPT_DIR}/reconcile_driven_terminal_counts.sh}"
REAP_PLACEHOLDERS_CMD="${REAP_PLACEHOLDERS_CMD:-${SCRIPT_DIR}/reap_driven_orphan_placeholders.sh}"
RESERVE_CMD="${RESERVE_CMD:-${SCRIPT_DIR}/reserve_driven_batch_items.sh}"
TOPUP_CMD="${TOPUP_CMD:-${SCRIPT_DIR}/dispatch_driven_topup.sh}"
IMPORT_SKIP_CMD="${IMPORT_SKIP_CMD:-${SCRIPT_DIR}/import_driven_skipped.sh}"
RECORD_LAUNCH_CMD="${RECORD_LAUNCH_CMD:-${SCRIPT_DIR}/record_driven_batch_launch.sh}"
BIND_CLAIM_CMD="${BIND_CLAIM_CMD:-${SCRIPT_DIR}/bind_driven_claim.sh}"
RESUME_SPAWN_CMD="${RESUME_SPAWN_CMD:-${SCRIPT_DIR}/record_executor_batch_spawn.sh}"
EXPIRE_RUNNING_CMD="${EXPIRE_RUNNING_CMD:-${SCRIPT_DIR}/dispatch_followup.sh}"
DEFER_DRIVEN_CALLBACK_DELIVERY="${DEFER_DRIVEN_CALLBACK_DELIVERY:-0}"

tick_die() {
  echo "run_executor_batch_tick.sh: $*" >&2
  exit 2
}

validate_command() {
  local name="$1" path="$2"
  case "${path}" in
    /*) ;;
    *) tick_die "${name} must be absolute" ;;
  esac
  case "${path}" in
    *$'\n'*|*$'\r'*|*$'\t'*) tick_die "${name} contains control characters" ;;
  esac
  [ -f "${path}" ] && [ -x "${path}" ] \
    || tick_die "${name} must be an executable regular file"
}

validate_bash_script() {
  local name="$1" path="$2"
  case "${path}" in
    /*) ;;
    *) tick_die "${name} must be absolute" ;;
  esac
  case "${path}" in
    *$'\n'*|*$'\r'*|*$'\t'*) tick_die "${name} contains control characters" ;;
  esac
  [ -f "${path}" ] && [ -r "${path}" ] \
    || tick_die "${name} must be a readable regular file"
}

for command_spec in \
  "SCHEDULER_ENV_CMD:${SCHEDULER_ENV_CMD}" \
  "RESOLVE_REPO_CMD:${RESOLVE_REPO_CMD}" \
  "DRAIN_HANDOFF_CMD:${DRAIN_HANDOFF_CMD}" \
  "DRAIN_OUTBOX_CMD:${DRAIN_OUTBOX_CMD}" \
  "RECONCILE_COUNTS_CMD:${RECONCILE_COUNTS_CMD}" \
  "REAP_PLACEHOLDERS_CMD:${REAP_PLACEHOLDERS_CMD}" \
  "RESERVE_CMD:${RESERVE_CMD}" \
  "TOPUP_CMD:${TOPUP_CMD}" \
  "IMPORT_SKIP_CMD:${IMPORT_SKIP_CMD}" \
  "RECORD_LAUNCH_CMD:${RECORD_LAUNCH_CMD}" \
  "BIND_CLAIM_CMD:${BIND_CLAIM_CMD}" \
  "RESUME_SPAWN_CMD:${RESUME_SPAWN_CMD}"
do
  validate_command "${command_spec%%:*}" "${command_spec#*:}"
done
validate_bash_script EXPIRE_RUNNING_CMD "${EXPIRE_RUNNING_CMD}"
case "${DEFER_DRIVEN_CALLBACK_DELIVERY}" in
  0|1) ;;
  *) tick_die "DEFER_DRIVEN_CALLBACK_DELIVERY must be 0 or 1" ;;
esac

# Preserve process overrides before sourcing deployment pins.
REPO_PARENT_PROCESS_OVERRIDE="${REPO_PARENT_PATH:-}"
SCHEDULER_ROOT_PROCESS_SET="${EXECUTOR_SCHEDULER_ROOT+x}"
SCHEDULER_ROOT_PROCESS_OVERRIDE="${EXECUTOR_SCHEDULER_ROOT:-}"
MAX_CONCURRENCY_PROCESS_SET="${EXECUTOR_MAX_CONCURRENCY+x}"
MAX_CONCURRENCY_PROCESS_OVERRIDE="${EXECUTOR_MAX_CONCURRENCY:-}"
RUNNING_LEASE_PROCESS_SET="${EXECUTOR_RUNNING_LEASE_SECONDS+x}"
RUNNING_LEASE_PROCESS_OVERRIDE="${EXECUTOR_RUNNING_LEASE_SECONDS:-}"
EXECUTOR_AGENT_PROCESS_SET="${EXECUTOR_AGENT+x}"
EXECUTOR_AGENT_PROCESS_OVERRIDE="${EXECUTOR_AGENT:-}"
CALLBACK_TARGET_PROCESS_SET="${DISPATCHER_CALLBACK_TARGET+x}"
CALLBACK_TARGET_PROCESS_OVERRIDE="${DISPATCHER_CALLBACK_TARGET:-}"
LOCK_COMPAT_PROCESS_SET="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS+x}"
LOCK_COMPAT_PROCESS_OVERRIDE="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS:-}"
[ -f "${CONFIG_DIR}/gitlab.env" ] \
  || tick_die "missing config/gitlab.env"
[ -f "${CONFIG_DIR}/campaign_defaults.env" ] \
  || tick_die "missing config/campaign_defaults.env"
# Resolve host/protocol/token as one layer before campaign defaults can
# overwrite individual GitLab variables. This is network-free but enforces the
# same local-test blue-zone deny fence as glab_auth.sh.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/gitlab_env_resolver.sh"
GITLAB_HOST_RESOLVED="${GITLAB_HOST}"
GITLAB_PROTOCOL_RESOLVED="${GITLAB_API_PROTOCOL}"
GITLAB_TOKEN_RESOLVED="${GITLAB_TOKEN}"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/gitlab.env"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/campaign_defaults.env"
if [ -f "${CONFIG_DIR}/campaign_defaults.local.env" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_DIR}/campaign_defaults.local.env"
fi
: "${EXECUTOR_RUNNING_LEASE_SECONDS:=21600}"
if [ "${SCHEDULER_ROOT_PROCESS_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT_PROCESS_OVERRIDE}"
fi
if [ "${MAX_CONCURRENCY_PROCESS_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${MAX_CONCURRENCY_PROCESS_OVERRIDE}"
fi
if [ "${RUNNING_LEASE_PROCESS_SET}" = x ]; then
  EXECUTOR_RUNNING_LEASE_SECONDS="${RUNNING_LEASE_PROCESS_OVERRIDE}"
fi
if [ "${EXECUTOR_AGENT_PROCESS_SET}" = x ]; then
  EXECUTOR_AGENT="${EXECUTOR_AGENT_PROCESS_OVERRIDE}"
fi
if [ "${CALLBACK_TARGET_PROCESS_SET}" = x ]; then
  DISPATCHER_CALLBACK_TARGET="${CALLBACK_TARGET_PROCESS_OVERRIDE}"
fi
if [ "${LOCK_COMPAT_PROCESS_SET}" = x ]; then
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS="${LOCK_COMPAT_PROCESS_OVERRIDE}"
fi
GITLAB_HOST="${GITLAB_HOST_RESOLVED}"
GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_RESOLVED}"
GITLAB_TOKEN_EFF="${GITLAB_TOKEN_RESOLVED}"
REPO_PARENT_BASE="${REPO_PARENT_PROCESS_OVERRIDE:-${REPO_PARENT_PATH:-/data}}"
export REPO_PARENT_PATH="${REPO_PARENT_BASE}"
[ -n "${GITLAB_TOKEN_EFF}" ] || tick_die "executor GitLab credential is unavailable"
case "${GITLAB_TOKEN_EFF}" in
  *[[:cntrl:]]*) tick_die "executor GitLab credential contains control characters" ;;
esac
: "${GITLAB_HOST:?run_executor_batch_tick.sh: GITLAB_HOST missing}"
: "${GITLAB_API_PROTOCOL:?run_executor_batch_tick.sh: GITLAB_API_PROTOCOL missing}"

# scheduler_env exports all paths and validates the deployment concurrency pin.
# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null
# scheduler_env sources the same deployment files for scheduler validation;
# restore the already-resolved process/config repo parent afterwards so every
# child wrapper observes the same effective clone root.
export REPO_PARENT_PATH="${REPO_PARENT_BASE}"
export GITLAB_HOST="${GITLAB_HOST_RESOLVED}"
export GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_RESOLVED}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_driven_launch_coordinator.sh"

OPERATIONS='[]'
SPAWN_GRANTS='[]'
RECONCILE_ACTIONS='[]'
HAD_FAILURE=false

append_operation() {
  local operation_json="$1"
  OPERATIONS="$(jq -ce --argjson operation "${operation_json}" \
    '. + [$operation]' <<<"${OPERATIONS}")"
}

set +e
RECONCILE_COUNTS_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RECONCILE_COUNTS_CMD}" 2>/dev/null)"
RECONCILE_COUNTS_RC=$?
set -e
if [ "${RECONCILE_COUNTS_RC}" -eq 0 ] \
    && RECONCILE_COUNTS_JSON="$(printf '%s' "${RECONCILE_COUNTS_OUTPUT}" | jq -ce '
      if type == "object"
        and (.status == "reconciled" or .status == "partial")
        and ([.scanned,.repaired,.unresolved]
          | all(type == "number" and . == floor and . >= 0))
        and ((.status == "reconciled" and .unresolved == 0)
          or (.status == "partial" and .unresolved > 0))
      then . else error("invalid terminal count reconciliation envelope") end
    ' 2>/dev/null)"; then
  if [ "$(jq -r '.repaired + .unresolved' <<<"${RECONCILE_COUNTS_JSON}")" -gt 0 ]; then
    append_operation "$(jq -cn --argjson result "${RECONCILE_COUNTS_JSON}" '{
      operation:"terminal_count_reconcile",
      status:$result.status,
      scanned:$result.scanned,
      repaired:$result.repaired,
      unresolved:$result.unresolved
    }')"
  fi
  if [ "$(jq -r '.unresolved' <<<"${RECONCILE_COUNTS_JSON}")" -gt 0 ]; then
    HAD_FAILURE=true
  fi
else
  append_operation "$(jq -cn '{operation:"terminal_count_reconcile",status:"failed"}')"
  HAD_FAILURE=true
fi

# Terminal-count migration is a scheduler safety boundary. Never reserve or
# expose a spawn grant when its recovery/reconciliation is incomplete.
if [ "${HAD_FAILURE}" = true ]; then
  jq -cn \
    --argjson operation_results "${OPERATIONS}" '{
      status:"tick_failed",
      spawn_grants:[],
      reconcile_actions:[],
      operation_results:$operation_results,
      max_launch_retries:3,
      backoff_seconds:2,
      chat_summary:"executor batch tick stopped before reservation because terminal count reconciliation failed"
    }'
  exit 0
fi

project_context() {
  local project="$1" group slug resolved repo_parent
  if ! [[ "${project}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
    return 2
  fi
  group="${project%/*}"
  slug="${project##*/}"
  resolved="$(PROJECT_FULL="${project}" \
    REPO_PARENT_PATH="${REPO_PARENT_BASE}" \
    GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
    GITLAB_HOST="${GITLAB_HOST}" \
    bash "${RESOLVE_REPO_CMD}")" || return 2
  repo_parent="${resolved%/*}"
  jq -cn \
    --arg project "${project}" \
    --arg group "${group}" \
    --arg slug "${slug}" \
    --arg repo_path "${resolved}" \
    --arg repo_parent "${repo_parent}" '{
      project:$project,
      group:$group,
      slug:$slug,
      repo_path:$repo_path,
      repo_parent:$repo_parent
    }'
}

# Snapshot the scheduler state only long enough to discover active projects.
# Every project/network operation below occurs after this lock is released.
exec {SNAPSHOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SNAPSHOT_LOCK_FD}"
SCHEDULER_SNAPSHOT="$(jq -ce '
  if type == "object"
    and .version == 1
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
  then . else error("invalid scheduler state") end
' "${SCHEDULER_STATE_FILE}")" || tick_die "scheduler state is invalid"
flock -u "${SNAPSHOT_LOCK_FD}"
exec {SNAPSHOT_LOCK_FD}>&-

PROJECTS_JSON="$(jq -c '[.active_jobs[].project] | unique' \
  <<<"${SCHEDULER_SNAPSHOT}")"

# A runtime callback can be lost permanently across gateway/process failures.
# Reconcile only positive-generation jobs whose durable running lease expired,
# and pass the project wrapper a SHA-256 claim fence rather than the private
# token. The wrapper re-checks the current project pending entry and its own
# ACPX deadline before synthesizing a timeout through the ordinary handoff/I3
# path, so an old observation cannot terminate a newer generation.
TICK_NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"
EXPIRED_RUNNING_JOBS="$(jq -c \
  --argjson now "${TICK_NOW_EPOCH}" \
  --argjson lease "${EXECUTOR_RUNNING_LEASE_SECONDS}" '
  [.active_jobs[]
    | select(.status == "running"
      and (.finalization // null) == null
      and (.updated_at | type == "number" and . == floor and . >= 0)
      and (.claim_generation | type == "number" and . == floor and . > 0)
      and (.claim_token | type == "string" and length > 0)
      and (($now - .updated_at) >= $lease))]
  | sort_by(.reservation_seq // 0, .job_id)
' <<<"${SCHEDULER_SNAPSHOT}")"
while IFS= read -r expired_job; do
  [ -n "${expired_job}" ] || continue
  expired_job_id="$(jq -r '.job_id' <<<"${expired_job}")"
  expired_project="$(jq -r '.project' <<<"${expired_job}")"
  expired_iid="$(jq -r '.iid' <<<"${expired_job}")"
  expired_generation="$(jq -r '.claim_generation' <<<"${expired_job}")"
  expired_token_sha256="$(printf '%s' "$(jq -r '.claim_token' <<<"${expired_job}")" | dlc_sha256)" \
    || tick_die "unable to hash running claim fence"
  if ! expired_context="$(project_context "${expired_project}")"; then
    append_operation "$(jq -cn --arg job_id "${expired_job_id}" '{
      operation:"running_timeout_reconcile",job_id:$job_id,status:"invalid_project"
    }')"
    HAD_FAILURE=true
    continue
  fi
  set +e
  expired_output="$(printf '' | \
    PROJECT="$(jq -r '.slug' <<<"${expired_context}")" \
    GROUP="$(jq -r '.group' <<<"${expired_context}")" \
    GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
    REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${expired_context}")" \
    IID="${expired_iid}" DRIVEN_TIMEOUT_RECONCILE=1 \
    DRIVEN_TIMEOUT_JOB_ID="${expired_job_id}" \
    DRIVEN_TIMEOUT_CLAIM_GENERATION="${expired_generation}" \
    DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${expired_token_sha256}" \
    DRIVEN_TIMEOUT_NOW_EPOCH="${TICK_NOW_EPOCH}" \
      bash "${EXPIRE_RUNNING_CMD}" 2>/dev/null)"
  expired_rc=$?
  set -e
  if [ "${expired_rc}" -eq 0 ] \
      && expired_status="$(jq -er '.callback_status | select(type == "string" and length > 0)' \
        <<<"${expired_output}" 2>/dev/null)"; then
    append_operation "$(jq -cn \
      --arg job_id "${expired_job_id}" --arg status "${expired_status}" '{
      operation:"running_timeout_reconcile",job_id:$job_id,status:$status
    }')"
  else
    append_operation "$(jq -cn --arg job_id "${expired_job_id}" '{
      operation:"running_timeout_reconcile",job_id:$job_id,status:"failed"
    }')"
    HAD_FAILURE=true
  fi
done < <(jq -c '.[]' <<<"${EXPIRED_RUNNING_JOBS}")

while IFS= read -r active_batch_id; do
  [ -n "${active_batch_id}" ] || continue
  request_file="${BATCHES_ROOT}/${active_batch_id}/request.json"
  [ -f "${request_file}" ] || tick_die "active batch request is missing"
  request_project="$(jq -er '
    if type == "object"
      and (.project | type == "string"
        and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    then .project else error("invalid batch project") end
  ' "${request_file}")" || tick_die "registered batch request is invalid"
  PROJECTS_JSON="$(jq -c --arg project "${request_project}" \
    '(. + [$project]) | unique' <<<"${PROJECTS_JSON}")"
done < <(jq -r '.batch_order[]' <<<"${SCHEDULER_SNAPSHOT}")

# Phase A: scan every related project for durable Phase 6 intents. The project
# drainer snapshots under campaign.lock and imports only after releasing it.
while IFS= read -r project; do
  [ -n "${project}" ] || continue
  if ! context="$(project_context "${project}")"; then
    append_operation "$(jq -cn --arg project "${project}" '{
      operation:"handoff_drain",project:$project,status:"invalid_project"
    }')"
    HAD_FAILURE=true
    continue
  fi
  project_repo="$(jq -r '.repo_path' <<<"${context}")"
  if [ ! -d "${project_repo}/.git" ]; then
    append_operation "$(jq -cn --arg project "${project}" '{
      operation:"handoff_drain",project:$project,status:"not_initialized"
    }')"
    continue
  fi

  set +e
  drain_output="$(PROJECT="$(jq -r '.slug' <<<"${context}")" \
    GROUP="$(jq -r '.group' <<<"${context}")" \
    GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
    REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${context}")" \
    CONFIG_DIR="${CONFIG_DIR}" \
    bash "${DRAIN_HANDOFF_CMD}" 2>/dev/null)"
  drain_rc=$?
  set -e
  if [ "${drain_rc}" -eq 0 ] && drain_json="$(printf '%s' "${drain_output}" | jq -ce '
      if type == "object"
        and (.status == "drained" or .status == "lock_held")
        and (.intent_count | type == "number" and . >= 0)
      then . else error("invalid drain envelope") end
    ' 2>/dev/null)"; then
    append_operation "$(jq -cn \
      --arg project "${project}" \
      --arg status "$(jq -r '.status' <<<"${drain_json}")" \
      --argjson intent_count "$(jq -r '.intent_count' <<<"${drain_json}")" '{
      operation:"handoff_drain",project:$project,status:$status,
      intent_count:$intent_count
    }')"
  else
    append_operation "$(jq -cn --arg project "${project}" '{
      operation:"handoff_drain",project:$project,status:"failed"
    }')"
    HAD_FAILURE=true
  fi
done < <(jq -r '.[]' <<<"${PROJECTS_JSON}")

# Phase B: deliver all ready outbox entries before computing free slots.
# Synchronous I1 intake explicitly defers this network phase because its target
# is the req_dispatcher main session that is waiting for the I1 acceptance.
if [ "${DEFER_DRIVEN_CALLBACK_DELIVERY}" = 1 ]; then
  append_operation "$(jq -cn '{
    operation:"outbox_drain",status:"deferred",
    scanned:0,attempted:0,delivered:0,failed:0
  }')"
else
  set +e
  OUTBOX_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" bash "${DRAIN_OUTBOX_CMD}" 2>/dev/null)"
  OUTBOX_RC=$?
  set -e
  if [ "${OUTBOX_RC}" -eq 0 ] && OUTBOX_JSON="$(printf '%s' "${OUTBOX_OUTPUT}" | jq -ce '
      if type == "object"
        and .status == "drained"
        and ([.scanned,.attempted,.delivered,.failed]
          | all(type == "number" and . == floor and . >= 0))
      then . else error("invalid outbox envelope") end
    ' 2>/dev/null)"; then
    append_operation "$(jq -cn --argjson outbox "${OUTBOX_JSON}" '{
      operation:"outbox_drain",status:$outbox.status,
      scanned:$outbox.scanned,attempted:$outbox.attempted,
      delivered:$outbox.delivered,failed:$outbox.failed
    }')"
  else
    append_operation "$(jq -cn '{operation:"outbox_drain",status:"failed"}')"
    HAD_FAILURE=true
  fi
fi

# Phase B2: runtime acknowledgements are already durable in launch_actions.
# Resume every post-spawn state machine before reservation so a crashed caller
# never has to resend run/session/error evidence from chat memory. Snapshot one
# action under its own lock, release it, then let the fixed recorder reacquire
# the lock and continue project-first. Only safe identity/status is surfaced.
resume_durable_launch_actions() {
  local action_file raw_job_id action action_stage resume_input
  local resume_output resume_rc resume_json resume_status
  local -a action_files=()

  shopt -s nullglob
  action_files=("${DLC_ROOT}"/*.json)
  if [ "${#action_files[@]}" -gt 0 ]; then
    IFS=$'\n' action_files=($(printf '%s\n' "${action_files[@]}" | LC_ALL=C sort))
    unset IFS
  fi
  for action_file in "${action_files[@]}"; do
    raw_job_id="$(jq -er '
      if type == "object" and (.job_id | type == "string" and length > 0)
      then .job_id else error("missing job_id") end
    ' "${action_file}")" || tick_die "durable launch action is invalid"
    dlc_open "${raw_job_id}"
    if [ "${DLC_ACTION_FILE}" != "${action_file}" ]; then
      dlc_close
      tick_die "durable launch action path does not match job identity"
    fi
    action="$(dlc_read)" || {
      dlc_close
      tick_die "durable launch action is invalid"
    }
    action_stage="$(jq -r '.stage' <<<"${action}")"
    case "${action_stage}" in
      ack_received|project_recorded|scheduler_recorded) ;;
      completed)
        dlc_archive_completed || {
          dlc_close
          tick_die "completed launch action could not be archived"
        }
        dlc_close
        continue
        ;;
      *) dlc_close; continue ;;
    esac

    if jq -e '
        .outcome == "spawned"
        and (.ack | type == "object")
        and (.ack.run_id | type == "string" and length > 0)
        and (.ack.child_session_key | type == "string" and length > 0)
      ' <<<"${action}" >/dev/null; then
      resume_input="$(jq -cn --argjson action "${action}" '{
        job_id:$action.job_id,
        claim_generation:$action.claim_generation,
        project:$action.project,
        iid:$action.iid,
        attempt_number:$action.attempt_number,
        expected_task_sha256:$action.expected_task_sha256,
        expected_task_bytes:$action.expected_task_bytes,
        status:"spawned",
        run_id:$action.ack.run_id,
        child_session_key:$action.ack.child_session_key
      }')"
    elif jq -e '
        .outcome == "launch_failed"
        and (.ack | type == "object")
        and (.ack.launch_attempts | type == "number"
          and . == floor and . > 0 and . <= 3)
        and (.ack.launch_error | type == "string" and length > 0)
      ' <<<"${action}" >/dev/null; then
      resume_input="$(jq -cn --argjson action "${action}" '{
        job_id:$action.job_id,
        claim_generation:$action.claim_generation,
        project:$action.project,
        iid:$action.iid,
        attempt_number:$action.attempt_number,
        expected_task_sha256:$action.expected_task_sha256,
        expected_task_bytes:$action.expected_task_bytes,
        status:"launch_failed",
        launch_attempts:$action.ack.launch_attempts,
        launch_error:$action.ack.launch_error
      }')"
    else
      dlc_close
      tick_die "durable post-spawn action lacks strict runtime evidence"
    fi
    dlc_close

    set +e
    resume_output="$(printf '%s' "${resume_input}" | \
      CONFIG_DIR="${CONFIG_DIR}" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="${REPO_PARENT_BASE}" \
      EXECUTOR_SCHEDULER_ROOT="${EXECUTOR_SCHEDULER_ROOT}" \
      EXECUTOR_MAX_CONCURRENCY="${EXECUTOR_MAX_CONCURRENCY}" \
      bash "${RESUME_SPAWN_CMD}" 2>/dev/null)"
    resume_rc=$?
    set -e
    if [ "${resume_rc}" -ne 0 ] || ! resume_json="$(printf '%s' "${resume_output}" | jq -ce \
        --arg job_id "${raw_job_id}" \
        --argjson generation "$(jq -r '.claim_generation' <<<"${action}")" '
        if type == "object"
          and (keys | sort) == [
            "chat_summary","claim_generation","job_id","status"
          ]
          and (.status == "spawned_recorded"
            or .status == "launch_failed_recorded"
            or .status == "project_record_pending"
            or .status == "scheduler_record_pending")
          and .job_id == $job_id
          and .claim_generation == $generation
          and (.chat_summary | type == "string")
        then . else error("invalid resume envelope") end
      ' 2>/dev/null)"; then
      append_operation "$(jq -cn --arg job_id "${raw_job_id}" '{
        operation:"launch_resume",job_id:$job_id,status:"failed"
      }')"
      HAD_FAILURE=true
      continue
    fi
    resume_status="$(jq -r '.status' <<<"${resume_json}")"
    append_operation "$(jq -cn \
      --arg job_id "${raw_job_id}" --arg status "${resume_status}" '{
      operation:"launch_resume",job_id:$job_id,status:$status
    }')"
    case "${resume_status}" in
      project_record_pending|scheduler_record_pending) HAD_FAILURE=true ;;
    esac
  done
}

resume_durable_launch_actions

# One agent-wide tick owns only the cross-state topup transaction: reserve,
# read project pending, decide whether a live-preflight skip is safe, and
# finalize that skip against the scheduler claim. Callback delivery and other
# independently fenced recovery phases above must not hold this lock because
# they can wait on network transports for minutes.
EXECUTOR_TICK_LOCK_FILE="${EXECUTOR_SCHEDULER_ROOT}/executor_batch_tick.lock"
exec {EXECUTOR_TICK_LOCK_FD}>"${EXECUTOR_TICK_LOCK_FILE}"
chmod 600 "${EXECUTOR_TICK_LOCK_FILE}" 2>/dev/null \
  || tick_die "executor tick lock must be private"
if ! flock -n -x "${EXECUTOR_TICK_LOCK_FD}"; then
  jq -cn '{
    status:"idle",
    spawn_grants:[],
    reconcile_actions:[],
    operation_results:[{operation:"tick_lock",status:"held"}],
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:"another executor batch tick owns the topup transaction"
  }'
  exit 0
fi

# Reap only project placeholders whose exact scheduler job is absent from both
# current active_jobs and every unfinished launch coordinator. This runs under
# the agent-wide tick lock, so another tick cannot create a project placeholder
# between the protected-set snapshot and the campaign-lock mutation. A
# scheduler job is always reserved before its project placeholder is created;
# exact job-id protection therefore closes the cross-state observation window.
reap_project_orphan_placeholders() {
  local project="$1" context protected_job_ids action_file action_json
  local project_repo reap_input reap_output reap_rc reap_json
  local reap_status reaped_count protected_count unresolved_count
  local -a action_files=()

  context="$(project_context "${project}")" || return 2
  project_repo="$(jq -r '.repo_path' <<<"${context}")"
  [ -d "${project_repo}/.git" ] || return 0

  exec {ORPHAN_SNAPSHOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  flock -x "${ORPHAN_SNAPSHOT_LOCK_FD}"
  protected_job_ids="$(jq -ce '
    [.active_jobs[].job_id]
    | unique | sort
  ' "${SCHEDULER_STATE_FILE}")" || {
    flock -u "${ORPHAN_SNAPSHOT_LOCK_FD}"
    exec {ORPHAN_SNAPSHOT_LOCK_FD}>&-
    return 2
  }
  flock -u "${ORPHAN_SNAPSHOT_LOCK_FD}"
  exec {ORPHAN_SNAPSHOT_LOCK_FD}>&-

  shopt -s nullglob
  action_files=("${DLC_ROOT}"/*.json)
  shopt -u nullglob
  if [ "${#action_files[@]}" -gt 0 ]; then
    IFS=$'\n' action_files=($(printf '%s\n' "${action_files[@]}" | LC_ALL=C sort))
    unset IFS
  fi
  for action_file in "${action_files[@]}"; do
    action_json="$(jq -ce '
      if type == "object"
        and (.job_id | type == "string" and length > 0)
        and (.project | type == "string" and length > 0)
        and (.stage | type == "string" and length > 0)
      then {job_id,project,stage}
      else error("invalid launch coordinator identity")
      end
    ' "${action_file}")" || return 2
    if [ "$(jq -r '.stage' <<<"${action_json}")" != completed ]; then
      protected_job_ids="$(jq -ce \
        --arg job_id "$(jq -r '.job_id' <<<"${action_json}")" \
        '(. + [$job_id]) | unique | sort' <<<"${protected_job_ids}")"
    fi
  done

  reap_input="$(jq -cn --argjson protected_job_ids "${protected_job_ids}" \
    '{protected_job_ids:$protected_job_ids}')"
  set +e
  reap_output="$(printf '%s' "${reap_input}" | \
    PROJECT="$(jq -r '.slug' <<<"${context}")" \
    GROUP="$(jq -r '.group' <<<"${context}")" \
    GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
    REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${context}")" \
      bash "${REAP_PLACEHOLDERS_CMD}" 2>/dev/null)"
  reap_rc=$?
  set -e
  if [ "${reap_rc}" -ne 0 ] || ! reap_json="$(printf '%s' "${reap_output}" | jq -ce '
      if type == "object"
        and (.status == "reaped" or .status == "lock_held")
        and (.reaped_entries | type == "array")
        and (.protected_entries | type == "array")
        and (.unresolved_iids | type == "array")
      then . else error("invalid orphan reaper envelope") end
    ' 2>/dev/null)"; then
    append_operation "$(jq -cn --arg project "${project}" '{
      operation:"orphan_placeholder_reap",project:$project,status:"failed"
    }')"
    HAD_FAILURE=true
    return 0
  fi

  reap_status="$(jq -r '.status' <<<"${reap_json}")"
  reaped_count="$(jq -r '.reaped_entries | length' <<<"${reap_json}")"
  protected_count="$(jq -r '.protected_entries | length' <<<"${reap_json}")"
  unresolved_count="$(jq -r '.unresolved_iids | length' <<<"${reap_json}")"
  if [ "${reap_status}" != reaped ] \
      || [ "${reaped_count}" -gt 0 ] \
      || [ "${unresolved_count}" -gt 0 ]; then
    append_operation "$(jq -cn \
      --arg project "${project}" \
      --arg status "${reap_status}" \
      --argjson reaped_count "${reaped_count}" \
      --argjson protected_count "${protected_count}" \
      --argjson unresolved_count "${unresolved_count}" '{
      operation:"orphan_placeholder_reap",
      project:$project,
      status:$status,
      reaped_count:$reaped_count,
      protected_count:$protected_count,
      unresolved_count:$unresolved_count
    }')"
  fi
}

while IFS= read -r orphan_project; do
  [ -n "${orphan_project}" ] || continue
  if ! reap_project_orphan_placeholders "${orphan_project}"; then
    append_operation "$(jq -cn --arg project "${orphan_project}" '{
      operation:"orphan_placeholder_reap",project:$project,status:"invalid_project"
    }')"
    HAD_FAILURE=true
  fi
done < <(jq -r '.[]' <<<"${PROJECTS_JSON}")

# A prior sessions_spawn action globally closes the launch gate until its
# acknowledgement is durable (or explicit runtime reconciliation resolves the
# ambiguity). Do this independent of the current reservation set: a preparing
# job already occupies a scheduler slot and therefore may not be returned by
# reserve_driven_batch_items.sh at all.
SERIAL_LAUNCH_GATE_CLOSED=false
declare -a SERIAL_GATE_ACTION_FILES=()
shopt -s nullglob
SERIAL_GATE_ACTION_FILES=("${DLC_ROOT}"/*.json)
shopt -u nullglob
if [ "${#SERIAL_GATE_ACTION_FILES[@]}" -gt 0 ]; then
  IFS=$'\n' SERIAL_GATE_ACTION_FILES=($(printf '%s\n' \
    "${SERIAL_GATE_ACTION_FILES[@]}" | LC_ALL=C sort))
  unset IFS
  for serial_action_file in "${SERIAL_GATE_ACTION_FILES[@]}"; do
  serial_job_id="$(jq -er '
    if type == "object" and (.job_id | type == "string" and length > 0)
    then .job_id else error("missing job_id") end
  ' "${serial_action_file}")" || tick_die "durable launch action is invalid"
  dlc_open "${serial_job_id}"
  if [ "${DLC_ACTION_FILE}" != "${serial_action_file}" ]; then
    dlc_close
    tick_die "durable launch action path does not match job identity"
  fi
  serial_action="$(dlc_read)" || {
    dlc_close
    tick_die "durable launch action is invalid"
  }
  serial_stage="$(jq -r '.stage' <<<"${serial_action}")"
  case "${serial_stage}" in
    action_emitted)
      exec {SERIAL_GATE_STATE_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
      flock -x "${SERIAL_GATE_STATE_LOCK_FD}"
      serial_scheduler_job="$(jq -c --arg job_id "${serial_job_id}" \
        '.active_jobs[$job_id] // null' "${SCHEDULER_STATE_FILE}")"
      flock -u "${SERIAL_GATE_STATE_LOCK_FD}"
      exec {SERIAL_GATE_STATE_LOCK_FD}>&-
      if jq -e \
          --argjson prior_generation "$(jq -r '.claim_generation' <<<"${serial_action}")" '
          type == "object"
          and .status == "reserved"
          and .claim_generation == $prior_generation
          and .claim_token == null
        ' <<<"${serial_scheduler_job}" >/dev/null; then
        RECONCILE_ACTIONS="$(jq -c \
          --arg job_id "${serial_job_id}" \
          --argjson claim_generation "$(jq -r '.claim_generation' <<<"${serial_action}")" \
          --arg project "$(jq -r '.project' <<<"${serial_action}")" \
          --argjson iid "$(jq -r '.iid' <<<"${serial_action}")" \
          --argjson attempt_number "$(jq -r '.attempt_number' <<<"${serial_action}")" \
          --arg child_label "$(jq -r '.child_label' <<<"${serial_action}")" \
          --arg expected_task_sha256 "$(jq -r '.expected_task_sha256' <<<"${serial_action}")" \
          --argjson expected_task_bytes "$(jq -r '.expected_task_bytes' <<<"${serial_action}")" '
          . + [{
            action:"reconcile_emitted_spawn",
            job_id:$job_id,
            claim_generation:$claim_generation,
            project:$project,
            iid:$iid,
            attempt_number:$attempt_number,
            child_label:$child_label,
            expected_task_sha256:$expected_task_sha256,
            expected_task_bytes:$expected_task_bytes
          }]
        ' <<<"${RECONCILE_ACTIONS}")"
        append_operation "$(jq -cn --arg job_id "${serial_job_id}" '{
          operation:"spawn_reconcile",job_id:$job_id,status:"required"
        }')"
      else
        append_operation "$(jq -cn --arg job_id "${serial_job_id}" '{
          operation:"spawn_ack",job_id:$job_id,status:"pending"
        }')"
      fi
      SERIAL_LAUNCH_GATE_CLOSED=true
      ;;
    ack_received|project_recorded|scheduler_recorded)
      append_operation "$(jq -cn --arg job_id "${serial_job_id}" '{
        operation:"launch_resume",job_id:$job_id,status:"pending"
      }')"
      HAD_FAILURE=true
      SERIAL_LAUNCH_GATE_CLOSED=true
      ;;
  esac
  dlc_close
    [ "${SERIAL_LAUNCH_GATE_CLOSED}" = true ] && break
  done
fi

if [ "${SERIAL_LAUNCH_GATE_CLOSED}" = true ]; then
  if [ "$(jq -r 'length' <<<"${RECONCILE_ACTIONS}")" -gt 0 ]; then
    SERIAL_GATE_STATUS=reconcile_required
    SERIAL_GATE_SUMMARY="executor batch tick requires runtime reconciliation before retry"
  elif [ "${HAD_FAILURE}" = true ]; then
    SERIAL_GATE_STATUS=tick_failed
    SERIAL_GATE_SUMMARY="executor batch tick has durable launch recording pending recovery"
  else
    SERIAL_GATE_STATUS=idle
    SERIAL_GATE_SUMMARY="executor batch tick is waiting for the prior spawn acknowledgement"
  fi
  jq -cn \
    --arg status "${SERIAL_GATE_STATUS}" \
    --argjson operations "${OPERATIONS}" \
    --argjson reconcile_actions "${RECONCILE_ACTIONS}" \
    --arg chat_summary "${SERIAL_GATE_SUMMARY}" '{
      status:$status,
      spawn_grants:[],
      reconcile_actions:$reconcile_actions,
      operation_results:$operations,
      max_launch_retries:3,
      backoff_seconds:2,
      chat_summary:$chat_summary
    }'
  exit 0
fi

# Phase C: lease recovery + strict round-robin reservation. A hard reserve
# failure is terminal for this tick because no safe grant set exists.
set +e
RESERVE_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE_CMD}" 2>/dev/null)"
RESERVE_RC=$?
set -e
if [ "${RESERVE_RC}" -ne 0 ] || ! RESERVE_JSON="$(printf '%s' "${RESERVE_OUTPUT}" | jq -ce '
    if type == "object"
      and (.status == "ready" or .status == "idle" or .status == "at_capacity")
      and (.grants | type == "array")
      and (.active_count | type == "number" and . == floor and . >= 0)
      and (.available_slots | type == "number" and . == floor and . >= 0)
    then . else error("invalid reserve envelope") end
  ' 2>/dev/null)"; then
  append_operation "$(jq -cn '{operation:"reservation",status:"failed"}')"
  jq -cn --argjson operations "${OPERATIONS}" '{
    status:"tick_failed",spawn_grants:[],reconcile_actions:[],
    operation_results:$operations,
    max_launch_retries:3,backoff_seconds:2,
    chat_summary:"executor reservation failed"
  }'
  exit 0
fi
append_operation "$(jq -cn --argjson reserve "${RESERVE_JSON}" '{
  operation:"reservation",status:$reserve.status,
  grant_count:($reserve.grants | length),active_count:$reserve.active_count,
  available_slots:$reserve.available_slots
}')"

# Running physical jobs already occupy a global slot. Re-present them to their
# project campaign so a prior blocked/retry terminal can prepare its next
# attempt without consuming a new reservation or creating another physical job.
exec {ACTIVE_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${ACTIVE_LOCK_FD}"
ACTIVE_CONTINUATIONS="$(jq -ce '
  [.active_jobs[]
    | select(.status == "running" and (.finalization // null) == null)
    | {
        job_id,
        batch_id:.owner.batch_id,
        snapshot_index:.owner.snapshot_index,
        project,
        iid,
        branch,
        entry_mode,
        force_rerun_pr
      }]
' "${SCHEDULER_STATE_FILE}")" || tick_die "active scheduler jobs are invalid"
flock -u "${ACTIVE_LOCK_FD}"
exec {ACTIVE_LOCK_FD}>&-

CANDIDATES="$(jq -cn \
  --argjson reserved "$(jq -c '.grants' <<<"${RESERVE_JSON}")" \
  --argjson continuations "${ACTIVE_CONTINUATIONS}" '
  reduce ($reserved + $continuations)[] as $grant ([];
    if any(.[]; .job_id == $grant.job_id) then . else . + [$grant] end)
')"

TOPUP_ENTRIES='[]'
SKIPPED_ENTRIES='[]'
PROJECT_PENDING_ENTRIES='[]'
topup_candidate_set() {
  local candidate_set="$1"
  local candidate_projects project project_grants context topup_request
  local topup_output topup_rc topup_json project_pending_iids

  candidate_projects="$(jq -c '[.[].project] | unique' <<<"${candidate_set}")"
  while IFS= read -r project; do
    [ -n "${project}" ] || continue
    project_grants="$(jq -c --arg project "${project}" \
      '[.[] | select(.project == $project)]' <<<"${candidate_set}")"
    context="$(project_context "${project}")" || {
      append_operation "$(jq -cn --arg project "${project}" '{
        operation:"project_topup",project:$project,status:"invalid_project"
      }')"
      HAD_FAILURE=true
      continue
    }
    topup_request="$(jq -cn --arg owner_id executor-agent-scheduler-v1 \
      --argjson grants "${project_grants}" '{owner_id:$owner_id,grants:$grants}')"

    set +e
    topup_output="$(printf '%s' "${topup_request}" | \
      CONFIG_DIR="${CONFIG_DIR}" GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="${REPO_PARENT_BASE}" \
      EXECUTOR_SCHEDULER_ROOT="${EXECUTOR_SCHEDULER_ROOT}" \
      EXECUTOR_MAX_CONCURRENCY="${EXECUTOR_MAX_CONCURRENCY}" \
      EXECUTOR_RUNNING_LEASE_SECONDS="${EXECUTOR_RUNNING_LEASE_SECONDS}" \
      bash "${TOPUP_CMD}" 2>/dev/null)"
    topup_rc=$?
    set -e
    if [ "${topup_rc}" -ne 0 ] || ! topup_json="$(printf '%s' "${topup_output}" | jq -ce '
        if type == "object"
          and (.status | type == "string")
          and (.dispatch_entries | type == "array")
          and (all(.dispatch_entries[];
            (.payload_path | type == "string" and startswith("/"))
            and (.expected_task_sha256 | type == "string"
              and test("^[0-9a-f]{64}$"))
            and (.expected_task_bytes | type == "number"
              and . == floor and . > 0)))
          and ((.skipped_entries // []) | type == "array")
          and (if ((.skipped_entries // []) | length) > 0 then
            (.pending_iids | type == "array")
            and (all(.pending_iids[];
              type == "number" and . == floor and . > 0))
            and ((.pending_iids | length) == (.pending_iids | unique | length))
          else true end)
        then . else error("invalid topup envelope") end
      ' 2>/dev/null)"; then
      append_operation "$(jq -cn --arg project "${project}" '{
        operation:"project_topup",project:$project,status:"failed"
      }')"
      HAD_FAILURE=true
      continue
    fi

    append_operation "$(jq -cn \
      --arg project "${project}" \
      --arg status "$(jq -r '.status' <<<"${topup_json}")" \
      --argjson dispatch_count "$(jq -r '.dispatch_entries | length' <<<"${topup_json}")" \
      --argjson skipped_count "$(jq -r '(.skipped_entries // []) | length' <<<"${topup_json}")" '{
      operation:"project_topup",project:$project,status:$status,
      dispatch_count:$dispatch_count,skipped_count:$skipped_count
    }')"
    TOPUP_ENTRIES="$(jq -cn \
      --argjson current "${TOPUP_ENTRIES}" \
      --argjson additions "$(jq -c '.dispatch_entries' <<<"${topup_json}")" \
      '$current + $additions')"
    SKIPPED_ENTRIES="$(jq -cn \
      --argjson current "${SKIPPED_ENTRIES}" \
      --argjson additions "$(jq -c '.skipped_entries // []' <<<"${topup_json}")" \
      '$current + $additions')"
    if [ "$(jq -r '(.skipped_entries // []) | length' <<<"${topup_json}")" -gt 0 ]; then
      project_pending_iids="$(jq -c '.pending_iids' <<<"${topup_json}")"
      PROJECT_PENDING_ENTRIES="$(jq -cn \
        --argjson current "${PROJECT_PENDING_ENTRIES}" \
        --arg project "${project}" \
        --argjson pending_iids "${project_pending_iids}" '
        [$current[] | select(.project != $project)]
        + [$pending_iids[] | {project:$project,iid:.}]
        | sort_by(.project,.iid)')"
    fi
  done < <(jq -r '.[]' <<<"${candidate_projects}")
}

seed_topup_actions() {
  local candidate_set="$1"
  local grant job_id project iid entries entry_count entry action now
  while IFS= read -r grant; do
    [ -n "${grant}" ] || continue
    job_id="$(jq -r '.job_id' <<<"${grant}")"
    project="$(jq -r '.project' <<<"${grant}")"
    iid="$(jq -r '.iid' <<<"${grant}")"
    entries="$(jq -c --arg job_id "${job_id}" \
      '[.[] | select(.job_id == $job_id)]' <<<"${TOPUP_ENTRIES}")"
    entry_count="$(jq -r 'length' <<<"${entries}")"
    [ "${entry_count}" -eq 0 ] && continue
    if [ "${entry_count}" -ne 1 ]; then
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"launch_coordinator",job_id:$job_id,status:"duplicate_entry"
      }')"
      HAD_FAILURE=true
      continue
    fi
    entry="$(jq -c '.[0]' <<<"${entries}")"
    dlc_open "${job_id}"
    action="$(dlc_read)" || {
      dlc_close
      tick_die "durable launch action is invalid"
    }
    now="$(date +%s)"
    if [ "${action}" = null ]; then
      action="$(jq -cnS \
        --arg job_id "${job_id}" \
        --arg project "${project}" \
        --argjson iid "${iid}" \
        --arg batch_id "$(jq -r '.batch_id' <<<"${grant}")" \
        --argjson snapshot_index "$(jq -r '.snapshot_index' <<<"${grant}")" \
        --argjson attempt_number "$(jq -r '.attempt_number' <<<"${entry}")" \
        --arg child_label "$(jq -r '.child_label' <<<"${entry}")" \
        --arg payload_path "$(jq -r '.payload_path' <<<"${entry}")" \
        --arg expected_task_sha256 "$(jq -r '.expected_task_sha256' <<<"${entry}")" \
        --argjson expected_task_bytes "$(jq -r '.expected_task_bytes' <<<"${entry}")" \
        --argjson now "${now}" '{
        version:1,
        job_id:$job_id,
        project:$project,
        iid:$iid,
        batch_id:$batch_id,
        snapshot_index:$snapshot_index,
        attempt_number:$attempt_number,
        child_label:$child_label,
        payload_path:$payload_path,
        expected_task_sha256:$expected_task_sha256,
        expected_task_bytes:$expected_task_bytes,
        claim_generation:0,
        claim_token:null,
        stage:"topup_prepared",
        outcome:null,
        ack:null,
        created_at:$now,
        updated_at:$now
      }')"
      dlc_write "${action}"
    else
      if ! jq -e \
          --arg job_id "${job_id}" \
          --arg project "${project}" \
          --argjson iid "${iid}" \
          --arg batch_id "$(jq -r '.batch_id' <<<"${grant}")" \
          --argjson snapshot_index "$(jq -r '.snapshot_index' <<<"${grant}")" \
          --argjson attempt_number "$(jq -r '.attempt_number' <<<"${entry}")" \
          --arg expected_task_sha256 "$(jq -r '.expected_task_sha256' <<<"${entry}")" \
          --argjson expected_task_bytes "$(jq -r '.expected_task_bytes' <<<"${entry}")" '
          .job_id == $job_id and .project == $project and .iid == $iid
          and .batch_id == $batch_id and .snapshot_index == $snapshot_index
          and .attempt_number == $attempt_number
          and .expected_task_sha256 == $expected_task_sha256
          and .expected_task_bytes == $expected_task_bytes
        ' <<<"${action}" >/dev/null; then
        if jq -e \
            --arg job_id "${job_id}" \
            --arg project "${project}" \
            --argjson iid "${iid}" \
            --arg batch_id "$(jq -r '.batch_id' <<<"${grant}")" \
            --argjson snapshot_index "$(jq -r '.snapshot_index' <<<"${grant}")" \
            --argjson attempt_number "$(jq -r '.attempt_number' <<<"${entry}")" '
            .stage == "completed"
            and .job_id == $job_id and .project == $project and .iid == $iid
            and .batch_id == $batch_id and .snapshot_index == $snapshot_index
            and .attempt_number < $attempt_number
          ' <<<"${action}" >/dev/null; then
          action="$(jq -c \
            --argjson attempt_number "$(jq -r '.attempt_number' <<<"${entry}")" \
            --arg child_label "$(jq -r '.child_label' <<<"${entry}")" \
            --arg payload_path "$(jq -r '.payload_path' <<<"${entry}")" \
            --arg expected_task_sha256 "$(jq -r '.expected_task_sha256' <<<"${entry}")" \
            --argjson expected_task_bytes "$(jq -r '.expected_task_bytes' <<<"${entry}")" \
            --argjson now "${now}" '
            .attempt_number = $attempt_number
            | .child_label = $child_label
            | .payload_path = $payload_path
            | .expected_task_sha256 = $expected_task_sha256
            | .expected_task_bytes = $expected_task_bytes
            | .claim_generation = 0
            | .claim_token = null
            | .stage = "topup_prepared"
            | .outcome = null
            | .ack = null
            | del(.runtime_label_version)
            | .updated_at = $now
          ' <<<"${action}")"
          dlc_write "${action}"
        else
          append_operation "$(jq -cn --arg job_id "${job_id}" '{
            operation:"launch_coordinator",job_id:$job_id,status:"identity_conflict"
          }')"
          HAD_FAILURE=true
        fi
      fi
    fi
    dlc_close
  done < <(jq -c '.[]' <<<"${candidate_set}")
}

topup_candidate_set "${CANDIDATES}"
seed_topup_actions "${CANDIDATES}"
if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_topup_seed ]; then
  exit 83
fi

# Re-check a running preflight completion against both current scheduler claim
# identity and GitLab live state. The project wrapper writes the claim-bound
# skipped handoff intent in the same campaign-state transaction that drains the
# pending entry, so a callback lost after creating an MR does not wait for the
# running timeout lease.
reconcile_running_preflight_completion() {
  local job_id="$1" project="$2" iid="$3"
  local current_job claim_generation claim_token_sha256 context
  local completion_output completion_rc completion_json

  exec {COMPLETION_SNAPSHOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  flock -x "${COMPLETION_SNAPSHOT_LOCK_FD}"
  current_job="$(jq -c --arg job_id "${job_id}" \
    '.active_jobs[$job_id] // null' "${SCHEDULER_STATE_FILE}")"
  flock -u "${COMPLETION_SNAPSHOT_LOCK_FD}"
  exec {COMPLETION_SNAPSHOT_LOCK_FD}>&-

  if ! jq -e \
      --arg job_id "${job_id}" \
      --arg project "${project}" \
      --argjson iid "${iid}" '
      type == "object"
      and .job_id == $job_id
      and .project == $project
      and .iid == $iid
      and .status == "running"
      and (.finalization // null) == null
      and (.claim_generation | type == "number"
        and . == floor and . > 0)
      and (.claim_token | type == "string" and length > 0)
    ' <<<"${current_job}" >/dev/null; then
    jq -cn '{status:"stale_scheduler"}'
    return 0
  fi

  claim_generation="$(jq -r '.claim_generation' <<<"${current_job}")"
  claim_token_sha256="$(printf '%s' \
    "$(jq -r '.claim_token' <<<"${current_job}")" | dlc_sha256)" \
    || return 2
  context="$(project_context "${project}")" || return 2

  set +e
  completion_output="$(printf '' | \
    PROJECT="$(jq -r '.slug' <<<"${context}")" \
    GROUP="$(jq -r '.group' <<<"${context}")" \
    GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
    REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${context}")" \
    IID="${iid}" DRIVEN_COMPLETED_RECONCILE=1 \
    DRIVEN_RECONCILE_JOB_ID="${job_id}" \
    DRIVEN_RECONCILE_CLAIM_GENERATION="${claim_generation}" \
    DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${claim_token_sha256}" \
      bash "${EXPIRE_RUNNING_CMD}" 2>/dev/null)"
  completion_rc=$?
  set -e
  if [ "${completion_rc}" -ne 0 ] || ! completion_json="$(printf '%s' "${completion_output}" | jq -ce \
      --argjson iid "${iid}" '
      if type == "object"
        and .iid == $iid
        and (.callback_status == "handled"
          or .callback_status == "not_completed"
          or .callback_status == "stale_claim"
          or .callback_status == "stale_or_already_drained"
          or .callback_status == "lock_held")
        and (if .callback_status == "handled"
          then .terminal_status == "skipped"
          else true end)
      then . else error("invalid completion reconcile envelope") end
    ' 2>/dev/null)"; then
    jq -cn '{status:"failed"}'
    return 0
  fi

  jq -cn \
    --arg status "$(jq -r '.callback_status' <<<"${completion_json}")" \
    --argjson claim_generation "${claim_generation}" '{
    status:$status,
    claim_generation:$claim_generation
  }'
}

# Every live-preflight skip is terminalized through its exact scheduler claim:
# claim-0 for a fresh reservation, or a claim-fenced project handoff for a
# running continuation. This guarantees zero new spawn for skips and releases
# slots before actionable claims are emitted.
import_candidate_skips() {
  local candidate_set="$1"
  local grant job_id project iid skipped skipped_count skip_output skip_rc skip_status
  local completion_result completion_status
  LAST_IMPORTED_SKIP_COUNT=0
  while IFS= read -r grant; do
    [ -n "${grant}" ] || continue
    job_id="$(jq -r '.job_id' <<<"${grant}")"
    project="$(jq -r '.project' <<<"${grant}")"
    iid="$(jq -r '.iid' <<<"${grant}")"
    skipped="$(jq -c --arg job_id "${job_id}" \
      '[.[] | select(.job_id == $job_id)]' <<<"${SKIPPED_ENTRIES}")"
    skipped_count="$(jq -r 'length' <<<"${skipped}")"
    [ "${skipped_count}" -eq 0 ] && continue
    if jq -e --arg job_id "${job_id}" \
        'any(.[]; .job_id == $job_id)' <<<"${ACTIVE_CONTINUATIONS}" >/dev/null; then
      if jq -e --arg project "${project}" --argjson iid "${iid}" '
          any(.[]; .project == $project and .iid == $iid)
        ' <<<"${PROJECT_PENDING_ENTRIES}" >/dev/null; then
        completion_result="$(reconcile_running_preflight_completion \
          "${job_id}" "${project}" "${iid}")" || completion_result='{"status":"failed"}'
        completion_status="$(jq -r '.status' <<<"${completion_result}")"
        case "${completion_status}" in
          handled)
            append_operation "$(jq -cn \
              --arg job_id "${job_id}" \
              --argjson claim_generation \
                "$(jq -r '.claim_generation' <<<"${completion_result}")" '{
              operation:"running_preflight_skip",
              job_id:$job_id,
              status:"handoff_recorded",
              claim_generation:$claim_generation
            }')"
            LAST_IMPORTED_SKIP_COUNT=$((LAST_IMPORTED_SKIP_COUNT + 1))
            ;;
          not_completed|stale_claim|stale_or_already_drained|lock_held|stale_scheduler)
            append_operation "$(jq -cn \
              --arg job_id "${job_id}" \
              --arg status "${completion_status}" '{
              operation:"running_preflight_skip",job_id:$job_id,status:$status
            }')"
            ;;
          *)
            append_operation "$(jq -cn --arg job_id "${job_id}" '{
              operation:"running_preflight_skip",job_id:$job_id,status:"failed"
            }')"
            HAD_FAILURE=true
            ;;
        esac
        continue
      fi
    fi
    if [ "${skipped_count}" -ne 1 ]; then
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"synthetic_skip",job_id:$job_id,status:"duplicate_entry"
      }')"
      HAD_FAILURE=true
      continue
    fi
    set +e
    skip_output="$(printf '%s' "$(jq -c '.[0]' <<<"${skipped}")" | \
      CONFIG_DIR="${CONFIG_DIR}" bash "${IMPORT_SKIP_CMD}" 2>/dev/null)"
    skip_rc=$?
    set -e
    if [ "${skip_rc}" -eq 0 ] && skip_status="$(jq -er '
        if type == "object"
          and (.status == "imported" or .status == "replayed")
        then .status else error("invalid skip import") end
      ' <<<"${skip_output}" 2>/dev/null)"; then
      append_operation "$(jq -cn --arg job_id "${job_id}" --arg status "${skip_status}" '{
        operation:"synthetic_skip",job_id:$job_id,status:$status
      }')"
      LAST_IMPORTED_SKIP_COUNT=$((LAST_IMPORTED_SKIP_COUNT + 1))
    else
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"synthetic_skip",job_id:$job_id,status:"failed"
      }')"
      HAD_FAILURE=true
    fi
  done < <(jq -c '.[]' <<<"${candidate_set}")
}

import_candidate_skips "${CANDIDATES}"

# A successful synthetic terminal frees a physical slot immediately. Re-run
# the strict scheduler reservation and project preflight in the same tick until
# a refill round contains no further skip. Novel-job checking prevents a broken
# importer/reserver pair from spinning on the same grant forever.
while [ "${LAST_IMPORTED_SKIP_COUNT}" -gt 0 ]; do
  set +e
  REFILL_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE_CMD}" 2>/dev/null)"
  REFILL_RC=$?
  set -e
  if [ "${REFILL_RC}" -ne 0 ] || ! REFILL_JSON="$(printf '%s' "${REFILL_OUTPUT}" | jq -ce '
      if type == "object"
        and (.status == "ready" or .status == "idle" or .status == "at_capacity")
        and (.grants | type == "array")
        and (.active_count | type == "number" and . == floor and . >= 0)
        and (.available_slots | type == "number" and . == floor and . >= 0)
      then . else error("invalid refill envelope") end
    ' 2>/dev/null)"; then
    append_operation "$(jq -cn '{operation:"reservation",status:"refill_failed"}')"
    HAD_FAILURE=true
    break
  fi
  append_operation "$(jq -cn --argjson reserve "${REFILL_JSON}" '{
    operation:"reservation",status:$reserve.status,
    grant_count:($reserve.grants | length),active_count:$reserve.active_count,
    available_slots:$reserve.available_slots
  }')"
  REFILL_GRANTS="$(jq -c '.grants' <<<"${REFILL_JSON}")"
  [ "$(jq -r 'length' <<<"${REFILL_GRANTS}")" -gt 0 ] || break
  NOVEL_REFILL_GRANTS="$(jq -cn \
    --argjson existing "${CANDIDATES}" \
    --argjson refill "${REFILL_GRANTS}" '
    [$refill[] | select(.job_id as $job_id
      | any($existing[]; .job_id == $job_id) | not)]
  ')"
  if [ "$(jq -r 'length' <<<"${NOVEL_REFILL_GRANTS}")" -eq 0 ]; then
    append_operation "$(jq -cn '{operation:"reservation",status:"duplicate_refill"}')"
    HAD_FAILURE=true
    break
  fi
  CANDIDATES="$(jq -cn \
    --argjson existing "${CANDIDATES}" \
    --argjson refill "${NOVEL_REFILL_GRANTS}" '$existing + $refill')"
  topup_candidate_set "${NOVEL_REFILL_GRANTS}"
  seed_topup_actions "${NOVEL_REFILL_GRANTS}"
  if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_topup_seed ]; then
    exit 83
  fi
  import_candidate_skips "${NOVEL_REFILL_GRANTS}"
done

flock -u "${EXECUTOR_TICK_LOCK_FD}"
exec {EXECUTOR_TICK_LOCK_FD}>&-

# Preserve scheduler grant order even though project topups were grouped.
while IFS= read -r grant; do
  [ -n "${grant}" ] || continue
  job_id="$(jq -r '.job_id' <<<"${grant}")"
  project="$(jq -r '.project' <<<"${grant}")"
  iid="$(jq -r '.iid' <<<"${grant}")"

  skipped="$(jq -c --arg job_id "${job_id}" \
    '[.[] | select(.job_id == $job_id)]' <<<"${SKIPPED_ENTRIES}")"
  skipped_count="$(jq -r 'length' <<<"${skipped}")"
  if [ "${skipped_count}" -gt 1 ]; then
    continue
  elif [ "${skipped_count}" -eq 1 ]; then
    continue
  fi

  dlc_open "${job_id}"
  action="$(dlc_read)" || {
    dlc_close
    tick_die "durable launch action is invalid"
  }
  if [ "${action}" = null ]; then
    dlc_close
    continue
  fi
  if ! jq -e \
      --arg job_id "${job_id}" \
      --arg project "${project}" \
      --argjson iid "${iid}" \
      --arg batch_id "$(jq -r '.batch_id' <<<"${grant}")" \
      --argjson snapshot_index "$(jq -r '.snapshot_index' <<<"${grant}")" '
      .job_id == $job_id and .project == $project and .iid == $iid
      and .batch_id == $batch_id and .snapshot_index == $snapshot_index
      and (.attempt_number | type == "number" and . == floor and . > 0)
      and (.child_label | type == "string" and length > 0)
      and (.payload_path | type == "string" and startswith("/"))
      and (.expected_task_sha256 | type == "string"
        and test("^[0-9a-f]{64}$"))
      and (.expected_task_bytes | type == "number"
        and . == floor and . > 0)
    ' <<<"${action}" >/dev/null; then
    append_operation "$(jq -cn --arg job_id "${job_id}" '{
      operation:"preparing",job_id:$job_id,status:"coordinator_conflict"
    }')"
    HAD_FAILURE=true
    dlc_close
    continue
  fi

  action_stage="$(jq -r '.stage' <<<"${action}")"
  if [ "${action_stage}" = action_emitted ]; then
    # sessions_spawn may already have succeeded even though its acknowledgement
    # never reached the fixed post-spawn wrapper. Once the preparing lease has
    # been fenced back to reserved, never guess by rotating the claim here.
    # Return a claim-token-free reconciliation action; only explicit runtime evidence
    # handled by resolve_executor_batch_reconcile.sh may recover or reset it.
    exec {EMITTED_RECOVERY_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
    flock -x "${EMITTED_RECOVERY_LOCK_FD}"
    emitted_scheduler_job="$(jq -c --arg job_id "${job_id}" \
      '.active_jobs[$job_id] // null' "${SCHEDULER_STATE_FILE}")"
    flock -u "${EMITTED_RECOVERY_LOCK_FD}"
    exec {EMITTED_RECOVERY_LOCK_FD}>&-
    if jq -e \
        --argjson prior_generation "$(jq -r '.claim_generation' <<<"${action}")" '
        type == "object"
        and .status == "reserved"
        and .claim_generation == $prior_generation
        and .claim_token == null
      ' <<<"${emitted_scheduler_job}" >/dev/null; then
      RECONCILE_ACTIONS="$(jq -c \
        --arg job_id "${job_id}" \
        --argjson claim_generation "$(jq -r '.claim_generation' <<<"${action}")" \
        --arg project "${project}" \
        --argjson iid "${iid}" \
        --argjson attempt_number "$(jq -r '.attempt_number' <<<"${action}")" \
        --arg child_label "$(jq -r '.child_label' <<<"${action}")" \
        --arg expected_task_sha256 "$(jq -r '.expected_task_sha256' <<<"${action}")" \
        --argjson expected_task_bytes "$(jq -r '.expected_task_bytes' <<<"${action}")" '
        . + [{
          action:"reconcile_emitted_spawn",
          job_id:$job_id,
          claim_generation:$claim_generation,
          project:$project,
          iid:$iid,
          attempt_number:$attempt_number,
          child_label:$child_label,
          expected_task_sha256:$expected_task_sha256,
          expected_task_bytes:$expected_task_bytes
        }]
      ' <<<"${RECONCILE_ACTIONS}")"
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"spawn_reconcile",job_id:$job_id,status:"required"
      }')"
    fi
    # A runtime call may already exist and its acknowledgement is not yet
    # durably recorded. Never expose a later grant in the same tick; explicit
    # reconciliation must resolve this action first.
    dlc_close
    break
  fi
  if [ "${action_stage}" = ack_received ] \
      || [ "${action_stage}" = project_recorded ] \
      || [ "${action_stage}" = scheduler_recorded ]; then
    # resume_durable_launch_actions owns these stages. If it could not finish,
    # keep the global serial gate closed instead of launching another child.
    HAD_FAILURE=true
    dlc_close
    break
  fi
  if [ "${action_stage}" = topup_prepared ]; then
    set +e
    claim_output="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${job_id}" \
      ACTION=preparing bash "${RECORD_LAUNCH_CMD}" 2>/dev/null)"
    claim_rc=$?
    set -e
    if [ "${claim_rc}" -ne 0 ] || ! claim_json="$(printf '%s' "${claim_output}" | jq -ce '
        if type == "object"
          and .status == "recorded"
          and .job_status == "preparing"
          and (.should_spawn | type == "boolean")
          and (if .should_spawn then
            (.claim_generation | type == "number" and . == floor and . > 0)
            and (.claim_token | type == "string" and length > 0)
          else .claim_generation == null and .claim_token == null end)
        then . else error("invalid preparing acknowledgement") end
      ' 2>/dev/null)"; then
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"preparing",job_id:$job_id,status:"failed"
      }')"
      HAD_FAILURE=true
      dlc_close
      continue
    fi
    if [ "$(jq -r '.should_spawn' <<<"${claim_json}")" = true ]; then
      action="$(jq -c \
        --argjson claim_generation "$(jq -r '.claim_generation' <<<"${claim_json}")" \
        --arg claim_token "$(jq -r '.claim_token' <<<"${claim_json}")" \
        --argjson now "$(date +%s)" '
        .claim_generation = $claim_generation
        | .claim_token = $claim_token
        | .stage = "preparing_claimed"
        | .updated_at = $now
      ' <<<"${action}")"
      dlc_write "${action}"
      action_stage=preparing_claimed
    else
      # Recover the crash window where record committed reserved->preparing but
      # the tick died before persisting the private claim in this coordinator.
      exec {RECOVER_CLAIM_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
      flock -x "${RECOVER_CLAIM_LOCK_FD}"
      recovered_claim="$(jq -c \
        --arg job_id "${job_id}" '
        .active_jobs[$job_id]
        | if type == "object" and .status == "preparing"
            and (.claim_generation | type == "number" and . > 0)
            and (.claim_token | type == "string" and length > 0)
          then {generation:.claim_generation,token:.claim_token}
          else null end
      ' "${SCHEDULER_STATE_FILE}")"
      flock -u "${RECOVER_CLAIM_LOCK_FD}"
      exec {RECOVER_CLAIM_LOCK_FD}>&-
      if [ "${recovered_claim}" = null ]; then
        append_operation "$(jq -cn --arg job_id "${job_id}" '{
          operation:"preparing",job_id:$job_id,status:"suppressed"
        }')"
        dlc_close
        continue
      fi
      action="$(jq -c \
        --argjson claim_generation "$(jq -r '.generation' <<<"${recovered_claim}")" \
        --arg claim_token "$(jq -r '.token' <<<"${recovered_claim}")" \
        --argjson now "$(date +%s)" '
        .claim_generation = $claim_generation
        | .claim_token = $claim_token
        | .stage = "preparing_claimed"
        | .updated_at = $now
      ' <<<"${action}")"
      dlc_write "${action}"
      action_stage=preparing_claimed
    fi
  fi

  # Project preparation labels are only project-local (for example
  # #42-att-001). Before bind/emission, replace them with a deterministic
  # agent-wide runtime label bound to project + physical job + generation.
  # Recomputing the same bytes also repairs a crash after claim persistence but
  # before the coordinator label write. Never relabel action_emitted: a runtime
  # child may already exist under the durable label stored at emission time.
  if [ "${action_stage}" = preparing_claimed ] \
      || [ "${action_stage}" = bound ]; then
    runtime_child_label="$(dlc_runtime_child_label \
      "${project}" "${iid}" "${job_id}" \
      "$(jq -r '.claim_generation' <<<"${action}")" \
      "$(jq -r '.attempt_number' <<<"${action}")")" || {
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"preparing",job_id:$job_id,status:"invalid_runtime_label"
      }')"
      HAD_FAILURE=true
      dlc_close
      continue
    }
    if [ "$(jq -r '.child_label' <<<"${action}")" != "${runtime_child_label}" ] \
        || [ "$(jq -r '.runtime_label_version // 0' <<<"${action}")" -ne 1 ]; then
      action="$(jq -c \
        --arg child_label "${runtime_child_label}" \
        --argjson now "$(date +%s)" '
        .child_label = $child_label
        | .runtime_label_version = 1
        | .updated_at = $now
      ' <<<"${action}")"
      dlc_write "${action}"
    fi
  fi

  if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_preparing_persist ] \
      && [ "${action_stage}" = preparing_claimed ]; then
    dlc_close
    exit 84
  fi

  if [ "${action_stage}" = preparing_claimed ]; then
    claim_generation="$(jq -r '.claim_generation' <<<"${action}")"
    claim_token="$(jq -r '.claim_token' <<<"${action}")"
    context="$(project_context "${project}")" || {
      dlc_close
      tick_die "claim project became invalid"
    }
    set +e
    bind_output="$(PROJECT="$(jq -r '.slug' <<<"${context}")" \
      GROUP="$(jq -r '.group' <<<"${context}")" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${context}")" \
      IID="${iid}" JOB_ID="${job_id}" \
      CLAIM_GENERATION="${claim_generation}" CLAIM_TOKEN="${claim_token}" \
      bash "${BIND_CLAIM_CMD}" 2>/dev/null)"
    bind_rc=$?
    set -e
    if [ "${bind_rc}" -ne 0 ] || ! jq -e \
        --arg job_id "${job_id}" \
        --argjson claim_generation "${claim_generation}" '
        type == "object"
        and (.status == "bound" or .status == "idempotent" or .status == "rebound")
        and .job_id == $job_id
        and .claim_generation == $claim_generation
      ' <<<"${bind_output}" >/dev/null 2>&1; then
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"preparing",job_id:$job_id,status:"bind_failed"
      }')"
      HAD_FAILURE=true
      dlc_close
      continue
    fi
    action="$(jq -c --argjson now "$(date +%s)" '
      .stage = "bound" | .updated_at = $now
    ' <<<"${action}")"
    dlc_write "${action}"
    action_stage=bound
  fi

  if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_bind_persist ] \
      && [ "${action_stage}" = bound ]; then
    dlc_close
    exit 85
  fi

  if [ "${action_stage}" = bound ]; then
    action="$(jq -c --argjson now "$(date +%s)" '
      .stage = "action_emitted" | .updated_at = $now
    ' <<<"${action}")"
    dlc_write "${action}"
    append_operation "$(jq -cn --arg job_id "${job_id}" '{
      operation:"preparing",job_id:$job_id,status:"ready"
    }')"
    SPAWN_GRANTS="$(jq -c \
      --arg job_id "${job_id}" \
      --argjson claim_generation "$(jq -r '.claim_generation' <<<"${action}")" \
      --arg project "${project}" \
      --argjson iid "${iid}" \
      --argjson attempt_number "$(jq -r '.attempt_number' <<<"${action}")" \
      --arg child_label "$(jq -r '.child_label' <<<"${action}")" \
      --arg payload_path "$(jq -r '.payload_path' <<<"${action}")" \
      --arg expected_task_sha256 "$(jq -r '.expected_task_sha256' <<<"${action}")" \
      --argjson expected_task_bytes "$(jq -r '.expected_task_bytes' <<<"${action}")" '
      . + [{
        job_id:$job_id,
        claim_generation:$claim_generation,
        project:$project,
        iid:$iid,
        attempt_number:$attempt_number,
        child_label:$child_label,
        payload_path:$payload_path,
        expected_task_sha256:$expected_task_sha256,
        expected_task_bytes:$expected_task_bytes
      }]
    ' <<<"${SPAWN_GRANTS}")"
  fi
  dlc_close
  if [ "$(jq -r 'length' <<<"${SPAWN_GRANTS}")" -gt 0 ]; then
    # Exactly one grant is exposed per tick. Its recorder must finish before a
    # later tick can advance the next coordinator action to action_emitted.
    break
  fi
done < <(jq -c '.[]' <<<"${CANDIDATES}")

if [ "$(jq -r 'length' <<<"${SPAWN_GRANTS}")" -gt 0 ]; then
  TICK_STATUS=ready
  CHAT_SUMMARY="executor batch tick prepared $(jq -r 'length' <<<"${SPAWN_GRANTS}") spawn grant(s) and $(jq -r 'length' <<<"${RECONCILE_ACTIONS}") reconciliation action(s)"
elif [ "$(jq -r 'length' <<<"${RECONCILE_ACTIONS}")" -gt 0 ]; then
  TICK_STATUS=reconcile_required
  CHAT_SUMMARY="executor batch tick requires runtime reconciliation before retry"
elif [ "${HAD_FAILURE}" = true ]; then
  TICK_STATUS=tick_failed
  CHAT_SUMMARY="executor batch tick completed with recoverable operation failures"
else
  TICK_STATUS=idle
  CHAT_SUMMARY="executor batch tick has no spawn grant"
fi

jq -cn \
  --arg status "${TICK_STATUS}" \
  --argjson spawn_grants "${SPAWN_GRANTS}" \
  --argjson reconcile_actions "${RECONCILE_ACTIONS}" \
  --argjson operation_results "${OPERATIONS}" \
  --arg chat_summary "${CHAT_SUMMARY}" '{
    status:$status,
    spawn_grants:$spawn_grants,
    reconcile_actions:$reconcile_actions,
    operation_results:$operation_results,
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:$chat_summary
  }'
