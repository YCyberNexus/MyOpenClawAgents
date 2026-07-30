#!/usr/bin/env bash
# Persist the complete current execution log as a log-only child commit on the
# same WORK_BRANCH used by the Issue.  This script never creates a second log
# branch and never stages unrelated worktree changes.
#
# worker_result.json describes the already-pushed business commit, so it cannot
# be embedded in that same commit (the commit hash would depend on itself).  A
# direct child commit is the only non-circular way to keep the terminal result
# and the rest of LOG_DIR on issue/<iid> itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=archive_execution_logs

: "${WORKTREE_DIR:?}" "${WORK_ROOT:?}" "${ISSUE_IID:?}" \
  "${EXECUTION_ID:?}" "${ISSUE_LOG_REL:?}" "${LOG_DIR:?}" \
  "${WORK_BRANCH:?}"

if [ ! -d "${WORKTREE_DIR}" ] || [ ! -d "${LOG_DIR}" ] \
    || [ -L "${LOG_DIR}" ]; then
  echo "archive_execution_logs: worktree or safe LOG_DIR is missing" >&2
  exit 2
fi
case "${LOG_DIR}" in
  "${WORKTREE_DIR}/${ISSUE_LOG_REL}") ;;
  *)
    echo "archive_execution_logs: LOG_DIR escaped its derived repository path" >&2
    exit 2
    ;;
esac
VALID_WORK_BRANCH=false
if [ "${WORK_BRANCH}" = "issue/${ISSUE_IID}" ]; then
  VALID_WORK_BRANCH=true
elif [[ "${WORK_BRANCH}" =~ ^issue/([1-9][0-9]*)\+([1-9][0-9]*)$ ]] \
    && [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ] \
    && { [ "${ISSUE_IID}" = "${BASH_REMATCH[1]}" ] \
      || [ "${ISSUE_IID}" = "${BASH_REMATCH[2]}" ]; }; then
  VALID_WORK_BRANCH=true
fi
if [ "${VALID_WORK_BRANCH}" != true ]; then
  echo "archive_execution_logs: invalid Issue work branch" >&2
  exit 2
fi

cd "${WORKTREE_DIR}"
git_network_guard_assert_repo "${WORKTREE_DIR}"

BASE_COMMIT_SHA="$(GIT_NO_REPLACE_OBJECTS=1 \
  git rev-parse --verify 'HEAD^{commit}')"
if ! [[ "${BASE_COMMIT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "archive_execution_logs: local HEAD is not a full commit ID" >&2
  exit 5
fi
if [ -n "${COMMIT_SHA:-}" ] \
    && [ "${COMMIT_SHA,,}" != "${BASE_COMMIT_SHA,,}" ]; then
  echo "archive_execution_logs: caller commit does not match local HEAD" >&2
  exit 5
fi

WORK_BRANCH_REF="refs/heads/${WORK_BRANCH}"
set +e
REMOTE_ROWS="$(git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --exit-code --heads origin "${WORK_BRANCH}" 2>/dev/null)"
REMOTE_STATUS=$?
set -e
case "${REMOTE_STATUS}" in
  0|2) ;;
  *) exit "${REMOTE_STATUS}" ;;
esac
REMOTE_TIPS="$(awk -v expected_ref="${WORK_BRANCH_REF}" \
  '$2 == expected_ref {print $1}' <<<"${REMOTE_ROWS}")"
REMOTE_TIP_COUNT="$(awk 'NF {count++} END {print count+0}' \
  <<<"${REMOTE_TIPS}")"
if [ "${REMOTE_TIP_COUNT}" -gt 1 ]; then
  echo "archive_execution_logs: remote returned duplicate Issue branch refs" >&2
  exit 5
