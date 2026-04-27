#!/usr/bin/env bash
# prepare_branch.sh — prepare the per-issue work branch.
#
# Two modes (selected by env var ISSUE_MODE):
#
#   ISSUE_MODE=fresh      (default)
#     Create WORK_BRANCH from a clean tip of BRANCH. Discards any prior
#     local copy of WORK_BRANCH. This is the original behavior used when
#     the issue is being processed for the first time (label `todo` /
#     `doing` / user-reopened).
#
#   ISSUE_MODE=continue
#     Resume the existing remote WORK_BRANCH if it exists; otherwise
#     fall back to fresh. Used when reviewers set the `continue` label,
#     meaning Claude Code's prior run on this issue did not actually
#     finish and the work-in-progress branch should be re-entered.
#
# Required env vars:
#   REPO_PATH      from env_paths.sh
#   BRANCH         integration branch (typically "master")
#   ISSUE_IID      from env_paths.sh
#   WORK_BRANCH    "issue/<iid>-auto-fix" (set by env_paths.sh)
#
# Optional env var:
#   ISSUE_MODE     "fresh" (default) or "continue"
#
# Why each step matters:
#   - reset --hard  : drops stray edits left by prior runs
#   - clean -fdx    : nukes untracked dirs/files (e.g. legacy openclaw_log/
#                     or openclaw_state/ left in the repo by older deployments)
#   - branch -D     : in fresh mode only, drop any stale local WORK_BRANCH
#                     so the new branch starts from a fresh BRANCH tip
#
# Output: prints either "fresh" or "continue" on its own line, followed
# by the WORK_BRANCH name on the next line. The executor must read these
# to know which path actually ran.

set -euo pipefail

: "${REPO_PATH:?}" "${BRANCH:?}" "${ISSUE_IID:?}" "${WORK_BRANCH:?}"

ISSUE_MODE="${ISSUE_MODE:-fresh}"
case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "prepare_branch: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

cd "${REPO_PATH}"
git fetch origin

# Decide the actual mode. continue downgrades to fresh if no remote branch.
ACTUAL_MODE="${ISSUE_MODE}"
if [ "${ACTUAL_MODE}" = "continue" ]; then
  if ! git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
    ACTUAL_MODE=fresh
  fi
fi

if [ "${ACTUAL_MODE}" = "continue" ]; then
  # Resume the remote work branch.
  if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
    git checkout "${WORK_BRANCH}"
    git reset --hard "origin/${WORK_BRANCH}"
  else
    git checkout -b "${WORK_BRANCH}" "origin/${WORK_BRANCH}"
  fi
  git clean -fdx
else
  # Fresh: rebuild from BRANCH tip.
  git checkout "${BRANCH}"
  git reset --hard "origin/${BRANCH}"
  git clean -fdx

  if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
    git branch -D "${WORK_BRANCH}"
  fi

  git checkout -b "${WORK_BRANCH}"
fi

echo "${ACTUAL_MODE}"
echo "${WORK_BRANCH}"
