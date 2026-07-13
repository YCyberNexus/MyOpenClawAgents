#!/usr/bin/env bash
# clone_or_pull.sh — ensure ${REPO_PATH} exists as a clone of the project
# repo, with up-to-date refs, and create the agent's runtime subtree at
# ${REPO_PATH}/.req_executor/.
#
# The agent's state lives INSIDE the cloned repo at `${RESULT_ROOT}`.
# Before the first clone, that subtree does not exist — the bootstrap
# order is:
#
#   1. Ensure the parent directory of ${REPO_PATH} exists.
#   2. If repo is missing, acquire a tmpfs lock and `git clone`. We can't
#      use the in-repo lock yet because the repo doesn't exist.
#   3. After clone, create the dispatcher subtree (_dispatcher/log,
#      _dispatcher/locks) and the issue subtree root.
#   4. Acquire the in-repo flock and run `git fetch` + `git worktree prune`.
#   5. Idempotently append `/.req_executor/` and `logs/` to
#      `${REPO_PATH}/.git/info/exclude` so the runtime root is git-ignored
#      locally. `.git/info/exclude` is NEVER committed/pushed. The current issue's
#      `${OUTPUT_DIR}` is force-added by `stage_and_guard.sh`, and the stage
#      guard removes `logs/` paths from the index before commit.
#
# The MAIN repo's working tree is the only issue execution cwd. The
# dispatcher serializes issue attempts, and prepare_attempt.sh switches this
# checkout onto a per-attempt local branch before acpx runs.
#
# Required env vars:
#   REPO_PATH               from env_paths.sh (default /data/${PROJECT}; trigger
#                           repo_path overrides the parent)
#   BRANCH                  optional target branch; omitted means origin/HEAD
#   GROUP                   from trigger
#   PROJECT                 from trigger
#   GITLAB_TOKEN            from trigger
#   GITLAB_HOST             from glab_auth.sh (deployment pin)
#   GITLAB_API_PROTOCOL     from glab_auth.sh (deployment pin)
#
# `git fetch --prune origin` retrieves all branches for prepare_attempt.sh.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# env_paths.sh now resolves process/local/tracked GitLab values as one tuple;
# do not source the broad local scheduler file here because that can overwrite
# explicit path inputs before path derivation.
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
source "${SCRIPT_DIR}/branch_utils.sh"

: "${REPO_PATH:?}" "${WORK_ROOT:?}" \
  "${GROUP:?}" "${PROJECT:?}" "${GITLAB_TOKEN:?}" \
  "${GITLAB_HOST:?run scripts/glab_auth.sh first}" \
  "${GITLAB_API_PROTOCOL:?run scripts/glab_auth.sh first}"
BRANCH="${BRANCH:-}"

clone_die() {
  echo "clone_or_pull: $1" >&2
  exit "${2:-15}"
}

GIT_NETWORK_GUARD_CONTEXT=clone_or_pull
git_network_guard_validate_target
git_network_guard_enforce_local_test_host
git_network_guard_reject_proxy_environment
if ! [[ "${GITLAB_TOKEN}" =~ ^[A-Za-z0-9._~-]+$ ]]; then
  clone_die "GITLAB_TOKEN contains characters that are unsafe in an authenticated URL"
fi

AUTHED_REMOTE_URL="${GITLAB_API_PROTOCOL}://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GROUP}/${PROJECT}.git"
git_network_guard_validate_origin_url "${AUTHED_REMOTE_URL}" \
  || clone_die "constructed GitLab origin failed strict validation"

mkdir -p "$(dirname "${REPO_PATH}")"

