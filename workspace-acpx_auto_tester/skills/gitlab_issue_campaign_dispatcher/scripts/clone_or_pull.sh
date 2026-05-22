#!/usr/bin/env bash
# clone_or_pull.sh — ensure ${REPO_PATH} exists as a clone of the project
# repo, with up-to-date refs, and create the agent's runtime subtree at
# ${REPO_PATH}/${RESULT_BASENAME}/ (default `ifp-result/`; per-project
# overridable via the `result_basename` trigger field).
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
#   5. Idempotently append `/<basename RESULT_ROOT>/` to
#      `${REPO_PATH}/.git/info/exclude` so the runtime root is git-ignored
#      locally. `.git/info/exclude` is NEVER committed/pushed, so this
#      handles per-project naming (`ifp-result/`, `<project>-result/`, …)
#      without requiring the test team to maintain a `.gitignore` rule
#      in master + dev for every project. The current issue's
#      `${OUTPUT_DIR}` is force-added by `stage_and_guard.sh` (which
#      bypasses both gitignore and info/exclude), so the single
#      committable path is unaffected.
#
# The MAIN repo's working tree is the only issue execution cwd. The
# dispatcher serializes issue attempts, and prepare_attempt.sh switches this
# checkout onto a per-attempt local branch before acpx runs.
#
# Required env vars:
#   REPO_PATH               from env_paths.sh (default /data/${PROJECT}; trigger
#                           repo_path overrides the parent)
#   BRANCH                  integration / target branch (typically "master")
#   GROUP                   from trigger
#   PROJECT                 from trigger
#   GITLAB_TOKEN            from trigger
#   GITLAB_HOST             from glab_auth.sh (deployment pin)
#   GITLAB_API_PROTOCOL     from glab_auth.sh (deployment pin)
#
# DEV_BRANCH is consulted by prepare_attempt.sh, not here. `git fetch
# --prune origin` retrieves all branches, so DEV_BRANCH refs are
# available without a separate fetch.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${REPO_PATH:?}" "${WORK_ROOT:?}" "${BRANCH:?}" \
  "${GROUP:?}" "${PROJECT:?}" "${GITLAB_TOKEN:?}" \
  "${GITLAB_HOST:?run scripts/glab_auth.sh first}" \
  "${GITLAB_API_PROTOCOL:?run scripts/glab_auth.sh first}"

REMOTE_URL="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${GROUP}/${PROJECT}.git"
AUTHED_REMOTE_URL="$(echo "${REMOTE_URL}" | sed "s#://#://oauth2:${GITLAB_TOKEN}@#")"

mkdir -p "$(dirname "${REPO_PATH}")"

# ─── First-time bootstrap (no in-repo lock yet) ───────────────────
if [ ! -d "${REPO_PATH}/.git" ]; then
  BOOTSTRAP_LOCK="/tmp/acpx_auto_tester.clone.${PROJECT}.lock"
  exec 7>"${BOOTSTRAP_LOCK}"
  flock 7
  if [ ! -d "${REPO_PATH}/.git" ]; then  # re-check after acquiring lock
    if [ -d "${REPO_PATH}" ]; then
      # REPO_PATH exists but is not a git clone. Could be partial state
      # from a prior interrupted bootstrap (e.g. env_paths.sh mkdir'd
      # the ifp-result subtree before a previous tick crashed before
      # `git clone`), OR could be a directory the operator put there on
      # purpose. We refuse to delete it — `rm -rf` on a path the
      # operator chose is too destructive to do silently. Fail the tick
      # with a clear message; the operator decides whether the directory
      # is safe to remove and does it manually.
      echo "clone_or_pull: ${REPO_PATH} exists but is not a git clone (no .git/ inside)." >&2
      echo "  Refusing to delete automatically. If this is leftover state from an" >&2
      echo "  interrupted bootstrap and the directory contains nothing important," >&2
      echo "  remove it manually (e.g. \`rm -rf ${REPO_PATH}\`) and re-trigger the" >&2
      echo "  scheduled wake-up. Otherwise investigate what put it there before retrying." >&2
      flock -u 7
      exit 12
    fi
    git clone -b "${BRANCH}" "${AUTHED_REMOTE_URL}" "${REPO_PATH}"
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
git remote set-url origin "${AUTHED_REMOTE_URL}"
git fetch --prune origin

# Prune stale linked-worktree metadata left by older deployments.
git worktree prune

# Ensure the agent runtime root is locally ignored. `.git/info/exclude`
# has identical semantics to `.gitignore` but is never committed/pushed,
# so per-project runtime-root names (e.g. `ifp-result/`,
# `<project>-result/`) are handled here without touching the project's
# tracked `.gitignore`. Idempotent: a fixed-string match prevents
# duplicate appends across ticks.
RUNTIME_IGNORE_LINE="/$(basename "${RESULT_ROOT}")/"
EXCLUDE_FILE="${REPO_PATH}/.git/info/exclude"
mkdir -p "$(dirname "${EXCLUDE_FILE}")"
if [ ! -f "${EXCLUDE_FILE}" ] || ! grep -Fxq "${RUNTIME_IGNORE_LINE}" "${EXCLUDE_FILE}"; then
  printf '\n# acpx_auto_tester runtime root (managed by clone_or_pull.sh)\n%s\n' \
    "${RUNTIME_IGNORE_LINE}" >> "${EXCLUDE_FILE}"
fi
