#!/usr/bin/env bash
# env_paths.sh — populate the dispatcher path variables.
#
# Usage (must be SOURCED, not executed, so the exports survive in the caller):
#   PROJECT=px_ifp_hulat_test source scripts/env_paths.sh
#
# Required input env vars:
#   PROJECT     project slug from the trigger command
#
# Exports:
#   REPO_PATH               git clone target ONLY
#   WORK_ROOT               agent scratch root, OUTSIDE the repo
#   STATE_DIR               campaign + per-issue state dir
#   ISSUE_STATE_DIR         per-issue JSON files
#   CAMPAIGN_STATE_FILE     campaign_state.json path
#   LOG_ROOT                all log subtrees live here
#   DISPATCHER_LOG_DIR      reconcile-<ts>.json evidence files live here
#   LOCK_FILE               flock file for the campaign
#
# This script ALSO creates the directories so the rest of the dispatcher can write freely.

set -euo pipefail

if [ -z "${PROJECT:-}" ]; then
  echo "env_paths.sh: PROJECT must be set before sourcing" >&2
  return 2 2>/dev/null || exit 2
fi

export REPO_PATH="/data/${PROJECT}"
export WORK_ROOT="/data/openclaw_work/${PROJECT}"
export STATE_DIR="${WORK_ROOT}/openclaw_state"
export ISSUE_STATE_DIR="${STATE_DIR}/issues"
export CAMPAIGN_STATE_FILE="${STATE_DIR}/campaign_state.json"
export LOG_ROOT="${WORK_ROOT}/openclaw_log"
export DISPATCHER_LOG_DIR="${LOG_ROOT}/dispatcher"
export LOCK_FILE="${STATE_DIR}/campaign.lock"

mkdir -p \
  "${STATE_DIR}" \
  "${ISSUE_STATE_DIR}" \
  "${LOG_ROOT}" \
  "${DISPATCHER_LOG_DIR}"
