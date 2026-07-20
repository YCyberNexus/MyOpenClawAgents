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
RECOVER_SHARED_MR_CMD="${RECOVER_SHARED_MR_CMD:-${SCRIPT_DIR}/recover_shared_mr_finalization.sh}"
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
validate_bash_script RECOVER_SHARED_MR_CMD "${RECOVER_SHARED_MR_CMD}"
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
ACPX_TIMEOUT_PROCESS_SET="${EXECUTOR_ACPX_TIMEOUT_SECONDS+x}"
ACPX_TIMEOUT_PROCESS_OVERRIDE="${EXECUTOR_ACPX_TIMEOUT_SECONDS:-}"
RUNNING_LEASE_PROCESS_SET="${EXECUTOR_RUNNING_LEASE_SECONDS+x}"
RUNNING_LEASE_PROCESS_OVERRIDE="${EXECUTOR_RUNNING_LEASE_SECONDS:-}"
POST_ACPX_GRACE_PROCESS_SET="${EXECUTOR_POST_ACPX_GRACE_SECONDS+x}"
POST_ACPX_GRACE_PROCESS_OVERRIDE="${EXECUTOR_POST_ACPX_GRACE_SECONDS:-}"
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
: "${EXECUTOR_POST_ACPX_GRACE_SECONDS:=2400}"
if [ "${SCHEDULER_ROOT_PROCESS_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT_PROCESS_OVERRIDE}"
fi
if [ "${MAX_CONCURRENCY_PROCESS_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${MAX_CONCURRENCY_PROCESS_OVERRIDE}"
fi
if [ "${ACPX_TIMEOUT_PROCESS_SET}" = x ]; then
  EXECUTOR_ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_PROCESS_OVERRIDE}"
fi
if [ "${RUNNING_LEASE_PROCESS_SET}" = x ]; then
  EXECUTOR_RUNNING_LEASE_SECONDS="${RUNNING_LEASE_PROCESS_OVERRIDE}"
fi
if [ "${POST_ACPX_GRACE_PROCESS_SET}" = x ]; then
  EXECUTOR_POST_ACPX_GRACE_SECONDS="${POST_ACPX_GRACE_PROCESS_OVERRIDE}"
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
case "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" in
  ''|*[!0-9]*) tick_die "EXECUTOR_POST_ACPX_GRACE_SECONDS must be a positive integer" ;;
esac
if [ "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" -lt 60 ]; then
  tick_die "EXECUTOR_POST_ACPX_GRACE_SECONDS must be >= 60"
fi

# scheduler_env exports all paths and validates the deployment concurrency pin.
# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null
# scheduler_env sources the same deployment files for scheduler validation;
# restore the already-resolved process/config repo parent afterwards so every
# child wrapper observes the same effective clone root.
export REPO_PARENT_PATH="${REPO_PARENT_BASE}"
export GITLAB_HOST="${GITLAB_HOST_RESOLVED}"
export GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_RESOLVED}"
if [ "${POST_ACPX_GRACE_PROCESS_SET}" = x ]; then
  EXECUTOR_POST_ACPX_GRACE_SECONDS="${POST_ACPX_GRACE_PROCESS_OVERRIDE}"
fi
case "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" in
  ''|*[!0-9]*) tick_die "EXECUTOR_POST_ACPX_GRACE_SECONDS must be a positive integer" ;;
esac
if [ "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" -lt 60 ]; then
  tick_die "EXECUTOR_POST_ACPX_GRACE_SECONDS must be >= 60"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_driven_launch_coordinator.sh"

OPERATIONS='[]'
SPAWN_GRANTS='[]'
RECONCILE_ACTIONS='[]'
CLEANUP_ACTIONS='[]'
HAD_FAILURE=false

append_operation() {
  local operation_json="$1"
  OPERATIONS="$(jq -ce --argjson operation "${operation_json}" \
    '. + [$operation]' <<<"${OPERATIONS}")"
}

tick_file_mode() {
  local path="$1" mode
  if mode="$(stat -f '%Lp' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -c '%a' "${path}" 2>/dev/null
  fi
}

tick_file_owner() {
  local path="$1" owner
  if owner="$(stat -f '%u' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${owner}"
  else
    stat -c '%u' "${path}" 2>/dev/null
  fi
}

