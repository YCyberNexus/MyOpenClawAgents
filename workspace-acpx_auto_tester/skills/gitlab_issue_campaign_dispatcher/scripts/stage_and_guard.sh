#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's repo changes from the main repo root
# and guard against committing protected runtime state.
#
# Why this guard:
#   - The only committable path under `ifp-result/` is this issue's
#     `${OUTPUT_DIR}`. Dispatcher state, logs, summaries, and other issue
#     subtrees are runtime/audit data and must never enter the work branch.
#
# Required env vars:
#   WORKTREE_DIR    repo root cwd (set by env_paths.sh)
#   OUTPUT_DIR      current issue's committable result directory
#   LOG_DIR         where to write evidence files (under ISSUE_ROOT/log/attempt-NNN)
#   ISSUE_IID       current issue IID
#
# Exit codes:
#   0   normal staging completed; check stdout marker
#   3   protected runtime paths leaked into staged changes; caller
#       must mark issue blocked
#
# Stdout markers (one of these is printed):
#   STAGED_OK       there are staged changes ready to commit
#   NO_CHANGES      Claude produced no diff; caller marks the issue blocked
#
# Stderr on leak:
#   PROTECTED_PATHS_LEAKED followed by the offending paths

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

ALLOWED_OUTPUT_RE="^ifp-result/issue-${ISSUE_IID}/hulat-spec-issue${ISSUE_IID}(/|$)"
LEAKED="$(
  git diff --cached --name-only \
    | { grep -E '^(ifp-result/)' || true; } \
    | { grep -vE "${ALLOWED_OUTPUT_RE}" || true; }
)"
if [ -n "${LEAKED}" ]; then
  echo "PROTECTED_PATHS_LEAKED" >&2
  echo "${LEAKED}" >&2
  exit 3
fi

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
