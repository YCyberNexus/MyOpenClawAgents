#!/usr/bin/env bash
# commit_and_push.sh — commit the staged changes inside the worktree and
# force-push the per-attempt local branch to the SINGLE fixed remote
# branch ${WORK_BRANCH} (Strategy A).
#
# Required env vars:
#   WORKTREE_DIR             git worktree (cwd for git commands)
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   LOCAL_ATTEMPT_BRANCH     "issue/<iid>-auto-fix-att<NNN>"
#   WORK_BRANCH              "issue/<iid>-auto-fix" (single remote)
#   ISSUE_TITLE              short human title for commit message
#
# Why force-push: Strategy A keeps a single MR pointing at a single
# remote branch. Each attempt overwrites that branch's tip with the
# new attempt's history. Local attempt branches are preserved in
# ${REPO_PATH}/.git/refs/heads/ for audit; only the remote moves.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${LOCAL_ATTEMPT_BRANCH:?}" "${WORK_BRANCH:?}" "${ISSUE_TITLE:?}"

cd "${WORKTREE_DIR}"

git commit -m "fix(issue-${ISSUE_IID}): ${ISSUE_TITLE} (attempt ${ATTEMPT_NUMBER_PADDED})"

# Force-push the local attempt branch to the fixed remote branch.
# Use --force-with-lease where possible; fall back to --force if the
# remote ref doesn't exist yet (first attempt).
if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
  git push --force-with-lease origin "${LOCAL_ATTEMPT_BRANCH}:${WORK_BRANCH}"
else
  git push origin "${LOCAL_ATTEMPT_BRANCH}:${WORK_BRANCH}"
fi

git rev-parse HEAD
