#!/usr/bin/env bash
# Run one complete per-Issue executor attempt in a single Bash tool call.
#
# The OpenClaw outer subagent used to call run_acpx_attempt.sh and then rely on
# another model turn to start staging. A long synchronous acpx tool call can
# return without that next turn being scheduled, leaving the native subagent
# (and therefore a global subagent slot) alive until somebody talks to it.
# This wrapper keeps the whole deterministic path in one process:
#
#   acpx -> stage -> commit/push -> verify -> labels -> MR -> summary
#
# The final compact worker result is written atomically to
# ${LOG_DIR}/worker_result.json before it is printed. The executor heartbeat can
# therefore recover the exact result even if OpenClaw never asks the outer model
# to echo the line and finish its run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

: "${PROJECT:?}" "${GROUP:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER:?}"
: "${ISSUE_TITLE:?run_executor_attempt.sh: ISSUE_TITLE must be set}"
: "${ISSUE_MODE:?run_executor_attempt.sh: ISSUE_MODE must be set}"
: "${BRANCH:?run_executor_attempt.sh: BRANCH must be set}"

AUTO_MERGE="${AUTO_MERGE:-false}"
MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH}}"
case "${AUTO_MERGE}" in
  true|false) ;;
  *)
    echo "run_executor_attempt.sh: AUTO_MERGE must be true or false" >&2
    exit 2
    ;;
esac
if [ -z "${MERGE_TARGET_BRANCH}" ]; then
  echo "run_executor_attempt.sh: MERGE_TARGET_BRANCH or BRANCH must be non-empty" >&2
  exit 2
fi

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "run_executor_attempt.sh: ISSUE_MODE must be fresh or continue" >&2
    exit 2
    ;;
esac

ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_SECONDS:-3600}"
case "${ACPX_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*)
    echo "run_executor_attempt.sh: ACPX_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "${ACPX_TIMEOUT_SECONDS}" -lt 60 ]; then
  echo "run_executor_attempt.sh: ACPX_TIMEOUT_SECONDS must be >= 60" >&2
  exit 2
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "run_executor_attempt.sh: GNU coreutils 'timeout' is required" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "run_executor_attempt.sh: jq is required" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"

FINAL_STATUS=""
BLOCK_REASON=""
COMMIT_SHA=""
MERGE_REQUEST_URL=""
MERGE_REQUEST_IID=""
MR_ACTION="none"
SUMMARY_POSTED=false
SUPPRESS_SUCCESS_SUMMARY=false
LABELS_ADDED='[]'
LABELS_REMOVED='[]'
STEP_STDOUT=""
STEP_STDERR=""
STEP_RC=0

append_reason() {
  local detail="$1"
  [ -n "${detail}" ] || return 0
  if [ -z "${BLOCK_REASON}" ]; then
    BLOCK_REASON="${detail}"
  else
    BLOCK_REASON="${BLOCK_REASON}; ${detail}"
  fi
}

append_json_string() {
  local current="$1" value="$2"
  jq -c --arg value "${value}" '
    if index($value) == null then . + [$value] else . end
  ' <<<"${current}"
}

remove_json_string() {
  local current="$1" value="$2"
  jq -c --arg value "${value}" 'map(select(. != $value))' <<<"${current}"
}

last_error_line() {
  local text="$1" fallback="$2" line
  line="$(printf '%s\n' "${text}" | awk 'NF { last=$0 } END { print last }')"
  [ -n "${line}" ] || line="${fallback}"
  printf '%s' "${line}"
}

# Capture every fixed step in attempt-local evidence. Each post-acpx operation
# has its own hard cap so a wedged Git/glab call cannot indefinitely retain the
# native subagent slot. The heartbeat has a larger whole-finalization watchdog
# as a second line of defense.
run_bounded_step() {
  local name="$1" seconds="$2"
  shift 2
  local stdout_file="${LOG_DIR}/outer-${name}.stdout.log"
  local stderr_file="${LOG_DIR}/outer-${name}.stderr.log"
  set +e
  timeout --kill-after=30s "${seconds}s" "$@" \
    >"${stdout_file}" 2>"${stderr_file}"
  STEP_RC=$?
  set -e
  STEP_STDOUT="$(cat "${stdout_file}" 2>/dev/null || true)"
  STEP_STDERR="$(cat "${stderr_file}" 2>/dev/null || true)"
}

sync_label() {
  local op="$1" label="$2"
  run_bounded_step "label-${op}-${label}" 120 \
    bash "${SCRIPT_DIR}/set_issue_label.sh" "${op}" "${label}"
  if [ "${STEP_RC}" -ne 0 ]; then
    return "${STEP_RC}"
  fi
  if [ "${op}" = add ]; then
    LABELS_ADDED="$(append_json_string "${LABELS_ADDED}" "${label}")"
  else
    LABELS_REMOVED="$(append_json_string "${LABELS_REMOVED}" "${label}")"
  fi
}