tick_read_private_json() {
  local path="$1" bytes mode owner
  [ -f "${path}" ] && [ ! -L "${path}" ] || return 1
  mode="$(tick_file_mode "${path}")" || return 1
  owner="$(tick_file_owner "${path}")" || return 1
  bytes="$(wc -c <"${path}" 2>/dev/null | tr -d '[:space:]')"
  [ "${mode}" = 600 ] && [ "${owner}" = "$(id -u)" ] \
    && [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${bytes}" -le 65536 ] || return 1
  jq -ce 'if type == "object" then . else error("not an object") end' \
    "${path}" 2>/dev/null
}

# Return the exact pending checkpoint only when both private state files and
# the scheduler-owned pending entry describe the same two-Issue branch
# attempt. This prefilter keeps ordinary branches and stale attempts away from
# the MR-only recovery command; that command independently repeats the fixed
# identity checks before touching GitLab.
post_acpx_shared_mr_checkpoint() {
  local pending="$1" issue_state_file="$2" attempt_state_file="$3"
  local iid="$4" attempt_number="$5" work_branch="$6"
  local issue_state attempt_state
  issue_state="$(tick_read_private_json "${issue_state_file}")" || return 1
  attempt_state="$(tick_read_private_json "${attempt_state_file}")" || return 1
  jq -nce \
    --argjson pending "${pending}" \
    --argjson issue_state "${issue_state}" \
    --argjson attempt_state "${attempt_state}" \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt_number}" \
    --arg work_branch "${work_branch}" '
      ($pending.branch_members // null) as $members
      | ($pending.merge_target_branch // $pending.branch // "") as $target
      | ($issue_state.mr_finalization // null) as $finalization
      | if ($pending | type) == "object"
        and $pending.auto_merge == false
        and ($members | type == "array" and length == 2)
        and all($members[]; type == "number" and . == floor and . > 0)
        and $members[0] != $members[1]
        and ($members | index($iid) != null)
        and $work_branch == ("issue/" + ($members[0] | tostring)
          + "+" + ($members[1] | tostring))
        and $pending.work_branch == $work_branch
        and $pending.shared_branch_role ==
          (if $iid == $members[0] then "head" else "tail" end)
        and ($target | type == "string" and length > 0)
        and $attempt_state.iid == $iid
        and $attempt_state.attempt_number == $attempt_number
        and ($attempt_state.issue_title | type == "string" and length > 0)
        and ($attempt_state.mode_actual == "fresh"
          or $attempt_state.mode_actual == "continue")
        and $attempt_state.auto_merge == false
        and $attempt_state.work_branch == $work_branch
        and $attempt_state.branch_members == $members
        and $attempt_state.shared_branch_role == $pending.shared_branch_role
        and $attempt_state.merge_target_branch == $target
        and $issue_state.iid == $iid
        and $issue_state.work_branch == $work_branch
        and $issue_state.branch_members == $members
        and $issue_state.shared_branch_role == $pending.shared_branch_role
        and $issue_state.dependency_history_verified == true
        and ($issue_state.work_branch_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and ($finalization | type == "object")
        and ($finalization | keys | sort) == ([
          "branch_members","commit_sha","intent_id","shared_branch_role",
          "source_attempt_number","status","target_branch","work_branch"
        ] | sort)
        and $finalization.status == "pending"
        and $finalization.source_attempt_number == $attempt_number
        and $finalization.work_branch == $work_branch
        and $finalization.branch_members == $members
        and $finalization.shared_branch_role == $pending.shared_branch_role
        and ($finalization.commit_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and ($finalization.intent_id | type == "string"
          and test("^[0-9a-f]{64}$"))
        and (($finalization.commit_sha | ascii_downcase)
          == ($issue_state.work_branch_sha | ascii_downcase))
        and $finalization.target_branch == $target
        and (if $pending.shared_branch_role == "head" then
          ($pending.dependency_iid // null) == null
          and ($pending.dependency_branch // null) == null
          and ($pending.dependency_base_sha // null) == null
          and ($attempt_state.dependency_iid // null) == null
          and ($attempt_state.dependency_branch // null) == null
          and ($attempt_state.dependency_base_sha // null) == null
          and ($issue_state.dependency_iid // null) == null
          and ($issue_state.dependency_branch // null) == null
          and ($issue_state.dependency_base_sha // null) == null
        else
          $pending.dependency_iid == $members[0]
          and $pending.dependency_branch == $work_branch
          and ($pending.dependency_base_sha | type == "string"
            and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
          and $attempt_state.dependency_iid == $pending.dependency_iid
          and $attempt_state.dependency_branch == $pending.dependency_branch
          and (($attempt_state.dependency_base_sha | ascii_downcase)
            == ($pending.dependency_base_sha | ascii_downcase))
          and $issue_state.dependency_iid == $pending.dependency_iid
          and $issue_state.dependency_branch == $pending.dependency_branch
          and (($issue_state.dependency_base_sha | ascii_downcase)
            == ($pending.dependency_base_sha | ascii_downcase))
        end)
      then $finalization else error("shared checkpoint mismatch") end
    ' 2>/dev/null
}

# A pending checkpoint can coexist briefly with a marker whose exact MR
# identity is known but whose prior observation is opened, closed, or unknown.
# Avoid a second finalization call: Phase 6 always performs the fresh live read
# and alone decides whether to complete, terminate, or retain the claim.
post_acpx_shared_mr_marker_ready() {
  local marker_file="$1" pending="$2" checkpoint="$3"
  local iid="$4" attempt_number="$5" marker
  marker="$(tick_read_private_json "${marker_file}")" || return 1
  jq -nce \
    --argjson marker "${marker}" \
    --argjson pending "${pending}" \
    --argjson checkpoint "${checkpoint}" \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt_number}" '
      ($pending.merge_target_branch // $pending.branch // "") as $target
      | ($pending.dependency_base_sha // "") as $dependency_sha
      | if ($marker | keys | sort) == ([
          "attempt_number","auto_merge","dependency_base_sha","iid",
          "issue_iid","merge_api_succeeded","merge_attempted","mr_action",
          "observed_state","outcome","reason","sha","source_branch",
          "shared_mr_intent_id","target_branch","verified","version","web_url"
        ] | sort)
        and $marker.version == 1
        and $marker.issue_iid == $iid
        and $marker.attempt_number == $attempt_number
        and $marker.auto_merge == false
        and $marker.source_branch == $checkpoint.work_branch
        and $marker.target_branch == $target
        and (($marker.dependency_base_sha | ascii_downcase)
          == ($dependency_sha | ascii_downcase))
        and (($marker.sha | ascii_downcase)
          == ($checkpoint.commit_sha | ascii_downcase))
        and $marker.shared_mr_intent_id == $checkpoint.intent_id
        and ($marker.iid | type == "number" and . == floor and . > 0)
        and ($marker.web_url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/"
            + ($marker.iid | tostring) + "/?$"))
        and (if $checkpoint.shared_branch_role == "head"
          then $marker.mr_action == "created"
          else $marker.mr_action == "reused" end)
        and ($marker.verified | type == "boolean")
        and ($marker.outcome | type == "string")
        and ($marker.observed_state | type == "string")
        and $marker.merge_attempted == false
        and $marker.merge_api_succeeded == false
        and ($marker.reason | type == "string" and length > 0)
      then true else error("shared marker not ready") end
    ' >/dev/null 2>&1
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
      cleanup_actions:[],
      operation_results:$operation_results,
      max_launch_retries:3,
      backoff_seconds:2,
      chat_summary:"executor batch tick stopped before reservation because terminal count reconciliation failed"
    }'
  exit 0
fi

project_context() {
  local project="$1" resolve_timeout="${2:-10}"
  local group slug resolved repo_parent
  if ! [[ "${project}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
    return 2
  fi
  case "${resolve_timeout}" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "${resolve_timeout}" -ge 1 ] && [ "${resolve_timeout}" -le 10 ] \
    || return 2
  group="${project%/*}"
  slug="${project##*/}"
  resolved="$(PROJECT_FULL="${project}" \
    REPO_PARENT_PATH="${REPO_PARENT_BASE}" \
    GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
    GITLAB_HOST="${GITLAB_HOST}" \
    timeout --kill-after=1s "${resolve_timeout}s" \
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

# Recover the exact failure mode where the fixed outer wrapper completed acpx
# (or even the whole attempt) but OpenClaw never scheduled the outer model's
# next/final turn. A durable worker_result.json is processed immediately under
# the scheduler claim fence. If only acpx_terminal.json exists and finalization
# has exceeded its short grace period, request native child cleanup so the
# OpenClaw subagent slot is not held until the multi-hour running lease expires.
POST_ACPX_NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"
POST_ACPX_RUNNING_JOBS="$(jq -c '
  [.active_jobs[]
    | select(.status == "running"
      and (.finalization // null) == null
      and (.claim_generation | type == "number" and . == floor and . > 0)
      and (.claim_token | type == "string" and length > 0))]
  | sort_by(.reservation_seq // 0, .job_id)
' <<<"${SCHEDULER_SNAPSHOT}")"
while IFS= read -r post_job; do
  [ -n "${post_job}" ] || continue
  post_job_id="$(jq -r '.job_id' <<<"${post_job}")"
  post_project="$(jq -r '.project' <<<"${post_job}")"
  post_iid="$(jq -r '.iid' <<<"${post_job}")"
  post_generation="$(jq -r '.claim_generation' <<<"${post_job}")"
  if ! post_context="$(project_context "${post_project}")"; then
    continue
  fi
  post_repo="$(jq -r '.repo_path' <<<"${post_context}")"
  post_state_file="${post_repo}/.req_executor/_dispatcher/campaign_state.json"
  [ -f "${post_state_file}" ] && [ ! -L "${post_state_file}" ] || continue
  if ! post_pending="$(jq -ce \
      --argjson iid "${post_iid}" \
      --arg job_id "${post_job_id}" \
      --argjson generation "${post_generation}" '
      (.pending_subagents[($iid | tostring)] // null)
      | select(type == "object"
        and .job_id == $job_id
        and .claim_generation == $generation
        and (.attempt_number | type == "number" and . == floor and . > 0)
        and (.run_id | type == "string" and length > 0)
        and (.child_session_key | type == "string" and length > 0))
    ' "${post_state_file}" 2>/dev/null)"; then
    continue
  fi
  post_attempt="$(jq -r '.attempt_number' <<<"${post_pending}")"
  post_run_id="$(jq -r '.run_id' <<<"${post_pending}")"
  post_child_session_key="$(jq -r '.child_session_key' <<<"${post_pending}")"
  post_work_branch="$(jq -r --argjson iid "${post_iid}" \
    '.work_branch // ("issue/" + ($iid | tostring))' <<<"${post_pending}")"
  if ! git check-ref-format --branch "${post_work_branch}" >/dev/null 2>&1; then
    continue
  fi
  printf -v post_attempt_padded '%03d' "${post_attempt}"
  post_log_dir="${post_repo}/.req_executor/.worktrees/issue-${post_iid}/.req_executor/issue-${post_iid}/log/attempt-${post_attempt_padded}"
  post_result_file="${post_log_dir}/worker_result.json"
  post_marker_file="${post_log_dir}/acpx_terminal.json"

  # A durable result is valid only after the fixed acpx wrapper has written its
  # exact terminal marker for this attempt. This prevents a stray or partial
  # result file from racing an inner acpx process that is still running.
  post_marker_json=""
  post_marker_bytes=""
  if [ -f "${post_marker_file}" ] && [ ! -L "${post_marker_file}" ]; then
    post_marker_bytes="$(wc -c <"${post_marker_file}" 2>/dev/null | tr -d ' ' || true)"
  fi
  if [[ "${post_marker_bytes}" =~ ^[0-9]+$ ]] \
      && [ "${post_marker_bytes}" -gt 0 ] \
      && [ "${post_marker_bytes}" -le 4096 ]; then
    post_marker_json="$(jq -ce \
      --argjson iid "${post_iid}" \
      --argjson attempt "${post_attempt}" '
      if type == "object"
        and (keys | sort) == ["attempt_number","completed_at_epoch","exit_code","iid","version"]
        and .version == 1 and .iid == $iid and .attempt_number == $attempt
        and (.exit_code | type == "number" and . == floor and . >= 0 and . <= 255)
        and (.completed_at_epoch | type == "number" and . == floor and . >= 0)
      then . else error("invalid acpx terminal marker") end
    ' "${post_marker_file}" 2>/dev/null || true)"
  fi

  post_result_json=""
  post_result_bytes=""
  if [ -n "${post_marker_json}" ] \
      && [ -f "${post_result_file}" ] && [ ! -L "${post_result_file}" ]; then
    post_result_bytes="$(wc -c <"${post_result_file}" 2>/dev/null | tr -d ' ' || true)"
  fi
  if [[ "${post_result_bytes}" =~ ^[0-9]+$ ]] \
      && [ "${post_result_bytes}" -gt 0 ] \
      && [ "${post_result_bytes}" -le 1048576 ]; then
    post_result_json="$(jq -ce \
      --argjson iid "${post_iid}" \
      --argjson attempt "${post_attempt}" \
      --arg work_branch "${post_work_branch}" \
      --arg local_branch "issue/${post_iid}-att${post_attempt_padded}" \
      --arg log_dir "${post_log_dir}" \
      --argjson acpx_exit "$(jq -r '.exit_code' <<<"${post_marker_json}")" '
      if type == "object"
        and (keys | sort) == ([
          "attempt_number","block_reason","commit_sha","iid",
          "labels_added","labels_removed","local_branch","log_dir",
          "merge_request_url","mode_actual","mr_action","status",
          "summary_posted","wiki_url","work_branch"
        ] | sort)
        and .iid == $iid
        and .attempt_number == $attempt
        and (.status as $status
          | ["done","no_changes","blocked","failed","timeout"]
          | index($status)) != null
        and (.mode_actual == "fresh" or .mode_actual == "continue")
        and .work_branch == $work_branch
        and .local_branch == $local_branch
        and (.commit_sha | type == "string"
          and (length == 0 or test("^[0-9a-fA-F]{7,64}$")))
        and (.merge_request_url | type == "string")
        and (.mr_action == "created" or .mr_action == "rotated"
          or .mr_action == "reused" or .mr_action == "none")
        and .wiki_url == ""
        and (.labels_added | type == "array" and all(.[]; type == "string"))
        and (.labels_removed | type == "array" and all(.[]; type == "string"))
        and (.summary_posted | type == "boolean")
        and (.block_reason | type == "string")
        and .log_dir == $log_dir
        and (if .status == "blocked" or .status == "failed" or .status == "timeout"
          then (.block_reason | length) > 0 else true end)
        and (if .status == "done" then $acpx_exit == 0 else true end)
      then . else error("invalid durable worker result") end
    ' "${post_result_file}" 2>/dev/null || true)"
  fi
  if [ -n "${post_result_json}" ]; then
    post_result_claim_retained=false
    post_token_sha256="$(printf '%s' "$(jq -r '.claim_token' <<<"${post_job}")" | dlc_sha256)" \
      || tick_die "unable to hash durable-result claim fence"
    set +e
    post_reconcile_output="$(printf '%s' "${post_result_json}" | \
      PROJECT="$(jq -r '.slug' <<<"${post_context}")" \
      GROUP="$(jq -r '.group' <<<"${post_context}")" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${post_context}")" \
      IID="${post_iid}" DRIVEN_RESULT_RECONCILE=1 \
      DRIVEN_RECONCILE_JOB_ID="${post_job_id}" \
      DRIVEN_RECONCILE_CLAIM_GENERATION="${post_generation}" \
      DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${post_token_sha256}" \
        bash "${EXPIRE_RUNNING_CMD}" 2>/dev/null)"
    post_reconcile_rc=$?
    set -e
    if [ "${post_reconcile_rc}" -eq 0 ] \
        && post_reconcile_json="$(jq -ce \
          --argjson iid "${post_iid}" '
          if type == "object" and .iid == $iid
            and (.callback_status | type == "string" and length > 0)
          then . else error("invalid durable result reconcile envelope") end
        ' <<<"${post_reconcile_output}" 2>/dev/null)"; then
      post_reconcile_status="$(jq -r '.callback_status' <<<"${post_reconcile_json}")"
      if [ "${post_reconcile_status}" = handled ] \
          && jq -e --argjson iid "${post_iid}" '
            .remaining_pending_iids | index($iid) != null
          ' <<<"${post_reconcile_json}" >/dev/null 2>&1; then
        post_result_claim_retained=true
      fi
      append_operation "$(jq -cn \
        --arg job_id "${post_job_id}" \
        --arg status "${post_reconcile_status}" '{
        operation:"durable_worker_result_reconcile",job_id:$job_id,status:$status
      }')"
      if [ "${post_reconcile_status}" = handled ] \
          && jq -e '.cleanup.action == "kill"
            and (.cleanup.target | type == "string" and length > 0)' \
            <<<"${post_reconcile_json}" >/dev/null 2>&1; then
        CLEANUP_ACTIONS="$(jq -c \
          --argjson cleanup "$(jq -c '.cleanup' <<<"${post_reconcile_json}")" \
          --arg job_id "${post_job_id}" \
          --argjson iid "${post_iid}" \
          --argjson attempt_number "${post_attempt}" \
          --argjson claim_generation "${post_generation}" '
          . + [$cleanup + {
            job_id:$job_id,iid:$iid,attempt_number:$attempt_number,
            claim_generation:$claim_generation
          }]
        ' <<<"${CLEANUP_ACTIONS}")"
      fi
    else
      append_operation "$(jq -cn --arg job_id "${post_job_id}" '{
        operation:"durable_worker_result_reconcile",job_id:$job_id,status:"failed"
      }')"
      HAD_FAILURE=true
    fi
    # Phase 6 deliberately retains the same claim for finish/pr label retries
    # and for a shared MR pending checkpoint. Do not let the durable worker
    # result shadow the marker/MR-only recovery section on every later tick.
    [ "${post_result_claim_retained}" = true ] || continue
  fi

  if [ -z "${post_marker_json}" ]; then
    continue
  fi
  post_completed_at="$(jq -r '.completed_at_epoch' <<<"${post_marker_json}")"
  if [ "${post_completed_at}" -gt "${POST_ACPX_NOW_EPOCH}" ] \
      || [ $((POST_ACPX_NOW_EPOCH - post_completed_at)) \
        -lt "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" ]; then
    continue
  fi

  # The fixed wrapper writes acpx_terminal.json before MR finalization. Once
  # the short post-acpx grace expires, proactively recover a private exact MR
  # marker under the current scheduler claim before asking OpenClaw to kill the
  # stalled child. A kill event is not recovery evidence and may carry an empty
  # or failure-shaped callback, so relying on it would lose an already-merged
  # MR or a pending finish-label retry.
  post_token_sha256="$(printf '%s' "$(jq -r '.claim_token' <<<"${post_job}")" | dlc_sha256)" \
    || tick_die "unable to hash post-acpx claim fence"
  post_recovery_handled=false
  post_auto_merge="$(jq -r '.auto_merge // false' <<<"${post_pending}")"
  post_shared_branch="$(jq -r '
    (.work_branch | type == "string"
      and test("^issue/[1-9][0-9]*\\+[1-9][0-9]*$"))
    and (.branch_members | type == "array" and length == 2)
    and (.shared_branch_role == "head" or .shared_branch_role == "tail")
  ' <<<"${post_pending}")"
  if [ "${post_shared_branch}" = true ]; then
    post_issue_state_file="${post_repo}/.req_executor/issues/issue-${post_iid}/state.json"
    post_attempt_state_file="${post_repo}/.req_executor/issues/issue-${post_iid}/attempt_state.json"
    post_shared_checkpoint=""
    if post_shared_checkpoint="$(post_acpx_shared_mr_checkpoint \
        "${post_pending}" "${post_issue_state_file}" \
        "${post_attempt_state_file}" "${post_iid}" "${post_attempt}" \
        "${post_work_branch}")" \
        && ! post_acpx_shared_mr_marker_ready "${post_log_dir}/mr_result.json" \
          "${post_pending}" "${post_shared_checkpoint}" \
          "${post_iid}" "${post_attempt}"; then
      set +e
      post_shared_recovery_output="$(
        PROJECT="$(jq -r '.slug' <<<"${post_context}")" \
        GROUP="$(jq -r '.group' <<<"${post_context}")" \
        GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
        REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${post_context}")" \
        ISSUE_IID="${post_iid}" ATTEMPT_NUMBER="${post_attempt}" \
        WORK_BRANCH="${post_work_branch}" \
          timeout --kill-after=30s 300s \
            bash "${RECOVER_SHARED_MR_CMD}" 2>/dev/null
      )"
      post_shared_recovery_rc=$?
      set -e
      if [ "${post_shared_recovery_rc}" -eq 0 ] \
          && post_shared_recovery_json="$(jq -ce \
            --argjson iid "${post_iid}" \
            --argjson attempt_number "${post_attempt}" \
            --arg commit_sha "$(jq -r '.commit_sha' \
              <<<"${post_shared_checkpoint}")" \
            --arg shared_role "$(jq -r '.shared_branch_role' \
              <<<"${post_shared_checkpoint}")" \
            --arg intent_id "$(jq -r '.intent_id' \
              <<<"${post_shared_checkpoint}")" '
            if type == "object"
              and (keys | sort) == ([
                "attempt_number","commit_sha","iid","intent_id","merge_request_url",
                "mr_action","status"
              ] | sort)
              and .status == "verified_open"
              and .iid == $iid
              and .attempt_number == $attempt_number
              and ((.commit_sha | ascii_downcase)
                == ($commit_sha | ascii_downcase))
              and .intent_id == $intent_id
              and (.merge_request_url | type == "string"
                and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
              and (if $shared_role == "head"
                then .mr_action == "created" else .mr_action == "reused" end)
            then . else error("invalid shared MR recovery envelope") end
          ' <<<"${post_shared_recovery_output}" 2>/dev/null)"; then
        append_operation "$(jq -cn --arg job_id "${post_job_id}" '{
          operation:"post_acpx_shared_mr_recovery",job_id:$job_id,
          status:"verified_open"
        }')"
      elif [ "${post_shared_recovery_rc}" -ne 0 ]; then
        append_operation "$(jq -cn --arg job_id "${post_job_id}" '{
          operation:"post_acpx_shared_mr_recovery",job_id:$job_id,
          status:"not_ready"
        }')"
      else
        append_operation "$(jq -cn --arg job_id "${post_job_id}" '{
          operation:"post_acpx_shared_mr_recovery",job_id:$job_id,
          status:"failed"
        }')"
        HAD_FAILURE=true
      fi
    fi
  fi
  if [ "${post_auto_merge}" = true ] \
      || [ "${post_shared_branch}" = true ]; then
    set +e
    post_marker_reconcile_output="$(printf '' | \
      PROJECT="$(jq -r '.slug' <<<"${post_context}")" \
      GROUP="$(jq -r '.group' <<<"${post_context}")" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${post_context}")" \
      IID="${post_iid}" DRIVEN_MARKER_RECONCILE=1 \
      DRIVEN_RECONCILE_JOB_ID="${post_job_id}" \
      DRIVEN_RECONCILE_CLAIM_GENERATION="${post_generation}" \
      DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${post_token_sha256}" \
        bash "${EXPIRE_RUNNING_CMD}" 2>/dev/null)"
    post_marker_reconcile_rc=$?
    set -e
    if [ "${post_marker_reconcile_rc}" -eq 0 ] \
        && post_marker_reconcile_json="$(jq -ce \
          --argjson iid "${post_iid}" '
          if type == "object" and .iid == $iid
            and (.callback_status == "handled"
              or .callback_status == "marker_not_ready"
              or .callback_status == "stale_claim"
              or .callback_status == "stale_or_already_drained"
              or .callback_status == "lock_held")
            and (if .callback_status == "handled"
              then (.terminal_status == "done"
                or .terminal_status == "failed"
                or .terminal_status == "blocked")
              else true end)
          then . else error("invalid marker reconcile envelope") end
        ' <<<"${post_marker_reconcile_output}" 2>/dev/null)"; then
      post_marker_reconcile_status="$(jq -r '.callback_status' \
        <<<"${post_marker_reconcile_json}")"
      append_operation "$(jq -cn \
        --arg job_id "${post_job_id}" \
        --arg status "${post_marker_reconcile_status}" \
        --arg terminal_status "$(jq -r '.terminal_status // ""' \
          <<<"${post_marker_reconcile_json}")" '{
          operation:"post_acpx_marker_reconcile",job_id:$job_id,status:$status
        } + (if $terminal_status == "" then {}
             else {terminal_status:$terminal_status} end)')"
      [ "${post_marker_reconcile_status}" != handled ] \
        || post_recovery_handled=true
    else
      append_operation "$(jq -cn --arg job_id "${post_job_id}" '{
        operation:"post_acpx_marker_reconcile",job_id:$job_id,status:"failed"
      }')"
      HAD_FAILURE=true
    fi
  fi

  # cleanup_required is returned before the ordinary expired-running scan
  # below. Perform its claim-fenced timeout reconciliation here once the same
  # scheduler lease is due, otherwise a persistent acpx marker would shadow
  # timeout recovery forever. A handled marker retry (notably finish-label
  # blocked) wins and remains pending for the next marker-only tick.
  post_updated_at="$(jq -r '.updated_at // -1' <<<"${post_job}")"
  if [ "${post_recovery_handled}" != true ] \
      && [[ "${post_updated_at}" =~ ^[0-9]+$ ]] \
      && [ "${POST_ACPX_NOW_EPOCH}" -ge "${post_updated_at}" ] \
      && [ $((POST_ACPX_NOW_EPOCH - post_updated_at)) \
        -ge "${EXECUTOR_RUNNING_LEASE_SECONDS}" ]; then
    set +e
    post_timeout_output="$(printf '' | \
      PROJECT="$(jq -r '.slug' <<<"${post_context}")" \
      GROUP="$(jq -r '.group' <<<"${post_context}")" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${post_context}")" \
      IID="${post_iid}" DRIVEN_TIMEOUT_RECONCILE=1 \
      DRIVEN_TIMEOUT_JOB_ID="${post_job_id}" \
      DRIVEN_TIMEOUT_CLAIM_GENERATION="${post_generation}" \
      DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${post_token_sha256}" \
      DRIVEN_TIMEOUT_NOW_EPOCH="${POST_ACPX_NOW_EPOCH}" \
        bash "${EXPIRE_RUNNING_CMD}" 2>/dev/null)"
    post_timeout_rc=$?
    set -e
    if [ "${post_timeout_rc}" -eq 0 ] \
        && post_timeout_status="$(jq -er '
          .callback_status | select(type == "string" and length > 0)
        ' <<<"${post_timeout_output}" 2>/dev/null)"; then
      append_operation "$(jq -cn \
        --arg job_id "${post_job_id}" --arg status "${post_timeout_status}" '{
        operation:"post_acpx_timeout_reconcile",job_id:$job_id,status:$status
      }')"
    else
      append_operation "$(jq -cn --arg job_id "${post_job_id}" '{
        operation:"post_acpx_timeout_reconcile",job_id:$job_id,status:"failed"
      }')"
      HAD_FAILURE=true
    fi
  fi

  CLEANUP_ACTIONS="$(jq -c \
    --arg target "${post_child_session_key}" \
    --arg job_id "${post_job_id}" \
    --arg run_id "${post_run_id}" \
    --argjson iid "${post_iid}" \
    --argjson attempt_number "${post_attempt}" \
    --argjson claim_generation "${post_generation}" \
    --argjson completed_at_epoch "${post_completed_at}" \
    --argjson grace_seconds "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" '
    . + [{
      action:"kill",target:$target,
      reason:"post_acpx_finalization_grace_exceeded",
      job_id:$job_id,run_id:$run_id,iid:$iid,
      attempt_number:$attempt_number,claim_generation:$claim_generation,
      completed_at_epoch:$completed_at_epoch,grace_seconds:$grace_seconds
    }]
  ' <<<"${CLEANUP_ACTIONS}")"
  append_operation "$(jq -cn \
    --arg job_id "${post_job_id}" \
    --argjson grace_seconds "${EXECUTOR_POST_ACPX_GRACE_SECONDS}" '{
    operation:"post_acpx_watchdog",job_id:$job_id,status:"kill_required",
    grace_seconds:$grace_seconds
  }')"
done < <(jq -c '.[]' <<<"${POST_ACPX_RUNNING_JOBS}")

if [ "$(jq -r 'length' <<<"${CLEANUP_ACTIONS}")" -gt 0 ]; then
  jq -cn \
    --argjson cleanup_actions "${CLEANUP_ACTIONS}" \
    --argjson operation_results "${OPERATIONS}" '{
    status:"cleanup_required",
    spawn_grants:[],
    reconcile_actions:[],
    cleanup_actions:$cleanup_actions,
    operation_results:$operation_results,
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:"executor batch tick recovered or reaped post-acpx subagent stalls"
  }'
  exit 0
fi

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
EXECUTOR_TOPUP_ITEM_LIMIT="${EXECUTOR_TOPUP_ITEM_LIMIT:-256}"
EXECUTOR_REFILL_ROUND_LIMIT="${EXECUTOR_REFILL_ROUND_LIMIT:-32}"
EXECUTOR_TOPUP_PHASE_SECONDS="${EXECUTOR_TOPUP_PHASE_SECONDS:-90}"
case "${EXECUTOR_TOPUP_ITEM_LIMIT}" in
  ''|*[!0-9]*) tick_die "EXECUTOR_TOPUP_ITEM_LIMIT must be an integer" ;;
esac
case "${EXECUTOR_REFILL_ROUND_LIMIT}" in
  ''|*[!0-9]*) tick_die "EXECUTOR_REFILL_ROUND_LIMIT must be an integer" ;;
esac
case "${EXECUTOR_TOPUP_PHASE_SECONDS}" in
  ''|*[!0-9]*) tick_die "EXECUTOR_TOPUP_PHASE_SECONDS must be an integer" ;;
