#!/usr/bin/env bash
# env_paths.sh (prepared worker) — bootstrap worker env in one place:
# paths + glab auth + PROJECT_FULL/PROJECT_URI.
#
# As of SKILL_VERSION 2026-04-28.1 this script is the SINGLE bootstrap
# entry point for every other script in this skill. Each subsequent
# script `source`s this file at its top (via `source
# "$(dirname "${BASH_SOURCE[0]}")/env_paths.sh"`), so every fresh bash
# exec gets a fully-populated environment without the caller having to
# re-export everything by hand.
#
# Why: OpenClaw runs each Bash tool call in a brand-new shell. Exports
# made in one call do NOT survive to the next. Before this change, the
# agent would call env_paths.sh + glab_auth.sh once, then a later
# `bash scripts/ensure_labels.sh` would fail because GITLAB_HOST and
# PROJECT_URI were no longer in env. Now each script self-bootstraps.
#
# Required input env vars (the caller — the model — must export these
# in every bash exec; they all come straight from the trigger):
#   PROJECT          project slug
#   ISSUE_IID        integer issue IID
#   ATTEMPT_NUMBER   integer attempt number (allocated by dispatcher)
#   GROUP            GitLab group slug
#   GITLAB_TOKEN     GitLab access token
#
# Outputs (exported into the calling shell):
#   path vars: REPO_PATH, WORK_ROOT, ISSUE_ROOT, ISSUE_STATE_FILE,
#              WORK_BRANCH, ATTEMPT_NUMBER_PADDED, ATTEMPT_DIR,
#              WORKTREE_DIR, ISSUE_LOG_ROOT, LOG_DIR,
#              ATTEMPT_STATE_FILE, SUMMARY_FILE, LOCAL_ATTEMPT_BRANCH
#   glab vars: GITLAB_HOST, GITLAB_API_PROTOCOL
#   project vars: PROJECT_FULL, PROJECT_URI

set -euo pipefail

: "${PROJECT:?env_paths.sh: PROJECT must be set (trigger)}"
: "${ISSUE_IID:?env_paths.sh: ISSUE_IID must be set (trigger)}"
: "${ATTEMPT_NUMBER:?env_paths.sh: ATTEMPT_NUMBER must be set (trigger; dispatcher allocates via allocate_attempt.sh)}"

# ─── 1. Path layout ──────────────────────────────────────────────────
export REPO_PATH="/data/${PROJECT}"
export WORK_ROOT="/data/openclaw_work/${PROJECT}"
export ISSUE_ROOT="${WORK_ROOT}/issues/issue-${ISSUE_IID}"
export ISSUE_STATE_FILE="${ISSUE_ROOT}/state.json"
export WORK_BRANCH="issue/${ISSUE_IID}-auto-fix"

if [ "${PREPARED_WORKER:-}" = "1" ]; then
  if [ ! -d "${ISSUE_ROOT}" ]; then
    echo "env_paths.sh: prepared worker missing dispatcher-created ISSUE_ROOT: ${ISSUE_ROOT}" >&2
    exit 20
  fi
else
  mkdir -p "${ISSUE_ROOT}"
fi

export ATTEMPT_NUMBER_PADDED
ATTEMPT_NUMBER_PADDED="$(printf '%03d' "${ATTEMPT_NUMBER}")"

# ATTEMPT_DIR is kept as a compatibility alias for scripts and state
# updates. There is no attempts/attempt-NNN subtree; logs remain
# attempt-scoped under log/attempt-NNN.
export ATTEMPT_DIR="${ISSUE_ROOT}"
export WORKTREE_DIR="${ATTEMPT_DIR}/worktree"
export ISSUE_LOG_ROOT="${ATTEMPT_DIR}/log"
export LOG_DIR="${ISSUE_LOG_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}"
export ATTEMPT_STATE_FILE="${ATTEMPT_DIR}/attempt_state.json"
export SUMMARY_FILE="${ATTEMPT_DIR}/summary.md"
export LOCAL_ATTEMPT_BRANCH="${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}"

if [ "${PREPARED_WORKER:-}" = "1" ]; then
  for __prepared_dir in "${ATTEMPT_DIR}" "${ISSUE_LOG_ROOT}" "${LOG_DIR}"; do
    if [ ! -d "${__prepared_dir}" ]; then
      echo "env_paths.sh: prepared worker missing dispatcher-created directory: ${__prepared_dir}" >&2
      exit 20
    fi
  done
  unset __prepared_dir
else
  mkdir -p "${ATTEMPT_DIR}" "${ISSUE_LOG_ROOT}" "${LOG_DIR}"
fi

# ─── 2. glab auth (idempotent) ──────────────────────────────────────
# If GITLAB_HOST is already in env (e.g. parent shell already ran this),
# skip — glab_auth.sh just re-runs `glab auth login` which is fast but
# we save the latency.
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

# ─── 3. Project handle ──────────────────────────────────────────────
if [ -z "${PROJECT_FULL:-}" ]; then
  : "${GROUP:?env_paths.sh: GROUP must be set to compute PROJECT_FULL}"
  export PROJECT_FULL="${GROUP}/${PROJECT}"
fi
if [ -z "${PROJECT_URI:-}" ]; then
  PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"
  export PROJECT_URI
fi
