#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's changes from inside the shared
# per-issue linked git worktree at ${WORKTREE_DIR} (created on attempt 1
# and reused on later attempts by prepare_attempt.sh).
#
# All ordinary non-log files Claude wrote (or any non-log file already tracked
# on the base branch) go through. The script force-adds the current issue's
# ${OUTPUT_DIR} so that committable output survives the `/.req_executor/` line
# in `.git/info/exclude`. Runtime log files stay local: ${LOG_DIR} is never
# force-added, and any repository path under a `logs/` directory is removed
# from the index before commit.
# The script still distinguishes STAGED_OK from NO_CHANGES so the caller
# can short-circuit empty diffs.
#
# Required env vars:
#   WORKTREE_DIR    shared per-issue worktree cwd (set by env_paths.sh)
#   OUTPUT_DIR      current issue's primary result directory inside the worktree (force-added)
#   LOG_DIR         current-attempt log dir INSIDE the worktree;
#                   evidence files (git_status.txt / git_diff.patch) are written here
#   ISSUE_IID       current issue IID
#
# Exit codes:
#   0   normal staging completed; check stdout marker
#
# Stdout markers (one of these is printed):
#   STAGED_OK       there are staged changes ready to commit
#   NO_CHANGES      Claude produced no diff; caller marks the issue blocked

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"

: "${WORKTREE_DIR:?}" "${OUTPUT_DIR:?}" "${LOG_DIR:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"

unstage_log_paths() {
  git reset -q -- "${ISSUE_WORKTREE_REL}/log/" 2>/dev/null || true
  git reset -q -- "logs/" ":(glob)**/logs/**" 2>/dev/null || true
}

filter_non_log_paths() {
  awk -v issue_log_prefix="${ISSUE_WORKTREE_REL}/log/" '
    $0 == "" { next }
    index($0, issue_log_prefix) == 1 { next }
    $0 == "logs" || $0 ~ /^logs\// || $0 ~ /\/logs\// { next }
    { print }
  '
}

git status --porcelain > "${LOG_DIR}/git_status.txt"
git diff > "${LOG_DIR}/git_diff.patch"

deleted_paths="$(git diff --name-only --diff-filter=D \
  | filter_non_log_paths)"
if [ -n "${deleted_paths}" ]; then
  {
    echo "stage_and_guard: refusing to stage deleted files; destructive deletion is forbidden"
    echo "${deleted_paths}"
  } >&2
  exit 2
fi

git add -A

# In continue mode the worktree is checked out from origin/${WORK_BRANCH}
# which already has prior attempts' `log/attempt-NNN/prompt.txt` +
# `claude_result.txt` committed. `.git/info/exclude` only blocks untracked
# files, so any modification a Claude Code run accidentally makes under
# `.req_executor/issue-<iid>/log/` would be picked up by `git add -A`
# above and silently rewrite prior attempts' reviewer evidence. Unstage
# anything under that subtree before any output force-add below.
unstage_log_paths

staged_deleted_paths="$(git diff --cached --name-only --diff-filter=D \
  | filter_non_log_paths)"
if [ -n "${staged_deleted_paths}" ]; then
  {
    echo "stage_and_guard: refusing to commit deleted files; destructive deletion is forbidden"
    echo "${staged_deleted_paths}"
  } >&2
  exit 2
fi

if [ -f "${OUTPUT_DIR}" ]; then
  git add -f "${OUTPUT_DIR}"
elif [ -d "${OUTPUT_DIR}" ] && [ -n "$(find "${OUTPUT_DIR}" -type f -print -quit)" ]; then
  git add -f "${OUTPUT_DIR}"
fi

unstage_log_paths

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
