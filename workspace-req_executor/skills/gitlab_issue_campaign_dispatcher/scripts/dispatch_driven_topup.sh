#!/usr/bin/env bash
# Convert agent-scheduler grants into one project-campaign driven topup tick.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
REPO_PARENT_ENV_SET="${REPO_PARENT_PATH+x}"
REPO_PARENT_ENV_VALUE="${REPO_PARENT_PATH:-}"
SCHEDULER_ROOT_ENV_SET="${EXECUTOR_SCHEDULER_ROOT+x}"
SCHEDULER_ROOT_ENV_VALUE="${EXECUTOR_SCHEDULER_ROOT:-}"
MAX_CONCURRENCY_ENV_SET="${EXECUTOR_MAX_CONCURRENCY+x}"
MAX_CONCURRENCY_ENV_VALUE="${EXECUTOR_MAX_CONCURRENCY:-}"
ISSUES_PER_REPOSITORY_ENV_SET="${EXECUTOR_MAX_ISSUES_PER_REPOSITORY+x}"
ISSUES_PER_REPOSITORY_ENV_VALUE="${EXECUTOR_MAX_ISSUES_PER_REPOSITORY:-}"
ACPX_TIMEOUT_ENV_SET="${EXECUTOR_ACPX_TIMEOUT_SECONDS+x}"
ACPX_TIMEOUT_ENV_VALUE="${EXECUTOR_ACPX_TIMEOUT_SECONDS:-}"
RUNNING_LEASE_ENV_SET="${EXECUTOR_RUNNING_LEASE_SECONDS+x}"
RUNNING_LEASE_ENV_VALUE="${EXECUTOR_RUNNING_LEASE_SECONDS:-}"
EXECUTOR_AGENT_ENV_SET="${EXECUTOR_AGENT+x}"
EXECUTOR_AGENT_ENV_VALUE="${EXECUTOR_AGENT:-}"
CALLBACK_TARGET_ENV_SET="${DISPATCHER_CALLBACK_TARGET+x}"
CALLBACK_TARGET_ENV_VALUE="${DISPATCHER_CALLBACK_TARGET:-}"
LOCK_COMPAT_ENV_SET="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS+x}"
LOCK_COMPAT_ENV_VALUE="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS:-}"

die() {
  echo "dispatch_driven_topup.sh: $*" >&2
  exit 2
}

REQUEST_RAW="$(cat)"
if ! REQUEST_JSON="$(printf '%s' "${REQUEST_RAW}" | jq -ce '
  def clean_string:
    type == "string" and length > 0
    and (explode | all(. >= 32 and . != 127));
  def exact_keys($wanted): (keys | sort) == ($wanted | sort);
  if type == "object" and ((.grants | type) == "array") then
    .grants |= map(
      if type == "object" then
        (if has("auto_merge") then . else .auto_merge = false end
        | if has("merge_target_branch") then . else .merge_target_branch = null end)
      else . end)
  else . end
  |
  if type != "object"
     or (exact_keys(["owner_id","grants"]) | not)
     or (.owner_id | clean_string | not)
     or ((.grants | type) != "array")
     or ((.grants | length) == 0)
     or (all(.grants[];
          type == "object"
          and exact_keys(["job_id","batch_id","snapshot_index","project","iid","branch","entry_mode","force_rerun_pr","auto_merge","merge_target_branch"])
          and (.job_id | clean_string)
          and (.batch_id | clean_string)
          and (.project | clean_string)
          and (.branch == null or (.branch | clean_string))
          and (.snapshot_index | type == "number" and . == floor and . >= 0)
          and (.iid | type == "number" and . == floor and . >= 1)
          and (.entry_mode == "auto" or .entry_mode == "fresh" or .entry_mode == "continue")
          and (.force_rerun_pr | type == "boolean")
          and (.auto_merge | type == "boolean")
          and (.merge_target_branch == null or (.merge_target_branch | clean_string))
          and (.auto_merge == false or (.merge_target_branch | clean_string))) | not)
     or ([.grants[].project] | unique | length != 1)
     or ([.grants[] | [.project,.iid]] | group_by(.) | any(length > 1))
     or ([.grants[].job_id] | group_by(.) | any(length > 1))
     or ([.grants[] | [.batch_id,.snapshot_index]] | group_by(.) | any(length > 1))
  then error("invalid driven topup request") else . end
