#!/usr/bin/env bash
# prepare_attempt.sh — replace the issue's git worktree for this attempt
# and base it on the right starting point.
#
# Strategy A — single fixed remote branch ${WORK_BRANCH} ("issue/<iid>-auto-fix").
# Each attempt gets its own LOCAL branch (${LOCAL_ATTEMPT_BRANCH},
# "${WORK_BRANCH}-att${PADDED}") that is force-pushed to ${WORK_BRANCH}
# at commit time. Worktrees collide if two attempts checked out the same
# local branch, so each attempt uses a unique local branch name.
#
# Modes (env var ISSUE_MODE):
#   fresh     — base attempt on origin/${DEV_BRANCH} (clean baseline,
#               no past spec accumulation visible to Claude). The
#               previous attempts' work is intentionally discarded.
#   continue  — base attempt on origin/${WORK_BRANCH} if it exists, else
#               downgrade to fresh (and use origin/${DEV_BRANCH})
#
# Why DEV_BRANCH and not BRANCH for fresh mode:
#   BRANCH is the integration target (e.g. master) and accumulates every
#   completed issue's spec output. Checking out from BRANCH would expose
#   Claude to past issues' files in the worktree, polluting context and
#   inviting accidental edits. DEV_BRANCH is a clean baseline (no spec
#   output) so each fresh attempt starts from zero. PRs still target
#   BRANCH — only the source baseline changes.
#
# What this script does NOT do:
#   - It does NOT symlink hulat into the worktree. The test team committed
#     `hulat/` to master+dev, so the worktree's checkout already contains it.
#   - It does NOT copy a `.claude/` runtime config into the worktree. The
#     test team committed `.claude/` to master+dev, so the worktree's
#     checkout already contains that too.
#   - It does NOT write `.git/info/exclude`. There is nothing local-only
#     in the worktree any more — every directory the agent touches is
#     either a tracked repo path or under the gitignored `ifp_result/`
#     subtree (the latter only used by the dispatcher OUTSIDE this worktree).
#
# Required env vars (all from env_paths.sh + glab_auth.sh + trigger):
#   REPO_PATH, BRANCH, DEV_BRANCH, ISSUE_IID, ISSUE_MODE,
#   ATTEMPT_DIR, WORKTREE_DIR, LOG_DIR, ATTEMPT_NUMBER_PADDED,
#   WORK_BRANCH, LOCAL_ATTEMPT_BRANCH
#
# Output (to stdout, two lines):
#   <actual-mode>           "fresh" or "continue"
#   <local-branch-name>     ${LOCAL_ATTEMPT_BRANCH}

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${REPO_PATH:?}" "${WORK_ROOT:?}" "${BRANCH:?}" "${DEV_BRANCH:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" \
  "${ATTEMPT_DIR:?}" "${WORKTREE_DIR:?}" "${LOG_DIR:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${WORK_BRANCH:?}" "${LOCAL_ATTEMPT_BRANCH:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "prepare_attempt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

LOCK_DIR="${WORK_ROOT}/locks"
mkdir -p "${LOCK_DIR}"
exec 8>"${LOCK_DIR}/repo.lock"
flock 8

# Refresh refs. clone_or_pull.sh has already fetched, but do it again
# defensively in case this script is run standalone.
cd "${REPO_PATH}"
git fetch --prune origin

# Resolve the actual base ref.
# Fresh mode bases on DEV_BRANCH (clean baseline). Continue mode tries
# WORK_BRANCH first; if missing, downgrade to fresh on DEV_BRANCH.
BASE_REF="origin/${DEV_BRANCH}"
ACTUAL_MODE="${ISSUE_MODE}"
if [ "${ACTUAL_MODE}" = "continue" ]; then
  if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
    BASE_REF="origin/${WORK_BRANCH}"
  else
    ACTUAL_MODE=fresh
    BASE_REF="origin/${DEV_BRANCH}"
  fi
fi

# Sanity check the resolved BASE_REF actually exists. If DEV_BRANCH is
# missing on the remote, fail loudly — there is no further fallback.
if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
  echo "prepare_attempt: base ref ${BASE_REF} does not exist on origin" >&2
  echo "Check that --dev_branch=${DEV_BRANCH} is correct and the branch exists on the remote." >&2
  exit 5
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

# The issue directory is reused across attempts, but logs are preserved
# per attempt under log/attempt-NNN. Recreate only the current attempt's
# log directory so stale evidence from a same-attempt rerun is not mixed
# with the current run.
if [ -d "${LOG_DIR}" ]; then
  rm -rf "${LOG_DIR}"
fi
mkdir -p "${LOG_DIR}"

# If a stale local branch with this name exists (shouldn't, since
# attempt numbers monotonically increase, but guard anyway), drop it.
if git show-ref --verify --quiet "refs/heads/${LOCAL_ATTEMPT_BRANCH}"; then
  git branch -D "${LOCAL_ATTEMPT_BRANCH}"
fi

mkdir -p "${ATTEMPT_DIR}"
git worktree add -b "${LOCAL_ATTEMPT_BRANCH}" "${WORKTREE_DIR}" "${BASE_REF}"
flock -u 8

echo "${ACTUAL_MODE}"
echo "${LOCAL_ATTEMPT_BRANCH}"
