#!/usr/bin/env bash
# clone_or_pull.sh — clone the project repo into REPO_PATH if missing,
# otherwise update the existing checkout.
#
# Required env vars:
#   REPO_PATH               from env_paths.sh
#   BRANCH                  default branch (typically "master")
#   GROUP                   from trigger
#   PROJECT                 from trigger
#   GITLAB_TOKEN            from trigger
#   GITLAB_HOST             from glab_auth.sh (deployment pin)
#   GITLAB_API_PROTOCOL     from glab_auth.sh (deployment pin)
#
# The remote URL is built from the deployment pin, NOT from any
# ${GITLAB_ADDRESS} trigger value. glab_auth.sh must run first.
#
# This script does NOT touch WORK_ROOT and does NOT switch to the issue
# work branch. Branch creation is the job of prepare_branch.sh.

set -euo pipefail

: "${REPO_PATH:?}" "${BRANCH:?}" \
  "${GROUP:?}" "${PROJECT:?}" "${GITLAB_TOKEN:?}" \
  "${GITLAB_HOST:?run scripts/glab_auth.sh first to populate GITLAB_HOST}" \
  "${GITLAB_API_PROTOCOL:?run scripts/glab_auth.sh first to populate GITLAB_API_PROTOCOL}"

REMOTE_URL="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${GROUP}/${PROJECT}.git"
AUTHED_REMOTE_URL="$(echo "${REMOTE_URL}" | sed "s#://#://oauth2:${GITLAB_TOKEN}@#")"

mkdir -p /data

if [ ! -d "${REPO_PATH}/.git" ]; then
  git clone -b "${BRANCH}" "${AUTHED_REMOTE_URL}" "${REPO_PATH}"
else
  cd "${REPO_PATH}"
  git remote set-url origin "${AUTHED_REMOTE_URL}"
  git fetch origin
  git checkout "${BRANCH}"
  git pull origin "${BRANCH}"
fi