sync_failure_labels() {
  local terminal_label="$1" error_text=""
  if ! sync_label remove doing; then
    error_text="$(last_error_line "${STEP_STDERR}" "remove doing failed rc=${STEP_RC}")"
  fi
  if ! sync_label add "${terminal_label}"; then
    local add_error
    add_error="$(last_error_line "${STEP_STDERR}" "add ${terminal_label} failed rc=${STEP_RC}")"
    if [ -n "${error_text}" ]; then
      error_text="${error_text}; ${add_error}"
    else
      error_text="${add_error}"
    fi
  fi
  [ -z "${error_text}" ] || append_reason "${terminal_label} label sync failed: ${error_text}"
}

run_summary() {
  local post_to_issue=false
  if [ "${FINAL_STATUS}" = done ] \
      && [ "${SUPPRESS_SUCCESS_SUMMARY}" != true ]; then
    post_to_issue=true
  fi
  run_bounded_step summarize 180 env \
    ATTEMPT_STATUS="${FINAL_STATUS}" \
    SUMMARY_POST_TO_ISSUE="${post_to_issue}" \
    COMMIT_SHA="${COMMIT_SHA}" \
    MERGE_REQUEST_URL="${MERGE_REQUEST_URL}" \
    BLOCK_REASON="${BLOCK_REASON}" \
    ISSUE_MODE="${ISSUE_MODE}" \
    bash "${SCRIPT_DIR}/summarize_attempt.sh"
  if [ "${STEP_RC}" -eq 0 ] \
      && grep -Fq 'SUMMARY_POSTED=true' "${LOG_DIR}/outer-summarize.stderr.log"; then
    SUMMARY_POSTED=true
  else
    SUMMARY_POSTED=false
  fi
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "summary step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  fi
}

persist_and_print_result() {
  local result_file="${LOG_DIR}/worker_result.json"
  local result_tmp="${result_file}.tmp.$$"
  local result
  result="$(jq -cn \
    --argjson iid "${ISSUE_IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg status "${FINAL_STATUS}" \
    --arg mode_actual "${ISSUE_MODE}" \
    --arg work_branch "${WORK_BRANCH}" \
    --arg local_branch "${LOCAL_ATTEMPT_BRANCH}" \
    --arg commit_sha "${COMMIT_SHA}" \
    --arg merge_request_url "${MERGE_REQUEST_URL}" \
    --arg mr_action "${MR_ACTION}" \
    --argjson labels_added "${LABELS_ADDED}" \
    --argjson labels_removed "${LABELS_REMOVED}" \
    --argjson summary_posted "${SUMMARY_POSTED}" \
    --arg block_reason "${BLOCK_REASON}" \
    --arg log_dir "${LOG_DIR}" '{
      iid:$iid,
      attempt_number:$attempt_number,
      status:$status,
      mode_actual:$mode_actual,
      work_branch:$work_branch,
      local_branch:$local_branch,
      commit_sha:$commit_sha,
      merge_request_url:$merge_request_url,
      mr_action:$mr_action,
      wiki_url:"",
      labels_added:$labels_added,
      labels_removed:$labels_removed,
      summary_posted:$summary_posted,
      block_reason:$block_reason,
      log_dir:$log_dir
    }')"
  if ! (
    umask 077
    printf '%s\n' "${result}" >"${result_tmp}"
    chmod 600 "${result_tmp}"
    mv "${result_tmp}" "${result_file}"
  ); then
    echo "run_executor_attempt.sh: failed to persist ${result_file}" >&2
    exit 3
  fi
  printf '%s\n' "${result}"
}

finish_blocked() {
  FINAL_STATUS=blocked
  sync_failure_labels blocked-cc
  run_summary
  persist_and_print_result
  exit 0
}

finish_timeout() {
  FINAL_STATUS=timeout
  MR_ACTION=none
  MERGE_REQUEST_URL=""
  sync_failure_labels timeout
  run_summary
  persist_and_print_result
  exit 0
}

stage_partial_work() {
  run_bounded_step stage 180 bash "${SCRIPT_DIR}/stage_and_guard.sh"
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "stage step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
    return 1
  fi
  case "$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')" in
    STAGED_OK) return 0 ;;
    NO_CHANGES)
      append_reason "no staged changes to push"
      return 1
      ;;
    *)
      append_reason "stage step returned an invalid marker"
      return 1
      ;;
  esac
}

