#!/usr/bin/env bash
# commit_and_push.sh — commit the staged changes inside the repo root and
# publish the commit from the fixed issue-local branch to the canonical remote
# branch ${WORK_BRANCH} (Strategy A).
#
# Required env vars:
#   WORKTREE_DIR             repo root cwd for git commands
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   LOCAL_ISSUE_BRANCH       "issue/<iid>"
#   WORK_BRANCH              `issue/<iid>` or shared `issue/<head>+<tail>`
#   EXPECTED_WORK_BRANCH_SHA  optional full old remote tip used only as the
#                             explicit push lease; required when updating an
#                             existing shared issue/<A>+<C> branch
#   EXPECTED_COMMIT_PARENT_SHA
#                             full commit that must be the new shared commit's
#                             only parent; required for every shared branch push
#   ISSUE_TITLE              short human title for commit message
#
# Strategy A keeps a single MR pointing at a single remote branch. The local
# issue branch and remote work branch are both reused across runs.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=commit_and_push

: "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${LOCAL_ISSUE_BRANCH:?}" "${WORK_BRANCH:?}" "${ISSUE_TITLE:?}"
EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA:-}"
EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA:-}"
if [ -n "${EXPECTED_WORK_BRANCH_SHA}" ] \
    && ! [[ "${EXPECTED_WORK_BRANCH_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "commit_and_push: EXPECTED_WORK_BRANCH_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
if [ -n "${EXPECTED_COMMIT_PARENT_SHA}" ] \
    && ! [[ "${EXPECTED_COMMIT_PARENT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "commit_and_push: EXPECTED_COMMIT_PARENT_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
SHARED_WORK_BRANCH=false
if [[ "${WORK_BRANCH}" == issue/*+* ]]; then
  SHARED_WORK_BRANCH=true
  if [ -z "${EXPECTED_COMMIT_PARENT_SHA}" ]; then
    echo "commit_and_push: shared work branch requires EXPECTED_COMMIT_PARENT_SHA" >&2
    exit 5
  fi
fi

cd "${WORKTREE_DIR}"
git_network_guard_assert_repo "${WORKTREE_DIR}"

git -c core.hooksPath=/dev/null -c commit.gpgSign=false commit -m \
  "fix(issue-${ISSUE_IID}): ${ISSUE_TITLE} (attempt ${ATTEMPT_NUMBER_PADDED})"
NEW_COMMIT_SHA="$(GIT_NO_REPLACE_OBJECTS=1 \
  git rev-parse --verify 'HEAD^{commit}')"
if ! [[ "${NEW_COMMIT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "commit_and_push: newly created commit did not resolve to a full object ID" >&2
  exit 5
fi

if [ "${SHARED_WORK_BRANCH}" = true ]; then
  commit_parents_line="$(GIT_NO_REPLACE_OBJECTS=1 \
    git rev-list --parents -n 1 "${NEW_COMMIT_SHA}" 2>/dev/null || true)"
  read -r -a commit_parents <<<"${commit_parents_line}"
  if [ "${#commit_parents[@]}" -ne 2 ] \
      || [ "${commit_parents[0],,}" != "${NEW_COMMIT_SHA,,}" ] \
      || [ "${commit_parents[1],,}" != "${EXPECTED_COMMIT_PARENT_SHA,,}" ]; then
    echo "commit_and_push: new shared commit must have exactly EXPECTED_COMMIT_PARENT_SHA as its only parent" >&2
    exit 5
  fi
fi

# A transport can report failure after the server has already accepted the
# update. Conversely, a successful client return is not enough when another
# same-UID process can move local refs. Resolve both outcomes by reading the
# canonical remote ref and comparing it with the immutable captured commit.
push_and_confirm_remote_tip() {
  local expected_sha="$1"
  shift
  local push_status remote_status remote_rows remote_tips remote_tip tip_count
  set +e
  git_network_guard_run "${WORKTREE_DIR}" push "$@" >&2
  push_status=$?
  set -e

  set +e
  remote_rows="$(git_network_guard_run "${WORKTREE_DIR}" \
    ls-remote --heads origin "refs/heads/${WORK_BRANCH}" 2>/dev/null)"
  remote_status=$?
  set -e
  remote_tips="$(awk -v expected_ref="refs/heads/${WORK_BRANCH}" \
    '$2 == expected_ref {print $1}' <<<"${remote_rows}")"
  tip_count="$(awk 'NF {count++} END {print count+0}' <<<"${remote_tips}")"
  remote_tip="$(awk 'NF {print; exit}' <<<"${remote_tips}")"
  if [ "${remote_status}" -eq 0 ] \
      && [ "${tip_count}" -eq 1 ] \
      && [ "${remote_tip,,}" = "${expected_sha,,}" ]; then
    if [ "${push_status}" -ne 0 ]; then
      echo "commit_and_push: push returned ${push_status}, but the exact remote tip confirms success" >&2
    fi
    return 0
  fi
  if [ "${push_status}" -eq 0 ]; then
    echo "commit_and_push: push returned success, but the exact remote tip does not match the captured commit" >&2
    return 5
  fi
  return "${push_status}"
}

# Publish the immutable captured commit to the fixed remote branch. Every
# existing ref uses an explicit observed/planned SHA lease. First creation uses
# an empty expected value so the server atomically proves the ref is still
# absent at update time.
set +e
remote_rows="$(git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --exit-code --heads origin "${WORK_BRANCH}" \
  2>/dev/null)"
ls_remote_status=$?
set -e
case "${ls_remote_status}" in 0|2) ;; *) exit "${ls_remote_status}" ;; esac
remote_tips="$(awk -v expected_ref="refs/heads/${WORK_BRANCH}" \
  '$2 == expected_ref {print $1}' <<<"${remote_rows}")"
remote_tip_count="$(awk 'NF {count++} END {print count+0}' <<<"${remote_tips}")"
if [ "${remote_tip_count}" -gt 1 ]; then
  echo "commit_and_push: remote returned duplicate exact work-branch refs" >&2
  exit 5
fi
remote_tip="$(awk 'NF {print; exit}' <<<"${remote_tips}")"
if [ "${remote_tip_count}" -eq 1 ]; then
    if [ -n "${EXPECTED_WORK_BRANCH_SHA}" ]; then
      if [ "${remote_tip,,}" != "${EXPECTED_WORK_BRANCH_SHA,,}" ]; then
        echo "commit_and_push: shared work branch moved from its expected tip" >&2
        exit 5
      fi
      push_and_confirm_remote_tip "${NEW_COMMIT_SHA}" \
        "--force-with-lease=refs/heads/${WORK_BRANCH}:${EXPECTED_WORK_BRANCH_SHA}" \
        origin "${NEW_COMMIT_SHA}:refs/heads/${WORK_BRANCH}"
    elif [[ "${WORK_BRANCH}" == issue/*+* ]]; then
      echo "commit_and_push: updating a shared work branch requires EXPECTED_WORK_BRANCH_SHA" >&2
      exit 5
    else
      push_and_confirm_remote_tip "${NEW_COMMIT_SHA}" \
        "--force-with-lease=refs/heads/${WORK_BRANCH}:${remote_tip}" \
        origin "${NEW_COMMIT_SHA}:refs/heads/${WORK_BRANCH}"
    fi
else
    if [ -n "${EXPECTED_WORK_BRANCH_SHA}" ]; then
      echo "commit_and_push: expected shared work branch is missing" >&2
      exit 5
    fi
    push_and_confirm_remote_tip "${NEW_COMMIT_SHA}" \
      "--force-with-lease=refs/heads/${WORK_BRANCH}:" \
      origin "${NEW_COMMIT_SHA}:refs/heads/${WORK_BRANCH}"
fi

printf '%s\n' "${NEW_COMMIT_SHA}"
