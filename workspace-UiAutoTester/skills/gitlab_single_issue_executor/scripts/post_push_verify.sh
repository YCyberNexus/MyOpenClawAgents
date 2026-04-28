#!/usr/bin/env bash
# post_push_verify.sh — confirm the remote ${WORK_BRANCH} contains only
# repo code, no agent artifacts and no _hulat symlink. If verification
# fails the executor must mark the issue blocked and skip MR creation.
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

: "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}"

cd "${WORKTREE_DIR}"
git fetch origin "${WORK_BRANCH}"

POLLUTED="$(
  git ls-tree -r --name-only "origin/${WORK_BRANCH}" \
    | grep -E '^(openclaw_log/|openclaw_state/|_hulat(/|$))' || true
)"

if [ -n "${POLLUTED}" ]; then
  echo "REMOTE_POLLUTED" >&2
  echo "${POLLUTED}" >&2
  exit 4
fi

echo "REMOTE_CLEAN"