commit_partial_work() {
  run_bounded_step commit-and-push 300 env \
    ISSUE_TITLE="${ISSUE_TITLE}" \
    bash "${SCRIPT_DIR}/commit_and_push.sh"
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "commit_and_push step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
    return 1
  fi
  COMMIT_SHA="$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')"
  if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    append_reason "commit_and_push step returned an invalid commit SHA"
    COMMIT_SHA=""
    return 1
  fi
}

verify_partial_work() {
  run_bounded_step post-push-verify 180 env \
    BRANCH="${BRANCH}" \
    bash "${SCRIPT_DIR}/post_push_verify.sh"
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "post-push verify failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
    return 1
  fi
}

if [ ! -d "${WORKTREE_DIR}" ] || [ ! -d "${OUTPUT_DIR}" ]; then
  BLOCK_REASON="worktree or output directory missing"
  finish_blocked
fi

# Keep acpx and every following deterministic step inside this same Bash tool
# call. The command writes acpx_terminal.json before returning, which lets the
# heartbeat distinguish a post-acpx stall from a still-running inner session.
run_bounded_step acpx "$((ACPX_TIMEOUT_SECONDS + 120))" env \
  ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_SECONDS}" \
  bash "${SCRIPT_DIR}/run_acpx_attempt.sh"
printf '%s\n' "${STEP_STDOUT}"

ACPX_EXIT="$(printf '%s\n' "${STEP_STDOUT}" \
  | awk -F= '/^ACPX_EXIT=[0-9]+$/ { value=$2 } END { print value }')"
if [ -z "${ACPX_EXIT}" ]; then
  BLOCK_REASON="acpx exec exceeded ${ACPX_TIMEOUT_SECONDS}s wall-clock cap"
  if stage_partial_work && commit_partial_work; then
    verify_partial_work || true
  fi
  finish_timeout
fi

case "${ACPX_EXIT}" in
  0) ;;
  124|137)
    BLOCK_REASON="acpx exec exceeded ${ACPX_TIMEOUT_SECONDS}s wall-clock cap"
    if stage_partial_work && commit_partial_work; then
      verify_partial_work || true
    fi
    finish_timeout
    ;;
  *)
    BLOCK_REASON="acpx run failed (exit ${ACPX_EXIT}); see ${LOG_DIR}/acpx_raw.log"
    if stage_partial_work && commit_partial_work; then
      verify_partial_work || true
    fi
    finish_blocked
    ;;
esac

run_bounded_step stage 180 bash "${SCRIPT_DIR}/stage_and_guard.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  BLOCK_REASON="stage step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi
case "$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')" in
  STAGED_OK) ;;
  NO_CHANGES)
    BLOCK_REASON="Claude produced no staged changes"
    finish_blocked
    ;;
  *)
    BLOCK_REASON="stage step returned an invalid marker"
    finish_blocked
    ;;
esac

run_bounded_step commit-and-push 300 env \
  ISSUE_TITLE="${ISSUE_TITLE}" \
  bash "${SCRIPT_DIR}/commit_and_push.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  BLOCK_REASON="git push failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi
COMMIT_SHA="$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')"
if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  BLOCK_REASON="git push failed: commit_and_push returned an invalid commit SHA"
  COMMIT_SHA=""
  finish_blocked
fi

run_bounded_step post-push-verify 180 env \
  BRANCH="${MERGE_TARGET_BRANCH}" \
  bash "${SCRIPT_DIR}/post_push_verify.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  BLOCK_REASON="post-push verification failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi

if ! sync_label remove doing; then
  BLOCK_REASON="label transition doing->done failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi
if ! sync_label add done; then
  BLOCK_REASON="label transition doing->done failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi

run_bounded_step create-mr 300 env \
  ISSUE_TITLE="${ISSUE_TITLE}" \
  ISSUE_MODE="${ISSUE_MODE}" \
  BRANCH="${BRANCH}" \
  MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
  AUTO_MERGE="${AUTO_MERGE}" \
  COMMIT_SHA="${COMMIT_SHA}" \
  bash "${SCRIPT_DIR}/create_mr.sh"
MERGE_REQUEST_URL="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '1p')"
MR_ACTION="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '2p')"
MERGE_REQUEST_IID="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '3p')"
MR_OUTCOME="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '4p')"

MR_STDOUT_IDENTITY_VALID=false
case "${MR_ACTION}" in
  created|rotated)
    if [[ "${MERGE_REQUEST_IID}" =~ ^[1-9][0-9]*$ ]]; then
      case "${MERGE_REQUEST_URL}" in
        http://*|https://*) MR_STDOUT_IDENTITY_VALID=true ;;
      esac
    fi
    ;;
esac

