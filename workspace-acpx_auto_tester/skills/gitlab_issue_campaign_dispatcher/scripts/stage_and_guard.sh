#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's repo changes from the main repo root.
#
# All path-based protection has been removed: any file Claude wrote (or
# any file already tracked on the base branch) goes through. The script
# still force-adds the current issue's ${OUTPUT_DIR} so it survives the
# `${RESULT_BASENAME}/` line in `.git/info/exclude` (default `ifp-result/`,
# overridable per project via the `result_basename` trigger field), and
# still distinguishes STAGED_OK from NO_CHANGES so the caller can short-
# circuit empty diffs.
#
# Required env vars:
#   WORKTREE_DIR    repo root cwd (set by env_paths.sh)
#   OUTPUT_DIR      current issue's primary result directory (force-added)
#   LOG_DIR         where to write evidence files (under ISSUE_ROOT/log/attempt-NNN)
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

git add -A

if [ -f "${OUTPUT_DIR}" ]; then
  git add -f "${OUTPUT_DIR}"
elif [ -d "${OUTPUT_DIR}" ] && [ -n "$(find "${OUTPUT_DIR}" -type f -print -quit)" ]; then
  git add -f "${OUTPUT_DIR}"
fi

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
