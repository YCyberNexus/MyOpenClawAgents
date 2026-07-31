#!/usr/bin/env bash
# env_paths.sh — single bootstrap for every script in this skill.
#
# The cloned project repo IS the agent's entire workspace. The agent's own
# state and per-issue subtrees live under `${REPO_PATH}/.req_executor/`.
# Runtime state stays local there; each issue's committed output and current
# execution log are force-added from `.req_executor/issue-<iid>/`
# directory inside the per-issue worktree.
#
# The repo clone parent is overridable per project via optional trigger field
# `repo_path` (forwarded as REPO_PARENT_PATH). Defaults: repo parent `/data`
# and final clone target `/data/${PROJECT}`.
#
# Disk layout produced by this file (with default basenames):
#
#   ${REPO_PATH}/                        ← /data/${PROJECT}, parent checkout (shared
#                                          object DB; only `git fetch` mutates it)
#       .req_executor/                   (agent state/logs + per-issue subtrees)
#           _dispatcher/                 ← campaign-level state + logs + locks
#               campaign_state.json
#               campaign.lock
#               log/reconcile-<ts>.json
#               locks/repo.lock
#           issues/                      ← parent of per-issue persistent subtrees
#               issue-<iid>/             ← per-issue subtree (lives OUTSIDE worktree
#                                          so state/summary survive worktree teardown)
#                   state.json
#                   executions/execution-<execution_id>.json
#                   summary.md
#           .worktrees/                  ← per-issue linked git worktrees
#               issue-<iid>/             ← WORKTREE_DIR; acpx cwd; reused across every
#                                          run of this IID. prepare_attempt.sh creates it
#                                          once and later force-switches the same issue-local
#                                          branch to BASE_REF in place.
#                   .req_executor/issue-<iid>/output/
#                                                        ← OUTPUT_DIR (force-added; shared)
#                   .req_executor/issue-<iid>/log/execution-<execution_id>/
#                                                        ← LOG_DIR (isolated per execution;
#                                                          stays local and is not committed)
#
# Path derivation is layered:
#
#   - dispatcher level (always derived):  PROJECT, GROUP, GITLAB_TOKEN
#                                         (+ optional REPO_PARENT_PATH or REPO_PATH)
#       → REPO_PATH, RESULT_ROOT, WORK_ROOT,
#         STATE_DIR, CAMPAIGN_STATE_FILE, LOG_ROOT, DISPATCHER_LOG_DIR,
#         ISSUES_ROOT, LOCK_FILE, WORKTREES_ROOT
#   - per-issue run level (derived only if ISSUE_IID is set):
#                                       PROJECT, ISSUE_IID, EXECUTION_ID
#       → ISSUE_ROOT, ISSUE_STATE_FILE, WORK_BRANCH,
#         EXECUTION_ID, WORKTREE_DIR, OUTPUT_DIR,
#         LOG_DIR, EXECUTION_STATE_FILE, SUMMARY_FILE,
#         LOCAL_ISSUE_BRANCH
#
# Why a single layered file: a single env_paths.sh keeps the dispatcher's
# prep scripts (which need execution-scoped paths to call prepare_attempt.sh,
# build_prompt.sh) and the subagent's post-acpx scripts (which also need
# execution-scoped paths) symmetric. Each Bash exec under OpenClaw is a fresh
# shell, so every script must self-bootstrap; the same env_paths.sh works
# for everyone.
#
# Required input env vars per Bash exec:
#   PROJECT          project slug                                   (always)
#   GROUP            GitLab group slug                              (always)
#   GITLAB_TOKEN     GitLab access token                            (always)
#   ISSUE_IID        integer issue IID                              (per-issue)
#   EXECUTION_ID   integer execution identity, allocated by dispatcher (per-issue)
#
# Optional input env vars (forwarded by the orchestrator from trigger
# fields:
#   REPO_PARENT_PATH absolute parent for project clones (default: /data)
#   REPO_PATH        final clone target path. Compatibility input only when
#                    REPO_PARENT_PATH is unset; normally exported by this file.
#   REQ_EXECUTOR_DIR fixed agent runtime directory name (.req_executor)
#   WORK_BRANCH     trusted canonical source branch selected by the dispatcher;
#                   either issue/<current IID> or a two-member dependency
#                   branch issue/<head IID>+<tail IID> containing current IID
#   DEPENDENCY_CONTRACT_VERSION / DEPENDENCY_PLAN_SHA256
#                   required together for DAG-v2 branch
#                   issue/<current IID>-dag-<plan SHA-256 prefix>
#
# Outputs (exported into the calling shell): see lists above. Plus:
#   GITLAB_HOST, GITLAB_API_PROTOCOL    (loaded via glab_auth.sh)
#   PROJECT_FULL, PROJECT_URI            (derived)
#
# Helper: issue_state_file_for <iid> — prints absolute path to a per-issue
# state file (used by the dispatcher when scanning multiple IIDs).

