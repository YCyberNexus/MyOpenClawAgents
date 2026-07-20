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
: "${ISSUE_MODE:?run_executor_attempt.sh: ISSUE_MODE must be set}"
: "${BRANCH:?run_executor_attempt.sh: BRANCH must be set}"

if ! command -v jq >/dev/null 2>&1; then
  echo "run_executor_attempt.sh: jq is required" >&2
  exit 2
fi

CALLER_AUTO_MERGE="${AUTO_MERGE:-false}"
CALLER_MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH}}"
CALLER_DEPENDENCY_IID="${DEPENDENCY_IID:-}"
CALLER_DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH:-}"
CALLER_DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA:-}"
CALLER_WORK_BRANCH="${WORK_BRANCH:-}"
CALLER_EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA:-}"
CALLER_EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA:-}"

attempt_state_file_mode() {
  local path="$1"
  if stat -f '%Lp' "${path}" 2>/dev/null; then
    :
  else
    stat -c '%a' "${path}" 2>/dev/null
  fi
}

attempt_state_file_owner() {
  local path="$1"
  if stat -f '%u' "${path}" 2>/dev/null; then
    :
  else
    stat -c '%u' "${path}" 2>/dev/null
  fi
}

# The outer model only copies the deterministic wrapper invocation. It is not
# an authority for merge intent or dependency identity. Load those values from
# the private state written before worktree preparation, and reject omission or
# substitution rather than silently defaulting to a non-dependent run.
: "${ATTEMPT_STATE_FILE:?run_executor_attempt.sh: ATTEMPT_STATE_FILE must be set}"
if [ ! -f "${ATTEMPT_STATE_FILE}" ] || [ -L "${ATTEMPT_STATE_FILE}" ]; then
  echo "run_executor_attempt.sh: fixed attempt identity is missing or not a regular file" >&2
  exit 2
fi
ATTEMPT_STATE_MODE="$(attempt_state_file_mode "${ATTEMPT_STATE_FILE}")" || true
ATTEMPT_STATE_OWNER="$(attempt_state_file_owner "${ATTEMPT_STATE_FILE}")" || true
ATTEMPT_STATE_BYTES="$(wc -c <"${ATTEMPT_STATE_FILE}" 2>/dev/null | tr -d '[:space:]')"
if [ "${ATTEMPT_STATE_MODE}" != 600 ] \
    || [ "${ATTEMPT_STATE_OWNER}" != "$(id -u)" ] \
    || ! [[ "${ATTEMPT_STATE_BYTES}" =~ ^[1-9][0-9]*$ ]] \
    || [ "${ATTEMPT_STATE_BYTES}" -gt 65536 ]; then
  echo "run_executor_attempt.sh: fixed attempt identity has unsafe metadata" >&2
  exit 2
fi