esac
if [ "${EXECUTOR_TOPUP_ITEM_LIMIT}" -lt 1 ] \
    || [ "${EXECUTOR_TOPUP_ITEM_LIMIT}" -gt 256 ]; then
  tick_die "EXECUTOR_TOPUP_ITEM_LIMIT must be between 1 and 256"
fi
if [ "${EXECUTOR_REFILL_ROUND_LIMIT}" -lt 1 ] \
    || [ "${EXECUTOR_REFILL_ROUND_LIMIT}" -gt 32 ]; then
  tick_die "EXECUTOR_REFILL_ROUND_LIMIT must be between 1 and 32"
fi
if [ "${EXECUTOR_TOPUP_PHASE_SECONDS}" -lt 1 ] \
    || [ "${EXECUTOR_TOPUP_PHASE_SECONDS}" -gt 120 ]; then
  tick_die "EXECUTOR_TOPUP_PHASE_SECONDS must be between 1 and 120"
fi
EXECUTOR_TICK_LOCK_FILE="${EXECUTOR_SCHEDULER_ROOT}/executor_batch_tick.lock"
exec {EXECUTOR_TICK_LOCK_FD}>"${EXECUTOR_TICK_LOCK_FILE}"
chmod 600 "${EXECUTOR_TICK_LOCK_FILE}" 2>/dev/null \
  || tick_die "executor tick lock must be private"
