#!/usr/bin/env bash
# clone_or_pull.sh — ensure ${REPO_PATH} exists as a clone of the project
# repo, with up-to-date refs, and create the agent's runtime subtree at
# ${REPO_PATH}/ifp_result/.
#
# As of SKILL_VERSION 2026-05-07.0 the agent's state lives INSIDE the
# cloned repo at `${REPO_PATH}/ifp_result/`. Before the first clone, that
# subtree does not exist — the bootstrap order is:
#
#   1. Ensure /data exists.
#   2. If repo is missing, acquire a tmpfs lock and `git clone`. We can't
#      use the in-repo lock yet because the repo doesn't exist.
#   3. After clone, create the dispatcher subtree (_dispatcher/log,
#      _dispatcher/locks) and the issue subtree root (ifp_result/).
#   4. Acquire the in-repo flock and run `git fetch` + `git worktree prune`.
#
# The MAIN repo's working tree is not used for issue work — each issue
# gets a separate git worktree at `${REPO_PATH}/ifp_result/issue-<iid>/worktree/`
# that is replaced for every attempt. The main worktree is only needed
# because `git worktree add` requires an existing repo to host links
# from.
#
# Required env vars:
#   REPO_PATH               from env_paths.sh
#   BRANCH                  integration / target branch (typically "master")
#   GROUP                   from trigger
#   PROJECT                 from trigger
#   GITLAB_TOKEN            from trigger
#   GITLAB_HOST             from glab_auth.sh (deployment pin)
#   GITLAB_API_PROTOCOL     from glab_auth.sh (deployment pin)
#
# DEV_BRANCH is consulted by prepare_attempt.sh, not here. `git fetch
# --prune origin` retrieves all branches, so DEV_BRANCH refs are
# available without a separate fetch.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${REPO_PATH:?}" "${WORK_ROOT:?}" "${BRANCH:?}" \
  "${GROUP:?}" "${PROJECT:?}" "${GITLAB_TOKEN:?}" \
  "${GITLAB_HOST:?run scripts/glab_auth.sh first}" \
  "${GITLAB_API_PROTOCOL:?run scripts/glab_auth.sh first}"

REMOTE_URL="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${GROUP}/${PROJECT}.git"
AUTHED_REMOTE_URL="$(echo "${REMOTE_URL}" | sed "s#://#://oauth2:${GITLAB_TOKEN}@#")"

mkdir -p "$(dirname "${REPO_PATH}")"

# ─── First-time bootstrap (no in-repo lock yet) ───────────────────
if [ ! -d "${REPO_PATH}/.git" ]; then
  BOOTSTRAP_LOCK="/tmp/acpx_auto_tester.clone.${PROJECT}.lock"
  exec 7>"${BOOTSTRAP_LOCK}"
  flock 7
  if [ ! -d "${REPO_PATH}/.git" ]; then  # re-check after acquiring lock
    if [ -d "${REPO_PATH}" ]; then
      # Partial state from a prior interrupted bootstrap (e.g. env_paths.sh
      # mkdir'd the ifp_result subtree before we got here on a previous
      # tick that crashed before clone). git clone refuses a non-empty
      # target, so wipe and retry. Safe because no .git/ means no real
      # work is in this directory.
      rm -rf "${REPO_PATH}"
    fi
    git clone -b "${BRANCH}" "${AUTHED_REMOTE_URL}" "${REPO_PATH}"
  fi
  flock -u 7
fi

# ─── Now ${REPO_PATH} is guaranteed to be a real clone. ───────────
# Create the dispatcher subtree (env_paths.sh skipped this on the first
# pass because ${REPO_PATH}/.git did not yet exist).
mkdir -p \
  "${WORK_ROOT}" \
  "${STATE_DIR}" \
  "${LOG_ROOT}" \
  "${DISPATCHER_LOG_DIR}" \
  "${ISSUES_ROOT}" \
  "${WORK_ROOT}/locks"

# Acquire the in-repo lock for fetch + worktree prune. This is the same
# lock prepare_attempt.sh uses, so concurrent fetch + worktree-add are
# serialized.
LOCK_DIR="${WORK_ROOT}/locks"
exec 8>"${LOCK_DIR}/repo.lock"
flock 8

cd "${REPO_PATH}"
git remote set-url origin "${AUTHED_REMOTE_URL}"
git fetch --prune origin

# Prune any stale worktree entries — worktree dirs deleted out-of-band
# leave records in .git/worktrees that interfere with `worktree add`.
git worktree prune
