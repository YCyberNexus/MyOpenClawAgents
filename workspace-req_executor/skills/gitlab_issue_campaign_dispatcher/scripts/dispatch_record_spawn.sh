#!/usr/bin/env bash
# dispatch_record_spawn.sh — record a sessions_spawn outcome for one IID.
#
# Called by the orchestrator LLM after each sessions_spawn attempt. Two
# modes, selected by the STATUS env var:
#
#   STATUS=spawned     — valid launch ack. Update pending_subagents[iid]
#                        with run_id, child_session_key, spawned_at; drop
#                        the placeholder flag.
#   STATUS=launch_failed — all 3 launch retries exhausted. Synthesize a
#                        blocked Phase 6 reply (via the shared library)
#                        with the verbatim last error, write terminal
#                        state files, drain pending entry, and classify
#                        as blocked WITHOUT incrementing retry_count
#                        (launch-side failures don't consume the cross-
#                        tick retry budget; the IID gets its reschedule
#                        for free via blocked_iids).
#
# Required env:
#   PROJECT, GROUP, GITLAB_TOKEN, IID, ATTEMPT_NUMBER, STATUS
#   When STATUS=spawned:        RUN_ID, CHILD_SESSION_KEY
#   When STATUS=launch_failed:  LAUNCH_ATTEMPTS (default 3), LAUNCH_ERROR
# Optional (forwarded when non-default deployment):
#   REPO_PARENT_PATH
# Optional driven identity (all-or-none; fixed batch wrapper only):
#   DRIVEN_JOB_ID, DRIVEN_CLAIM_GENERATION, DRIVEN_CLAIM_TOKEN
#
# Stdout: one-line JSON envelope describing the recorded outcome:
#   {"status":"spawned|launch_failed_recorded", "iid":N, "attempt_number":N,
#    "remaining_pending_count":N, "cleanup":{...} (only for launch_failed),
#    "chat_summary":"..."}
#
# Exit codes:
#   0 — recorded successfully (state mutated)
#   2 — invalid input (missing env, unknown STATUS, etc.)
#   3 — flock could not be acquired (caller should retry on next tick)
#
# Notes:
#   - This script does NOT itself call sessions_spawn. The LLM owns that.
#   - For STATUS=launch_failed, the cleanup decision will normally be
#     {action:"skip", reason:"no_child_session_key"} because the failed
#     launch never produced a usable child_session_key.

set -euo pipefail

: "${PROJECT:?dispatch_record_spawn.sh: PROJECT must be set}"
: "${GROUP:?dispatch_record_spawn.sh: GROUP must be set}"
: "${GITLAB_TOKEN:?dispatch_record_spawn.sh: GITLAB_TOKEN must be set}"
: "${IID:?dispatch_record_spawn.sh: IID must be set}"
: "${ATTEMPT_NUMBER:?dispatch_record_spawn.sh: ATTEMPT_NUMBER must be set}"
: "${STATUS:?dispatch_record_spawn.sh: STATUS must be set (spawned|launch_failed)}"

case "${IID}" in *[!0-9]*|"") echo "dispatch_record_spawn.sh: IID must be a positive integer" >&2; exit 2 ;; esac
case "${ATTEMPT_NUMBER}" in *[!0-9]*|"") echo "dispatch_record_spawn.sh: ATTEMPT_NUMBER must be a positive integer" >&2; exit 2 ;; esac

case "${STATUS}" in
  spawned)
    : "${RUN_ID:?dispatch_record_spawn.sh: RUN_ID required for STATUS=spawned}"
    : "${CHILD_SESSION_KEY:?dispatch_record_spawn.sh: CHILD_SESSION_KEY required for STATUS=spawned}"
    INCOMING_ACK_JSON="$(jq -cnS \
      --arg run_id "${RUN_ID}" \
      --arg child_session_key "${CHILD_SESSION_KEY}" \
      '{run_id:$run_id,child_session_key:$child_session_key}')"
    ;;
  launch_failed)
    : "${LAUNCH_ERROR:=unspecified}"
    : "${LAUNCH_ATTEMPTS:=3}"
    case "${LAUNCH_ATTEMPTS}" in
      *[!0-9]*|"") echo "dispatch_record_spawn.sh: LAUNCH_ATTEMPTS must be a positive integer" >&2; exit 2 ;;
      0) echo "dispatch_record_spawn.sh: LAUNCH_ATTEMPTS must be a positive integer" >&2; exit 2 ;;
    esac
    INCOMING_ACK_JSON="$(jq -cnS \
      --argjson launch_attempts "${LAUNCH_ATTEMPTS}" \
      --arg launch_error "${LAUNCH_ERROR}" \
      '{launch_attempts:$launch_attempts,launch_error:$launch_error}')"
    ;;
  *)
    echo "dispatch_record_spawn.sh: unknown STATUS=${STATUS} (want spawned|launch_failed)" >&2
    exit 2
    ;;
