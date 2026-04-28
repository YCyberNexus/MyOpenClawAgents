#!/usr/bin/env bash
# env_paths.sh (dispatcher) — populate dispatcher-level path variables.
#
# As of SKILL_VERSION 2026-04-25.1, the disk layout is:
#
#   /data/${PROJECT}/                              ← main git repo (host of worktrees)
#   /data/openclaw_work/${PROJECT}/
#       openclaw_state/
#           campaign_state.json                    (this dispatcher's only state file)
#           campaign.lock
#       openclaw_log/
#           dispatcher/                            (reconcile-<ts>.json)
#       issues/
#           issue-<iid>/                           (executor-owned per-issue tree, see executor env_paths.sh)
#
# Per-issue state files no longer live at the dispatcher level. They are
# inside `issues/issue-<iid>/state.json`. The dispatcher reads them via
# the path it computes here (ISSUE_ROOT / ISSUE_STATE_FILE_FOR_IID).
#
# Usage (must be SOURCED):
#   PROJECT=px_ifp_hulat_test source scripts/env_paths.sh
#
# Required input:
#   PROJECT     project slug from the trigger command
#
# Exports:
#   REPO_PATH               main git repo, hosts worktrees
#   WORK_ROOT               agent scratch root, OUTSIDE the repo
#   STATE_DIR               dispatcher-level state dir (campaign-only)
#   CAMPAIGN_STATE_FILE     campaign_state.json
#   LOG_ROOT                log subtree root
#   DISPATCHER_LOG_DIR      reconcile-<ts>.json files
#   ISSUES_ROOT             where executor puts issues/issue-<iid>/...
#   LOCK_FILE               flock target
#
# Helper function exported:
#   issue_state_file_for <iid>     → echoes /data/.../issues/issue-<iid>/state.json

set -euo pipefail

if [ -z "${PROJECT:-}" ]; then
  echo "env_paths.sh: PROJECT must be set before sourcing" >&2
  return 2 2>/dev/null || exit 2
fi

export REPO_PATH="/data/${PROJECT}"
export WORK_ROOT="/data/openclaw_work/${PROJECT}"
export STATE_DIR="${WORK_ROOT}/openclaw_state"
export CAMPAIGN_STATE_FILE="${STATE_DIR}/campaign_state.json"
export LOG_ROOT="${WORK_ROOT}/openclaw_log"
export DISPATCHER_LOG_DIR="${LOG_ROOT}/dispatcher"
export ISSUES_ROOT="${WORK_ROOT}/issues"
export LOCK_FILE="${STATE_DIR}/campaign.lock"

mkdir -p \
  "${STATE_DIR}" \
  "${LOG_ROOT}" \
  "${DISPATCHER_LOG_DIR}" \
  "${ISSUES_ROOT}"

issue_state_file_for() {
  local iid="$1"
  echo "${ISSUES_ROOT}/issue-${iid}/state.json"
}
export -f issue_state_file_for