if ! flock -n -x "${EXECUTOR_TICK_LOCK_FD}"; then
  jq -cn '{
    status:"idle",
    spawn_grants:[],
    reconcile_actions:[],
    cleanup_actions:[],
    operation_results:[{operation:"tick_lock",status:"held"}],
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:"another executor batch tick owns the topup transaction"
  }'
  exit 0
fi
TOPUP_PHASE_DEADLINE_SECONDS=$((SECONDS + EXECUTOR_TOPUP_PHASE_SECONDS))
TOPUP_ITEMS_PROCESSED=0
REFILL_ROUNDS=0
TOPUP_PHASE_EXHAUSTED=false
TOPUP_BUDGET_RECORDED=false

record_topup_budget() {
  local reason="$1"
  [ "${TOPUP_BUDGET_RECORDED}" = false ] || return 0
  append_operation "$(jq -cn \
    --arg reason "${reason}" \
    --argjson item_limit "${EXECUTOR_TOPUP_ITEM_LIMIT}" \
    --argjson items_processed "${TOPUP_ITEMS_PROCESSED}" \
    --argjson round_limit "${EXECUTOR_REFILL_ROUND_LIMIT}" \
    --argjson refill_rounds "${REFILL_ROUNDS}" '{
      operation:"topup_budget",status:"partial",reason:$reason,
      item_limit:$item_limit,items_processed:$items_processed,
      refill_round_limit:$round_limit,refill_rounds:$refill_rounds
    }')"
  TOPUP_BUDGET_RECORDED=true
}

