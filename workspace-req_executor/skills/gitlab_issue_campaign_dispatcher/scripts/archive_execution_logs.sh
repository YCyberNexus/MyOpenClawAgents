#!/usr/bin/env bash
# archive_execution_logs.sh — publish the complete terminal LOG_DIR without
# moving the issue work branch or changing the business commit SHA used by MR,
# dependency, and callback identity checks.
#
# The archive is an append-only snapshot branch:
#   req-executor-logs/issue-<iid>/execution-<execution_id>
# Its tree preserves LOG_DIR at the same repository-relative path used by the
# issue worktree. The branch is deliberately separate from WORK_BRANCH because
# terminal files such as worker_result.json contain the business commit SHA;
# adding them to that same commit would create a circular hash dependency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=archive_execution_logs

: "${WORKTREE_DIR:?}" "${WORK_ROOT:?}" "${ISSUE_IID:?}" \
  "${EXECUTION_ID:?}" "${ISSUE_LOG_REL:?}" "${LOG_DIR:?}"

if [ ! -d "${WORKTREE_DIR}" ] || [ ! -d "${LOG_DIR}" ]; then
  echo "archive_execution_logs: worktree or LOG_DIR is missing" >&2
  exit 2
fi
case "${LOG_DIR}" in
  "${WORKTREE_DIR}/${ISSUE_LOG_REL}") ;;
  *)
    echo "archive_execution_logs: LOG_DIR escaped its derived repository path" >&2
    exit 2
    ;;
esac

ARCHIVE_BRANCH="req-executor-logs/issue-${ISSUE_IID}/execution-${EXECUTION_ID}"
ARCHIVE_REF="refs/heads/${ARCHIVE_BRANCH}"
INDEX_ROOT="${WORK_ROOT}/log_archive_indexes"
INDEX_FILE="${INDEX_ROOT}/issue-${ISSUE_IID}-execution-${EXECUTION_ID}.index"
mkdir -p "${INDEX_ROOT}"
if [ -e "${INDEX_FILE}" ] || [ -L "${INDEX_FILE}" ]; then
  INDEX_FILE="${INDEX_FILE}.$$.${RANDOM}"
fi

GIT_INDEX_FILE="${INDEX_FILE}" git -C "${WORKTREE_DIR}" read-tree --empty
GIT_INDEX_FILE="${INDEX_FILE}" git -C "${WORKTREE_DIR}" add -f -- "${ISSUE_LOG_REL}"
ARCHIVE_TREE="$(GIT_INDEX_FILE="${INDEX_FILE}" \
  git -C "${WORKTREE_DIR}" write-tree)"
if ! [[ "${ARCHIVE_TREE}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "archive_execution_logs: failed to build an archive tree" >&2
  exit 5
fi

git_network_guard_assert_repo "${WORKTREE_DIR}"
set +e
REMOTE_ROWS="$(git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --exit-code --heads origin "${ARCHIVE_BRANCH}" 2>/dev/null)"
REMOTE_STATUS=$?
set -e
case "${REMOTE_STATUS}" in
  0|2) ;;
  *) exit "${REMOTE_STATUS}" ;;
esac
REMOTE_TIPS="$(awk -v expected_ref="${ARCHIVE_REF}" \
  '$2 == expected_ref {print $1}' <<<"${REMOTE_ROWS}")"
REMOTE_TIP_COUNT="$(awk 'NF {count++} END {print count+0}' <<<"${REMOTE_TIPS}")"
if [ "${REMOTE_TIP_COUNT}" -gt 1 ]; then
  echo "archive_execution_logs: remote returned duplicate archive refs" >&2
  exit 5
fi
COMMIT_PARENT_ARGS=()
if [ "${REMOTE_TIP_COUNT}" -eq 1 ]; then
  REMOTE_TIP="$(awk 'NF {print; exit}' <<<"${REMOTE_TIPS}")"
  if ! GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
      cat-file -e "${REMOTE_TIP}^{commit}" 2>/dev/null; then
    git_network_guard_run "${WORKTREE_DIR}" fetch \
      --no-tags --refmap= origin \
      "+${ARCHIVE_REF}:refs/remotes/origin/${ARCHIVE_BRANCH}" >&2
  fi
  REMOTE_TREE="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-parse --verify "${REMOTE_TIP}^{tree}")"
  if [ "${REMOTE_TREE,,}" = "${ARCHIVE_TREE,,}" ]; then
    printf 'LOG_ARCHIVE_REF=%s\n' "${ARCHIVE_REF}"
    printf 'LOG_ARCHIVE_COMMIT=%s\n' "${REMOTE_TIP}"
    exit 0
  fi
  COMMIT_PARENT_ARGS=(-p "${REMOTE_TIP}")
fi

ARCHIVE_COMMIT="$(
  GIT_AUTHOR_NAME=req_executor \
  GIT_AUTHOR_EMAIL=req_executor@localhost \
  GIT_AUTHOR_DATE=2000-01-01T00:00:00Z \
  GIT_COMMITTER_NAME=req_executor \
  GIT_COMMITTER_EMAIL=req_executor@localhost \
  GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    git -C "${WORKTREE_DIR}" commit-tree "${ARCHIVE_TREE}" \
      "${COMMIT_PARENT_ARGS[@]}" \
      -m "chore(req_executor): archive issue-${ISSUE_IID} execution-${EXECUTION_ID} logs"
)"
if ! [[ "${ARCHIVE_COMMIT}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "archive_execution_logs: failed to create an archive commit" >&2
  exit 5
fi

if [ "${REMOTE_TIP_COUNT}" -eq 1 ]; then
  git_network_guard_run "${WORKTREE_DIR}" push \
    "--force-with-lease=${ARCHIVE_REF}:${REMOTE_TIP}" origin \
    "${ARCHIVE_COMMIT}:${ARCHIVE_REF}" >&2
else
  git_network_guard_run "${WORKTREE_DIR}" push \
    "--force-with-lease=${ARCHIVE_REF}:" origin \
    "${ARCHIVE_COMMIT}:${ARCHIVE_REF}" >&2
fi

VERIFY_ROWS="$(git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --heads origin "${ARCHIVE_BRANCH}")"
VERIFY_TIPS="$(awk -v expected_ref="${ARCHIVE_REF}" \
  '$2 == expected_ref {print $1}' <<<"${VERIFY_ROWS}")"
VERIFY_COUNT="$(awk 'NF {count++} END {print count+0}' <<<"${VERIFY_TIPS}")"
VERIFY_TIP="$(awk 'NF {print; exit}' <<<"${VERIFY_TIPS}")"
if [ "${VERIFY_COUNT}" -ne 1 ] \
    || [ "${VERIFY_TIP,,}" != "${ARCHIVE_COMMIT,,}" ]; then
  echo "archive_execution_logs: remote archive ref does not match the local commit" >&2
  exit 5
fi

printf 'LOG_ARCHIVE_REF=%s\n' "${ARCHIVE_REF}"
printf 'LOG_ARCHIVE_COMMIT=%s\n' "${ARCHIVE_COMMIT}"
