#!/usr/bin/env bash
# post_push_verify.sh — sanity-check that the force-push made it to origin.
#
# Path-based protection has been removed: this script no longer rejects
# anything in the MR diff. It only fetches the relevant remote refs so the
# caller can be sure origin/${WORK_BRANCH} exists after Step 3, then prints
# REMOTE_CLEAN and exits 0.
#
# Required env vars:
#   WORKTREE_DIR    repo root cwd
#   WORK_BRANCH     `issue/<iid>` or frozen shared `issue/<head>+<tail>`
#   BRANCH          integration / target branch
#   ISSUE_IID       current issue IID (kept for log correlation)
#
# Exit codes:
#   0   remote fetch succeeded; safe to create / keep MR
#   non-zero only if `git fetch` itself fails

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=post_push_verify

: "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" "${BRANCH:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"
GIT_NO_REPLACE_OBJECTS=1 git_network_guard_run "${WORKTREE_DIR}" fetch \
  --no-tags --refmap= origin \
  "+refs/heads/${WORK_BRANCH}:refs/remotes/origin/${WORK_BRANCH}" >&2
GIT_NO_REPLACE_OBJECTS=1 git_network_guard_run "${WORKTREE_DIR}" fetch \
  --no-tags --refmap= origin \
  "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" >&2

echo "REMOTE_CLEAN"
