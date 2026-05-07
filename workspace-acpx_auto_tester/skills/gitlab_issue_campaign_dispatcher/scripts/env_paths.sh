#!/usr/bin/env bash
# env_paths.sh — single bootstrap for every script in this skill.
#
# As of SKILL_VERSION 2026-05-06.5 there is exactly ONE skill in the workspace
# (the orchestrator), running 6 phases per scheduled tick. The orchestrator
# does ALL preparation (Phases 1-4: parse, reconcile, eligibility, per-IID
# prep — clone/pull, worktree, prompt build, label transitions, attempt
# allocation, UI-account allocation, in-progress state-file init) and ALL
# terminal bookkeeping (Phase 6: write terminal state files from the
# subagent's compact JSON reply, classify into campaign_state lists).
# The spawned subagent runs the technical workflow scripts
# (stage/commit/push/wiki/MR/label/summarize) by absolute path against
# pre-rendered env vars; it does NOT load a SKILL and does NOT write any
# state file.
#
# Both halves source THIS file. Path derivation is layered:
#
#   - dispatcher level (always derived):  PROJECT, GROUP, GITLAB_TOKEN
#       → REPO_PATH, WORK_ROOT, STATE_DIR, CAMPAIGN_STATE_FILE, LOG_ROOT,
#         DISPATCHER_LOG_DIR, ISSUES_ROOT, LOCK_FILE
#   - per-issue + attempt level (derived only if ISSUE_IID is set):
#                                       PROJECT, ISSUE_IID, ATTEMPT_NUMBER
#       → ISSUE_ROOT, ISSUE_STATE_FILE, WORK_BRANCH,
#         ATTEMPT_NUMBER_PADDED, ATTEMPT_DIR, WORKTREE_DIR,
#         ISSUE_LOG_ROOT, LOG_DIR, ATTEMPT_STATE_FILE, SUMMARY_FILE,
#         LOCAL_ATTEMPT_BRANCH
#
# Why both layers in one file: a single env_paths.sh keeps the dispatcher's
# prep scripts (which need attempt-level paths to call prepare_attempt.sh,
# build_prompt.sh) and the subagent's post-acpx scripts (which also need
# attempt-level paths) symmetric. Each Bash exec under OpenClaw is a fresh
# shell, so every script must self-bootstrap; the same env_paths.sh works
# for everyone.
#
# Required input env vars per Bash exec (caller must export — typically
# straight from the trigger or from the dispatcher's spawn payload):
#   PROJECT          project slug                                   (always)
#   GROUP            GitLab group slug                              (always)
#   GITLAB_TOKEN     GitLab access token                            (always)
#   ISSUE_IID        integer issue IID                              (per-issue)
#   ATTEMPT_NUMBER   integer attempt number, allocated by dispatcher (per-issue)
#
# Outputs (exported into the calling shell): see lists above. Plus:
#   GITLAB_HOST, GITLAB_API_PROTOCOL    (loaded via glab_auth.sh)
#   PROJECT_FULL, PROJECT_URI            (derived)
#
# Helper: issue_state_file_for <iid> — prints absolute path to a per-issue
# state file (used by the dispatcher when scanning multiple IIDs).

set -euo pipefail

: "${PROJECT:?env_paths.sh: PROJECT must be set (trigger)}"

# ─── 1. Dispatcher-level path layout (always) ──────────────────────
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

# ─── 2. Per-issue + attempt path layout (only when ISSUE_IID set) ──
if [ -n "${ISSUE_IID:-}" ]; then
  : "${ATTEMPT_NUMBER:?env_paths.sh: ATTEMPT_NUMBER must be set when ISSUE_IID is set (dispatcher allocates via allocate_attempt.sh)}"

  export ISSUE_ROOT="${ISSUES_ROOT}/issue-${ISSUE_IID}"
  export ISSUE_STATE_FILE="${ISSUE_ROOT}/state.json"
  export WORK_BRANCH="issue/${ISSUE_IID}-auto-fix"

  mkdir -p "${ISSUE_ROOT}"

  ATTEMPT_NUMBER_PADDED="$(printf '%03d' "${ATTEMPT_NUMBER}")"
  export ATTEMPT_NUMBER_PADDED

  # ATTEMPT_DIR is a compatibility alias for ISSUE_ROOT — there is no
  # per-attempt subtree. Logs are attempt-scoped under log/attempt-NNN.
  export ATTEMPT_DIR="${ISSUE_ROOT}"
  export WORKTREE_DIR="${ATTEMPT_DIR}/worktree"
  export ISSUE_LOG_ROOT="${ATTEMPT_DIR}/log"
  export LOG_DIR="${ISSUE_LOG_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}"
  export ATTEMPT_STATE_FILE="${ATTEMPT_DIR}/attempt_state.json"
  export SUMMARY_FILE="${ATTEMPT_DIR}/summary.md"
  export LOCAL_ATTEMPT_BRANCH="${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}"

  mkdir -p "${ATTEMPT_DIR}" "${ISSUE_LOG_ROOT}" "${LOG_DIR}"
fi

# ─── 3. glab auth (idempotent — loads both HOST and PROTOCOL) ─────
if [ -z "${GITLAB_HOST:-}" ] || [ -z "${GITLAB_API_PROTOCOL:-}" ]; then
  : "${GITLAB_TOKEN:?env_paths.sh: GITLAB_TOKEN must be set to bootstrap glab}"
  __ENV_PATHS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  GITLAB_HOST="$(bash "${__ENV_PATHS_SH_DIR}/glab_auth.sh")"
  if [ -z "${GITLAB_API_PROTOCOL:-}" ]; then
    __PIN_FILE="$(cd "${__ENV_PATHS_SH_DIR}/../../.." && pwd)/config/gitlab.env"
    # shellcheck disable=SC1090
    source "${__PIN_FILE}"
  fi
  export GITLAB_HOST GITLAB_API_PROTOCOL
  unset __ENV_PATHS_SH_DIR
  unset __PIN_FILE
fi

# ─── 4. Project handle ────────────────────────────────────────────
if [ -z "${PROJECT_FULL:-}" ]; then
  : "${GROUP:?env_paths.sh: GROUP must be set to compute PROJECT_FULL}"
  export PROJECT_FULL="${GROUP}/${PROJECT}"
fi
if [ -z "${PROJECT_URI:-}" ]; then
  PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"
  export PROJECT_URI
fi