remaining_topup_seconds() {
  local cap="$1" remaining=0
  remaining=$((TOPUP_PHASE_DEADLINE_SECONDS - SECONDS))
  [ "${remaining}" -gt 0 ] || return 1
  if [ "${remaining}" -gt "${cap}" ]; then
    remaining="${cap}"
  fi
  printf '%s\n' "${remaining}"
}

# Reap only project placeholders whose exact scheduler job is absent from both
# current active_jobs and every unfinished launch coordinator. This runs under
# the agent-wide tick lock, so another tick cannot create a project placeholder
# between the protected-set snapshot and the campaign-lock mutation. A
# scheduler job is always reserved before its project placeholder is created;
# exact job-id protection therefore closes the cross-state observation window.
reap_project_orphan_placeholders() {
  local project="$1" context protected_job_ids action_file action_json
  local project_repo reap_input reap_output reap_rc reap_json reap_timeout
  local lock_timeout context_timeout
  local reap_status reaped_count protected_count unresolved_count
  local -a action_files=()

  if ! context_timeout="$(remaining_topup_seconds 10)"; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    return 2
  fi
  context="$(project_context "${project}" "${context_timeout}")" || return 2
  project_repo="$(jq -r '.repo_path' <<<"${context}")"
  [ -d "${project_repo}/.git" ] || return 0

  if ! lock_timeout="$(remaining_topup_seconds 5)"; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    return 2
  fi
  exec {ORPHAN_SNAPSHOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  if ! flock -w "${lock_timeout}" -x "${ORPHAN_SNAPSHOT_LOCK_FD}"; then
    exec {ORPHAN_SNAPSHOT_LOCK_FD}>&-
    return 2
  fi
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
  if ! reap_timeout="$(remaining_topup_seconds 15)"; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    return 0
  fi
  set +e
  reap_output="$(printf '%s' "${reap_input}" | \
    PROJECT="$(jq -r '.slug' <<<"${context}")" \
    GROUP="$(jq -r '.group' <<<"${context}")" \
    GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
    REPO_PARENT_PATH="$(jq -r '.repo_parent' <<<"${context}")" \
      timeout --kill-after=1s "${reap_timeout}s" \
        bash "${REAP_PLACEHOLDERS_CMD}" 2>/dev/null)"
  reap_rc=$?
  set -e
  if [ "${reap_rc}" -eq 124 ] || [ "${reap_rc}" -eq 137 ]; then
    append_operation "$(jq -cn --arg project "${project}" '{
      operation:"orphan_placeholder_reap",project:$project,status:"timeout"
    }')"
    HAD_FAILURE=true
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget child_timeout
    return 0
  fi
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
  if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    break
  fi
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
  if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    break
  fi
  serial_job_id="$(jq -er '
    if type == "object" and (.job_id | type == "string" and length > 0)
    then .job_id else error("missing job_id") end
  ' "${serial_action_file}")" || tick_die "durable launch action is invalid"
  if ! serial_lock_timeout="$(remaining_topup_seconds 5)" \
      || ! DLC_LOCK_WAIT_SECONDS="${serial_lock_timeout}" \
        dlc_open "${serial_job_id}"; then
    append_operation "$(jq -cn --arg job_id "${serial_job_id}" '{
      operation:"launch_coordinator",job_id:$job_id,status:"lock_timeout"
    }')"
    HAD_FAILURE=true
    SERIAL_LAUNCH_GATE_CLOSED=true
    break
  fi
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
      if ! serial_state_lock_timeout="$(remaining_topup_seconds 5)"; then
        dlc_close
        append_operation "$(jq -cn --arg job_id "${serial_job_id}" '{
          operation:"spawn_reconcile",job_id:$job_id,status:"lock_timeout"
        }')"
        HAD_FAILURE=true
        SERIAL_LAUNCH_GATE_CLOSED=true
        record_topup_budget deadline
        break
      fi
      exec {SERIAL_GATE_STATE_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
      if ! flock -w "${serial_state_lock_timeout}" -x \
          "${SERIAL_GATE_STATE_LOCK_FD}"; then
        exec {SERIAL_GATE_STATE_LOCK_FD}>&-
        dlc_close
        append_operation "$(jq -cn --arg job_id "${serial_job_id}" '{
          operation:"spawn_reconcile",job_id:$job_id,status:"lock_timeout"
        }')"
        HAD_FAILURE=true
        SERIAL_LAUNCH_GATE_CLOSED=true
        break
      fi
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
      cleanup_actions:[],
      operation_results:$operations,
      max_launch_retries:3,
      backoff_seconds:2,
      chat_summary:$chat_summary
    }'
  exit 0
fi

# Phase C: lease recovery + strict round-robin reservation. A hard reserve
# failure is terminal for this tick because no safe grant set exists.
RESERVE_OUTPUT=""
RESERVE_RC=124
if RESERVE_TIMEOUT="$(remaining_topup_seconds 15)"; then
  set +e
  RESERVE_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" \
    timeout --kill-after=1s "${RESERVE_TIMEOUT}s" \
      bash "${RESERVE_CMD}" 2>/dev/null)"
  RESERVE_RC=$?
  set -e
else
  TOPUP_PHASE_EXHAUSTED=true
  record_topup_budget deadline
fi
if [ "${RESERVE_RC}" -ne 0 ] || ! RESERVE_JSON="$(printf '%s' "${RESERVE_OUTPUT}" | jq -ce '
    if type == "object"
      and (.status == "ready" or .status == "idle" or .status == "at_capacity")
      and (.grants | type == "array")
      and (.active_count | type == "number" and . == floor and . >= 0)
      and (.available_slots | type == "number" and . == floor and . >= 0)
      and ((has("max_concurrency") | not)
        or (.max_concurrency | type == "number" and . == floor and . > 0))
    then . else error("invalid reserve envelope") end
  ' 2>/dev/null)"; then
  RESERVE_FAILURE_STATUS=failed
  if [ "${RESERVE_RC}" -eq 124 ] || [ "${RESERVE_RC}" -eq 137 ]; then
    RESERVE_FAILURE_STATUS=timeout
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget child_timeout
  fi
  append_operation "$(jq -cn --arg status "${RESERVE_FAILURE_STATUS}" '{
    operation:"reservation",status:$status
  }')"
  jq -cn --argjson operations "${OPERATIONS}" '{
    status:"tick_failed",spawn_grants:[],reconcile_actions:[],
    cleanup_actions:[],
    operation_results:$operations,
    max_launch_retries:3,backoff_seconds:2,
    chat_summary:"executor reservation failed"
  }'
  exit 0
fi
if [ "$(jq -r 'has("max_concurrency")' <<<"${RESERVE_JSON}")" = true ]; then
  EXECUTOR_MAX_CONCURRENCY="$(jq -r '.max_concurrency' <<<"${RESERVE_JSON}")"
  export EXECUTOR_MAX_CONCURRENCY
fi
append_operation "$(jq -cn --argjson reserve "${RESERVE_JSON}" '{
  operation:"reservation",status:$reserve.status,
  grant_count:($reserve.grants | length),active_count:$reserve.active_count,
  available_slots:$reserve.available_slots
}')"

# Running physical jobs already occupy a global slot. Re-present them to their
# project campaign so a prior blocked/retry terminal can prepare its next
# attempt without consuming a new reservation or creating another physical job.
if ! active_lock_timeout="$(remaining_topup_seconds 5)"; then
  active_lock_timeout=1
  TOPUP_PHASE_EXHAUSTED=true
  record_topup_budget deadline
