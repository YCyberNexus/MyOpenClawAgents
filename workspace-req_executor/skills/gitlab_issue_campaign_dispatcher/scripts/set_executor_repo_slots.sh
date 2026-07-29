#!/usr/bin/env bash
# Persist the executor-wide per-repository Issue ceiling from `/repo-slot N`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULER_ENV_CMD="${SCHEDULER_ENV_CMD:-${SCRIPT_DIR}/scheduler_env.sh}"

repo_slot_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

if [ "$#" -ne 0 ]; then
  repo_slot_failure "usage: /repo-slot <positive-integer>"
fi

COMMAND_TEXT="$(cat)"
if [[ ! "${COMMAND_TEXT}" =~ ^/repo-slot[[:blank:]]+([1-9][0-9]*)[[:blank:]]*$ ]]; then
  repo_slot_failure "usage: /repo-slot <positive-integer>"
fi
SLOT_COUNT_TEXT="${BASH_REMATCH[1]}"
if [ "${#SLOT_COUNT_TEXT}" -gt 10 ] \
  || [ "${SLOT_COUNT_TEXT}" -gt 2147483647 ]; then
  repo_slot_failure "per-repository Issue limit must be between 1 and 2147483647"
fi
SLOT_COUNT="${SLOT_COUNT_TEXT}"

# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null

exec {REPO_SLOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${REPO_SLOT_LOCK_FD}"
if ! SCHEDULER_STATE="$(jq -ce '
  if type == "object"
    and .version == 1
    and (.active_jobs | type == "object")
    and ((has("max_issues_per_repository") | not)
      or (.max_issues_per_repository | type == "number"
        and . == floor and . > 0))
    and ((has("pending_transaction") | not)
      or ((.pending_transaction | type) == "object"
        and (.pending_transaction.scheduler_state | type == "object")
        and .pending_transaction.scheduler_state.version == 1
        and (.pending_transaction.scheduler_state.active_jobs | type == "object")))
  then . else error("invalid scheduler state") end
' "${SCHEDULER_STATE_FILE}")"; then
  flock -u "${REPO_SLOT_LOCK_FD}"
  exec {REPO_SLOT_LOCK_FD}>&-
  repo_slot_failure "scheduler state is invalid"
fi

PREVIOUS_SLOT_COUNT="$(jq -r \
  --argjson configured_max "${EXECUTOR_MAX_ISSUES_PER_REPOSITORY}" \
  '.max_issues_per_repository // $configured_max' <<<"${SCHEDULER_STATE}")"
ACTIVE_ISSUE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
ACTIVE_REPOSITORY_COUNT="$(jq -r \
  '[.active_jobs[].project] | unique | length' <<<"${SCHEDULER_STATE}")"
OVER_LIMIT_REPOSITORY_COUNT="$(jq -r \
  --argjson slots "${SLOT_COUNT}" '
  [.active_jobs[].project]
  | group_by(.)
  | map(select(length > $slots))
  | length
' <<<"${SCHEDULER_STATE}")"
UPDATED_STATE="$(jq -c --argjson slots "${SLOT_COUNT}" '
  .max_issues_per_repository = $slots
  | if has("pending_transaction")
    then .pending_transaction.scheduler_state.max_issues_per_repository = $slots
    else .
    end
' <<<"${SCHEDULER_STATE}")"
scheduler_atomic_write_json "${SCHEDULER_STATE_FILE}" "${UPDATED_STATE}"
flock -u "${REPO_SLOT_LOCK_FD}"
exec {REPO_SLOT_LOCK_FD}>&-

if [ "${OVER_LIMIT_REPOSITORY_COUNT}" -gt 0 ]; then
  DRAINING=true
else
  DRAINING=false
fi

jq -cn \
  --argjson per_repository_issue_limit "${SLOT_COUNT}" \
  --argjson previous_per_repository_issue_limit "${PREVIOUS_SLOT_COUNT}" \
  --argjson active_repository_count "${ACTIVE_REPOSITORY_COUNT}" \
  --argjson active_issue_count "${ACTIVE_ISSUE_COUNT}" \
  --argjson over_limit_repository_count "${OVER_LIMIT_REPOSITORY_COUNT}" \
  --argjson draining "${DRAINING}" '
  {
    status:"success",
    per_repository_issue_limit:$per_repository_issue_limit,
    previous_per_repository_issue_limit:$previous_per_repository_issue_limit,
    active_repository_count:$active_repository_count,
    active_issue_count:$active_issue_count,
    over_limit_repository_count:$over_limit_repository_count,
    draining:$draining
  }'
