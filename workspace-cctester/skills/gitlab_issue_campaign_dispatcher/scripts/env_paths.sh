#!/usr/bin/env bash
# env_paths.sh (dispatcher) — bootstrap ALL dispatcher env in one place:
# paths + glab auth + PROJECT_FULL/PROJECT_URI.
#
# As of SKILL_VERSION 2026-04-28.1 this script is the SINGLE bootstrap
# entry point for every other script in this skill. Each subsequent
# script `source`s this file at its top so every fresh Bash exec gets
# a fully-populated environment without the caller re-exporting by hand.
#
# Required input env vars (caller exports these — typically from trigger):
#   PROJECT          project slug
#   GROUP            GitLab group slug
#   GITLAB_TOKEN     GitLab access token
#
# Outputs (exported into the calling shell):
#   path vars: REPO_PATH, WORK_ROOT, STATE_DIR, CAMPAIGN_STATE_FILE,
#              LOG_ROOT, DISPATCHER_LOG_DIR, ISSUES_ROOT, LOCK_FILE
#   glab vars: GITLAB_HOST, GITLAB_API_PROTOCOL
#   project vars: PROJECT_FULL, PROJECT_URI
#
# Helper function: issue_state_file_for <iid>

set -euo pipefail

: "${PROJECT:?env_paths.sh: PROJECT must be set (trigger)}"

# ─── 1. Path layout ──────────────────────────────────────────────────
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

# ─── 2. glab auth (idempotent) ──────────────────────────────────────
if [ -z "${GITLAB_HOST:-}" ] || [ -z "${GITLAB_API_PROTOCOL:-}" ]; then
  : "${GITLAB_TOKEN:?env_paths.sh: GITLAB_TOKEN must be set to bootstrap glab}"
  __ENV_PATHS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  GITLAB_HOST="$(bash "${__ENV_PATHS_SH_DIR}/glab_auth.sh")"
  export GITLAB_HOST
  unset __ENV_PATHS_SH_DIR
fi

# ─── 3. Project handle ──────────────────────────────────────────────
if [ -z "${PROJECT_FULL:-}" ]; then
  : "${GROUP:?env_paths.sh: GROUP must be set to compute PROJECT_FULL}"
  export PROJECT_FULL="${GROUP}/${PROJECT}"
fi
if [ -z "${PROJECT_URI:-}" ]; then
  PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"
  export PROJECT_URI
fi
