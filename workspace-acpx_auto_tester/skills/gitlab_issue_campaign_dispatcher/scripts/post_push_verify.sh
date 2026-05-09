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
#   WORK_BRANCH     "issue/<iid>-auto-fix"
#   BRANCH          integration / target branch
#   ISSUE_IID       current issue IID (kept for log correlation)
#
# Exit codes:
#   0   remote fetch succeeded; safe to create / keep MR
#   non-zero only if `git fetch` itself fails

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" "${BRANCH:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"
git fetch origin "${WORK_BRANCH}"
git fetch origin "${BRANCH}"

echo "REMOTE_CLEAN"
