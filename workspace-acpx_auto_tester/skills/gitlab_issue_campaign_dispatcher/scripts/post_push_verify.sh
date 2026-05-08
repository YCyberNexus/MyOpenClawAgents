#!/usr/bin/env bash
# post_push_verify.sh — confirm the remote ${WORK_BRANCH} contains only
# this issue's content, with no foreign `ifp-result/issue-<other-iid>/`
# subtrees and no `ifp-result/_dispatcher/` subtree. If verification
# fails the executor must mark the issue blocked and skip MR creation.
#
# The leak surface is `ifp-result/` only — `hulat/`, `.claude/`, and
# `ifp-data/` are valid repo content committed by the test team and are
# not rejected.
#
# Required env vars:
#   WORKTREE_DIR    git worktree (cwd; works because the worktree shares
#                   the main repo's refs)
#   WORK_BRANCH     "issue/<iid>-auto-fix"
#   ISSUE_IID       current issue IID (used to whitelist its own
#                   ifp-result subdir; everything else under ifp-result/
#                   is treated as foreign)
#
# Exit codes:
#   0   remote is clean; safe to create / keep MR
#   4   remote contains foreign ifp-result subtree(s); caller must mark
#       issue blocked

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"
git fetch origin "${WORK_BRANCH}"

POLLUTED="$(
  git ls-tree -r --name-only "origin/${WORK_BRANCH}" \
    | grep -E '^ifp-result/(_dispatcher/|issue-[0-9]+/)' \
    | grep -vE "^ifp-result/issue-${ISSUE_IID}/" \
    || true
)"

if [ -n "${POLLUTED}" ]; then
  echo "REMOTE_POLLUTED" >&2
  echo "${POLLUTED}" >&2
  exit 4
fi

echo "REMOTE_CLEAN"
