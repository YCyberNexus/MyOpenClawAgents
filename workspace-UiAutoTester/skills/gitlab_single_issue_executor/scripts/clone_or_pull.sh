#!/usr/bin/env bash
# clone_or_pull.sh — ensure ${REPO_PATH} exists as a clone of the project
# repo, with up-to-date refs. The MAIN repo's working tree is not used
# for issue work — every attempt gets its own git worktree. This script
# therefore only needs to keep refs current and the remote URL set right.
#
# Required env vars:
#   REPO_PATH               from env_paths.sh
#   BRANCH                  default branch (typically "master")
#   GROUP                   from trigger
#   PROJECT                 from trigger
#   GITLAB_TOKEN            from trigger
#   GITLAB_HOST             from glab_auth.sh (deployment pin)
#   GITLAB_API_PROTOCOL     from glab_auth.sh (deployment pin)

set -euo pipefail

: "${REPO_PATH:?}" "${BRANCH:?}" \
  "${GROUP:?}" "${PROJECT:?}" "${GITLAB_TOKEN:?}" \
  "${GITLAB_HOST:?run scripts/glab_auth.sh first}" \
  "${GITLAB_API_PROTOCOL:?run scripts/glab_auth.sh first}"

REMOTE_URL="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${GROUP}/${PROJECT}.git"
AUTHED_REMOTE_URL="$(echo "${REMOTE_URL}" | sed "s#://#://oauth2:${GITLAB_TOKEN}@#")"

mkdir -p /data

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