fi
REMOTE_TIP="$(awk 'NF {print; exit}' <<<"${REMOTE_TIPS}")"
if [ "${REMOTE_TIP_COUNT}" -eq 0 ] && [[ "${WORK_BRANCH}" == issue/*+* ]]; then
  echo "archive_execution_logs: shared Issue branch is not remotely published" >&2
  exit 5
fi

# Build the snapshot from HEAD in a private index.  The normal index may still
# contain partial business work on a failed execution and must not leak into a
# log-only commit.
INDEX_ROOT="${WORK_ROOT}/log_branch_indexes"
mkdir -p "${INDEX_ROOT}"
INDEX_FILE="${INDEX_ROOT}/issue-${ISSUE_IID}-execution-${EXECUTION_ID}.$$.${RANDOM}.index"
GIT_INDEX_FILE="${INDEX_FILE}" git read-tree "${BASE_COMMIT_SHA}"
GIT_INDEX_FILE="${INDEX_FILE}" git add -f -- "${ISSUE_LOG_REL}"
LOG_TREE="$(GIT_INDEX_FILE="${INDEX_FILE}" git write-tree)"
BASE_TREE="$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify \
  "${BASE_COMMIT_SHA}^{tree}")"
if ! [[ "${LOG_TREE}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "archive_execution_logs: failed to build the terminal log tree" >&2
  exit 5
fi

# An exact replay after the log commit is already checked out is a tree no-op.
# If an ordinary Issue ref was deleted remotely, recreate that exact commit
# before reporting success; a local remote-tracking ref is not proof.
if [ "${LOG_TREE,,}" = "${BASE_TREE,,}" ]; then
  if [ "${REMOTE_TIP_COUNT}" -eq 1 ] \
      && [ "${REMOTE_TIP,,}" != "${BASE_COMMIT_SHA,,}" ]; then
    echo "archive_execution_logs: Issue branch moved before the exact log replay" >&2
    exit 5
  fi
  if [ "${REMOTE_TIP_COUNT}" -eq 0 ]; then
    set +e
    git_network_guard_run "${WORKTREE_DIR}" push \
      "--force-with-lease=${WORK_BRANCH_REF}:" origin \
      "${BASE_COMMIT_SHA}:${WORK_BRANCH_REF}" >&2
    RECREATE_STATUS=$?
    set -e
    RECREATE_ROWS="$(git_network_guard_run "${WORKTREE_DIR}" \
      ls-remote --heads origin "${WORK_BRANCH}")"
    RECREATE_TIPS="$(awk -v expected_ref="${WORK_BRANCH_REF}" \
      '$2 == expected_ref {print $1}' <<<"${RECREATE_ROWS}")"
    RECREATE_COUNT="$(awk 'NF {count++} END {print count+0}' \
      <<<"${RECREATE_TIPS}")"
    RECREATE_TIP="$(awk 'NF {print; exit}' <<<"${RECREATE_TIPS}")"
    if [ "${RECREATE_COUNT}" -ne 1 ] \
        || [ "${RECREATE_TIP,,}" != "${BASE_COMMIT_SHA,,}" ]; then
      [ "${RECREATE_STATUS}" -ne 0 ] || exit 5
      exit "${RECREATE_STATUS}"
    fi
    GIT_NO_REPLACE_OBJECTS=1 git update-ref \
      "refs/remotes/origin/${WORK_BRANCH}" "${BASE_COMMIT_SHA}"
  fi
  printf 'LOG_WORK_BRANCH=%s\n' "${WORK_BRANCH}"
  printf 'LOG_PARENT_COMMIT=%s\n' "${BASE_COMMIT_SHA}"
  printf 'LOG_COMMIT_SHA=%s\n' "${BASE_COMMIT_SHA}"
  exit 0
fi

LOG_COMMIT_SHA="$(
  GIT_AUTHOR_NAME=req_executor \
  GIT_AUTHOR_EMAIL=req_executor@localhost \
  GIT_AUTHOR_DATE=2000-01-01T00:00:00Z \
  GIT_COMMITTER_NAME=req_executor \
  GIT_COMMITTER_EMAIL=req_executor@localhost \
  GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    git commit-tree "${LOG_TREE}" -p "${BASE_COMMIT_SHA}" \
      -m "chore(issue-${ISSUE_IID}): 保存 execution-${EXECUTION_ID} 执行日志"
)"
if ! [[ "${LOG_COMMIT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "archive_execution_logs: failed to create the terminal log commit" >&2
  exit 5
fi

REMOTE_ALREADY_HAS_LOG_COMMIT=false
if [ "${REMOTE_TIP_COUNT}" -eq 1 ] \
    && [ "${REMOTE_TIP,,}" != "${BASE_COMMIT_SHA,,}" ]; then
  if [ "${REMOTE_TIP,,}" = "${LOG_COMMIT_SHA,,}" ]; then
    # Recovery after the server accepted the deterministic commit but this
    # process stopped before advancing its local refs.
    REMOTE_ALREADY_HAS_LOG_COMMIT=true
  else
    echo "archive_execution_logs: Issue branch moved before terminal logs were persisted" >&2
    exit 5
  fi
fi

PUSH_STATUS=0
if [ "${REMOTE_ALREADY_HAS_LOG_COMMIT}" != true ]; then
  set +e
  if [ "${REMOTE_TIP_COUNT}" -eq 1 ]; then
    git_network_guard_run "${WORKTREE_DIR}" push \
      "--force-with-lease=${WORK_BRANCH_REF}:${BASE_COMMIT_SHA}" origin \
      "${LOG_COMMIT_SHA}:${WORK_BRANCH_REF}" >&2
  else
    git_network_guard_run "${WORKTREE_DIR}" push \
      "--force-with-lease=${WORK_BRANCH_REF}:" origin \
      "${LOG_COMMIT_SHA}:${WORK_BRANCH_REF}" >&2
  fi
  PUSH_STATUS=$?
  set -e
else
  echo "archive_execution_logs: exact remote log commit already exists; recovering local refs" >&2
fi

VERIFY_ROWS="$(git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --heads origin "${WORK_BRANCH}")"
VERIFY_TIPS="$(awk -v expected_ref="${WORK_BRANCH_REF}" \
  '$2 == expected_ref {print $1}' <<<"${VERIFY_ROWS}")"
VERIFY_COUNT="$(awk 'NF {count++} END {print count+0}' <<<"${VERIFY_TIPS}")"
VERIFY_TIP="$(awk 'NF {print; exit}' <<<"${VERIFY_TIPS}")"
if [ "${VERIFY_COUNT}" -ne 1 ] \
    || [ "${VERIFY_TIP,,}" != "${LOG_COMMIT_SHA,,}" ]; then
  if [ "${PUSH_STATUS}" -eq 0 ]; then
    echo "archive_execution_logs: push succeeded but the remote Issue branch tip is different" >&2
    exit 5
  fi
  exit "${PUSH_STATUS}"
fi
if [ "${PUSH_STATUS}" -ne 0 ]; then
  echo "archive_execution_logs: push returned ${PUSH_STATUS}, but the exact remote tip confirms success" >&2
fi

# Advance only the local checked-out branch and its exact remote-tracking ref.
# Resetting this one index path avoids making the freshly committed log files
# appear as staged deletions while preserving unrelated partial work.
GIT_NO_REPLACE_OBJECTS=1 git update-ref HEAD \
  "${LOG_COMMIT_SHA}" "${BASE_COMMIT_SHA}"
git reset -q -- "${ISSUE_LOG_REL}"
if [ "${REMOTE_TIP_COUNT}" -eq 1 ]; then
  GIT_NO_REPLACE_OBJECTS=1 git update-ref \
    "refs/remotes/origin/${WORK_BRANCH}" "${LOG_COMMIT_SHA}" \
    "${BASE_COMMIT_SHA}" 2>/dev/null \
    || GIT_NO_REPLACE_OBJECTS=1 git update-ref \
      "refs/remotes/origin/${WORK_BRANCH}" "${LOG_COMMIT_SHA}"
else
  GIT_NO_REPLACE_OBJECTS=1 git update-ref \
    "refs/remotes/origin/${WORK_BRANCH}" "${LOG_COMMIT_SHA}"
fi

printf 'LOG_WORK_BRANCH=%s\n' "${WORK_BRANCH}"
printf 'LOG_PARENT_COMMIT=%s\n' "${BASE_COMMIT_SHA}"
printf 'LOG_COMMIT_SHA=%s\n' "${LOG_COMMIT_SHA}"
