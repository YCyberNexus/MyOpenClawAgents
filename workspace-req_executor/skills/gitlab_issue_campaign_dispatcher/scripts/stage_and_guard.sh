#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's changes from inside the shared
# per-issue linked git worktree at ${WORKTREE_DIR} (created on attempt 1
# and reused on later attempts by prepare_attempt.sh).
#
# All path-based protection has been removed: any file Claude wrote (or
# any file already tracked on the base branch) goes through. The script
# force-adds two sets of paths so they survive the `${RESULT_BASENAME}/`
# line in `.git/info/exclude` (default `ifp-result/`, overridable per
# project via the `result_basename` trigger field, and repository-wide
# so it applies to every linked worktree):
#   - the current issue's ${OUTPUT_DIR} (the committable output);
#   - ${LOG_DIR}/prompt.txt and ${LOG_DIR}/claude_result.txt (the two
#     human-reviewable evidence files; intentionally NOT the bulky
#     acpx_raw.log / git_diff.patch / wiki_* / mr_description.md, which
#     stay locally ignored and disappear with the worktree).
# The script still distinguishes STAGED_OK from NO_CHANGES so the caller
# can short-circuit empty diffs.
#
# Required env vars:
#   WORKTREE_DIR    shared per-issue worktree cwd (set by env_paths.sh)
#   OUTPUT_DIR      current issue's primary result directory inside the worktree (force-added)
#   LOG_DIR         current-attempt log dir INSIDE the worktree (force-add list above);
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${OUTPUT_DIR:?}" "${LOG_DIR:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"

git status --porcelain > "${LOG_DIR}/git_status.txt"
git diff > "${LOG_DIR}/git_diff.patch"

deleted_paths="$(git diff --name-only --diff-filter=D)"
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
# `<RESULT_BASENAME>/issue-<iid>/log/` would be picked up by `git add -A`
# above and silently rewrite prior attempts' reviewer evidence. Unstage
# anything under that subtree before the explicit force-add for the
# current attempt's two files.
git reset -q -- "${RESULT_BASENAME}/issue-${ISSUE_IID}/log/" 2>/dev/null || true

staged_deleted_paths="$(git diff --cached --name-only --diff-filter=D)"
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

# Force-add the two reviewer-facing log files so they land in the MR
# diff. acpx_raw.log / git_status.txt / git_diff.patch / wiki_* /
# mr_description.md are intentionally NOT force-added; they remain
# locally ignored under `.git/info/exclude` and are discarded with the
# worktree on housekeeping.
for log_file in "${LOG_DIR}/prompt.txt" "${LOG_DIR}/claude_result.txt"; do
  if [ -f "${log_file}" ]; then
    git add -f "${log_file}"
  fi
done

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
