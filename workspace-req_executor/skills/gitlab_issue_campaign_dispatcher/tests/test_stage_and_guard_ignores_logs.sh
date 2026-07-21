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
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-7/log/execution-1"

mkdir -p "${WORKTREE_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
git -C "${WORKTREE_DIR}" init -q
git -C "${WORKTREE_DIR}" config user.email "req-executor-test@example.invalid"
git -C "${WORKTREE_DIR}" config user.name "req-executor-test"
printf '/.req_executor/\nlogs/\n' >"${WORKTREE_DIR}/.git/info/exclude"
mkdir -p "${WORKTREE_DIR}/src" "${WORKTREE_DIR}/logs"
printf 'base\n' >"${WORKTREE_DIR}/src/app.txt"
printf 'old log\n' >"${WORKTREE_DIR}/logs/old.log"
git -C "${WORKTREE_DIR}" add src/app.txt
git -C "${WORKTREE_DIR}" add -f logs/old.log
git -C "${WORKTREE_DIR}" commit -m "base" >/dev/null

printf 'changed\n' >"${WORKTREE_DIR}/src/app.txt"
mv "${WORKTREE_DIR}/logs/old.log" "${WORKTREE_DIR}/logs/old.log.rotated"
printf 'new log\n' >"${WORKTREE_DIR}/logs/new.log"
mkdir -p "${WORKTREE_DIR}/service/logs"
printf 'nested log\n' >"${WORKTREE_DIR}/service/logs/trace.log"
printf 'inner prompt\n' >"${LOG_DIR}/prompt.txt"
printf 'inner result\n' >"${LOG_DIR}/claude_result.txt"
printf 'raw acpx output\n' >"${LOG_DIR}/acpx_raw.log"
printf '{"status":"done"}\n' >"${LOG_DIR}/acpx_terminal.json"

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
  EXECUTION_ID=1 \
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

for expected_log in \
  prompt.txt \
  claude_result.txt \
  acpx_raw.log \
  acpx_terminal.json \
  git_status.txt \
  git_diff.patch; do
  expected_path=".req_executor/issue-7/log/execution-1/${expected_log}"
  if ! grep -Fxq "${expected_path}" <<<"${staged}"; then
    echo "expected complete req_executor LOG_DIR to be staged: ${expected_path}" >&2
    printf '%s\n' "${staged}" >&2
    exit 1
  fi
done

NO_CHANGE_PROJECT_NAME="req_executor_log_only_test"
NO_CHANGE_REPO_PATH="${REPO_PARENT}/${NO_CHANGE_PROJECT_NAME}"
NO_CHANGE_WORKTREE_DIR="${NO_CHANGE_REPO_PATH}/.req_executor/.worktrees/issue-8"
NO_CHANGE_OUTPUT_DIR="${NO_CHANGE_WORKTREE_DIR}/.req_executor/issue-8/output"
NO_CHANGE_LOG_DIR="${NO_CHANGE_WORKTREE_DIR}/.req_executor/issue-8/log/execution-2"
mkdir -p "${NO_CHANGE_OUTPUT_DIR}" "${NO_CHANGE_LOG_DIR}"
git -C "${NO_CHANGE_WORKTREE_DIR}" init -q
git -C "${NO_CHANGE_WORKTREE_DIR}" config user.email "req-executor-test@example.invalid"
git -C "${NO_CHANGE_WORKTREE_DIR}" config user.name "req-executor-test"
printf '/.req_executor/\nlogs/\n' >"${NO_CHANGE_WORKTREE_DIR}/.git/info/exclude"
printf 'unchanged\n' >"${NO_CHANGE_WORKTREE_DIR}/app.txt"
git -C "${NO_CHANGE_WORKTREE_DIR}" add app.txt
git -C "${NO_CHANGE_WORKTREE_DIR}" commit -m "base" >/dev/null
printf 'inner prompt only\n' >"${NO_CHANGE_LOG_DIR}/prompt.txt"
printf 'inner result only\n' >"${NO_CHANGE_LOG_DIR}/claude_result.txt"

no_change_result="$(
  PROJECT="${NO_CHANGE_PROJECT_NAME}" \
  GROUP="claw_gitlab" \
  GITLAB_HOST="local-gitlab.invalid:9443" \
  GITLAB_API_PROTOCOL="https" \
  GITLAB_TOKEN="test-token" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="local-gitlab.invalid:9443" \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=8 \
  EXECUTION_ID=2 \
  bash "${STAGE_SCRIPT}"
)"
if [ "${no_change_result}" != "NO_CHANGES" ]; then
  echo "expected log-only execution to return NO_CHANGES, got ${no_change_result}" >&2
  exit 1
fi
if [ -n "$(git -C "${NO_CHANGE_WORKTREE_DIR}" diff --cached --name-only)" ]; then
  echo "expected log-only execution to leave the commit index empty" >&2
  git -C "${NO_CHANGE_WORKTREE_DIR}" diff --cached --name-only >&2
  exit 1
fi

echo "ok stage_and_guard tracks executor LOG_DIR and ignores generic logs directories"
