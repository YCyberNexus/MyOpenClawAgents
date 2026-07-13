#!/usr/bin/env bash
# commit_and_push.sh — commit the staged changes inside the repo root and
# force-push the per-attempt local branch to the SINGLE fixed remote
# branch ${WORK_BRANCH} (Strategy A).
#
# Required env vars:
#   WORKTREE_DIR             repo root cwd for git commands
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   LOCAL_ATTEMPT_BRANCH     "issue/<iid>-att<NNN>"
#   WORK_BRANCH              "issue/<iid>" (single remote)
#   ISSUE_TITLE              short human title for commit message
#
# Why force-push: Strategy A keeps a single MR pointing at a single
# remote branch. Each attempt overwrites that branch's tip with the
# new attempt's history. Local attempt branches are preserved in
# ${REPO_PATH}/.git/refs/heads/ for audit; only the remote moves.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=commit_and_push

: "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${LOCAL_ATTEMPT_BRANCH:?}" "${WORK_BRANCH:?}" "${ISSUE_TITLE:?}"

cd "${WORKTREE_DIR}"
git_network_guard_assert_repo "${WORKTREE_DIR}"

git commit -m \
  "fix(issue-${ISSUE_IID}): ${ISSUE_TITLE} (attempt ${ATTEMPT_NUMBER_PADDED})"

# Force-push the local attempt branch to the fixed remote branch.
# Use --force-with-lease for an existing ref; use a normal push when the
# remote ref does not exist yet (first attempt).
set +e
git_network_guard_run "${WORKTREE_DIR}" \
  ls-remote --exit-code --heads origin "${WORK_BRANCH}" \
  >/dev/null
ls_remote_status=$?
set -e
case "${ls_remote_status}" in
  0)
    git_network_guard_run "${WORKTREE_DIR}" push --force-with-lease origin \
      "${LOCAL_ATTEMPT_BRANCH}:${WORK_BRANCH}" >&2
    ;;
  2)
    git_network_guard_run "${WORKTREE_DIR}" push origin \
      "${LOCAL_ATTEMPT_BRANCH}:${WORK_BRANCH}" >&2
    ;;
  *) exit "${ls_remote_status}" ;;
esac

git rev-parse HEAD
