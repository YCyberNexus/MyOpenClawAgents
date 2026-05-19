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
# The repo clone parent and the basenames of the runtime root and
# knowledge-base directory are overridable per project via optional trigger
# fields `repo_path`, `result_basename`, and `data_basename` (forwarded as
# REPO_PARENT_PATH / RESULT_BASENAME / DATA_BASENAME env vars). Defaults
# preserve legacy behavior: repo parent `/data`, final clone target
# `/data/${PROJECT}`, `ifp-result`, and `ifp-data` for projects that never
# ship the new fields.
#
# Disk layout produced by this file (with default basenames):
#
#   ${REPO_PATH}/                        ← /data/${PROJECT}, parent checkout (shared
#                                          object DB; only `git fetch` mutates it)
#       .claude/                         (in master+dev, test-team owned)
#       hulat/                           (in master+dev, test-team owned)
#       ${DATA_BASENAME}/                (in master+dev, test-team owned; default ifp-data)
#       ${RESULT_BASENAME}/              (agent state/logs + per-issue subtrees; default ifp-result)
#           _dispatcher/                 ← campaign-level state + logs + locks
#               campaign_state.json
#               campaign.lock
#               log/reconcile-<ts>.json
#               locks/repo.lock
#           issues/                      ← parent of per-issue persistent subtrees
#               issue-<iid>/             ← per-issue subtree (lives OUTSIDE worktree
#                                          so state/summary survive worktree teardown)
#                   state.json
#                   attempt_state.json
#                   summary.md
#           .worktrees/                  ← per-issue linked git worktrees
#               issue-<iid>/             ← WORKTREE_DIR; acpx cwd; reused across every
#                                          attempt of this IID. prepare_attempt.sh
#                                          creates it on attempt 1 via `git worktree add -B`
#                                          and on attempt N>1 force-switches the checked-out
#                                          branch to BASE_REF in place (untracked files
#                                          Claude wrote in earlier attempts survive, so
#                                          `acpx claude exec` can pick up where it left off).
#                   .claude/ hulat/ ${DATA_BASENAME}/    (from base branch checkout)
#                   ${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/
#                                                        ← OUTPUT_DIR (force-added; shared
#                                                          across attempts of this IID)
#                   ${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/
#                                                        ← LOG_DIR (still attempt-scoped
#                                                          inside the shared worktree;
#                                                          prompt.txt + claude_result.txt
#                                                          force-added by stage_and_guard.sh,
#                                                          other files stay locally ignored
#                                                          via .git/info/exclude)
#
# Path derivation is layered:
#
#   - dispatcher level (always derived):  PROJECT, GROUP, GITLAB_TOKEN
#                                         (+ optional REPO_PARENT_PATH or REPO_PATH,
#                                            RESULT_BASENAME, DATA_BASENAME)
#       → REPO_PATH, HULAT_DIR, DATA_DIR, RESULT_ROOT, WORK_ROOT,
#         STATE_DIR, CAMPAIGN_STATE_FILE, LOG_ROOT, DISPATCHER_LOG_DIR,
#         ISSUES_ROOT, LOCK_FILE, WORKTREES_ROOT
#   - per-issue + attempt level (derived only if ISSUE_IID is set):
#                                       PROJECT, ISSUE_IID, ATTEMPT_NUMBER
#       → ISSUE_ROOT, ISSUE_STATE_FILE, WORK_BRANCH,
#         ATTEMPT_NUMBER_PADDED, ATTEMPT_DIR, WORKTREE_DIR, OUTPUT_DIR,
#         LOG_DIR, ATTEMPT_STATE_FILE, SUMMARY_FILE,
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
# fields; defaults preserve legacy ifp-* layout):
#   REPO_PARENT_PATH absolute parent for project clones (default: /data)
#   REPO_PATH        final clone target path. Compatibility input only when
#                    REPO_PARENT_PATH is unset; normally exported by this file.
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

# Optional trigger field `repo_path` lets the orchestrator place clones under
# a parent directory other than `/data`. The trigger value is forwarded as
# REPO_PARENT_PATH; the final repo root remains `${REPO_PARENT_PATH}/${PROJECT}`.
# REPO_PATH is still accepted as a final repo-root compatibility input for
# subagent prompts and direct script invocations.
: "${REPO_PARENT_PATH:=}"
if [ -n "${REPO_PARENT_PATH}" ]; then
  # If the trigger supplied a parent with trailing slashes, recompute the final
  # repo path after parent normalization so `/data/foo/` and `/data/foo` match.
  while [ "${REPO_PARENT_PATH}" != "/" ] && [ "${REPO_PARENT_PATH%/}" != "${REPO_PARENT_PATH}" ]; do
    REPO_PARENT_PATH="${REPO_PARENT_PATH%/}"
  done
  REPO_PATH="${REPO_PARENT_PATH}/${PROJECT}"
  while [ "${REPO_PATH}" != "/" ] && [ "${REPO_PATH%/}" != "${REPO_PATH}" ]; do
    REPO_PATH="${REPO_PATH%/}"
  done