# ─── First-time bootstrap (no in-repo lock yet) ───────────────────
if [ ! -d "${REPO_PATH}/.git" ]; then
  BOOTSTRAP_LOCK="/tmp/req_executor.clone.${PROJECT}.lock"
  exec 7>"${BOOTSTRAP_LOCK}"
  flock 7
  if [ ! -d "${REPO_PATH}/.git" ]; then  # re-check after acquiring lock
    if [ -d "${REPO_PATH}" ]; then
      # REPO_PATH exists but is not a git clone. Could be partial state
      # from a prior interrupted bootstrap (e.g. env_paths.sh mkdir'd
      # the runtime subtree before a previous tick crashed before
      # `git clone`), OR could be a directory the operator put there on
      # purpose. We refuse to delete it automatically. Fail the tick with
      # a clear message; the operator decides whether the directory is
      # safe to archive or clear manually.
      echo "clone_or_pull: ${REPO_PATH} exists but is not a git clone (no .git/ inside)." >&2
      echo "  Refusing to delete automatically. If this is leftover state from an" >&2
      echo "  interrupted bootstrap and the directory contains nothing important," >&2
      echo "  archive or clear it manually and re-trigger the scheduled wake-up." >&2
      echo "  Otherwise investigate what put it there before retrying." >&2
      flock -u 7
      exit 12
    fi
    if [ -n "${BRANCH}" ]; then
      git_network_guard_clone -b "${BRANCH}" \
        "${AUTHED_REMOTE_URL}" "${REPO_PATH}" >&2
    else
      git_network_guard_clone \
        "${AUTHED_REMOTE_URL}" "${REPO_PATH}" >&2
    fi
  fi
  flock -u 7
fi

# ─── Now ${REPO_PATH} is guaranteed to be a real clone. ───────────
# Create the dispatcher subtree (env_paths.sh skipped this on the first
# pass because ${REPO_PATH}/.git did not yet exist).
mkdir -p \
  "${WORK_ROOT}" \
  "${STATE_DIR}" \
  "${LOG_ROOT}" \
  "${DISPATCHER_LOG_DIR}" \
  "${ISSUES_ROOT}" \
  "${WORK_ROOT}/locks"

# Acquire the in-repo lock for fetch + worktree prune. This is the same
# lock prepare_attempt.sh uses, so concurrent fetch + branch checkout are
# serialized.
LOCK_DIR="${WORK_ROOT}/locks"
exec 8>"${LOCK_DIR}/repo.lock"
flock 8

cd "${REPO_PATH}"
# The existing origin may contain a credential from an older local run. Audit
# its protocol/host/path without network access, then replace it with the
# currently resolved credential before the first guarded fetch.
git_network_guard_assert_repo_rewrite_context "${REPO_PATH}"
git remote set-url origin "${AUTHED_REMOTE_URL}" >&2
git_network_guard_harden_repo "${REPO_PATH}"
git_network_guard_run "${REPO_PATH}" fetch --prune origin >&2
if [ -z "${BRANCH}" ]; then
  BRANCH="$(resolve_origin_default_branch "${REPO_PATH}")" || {
    echo "clone_or_pull: unable to resolve origin/HEAD default branch" >&2
    exit 14
  }
fi

# Prune stale linked-worktree metadata left by older deployments.
git worktree prune

# Ensure the agent runtime root and generic logs directories are locally ignored. `.git/info/exclude`
# has identical semantics to `.gitignore` but is never committed/pushed,
# without touching the project's tracked `.gitignore`. Idempotent: a
# fixed-string match prevents duplicate appends across ticks.
RUNTIME_IGNORE_LINE="/$(basename "${RESULT_ROOT}")/"
LOGS_IGNORE_LINE="logs/"
EXCLUDE_FILE="${REPO_PATH}/.git/info/exclude"
mkdir -p "$(dirname "${EXCLUDE_FILE}")"
if [ ! -f "${EXCLUDE_FILE}" ] || ! grep -Fxq "${RUNTIME_IGNORE_LINE}" "${EXCLUDE_FILE}"; then
  printf '\n# req_executor runtime root (managed by clone_or_pull.sh)\n%s\n' \
    "${RUNTIME_IGNORE_LINE}" >> "${EXCLUDE_FILE}"
fi
if [ ! -f "${EXCLUDE_FILE}" ] || ! grep -Fxq "${LOGS_IGNORE_LINE}" "${EXCLUDE_FILE}"; then
  printf '\n# req_executor local logs (managed by clone_or_pull.sh)\n%s\n' \
    "${LOGS_IGNORE_LINE}" >> "${EXCLUDE_FILE}"
fi