fi
exec {ACTIVE_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
if ! flock -w "${active_lock_timeout}" -x "${ACTIVE_LOCK_FD}"; then
  exec {ACTIVE_LOCK_FD}>&-
  append_operation "$(jq -cn '{
    operation:"active_continuation_snapshot",status:"lock_timeout"
  }')"
  flock -u "${EXECUTOR_TICK_LOCK_FD}"
  exec {EXECUTOR_TICK_LOCK_FD}>&-
  jq -cn --argjson operations "${OPERATIONS}" '{
    status:"tick_failed",spawn_grants:[],reconcile_actions:[],
    cleanup_actions:[],operation_results:$operations,
    max_launch_retries:3,backoff_seconds:2,
    chat_summary:"executor active-continuation snapshot timed out"
  }'
  exit 0
fi
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
        force_rerun_pr,
        auto_merge,
        merge_target_branch
      }]
' "${SCHEDULER_STATE_FILE}")" || tick_die "active scheduler jobs are invalid"
flock -u "${ACTIVE_LOCK_FD}"
exec {ACTIVE_LOCK_FD}>&-

CANDIDATES_ALL="$(jq -cn \
  --argjson reserved "$(jq -c '.grants' <<<"${RESERVE_JSON}")" \
  --argjson continuations "${ACTIVE_CONTINUATIONS}" '
  reduce ($reserved + $continuations)[] as $grant ([];
    if any(.[]; .job_id == $grant.job_id) then . else . + [$grant] end)
')"
CANDIDATES="$(jq -c --argjson limit "${EXECUTOR_TOPUP_ITEM_LIMIT}" \
  '.[:$limit]' <<<"${CANDIDATES_ALL}")"
TOPUP_ITEMS_PROCESSED="$(jq -r 'length' <<<"${CANDIDATES}")"
if [ "$(jq -r 'length' <<<"${CANDIDATES_ALL}")" \
    -gt "${TOPUP_ITEMS_PROCESSED}" ]; then
  record_topup_budget item_limit
fi

TOPUP_ENTRIES='[]'
SKIPPED_ENTRIES='[]'
DEFERRED_ENTRIES='[]'
PROJECT_PENDING_ENTRIES='[]'
topup_candidate_set() {
  local candidate_set="$1"
  local candidate_projects project project_grants context topup_request
  local topup_output topup_rc topup_json project_pending_iids topup_timeout
  local context_timeout

  candidate_projects="$(jq -c '[.[].project] | unique' <<<"${candidate_set}")"
  while IFS= read -r project; do
    [ -n "${project}" ] || continue
    if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    if ! context_timeout="$(remaining_topup_seconds 10)"; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    project_grants="$(jq -c --arg project "${project}" \
      '[.[] | select(.project == $project)]' <<<"${candidate_set}")"
    context="$(project_context "${project}" "${context_timeout}")" || {
      append_operation "$(jq -cn --arg project "${project}" '{
        operation:"project_topup",project:$project,status:"invalid_project"
      }')"
      HAD_FAILURE=true
      continue
    }
    if ! topup_timeout="$(remaining_topup_seconds 75)"; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    topup_request="$(jq -cn --arg owner_id executor-agent-scheduler-v1 \
      --argjson grants "${project_grants}" '{owner_id:$owner_id,grants:$grants}')"

    set +e
    topup_output="$(printf '%s' "${topup_request}" | \
      CONFIG_DIR="${CONFIG_DIR}" GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" \
      REPO_PARENT_PATH="${REPO_PARENT_BASE}" \
      EXECUTOR_SCHEDULER_ROOT="${EXECUTOR_SCHEDULER_ROOT}" \
      EXECUTOR_MAX_CONCURRENCY="${EXECUTOR_MAX_CONCURRENCY}" \
      EXECUTOR_ACPX_TIMEOUT_SECONDS="${EXECUTOR_ACPX_TIMEOUT_SECONDS:-3600}" \
      EXECUTOR_RUNNING_LEASE_SECONDS="${EXECUTOR_RUNNING_LEASE_SECONDS}" \
      timeout --kill-after=1s "${topup_timeout}s" \
        bash "${TOPUP_CMD}" 2>/dev/null)"
    topup_rc=$?
    set -e
    if [ "${topup_rc}" -eq 124 ] || [ "${topup_rc}" -eq 137 ]; then
      append_operation "$(jq -cn --arg project "${project}" '{
        operation:"project_topup",project:$project,status:"timeout"
      }')"
      HAD_FAILURE=true
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget project_timeout
      break
    fi
    if [ "${topup_rc}" -ne 0 ] || ! topup_json="$(printf '%s' "${topup_output}" | jq -ce \
      --argjson project_grants "${project_grants}" '
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
          and ((.deferred_entries // []) | type == "array")
          and (all((.deferred_entries // [])[];
            type == "object"
            and (keys | sort) == [
              "batch_id","dependency_branch","dependency_iid","iid",
              "job_id","project","reason","snapshot_index","status"
            ]
            and .status == "deferred"
            and (.job_id | type == "string" and length > 0)
            and (.batch_id | type == "string" and length > 0)
            and (.project | type == "string" and length > 0)
            and (.iid | type == "number" and . == floor and . > 0)
            and (. as $deferred
              | (((($deferred.reason == "dependency_preflight_deferred")
                      or ($deferred.reason == "dependency_graph_preflight_deferred")
                      or ($deferred.reason == "dependency_graph_scope_incomplete")
                      or ($deferred.reason == "shared_branch_head_continue_unsupported"))
                    and $deferred.dependency_iid == null
                    and $deferred.dependency_branch == null)
                or (($deferred.dependency_iid | type) == "number"
                  and $deferred.dependency_iid ==
                    ($deferred.dependency_iid | floor)
                  and $deferred.dependency_iid > 0
                  and $deferred.dependency_iid != $deferred.iid
                  and (($deferred.reason == "dependency_not_completed")
                    or ($deferred.reason == "dependency_branch_missing")
                    or ($deferred.reason == "dependency_commit_unverified")
                    or ($deferred.reason == "dependency_not_in_merge_target")
                    or ($deferred.reason == "dependency_cycle_check_deferred"))
                  and (($deferred.dependency_branch ==
                        ("issue/" + ($deferred.dependency_iid | tostring)))
                    or ($deferred.dependency_branch ==
                        ("issue/" + ($deferred.dependency_iid | tostring)
                          + "+" + ($deferred.iid | tostring)))))))
            and (.snapshot_index | type == "number"
              and . == floor and . >= 0)
            and (.reason == "dependency_preflight_deferred"
              or .reason == "dependency_graph_preflight_deferred"
              or .reason == "dependency_graph_scope_incomplete"
              or .reason == "shared_branch_head_continue_unsupported"
              or .reason == "dependency_not_completed"
              or .reason == "dependency_branch_missing"
              or .reason == "dependency_commit_unverified"
              or .reason == "dependency_not_in_merge_target"
              or .reason == "dependency_cycle_check_deferred")
            and (. as $deferred | any($project_grants[];
              .job_id == $deferred.job_id
              and .batch_id == $deferred.batch_id
              and .snapshot_index == $deferred.snapshot_index
              and .project == $deferred.project
              and .iid == $deferred.iid))))
          and (((.dispatch_entries // []) + (.skipped_entries // [])
              + (.deferred_entries // []) | map(.job_id)) as $job_ids
            | (all($job_ids[]; type == "string" and length > 0))
              and (($job_ids | length) == ($job_ids | unique | length)))
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
      --argjson skipped_count "$(jq -r '(.skipped_entries // []) | length' <<<"${topup_json}")" \
      --argjson deferred_count "$(jq -r '(.deferred_entries // []) | length' <<<"${topup_json}")" '{
      operation:"project_topup",project:$project,status:$status,
      dispatch_count:$dispatch_count,skipped_count:$skipped_count,
      deferred_count:$deferred_count
    }')"
    TOPUP_ENTRIES="$(jq -cn \
      --argjson current "${TOPUP_ENTRIES}" \
      --argjson additions "$(jq -c '.dispatch_entries' <<<"${topup_json}")" \
      '$current + $additions')"
    SKIPPED_ENTRIES="$(jq -cn \
      --argjson current "${SKIPPED_ENTRIES}" \
      --argjson additions "$(jq -c '.skipped_entries // []' <<<"${topup_json}")" \
      '$current + $additions')"
    DEFERRED_ENTRIES="$(jq -cn \
      --argjson current "${DEFERRED_ENTRIES}" \
      --argjson additions "$(jq -c '.deferred_entries // []' <<<"${topup_json}")" \
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
  local grant job_id project iid entries entry_count entry action now dlc_timeout
  while IFS= read -r grant; do
    [ -n "${grant}" ] || continue
    if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
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
    if ! dlc_timeout="$(remaining_topup_seconds 5)" \
        || ! DLC_LOCK_WAIT_SECONDS="${dlc_timeout}" dlc_open "${job_id}"; then
      append_operation "$(jq -cn --arg job_id "${job_id}" '{
        operation:"launch_coordinator",job_id:$job_id,status:"lock_timeout"
      }')"
      HAD_FAILURE=true
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget lock_timeout
      break
    fi
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
  local completion_output completion_rc completion_json completion_timeout
  local completion_lock_timeout context_timeout

  if ! completion_lock_timeout="$(remaining_topup_seconds 5)"; then
    jq -cn '{status:"deadline"}'
    return 0
  fi
  exec {COMPLETION_SNAPSHOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  if ! flock -w "${completion_lock_timeout}" -x \
      "${COMPLETION_SNAPSHOT_LOCK_FD}"; then
    exec {COMPLETION_SNAPSHOT_LOCK_FD}>&-
    jq -cn '{status:"lock_held"}'
    return 0
  fi
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
  if ! context_timeout="$(remaining_topup_seconds 10)"; then
    jq -cn '{status:"deadline"}'
    return 0
  fi
  context="$(project_context "${project}" "${context_timeout}")" || return 2

  if ! completion_timeout="$(remaining_topup_seconds 15)"; then
    jq -cn '{status:"deadline"}'
    return 0
  fi

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
      timeout --kill-after=1s "${completion_timeout}s" \
        bash "${EXPIRE_RUNNING_CMD}" 2>/dev/null)"
  completion_rc=$?
  set -e
  if [ "${completion_rc}" -eq 124 ] || [ "${completion_rc}" -eq 137 ]; then
    jq -cn '{status:"timeout"}'
    return 0
  fi
  if [ "${completion_rc}" -ne 0 ] || ! completion_json="$(printf '%s' "${completion_output}" | jq -ce \
      --argjson iid "${iid}" '
      if type == "object"
        and .iid == $iid
        and (.callback_status == "handled"
          or .callback_status == "marker_not_ready"
          or .callback_status == "not_completed"
          or .callback_status == "stale_claim"
          or .callback_status == "stale_or_already_drained"
          or .callback_status == "lock_held")
        and (if .callback_status == "handled"
          then (.terminal_status == "skipped"
            or .terminal_status == "done"
            or .terminal_status == "failed"
            or .terminal_status == "blocked")
          else true end)
      then . else error("invalid completion reconcile envelope") end
    ' 2>/dev/null)"; then
    jq -cn '{status:"failed"}'
    return 0
  fi

  jq -cn \
    --arg status "$(jq -r '.callback_status' <<<"${completion_json}")" \
    --arg terminal_status "$(jq -r '.terminal_status // ""' <<<"${completion_json}")" \
    --argjson claim_generation "${claim_generation}" '{
    status:$status,
    claim_generation:$claim_generation
  } + (if $terminal_status == "" then {}
       else {terminal_status:$terminal_status} end)'
}

# Every live-preflight skip is terminalized through its exact scheduler claim:
# claim-0 for a fresh reservation, or a claim-fenced project handoff for a
# running continuation. This guarantees zero new spawn for skips and releases
# slots before actionable claims are emitted.
import_candidate_skips() {
  local candidate_set="$1"
  local grant job_id project iid skipped skipped_count skip_output skip_rc skip_status
  local completion_result completion_status completion_terminal_status skip_timeout
  LAST_IMPORTED_SKIP_COUNT=0
  while IFS= read -r grant; do
    [ -n "${grant}" ] || continue
    if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
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
            completion_terminal_status="$(jq -r '.terminal_status' \
              <<<"${completion_result}")"
            if [ "${completion_terminal_status}" = blocked ]; then
              append_operation "$(jq -cn \
                --arg job_id "${job_id}" \
                --argjson claim_generation \
                  "$(jq -r '.claim_generation' <<<"${completion_result}")" '{
                operation:"running_preflight_skip",
                job_id:$job_id,
                status:"marker_retry_pending",
                terminal_status:"blocked",
                claim_generation:$claim_generation
              }')"
            else
              append_operation "$(jq -cn \
                --arg job_id "${job_id}" \
                --arg terminal_status "${completion_terminal_status}" \
                --argjson claim_generation \
                  "$(jq -r '.claim_generation' <<<"${completion_result}")" '{
                operation:"running_preflight_skip",
                job_id:$job_id,
                status:"handoff_recorded",
                terminal_status:$terminal_status,
                claim_generation:$claim_generation
              }')"
              LAST_IMPORTED_SKIP_COUNT=$((LAST_IMPORTED_SKIP_COUNT + 1))
            fi
            ;;
          marker_not_ready|not_completed|stale_claim|stale_or_already_drained|lock_held|stale_scheduler)
            append_operation "$(jq -cn \
              --arg job_id "${job_id}" \
              --arg status "${completion_status}" '{
              operation:"running_preflight_skip",job_id:$job_id,status:$status
            }')"
            ;;
          deadline|timeout)
            append_operation "$(jq -cn \
              --arg job_id "${job_id}" \
              --arg status "${completion_status}" '{
              operation:"running_preflight_skip",job_id:$job_id,status:$status
            }')"
            HAD_FAILURE=true
            TOPUP_PHASE_EXHAUSTED=true
            record_topup_budget child_timeout
            break
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
    if ! skip_timeout="$(remaining_topup_seconds 15)"; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    set +e
    skip_output="$(printf '%s' "$(jq -c '.[0]' <<<"${skipped}")" | \
      CONFIG_DIR="${CONFIG_DIR}" \
      timeout --kill-after=1s "${skip_timeout}s" \
        bash "${IMPORT_SKIP_CMD}" 2>/dev/null)"
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
      skip_failure_status=failed
      if [ "${skip_rc}" -eq 124 ] || [ "${skip_rc}" -eq 137 ]; then
        skip_failure_status=timeout
        TOPUP_PHASE_EXHAUSTED=true
        record_topup_budget child_timeout
      fi
      append_operation "$(jq -cn --arg job_id "${job_id}" \
        --arg status "${skip_failure_status}" '{
        operation:"synthetic_skip",job_id:$job_id,status:$status
      }')"
      HAD_FAILURE=true
      [ "${TOPUP_PHASE_EXHAUSTED}" = false ] || break
    fi
  done < <(jq -c '.[]' <<<"${candidate_set}")
}

