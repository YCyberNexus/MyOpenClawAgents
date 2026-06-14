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
# flow (commit + push partial work to ${WORK_BRANCH}, label `timeout`; there
# is no MR step in this campaign). See references/executor_prompt.md §timeout_flow.
#
# Orphan prevention (defense-in-depth): acpx is launched as a backgrounded
# job in its OWN process group and reaped with `wait`, with a SIGTERM/INT/HUP
# trap that tears the whole acpx process group down. This stops a Bash-tool
# command-timeout (which may kill only our direct child) from orphaning a
# still-running acpx that would keep mutating the shared per-issue worktree
# after the subagent already classified the attempt. SIGKILL of this script
# cannot be trapped, so this is best-effort; the executor prompt pairs it with
# a routing rule that treats any return without a clean `ACPX_EXIT=` line as
# `timeout`, never `blocked`.

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

# Benchmark efficiency stamp: record wall-clock start before acpx launches.
# collect_metrics.sh reads timing.txt to compute wall_clock_seconds.
printf 'start_epoch=%s\n' "$(date +%s)" > "${LOG_DIR}/timing.txt"

# Run acpx (under `timeout`) as a backgrounded job in its OWN process group
# so the entire acpx subtree can be torn down if THIS script is signalled to
# stop. Two reasons this matters:
#   1. The subagent's Bash tool enforces its own command timeout. If that
#      timeout (or a disconnect) kills only our direct child, a *foreground*
#      acpx would be re-parented to init and keep running — an orphan that
#      still mutates the shared per-issue worktree while the subagent has
#      already classified the attempt. That orphan is the root cause behind a
#      premature `blocked` label appearing on the issue while acpx is "still
#      running".
#   2. `set -m` puts the job in a fresh process group (PGID == the job's PID
#      == $!), so `kill -s <sig> -$pgid` reaps acpx AND every child it forked
#      (claude, helpers), not just the `timeout` wrapper.
# Backgrounding + `wait` (instead of a foreground call) is required so the
# trap can fire promptly: a foreground external command holds the shell until
# it returns, deferring any trap until after acpx is already gone. A SIGKILL
# of this script cannot be trapped, so this is best-effort and covers the
# common SIGTERM/SIGINT/SIGHUP-first shutdown path. The companion defense is
# the executor prompt's routing rule: any return WITHOUT a clean `ACPX_EXIT=`
# line is classified as `timeout`, never `blocked`.
acpx_pgid=""
cleanup() {
  trap - TERM INT HUP
  if [ -n "${acpx_pgid}" ]; then
    kill -s TERM "-${acpx_pgid}" 2>/dev/null || true
    sleep 2
    kill -s KILL "-${acpx_pgid}" 2>/dev/null || true
  fi
  # Signalled abort: the script exits HERE, before the `ACPX_EXIT=<n>`
  # print below ever runs, so the subagent sees NO `ACPX_EXIT=` line. That
  # missing line — not this exit code — is what routes the attempt to the
  # timeout flow (executor_prompt.md "NO `ACPX_EXIT=<n>` line → timeout").
  # We still exit 124 (rather than the inherited signal code) so that on the
  # off chance the code IS read it maps to timeout, never blocked.
  printf 'end_epoch=%s\n' "$(date +%s)" >> "${LOG_DIR}/timing.txt" 2>/dev/null || true
  exit 124
}

set +e
set -m
PATH="${safety_bin}:${PATH}" \
TASK_OUTPUT_DIR="${OUTPUT_DIR}" \
  timeout --kill-after=30s "${ACPX_TIMEOUT_SECONDS}s" \
  acpx --auth-policy skip claude exec -f "${prompt_file}" \
  1>"${stdout_log}" 2>"${stderr_log}" &
acpx_pgid=$!
# Arm the trap only AFTER acpx_pgid is captured, so cleanup() can never run
# with an empty pgid (which would skip the group-kill). A signal in the
# microscopic window between `&` and here is handled by the default
# disposition — same orphan outcome as an empty-pgid cleanup, so no worse —
# while every signal during the long `wait` below is now guaranteed a real
# pgid to tear down.
trap cleanup TERM INT HUP
set +m
wait "${acpx_pgid}"
acpx_exit=$?
printf 'end_epoch=%s\n' "$(date +%s)" >> "${LOG_DIR}/timing.txt"
set -e
trap - TERM INT HUP

# `timeout` returns 124 on SIGTERM kill, 137 on SIGKILL kill-after fire.
if [ "${acpx_exit}" -eq 124 ] || [ "${acpx_exit}" -eq 137 ]; then
  printf 'ACPX_TIMED_OUT=1\n'
fi
printf 'ACPX_EXIT=%s\n' "${acpx_exit}"
exit "${acpx_exit}"
