#!/usr/bin/env bash
# post_push_verify.sh — sanity-check that the push made it to origin.
#
# Path-based protection has been removed: this script no longer rejects
# anything in the per-issue diff. It only fetches the relevant remote refs so
# the caller can be sure the immutable per-attempt branch
# origin/${LOCAL_ATTEMPT_BRANCH} exists after Step 3, then prints REMOTE_CLEAN
# and exits 0. The legacy mutable ${WORK_BRANCH} is no longer pushed on this
# branch (commit_and_push.sh publishes only the immutable per-attempt branch),
# so verifying it would fetch a non-existent ref and fail.
#
# Required env vars:
#   WORKTREE_DIR          repo root cwd
#   LOCAL_ATTEMPT_BRANCH  "issue/<iid>-auto-fix-att<NNN>" (the single remote)
#   BRANCH                integration / target branch
#   ISSUE_IID             current issue IID (kept for log correlation)
#
# Exit codes:
#   0   remote fetch succeeded; origin/${LOCAL_ATTEMPT_BRANCH} is present
#   non-zero only if `git fetch` itself fails

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${LOCAL_ATTEMPT_BRANCH:?}" "${BRANCH:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"
git fetch origin "${LOCAL_ATTEMPT_BRANCH}"
git fetch origin "${BRANCH}"

echo "REMOTE_CLEAN"