import_candidate_skips "${CANDIDATES}"

# A successful synthetic terminal frees a physical slot immediately. Re-run
# the strict scheduler reservation and project preflight in the same tick until
# a refill round contains no further skip. The outer deadline, round cap, and
# item cap keep this agent-wide lock independent of the total batch size;
# unprocessed reserved jobs are safely re-emitted on the next tick. Novel-job
# checking still prevents a broken importer/reserver pair from spinning on the
# same grant forever.
while [ "${LAST_IMPORTED_SKIP_COUNT}" -gt 0 ]; do
  if [ "${TOPUP_PHASE_EXHAUSTED}" = true ]; then
    break
  fi
  if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    break
  fi
  if [ "${REFILL_ROUNDS}" -ge "${EXECUTOR_REFILL_ROUND_LIMIT}" ]; then
    record_topup_budget refill_round_limit
    break
  fi
  if [ "${TOPUP_ITEMS_PROCESSED}" -ge "${EXECUTOR_TOPUP_ITEM_LIMIT}" ]; then
    record_topup_budget item_limit
    break
  fi
  REFILL_ROUNDS=$((REFILL_ROUNDS + 1))
  if ! REFILL_TIMEOUT="$(remaining_topup_seconds 15)"; then
    TOPUP_PHASE_EXHAUSTED=true
    record_topup_budget deadline
    break
  fi
  set +e
  REFILL_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" \
    timeout --kill-after=1s "${REFILL_TIMEOUT}s" \
      bash "${RESERVE_CMD}" 2>/dev/null)"
  REFILL_RC=$?
  set -e
  if [ "${REFILL_RC}" -ne 0 ] || ! REFILL_JSON="$(printf '%s' "${REFILL_OUTPUT}" | jq -ce '
      if type == "object"
        and (.status == "ready" or .status == "idle" or .status == "at_capacity")
        and (.grants | type == "array")
        and (.active_count | type == "number" and . == floor and . >= 0)
        and (.available_slots | type == "number" and . == floor and . >= 0)
        and ((has("max_concurrency") | not)
          or (.max_concurrency | type == "number" and . == floor and . > 0))
      then . else error("invalid refill envelope") end
    ' 2>/dev/null)"; then
    REFILL_FAILURE_STATUS=refill_failed
    if [ "${REFILL_RC}" -eq 124 ] || [ "${REFILL_RC}" -eq 137 ]; then
      REFILL_FAILURE_STATUS=refill_timeout
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget child_timeout
    fi
    append_operation "$(jq -cn --arg status "${REFILL_FAILURE_STATUS}" '{
      operation:"reservation",status:$status
    }')"
    HAD_FAILURE=true
    break
  fi
  if [ "$(jq -r 'has("max_concurrency")' <<<"${REFILL_JSON}")" = true ]; then
    EXECUTOR_MAX_CONCURRENCY="$(jq -r '.max_concurrency' <<<"${REFILL_JSON}")"
    export EXECUTOR_MAX_CONCURRENCY
  fi
  append_operation "$(jq -cn --argjson reserve "${REFILL_JSON}" '{
    operation:"reservation",status:$reserve.status,
    grant_count:($reserve.grants | length),active_count:$reserve.active_count,
    available_slots:$reserve.available_slots
  }')"
  REFILL_GRANTS="$(jq -c '.grants' <<<"${REFILL_JSON}")"
  [ "$(jq -r 'length' <<<"${REFILL_GRANTS}")" -gt 0 ] || break
  NOVEL_REFILL_GRANTS_ALL="$(jq -cn \
    --argjson existing "${CANDIDATES}" \
    --argjson refill "${REFILL_GRANTS}" '
    [$refill[] | select(.job_id as $job_id
      | any($existing[]; .job_id == $job_id) | not)]
  ')"
  if [ "$(jq -r 'length' <<<"${NOVEL_REFILL_GRANTS_ALL}")" -eq 0 ]; then
    append_operation "$(jq -cn '{operation:"reservation",status:"duplicate_refill"}')"
    HAD_FAILURE=true
    break
  fi
  REFILL_ITEM_REMAINING=$((EXECUTOR_TOPUP_ITEM_LIMIT - TOPUP_ITEMS_PROCESSED))
  NOVEL_REFILL_GRANTS="$(jq -c \
    --argjson limit "${REFILL_ITEM_REMAINING}" \
    '.[:$limit]' <<<"${NOVEL_REFILL_GRANTS_ALL}")"
  NOVEL_REFILL_COUNT="$(jq -r 'length' <<<"${NOVEL_REFILL_GRANTS}")"
  TOPUP_ITEMS_PROCESSED=$((TOPUP_ITEMS_PROCESSED + NOVEL_REFILL_COUNT))
  if [ "$(jq -r 'length' <<<"${NOVEL_REFILL_GRANTS_ALL}")" \
      -gt "${NOVEL_REFILL_COUNT}" ]; then
    record_topup_budget item_limit
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

