#!/usr/bin/env bash
# commit_and_push.sh — commit the already-staged changes and push the work
# branch. Assumes stage_and_guard.sh printed STAGED_OK.
#
# Required env vars:
#   REPO_PATH       git working tree
#   ISSUE_IID       from env_paths.sh
#   WORK_BRANCH     "issue/<iid>-auto-fix" (from env_paths.sh)
#   ISSUE_TITLE     short human title used in the commit message
#
# Output:
#   Prints the new HEAD commit SHA to stdout.

set -euo pipefail

: "${REPO_PATH:?}" "${ISSUE_IID:?}" "${WORK_BRANCH:?}" "${ISSUE_TITLE:?}"

cd "${REPO_PATH}"

git commit -m "fix(issue-${ISSUE_IID}): ${ISSUE_TITLE}"
git push -u origin "${WORK_BRANCH}"
git rev-parse HEAD