set -euo pipefail

: "${PROJECT:?env_paths.sh: PROJECT must be set (trigger)}"
WORK_BRANCH_INPUT="${WORK_BRANCH:-}"
DEPENDENCY_CONTRACT_VERSION_INPUT="${DEPENDENCY_CONTRACT_VERSION:-}"
DEPENDENCY_PLAN_SHA256_INPUT="${DEPENDENCY_PLAN_SHA256:-}"

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

# Fixed internal runtime directory. It is intentionally not trigger
# configurable: req_executor runs issue prompts directly and does not expose
# per-project result/data basenames.
export REQ_EXECUTOR_DIR=".req_executor"

# ─── 1. Dispatcher-level path layout (always) ──────────────────────
export RESULT_ROOT="${REPO_PATH}/${REQ_EXECUTOR_DIR}"
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
# unset. Each IID gets exactly one worktree (reused across executions);
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

# ─── 2. Per-issue runtime layout (only when ISSUE_IID set) ──
if [ -n "${ISSUE_IID:-}" ]; then
  : "${EXECUTION_ID:?env_paths.sh: EXECUTION_ID must be set when ISSUE_IID is set (dispatcher generates it via allocate_execution_id.sh)}"
  case "${EXECUTION_ID}" in
    ''|*[!0-9]*)
      echo "env_paths.sh: EXECUTION_ID must be a positive integer" >&2
      return 2 2>/dev/null || exit 2
      ;;
  esac
  if [ "${EXECUTION_ID}" -le 0 ]; then
    echo "env_paths.sh: EXECUTION_ID must be a positive integer" >&2
    return 2 2>/dev/null || exit 2
  fi

  export ISSUE_ROOT="${ISSUES_ROOT}/issue-${ISSUE_IID}"
  export ISSUE_STATE_FILE="${ISSUE_ROOT}/state.json"
  if [ -z "${WORK_BRANCH_INPUT}" ]; then
    WORK_BRANCH_INPUT="issue/${ISSUE_IID}"
  fi
  if [ "${WORK_BRANCH_INPUT}" = "issue/${ISSUE_IID}" ]; then
    if [ -n "${DEPENDENCY_CONTRACT_VERSION_INPUT}${DEPENDENCY_PLAN_SHA256_INPUT}" ]; then
      echo "env_paths.sh: ordinary Issue branch cannot carry a DAG dependency contract" >&2
      return 2 2>/dev/null || exit 2
    fi
    :
  elif [ "${DEPENDENCY_CONTRACT_VERSION_INPUT}" = 2 ] \
      && [[ "${DEPENDENCY_PLAN_SHA256_INPUT}" =~ ^[0-9a-f]{64}$ ]] \
      && [ "${WORK_BRANCH_INPUT}" = \
        "issue/${ISSUE_IID}-dag-${DEPENDENCY_PLAN_SHA256_INPUT:0:16}" ]; then
    :
  elif [[ "${WORK_BRANCH_INPUT}" =~ ^issue/([1-9][0-9]*)\+([1-9][0-9]*)$ ]] \
      && [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ] \
      && { [ "${ISSUE_IID}" = "${BASH_REMATCH[1]}" ] \
        || [ "${ISSUE_IID}" = "${BASH_REMATCH[2]}" ]; } \
      && [ -z "${DEPENDENCY_CONTRACT_VERSION_INPUT}${DEPENDENCY_PLAN_SHA256_INPUT}" ]; then
    :
  else
    echo "env_paths.sh: WORK_BRANCH does not match the ordinary, legacy shared, or authenticated DAG-v2 Issue branch contract" >&2
    return 2 2>/dev/null || exit 2
  fi
  export WORK_BRANCH="${WORK_BRANCH_INPUT}"

  # One-time migration: older deployments placed per-issue subtrees directly
  # under ${RESULT_ROOT} (legacy issue-<iid>/) before the issues/
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

  export EXECUTION_ID

  # Every run of this IID uses one linked git worktree at
  # WORKTREE_DIR (the path does NOT include the execution identity). The parent
  # checkout at ${REPO_PATH} is only used as the shared object database /
  # `git fetch` target and is NEVER mutated by an execution. Cross-IID
  # parallelism is still safe because different IIDs get different worktree
  # paths; same-IID executions never run concurrently (single-batch-in-flight
  # invariant enforced by the dispatcher's `pending_subagents` bookkeeping),
  # so it is safe to reuse one working tree across executions. EXECUTION_ID is
  # an opaque random identity used by state, log isolation, and callback
  # fencing; it never represents how many times the Issue has run.
  # prepare_attempt.sh owns the create-or-reuse logic.
  #
  # Persistent Issue state and the latest summary live in ISSUE_ROOT. Each
  # execution uses an isolated state file and log directory.
  # stage_and_guard.sh force-adds OUTPUT_DIR and the complete current LOG_DIR;
  # unrelated generic logs/ paths stay outside the commit index.
  export WORKTREE_DIR="${WORKTREES_ROOT}/issue-${ISSUE_IID}"
  export ISSUE_WORKTREE_REL="${REQ_EXECUTOR_DIR}/issue-${ISSUE_IID}"
  export ISSUE_LOG_REL="${ISSUE_WORKTREE_REL}/log/execution-${EXECUTION_ID}"
  export OUTPUT_DIR="${WORKTREE_DIR}/${ISSUE_WORKTREE_REL}/output"
  export LOG_DIR="${WORKTREE_DIR}/${ISSUE_LOG_REL}"
  export EXECUTIONS_ROOT="${ISSUE_ROOT}/executions"
  export EXECUTION_STATE_FILE="${EXECUTIONS_ROOT}/execution-${EXECUTION_ID}.json"
  export SUMMARY_FILE="${ISSUE_ROOT}/summary.md"
  # A and its dependent share one remote branch, but their linked worktrees
  # must never try to check out the same local branch. Keep one fixed local ref
  # owned by the current IID while WORK_BRANCH names the canonical remote ref.
  export LOCAL_ISSUE_BRANCH="issue/${ISSUE_IID}"

  # Only create parent-side dirs here. WORKTREE_DIR + OUTPUT_DIR + LOG_DIR
  # are created inside prepare_attempt.sh after `git worktree add`
  # succeeds — creating WORKTREE_DIR ahead of time would make
  # `git worktree add` refuse the path, and LOG_DIR is nested inside the
  # worktree.
  if [ -d "${REPO_PATH}/.git" ]; then
    mkdir -p "${ISSUE_ROOT}" "${EXECUTIONS_ROOT}"
  fi
