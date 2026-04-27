#!/usr/bin/env bash
# clone_or_pull.sh — clone the project repo into REPO_PATH if missing,
# otherwise update the existing checkout.
#
# Required env vars:
#   REPO_PATH        from env_paths.sh
#   BRANCH           default branch (typically "master")
#   GITLAB_ADDRESS   from trigger
#   GROUP            from trigger
#   PROJECT          from trigger
#   GITLAB_TOKEN     from trigger
#
# This script does NOT touch WORK_ROOT and does NOT switch to the issue
# work branch. Branch creation is the job of prepare_branch.sh.

set -euo pipefail

: "${REPO_PATH:?}" "${BRANCH:?}" \
  "${GITLAB_ADDRESS:?}" "${GROUP:?}" "${PROJECT:?}" "${GITLAB_TOKEN:?}"

REMOTE_URL="${GITLAB_ADDRESS}/${GROUP}/${PROJECT}.git"
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
