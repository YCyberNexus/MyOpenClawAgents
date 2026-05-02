#!/usr/bin/env bash
# clone_or_pull.sh — ensure ${REPO_PATH} exists as a clone of the project
# repo, with up-to-date refs. The MAIN repo's working tree is not used
# for issue work — each issue gets a separate git worktree that is replaced
# for every attempt. This script only needs to keep refs current and the
# remote URL set right.
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

mkdir -p /data
LOCK_DIR="${WORK_ROOT}/locks"
mkdir -p "${LOCK_DIR}"
exec 8>"${LOCK_DIR}/repo.lock"
flock 8

if [ ! -d "${REPO_PATH}/.git" ]; then
  git clone -b "${BRANCH}" "${AUTHED_REMOTE_URL}" "${REPO_PATH}"
else
  cd "${REPO_PATH}"
  git remote set-url origin "${AUTHED_REMOTE_URL}"
  git fetch --prune origin
fi

# Prune any stale worktree entries — worktree dirs deleted out-of-band
# leave records in .git/worktrees that interfere with `worktree add`.
cd "${REPO_PATH}"
git worktree prune
