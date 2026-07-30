#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's changes from inside the shared
# per-issue linked git worktree at ${WORKTREE_DIR} (created on the first
# execution and reused by later executions through prepare_attempt.sh).
#
# All ordinary non-log files Claude wrote (or any non-log file already tracked
# on the base branch) go through. The script force-adds the current issue's
# ${OUTPUT_DIR} and the complete staging-time ${LOG_DIR} so both survive the
# `/.req_executor/` line in `.git/info/exclude` and enter the same WORK_BRANCH
# business commit. Files created after that commit are appended by
# archive_execution_logs.sh as a log-only child on the same branch. Unrelated
# repository paths under a `logs/` directory remain local and are removed from
# the index.
# The script still distinguishes STAGED_OK from NO_CHANGES so the caller
# can short-circuit empty diffs.
#
# Required env vars:
#   WORKTREE_DIR    shared per-issue worktree cwd (set by env_paths.sh)
#   OUTPUT_DIR      current issue's primary result directory inside the worktree (force-added)
#   LOG_DIR         current-execution log dir INSIDE the worktree (force-added);
#                   all files present at staging time are committed
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

unstage_managed_and_generic_log_paths() {
  git reset -q -- "${ISSUE_WORKTREE_REL}/log/" 2>/dev/null || true
  git reset -q -- "logs/" ":(glob)**/logs/**" 2>/dev/null || true
}

filter_non_generic_log_paths() {
  awk '
    $0 == "" { next }
    $0 == "logs" || $0 ~ /^logs\// || $0 ~ /\/logs\// { next }
    { print }
  '
}

git status --porcelain > "${LOG_DIR}/git_status.txt"
git diff > "${LOG_DIR}/git_diff.patch"

deleted_paths="$(git diff --name-only --diff-filter=D \
  | filter_non_generic_log_paths)"
if [ -n "${deleted_paths}" ]; then
  {
    echo "stage_and_guard: refusing to stage deleted files; destructive deletion is forbidden"
    echo "${deleted_paths}"
  } >&2
  exit 2
fi

git add -A

# `.git/info/exclude` only blocks untracked files, so a repository that already
# tracks paths under the issue-local log directory could still stage them via
# `git add -A`. Unstage the whole issue log subtree first so a current execution
# cannot rewrite another execution's evidence; the current LOG_DIR is added
# back explicitly below.
unstage_managed_and_generic_log_paths

staged_deleted_paths="$(git diff --cached --name-only --diff-filter=D \
  | filter_non_generic_log_paths)"
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

# Decide whether Claude produced a committable business change before adding
# executor evidence. LOG_DIR is always non-empty, so checking after its
# force-add would turn every log-only execution into STAGED_OK.
git reset -q -- "logs/" ":(glob)**/logs/**" 2>/dev/null || true
if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

# Manage the complete current execution log directory, not a hard-coded file
# allowlist. This intentionally includes prompt/result text, raw acpx output,
# git snapshots, and structured evidence already present at staging time.
if [ -d "${LOG_DIR}" ]; then
  git add -f "${LOG_DIR}"
fi

# LOG_DIR is singular (`.../log/...`) and is not matched by these generic
# `logs/` rules. Re-apply the generic filter after both force-add operations.
git reset -q -- "logs/" ":(glob)**/logs/**" 2>/dev/null || true

final_staged_deleted_paths="$(git diff --cached --name-only --diff-filter=D \
  | filter_non_generic_log_paths)"
if [ -n "${final_staged_deleted_paths}" ]; then
  {
    echo "stage_and_guard: refusing to commit deleted files; destructive deletion is forbidden"
    echo "${final_staged_deleted_paths}"
  } >&2
  exit 2
fi

echo "STAGED_OK"