esac

DRIVEN_JOB_ID_INPUT="${DRIVEN_JOB_ID:-}"
DRIVEN_CLAIM_GENERATION_INPUT="${DRIVEN_CLAIM_GENERATION:-}"
DRIVEN_CLAIM_TOKEN_INPUT="${DRIVEN_CLAIM_TOKEN:-}"
DRIVEN_MODE=false
if [ -n "${DRIVEN_JOB_ID_INPUT}" ] \
    || [ -n "${DRIVEN_CLAIM_GENERATION_INPUT}" ] \
    || [ -n "${DRIVEN_CLAIM_TOKEN_INPUT}" ]; then
  DRIVEN_MODE=true
  [ -n "${DRIVEN_JOB_ID_INPUT}" ] \
    && [ -n "${DRIVEN_CLAIM_GENERATION_INPUT}" ] \
    && [ -n "${DRIVEN_CLAIM_TOKEN_INPUT}" ] || {
      echo "dispatch_record_spawn.sh: driven launch identity must be all-or-none" >&2
      exit 2
    }
  case "${DRIVEN_JOB_ID_INPUT}${DRIVEN_CLAIM_TOKEN_INPUT}" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "dispatch_record_spawn.sh: driven launch identity contains control characters" >&2
      exit 2
      ;;
  esac
  if ! [[ "${DRIVEN_CLAIM_GENERATION_INPUT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "dispatch_record_spawn.sh: DRIVEN_CLAIM_GENERATION must be a positive integer" >&2
    exit 2
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "dispatch_record_spawn.sh: no SHA-256 command is available" >&2
    return 2
  fi
}

DRIVEN_CLAIM_TOKEN_SHA256=""
if [ "${DRIVEN_MODE}" = true ]; then
  DRIVEN_CLAIM_TOKEN_SHA256="$(printf '%s' "${DRIVEN_CLAIM_TOKEN_INPUT}" | sha256_text)" \
    || exit 2
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc --argjson iid "${IID}" \
    '{status:"lock_held", iid:$iid, chat_summary:"lock_held while recording spawn (retry on next callback or next tick)"}'
  exit 3
fi

STATE_JSON="$(load_state)"
PENDING="$(printf '%s' "${STATE_JSON}" | jq -c --argjson iid "${IID}" '.pending_subagents[($iid|tostring)] // null')"
DRIVEN_RECEIPT=null
if [ "${DRIVEN_MODE}" = true ]; then
  DRIVEN_RECEIPT="$(jq -c --arg job_id "${DRIVEN_JOB_ID_INPUT}" \
    '.driven_launch_receipts[$job_id] // null' <<<"${STATE_JSON}")"
  if [ "${DRIVEN_RECEIPT}" != null ]; then
    DRIVEN_RECEIPT="$(jq -ce '
      def clean_string:
        type == "string" and length > 0
        and (explode | all(. >= 32 and . != 127));
      def valid_cleanup($final_status):
        type == "object"
        and (
          ((keys | sort) == ["action","reason","target"]
            and .action == "skip"
            and .target == ""
            and .reason == "no_child_session_key")
          or ((keys | sort) == ["action","reason","status","target"]
            and .action == "skip"
            and (.target | clean_string)
            and .reason == "preserve_terminal_evidence"
            and .status == $final_status)
        );
      if type == "object"
        and (keys | sort) == [
          "ack","attempt_number","claim_generation","claim_token_sha256",
          "iid","job_id","outcome","recorded_at","result","version"
        ]
        and .version == 1
        and (.job_id | clean_string)
        and (.claim_generation | type == "number" and . == floor and . > 0)
        and (.claim_token_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.iid | type == "number" and . == floor and . > 0)
        and (.attempt_number | type == "number" and . == floor and . > 0)
        and (.recorded_at | clean_string)
        and (
          (.outcome == "spawned"
            and (.ack | keys | sort) == ["child_session_key","run_id"]
            and (.ack.run_id | clean_string)
            and (.ack.child_session_key | clean_string)
            and (.result | type == "object")
            and (.result | keys | sort) == [
              "attempt_number","chat_summary","iid",
              "remaining_pending_count","status"
            ]
            and .result.status == "spawned")
          or (.outcome == "launch_failed"
            and (.ack | keys | sort) == ["launch_attempts","launch_error"]
            and (.ack.launch_attempts | type == "number" and . == floor and . > 0)
            and (.ack.launch_error | clean_string)
            and (.result | type == "object")
            and (.result | keys | sort) == [
              "attempt_number","chat_summary","cleanup","final_status","iid",
              "remaining_pending_count","status"
            ]
            and .result.status == "launch_failed_recorded"
            and .result.final_status == "blocked"
            and (.result as $result
              | ($result.cleanup | valid_cleanup($result.final_status))))
        )
        and .result.iid == .iid
        and .result.attempt_number == .attempt_number
        and (.result.remaining_pending_count | type == "number"
          and . == floor and . >= 0)
        and (.result.chat_summary | clean_string)
      then . else error("invalid driven launch receipt") end
    ' <<<"${DRIVEN_RECEIPT}" 2>/dev/null)" || {
      echo "dispatch_record_spawn.sh: existing driven launch receipt is invalid" >&2
      exit 2
    }
  fi

  if [ "${PENDING}" != null ]; then
    if ! jq -e \
        --arg job_id "${DRIVEN_JOB_ID_INPUT}" \
        --argjson generation "${DRIVEN_CLAIM_GENERATION_INPUT}" \
        --arg token "${DRIVEN_CLAIM_TOKEN_INPUT}" \
        --argjson attempt "${ATTEMPT_NUMBER}" '
        .job_id == $job_id
        and .claim_generation == $generation
        and .claim_token == $token
        and .attempt_number == $attempt
      ' <<<"${PENDING}" >/dev/null; then
      echo "dispatch_record_spawn.sh: driven launch identity does not match current pending entry" >&2
      exit 2
    fi
  elif [ "${DRIVEN_RECEIPT}" = null ]; then
    echo "dispatch_record_spawn.sh: no pending entry or driven receipt for iid=${IID}" >&2
    exit 2
  fi

  if [ "${DRIVEN_RECEIPT}" != null ]; then
    RECEIPT_IDENTITY_MATCH=false
    if jq -e \
        --arg job_id "${DRIVEN_JOB_ID_INPUT}" \
        --argjson generation "${DRIVEN_CLAIM_GENERATION_INPUT}" \
        --arg token_sha256 "${DRIVEN_CLAIM_TOKEN_SHA256}" \
        --argjson iid "${IID}" \
        --argjson attempt "${ATTEMPT_NUMBER}" '
        .job_id == $job_id
        and .claim_generation == $generation
        and .claim_token_sha256 == $token_sha256
        and .iid == $iid
        and .attempt_number == $attempt
      ' <<<"${DRIVEN_RECEIPT}" >/dev/null; then
      RECEIPT_IDENTITY_MATCH=true
    fi
    if [ "${RECEIPT_IDENTITY_MATCH}" = true ]; then
      if ! jq -e \
          --arg outcome "${STATUS}" \
          --argjson ack "${INCOMING_ACK_JSON}" '
          .outcome == $outcome and .ack == $ack
        ' <<<"${DRIVEN_RECEIPT}" >/dev/null; then
        echo "dispatch_record_spawn.sh: driven launch outcome conflicts with durable receipt" >&2
        exit 2
      fi
      jq -c '.result' <<<"${DRIVEN_RECEIPT}"
      exit 0
    elif [ "${PENDING}" = null ]; then
      echo "dispatch_record_spawn.sh: driven launch identity conflicts with durable receipt" >&2
      exit 2
    fi
  fi
