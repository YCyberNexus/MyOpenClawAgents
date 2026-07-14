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
  if type != "object"
     or (exact_keys(["owner_id","grants"]) | not)
     or (.owner_id | clean_string | not)
     or ((.grants | type) != "array")
     or ((.grants | length) == 0)
     or (all(.grants[];
          type == "object"
          and exact_keys(["job_id","batch_id","snapshot_index","project","iid","branch","entry_mode","force_rerun_pr"])
          and (.job_id | clean_string)
          and (.batch_id | clean_string)
          and (.project | clean_string)
          and (.branch == null or (.branch | clean_string))
          and (.snapshot_index | type == "number" and . == floor and . >= 0)
          and (.iid | type == "number" and . == floor and . >= 1)
          and (.entry_mode == "auto" or .entry_mode == "fresh" or .entry_mode == "continue")
          and (.force_rerun_pr | type == "boolean")) | not)
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
    ""|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\[*|*\]*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ]
}
while IFS= read -r branch; do
  validate_branch_name "${branch}" || die "grant branch is not a safe Git ref name"
done < <(printf '%s' "${REQUEST_JSON}" | jq -r '.grants[] | select(.branch != null) | .branch')

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
MAX_CONCURRENT_EFF="${EXECUTOR_MAX_CONCURRENCY:-3}"
case "${MAX_CONCURRENT_EFF}" in
  ''|*[!0-9]*) die "EXECUTOR_MAX_CONCURRENCY must be a positive integer" ;;
esac
[ "${MAX_CONCURRENT_EFF}" -ge 1 ] || die "EXECUTOR_MAX_CONCURRENCY must be >= 1"

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

IID_CSV="$(printf '%s' "${REQUEST_JSON}" | jq -r '[.grants[].iid] | join(",")')"
IID_MIN="$(printf '%s' "${REQUEST_JSON}" | jq -r '[.grants[].iid] | min')"
IID_MAX="$(printf '%s' "${REQUEST_JSON}" | jq -r '[.grants[].iid] | max')"

export PROJECT="${PROJECT_SLUG}"
export GROUP="${GROUP_EFF}"
export GITLAB_TOKEN="${GITLAB_TOKEN_EFF}"
export GITLAB_HOST GITLAB_API_PROTOCOL
export REPO_PARENT_PATH="${REPO_PARENT_EFF}"
export EXECUTOR_SCHEDULER_ROOT EXECUTOR_MAX_CONCURRENCY
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
project=${PROJECT_SLUG}
group=${GROUP_EFF}
issue_iids=${IID_CSV}
issue_min_iid=${IID_MIN}
issue_max_iid=${IID_MAX}
hourly_issue_quota=${MAX_CONCURRENT_EFF}
max_concurrent_subagents=${MAX_CONCURRENT_EFF}
max_runtime_minutes=300
blocked_retry_limit=3
blocked_cooldown_ticks=1
acpx_timeout_seconds=18000
repo_path=${REPO_PARENT_EFF}
EOF
)"

PREPARE_TICK_CMD="${PREPARE_TICK_CMD:-${SCRIPT_DIR}/dispatch_prepare_tick.sh}"
printf '%s\n' "${TRIGGER}" | bash "${PREPARE_TICK_CMD}"