fi

# ─── 3. GitLab tuple resolution + glab auth ────────────────────────
# Resolve host/protocol as one target layer before authentication. A local
# target may use an explicitly injected process token or its own ignored-file
# token, but it must never inherit the tracked deployment token.
__RESOLVED_REPO_PARENT_PATH="${REPO_PARENT_PATH}"
__RESOLVED_REPO_PATH="${REPO_PATH}"
__ENV_PATHS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__ENV_PATHS_WORKSPACE_ROOT="$(cd "${__ENV_PATHS_SH_DIR}/../../.." && pwd)"
__ENV_PATHS_CONFIG_DIR="${CONFIG_DIR:-${__ENV_PATHS_WORKSPACE_ROOT}/config}"
__PIN_FILE="${__ENV_PATHS_CONFIG_DIR}/gitlab.env"
__LOCAL_FILE="${__ENV_PATHS_CONFIG_DIR}/campaign_defaults.local.env"

__PROCESS_HOST_SET="${GITLAB_HOST+x}"
__PROCESS_HOST="${GITLAB_HOST:-}"
__PROCESS_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
__PROCESS_PROTOCOL="${GITLAB_API_PROTOCOL:-}"
__PROCESS_TOKEN_SET="${GITLAB_TOKEN+x}"
__PROCESS_TOKEN="${GITLAB_TOKEN:-}"
__PROCESS_LOCAL_MODE_SET="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE+x}"
__PROCESS_LOCAL_MODE="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE:-}"
__PROCESS_ALLOWED_HOSTS_SET="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS+x}"
__PROCESS_ALLOWED_HOSTS="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS:-}"
__PROCESS_GLAB_BIN_SET="${GLAB_BIN+x}"
__PROCESS_GLAB_BIN="${GLAB_BIN:-}"
__PROCESS_GLAB_CONFIG_DIR_SET="${GLAB_CONFIG_DIR+x}"
__PROCESS_GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR:-}"

