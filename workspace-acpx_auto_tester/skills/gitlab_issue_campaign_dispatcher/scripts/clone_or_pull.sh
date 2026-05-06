#!/usr/bin/env bash
# clone_or_pull.sh — dispatcher-owned repo sync. Ensures ${REPO_PATH}
# exists as a clone of the GitLab project and has fresh refs for prepared
# issue worktrees. Subagents must not run clone/fetch preparation.

set -euo pipefail

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

cd "${REPO_PATH}"
git ls-remote --exit-code origin HEAD >/dev/null
git worktree prune
