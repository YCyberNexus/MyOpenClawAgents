#!/usr/bin/env bash
# prepare_attempt.sh — dispatcher-owned prepared-worktree creation.
# Replaces the current issue worktree, selects the correct base ref,
# creates local-only hulat/.claude runtime material, and writes the
# worktree exclude file. Subagents must receive this already done.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${REPO_PATH:?}" "${WORK_ROOT:?}" "${BRANCH:?}" "${DEV_BRANCH:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" \
  "${ATTEMPT_DIR:?}" "${WORKTREE_DIR:?}" "${LOG_DIR:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${WORK_BRANCH:?}" "${LOCAL_ATTEMPT_BRANCH:?}" "${HULAT_DIR:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "prepare_attempt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

LOCK_DIR="${WORK_ROOT}/locks"
mkdir -p "${LOCK_DIR}"
exec 8>"${LOCK_DIR}/repo.lock"
flock 8

cd "${REPO_PATH}"
git fetch --prune origin

BASE_REF="origin/${DEV_BRANCH}"
ACTUAL_MODE="${ISSUE_MODE}"
if [ "${ACTUAL_MODE}" = "continue" ]; then
  if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
    BASE_REF="origin/${WORK_BRANCH}"
  else
    ACTUAL_MODE=fresh
    BASE_REF="origin/${DEV_BRANCH}"
  fi
fi

if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
  echo "prepare_attempt: base ref ${BASE_REF} does not exist on origin" >&2
  echo "Check that --dev_branch=${DEV_BRANCH} is correct and the branch exists on the remote." >&2
  exit 5
fi

if [ -e "${WORKTREE_DIR}" ]; then
  if [ -d "${WORKTREE_DIR}" ]; then
    git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true
    rm -rf "${WORKTREE_DIR}"
  else
    rm -f "${WORKTREE_DIR}"
  fi
fi
git worktree prune

if [ -d "${LOG_DIR}" ]; then
  rm -rf "${LOG_DIR}"
fi
mkdir -p "${LOG_DIR}"

if git show-ref --verify --quiet "refs/heads/${LOCAL_ATTEMPT_BRANCH}"; then
  git branch -D "${LOCAL_ATTEMPT_BRANCH}"
fi

mkdir -p "${ATTEMPT_DIR}"
git worktree add -b "${LOCAL_ATTEMPT_BRANCH}" "${WORKTREE_DIR}" "${BASE_REF}"
flock -u 8

cd "${WORKTREE_DIR}"
if [ -e "hulat" ] && [ ! -L "hulat" ]; then
  echo "prepare_attempt: cannot create hulat symlink; path already exists in worktree: ${WORKTREE_DIR}/hulat" >&2
  exit 7
fi
ln -sfn "${HULAT_DIR}" "hulat"

CLAUDE_CONFIG_SRC="${HULAT_DIR}/ifp-hulat/.claude"
CLAUDE_CONFIG_DST="${WORKTREE_DIR}/.claude"
if [ ! -d "${CLAUDE_CONFIG_SRC}" ]; then
  echo "prepare_attempt: required Claude Code config directory missing: ${CLAUDE_CONFIG_SRC}" >&2
  exit 6
fi
rm -rf "${CLAUDE_CONFIG_DST}"
cp -a "${CLAUDE_CONFIG_SRC}" "${CLAUDE_CONFIG_DST}"

EXCLUDE_FILE="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "${EXCLUDE_FILE}")"
{
  echo "# managed by dispatcher prepare_attempt.sh"
  echo "/hulat"
  echo "/.claude"
} > "${EXCLUDE_FILE}"

echo "${ACTUAL_MODE}"
echo "${LOCAL_ATTEMPT_BRANCH}"
