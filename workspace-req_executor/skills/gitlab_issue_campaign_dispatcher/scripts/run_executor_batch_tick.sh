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
RESERVE_CMD="${RESERVE_CMD:-${SCRIPT_DIR}/reserve_driven_batch_items.sh}"
TOPUP_CMD="${TOPUP_CMD:-${SCRIPT_DIR}/dispatch_driven_topup.sh}"
IMPORT_SKIP_CMD="${IMPORT_SKIP_CMD:-${SCRIPT_DIR}/import_driven_skipped.sh}"
RECORD_LAUNCH_CMD="${RECORD_LAUNCH_CMD:-${SCRIPT_DIR}/record_driven_batch_launch.sh}"
BIND_CLAIM_CMD="${BIND_CLAIM_CMD:-${SCRIPT_DIR}/bind_driven_claim.sh}"
RESUME_SPAWN_CMD="${RESUME_SPAWN_CMD:-${SCRIPT_DIR}/record_executor_batch_spawn.sh}"

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

for command_spec in \
  "SCHEDULER_ENV_CMD:${SCHEDULER_ENV_CMD}" \
  "RESOLVE_REPO_CMD:${RESOLVE_REPO_CMD}" \
  "DRAIN_HANDOFF_CMD:${DRAIN_HANDOFF_CMD}" \
  "DRAIN_OUTBOX_CMD:${DRAIN_OUTBOX_CMD}" \
  "RESERVE_CMD:${RESERVE_CMD}" \
  "TOPUP_CMD:${TOPUP_CMD}" \
  "IMPORT_SKIP_CMD:${IMPORT_SKIP_CMD}" \
  "RECORD_LAUNCH_CMD:${RECORD_LAUNCH_CMD}" \
  "BIND_CLAIM_CMD:${BIND_CLAIM_CMD}" \
  "RESUME_SPAWN_CMD:${RESUME_SPAWN_CMD}"
do
  validate_command "${command_spec%%:*}" "${command_spec#*:}"
done

# Preserve process overrides before sourcing deployment pins. No credential is
# ever printed or inserted into operation_results.
GITLAB_TOKEN_PROCESS_OVERRIDE="${GITLAB_TOKEN:-}"
REPO_PARENT_PROCESS_OVERRIDE="${REPO_PARENT_PATH:-}"
SCHEDULER_ROOT_PROCESS_SET="${EXECUTOR_SCHEDULER_ROOT+x}"
SCHEDULER_ROOT_PROCESS_OVERRIDE="${EXECUTOR_SCHEDULER_ROOT:-}"
MAX_CONCURRENCY_PROCESS_SET="${EXECUTOR_MAX_CONCURRENCY+x}"
MAX_CONCURRENCY_PROCESS_OVERRIDE="${EXECUTOR_MAX_CONCURRENCY:-}"
[ -f "${CONFIG_DIR}/gitlab.env" ] \
  || tick_die "missing config/gitlab.env"
[ -f "${CONFIG_DIR}/campaign_defaults.env" ] \
  || tick_die "missing config/campaign_defaults.env"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/gitlab.env"
