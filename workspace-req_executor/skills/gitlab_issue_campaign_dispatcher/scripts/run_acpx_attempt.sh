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
#
# Orphan prevention (defense-in-depth): acpx is launched as a backgrounded
# job in its OWN process group and reaped with `wait`, with a SIGTERM/INT/HUP
# trap that tears the whole acpx process group down. This stops a Bash-tool
# command-timeout (which may kill only our direct child) from orphaning a
# still-running acpx that would keep mutating the shared per-issue worktree
# after the subagent already classified the attempt. SIGKILL of this script
# cannot be trapped, so this is best-effort. The outer wrapper combines a
# missing `ACPX_EXIT=` receipt with this script's exit status: 124/137 is a
# timeout, while an earlier capability/configuration failure is blocked.

set -euo pipefail

case "${BASH_SOURCE[0]}" in
  /*) ;;
  *)
    echo "run_acpx_attempt.sh: script must be invoked by absolute path" >&2
    exit 2
    ;;
esac
SCRIPT_DIR_INPUT="${BASH_SOURCE[0]%/*}"
SCRIPT_DIR="$(cd "${SCRIPT_DIR_INPUT}" && pwd -P)"

# Establish a minimum-trust PATH before sourcing env_paths.sh. That bootstrap
# performs mkdir/config/auth setup and therefore must not resolve utilities
# from the dependency worktree. This first pass uses Bash builtins only; a
# second pass below rechecks every entry against env_paths.sh's final REPO_PATH.
bootstrap_sanitize_runtime_path() {
  local raw_path="$1" entry canonical_entry sanitized=""
  local input_repo="${REPO_PATH:-}" canonical_input_repo=""
  local -a path_entries

  if [ -n "${input_repo}" ] && [[ "${input_repo}" = /* ]] \
      && [ -d "${input_repo}" ]; then
    canonical_input_repo="$(cd "${input_repo}" && pwd -P)" || return 1
  fi
  IFS=: read -r -a path_entries <<<"${raw_path}"
  for entry in "${path_entries[@]}"; do
    if [ -z "${entry}" ] || [[ "${entry}" != /* ]]; then
      return 1
    fi
    [ -d "${entry}" ] || continue
    canonical_entry="$(cd "${entry}" && pwd -P)" || return 1
    case "${canonical_entry}/" in
      *"/.req_executor/.worktrees/"*) return 1 ;;
    esac
    if [ -n "${canonical_input_repo}" ]; then
      case "${canonical_entry}/" in
        "${canonical_input_repo}/"*) return 1 ;;
      esac
    fi
    if [ -z "${sanitized}" ]; then
      sanitized="${canonical_entry}"
    else
      sanitized="${sanitized}:${canonical_entry}"
    fi
  done
  [ -n "${sanitized}" ] || return 1
  printf '%s\n' "${sanitized}"
}

if ! BOOTSTRAP_RUNTIME_PATH="$(bootstrap_sanitize_runtime_path "${PATH}")"; then
  echo "run_acpx_attempt.sh: PATH must contain only trusted absolute directories before bootstrap" >&2
  exit 2
fi
PATH="${BOOTSTRAP_RUNTIME_PATH}"
export PATH

# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

canonicalize_executable() {
  local target="$1" link_target="" hop=0 target_dir=""

  while [ -L "${target}" ]; do
    hop=$((hop + 1))
    [ "${hop}" -le 40 ] || return 1
    link_target="$(readlink "${target}")" || return 1
    if [[ "${link_target}" = /* ]]; then
      target="${link_target}"
    else
      target="$(dirname "${target}")/${link_target}"
    fi
  done
  [ -f "${target}" ] && [ -x "${target}" ] || return 1
  target_dir="$(cd "$(dirname "${target}")" && pwd -P)" || return 1
  printf '%s/%s\n' "${target_dir}" "$(basename "${target}")"
}

sanitize_runtime_path() {
  local raw_path="$1" entry canonical_entry sanitized=""
  local -a path_entries

  IFS=: read -r -a path_entries <<<"${raw_path}"
  for entry in "${path_entries[@]}"; do
    # Empty/relative PATH entries resolve against WORKTREE_DIR after `cd` and
    # would let dependency content replace acpx, timeout, node, or a shebang
    # interpreter. Treat them as a configuration error, not as entries to
    # silently normalize.
    if [ -z "${entry}" ] || [[ "${entry}" != /* ]]; then
      return 1
    fi
    case "${entry}/" in
      "${REPO_PATH}/"*) return 1 ;;
    esac
    [ -d "${entry}" ] || continue
    canonical_entry="$(cd "${entry}" && pwd -P)" || return 1
    case "${canonical_entry}/" in
      "${canonical_repo_path}/"*) return 1 ;;
    esac
    if [ -z "${sanitized}" ]; then
      sanitized="${canonical_entry}"
    else
      sanitized="${sanitized}:${canonical_entry}"
    fi
  done
  [ -n "${sanitized}" ] || return 1
  printf '%s\n' "${sanitized}"
}

: "${ISSUE_IID:?run_acpx_attempt.sh: ISSUE_IID must be set}"
: "${EXECUTION_ID:?run_acpx_attempt.sh: EXECUTION_ID must be set}"
CLAUDE_CODE_SAFE_MODE_EFFECTIVE="${CLAUDE_CODE_SAFE_MODE:-}"
CLAUDE_CODE_EXECUTABLE_EFFECTIVE="${CLAUDE_CODE_EXECUTABLE:-/home/claw/.local/bin/claude}"
CLAUDE_CODE_FORK_SUBAGENT_EFFECTIVE=1

if [ ! -d "${REPO_PATH}/.git" ]; then
  echo "run_acpx_attempt.sh: REPO_PATH is not a git checkout: ${REPO_PATH}" >&2
  exit 2
fi
canonical_repo_path="$(cd "${REPO_PATH}" && pwd -P)"
if ! TRUSTED_RUNTIME_PATH="$(sanitize_runtime_path "${PATH}")"; then
  echo "run_acpx_attempt.sh: PATH must contain only absolute directories outside REPO_PATH" >&2
  exit 2
fi
PATH="${TRUSTED_RUNTIME_PATH}"
export PATH
if ! TIMEOUT_EXECUTABLE="$(
    canonicalize_executable "$(command -v timeout 2>/dev/null || true)"
  )"; then
  echo "run_acpx_attempt.sh: GNU coreutils 'timeout' is required but missing on trusted PATH" >&2
  exit 2
fi
if ! ACPX_EXECUTABLE="$(
    canonicalize_executable "$(command -v acpx 2>/dev/null || true)"
  )"; then
  echo "run_acpx_attempt.sh: acpx is required but missing on trusted PATH" >&2
  exit 2
fi
if [[ "${CLAUDE_CODE_EXECUTABLE_EFFECTIVE}" != /* ]] \
    || [ ! -x "${CLAUDE_CODE_EXECUTABLE_EFFECTIVE}" ]; then
  echo "run_acpx_attempt.sh: CLAUDE_CODE_EXECUTABLE must be an absolute executable (default: /home/claw/.local/bin/claude)" >&2
  exit 2
fi
if ! CLAUDE_CODE_EXECUTABLE_CANONICAL="$(
    canonicalize_executable "${CLAUDE_CODE_EXECUTABLE_EFFECTIVE}"
  )"; then
  echo "run_acpx_attempt.sh: unable to canonicalize CLAUDE_CODE_EXECUTABLE" >&2
  exit 2
fi
for runtime_executable in "${TIMEOUT_EXECUTABLE}" "${ACPX_EXECUTABLE}"; do
  case "${runtime_executable}/" in
    "${canonical_repo_path}/"*)
      echo "run_acpx_attempt.sh: runtime executables must be outside REPO_PATH" >&2
      exit 2
      ;;
  esac
done
case "${CLAUDE_CODE_EXECUTABLE_CANONICAL}/" in
  "${canonical_repo_path}/"*)
    echo "run_acpx_attempt.sh: CLAUDE_CODE_EXECUTABLE must be outside REPO_PATH" >&2
    exit 2
    ;;
esac

# Wall-clock cap; defaults to 3600s (1h) to match acpx_timeout_seconds.
ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_SECONDS:-3600}"
case "${ACPX_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*)
    echo "run_acpx_attempt.sh: ACPX_TIMEOUT_SECONDS must be a positive integer, got '${ACPX_TIMEOUT_SECONDS}'" >&2
    exit 2 ;;
esac
if [ "${ACPX_TIMEOUT_SECONDS}" -lt 60 ]; then
  echo "run_acpx_attempt.sh: ACPX_TIMEOUT_SECONDS must be >= 60, got ${ACPX_TIMEOUT_SECONDS}" >&2
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
terminal_marker="${LOG_DIR}/acpx_terminal.json"
safety_bin="${SCRIPT_DIR}/safety_bin"

if [ ! -f "${prompt_file}" ]; then
  echo "run_acpx_attempt.sh: prompt file missing: ${prompt_file}" >&2
  exit 2
fi

# Mode-bit heal lives in the dispatcher: _dispatch_lib.sh::ensure_safety_bin_executable
# runs once per scheduled tick. If this assertion ever trips, the heal didn't run for
# this tick — investigate dispatch_prepare_tick.sh / deployment sync, not this script.
for safety_command in rm git glab; do
  if [ ! -x "${safety_bin}/${safety_command}" ]; then
    echo "run_acpx_attempt.sh: safety wrapper missing or not executable: ${safety_bin}/${safety_command}" >&2
    exit 2
  fi
done

# ACPx's built-in Claude adapter isolates user settings by default. The
# OpenClaw runner needs the user's Claude Code auth/model provider config
# (for example third-party DeepSeek settings) to reach the inner agent.
: "${ACPX_CLAUDE_INCLUDE_USER_SETTINGS:=1}"

{
  printf 'cwd=%s\n' "${WORKTREE_DIR}"
  printf 'TASK_OUTPUT_DIR=%s\n' "${OUTPUT_DIR}"
  printf 'PATH_PREFIX=%s\n' "${safety_bin}"
  printf 'CLAUDE_CODE_EXECUTABLE=%s\n' "${CLAUDE_CODE_EXECUTABLE_EFFECTIVE}"
  printf 'CLAUDE_CODE_FORK_SUBAGENT=%s\n' "${CLAUDE_CODE_FORK_SUBAGENT_EFFECTIVE}"
  printf 'ACPX_CLAUDE_INCLUDE_USER_SETTINGS=%s\n' "${ACPX_CLAUDE_INCLUDE_USER_SETTINGS}"
  printf 'CLAUDE_CODE_SAFE_MODE=%s\n' "${CLAUDE_CODE_SAFE_MODE_EFFECTIVE}"
  printf 'timeout=%ss (kill-after=30s)\n' "${ACPX_TIMEOUT_SECONDS}"
  printf 'command=CLAUDE_CODE_EXECUTABLE=%s CLAUDE_CODE_FORK_SUBAGENT=%s ACPX_CLAUDE_INCLUDE_USER_SETTINGS=%s %s --kill-after=30s %ss %s --auth-policy skip claude exec -f %s\n' \
    "${CLAUDE_CODE_EXECUTABLE_EFFECTIVE}" \
    "${CLAUDE_CODE_FORK_SUBAGENT_EFFECTIVE}" \
    "${ACPX_CLAUDE_INCLUDE_USER_SETTINGS}" \
    "${TIMEOUT_EXECUTABLE}" "${ACPX_TIMEOUT_SECONDS}" \
    "${ACPX_EXECUTABLE}" "${prompt_file}"
} > "${LOG_DIR}/acpx_command.txt"

cd "${WORKTREE_DIR}"

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
# common SIGTERM/SIGINT/SIGHUP-first shutdown path. The outer wrapper uses the
# missing receipt together with the 124 exit status to distinguish this abort
# from a blocked preflight failure.
acpx_pgid=""
write_terminal_marker() {
  local exit_code="$1" completed_at_epoch terminal_marker_tmp
  completed_at_epoch="$(date -u +%s)"
  terminal_marker_tmp="${terminal_marker}.tmp.$$"
  (
    umask 077
    printf '{"version":1,"iid":%s,"execution_id":%s,"exit_code":%s,"completed_at_epoch":%s}\n' \
      "${ISSUE_IID}" "${EXECUTION_ID}" "${exit_code}" \
      "${completed_at_epoch}" >"${terminal_marker_tmp}"
    chmod 600 "${terminal_marker_tmp}"
    mv "${terminal_marker_tmp}" "${terminal_marker}"
  )
}

cleanup() {
  trap - TERM INT HUP
  if [ -n "${acpx_pgid}" ]; then
    kill -s TERM "-${acpx_pgid}" 2>/dev/null || true
    sleep 2
    kill -s KILL "-${acpx_pgid}" 2>/dev/null || true
  fi
  if ! write_terminal_marker 124; then
    echo "run_acpx_attempt.sh: warning: unable to persist ${terminal_marker}" >&2
  fi
  # Signalled abort: the script exits HERE, before the `ACPX_EXIT=<n>`
  # print below ever runs. The outer wrapper requires both that missing receipt
  # and this 124 exit status before routing the attempt to the timeout flow;
  # ordinary preflight failures return a different status and become blocked.
  exit 124
}

set +e
set -m
acpx_runtime_env=(
  "CLAUDE_CODE_EXECUTABLE=${CLAUDE_CODE_EXECUTABLE_EFFECTIVE}"
  "CLAUDE_CODE_FORK_SUBAGENT=${CLAUDE_CODE_FORK_SUBAGENT_EFFECTIVE}"
  "ACPX_CLAUDE_INCLUDE_USER_SETTINGS=${ACPX_CLAUDE_INCLUDE_USER_SETTINGS}"
  "CLAUDE_CODE_SAFE_MODE=${CLAUDE_CODE_SAFE_MODE_EFFECTIVE}"
)
acpx_command=(
  "${ACPX_EXECUTABLE}" --auth-policy skip claude exec -f "${prompt_file}"
)
env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u GITLAB_OAUTH_TOKEN \
  -u GLAB_TOKEN -u GITLAB_PRIVATE_TOKEN -u PRIVATE_TOKEN \
  -u OAUTH_TOKEN -u CI_JOB_TOKEN -u JOB_TOKEN -u WIKI_GITLAB_TOKEN \
  "${acpx_runtime_env[@]}" \
  PATH="${safety_bin}:${PATH}" \
  TASK_OUTPUT_DIR="${OUTPUT_DIR}" \
  "${TIMEOUT_EXECUTABLE}" --kill-after=30s "${ACPX_TIMEOUT_SECONDS}s" \
  "${acpx_command[@]}" \
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
set -e
trap - TERM INT HUP

# Persist a machine-readable terminal marker before returning control to the
# outer agent. OpenClaw can occasionally finish this long synchronous tool call
# without scheduling the model's next turn. The executor heartbeat uses this
# issue-local marker, fenced by execution_id in its payload, to distinguish
# that post-acpx stall from an inner acpx process that is still legitimately running.
if ! write_terminal_marker "${acpx_exit}"; then
  # The marker is a recovery aid, not the source of truth for this live tool
  # result. Preserve the existing ACPX_EXIT contract if the disk write fails.
  echo "run_acpx_attempt.sh: warning: unable to persist ${terminal_marker}" >&2
fi

# `timeout` returns 124 on SIGTERM kill, 137 on SIGKILL kill-after fire.
if [ "${acpx_exit}" -eq 124 ] || [ "${acpx_exit}" -eq 137 ]; then
  printf 'ACPX_TIMED_OUT=1\n'
fi
printf 'ACPX_EXIT=%s\n' "${acpx_exit}"
exit "${acpx_exit}"
