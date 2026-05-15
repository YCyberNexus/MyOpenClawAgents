#!/usr/bin/env bash
# Run the one allowed Claude Code invocation for a per-issue attempt.
#
# Keep acpx argument construction in this script instead of the rendered
# subagent prompt. That prevents model/tool-call drift from inventing flags or
# changing redirection while preserving the same one-shot execution contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

: "${ISSUE_IID:?run_acpx_attempt.sh: ISSUE_IID must be set}"
: "${ATTEMPT_NUMBER:?run_acpx_attempt.sh: ATTEMPT_NUMBER must be set}"

if [ ! -d "${REPO_PATH}/.git" ]; then
  echo "run_acpx_attempt.sh: REPO_PATH is not a git checkout: ${REPO_PATH}" >&2
  exit 2
fi

if [ ! -d "${WORKTREE_DIR}" ]; then
  echo "run_acpx_attempt.sh: WORKTREE_DIR missing: ${WORKTREE_DIR}" >&2
  exit 2
fi

if [ ! -d "${OUTPUT_DIR}" ]; then
  echo "run_acpx_attempt.sh: OUTPUT_DIR missing: ${OUTPUT_DIR}" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"

prompt_file="${LOG_DIR}/prompt.txt"
stdout_log="${LOG_DIR}/claude_result.txt"
stderr_log="${LOG_DIR}/acpx_raw.log"

if [ ! -f "${prompt_file}" ]; then
  echo "run_acpx_attempt.sh: prompt file missing: ${prompt_file}" >&2
  exit 2
fi

{
  printf 'cwd=%s\n' "${REPO_PATH}"
  printf 'TASK_OUTPUT_DIR=%s\n' "${OUTPUT_DIR}"
  printf 'command=acpx --auth-policy skip claude exec -f %s\n' "${prompt_file}"
} > "${LOG_DIR}/acpx_command.txt"

cd "${REPO_PATH}"

set +e
TASK_OUTPUT_DIR="${OUTPUT_DIR}" \
  acpx --auth-policy skip claude exec -f "${prompt_file}" \
  1>"${stdout_log}" 2>"${stderr_log}"
acpx_exit=$?
set -e

printf 'ACPX_EXIT=%s\n' "${acpx_exit}"
exit "${acpx_exit}"
