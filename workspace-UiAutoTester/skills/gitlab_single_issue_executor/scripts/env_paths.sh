#!/usr/bin/env bash
# env_paths.sh — populate the executor path variables.
#
# Usage (must be SOURCED, not executed):
#   PROJECT=px_ifp_hulat_test ISSUE_IID=14 source scripts/env_paths.sh
#
# Required input env vars:
#   PROJECT     project slug from the trigger command
#   ISSUE_IID   integer issue IID to execute
#
# Exports:
#   REPO_PATH               git clone target ONLY
#   WORK_ROOT               agent scratch root, OUTSIDE the repo
#   LOG_DIR                 per-issue log directory
#   STATE_DIR               campaign + per-issue state dir
#   ISSUE_STATE_DIR         per-issue JSON files
#   ISSUE_STATE_FILE        this issue's state file
#   WORK_BRANCH             "issue/<iid>-auto-fix"

set -euo pipefail

if [ -z "${PROJECT:-}" ]; then
  echo "env_paths.sh: PROJECT must be set before sourcing" >&2
  return 2 2>/dev/null || exit 2
fi
if [ -z "${ISSUE_IID:-}" ]; then
  echo "env_paths.sh: ISSUE_IID must be set before sourcing" >&2
  return 2 2>/dev/null || exit 2
fi

export REPO_PATH="/data/${PROJECT}"
export WORK_ROOT="/data/openclaw_work/${PROJECT}"
export LOG_DIR="${WORK_ROOT}/openclaw_log/issue-${ISSUE_IID}"
export STATE_DIR="${WORK_ROOT}/openclaw_state"
export ISSUE_STATE_DIR="${STATE_DIR}/issues"
export ISSUE_STATE_FILE="${ISSUE_STATE_DIR}/issue-${ISSUE_IID}.json"
export WORK_BRANCH="issue/${ISSUE_IID}-auto-fix"

mkdir -p \
  "${LOG_DIR}" \
  "${ISSUE_STATE_DIR}"
