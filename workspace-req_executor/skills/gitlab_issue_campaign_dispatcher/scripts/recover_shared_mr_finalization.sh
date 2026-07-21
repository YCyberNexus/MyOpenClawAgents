#!/usr/bin/env bash
# Recover only the MR-finalization half of an already pushed shared-branch
# attempt. This path never runs acpx and never stages, commits, or pushes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=git_network_guard.sh
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=recover_shared_mr_finalization

: "${ISSUE_IID:?}" "${EXECUTION_ID:?}" "${ISSUE_STATE_FILE:?}" \
  "${EXECUTION_STATE_FILE:?}" "${WORK_BRANCH:?}" "${WORKTREE_DIR:?}"

private_file_mode() {
  local path="$1"
  if stat -f '%Lp' "${path}" 2>/dev/null; then
    :
  else
    stat -c '%a' "${path}" 2>/dev/null
  fi
}

private_file_owner() {
  local path="$1"
  if stat -f '%u' "${path}" 2>/dev/null; then
    :
  else
    stat -c '%u' "${path}" 2>/dev/null
  fi
}

read_private_json() {
  local path="$1" bytes mode owner
  [ -f "${path}" ] && [ ! -L "${path}" ] || return 1
  mode="$(private_file_mode "${path}")" || return 1
  owner="$(private_file_owner "${path}")" || return 1
  bytes="$(wc -c <"${path}" 2>/dev/null | tr -d '[:space:]')"
  [ "${mode}" = 600 ] && [ "${owner}" = "$(id -u)" ] \
    && [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${bytes}" -le 65536 ] || return 1
  jq -ce 'if type == "object" then . else error("not an object") end' \
    "${path}" 2>/dev/null
}

ISSUE_STATE="$(read_private_json "${ISSUE_STATE_FILE}")" || {
  echo "recover_shared_mr_finalization: unsafe or invalid Issue state" >&2
  exit 2
}
EXECUTION_STATE="$(read_private_json "${EXECUTION_STATE_FILE}")" || {
  echo "recover_shared_mr_finalization: unsafe or invalid execution state" >&2
  exit 2
}

if ! RECOVERY_IDENTITY="$(jq -nce \
    --argjson issue_state "${ISSUE_STATE}" \
    --argjson execution_state "${EXECUTION_STATE}" \
    --argjson iid "${ISSUE_IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg work_branch "${WORK_BRANCH}" '
    ($issue_state.mr_finalization // null) as $finalization
    | if $execution_state.iid == $iid
      and $execution_state.execution_id == $execution_id
      and ($execution_state.issue_title | type == "string" and length > 0)
      and ($execution_state.mode_actual == "fresh"
        or $execution_state.mode_actual == "continue")
      and $execution_state.auto_merge == false
      and $execution_state.work_branch == $work_branch
      and ($execution_state.branch_members | type == "array" and length == 2)
      and $execution_state.branch_members[0] != $execution_state.branch_members[1]
      and ($execution_state.branch_members | index($iid) != null)
      and $execution_state.work_branch ==
        ("issue/" + ($execution_state.branch_members[0] | tostring)
          + "+" + ($execution_state.branch_members[1] | tostring))
      and $execution_state.shared_branch_role ==
        (if $iid == $execution_state.branch_members[0] then "head" else "tail" end)
      and ($execution_state.expected_commit_parent_sha | type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      and ($execution_state.merge_target_branch | type == "string" and length > 0)
      and ($finalization | type == "object")
      and ($finalization | keys | sort) == ([
        "branch_members","commit_sha","intent_id","shared_branch_role",
        "source_execution_id","status","target_branch","work_branch"
      ] | sort)
      and $finalization.status == "pending"
      and $finalization.source_execution_id == $execution_id
      and $finalization.work_branch == $execution_state.work_branch
      and $finalization.branch_members == $execution_state.branch_members
      and $finalization.shared_branch_role == $execution_state.shared_branch_role
      and ($finalization.commit_sha | type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      and ($finalization.intent_id | type == "string"
        and test("^[0-9a-f]{64}$"))
      and $finalization.target_branch == $execution_state.merge_target_branch
      and $issue_state.dependency_history_verified == true
      and $issue_state.dependency_pinned_execution_id == $execution_id
      and (($issue_state.work_branch_sha | ascii_downcase)
        == ($finalization.commit_sha | ascii_downcase))
      and $issue_state.work_branch == $finalization.work_branch
      and $issue_state.branch_members == $finalization.branch_members
      and $issue_state.shared_branch_role == $finalization.shared_branch_role
      and (if $execution_state.shared_branch_role == "head" then
        $execution_state.mode_actual == "fresh"
        and ($execution_state.expected_work_branch_sha // null) == null
        and ($execution_state.dependency_iid // null) == null
        and ($execution_state.dependency_branch // null) == null
        and ($execution_state.dependency_base_sha // null) == null
        and ($issue_state.dependency_iid // null) == null
        and ($issue_state.dependency_branch // null) == null
        and ($issue_state.dependency_base_sha // null) == null
      else
        ($execution_state.expected_work_branch_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and $execution_state.dependency_iid == $execution_state.branch_members[0]
        and $execution_state.dependency_branch == $execution_state.work_branch
        and ($execution_state.dependency_base_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and $issue_state.dependency_iid == $execution_state.dependency_iid
        and $issue_state.dependency_branch == $execution_state.dependency_branch
        and (($issue_state.dependency_base_sha | ascii_downcase)
          == ($execution_state.dependency_base_sha | ascii_downcase))
        and (($execution_state.expected_commit_parent_sha | ascii_downcase)
          == ($execution_state.dependency_base_sha | ascii_downcase))
        and (if $execution_state.mode_actual == "fresh" then
          (($execution_state.expected_work_branch_sha | ascii_downcase)
            == ($execution_state.dependency_base_sha | ascii_downcase))
        else true end)
      end)
    then {
      issue_title:$execution_state.issue_title,
      mode_actual:$execution_state.mode_actual,
      target_branch:$execution_state.merge_target_branch,
      branch_members:$execution_state.branch_members,
      shared_branch_role:$execution_state.shared_branch_role,
      dependency_iid:($execution_state.dependency_iid // null),
      dependency_branch:($execution_state.dependency_branch // null),
      dependency_base_sha:($execution_state.dependency_base_sha // null),
      commit_sha:$finalization.commit_sha,
      intent_id:$finalization.intent_id
    } else error("invalid shared MR recovery checkpoint") end
  ')"; then
  echo "recover_shared_mr_finalization: checkpoint does not match the fixed execution" >&2
  exit 2
fi

git_network_guard_assert_repo "${WORKTREE_DIR}"
REMOTE_ROWS="$(git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --heads origin "${WORK_BRANCH}")"
REMOTE_TIPS="$(awk -v expected_ref="refs/heads/${WORK_BRANCH}" \
  '$2 == expected_ref {print $1}' <<<"${REMOTE_ROWS}")"
REMOTE_TIP_COUNT="$(awk 'NF {count++} END {print count+0}' \
  <<<"${REMOTE_TIPS}")"
if [ "${REMOTE_TIP_COUNT}" -ne 1 ]; then
  echo "recover_shared_mr_finalization: exact shared remote ref is missing or ambiguous" >&2
  exit 5
fi
REMOTE_TIP="$(awk 'NF {print; exit}' <<<"${REMOTE_TIPS}")"
COMMIT_SHA="$(jq -r '.commit_sha' <<<"${RECOVERY_IDENTITY}")"
LOCAL_TIP="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
  rev-parse --verify 'HEAD^{commit}')"
if [ "${REMOTE_TIP,,}" != "${COMMIT_SHA,,}" ] \
    || [ "${LOCAL_TIP,,}" != "${COMMIT_SHA,,}" ]; then
  echo "recover_shared_mr_finalization: shared branch moved after its recovery checkpoint" >&2
  exit 5
fi

ISSUE_TITLE="$(jq -r '.issue_title' <<<"${RECOVERY_IDENTITY}")"
ISSUE_MODE="$(jq -r '.mode_actual' <<<"${RECOVERY_IDENTITY}")"
MERGE_TARGET_BRANCH="$(jq -r '.target_branch' <<<"${RECOVERY_IDENTITY}")"
DEPENDENCY_IID="$(jq -r '.dependency_iid // ""' <<<"${RECOVERY_IDENTITY}")"
DEPENDENCY_BRANCH="$(jq -r '.dependency_branch // ""' <<<"${RECOVERY_IDENTITY}")"
DEPENDENCY_BASE_SHA="$(jq -r '.dependency_base_sha // ""' <<<"${RECOVERY_IDENTITY}")"

MR_OUTPUT="$(
  ISSUE_TITLE="${ISSUE_TITLE}" ISSUE_MODE="${ISSUE_MODE}" \
  BRANCH="${MERGE_TARGET_BRANCH}" \
  MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" AUTO_MERGE=false \
  DEPENDENCY_IID="${DEPENDENCY_IID}" \
  DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH}" \
  DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA}" \
  COMMIT_SHA="${COMMIT_SHA}" SHARED_MR_RECOVERY=true \
    bash "${SCRIPT_DIR}/create_mr.sh"
)" || {
  echo "recover_shared_mr_finalization: exact MR finalization is not ready" >&2
  exit 6
}

MR_URL="$(sed -n '1p' <<<"${MR_OUTPUT}")"
MR_ACTION="$(sed -n '2p' <<<"${MR_OUTPUT}")"
MR_IID="$(sed -n '3p' <<<"${MR_OUTPUT}")"
MR_OUTCOME="$(sed -n '4p' <<<"${MR_OUTPUT}")"
EXPECTED_ACTION=created
[ "$(jq -r '.shared_branch_role' <<<"${RECOVERY_IDENTITY}")" = head ] \
  || EXPECTED_ACTION=reused
if ! [[ "${MR_IID}" =~ ^[1-9][0-9]*$ ]] \
    || [ "${MR_ACTION}" != "${EXPECTED_ACTION}" ] \
    || [ "${MR_OUTCOME}" != opened ] \
    || ! [[ "${MR_URL}" =~ ^https?://[^[:space:]]+/-/merge_requests/${MR_IID}/?$ ]]; then
  echo "recover_shared_mr_finalization: create_mr returned an invalid shared identity" >&2
  exit 6
fi

# create_mr.sh may have refreshed mr_result.json after the worker's first log
# snapshot. Append the new terminal tree to the execution's dedicated archive
# branch before reporting successful recovery.
if ! bash "${SCRIPT_DIR}/archive_execution_logs.sh" >/dev/null; then
  echo "recover_shared_mr_finalization: updated execution-log archive failed" >&2
  exit 6
fi

jq -nc \
  --argjson iid "${ISSUE_IID}" \
  --argjson execution_id "${EXECUTION_ID}" \
  --arg commit_sha "${COMMIT_SHA}" \
  --arg intent_id "$(jq -r '.intent_id' <<<"${RECOVERY_IDENTITY}")" \
  --arg mr_url "${MR_URL}" \
  --arg mr_action "${MR_ACTION}" '{
    status:"verified_open",iid:$iid,execution_id:$execution_id,
    commit_sha:$commit_sha,intent_id:$intent_id,
    merge_request_url:$mr_url,mr_action:$mr_action
  }'
