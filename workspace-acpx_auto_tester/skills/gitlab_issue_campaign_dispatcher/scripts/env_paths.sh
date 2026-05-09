#!/usr/bin/env bash
# env_paths.sh — single bootstrap for every script in this skill.
#
# The cloned project repo IS the agent's entire workspace. The test team
# maintains `.claude/`, `hulat/`, and the knowledge-base directory
# (default `ifp-data/`) inside the repo (committed to master + dev). The
# agent's own state and per-issue subtrees live under the runtime root
# (default `${REPO_PATH}/ifp-result/`). Runtime state/log files stay
# uncommitted there; each issue's committed output is force-added from
# its own `<runtime-root>/issue-<iid>/hulat-spec-issue<iid>/` directory.
#
# The basenames of the runtime root and knowledge-base directory are
# overridable per project via optional trigger fields `result_basename`
# and `data_basename` (forwarded as RESULT_BASENAME / DATA_BASENAME env
# vars). Defaults are `ifp-result` / `ifp-data` for projects that never
# ship the new fields.
#
# Disk layout produced by this file (with default basenames):
#
#   ${REPO_PATH}/                        ← /data/${PROJECT}, the cloned repo
#       .claude/                         (in master+dev, test-team owned)
#       hulat/                           (in master+dev, test-team owned)
#       ${DATA_BASENAME}/                (in master+dev, test-team owned; default ifp-data)
#       ${RESULT_BASENAME}/              (agent state/logs + committed per-issue output; default ifp-result)
#           _dispatcher/                 ← campaign-level state + logs + locks
#               campaign_state.json
#               campaign.lock
#               log/reconcile-<ts>.json
#               locks/repo.lock
#           issue-<iid>/                 ← per-issue subtree
#               state.json
#               attempt_state.json
#               hulat-spec-issue<iid>/   ← Claude Code output (committed to MR)
#               log/attempt-NNN/
#               summary.md
#
# Path derivation is layered:
#
#   - dispatcher level (always derived):  PROJECT, GROUP, GITLAB_TOKEN
#                                         (+ optional RESULT_BASENAME, DATA_BASENAME)
#       → REPO_PATH, HULAT_DIR, DATA_DIR, RESULT_ROOT, WORK_ROOT,
#         STATE_DIR, CAMPAIGN_STATE_FILE, LOG_ROOT, DISPATCHER_LOG_DIR,
#         ISSUES_ROOT, LOCK_FILE
#   - per-issue + attempt level (derived only if ISSUE_IID is set):
#                                       PROJECT, ISSUE_IID, ATTEMPT_NUMBER
#       → ISSUE_ROOT, ISSUE_STATE_FILE, WORK_BRANCH,
#         ATTEMPT_NUMBER_PADDED, ATTEMPT_DIR, WORKTREE_DIR, OUTPUT_DIR,
#         ISSUE_LOG_ROOT, LOG_DIR, ATTEMPT_STATE_FILE, SUMMARY_FILE,
#         LOCAL_ATTEMPT_BRANCH
#
# Why a single layered file: a single env_paths.sh keeps the dispatcher's
# prep scripts (which need attempt-level paths to call prepare_attempt.sh,
# build_prompt.sh) and the subagent's post-acpx scripts (which also need
# attempt-level paths) symmetric. Each Bash exec under OpenClaw is a fresh
# shell, so every script must self-bootstrap; the same env_paths.sh works
# for everyone.
#
# Required input env vars per Bash exec:
#   PROJECT          project slug                                   (always)
#   GROUP            GitLab group slug                              (always)
#   GITLAB_TOKEN     GitLab access token                            (always)
#   ISSUE_IID        integer issue IID                              (per-issue)
#   ATTEMPT_NUMBER   integer attempt number, allocated by dispatcher (per-issue)
#
# Optional input env vars (forwarded by the orchestrator from trigger
# fields of the same names; defaults preserve legacy ifp-* layout):
#   RESULT_BASENAME  basename of the agent runtime root (default: ifp-result)
#   DATA_BASENAME    basename of the test team's knowledge dir (default: ifp-data)
#
# Note: HULAT_DIR is NOT a trigger input. It is derived as
# `${REPO_PATH}/hulat` because the test team committed the hulat
# materials into the repo. Triggers that still pass `hulat_dir=...` are
# silently ignored (the override never reaches a script).
#
# Outputs (exported into the calling shell): see lists above. Plus:
#   GITLAB_HOST, GITLAB_API_PROTOCOL    (loaded via glab_auth.sh)
#   PROJECT_FULL, PROJECT_URI            (derived)
#
# Helper: issue_state_file_for <iid> — prints absolute path to a per-issue
# state file (used by the dispatcher when scanning multiple IIDs).

