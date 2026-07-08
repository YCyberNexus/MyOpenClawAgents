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
#   - the current issue's ${OUTPUT_DIR} (the committable spec output);
#   - the ENTIRE ${LOG_DIR} (eval branch full archival: acpx_raw.log,
#     git_diff.patch, acpx_command.txt, timing.txt, metrics.json,
#     prompt.txt, claude_result.txt) so every attempt's full evidence
#     lands in its immutable per-attempt branch for benchmarking.
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

# eval mode: force-add the ENTIRE attempt log dir so every artifact
# (acpx_raw.log, git_diff.patch, acpx_command.txt, timing.txt, metrics.json,
# prompt.txt, claude_result.txt) lands in the per-attempt branch for
# benchmarking. The ${RESULT_BASENAME}/ line in .git/info/exclude would
# otherwise hide all of it; -f bypasses that.
if [ -d "${LOG_DIR}" ] && [ -n "$(find "${LOG_DIR}" -type f -print -quit)" ]; then
  git add -f "${LOG_DIR}"
fi

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