GITLAB_TOKEN_PIN="${GITLAB_TOKEN:-}"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/campaign_defaults.env"
if [ -f "${CONFIG_DIR}/campaign_defaults.local.env" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_DIR}/campaign_defaults.local.env"
fi
if [ "${SCHEDULER_ROOT_PROCESS_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT_PROCESS_OVERRIDE}"
fi
if [ "${MAX_CONCURRENCY_PROCESS_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${MAX_CONCURRENCY_PROCESS_OVERRIDE}"
fi
GITLAB_TOKEN_EFF="${GITLAB_TOKEN_PROCESS_OVERRIDE:-${GITLAB_TOKEN_PIN:-}}"
REPO_PARENT_BASE="${REPO_PARENT_PROCESS_OVERRIDE:-${REPO_PARENT_PATH:-/data}}"
[ -n "${GITLAB_TOKEN_EFF}" ] || tick_die "executor GitLab credential is unavailable"
case "${GITLAB_TOKEN_EFF}" in
  *[[:cntrl:]]*) tick_die "executor GitLab credential contains control characters" ;;
esac
: "${GITLAB_HOST:?run_executor_batch_tick.sh: GITLAB_HOST missing}"
: "${GITLAB_API_PROTOCOL:?run_executor_batch_tick.sh: GITLAB_API_PROTOCOL missing}"

# scheduler_env exports all paths and validates the deployment concurrency pin.
# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null
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
shopt -s nullglob
for request_file in "${BATCHES_ROOT}"/*/request.json; do
  request_project="$(jq -er '
    if type == "object"
      and (.project | type == "string"
        and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    then .project else error("invalid batch project") end
  ' "${request_file}")" || tick_die "registered batch request is invalid"
  PROJECTS_JSON="$(jq -c --arg project "${request_project}" \
    '(. + [$project]) | unique' <<<"${PROJECTS_JSON}")"
done

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
topup_candidate_set() {
  local candidate_set="$1"
  local candidate_projects project project_grants context topup_request
  local topup_output topup_rc topup_json

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
      EXECUTOR_MAX_CONCURRENCY="${EXECUTOR_MAX_CONCURRENCY}" \
      bash "${TOPUP_CMD}" 2>/dev/null)"
    topup_rc=$?
    set -e
    if [ "${topup_rc}" -ne 0 ] || ! topup_json="$(printf '%s' "${topup_output}" | jq -ce '
        if type == "object"
          and (.status | type == "string")
          and (.dispatch_entries | type == "array")
          and ((.skipped_entries // []) | type == "array")
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
          --argjson attempt_number "$(jq -r '.attempt_number' <<<"${entry}")" '
          .job_id == $job_id and .project == $project and .iid == $iid
          and .batch_id == $batch_id and .snapshot_index == $snapshot_index
          and .attempt_number == $attempt_number
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
            --argjson now "${now}" '
            .attempt_number = $attempt_number
            | .child_label = $child_label
            | .payload_path = $payload_path
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

# Every live-preflight skip is terminalized through claim-0 before any physical
# job is allowed to enter preparing. This both guarantees zero spawn for skips
# and releases their global slots before actionable claims are emitted.
import_candidate_skips() {
  local candidate_set="$1"
  local grant job_id skipped skipped_count skip_output skip_rc skip_status
  LAST_IMPORTED_SKIP_COUNT=0
  while IFS= read -r grant; do
    [ -n "${grant}" ] || continue
    job_id="$(jq -r '.job_id' <<<"${grant}")"
    skipped="$(jq -c --arg job_id "${job_id}" \
      '[.[] | select(.job_id == $job_id)]' <<<"${SKIPPED_ENTRIES}")"
    skipped_count="$(jq -r 'length' <<<"${skipped}")"
    [ "${skipped_count}" -eq 0 ] && continue
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
    # Return a token-free reconciliation action; only explicit runtime evidence
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
        --arg child_label "$(jq -r '.child_label' <<<"${action}")" '
        . + [{
          action:"reconcile_emitted_spawn",
          job_id:$job_id,
          claim_generation:$claim_generation,
          project:$project,
          iid:$iid,
          attempt_number:$attempt_number,
          child_label:$child_label
        }]
      ' <<<"${RECONCILE_ACTIONS}")"
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"spawn_reconcile",job_id:$job_id,status:"required"
      }')"
    fi
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
      --arg payload_path "$(jq -r '.payload_path' <<<"${action}")" '
      . + [{
        job_id:$job_id,
        claim_generation:$claim_generation,
        project:$project,
        iid:$iid,
        attempt_number:$attempt_number,
        child_label:$child_label,
        payload_path:$payload_path
      }]
    ' <<<"${SPAWN_GRANTS}")"
  fi
  dlc_close
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