if [ -f "${__PIN_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${__PIN_FILE}"
  __TRACKED_HOST_SET="${GITLAB_HOST+x}"
  __TRACKED_HOST="${GITLAB_HOST:-}"
  __TRACKED_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
  __TRACKED_PROTOCOL="${GITLAB_API_PROTOCOL:-}"
  __TRACKED_TOKEN_SET="${GITLAB_TOKEN+x}"
  __TRACKED_TOKEN="${GITLAB_TOKEN:-}"
else
  __TRACKED_HOST_SET=""
  __TRACKED_HOST=""
  __TRACKED_PROTOCOL_SET=""
  __TRACKED_PROTOCOL=""
  __TRACKED_TOKEN_SET=""
  __TRACKED_TOKEN=""
fi

unset GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
if [ -f "${__LOCAL_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${__LOCAL_FILE}"
fi
__LOCAL_HOST_SET="${GITLAB_HOST+x}"
__LOCAL_HOST="${GITLAB_HOST:-}"
__LOCAL_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
__LOCAL_PROTOCOL="${GITLAB_API_PROTOCOL:-}"
__LOCAL_TOKEN_SET="${GITLAB_TOKEN+x}"
__LOCAL_TOKEN="${GITLAB_TOKEN:-}"

# The ignored file also carries scheduler defaults such as REPO_PARENT_PATH.
# env_paths has already derived its path tuple from explicit caller inputs, so
# restore those values after extracting only the intended GitLab settings.
REPO_PARENT_PATH="${__RESOLVED_REPO_PARENT_PATH}"
REPO_PATH="${__RESOLVED_REPO_PATH}"
export REPO_PARENT_PATH REPO_PATH

if [ "${__PROCESS_LOCAL_MODE_SET}" = x ]; then
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE="${__PROCESS_LOCAL_MODE}"
fi
if [ "${__PROCESS_ALLOWED_HOSTS_SET}" = x ]; then
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="${__PROCESS_ALLOWED_HOSTS}"
fi
if [ "${__PROCESS_GLAB_BIN_SET}" = x ]; then
  GLAB_BIN="${__PROCESS_GLAB_BIN}"
fi
if [ "${__PROCESS_GLAB_CONFIG_DIR_SET}" = x ]; then
  GLAB_CONFIG_DIR="${__PROCESS_GLAB_CONFIG_DIR}"
fi
if [ -n "${GLAB_CONFIG_DIR:-}" ]; then
  case "${GLAB_CONFIG_DIR}" in
    /*) ;;
    *) echo "env_paths.sh: GLAB_CONFIG_DIR must be absolute" >&2; exit 11 ;;
  esac
  case "${GLAB_CONFIG_DIR}" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "env_paths.sh: GLAB_CONFIG_DIR contains control characters" >&2
      exit 11
      ;;
  esac
  export GLAB_CONFIG_DIR
fi

__PROCESS_TARGET_SET=false
if [ "${__PROCESS_HOST_SET}" = x ] \
    || [ "${__PROCESS_PROTOCOL_SET}" = x ]; then
  __PROCESS_TARGET_SET=true
fi
__LOCAL_TARGET_SET=false
if [ "${__LOCAL_HOST_SET}" = x ] \
    || [ "${__LOCAL_PROTOCOL_SET}" = x ]; then
  __LOCAL_TARGET_SET=true
fi

__GITLAB_AUTH_REQUIRED=true
if [ "${__PROCESS_TARGET_SET}" = true ]; then
  if [ "${__PROCESS_HOST_SET}" != x ] \
      || [ "${__PROCESS_PROTOCOL_SET}" != x ]; then
    echo "env_paths.sh: process GITLAB_HOST and GITLAB_API_PROTOCOL must be provided together" >&2
    exit 11
  fi
  if [ "${__PROCESS_TOKEN_SET}" != x ]; then
    echo "env_paths.sh: a process GitLab target requires process GITLAB_TOKEN" >&2
    exit 11
  fi
  GITLAB_HOST="${__PROCESS_HOST}"
  GITLAB_API_PROTOCOL="${__PROCESS_PROTOCOL}"
  GITLAB_TOKEN="${__PROCESS_TOKEN}"
  __GITLAB_AUTH_REQUIRED=false
elif [ "${__LOCAL_TARGET_SET}" = true ]; then
  if [ "${__LOCAL_HOST_SET}" != x ] \
      || [ "${__LOCAL_PROTOCOL_SET}" != x ]; then
    echo "env_paths.sh: local GitLab host and protocol must be provided together" >&2
    exit 11
  fi
  GITLAB_HOST="${__LOCAL_HOST}"
  GITLAB_API_PROTOCOL="${__LOCAL_PROTOCOL}"
  if [ "${__PROCESS_TOKEN_SET}" = x ]; then
    GITLAB_TOKEN="${__PROCESS_TOKEN}"
  elif [ "${__LOCAL_TOKEN_SET}" = x ]; then
    GITLAB_TOKEN="${__LOCAL_TOKEN}"
  else
    echo "env_paths.sh: a local GitLab target requires a process or local-file GITLAB_TOKEN" >&2
    exit 11
  fi
elif [ "${__LOCAL_TOKEN_SET}" = x ]; then
  echo "env_paths.sh: local GITLAB_TOKEN requires a local host and protocol" >&2
  exit 11
else
  if [ "${__TRACKED_HOST_SET}" != x ] \
      || [ "${__TRACKED_PROTOCOL_SET}" != x ]; then
    echo "env_paths.sh: ${__PIN_FILE} must define GITLAB_HOST and GITLAB_API_PROTOCOL" >&2
    exit 11
  fi
  GITLAB_HOST="${__TRACKED_HOST}"
  GITLAB_API_PROTOCOL="${__TRACKED_PROTOCOL}"
  if [ "${__PROCESS_TOKEN_SET}" = x ]; then
    GITLAB_TOKEN="${__PROCESS_TOKEN}"
  elif [ "${__TRACKED_TOKEN_SET}" = x ]; then
    GITLAB_TOKEN="${__TRACKED_TOKEN}"
  else
    GITLAB_TOKEN=""
  fi
fi

: "${GITLAB_HOST:?env_paths.sh: resolved GITLAB_HOST must be non-empty}"
: "${GITLAB_API_PROTOCOL:?env_paths.sh: resolved GITLAB_API_PROTOCOL must be non-empty}"
: "${GITLAB_TOKEN:?env_paths.sh: GITLAB_TOKEN must be set for the resolved target}"
export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN

# Enforce the local-test host allowlist even when a complete process tuple is
# supplied. Process-token operation may legitimately skip persistent glab auth,
# but it must never skip the blue-zone deny fence.
# shellcheck disable=SC1091
source "${__ENV_PATHS_SH_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=env_paths
git_network_guard_enforce_local_test_host || exit $?

if [ "${__GITLAB_AUTH_REQUIRED}" = true ]; then
  bash "${__ENV_PATHS_SH_DIR}/glab_auth.sh" >/dev/null
fi

unset __ENV_PATHS_SH_DIR __ENV_PATHS_WORKSPACE_ROOT __ENV_PATHS_CONFIG_DIR
unset __PIN_FILE __LOCAL_FILE
unset __PROCESS_HOST_SET __PROCESS_HOST __PROCESS_PROTOCOL_SET __PROCESS_PROTOCOL
unset __PROCESS_TOKEN_SET __PROCESS_TOKEN __PROCESS_LOCAL_MODE_SET __PROCESS_LOCAL_MODE
unset __PROCESS_ALLOWED_HOSTS_SET __PROCESS_ALLOWED_HOSTS
unset __PROCESS_GLAB_BIN_SET __PROCESS_GLAB_BIN
unset __PROCESS_GLAB_CONFIG_DIR_SET __PROCESS_GLAB_CONFIG_DIR
unset __TRACKED_HOST_SET __TRACKED_HOST __TRACKED_PROTOCOL_SET __TRACKED_PROTOCOL
unset __TRACKED_TOKEN_SET __TRACKED_TOKEN
unset __LOCAL_HOST_SET __LOCAL_HOST __LOCAL_PROTOCOL_SET __LOCAL_PROTOCOL
unset __LOCAL_TOKEN_SET __LOCAL_TOKEN __PROCESS_TARGET_SET __LOCAL_TARGET_SET
unset __GITLAB_AUTH_REQUIRED
unset __RESOLVED_REPO_PARENT_PATH __RESOLVED_REPO_PATH

# ─── 4. Project handle ────────────────────────────────────────────
# A fixed wrapper supplies GROUP + PROJECT. Derive both downstream handles
# from that pair every time so an ambient PROJECT_FULL or PROJECT_URI from a
# previous project cannot redirect Git or API operations. Callers that only
# have a canonical PROJECT_FULL may continue to omit GROUP.
if [ -n "${GROUP:-}" ]; then
  export PROJECT_FULL="${GROUP}/${PROJECT}"
else
  : "${PROJECT_FULL:?env_paths.sh: GROUP or PROJECT_FULL must be set}"
fi
PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"
export PROJECT_URI