if ! TRUSTED_ATTEMPT_IDENTITY="$(jq -ce \
    --argjson iid "${ISSUE_IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" '
    def absent_or_empty: . == null or . == "";
    if type == "object"
        and (has("work_branch") | not)
        and (.dependency_iid? | absent_or_empty)
        and (.dependency_branch? | absent_or_empty)
        and (.dependency_base_sha? | absent_or_empty) then
      . + {
        work_branch:("issue/" + ($iid | tostring)),
        branch_members:[$iid],
        shared_branch_role:null,
        expected_work_branch_sha:null,
        expected_commit_parent_sha:null
      }
    else . end
    |
    if type == "object"
      and .iid == $iid
      and .attempt_number == $attempt_number
      and (.issue_title | type == "string" and length > 0 and length <= 1024)
      and (.mode_actual == "fresh" or .mode_actual == "continue")
      and (.auto_merge | type == "boolean")
      and (.merge_target_branch | type == "string" and length > 0)
      and (.work_branch | type == "string")
      and (.branch_members | type == "array")
      and (
        (.work_branch == ("issue/" + ($iid | tostring))
          and .branch_members == [$iid]
          and (.shared_branch_role // null) == null)
        or
        ((.branch_members | length) == 2
          and all(.branch_members[];
            type == "number" and . == floor and . > 0)
          and .branch_members[0] != .branch_members[1]
          and (.branch_members | index($iid) != null)
          and .work_branch == ("issue/" + (.branch_members[0] | tostring)
            + "+" + (.branch_members[1] | tostring))
          and .shared_branch_role ==
            (if $iid == .branch_members[0] then "head" else "tail" end)
          and .auto_merge == false)
      )
      and (((.expected_work_branch_sha // null) == null)
        or (.expected_work_branch_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")))
      and (((.expected_commit_parent_sha // null) == null)
        or (.expected_commit_parent_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")))
      and (if (.branch_members | length) == 2 then
        if .shared_branch_role == "head" then
          (.dependency_iid // null) == null
          and (.dependency_branch // null) == null
          and (.dependency_base_sha // null) == null
        else
          .shared_branch_role == "tail"
          and (.dependency_iid | type == "number" and . == floor and . > 0)
          and .dependency_iid == .branch_members[0]
          and .dependency_branch == .work_branch
          and (.dependency_base_sha | type == "string"
            and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        end
      else
        ((.dependency_iid // null) == null
          and (.dependency_branch // null) == null
          and (.dependency_base_sha // null) == null)
        or ((.dependency_iid | type == "number" and . == floor and . > 0)
          and .dependency_branch == ("issue/" + (.dependency_iid | tostring))
          and (.dependency_base_sha | type == "string"
            and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")))
      end)
      and (if (.branch_members | length) == 2 then
        (.expected_commit_parent_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and if .shared_branch_role == "head" then
          .mode_actual == "fresh"
          and (.expected_work_branch_sha // null) == null
        else
          (.expected_work_branch_sha | type == "string")
          and ((.expected_commit_parent_sha | ascii_downcase)
            == (.dependency_base_sha | ascii_downcase))
          and (if .mode_actual == "fresh" then
            ((.expected_work_branch_sha | ascii_downcase)
              == (.dependency_base_sha | ascii_downcase))
          else true end)
        end
      else (.expected_commit_parent_sha // null) == null end)
    then {
      mode_actual:.mode_actual,
      issue_title:.issue_title,
      auto_merge:.auto_merge,
      merge_target_branch:.merge_target_branch,
      work_branch:.work_branch,
      branch_members:.branch_members,
      shared_branch_role:(.shared_branch_role // null),
      expected_work_branch_sha:(.expected_work_branch_sha // null),
      expected_commit_parent_sha:(.expected_commit_parent_sha // null),
      dependency_iid:(.dependency_iid // null),
      dependency_branch:(.dependency_branch // null),
      dependency_base_sha:(.dependency_base_sha // null)
    }
    else error("invalid fixed attempt identity") end
  ' "${ATTEMPT_STATE_FILE}" 2>/dev/null)"; then
  echo "run_executor_attempt.sh: fixed attempt identity is invalid" >&2
  exit 2
fi

AUTO_MERGE="$(jq -r '.auto_merge' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
ISSUE_TITLE="$(jq -r '.issue_title' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
MERGE_TARGET_BRANCH="$(jq -r '.merge_target_branch' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
DEPENDENCY_IID="$(jq -r '.dependency_iid // ""' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
DEPENDENCY_BRANCH="$(jq -r '.dependency_branch // ""' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
DEPENDENCY_BASE_SHA="$(jq -r '.dependency_base_sha // ""' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
WORK_BRANCH="$(jq -r '.work_branch' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
BRANCH_MEMBERS_JSON="$(jq -c '.branch_members' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
SHARED_BRANCH_ROLE="$(jq -r '.shared_branch_role // ""' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
EXPECTED_WORK_BRANCH_SHA="$(jq -r '.expected_work_branch_sha // ""' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
EXPECTED_COMMIT_PARENT_SHA="$(jq -r '.expected_commit_parent_sha // ""' <<<"${TRUSTED_ATTEMPT_IDENTITY}")"
if [ "${ISSUE_MODE}" != "$(jq -r '.mode_actual' <<<"${TRUSTED_ATTEMPT_IDENTITY}")" ] \
    || [ "${CALLER_AUTO_MERGE}" != "${AUTO_MERGE}" ] \
    || [ "${CALLER_MERGE_TARGET_BRANCH}" != "${MERGE_TARGET_BRANCH}" ] \
    || [ "${CALLER_DEPENDENCY_IID}" != "${DEPENDENCY_IID}" ] \
    || [ "${CALLER_DEPENDENCY_BRANCH}" != "${DEPENDENCY_BRANCH}" ] \
    || [ "${CALLER_DEPENDENCY_BASE_SHA}" != "${DEPENDENCY_BASE_SHA}" ] \
    || [ "${CALLER_WORK_BRANCH}" != "${WORK_BRANCH}" ] \
    || [ "${CALLER_EXPECTED_WORK_BRANCH_SHA}" != "${EXPECTED_WORK_BRANCH_SHA}" ] \
    || [ "${CALLER_EXPECTED_COMMIT_PARENT_SHA}" != "${EXPECTED_COMMIT_PARENT_SHA}" ]; then
  echo "run_executor_attempt.sh: caller inputs do not match the fixed attempt identity" >&2
  exit 2
fi

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
if [ -n "${DEPENDENCY_IID}${DEPENDENCY_BRANCH}${DEPENDENCY_BASE_SHA}" ]; then
  if ! [[ "${DEPENDENCY_IID}" =~ ^[1-9][0-9]*$ ]] \
      || ! [[ "${DEPENDENCY_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
    echo "run_executor_attempt.sh: dependency identity must be a complete IID/branch/full-SHA tuple" >&2
    exit 2
  fi
  if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ]; then
    if [ "${SHARED_BRANCH_ROLE}" != tail ] \
        || [ "${DEPENDENCY_IID}" != "$(jq -r '.[0]' <<<"${BRANCH_MEMBERS_JSON}")" ] \
        || [ "${DEPENDENCY_BRANCH}" != "${WORK_BRANCH}" ]; then
      echo "run_executor_attempt.sh: shared dependency identity does not match the fixed work branch" >&2
      exit 2
    fi
  elif [ "${DEPENDENCY_BRANCH}" != "issue/${DEPENDENCY_IID}" ]; then
    echo "run_executor_attempt.sh: dependency branch does not match its IID" >&2
    exit 2
  fi
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
mkdir -p "${LOG_DIR}"

FINAL_STATUS=""
BLOCK_REASON=""
COMMIT_SHA=""
MERGE_REQUEST_URL=""
MERGE_REQUEST_IID=""
MR_ACTION="none"
SHARED_MR_INTENT_ID=""
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

# Promote dependency history only after the frozen WORK_BRANCH is observably
# the exact pushed commit. Preparation and local checkout are proposals: they
# never replace the tuple bound to the last remotely recoverable branch.
persist_pushed_branch_identity() {
  local canonical_commit remote_commit prior_state state_tmp now
  canonical_commit="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" rev-parse --verify \
    "${COMMIT_SHA}^{commit}" 2>/dev/null)" || return 1
  remote_commit="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" rev-parse --verify \
    "refs/remotes/origin/${WORK_BRANCH}^{commit}" 2>/dev/null)" || return 1
  if [ "${canonical_commit,,}" != "${remote_commit,,}" ]; then
    return 1
  fi
  if [ -n "${DEPENDENCY_BASE_SHA}" ] \
      && ! GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
        merge-base --is-ancestor \
        "${DEPENDENCY_BASE_SHA}" "${remote_commit}" >/dev/null 2>&1; then
    return 1
  fi
  if [ -L "${ISSUE_STATE_FILE}" ]; then
    return 1
  fi
  prior_state='{}'
  if [ -f "${ISSUE_STATE_FILE}" ]; then
    prior_state="$(jq -ce \
      'if type == "object" then . else error("invalid issue state") end' \
      "${ISSUE_STATE_FILE}" 2>/dev/null)" || return 1
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_tmp="${ISSUE_STATE_FILE}.tmp.$$"
  if ! (umask 077; printf '%s' "${prior_state}" | jq \
      --argjson iid "${ISSUE_IID}" \
      --argjson attempt_number "${ATTEMPT_NUMBER}" \
      --arg work_branch "${WORK_BRANCH}" \
      --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
      --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
      --arg dependency_iid "${DEPENDENCY_IID}" \
      --arg dependency_branch "${DEPENDENCY_BRANCH}" \
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
      --arg work_branch_sha "${remote_commit}" \
      --arg updated_at "${now}" '
      . + {
        iid:$iid,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:(if $shared_branch_role == "" then null else $shared_branch_role end),
        dependency_iid:(if $dependency_iid == "" then null else ($dependency_iid | tonumber) end),
        dependency_branch:(if $dependency_branch == "" then null else $dependency_branch end),
        dependency_base_sha:(if $dependency_base_sha == "" then null else $dependency_base_sha end),
        dependency_pinned_attempt_number:$attempt_number,
        work_branch_sha:$work_branch_sha,
        dependency_history_verified:true,
        dependency_history_updated_at:$updated_at
      }
      | del(.proposed_config_branch,
            .proposed_work_branch,
            .proposed_branch_members,
            .proposed_shared_branch_role,
            .proposed_expected_work_branch_sha,
            .proposed_expected_commit_parent_sha,
            .proposed_dependency_iid,
            .proposed_dependency_branch,
            .proposed_dependency_base_sha,
            .preparing_attempt_number)
    ' >"${state_tmp}"); then
    return 1
  fi
  chmod 600 "${state_tmp}" || return 1
  mv "${state_tmp}" "${ISSUE_STATE_FILE}"
}

# A shared branch has one cross-Issue MR identity. After the main execution
# path has pushed and verified the exact remote commit, invalidate any stale
# finalization and bind the MR work that is about to start to this fixed
# attempt. Partial-work salvage never calls this function: it may preserve a
# pushed commit, but it is not authorized to start or checkpoint MR creation.
persist_shared_mr_pending_checkpoint() {
  [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] || return 0

  local prior_state state_tmp intent_id="" head_state_file="" state_bytes
  if [ ! -f "${ISSUE_STATE_FILE}" ] || [ -L "${ISSUE_STATE_FILE}" ] \
      || [ "$(attempt_state_file_mode "${ISSUE_STATE_FILE}" 2>/dev/null || true)" != 600 ] \
      || [ "$(attempt_state_file_owner "${ISSUE_STATE_FILE}" 2>/dev/null || true)" != "$(id -u)" ]; then
    return 1
  fi
  state_bytes="$(wc -c <"${ISSUE_STATE_FILE}" 2>/dev/null \
    | tr -d '[:space:]')"
  [[ "${state_bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${state_bytes}" -le 65536 ] || return 1
  prior_state="$(jq -ce \
    --argjson iid "${ISSUE_IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg work_branch "${WORK_BRANCH}" \
    --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
    --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
    --arg commit_sha "${COMMIT_SHA}" '
      if type == "object"
        and .iid == $iid
        and .work_branch == $work_branch
        and .branch_members == $branch_members
        and .shared_branch_role == $shared_branch_role
        and .dependency_pinned_attempt_number == $attempt_number
        and .dependency_history_verified == true
        and ((.work_branch_sha | ascii_downcase)
          == ($commit_sha | ascii_downcase))
      then . else error("pushed shared identity mismatch") end
    ' "${ISSUE_STATE_FILE}" 2>/dev/null)" || return 1

  # Reuse an exact same-attempt intent after a process restart. Otherwise A
  # creates a fresh high-entropy ownership marker; C inherits A's verified
  # marker so both commits bind the same one MR.
  intent_id="$(jq -r \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg work_branch "${WORK_BRANCH}" \
    --arg commit_sha "${COMMIT_SHA}" '
    .mr_finalization // null
    | select(type == "object"
      and .status == "pending"
      and .source_attempt_number == $attempt_number
      and .work_branch == $work_branch
      and ((.commit_sha | ascii_downcase) == ($commit_sha | ascii_downcase))
      and (.intent_id | type == "string" and test("^[0-9a-f]{64}$")))
    | .intent_id
  ' <<<"${prior_state}" 2>/dev/null || true)"
  if [ -z "${intent_id}" ] && [ "${SHARED_BRANCH_ROLE}" = tail ]; then
    head_state_file="${ISSUES_ROOT}/issue-${DEPENDENCY_IID}/state.json"
    if [ ! -f "${head_state_file}" ] || [ -L "${head_state_file}" ] \
        || [ "$(attempt_state_file_mode "${head_state_file}" 2>/dev/null || true)" != 600 ] \
        || [ "$(attempt_state_file_owner "${head_state_file}" 2>/dev/null || true)" != "$(id -u)" ]; then
      return 1
    fi
    state_bytes="$(wc -c <"${head_state_file}" 2>/dev/null \
      | tr -d '[:space:]')"
    [[ "${state_bytes}" =~ ^[1-9][0-9]*$ ]] \
      && [ "${state_bytes}" -le 65536 ] || return 1
    intent_id="$(jq -er \
      --argjson head_iid "${DEPENDENCY_IID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --arg dependency_sha "${DEPENDENCY_BASE_SHA}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      if .iid == $head_iid
        and .status == "done"
        and .work_branch == $work_branch
        and .shared_branch_role == "head"
        and ((.commit_sha | ascii_downcase) == ($dependency_sha | ascii_downcase))
        and (.mr_finalization | type == "object")
        and .mr_finalization.status == "verified_open"
        and .mr_finalization.work_branch == $work_branch
        and .mr_finalization.shared_branch_role == "head"
        and ((.mr_finalization.commit_sha | ascii_downcase)
          == ($dependency_sha | ascii_downcase))
        and .mr_finalization.target_branch == $target_branch
        and (.mr_finalization.intent_id | type == "string"
          and test("^[0-9a-f]{64}$"))
      then .mr_finalization.intent_id else empty end
    ' "${head_state_file}" 2>/dev/null)" || return 1
  elif [ -z "${intent_id}" ]; then
    command -v od >/dev/null 2>&1 || return 1
    intent_id="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null \
      | tr -d '[:space:]')" || return 1
  fi
  [[ "${intent_id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  SHARED_MR_INTENT_ID="${intent_id}"

  state_tmp="${ISSUE_STATE_FILE}.tmp.$$"
  if ! (umask 077; printf '%s' "${prior_state}" | jq \
      --argjson attempt_number "${ATTEMPT_NUMBER}" \
      --arg work_branch "${WORK_BRANCH}" \
      --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
      --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
      --arg commit_sha "${COMMIT_SHA}" \
      --arg intent_id "${intent_id}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      .mr_finalization = {
        status:"pending",
        source_attempt_number:$attempt_number,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:$shared_branch_role,
        commit_sha:$commit_sha,
        intent_id:$intent_id,
        target_branch:$target_branch
      }
    ' >"${state_tmp}"); then
    return 1
  fi
  chmod 600 "${state_tmp}" || return 1
  mv "${state_tmp}" "${ISSUE_STATE_FILE}"
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
    EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA}" \
    EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA}" \
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

# The bounded commit helper can be killed after the server accepted its push
# but before it printed the SHA. For a shared branch, recover only when the
# current local HEAD is a new one-parent commit on the frozen parent and a fresh
# fetch proves the exact remote-tracking ref equals that HEAD.
recover_ambiguous_shared_push() {
  [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] || return 1
  local candidate_sha parents_line remote_sha
  local -a candidate_parents
  candidate_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  [[ "${candidate_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
    || return 1
  [ "${candidate_sha,,}" != "${EXPECTED_COMMIT_PARENT_SHA,,}" ] || return 1
  parents_line="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-list --parents -n 1 "${candidate_sha}" 2>/dev/null)" || return 1
  read -r -a candidate_parents <<<"${parents_line}"
  [ "${#candidate_parents[@]}" -eq 2 ] \
    && [ "${candidate_parents[0],,}" = "${candidate_sha,,}" ] \
    && [ "${candidate_parents[1],,}" = "${EXPECTED_COMMIT_PARENT_SHA,,}" ] \
    || return 1

  run_bounded_step post-push-ambiguity-verify 180 env \
    BRANCH="${MERGE_TARGET_BRANCH}" \
    bash "${SCRIPT_DIR}/post_push_verify.sh"
  [ "${STEP_RC}" -eq 0 ] || return 1
  remote_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-parse --verify "refs/remotes/origin/${WORK_BRANCH}^{commit}" \
    2>/dev/null)" || return 1
  [ "${remote_sha,,}" = "${candidate_sha,,}" ] || return 1
  COMMIT_SHA="${candidate_sha}"
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
  if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
      && stage_partial_work && commit_partial_work; then
    if verify_partial_work; then
      persist_pushed_branch_identity \
        || append_reason "pushed branch dependency identity could not be persisted"
    fi
  fi
  finish_timeout
fi

case "${ACPX_EXIT}" in
  0) ;;
  124|137)
    BLOCK_REASON="acpx exec exceeded ${ACPX_TIMEOUT_SECONDS}s wall-clock cap"
    if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
        && stage_partial_work && commit_partial_work; then
      if verify_partial_work; then
        persist_pushed_branch_identity \
          || append_reason "pushed branch dependency identity could not be persisted"
      fi
    fi
    finish_timeout
    ;;
  *)
    BLOCK_REASON="acpx run failed (exit ${ACPX_EXIT}); see ${LOG_DIR}/acpx_raw.log"
    if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
        && stage_partial_work && commit_partial_work; then
      if verify_partial_work; then
        persist_pushed_branch_identity \
          || append_reason "pushed branch dependency identity could not be persisted"
      fi
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
  EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA}" \
  bash "${SCRIPT_DIR}/commit_and_push.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  COMMIT_PUSH_FAILURE="$(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  if recover_ambiguous_shared_push; then
    append_reason "commit_and_push returned an ambiguous failure, but the exact shared remote tip confirms the local commit"
  else
    BLOCK_REASON="git push failed: ${COMMIT_PUSH_FAILURE}"
    finish_blocked
  fi
fi
if [ -z "${COMMIT_SHA}" ]; then
  COMMIT_SHA="$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')"
fi
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
if ! persist_pushed_branch_identity; then
  BLOCK_REASON="post-push dependency identity verification or persistence failed"
  finish_blocked
fi
if ! persist_shared_mr_pending_checkpoint; then
  BLOCK_REASON="shared MR pending checkpoint persistence failed"
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

MR_FINALIZATION_TRY=1
MR_FINALIZATION_MAX_TRIES=1
[ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
  || MR_FINALIZATION_MAX_TRIES=3
while :; do
  MR_STEP_NAME=create-mr
  SHARED_MR_RECOVERY=false
  if [ "${MR_FINALIZATION_TRY}" -gt 1 ]; then
    MR_STEP_NAME="create-mr-retry${MR_FINALIZATION_TRY}"
    SHARED_MR_RECOVERY=true
  fi
  run_bounded_step "${MR_STEP_NAME}" 300 env \
    ISSUE_TITLE="${ISSUE_TITLE}" \
    ISSUE_MODE="${ISSUE_MODE}" \
    BRANCH="${BRANCH}" \
    MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
    AUTO_MERGE="${AUTO_MERGE}" \
    DEPENDENCY_IID="${DEPENDENCY_IID}" \
    DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH}" \
    DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA}" \
    COMMIT_SHA="${COMMIT_SHA}" \
    SHARED_MR_RECOVERY="${SHARED_MR_RECOVERY}" \
    bash "${SCRIPT_DIR}/create_mr.sh"
  [ "${STEP_RC}" -ne 0 ] || break
  [ "${MR_FINALIZATION_TRY}" -lt "${MR_FINALIZATION_MAX_TRIES}" ] || break
  case "${STEP_RC}" in
    1|5|6|7|124|137) ;;
    *) break ;;
  esac
  MR_FINALIZATION_TRY=$((MR_FINALIZATION_TRY + 1))
done
MERGE_REQUEST_URL="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '1p')"
MR_ACTION="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '2p')"
MERGE_REQUEST_IID="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '3p')"
MR_OUTCOME="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '4p')"

MR_STDOUT_IDENTITY_VALID=false
case "${MR_ACTION}" in
  created|rotated|reused)
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
MR_RESULT_MODE="$(attempt_state_file_mode "${MR_RESULT_FILE}" 2>/dev/null || true)"
MR_RESULT_OWNER="$(attempt_state_file_owner "${MR_RESULT_FILE}" 2>/dev/null || true)"
MR_RESULT_BYTES="$(wc -c <"${MR_RESULT_FILE}" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -f "${MR_RESULT_FILE}" ] && [ ! -L "${MR_RESULT_FILE}" ] \
    && [ "${MR_RESULT_MODE}" = 600 ] \
    && [ "${MR_RESULT_OWNER}" = "$(id -u)" ] \
    && [[ "${MR_RESULT_BYTES}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${MR_RESULT_BYTES}" -le 65536 ]; then
  MR_MARKER="$(jq -ce \
    --argjson issue_iid "${ISSUE_IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg sha "${COMMIT_SHA}" \
    --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
    --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
    --arg shared_mr_intent_id "${SHARED_MR_INTENT_ID}" \
    --argjson auto_merge "${AUTO_MERGE}" '
      if type == "object"
        and .version == 1
        and .issue_iid == $issue_iid
        and .attempt_number == $attempt_number
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
        and ((.dependency_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
        and .auto_merge == $auto_merge
        and (.iid | type == "number" and . == floor and . > 0)
        and (.web_url | type == "string" and test("^https?://"))
        and (.mr_action == "created" or .mr_action == "rotated"
          or .mr_action == "reused")
        and (if $shared_branch_role == "head" then .mr_action == "created"
          elif $shared_branch_role == "tail" then .mr_action == "reused"
          else true end)
        and (if $shared_branch_role == "head" or $shared_branch_role == "tail"
          then .shared_mr_intent_id == $shared_mr_intent_id
            and (.shared_mr_intent_id | type == "string"
              and test("^[0-9a-f]{64}$"))
          else (has("shared_mr_intent_id") | not) end)
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

# Do not publish `pr` merely because a shared MR URL was observed. The exact
# opened marker is the release fence for C. If all bounded calls remain
# uncertain, persist the compact result without a completion-label mutation;
# Phase 6 retains this claim via the pending checkpoint and the heartbeat runs
# only MR finalization on a later tick.
if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] \
    && { [ -z "${MR_MARKER}" ] \
      || ! jq -e '
        .verified == true
        and .outcome == "opened"
        and .observed_state == "opened"
        and .merge_attempted == false
        and .merge_api_succeeded == false
      ' <<<"${MR_MARKER}" >/dev/null; }; then
  FINAL_STATUS=done
  SUPPRESS_SUCCESS_SUMMARY=true
  BLOCK_REASON=""
  run_summary
  persist_and_print_result
  exit 0
fi

# Shared completion labels are written only by claim-fenced Phase 6 after a
# fresh exact GitLab read. create_mr's marker is durable identity evidence, but
# the MR can still be closed, retargeted, or moved before callback processing.
if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ]; then
  FINAL_STATUS=done
  BLOCK_REASON=""
  run_summary
  persist_and_print_result
  exit 0
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