else
  if [ "${PENDING}" = "null" ]; then
    echo "dispatch_record_spawn.sh: no pending entry for iid=${IID} — refusing to record" >&2
    exit 2
  fi
  PENDING_ATTEMPT="$(printf '%s' "${PENDING}" | jq -r '.attempt_number')"
  if [ "${PENDING_ATTEMPT}" != "${ATTEMPT_NUMBER}" ]; then
    echo "dispatch_record_spawn.sh: attempt_number mismatch (pending=${PENDING_ATTEMPT} caller=${ATTEMPT_NUMBER})" >&2
    exit 2
  fi
fi

build_driven_receipt() {
  local result_json="$1" recorded_at="$2"
  jq -cnS \
    --arg job_id "${DRIVEN_JOB_ID_INPUT}" \
    --argjson claim_generation "${DRIVEN_CLAIM_GENERATION_INPUT}" \
    --arg claim_token_sha256 "${DRIVEN_CLAIM_TOKEN_SHA256}" \
    --argjson iid "${IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg outcome "${STATUS}" \
    --argjson ack "${INCOMING_ACK_JSON}" \
    --arg recorded_at "${recorded_at}" \
    --argjson result "${result_json}" '{
      version:1,
      job_id:$job_id,
      claim_generation:$claim_generation,
      claim_token_sha256:$claim_token_sha256,
      iid:$iid,
      attempt_number:$attempt_number,
      outcome:$outcome,
      ack:$ack,
      recorded_at:$recorded_at,
      result:$result
    }'
}

