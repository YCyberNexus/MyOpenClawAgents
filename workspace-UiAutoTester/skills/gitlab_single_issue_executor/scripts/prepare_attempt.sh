#!/usr/bin/env bash
# prepare_attempt.sh — create the per-attempt git worktree, base it on the
# right starting point, set up the _hulat symlink, and write the
# .git/info/exclude for the worktree.
#
# Strategy A — single fixed remote branch ${WORK_BRANCH} ("issue/<iid>-auto-fix").
# Each attempt gets its own LOCAL branch (${LOCAL_ATTEMPT_BRANCH},
# "${WORK_BRANCH}-att${PADDED}") that is force-pushed to ${WORK_BRANCH}
# at commit time. Worktrees collide if two attempts checked out the same
# local branch, so each attempt uses a unique local branch name.
#
# Modes (env var ISSUE_MODE):
#   fresh     — base attempt on origin/${BRANCH}; the previous attempts'
#               work is intentionally discarded (Claude redoes from scratch)
#   continue  — base attempt on origin/${WORK_BRANCH} if it exists, else
#               downgrade to fresh
#
# Required env vars (all from env_paths.sh + glab_auth.sh + trigger):
#   REPO_PATH, BRANCH, ISSUE_IID, ISSUE_MODE,
#   ATTEMPT_DIR, WORKTREE_DIR, ATTEMPT_NUMBER_PADDED,
#   WORK_BRANCH, LOCAL_ATTEMPT_BRANCH, HULAT_DIR
#
# Output (to stdout, two lines):
#   <actual-mode>           "fresh" or "continue"
#   <local-branch-name>     ${LOCAL_ATTEMPT_BRANCH}

set -euo pipefail

: "${REPO_PATH:?}" "${BRANCH:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" \
  "${ATTEMPT_DIR:?}" "${WORKTREE_DIR:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${WORK_BRANCH:?}" "${LOCAL_ATTEMPT_BRANCH:?}" "${HULAT_DIR:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "prepare_attempt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

# Refresh refs. clone_or_pull.sh has already fetched, but do it again
# defensively in case this script is run standalone.
cd "${REPO_PATH}"
git fetch --prune origin

# Resolve the actual base ref.
BASE_REF="origin/${BRANCH}"
ACTUAL_MODE="${ISSUE_MODE}"
if [ "${ACTUAL_MODE}" = "continue" ]; then
  if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
    BASE_REF="origin/${WORK_BRANCH}"
  else
    ACTUAL_MODE=fresh
    BASE_REF="origin/${BRANCH}"
  fi
fi

# If WORKTREE_DIR happens to exist (interrupted prior run), nuke it so
# `worktree add` can succeed cleanly.
if [ -e "${WORKTREE_DIR}" ]; then
  if [ -d "${WORKTREE_DIR}" ]; then
    git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true
    rm -rf "${WORKTREE_DIR}"
  else
    rm -f "${WORKTREE_DIR}"
  fi
fi
git worktree prune

# If a stale local branch with this name exists (shouldn't, since
# attempt numbers monotonically increase, but guard anyway), drop it.
if git show-ref --verify --quiet "refs/heads/${LOCAL_ATTEMPT_BRANCH}"; then
  git branch -D "${LOCAL_ATTEMPT_BRANCH}"
fi

mkdir -p "${ATTEMPT_DIR}"
git worktree add -b "${LOCAL_ATTEMPT_BRANCH}" "${WORKTREE_DIR}" "${BASE_REF}"

# Set up _hulat symlink inside the worktree (zero-cost shared read-only
# config). Also exclude it from git via .git/info/exclude (worktree's
# own git dir, not the main repo's).
cd "${WORKTREE_DIR}"
ln -sfn "${HULAT_DIR}" "_hulat"

# .git in a worktree is a file pointing to ../../.git/worktrees/<name>;
# `git rev-parse --git-path info/exclude` resolves to the right place.
EXCLUDE_FILE="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "${EXCLUDE_FILE}")"
{
  echo "# managed by prepare_attempt.sh"
  echo "/_hulat"
} > "${EXCLUDE_FILE}"

echo "${ACTUAL_MODE}"
echo "${LOCAL_ATTEMPT_BRANCH}"