set -euo pipefail

: "${PROJECT:?env_paths.sh: PROJECT must be set (trigger)}"

# Per-project basenames. Optional trigger fields `result_basename` /
# `data_basename` let the orchestrator override the runtime-root and
# knowledge-base directory names without code changes (see
# references/trigger_command.md). Defaults preserve legacy behavior for
# projects that never ship the new fields.
: "${RESULT_BASENAME:=ifp-result}"
: "${DATA_BASENAME:=ifp-data}"
export RESULT_BASENAME DATA_BASENAME

# ─── 1. Dispatcher-level path layout (always) ──────────────────────
export REPO_PATH="/data/${PROJECT}"
export HULAT_DIR="${REPO_PATH}/hulat"
export DATA_DIR="${REPO_PATH}/${DATA_BASENAME}"
export RESULT_ROOT="${REPO_PATH}/${RESULT_BASENAME}"
export WORK_ROOT="${RESULT_ROOT}/_dispatcher"
export STATE_DIR="${WORK_ROOT}"
export CAMPAIGN_STATE_FILE="${STATE_DIR}/campaign_state.json"
export LOG_ROOT="${WORK_ROOT}/log"
export DISPATCHER_LOG_DIR="${LOG_ROOT}"
export ISSUES_ROOT="${RESULT_ROOT}"
export LOCK_FILE="${STATE_DIR}/campaign.lock"

# Only mkdir inside the repo if the repo has actually been cloned. Before
# the first clone `${REPO_PATH}` does not exist; clone_or_pull.sh creates
# the dispatcher subtree itself after cloning.
if [ -d "${REPO_PATH}/.git" ]; then
  mkdir -p \
    "${WORK_ROOT}" \
    "${STATE_DIR}" \
    "${LOG_ROOT}" \
    "${DISPATCHER_LOG_DIR}" \
    "${ISSUES_ROOT}"
fi

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

  # Same guard as above: only create the per-issue subtree once the repo
  # exists. Phase 4 always runs after Phase 3's clone_or_pull, so the repo
  # is guaranteed present by the time any per-issue script sources this.
  if [ -d "${REPO_PATH}/.git" ]; then
    mkdir -p "${ISSUE_ROOT}"
  fi

  ATTEMPT_NUMBER_PADDED="$(printf '%03d' "${ATTEMPT_NUMBER}")"
  export ATTEMPT_NUMBER_PADDED

  # ATTEMPT_DIR is a compatibility alias for ISSUE_ROOT — there is no
  # per-attempt subtree. Claude runs at the repo root, while this issue's
  # committed output is force-added from OUTPUT_DIR under ${RESULT_BASENAME}/.
  export ATTEMPT_DIR="${ISSUE_ROOT}"
  export WORKTREE_DIR="${REPO_PATH}"
  export OUTPUT_DIR="${ISSUE_ROOT}/hulat-spec-issue${ISSUE_IID}"
  export ISSUE_LOG_ROOT="${ATTEMPT_DIR}/log"
  export LOG_DIR="${ISSUE_LOG_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}"
  export ATTEMPT_STATE_FILE="${ATTEMPT_DIR}/attempt_state.json"
  export SUMMARY_FILE="${ATTEMPT_DIR}/summary.md"
  export LOCAL_ATTEMPT_BRANCH="${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}"

  if [ -d "${REPO_PATH}/.git" ]; then
    mkdir -p "${ATTEMPT_DIR}" "${OUTPUT_DIR}" "${ISSUE_LOG_ROOT}" "${LOG_DIR}"
  fi
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