else
  : "${REPO_PATH:=/data/${PROJECT}}"
  # For the compatibility REPO_PATH input, normalize first and then derive its
  # parent so `/data/foo/A/` exports parent `/data/foo`.
  while [ "${REPO_PATH}" != "/" ] && [ "${REPO_PATH%/}" != "${REPO_PATH}" ]; do
    REPO_PATH="${REPO_PATH%/}"
  done
  REPO_PARENT_PATH="${REPO_PATH%/*}"
  if [ -z "${REPO_PARENT_PATH}" ] || [ "${REPO_PARENT_PATH}" = "${REPO_PATH}" ]; then
    REPO_PARENT_PATH="/"
  fi
  while [ "${REPO_PARENT_PATH}" != "/" ] && [ "${REPO_PARENT_PATH%/}" != "${REPO_PARENT_PATH}" ]; do
    REPO_PARENT_PATH="${REPO_PARENT_PATH%/}"
  done
fi

# Guard against unsafe clone parents and targets. clone_or_pull.sh may remove
# a non-git directory at REPO_PATH when recovering from an interrupted first
# clone, so REPO_PATH must be a concrete repo directory derived from a safe
# parent.
case "${REPO_PARENT_PATH}" in
  /*) ;;
  *)
    echo "env_paths.sh: invalid_repo_path: repo_path must be absolute" >&2
    exit 2
    ;;
esac
case "${REPO_PARENT_PATH}" in
  "/")
    echo "env_paths.sh: invalid_repo_path: repo_path must not be filesystem root" >&2
    exit 2
    ;;
esac
case "${REPO_PARENT_PATH}" in
  *"/.."|*"/../"*|*"/."|*"/./"*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*)
    echo "env_paths.sh: invalid_repo_path: repo_path must not contain dot segments or whitespace" >&2
    exit 2
    ;;
esac
case "${REPO_PARENT_PATH}" in
  *[!A-Za-z0-9_./-]*)
    echo "env_paths.sh: invalid_repo_path: repo_path contains unsupported characters" >&2
    exit 2
    ;;
esac
case "${REPO_PATH}" in
  "/"|"/data"|"/tmp"|"/var"|"/home"|"/Users"|"/private"|"/private/tmp"|"/private/var")
    echo "env_paths.sh: invalid_repo_path: final REPO_PATH must point at a repo directory, not ${REPO_PATH}" >&2
    exit 2
    ;;
esac
case "${REPO_PATH}" in
  *"/.."|*"/../"*|*"/."|*"/./"*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*|*[!A-Za-z0-9_./-]*)
    echo "env_paths.sh: invalid_repo_path: final REPO_PATH is not a safe repo directory" >&2
    exit 2
    ;;
esac
export REPO_PARENT_PATH REPO_PATH

# Per-project basenames. Optional trigger fields `result_basename` /
# `data_basename` let the orchestrator override the runtime-root and
# knowledge-base directory names without code changes (see
# references/trigger_command.md). Defaults preserve legacy behavior for
# projects that never ship the new fields.
: "${RESULT_BASENAME:=ifp-result}"
: "${DATA_BASENAME:=ifp-data}"
export RESULT_BASENAME DATA_BASENAME

# ─── 1. Dispatcher-level path layout (always) ──────────────────────
export HULAT_DIR="${REPO_PATH}/hulat"
export DATA_DIR="${REPO_PATH}/${DATA_BASENAME}"
export RESULT_ROOT="${REPO_PATH}/${RESULT_BASENAME}"
export WORK_ROOT="${RESULT_ROOT}/_dispatcher"
export STATE_DIR="${WORK_ROOT}"
export CAMPAIGN_STATE_FILE="${STATE_DIR}/campaign_state.json"
export LOG_ROOT="${WORK_ROOT}/log"
export DISPATCHER_LOG_DIR="${LOG_ROOT}"
export ISSUES_ROOT="${RESULT_ROOT}/issues"
export LOCK_FILE="${STATE_DIR}/campaign.lock"

# Per-issue git worktrees live under a single root inside the agent
# runtime tree (already covered by `.git/info/exclude`). Always exported
# so housekeeper / cleanup scripts can find them even when ISSUE_IID is
# unset. Each IID gets exactly one worktree (reused across attempts);
# see WORKTREE_DIR below.
export WORKTREES_ROOT="${RESULT_ROOT}/.worktrees"

# Only mkdir inside the repo if the repo has actually been cloned. Before
# the first clone `${REPO_PATH}` does not exist; clone_or_pull.sh creates
# the dispatcher subtree itself after cloning.
if [ -d "${REPO_PATH}/.git" ]; then
  mkdir -p \
    "${WORK_ROOT}" \
    "${STATE_DIR}" \
    "${LOG_ROOT}" \
    "${DISPATCHER_LOG_DIR}" \
    "${ISSUES_ROOT}" \
    "${WORKTREES_ROOT}"
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

  # One-time migration: older deployments placed per-issue subtrees directly
  # under ${RESULT_ROOT} (e.g. ifp-result/issue-14/) before the issues/
  # nesting was introduced. Move any legacy per-issue directory into the new
  # ${ISSUES_ROOT} parent so existing state files are not lost.
  LEGACY_ISSUE_ROOT="${RESULT_ROOT}/issue-${ISSUE_IID}"
  if [ ! -d "${ISSUE_ROOT}" ] && [ -d "${LEGACY_ISSUE_ROOT}" ]; then
    mkdir -p "${ISSUES_ROOT}"
    mv "${LEGACY_ISSUE_ROOT}" "${ISSUE_ROOT}"
  fi

  # Same guard as above: only create the per-issue subtree once the repo
  # exists. Phase 4 always runs after Phase 3's clone_or_pull, so the repo
  # is guaranteed present by the time any per-issue script sources this.
  if [ -d "${REPO_PATH}/.git" ]; then
    mkdir -p "${ISSUE_ROOT}"
  fi

  ATTEMPT_NUMBER_PADDED="$(printf '%03d' "${ATTEMPT_NUMBER}")"
  export ATTEMPT_NUMBER_PADDED

  # Every attempt of this IID runs inside one shared linked git worktree at
  # WORKTREE_DIR (the path does NOT include the attempt number). The parent
  # checkout at ${REPO_PATH} is only used as the shared object database /
  # `git fetch` target and is NEVER mutated by an attempt. Cross-IID
  # parallelism is still safe because different IIDs get different worktree
  # paths; same-IID attempts never run concurrently (single-batch-in-flight
  # invariant enforced by the dispatcher's `pending_subagents` bookkeeping),
  # so it is safe to reuse one working tree across attempts. The benefit:
  # any local scratch state Claude Code wrote during attempt N (untracked
  # files under .claude/, intermediate artifacts, etc.) survives in place
  # so `acpx claude exec` on attempt N+1 can pick up where it left off.
  # prepare_attempt.sh owns the create-or-reuse logic.
  #
  # ATTEMPT_DIR remains a compatibility alias for ISSUE_ROOT (the per-issue
  # persistent subtree). Cross-attempt state (state.json, attempt_state.json,
  # summary.md) lives in ISSUE_ROOT so it survives worktree teardown by a
  # housekeeper. LOG_DIR is still attempt-scoped under the shared worktree
  # at ${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/ so successive attempts
  # do NOT overwrite each other's prompt.txt / claude_result.txt. Only those
  # two files are force-added into the MR; the rest stay locally ignored via
  # the repository `.git/info/exclude` entry for `/${RESULT_BASENAME}/`.
  export ATTEMPT_DIR="${ISSUE_ROOT}"
  export WORKTREE_DIR="${WORKTREES_ROOT}/issue-${ISSUE_IID}"
  export OUTPUT_DIR="${WORKTREE_DIR}/${RESULT_BASENAME}/issue-${ISSUE_IID}/hulat-spec-issue${ISSUE_IID}"
  export LOG_DIR="${WORKTREE_DIR}/${RESULT_BASENAME}/issue-${ISSUE_IID}/log/attempt-${ATTEMPT_NUMBER_PADDED}"
  export ATTEMPT_STATE_FILE="${ATTEMPT_DIR}/attempt_state.json"
  export SUMMARY_FILE="${ATTEMPT_DIR}/summary.md"
  export LOCAL_ATTEMPT_BRANCH="${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}"

  # Only create parent-side dirs here. WORKTREE_DIR + OUTPUT_DIR + LOG_DIR
  # are created inside prepare_attempt.sh after `git worktree add`
  # succeeds — creating WORKTREE_DIR ahead of time would make
  # `git worktree add` refuse the path, and LOG_DIR is nested inside the
  # worktree.
  if [ -d "${REPO_PATH}/.git" ]; then
    mkdir -p "${ATTEMPT_DIR}"
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
