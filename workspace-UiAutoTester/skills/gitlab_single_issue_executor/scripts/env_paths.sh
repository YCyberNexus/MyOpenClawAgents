#!/usr/bin/env bash
# env_paths.sh (executor) — populate executor path variables, including
# the per-attempt variables for this run.
#
# Layout (SKILL_VERSION 2026-04-25.1+):
#
#   /data/${PROJECT}/                                ← main git repo
#   /data/openclaw_work/${PROJECT}/
#       issues/
#           issue-<iid>/
#               state.json                           ← per-issue state (cross-attempt)
#               attempts/
#                   attempt-001/
#                       worktree/                    ← Claude Code's cwd
#                       log/
#                       attempt_state.json
#                       summary.md
#                   attempt-002/
#                       ...
#
# Usage (must be SOURCED):
#   PROJECT=<p> ISSUE_IID=<n> source scripts/env_paths.sh
#
# Required input:
#   ATTEMPT_NUMBER     The attempt number for THIS run. As of SKILL_VERSION
#                      2026-04-25.3, env_paths.sh NO LONGER auto-allocates.
#                      The dispatcher must allocate the number once via
#                      `dispatcher/scripts/allocate_attempt.sh` and pass it
#                      to the executor via the `attempt_number=<N>` trigger
#                      field. This prevents one logical resolution from
#                      producing multiple empty attempt-NNN/ directories
#                      when the executor session is cold-restarted or
#                      env_paths.sh is sourced more than once.
#
# Exports (issue-level):
#   REPO_PATH                main git repo
#   WORK_ROOT                agent scratch root
#   ISSUE_ROOT               ${WORK_ROOT}/issues/issue-<iid>
#   ISSUE_STATE_FILE         ${ISSUE_ROOT}/state.json
#   ATTEMPTS_DIR             ${ISSUE_ROOT}/attempts
#   WORK_BRANCH              "issue/<iid>-auto-fix" (the SINGLE remote branch — strategy A)
#
# Exports (attempt-level — only after attempt number is resolved):
#   ATTEMPT_NUMBER           integer, zero-padded for paths
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   ATTEMPT_DIR              ${ATTEMPTS_DIR}/attempt-${ATTEMPT_NUMBER_PADDED}
#   WORKTREE_DIR             ${ATTEMPT_DIR}/worktree
#   LOG_DIR                  ${ATTEMPT_DIR}/log
#   ATTEMPT_STATE_FILE       ${ATTEMPT_DIR}/attempt_state.json
#   SUMMARY_FILE             ${ATTEMPT_DIR}/summary.md
#   LOCAL_ATTEMPT_BRANCH     "issue/<iid>-auto-fix-att${PADDED}" (per-attempt local branch)

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
export ISSUE_ROOT="${WORK_ROOT}/issues/issue-${ISSUE_IID}"
export ISSUE_STATE_FILE="${ISSUE_ROOT}/state.json"
export ATTEMPTS_DIR="${ISSUE_ROOT}/attempts"
export WORK_BRANCH="issue/${ISSUE_IID}-auto-fix"

mkdir -p "${ISSUE_ROOT}" "${ATTEMPTS_DIR}"

# ATTEMPT_NUMBER must be supplied by the dispatcher trigger. Auto-derivation
# is intentionally forbidden — see the comment block at the top of this file.
if [ -z "${ATTEMPT_NUMBER:-}" ]; then
  echo "env_paths.sh: ATTEMPT_NUMBER is required (must be supplied by dispatcher" >&2
  echo "via the executor trigger field 'attempt_number=<N>'). Refusing to" >&2
  echo "auto-allocate — that caused the empty-attempt-dir bug in older versions." >&2
  return 2 2>/dev/null || exit 2
fi

# Zero-pad to 3 digits.
export ATTEMPT_NUMBER_PADDED
ATTEMPT_NUMBER_PADDED="$(printf '%03d' "${ATTEMPT_NUMBER}")"

export ATTEMPT_DIR="${ATTEMPTS_DIR}/attempt-${ATTEMPT_NUMBER_PADDED}"
export WORKTREE_DIR="${ATTEMPT_DIR}/worktree"
export LOG_DIR="${ATTEMPT_DIR}/log"
export ATTEMPT_STATE_FILE="${ATTEMPT_DIR}/attempt_state.json"
export SUMMARY_FILE="${ATTEMPT_DIR}/summary.md"
export LOCAL_ATTEMPT_BRANCH="${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}"

mkdir -p "${ATTEMPT_DIR}" "${LOG_DIR}"
