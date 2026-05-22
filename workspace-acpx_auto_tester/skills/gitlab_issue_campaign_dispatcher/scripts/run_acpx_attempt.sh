#!/usr/bin/env bash
# Run the one allowed Claude Code invocation for a per-issue attempt.
#
# Keep acpx argument construction in this script instead of the rendered
# subagent prompt. That prevents model/tool-call drift from inventing flags or
# changing redirection while preserving the same one-shot execution contract.
#
# Wall-clock cap (defense-in-depth): the acpx invocation is wrapped with
# the `timeout` coreutil so the cap is enforced by the script itself, not
# just by the Bash tool calling it. When the cap fires:
#   - `timeout` sends SIGTERM to acpx after ${ACPX_TIMEOUT_SECONDS}s
#   - if acpx hasn't exited within the grace window, SIGKILL is sent
#   - the script returns exit code 124 (SIGTERM) or 137 (SIGKILL)
# The subagent prompt detects 124 / 137 and enters the dedicated timeout
# flow (commit + push partial work to ${WORK_BRANCH}, label `timeout`, NO
# MR). See references/executor_prompt.md §timeout_flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

: "${ISSUE_IID:?run_acpx_attempt.sh: ISSUE_IID must be set}"
: "${ATTEMPT_NUMBER:?run_acpx_attempt.sh: ATTEMPT_NUMBER must be set}"

# Wall-clock cap; defaults to 18000s (5h) to match acpx_timeout_seconds.
ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_SECONDS:-18000}"
case "${ACPX_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*)
    echo "run_acpx_attempt.sh: ACPX_TIMEOUT_SECONDS must be a positive integer, got '${ACPX_TIMEOUT_SECONDS}'" >&2
    exit 2 ;;
esac
if [ "${ACPX_TIMEOUT_SECONDS}" -lt 60 ]; then
  echo "run_acpx_attempt.sh: ACPX_TIMEOUT_SECONDS must be >= 60, got ${ACPX_TIMEOUT_SECONDS}" >&2
  exit 2
fi

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
safety_bin="${SCRIPT_DIR}/safety_bin"

if [ ! -f "${prompt_file}" ]; then
  echo "run_acpx_attempt.sh: prompt file missing: ${prompt_file}" >&2
  exit 2
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "run_acpx_attempt.sh: GNU coreutils 'timeout' is required but missing on PATH" >&2
  exit 2
fi

# Mode-bit heal lives in the dispatcher: _dispatch_lib.sh::ensure_safety_bin_executable
# runs once per scheduled tick. If this assertion ever trips, the heal didn't run for
# this tick — investigate dispatch_prepare_tick.sh / deployment sync, not this script.
if [ ! -x "${safety_bin}/rm" ]; then
  echo "run_acpx_attempt.sh: rm safety wrapper missing or not executable: ${safety_bin}/rm" >&2
  exit 2
fi

{
  printf 'cwd=%s\n' "${WORKTREE_DIR}"
  printf 'TASK_OUTPUT_DIR=%s\n' "${OUTPUT_DIR}"
  printf 'PATH_PREFIX=%s\n' "${safety_bin}"
  printf 'timeout=%ss (kill-after=30s)\n' "${ACPX_TIMEOUT_SECONDS}"
  printf 'command=timeout --kill-after=30s %ss acpx --auth-policy skip claude exec -f %s\n' \
    "${ACPX_TIMEOUT_SECONDS}" "${prompt_file}"
} > "${LOG_DIR}/acpx_command.txt"

cd "${WORKTREE_DIR}"

set +e
PATH="${safety_bin}:${PATH}" \
TASK_OUTPUT_DIR="${OUTPUT_DIR}" \
  timeout --kill-after=30s "${ACPX_TIMEOUT_SECONDS}s" \
  acpx --auth-policy skip claude exec -f "${prompt_file}" \
  1>"${stdout_log}" 2>"${stderr_log}"
acpx_exit=$?
set -e

# `timeout` returns 124 on SIGTERM kill, 137 on SIGKILL kill-after fire.
if [ "${acpx_exit}" -eq 124 ] || [ "${acpx_exit}" -eq 137 ]; then
  printf 'ACPX_TIMED_OUT=1\n'
fi
printf 'ACPX_EXIT=%s\n' "${acpx_exit}"
exit "${acpx_exit}"