' 2>/dev/null)"; then
  die "stdin must be strict {owner_id,grants} JSON with unique physical, job, and membership identities"
fi

PROJECT_FULL="$(printf '%s' "${REQUEST_JSON}" | jq -r '.grants[0].project')"
if ! [[ "${PROJECT_FULL}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  die "grant project must contain at least two safe path segments"
fi
IFS='/' read -r -a PROJECT_SEGMENTS <<<"${PROJECT_FULL}"
for segment in "${PROJECT_SEGMENTS[@]}"; do
  case "${segment}" in .|..) die "grant project must not contain dot segments" ;; esac
done
GROUP_EFF="${PROJECT_FULL%/*}"
PROJECT_SLUG="${PROJECT_FULL##*/}"

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*'`'*|*"'"*|*'"'*|*'<'*|*'>'*|*'!'*|*" "*|*$'\t'*|*$'\r'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ]
}
while IFS= read -r branch; do
  validate_branch_name "${branch}" || die "grant branch is not a safe Git ref name"
done < <(printf '%s' "${REQUEST_JSON}" | jq -r '.grants[] | select(.branch != null) | .branch')
while IFS= read -r merge_target_branch; do
  validate_branch_name "${merge_target_branch}" \
    || die "grant merge_target_branch is not a safe Git ref name"
done < <(printf '%s' "${REQUEST_JSON}" | jq -r \
  '.grants[] | select(.merge_target_branch != null) | .merge_target_branch')

[ -f "${CONFIG_DIR}/gitlab.env" ] \
  || die "missing config/gitlab.env at ${CONFIG_DIR}/gitlab.env"
[ -f "${CONFIG_DIR}/campaign_defaults.env" ] \
  || die "missing config/campaign_defaults.env at ${CONFIG_DIR}/campaign_defaults.env"
# Resolve the GitLab tuple before campaign defaults can mix tracked and local
# fields. This source-only mode performs no network I/O.
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
if [ "${REPO_PARENT_ENV_SET}" = x ]; then
  REPO_PARENT_PATH="${REPO_PARENT_ENV_VALUE}"
fi
if [ "${SCHEDULER_ROOT_ENV_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT_ENV_VALUE}"
fi
if [ "${MAX_CONCURRENCY_ENV_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${MAX_CONCURRENCY_ENV_VALUE}"
fi
if [ "${ISSUES_PER_REPOSITORY_ENV_SET}" = x ]; then
  EXECUTOR_MAX_ISSUES_PER_REPOSITORY="${ISSUES_PER_REPOSITORY_ENV_VALUE}"
fi
if [ "${ACPX_TIMEOUT_ENV_SET}" = x ]; then
  EXECUTOR_ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_ENV_VALUE}"
fi
if [ "${RUNNING_LEASE_ENV_SET}" = x ]; then
  EXECUTOR_RUNNING_LEASE_SECONDS="${RUNNING_LEASE_ENV_VALUE}"
fi
if [ "${EXECUTOR_AGENT_ENV_SET}" = x ]; then
  EXECUTOR_AGENT="${EXECUTOR_AGENT_ENV_VALUE}"
fi
if [ "${CALLBACK_TARGET_ENV_SET}" = x ]; then
  DISPATCHER_CALLBACK_TARGET="${CALLBACK_TARGET_ENV_VALUE}"
fi
if [ "${LOCK_COMPAT_ENV_SET}" = x ]; then
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS="${LOCK_COMPAT_ENV_VALUE}"
fi

GITLAB_HOST="${GITLAB_HOST_RESOLVED}"
GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_RESOLVED}"
GITLAB_TOKEN_EFF="${GITLAB_TOKEN_RESOLVED}"
case "${GITLAB_TOKEN_EFF}" in
  '') die "GITLAB_TOKEN is required from process env or config/gitlab.env" ;;
  *[[:cntrl:]]*) die "GITLAB_TOKEN must not contain control characters" ;;
