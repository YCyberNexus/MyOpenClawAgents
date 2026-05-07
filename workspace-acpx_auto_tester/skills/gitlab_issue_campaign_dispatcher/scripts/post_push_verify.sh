#!/usr/bin/env bash
# post_push_verify.sh — confirm the remote ${WORK_BRANCH} contains only
# this issue's content, with no foreign `ifp_result/issue-<other-iid>/`
# subtrees and no `ifp_result/_dispatcher/` subtree. If verification
# fails the executor must mark the issue blocked and skip MR creation.
#
# As of SKILL_VERSION 2026-05-07.0 the leak surface is `ifp_result/`
# only — `hulat/`, `.claude/`, and `ifp_data/` are valid repo content
# committed by the test team and are no longer rejected.
#
# Required env vars:
#   WORKTREE_DIR    git worktree (cwd; works because the worktree shares
#                   the main repo's refs)
#   WORK_BRANCH     "issue/<iid>-auto-fix"
#   ISSUE_IID       current issue IID (used to whitelist its own
#                   ifp_result subdir; everything else under ifp_result/
#                   is treated as foreign)
#
# Exit codes:
#   0   remote is clean; safe to create / keep MR
#   4   remote contains foreign ifp_result subtree(s); caller must mark
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
    | grep -E '^ifp_result/(_dispatcher/|issue-[0-9]+/)' \
    | grep -vE "^ifp_result/issue-${ISSUE_IID}/" \
    || true
)"

if [ -n "${POLLUTED}" ]; then
  echo "REMOTE_POLLUTED" >&2
  echo "${POLLUTED}" >&2
  exit 4
fi

echo "REMOTE_CLEAN"
