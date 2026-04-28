#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's repo changes inside the per-attempt
# worktree and guard against agent artifacts (or _hulat symlink) leaking
# into the work branch.
#
# Required env vars:
#   WORKTREE_DIR    git worktree (set by env_paths.sh)
#   LOG_DIR         where to write evidence files (under ATTEMPT_DIR)
#
# Exit codes:
#   0   normal staging completed; check stdout marker
#   3   agent artifacts leaked into the worktree; caller must mark issue blocked
#
# Stdout markers (one of these is printed):
#   STAGED_OK       there are staged changes ready to commit
#   NO_CHANGES      Claude produced no diff; caller writes status=no_changes
#
# Stderr on leak:
#   AGENT_ARTIFACTS_LEAKED followed by the offending paths

set -euo pipefail

: "${WORKTREE_DIR:?}" "${LOG_DIR:?}"

cd "${WORKTREE_DIR}"

git status --porcelain > "${LOG_DIR}/git_status.txt"
git diff > "${LOG_DIR}/git_diff.patch"

git add -A

LEAKED="$(git diff --cached --name-only \
  | grep -E '^(openclaw_log/|openclaw_state/|_hulat(/|$))' || true)"
if [ -n "${LEAKED}" ]; then
  echo "AGENT_ARTIFACTS_LEAKED" >&2
  echo "${LEAKED}" >&2
  exit 3
fi

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
