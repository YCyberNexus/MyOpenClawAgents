#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_SCRIPT="${SKILL_DIR}/scripts/stage_and_guard.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-stage-logs.XXXXXX")"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_NAME="req_executor_test"
REPO_PATH="${REPO_PARENT}/${PROJECT_NAME}"
WORKTREE_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-7"
OUTPUT_DIR="${WORKTREE_DIR}/.req_executor/issue-7/output"
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-7/log/attempt-001"

mkdir -p "${WORKTREE_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
git -C "${WORKTREE_DIR}" init -q
git -C "${WORKTREE_DIR}" config user.email "req-executor-test@example.invalid"
git -C "${WORKTREE_DIR}" config user.name "req-executor-test"
mkdir -p "${WORKTREE_DIR}/src" "${WORKTREE_DIR}/logs"
printf 'base\n' >"${WORKTREE_DIR}/src/app.txt"
printf 'old log\n' >"${WORKTREE_DIR}/logs/old.log"
git -C "${WORKTREE_DIR}" add src/app.txt logs/old.log
git -C "${WORKTREE_DIR}" commit -m "base" >/dev/null

printf 'changed\n' >"${WORKTREE_DIR}/src/app.txt"
mv "${WORKTREE_DIR}/logs/old.log" "${WORKTREE_DIR}/logs/old.log.rotated"
printf 'new log\n' >"${WORKTREE_DIR}/logs/new.log"
mkdir -p "${WORKTREE_DIR}/service/logs"
printf 'nested log\n' >"${WORKTREE_DIR}/service/logs/trace.log"
printf 'inner prompt\n' >"${LOG_DIR}/prompt.txt"
printf 'inner result\n' >"${LOG_DIR}/claude_result.txt"

result="$(
  PROJECT="${PROJECT_NAME}" \
  GROUP="claw_gitlab" \
  GITLAB_HOST="local-gitlab.invalid:9443" \
  GITLAB_API_PROTOCOL="https" \
  GITLAB_TOKEN="test-token" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="local-gitlab.invalid:9443" \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=7 \
  ATTEMPT_NUMBER=1 \
  bash "${STAGE_SCRIPT}"
)"

if [ "${result}" != "STAGED_OK" ]; then
  echo "expected STAGED_OK, got ${result}" >&2
  exit 1
fi

staged="$(git -C "${WORKTREE_DIR}" diff --cached --name-only)"
if ! grep -q '^src/app.txt$' <<<"${staged}"; then
  echo "expected source change to stay staged" >&2
  printf '%s\n' "${staged}" >&2
  exit 1
fi

if grep -Eq '(^|/)logs/' <<<"${staged}"; then
  echo "expected logs/ paths to be unstaged" >&2
  printf '%s\n' "${staged}" >&2
  exit 1
fi

if grep -Eq '^\.req_executor/.*/log/' <<<"${staged}"; then
  echo "expected req_executor log files to be unstaged" >&2
  printf '%s\n' "${staged}" >&2
  exit 1
fi

echo "ok stage_and_guard ignores logs directories"
