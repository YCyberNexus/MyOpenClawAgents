#!/usr/bin/env bash
# stage_and_guard.sh — stage Claude's repo changes inside the issue
# worktree and guard against this issue's commit accidentally pulling in
# another issue's `ifp_result/` subtree (or the campaign-level
# `ifp_result/_dispatcher/` subtree).
#
# Why this guard:
#   - `hulat/`, `.claude/`, and `ifp_data/` are committed by the test
#     team to master+dev. They are valid repo content. The guard does NOT
#     reject changes inside them — if Claude edits them, that's a
#     content concern (caught at MR review), not a repo-cleanliness
#     concern.
#   - The agent's runtime state lives at `${REPO_PATH}/ifp_result/...`
#     OUTSIDE the worktree's path. Inside the worktree, `ifp_result/` is
#     the project's own gitignored placeholder (since master/dev
#     gitignore ifp_result content). Anything staged under
#     `ifp_result/_dispatcher/` or another issue's
#     `ifp_result/issue-<other-iid>/` is a structural leak — almost
#     certainly the result of a `git add -f` past gitignore — and is
#     blocked.
#
# Required env vars:
#   WORKTREE_DIR    git worktree (set by env_paths.sh)
#   LOG_DIR         where to write evidence files (under ISSUE_ROOT/log/attempt-NNN)
#   ISSUE_IID       current issue IID (used to whitelist the matching
#                   ifp_result subdir)
#
# Exit codes:
#   0   normal staging completed; check stdout marker
#   3   another-issue / dispatcher ifp_result subtree leaked into the
#       worktree's staged changes; caller must mark issue blocked
#
# Stdout markers (one of these is printed):
#   STAGED_OK       there are staged changes ready to commit
#   NO_CHANGES      Claude produced no diff; caller writes status=no_changes
#
# Stderr on leak:
#   FOREIGN_IFP_RESULT_LEAKED followed by the offending paths

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${LOG_DIR:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"

git status --porcelain > "${LOG_DIR}/git_status.txt"
git diff > "${LOG_DIR}/git_diff.patch"

git add -A

LEAKED="$(git diff --cached --name-only \
  | grep -E '^ifp_result/(_dispatcher/|issue-[0-9]+/)' \
  | grep -vE "^ifp_result/issue-${ISSUE_IID}/" \
  || true)"
if [ -n "${LEAKED}" ]; then
  echo "FOREIGN_IFP_RESULT_LEAKED" >&2
  echo "${LEAKED}" >&2
  exit 3
fi

if [ -z "$(git diff --cached --name-only)" ]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "STAGED_OK"