# create_mr.sh writes this marker before attempting the optional merge.  It is
# a recovery artifact, not part of the strict compact worker-result schema.
# Require exact attempt/issue/branch/SHA identity before trusting it; in
# particular, only a verified merged marker can authorize `finish`.
MR_RESULT_FILE="${LOG_DIR}/mr_result.json"
MR_MARKER=""
if [ -f "${MR_RESULT_FILE}" ] && [ ! -L "${MR_RESULT_FILE}" ]; then
  MR_MARKER="$(jq -ce \
    --argjson issue_iid "${ISSUE_IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg sha "${COMMIT_SHA}" \
    --argjson auto_merge "${AUTO_MERGE}" '
      if type == "object"
        and .version == 1
        and .issue_iid == $issue_iid
        and .attempt_number == $attempt_number
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
        and .auto_merge == $auto_merge
        and (.iid | type == "number" and . == floor and . > 0)
        and (.web_url | type == "string" and test("^https?://"))
        and (.mr_action == "created" or .mr_action == "rotated")
        and (.outcome == "merged" or .outcome == "opened" or .outcome == "unknown")
        and (.verified | type == "boolean")
        and (.observed_state | type == "string")
        and (.merge_attempted | type == "boolean")
        and (.merge_api_succeeded | type == "boolean")
        and (.reason | type == "string")
      then . else error("invalid MR result marker") end
    ' "${MR_RESULT_FILE}" 2>/dev/null || true)"
fi

if [ -n "${MR_MARKER}" ]; then
  MARKER_URL="$(jq -r '.web_url' <<<"${MR_MARKER}")"
  MARKER_ACTION="$(jq -r '.mr_action' <<<"${MR_MARKER}")"
  MARKER_IID="$(jq -r '.iid' <<<"${MR_MARKER}")"
  if [ "${MR_STDOUT_IDENTITY_VALID}" = true ] \
      && { [ "${MERGE_REQUEST_URL}" != "${MARKER_URL}" ] \
        || [ "${MR_ACTION}" != "${MARKER_ACTION}" ] \
        || [ "${MERGE_REQUEST_IID}" != "${MARKER_IID}" ]; }; then
    BLOCK_REASON="MR creation failed: stdout identity does not match durable marker"
    MERGE_REQUEST_URL=""
    MERGE_REQUEST_IID=""
    MR_ACTION=none
    finish_blocked
  fi
  MERGE_REQUEST_URL="${MARKER_URL}"
  MR_ACTION="${MARKER_ACTION}"
  MERGE_REQUEST_IID="${MARKER_IID}"
  MR_OUTCOME="$(jq -r '.outcome' <<<"${MR_MARKER}")"
elif [ "${MR_STDOUT_IDENTITY_VALID}" != true ]; then
  BLOCK_REASON="MR creation failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}; no recoverable MR identity")"
  MERGE_REQUEST_URL=""
  MERGE_REQUEST_IID=""
  MR_ACTION=none
  finish_blocked
else
  # The MR identity is recoverable from stdout, but without the exact marker
  # no observed state can authorize finish.
  MR_OUTCOME=unknown
fi

DESIRED_COMPLETION_LABEL=pr
if [ "${AUTO_MERGE}" = true ] \
    && [ -n "${MR_MARKER}" ] \
    && jq -e '.verified == true and .outcome == "merged" and .observed_state == "merged"' \
      <<<"${MR_MARKER}" >/dev/null; then
  DESIRED_COMPLETION_LABEL=finish
fi

# The compact result intentionally stays success-shaped once the code, push,
# and MR creation completed so Phase 6 can independently reconcile the exact
# MR.  An automatic merge that is not yet verified, however, must not publish a
# premature `Status: done` Issue comment before that independent check.
if [ "${AUTO_MERGE}" = true ] \
    && [ "${DESIRED_COMPLETION_LABEL}" != finish ]; then
  SUPPRESS_SUCCESS_SUMMARY=true
fi

FINAL_STATUS=done
if ! sync_label add "${DESIRED_COMPLETION_LABEL}"; then
  # The MR already has a durable identity.  Do not turn an unavailable final
  # label write—or a verified merge—into blocked-cc.  The done worker result
  # keeps the existing strict schema and lets Phase 6 re-read the same exact MR
  # with merge_mr.sh verify mode before retrying the terminal label.
  BLOCK_REASON="add ${DESIRED_COMPLETION_LABEL} label failed after MR finalization: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  run_summary
  persist_and_print_result
  exit 0
fi
LABELS_ADDED="$(remove_json_string "${LABELS_ADDED}" done)"
LABELS_REMOVED="$(append_json_string "${LABELS_REMOVED}" done)"

BLOCK_REASON=""
run_summary
persist_and_print_result