esac
: "${GITLAB_HOST:?dispatch_driven_topup.sh: GITLAB_HOST missing from gitlab.env}"
: "${GITLAB_API_PROTOCOL:?dispatch_driven_topup.sh: GITLAB_API_PROTOCOL missing from gitlab.env}"
REPO_PARENT_EFF="${REPO_PARENT_PATH:-/data}"
MAX_CONCURRENT_EFF="${EXECUTOR_MAX_CONCURRENCY:-10}"
case "${MAX_CONCURRENT_EFF}" in
  ''|*[!0-9]*) die "EXECUTOR_MAX_CONCURRENCY must be a positive integer" ;;
esac
[ "${MAX_CONCURRENT_EFF}" -ge 1 ] || die "EXECUTOR_MAX_CONCURRENCY must be >= 1"
ACPX_TIMEOUT_EFF="${EXECUTOR_ACPX_TIMEOUT_SECONDS:-3600}"
case "${ACPX_TIMEOUT_EFF}" in
  ''|*[!0-9]*) die "EXECUTOR_ACPX_TIMEOUT_SECONDS must be an integer between 60 and 18000" ;;
esac
if [ "${ACPX_TIMEOUT_EFF}" -lt 60 ] || [ "${ACPX_TIMEOUT_EFF}" -gt 18000 ]; then
  die "EXECUTOR_ACPX_TIMEOUT_SECONDS must be between 60 and 18000"
fi
GRANT_COUNT="$(printf '%s' "${REQUEST_JSON}" | jq -r '.grants | length')"
# Runtime ceilings are enforced by the agent scheduler before this wrapper.
# Project campaign capacity comes only from the exact authorized grant set, so
# `/slot` cannot leak into repository-local concurrency and `/repo-slot` cannot
# authorize work that the scheduler did not grant. A shrink may still supply a
# larger started set temporarily so those claims can drain/reconcile safely.
PROJECT_GRANT_CAPACITY="${GRANT_COUNT}"

if ! RESOLVED_REPO_PATH="$(
  PROJECT_FULL="${PROJECT_FULL}" \
  REPO_PARENT_PATH="${REPO_PARENT_EFF}" \
  GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
  GITLAB_HOST="${GITLAB_HOST}" \
  bash "${SCRIPT_DIR}/resolve_driven_repo_path.sh"
)"; then
  die "unable to resolve a safe clone path for ${PROJECT_FULL}"
fi
REPO_PARENT_EFF="${RESOLVED_REPO_PATH%/*}"

IID_CSV="$(printf '%s' "${REQUEST_JSON}" | jq -r '[.grants[].iid] | map(tostring) | join(",")')"
IID_MIN="$(printf '%s' "${REQUEST_JSON}" | jq -r '[.grants[].iid] | min')"
IID_MAX="$(printf '%s' "${REQUEST_JSON}" | jq -r '[.grants[].iid] | max')"

# Dependency branch planning needs the complete immutable membership of each
# represented batch, not merely the IIDs that won a repository slot this round.
# Keep this planning scope separate from issue_iids: only grants are executable.
# A bounded scope preserves the scheduler's small-topup contract; a dependent
# encountered in a larger/incomplete scope fails closed in the project layer.
DEPENDENCY_SCOPE_MAX_IIDS="${DEPENDENCY_SCOPE_MAX_IIDS:-200}"
EXECUTOR_SCHEDULER_ROOT="${EXECUTOR_SCHEDULER_ROOT:-/data/req_executor/_scheduler}"
BATCHES_ROOT="${BATCHES_ROOT:-${EXECUTOR_SCHEDULER_ROOT}/batches}"
case "${DEPENDENCY_SCOPE_MAX_IIDS}" in
  ''|*[!0-9]*) die "DEPENDENCY_SCOPE_MAX_IIDS must be a positive integer" ;;
esac
[ "${DEPENDENCY_SCOPE_MAX_IIDS}" -ge 1 ] \
  || die "DEPENDENCY_SCOPE_MAX_IIDS must be >= 1"