# Dependency waiting is non-terminal workflow ordering. Release its physical
# scheduler job only after skip refills are complete, so the newly free slot is
# not immediately re-reserved by the same tick. record_driven_batch_launch.sh
# atomically parks every membership in retry_wait and deletes the active job;
# deferred retries receive a new job-id generation when reserved later.
release_dependency_deferrals() {
  local deferred job_id project iid dependency_iid reason current_job
  local job_status claim_generation claim_token record_output record_rc
  local defer_status record_timeout defer_lock_timeout

  while IFS= read -r deferred; do
    [ -n "${deferred}" ] || continue
    if [ "${SECONDS}" -ge "${TOPUP_PHASE_DEADLINE_SECONDS}" ]; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    job_id="$(jq -r '.job_id' <<<"${deferred}")"
    project="$(jq -r '.project' <<<"${deferred}")"
    iid="$(jq -r '.iid' <<<"${deferred}")"
    dependency_iid="$(jq -r '.dependency_iid' <<<"${deferred}")"
    reason="$(jq -r '.reason' <<<"${deferred}")"

    if ! defer_lock_timeout="$(remaining_topup_seconds 5)"; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    exec {DEFER_SNAPSHOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
    if ! flock -w "${defer_lock_timeout}" -x "${DEFER_SNAPSHOT_LOCK_FD}"; then
      exec {DEFER_SNAPSHOT_LOCK_FD}>&-
      append_operation "$(jq -cn \
        --arg job_id "${job_id}" --arg project "${project}" \
        --argjson iid "${iid}" --argjson dependency_iid "${dependency_iid}" \
        --arg reason "${reason}" '{
        operation:"dependency_defer",job_id:$job_id,project:$project,
        iid:$iid,dependency_iid:$dependency_iid,reason:$reason,
        status:"lock_timeout"
      }')"
      HAD_FAILURE=true
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget lock_timeout
      break
    fi
    current_job="$(jq -c --arg job_id "${job_id}" \
      '.active_jobs[$job_id] // null' "${SCHEDULER_STATE_FILE}")"
    flock -u "${DEFER_SNAPSHOT_LOCK_FD}"
    exec {DEFER_SNAPSHOT_LOCK_FD}>&-

    if ! jq -e \
        --arg job_id "${job_id}" \
        --arg project "${project}" \
        --argjson iid "${iid}" '
        type == "object"
        and .job_id == $job_id
        and .project == $project
        and .iid == $iid
        and (.status == "reserved" or .status == "running")
        and (.finalization // null) == null
        and (.claim_generation | type == "number" and . == floor and . >= 0)
        and ((.claim_token == null)
          or (.claim_token | type == "string" and length > 0))
      ' <<<"${current_job}" >/dev/null; then
      append_operation "$(jq -cn \
        --arg job_id "${job_id}" --arg project "${project}" \
        --argjson iid "${iid}" --argjson dependency_iid "${dependency_iid}" \
        --arg reason "${reason}" '{
        operation:"dependency_defer",job_id:$job_id,project:$project,
        iid:$iid,dependency_iid:$dependency_iid,reason:$reason,
        status:"stale_scheduler"
      }')"
      HAD_FAILURE=true
      continue
    fi

    job_status="$(jq -r '.status' <<<"${current_job}")"
    claim_generation="$(jq -r '.claim_generation' <<<"${current_job}")"
    claim_token="$(jq -r '.claim_token // empty' <<<"${current_job}")"
    if [ "${job_status}" = running ] \
        && [ "${claim_generation}" -eq 0 ] \
        && [ -z "${claim_token}" ]; then
      # A migrated legacy running job has no secret claim fence. It may only
      # be terminally reconciled by the legacy recovery path; never weaken the
      # CAS contract to make a new non-terminal dependency deferral succeed.
      append_operation "$(jq -cn \
        --arg job_id "${job_id}" --arg project "${project}" \
        --argjson iid "${iid}" --argjson dependency_iid "${dependency_iid}" \
        --arg reason "${reason}" '{
        operation:"dependency_defer",job_id:$job_id,project:$project,
        iid:$iid,dependency_iid:$dependency_iid,reason:$reason,
        status:"legacy_running_recovery_required"
      }')"
      HAD_FAILURE=true
      continue
    fi
    if ! record_timeout="$(remaining_topup_seconds 15)"; then
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget deadline
      break
    fi
    set +e
    if [ "${job_status}" = running ]; then
      record_output="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${job_id}" \
        ACTION=dependency_deferred \
        CLAIM_GENERATION="${claim_generation}" CLAIM_TOKEN="${claim_token}" \
        timeout --kill-after=1s "${record_timeout}s" \
          bash "${RECORD_LAUNCH_CMD}" 2>/dev/null)"
      record_rc=$?
    elif [ "${claim_generation}" -gt 0 ]; then
      # A recovered preparing lease is reserved and tokenless but keeps its
      # positive generation. Pass that exact fence so the recorder can reject
      # a stale snapshot if another claim transition wins the scheduler lock.
      record_output="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${job_id}" \
        ACTION=dependency_deferred \
        CLAIM_GENERATION="${claim_generation}" \
        timeout --kill-after=1s "${record_timeout}s" \
          bash "${RECORD_LAUNCH_CMD}" 2>/dev/null)"
      record_rc=$?
    else
      record_output="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${job_id}" \
        ACTION=dependency_deferred \
        timeout --kill-after=1s "${record_timeout}s" \
          bash "${RECORD_LAUNCH_CMD}" 2>/dev/null)"
      record_rc=$?
    fi
    set -e
    if [ "${record_rc}" -eq 0 ] \
        && printf '%s' "${record_output}" | jq -e '
          type == "object"
          and .status == "recorded"
          and .job_status == "retry_wait"
          and .should_spawn == false
          and .claim_generation == null
          and .claim_token == null
        ' >/dev/null 2>&1; then
      defer_status="released"
    else
      defer_status="failed"
      HAD_FAILURE=true
    fi
    if [ "${record_rc}" -eq 124 ] || [ "${record_rc}" -eq 137 ]; then
      defer_status="timeout"
      TOPUP_PHASE_EXHAUSTED=true
      record_topup_budget child_timeout
    fi
    append_operation "$(jq -cn \
      --arg job_id "${job_id}" --arg project "${project}" \
      --argjson iid "${iid}" --argjson dependency_iid "${dependency_iid}" \
      --arg reason "${reason}" --arg status "${defer_status}" '{
      operation:"dependency_defer",job_id:$job_id,project:$project,
      iid:$iid,dependency_iid:$dependency_iid,reason:$reason,status:$status
    }')"
    [ "${TOPUP_PHASE_EXHAUSTED}" = false ] || break
  done < <(jq -c '.[]' <<<"${DEFERRED_ENTRIES}")
}

release_dependency_deferrals

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

  if jq -e --arg job_id "${job_id}" \
      'any(.[]; .job_id == $job_id)' <<<"${DEFERRED_ENTRIES}" >/dev/null; then
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
  --argjson cleanup_actions "${CLEANUP_ACTIONS}" \
  --argjson operation_results "${OPERATIONS}" \
  --arg chat_summary "${CHAT_SUMMARY}" '{
    status:$status,
    spawn_grants:$spawn_grants,
    reconcile_actions:$reconcile_actions,
    cleanup_actions:$cleanup_actions,
    operation_results:$operation_results,
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:$chat_summary
  }'
