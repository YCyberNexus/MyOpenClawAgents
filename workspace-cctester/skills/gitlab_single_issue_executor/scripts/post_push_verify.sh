#!/usr/bin/env bash
# post_push_verify.sh — confirm the remote ${WORK_BRANCH} contains only
# repo code, no agent artifacts, no _hulat symlink, and no local Claude
# Code config. If verification fails the executor must mark the issue
# blocked and skip MR creation.
#
# Required env vars:
#   WORKTREE_DIR    git worktree (cwd; works because the worktree shares
#                   the main repo's refs)
#   WORK_BRANCH     "issue/<iid>-auto-fix"
#
# Exit codes:
#   0   remote is clean; safe to create / keep MR
#   4   remote contains agent artifacts; caller must mark issue blocked

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}"

cd "${WORKTREE_DIR}"
git fetch origin "${WORK_BRANCH}"

POLLUTED="$(
  git ls-tree -r --name-only "origin/${WORK_BRANCH}" \
    | grep -E '^(openclaw_log/|openclaw_state/|_hulat(/|$)|\.claude(/|$))' || true
)"

if [ -n "${POLLUTED}" ]; then
  echo "REMOTE_POLLUTED" >&2
  echo "${POLLUTED}" >&2
  exit 4
fi

echo "REMOTE_CLEAN"