install_driven_receipt() {
  local state_json="$1" result_json="$2" recorded_at="$3" receipt_json
  if [ "${DRIVEN_MODE}" != true ]; then
    printf '%s' "${state_json}"
    return 0
  fi
  receipt_json="$(build_driven_receipt "${result_json}" "${recorded_at}")"
  jq -c \
    --arg job_id "${DRIVEN_JOB_ID_INPUT}" \
    --argjson receipt "${receipt_json}" '
    .driven_launch_receipts = (.driven_launch_receipts // {})
    | .driven_launch_receipts[$job_id] = $receipt
  ' <<<"${state_json}"
}

case "${STATUS}" in
  spawned)
    NOW="$(utc_now)"
    NEW_STATE="$(printf '%s' "${STATE_JSON}" | jq -c \
      --argjson iid "${IID}" \
      --arg run_id "${RUN_ID}" \
      --arg child_session_key "${CHILD_SESSION_KEY}" \
      --arg now "${NOW}" '
      .pending_subagents[($iid|tostring)] = (
        .pending_subagents[($iid|tostring)]
        + {run_id:$run_id, child_session_key:$child_session_key, spawned_at:$now}
        | del(.placeholder)
      )
      | .quota_launched_this_tick = ((.quota_launched_this_tick // 0) + 1)
      | .campaign_status = "waiting_for_callbacks"
    ')"
    REMAINING="$(printf '%s' "${NEW_STATE}" | jq -r '.pending_subagents | keys | length')"
    RESULT_JSON="$(jq -cn \
      --argjson iid "${IID}" \
      --argjson att "${ATTEMPT_NUMBER}" \
      --argjson remaining "${REMAINING}" \
      --arg chat "spawned #${IID} att=${ATTEMPT_NUMBER}" '
      {status:"spawned", iid:$iid, attempt_number:$att,
       remaining_pending_count:$remaining, chat_summary:$chat}')"
    NEW_STATE="$(install_driven_receipt "${NEW_STATE}" "${RESULT_JSON}" "${NOW}")"
    persist_state "${NEW_STATE}"

    wrapper_log record_spawn "spawned iid=${IID} attempt=${ATTEMPT_NUMBER} run_id=${RUN_ID}"
    printf '%s\n' "${RESULT_JSON}"
    ;;
  launch_failed)
    BLOCK_REASON="sessions_spawn failed after ${LAUNCH_ATTEMPTS} attempts (2s backoff): ${LAUNCH_ERROR}"
    REPLY_JSON="$(phase6_synthesize_blocked "${IID}" "${ATTEMPT_NUMBER}" "${BLOCK_REASON}")"
    # Run Phase 6 with is_launch_synth=true so retry_count is NOT incremented.
    PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "true")"
    NEW_STATE="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"

    FINAL_STATUS="$(printf '%s' "${PHASE6_OUT}" | jq -r '.final_status')"
    CLEANUP="$(printf '%s' "${PHASE6_OUT}" | jq -c '.cleanup')"
    REMAINING="$(printf '%s' "${PHASE6_OUT}" | jq -r '.remaining_pending_count')"
    NOW="$(utc_now)"
    RESULT_JSON="$(jq -cn \
      --argjson iid "${IID}" \
      --argjson att "${ATTEMPT_NUMBER}" \
      --arg final_status "${FINAL_STATUS}" \
      --argjson cleanup "${CLEANUP}" \
      --argjson remaining "${REMAINING}" \
      --arg chat "launch_failed #${IID} att=${ATTEMPT_NUMBER} attempts=${LAUNCH_ATTEMPTS} → blocked" '
      {status:"launch_failed_recorded", iid:$iid, attempt_number:$att,
       final_status:$final_status, cleanup:$cleanup,
       remaining_pending_count:$remaining, chat_summary:$chat}')"
    NEW_STATE="$(install_driven_receipt "${NEW_STATE}" "${RESULT_JSON}" "${NOW}")"
    persist_state "${NEW_STATE}"

    wrapper_log record_spawn "launch_failed iid=${IID} attempt=${ATTEMPT_NUMBER} attempts=${LAUNCH_ATTEMPTS} err=${LAUNCH_ERROR}"

    printf '%s\n' "${RESULT_JSON}"
    ;;
esac
