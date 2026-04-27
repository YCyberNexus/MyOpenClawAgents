#!/usr/bin/env bash
# prepare_branch.sh — ensure the working tree is pristine, then create the
# per-issue work branch from a clean tip of the integration branch.
#
# Required env vars:
#   REPO_PATH      from env_paths.sh
#   BRANCH         integration branch (typically "master")
#   ISSUE_IID      from env_paths.sh
#   WORK_BRANCH    "issue/<iid>-auto-fix" (set by env_paths.sh)
#
# Why each step matters:
#   - reset --hard  : drops stray edits left by prior runs
#   - clean -fdx    : nukes untracked dirs/files (e.g. legacy openclaw_log/
#                     or openclaw_state/ left in the repo by older deployments)
#   - branch -D     : if a stale local copy of WORK_BRANCH exists, drop it so
#                     the new branch starts from the fresh BRANCH tip
#
# After this script the working tree is at WORK_BRANCH, ready for Claude Code
# to make changes inside REPO_PATH. The script must NEVER write under
# WORK_ROOT or HULAT_DIR.

set -euo pipefail

: "${REPO_PATH:?}" "${BRANCH:?}" "${ISSUE_IID:?}" "${WORK_BRANCH:?}"

cd "${REPO_PATH}"

git fetch origin
git checkout "${BRANCH}"
git reset --hard "origin/${BRANCH}"
git clean -fdx

if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
  git branch -D "${WORK_BRANCH}"
fi

git checkout -b "${WORK_BRANCH}"
echo "${WORK_BRANCH}"