DEPENDENCY_SCOPES_JSON='[]'
while IFS= read -r dependency_batch_id; do
  [[ "${dependency_batch_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
    || die "grant batch_id is not a safe path component"
  dependency_snapshot_file="${BATCHES_ROOT}/${dependency_batch_id}/snapshot.json"
  [ -f "${dependency_snapshot_file}" ] && [ ! -L "${dependency_snapshot_file}" ] \
    || die "dependency planning snapshot is missing for batch ${dependency_batch_id}"
  if ! dependency_snapshot="$(jq -ce \
      --arg project "${PROJECT_FULL}" '
      if type == "object" and .version == 1 and .project == $project
        and (.iids | type == "array" and length > 0)
        and (all(.iids[]; type == "number" and . == floor and . > 0))
        and ((.iids | length) == (.iids | unique | length))
      then . else error("invalid dependency planning snapshot") end
    ' "${dependency_snapshot_file}" 2>/dev/null)"; then
    die "dependency planning snapshot is invalid for batch ${dependency_batch_id}"
  fi
  dependency_scope_count="$(jq -r '.iids | length' <<<"${dependency_snapshot}")"
  dependency_scope_complete=true
  dependency_scope_iids="$(jq -c '.iids' <<<"${dependency_snapshot}")"
  if [ "${dependency_scope_count}" -gt "${DEPENDENCY_SCOPE_MAX_IIDS}" ]; then
    dependency_scope_complete=false
    dependency_scope_iids="$(printf '%s' "${REQUEST_JSON}" | jq -c \
      --arg batch_id "${dependency_batch_id}" \
      '[.grants[] | select(.batch_id == $batch_id) | .iid] | unique | sort')"
  fi
  DEPENDENCY_SCOPES_JSON="$(printf '%s' "${DEPENDENCY_SCOPES_JSON}" | jq -c \
    --arg scope_id "${dependency_batch_id}" \
    --argjson complete "${dependency_scope_complete}" \
    --argjson iids "${dependency_scope_iids}" \
    '. + [{scope_id:$scope_id,complete:$complete,iids:$iids}]')"
done < <(printf '%s' "${REQUEST_JSON}" | jq -r '.grants[].batch_id' | sort -u)

export PROJECT="${PROJECT_SLUG}"
export GROUP="${GROUP_EFF}"
export GITLAB_TOKEN="${GITLAB_TOKEN_EFF}"
export GITLAB_HOST GITLAB_API_PROTOCOL
export REPO_PARENT_PATH="${REPO_PARENT_EFF}"
export EXECUTOR_SCHEDULER_ROOT EXECUTOR_MAX_CONCURRENCY
export EXECUTOR_MAX_ISSUES_PER_REPOSITORY
export EXECUTOR_ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_EFF}"
export EXECUTOR_RUNNING_LEASE_SECONDS EXECUTOR_AGENT
export DISPATCHER_CALLBACK_TARGET DRIVEN_LEGACY_LOCK_COMPAT_SECONDS

TRIGGER="$(cat <<EOF
RUN_SCHEDULED_ISSUE_CAMPAIGN
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
dispatch_mode=driven_topup
driven_request_json=${REQUEST_JSON}
dependency_scopes_json=${DEPENDENCY_SCOPES_JSON}
project=${PROJECT_SLUG}
group=${GROUP_EFF}
issue_iids=${IID_CSV}
issue_min_iid=${IID_MIN}
issue_max_iid=${IID_MAX}
hourly_issue_quota=${PROJECT_GRANT_CAPACITY}
max_concurrent_subagents=${PROJECT_GRANT_CAPACITY}
max_runtime_minutes=300
blocked_retry_limit=3
blocked_cooldown_ticks=1
acpx_timeout_seconds=${ACPX_TIMEOUT_EFF}
repo_path=${REPO_PARENT_EFF}
EOF
)"

PREPARE_TICK_CMD="${PREPARE_TICK_CMD:-${SCRIPT_DIR}/dispatch_prepare_tick.sh}"
printf '%s\n' "${TRIGGER}" | bash "${PREPARE_TICK_CMD}"
