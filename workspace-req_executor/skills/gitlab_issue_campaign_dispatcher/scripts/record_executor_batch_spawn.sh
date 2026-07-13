#!/usr/bin/env bash
# Fixed post-sessions_spawn entry. The LLM reports only the safe grant identity
# and runtime ack/error; this wrapper recovers the private scheduler claim,
# records project pending state, then records the same claim in the scheduler.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
SCHEDULER_ENV_CMD="${SCHEDULER_ENV_CMD:-${SCRIPT_DIR}/scheduler_env.sh}"
RESOLVE_REPO_CMD="${RESOLVE_REPO_CMD:-${SCRIPT_DIR}/resolve_driven_repo_path.sh}"
PROJECT_RECORD_CMD="${PROJECT_RECORD_CMD:-${SCRIPT_DIR}/dispatch_record_spawn.sh}"
RECORD_LAUNCH_CMD="${RECORD_LAUNCH_CMD:-${SCRIPT_DIR}/record_driven_batch_launch.sh}"

die() {
  echo "record_executor_batch_spawn.sh: $*" >&2
  exit 2
}

validate_command() {
  local name="$1" path="$2"
  case "${path}" in
    /*) ;;
    *) die "${name} must be absolute" ;;
  esac
  [ -f "${path}" ] && [ -x "${path}" ] \
    || die "${name} must be an executable regular file"
}
validate_command SCHEDULER_ENV_CMD "${SCHEDULER_ENV_CMD}"
validate_command RESOLVE_REPO_CMD "${RESOLVE_REPO_CMD}"
validate_command PROJECT_RECORD_CMD "${PROJECT_RECORD_CMD}"
validate_command RECORD_LAUNCH_CMD "${RECORD_LAUNCH_CMD}"

if ! INPUT_JSON="$(jq -ce '
  def clean_string:
    type == "string" and length > 0
    and (explode | all(. >= 32 and . != 127));
  def common:
    (.job_id | clean_string)
    and (.claim_generation | type == "number" and . == floor and . > 0)
    and (.project | type == "string"
      and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    and (.iid | type == "number" and . == floor and . > 0)
    and (.attempt_number | type == "number" and . == floor and . > 0);
  if type != "object" or (common | not) then error("invalid common fields")
  elif .status == "spawned" then
    if (keys | sort) == [
        "attempt_number","child_session_key","claim_generation","iid",
        "job_id","project","run_id","status"
      ]
      and (.run_id | clean_string)
      and (.child_session_key | clean_string)
    then . else error("invalid spawned result") end
  elif .status == "launch_failed" then
    if (keys | sort) == [
        "attempt_number","claim_generation","iid","job_id","launch_attempts",
        "launch_error","project","status"
      ]
      and (.launch_attempts | type == "number" and . == floor and . > 0 and . <= 3)
      and (.launch_error | type == "string" and length > 0 and length <= 1024
        and (explode | all(. >= 32 and . != 127)))
    then . else error("invalid launch_failed result") end
  else error("unsupported status") end
' 2>/dev/null)"; then
  die "stdin must be one strict spawned or launch_failed result object"
fi

GITLAB_TOKEN_PROCESS_OVERRIDE="${GITLAB_TOKEN:-}"
GITLAB_HOST_PROCESS_SET="${GITLAB_HOST+x}"
GITLAB_HOST_PROCESS_OVERRIDE="${GITLAB_HOST:-}"
GITLAB_PROTOCOL_PROCESS_SET="${GITLAB_API_PROTOCOL+x}"
GITLAB_PROTOCOL_PROCESS_OVERRIDE="${GITLAB_API_PROTOCOL:-}"
REPO_PARENT_PROCESS_OVERRIDE="${REPO_PARENT_PATH:-}"
SCHEDULER_ROOT_PROCESS_SET="${EXECUTOR_SCHEDULER_ROOT+x}"
SCHEDULER_ROOT_PROCESS_OVERRIDE="${EXECUTOR_SCHEDULER_ROOT:-}"
MAX_CONCURRENCY_PROCESS_SET="${EXECUTOR_MAX_CONCURRENCY+x}"
MAX_CONCURRENCY_PROCESS_OVERRIDE="${EXECUTOR_MAX_CONCURRENCY:-}"
RUNNING_LEASE_PROCESS_SET="${EXECUTOR_RUNNING_LEASE_SECONDS+x}"
RUNNING_LEASE_PROCESS_OVERRIDE="${EXECUTOR_RUNNING_LEASE_SECONDS:-}"
EXECUTOR_AGENT_PROCESS_SET="${EXECUTOR_AGENT+x}"
EXECUTOR_AGENT_PROCESS_OVERRIDE="${EXECUTOR_AGENT:-}"
CALLBACK_TARGET_PROCESS_SET="${DISPATCHER_CALLBACK_TARGET+x}"
CALLBACK_TARGET_PROCESS_OVERRIDE="${DISPATCHER_CALLBACK_TARGET:-}"
LOCK_COMPAT_PROCESS_SET="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS+x}"
LOCK_COMPAT_PROCESS_OVERRIDE="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS:-}"
[ -f "${CONFIG_DIR}/gitlab.env" ] || die "missing config/gitlab.env"
[ -f "${CONFIG_DIR}/campaign_defaults.env" ] || die "missing config/campaign_defaults.env"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/gitlab.env"
GITLAB_TOKEN_PIN="${GITLAB_TOKEN:-}"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/campaign_defaults.env"
if [ -f "${CONFIG_DIR}/campaign_defaults.local.env" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_DIR}/campaign_defaults.local.env"
fi
if [ "${GITLAB_HOST_PROCESS_SET}" = x ]; then
  GITLAB_HOST="${GITLAB_HOST_PROCESS_OVERRIDE}"
fi
if [ "${GITLAB_PROTOCOL_PROCESS_SET}" = x ]; then
  GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_PROCESS_OVERRIDE}"
fi
if [ "${SCHEDULER_ROOT_PROCESS_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT_PROCESS_OVERRIDE}"
fi
if [ "${MAX_CONCURRENCY_PROCESS_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${MAX_CONCURRENCY_PROCESS_OVERRIDE}"
fi
if [ "${RUNNING_LEASE_PROCESS_SET}" = x ]; then
  EXECUTOR_RUNNING_LEASE_SECONDS="${RUNNING_LEASE_PROCESS_OVERRIDE}"
fi
if [ "${EXECUTOR_AGENT_PROCESS_SET}" = x ]; then
  EXECUTOR_AGENT="${EXECUTOR_AGENT_PROCESS_OVERRIDE}"
fi
if [ "${CALLBACK_TARGET_PROCESS_SET}" = x ]; then
  DISPATCHER_CALLBACK_TARGET="${CALLBACK_TARGET_PROCESS_OVERRIDE}"
fi
if [ "${LOCK_COMPAT_PROCESS_SET}" = x ]; then
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS="${LOCK_COMPAT_PROCESS_OVERRIDE}"
fi
GITLAB_TOKEN_EFF="${GITLAB_TOKEN_PROCESS_OVERRIDE:-${GITLAB_TOKEN_PIN:-}}"
REPO_PARENT_BASE="${REPO_PARENT_PROCESS_OVERRIDE:-${REPO_PARENT_PATH:-/data}}"
[ -n "${GITLAB_TOKEN_EFF}" ] || die "executor GitLab credential is unavailable"
: "${GITLAB_HOST:?record_executor_batch_spawn.sh: GITLAB_HOST missing}"
: "${GITLAB_API_PROTOCOL:?record_executor_batch_spawn.sh: GITLAB_API_PROTOCOL missing}"

# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null
if [ "${GITLAB_HOST_PROCESS_SET}" = x ]; then
  GITLAB_HOST="${GITLAB_HOST_PROCESS_OVERRIDE}"
fi
if [ "${GITLAB_PROTOCOL_PROCESS_SET}" = x ]; then
  GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_PROCESS_OVERRIDE}"
fi
if [ "${RUNNING_LEASE_PROCESS_SET}" = x ]; then
  EXECUTOR_RUNNING_LEASE_SECONDS="${RUNNING_LEASE_PROCESS_OVERRIDE}"
fi

JOB_ID="$(jq -r '.job_id' <<<"${INPUT_JSON}")"
CLAIM_GENERATION="$(jq -r '.claim_generation' <<<"${INPUT_JSON}")"
PROJECT_FULL="$(jq -r '.project' <<<"${INPUT_JSON}")"
IID="$(jq -r '.iid' <<<"${INPUT_JSON}")"
ATTEMPT_NUMBER="$(jq -r '.attempt_number' <<<"${INPUT_JSON}")"
RESULT_STATUS="$(jq -r '.status' <<<"${INPUT_JSON}")"

if [ "${RESULT_STATUS}" = spawned ]; then
  ACK_JSON="$(jq -c '{run_id,child_session_key}' <<<"${INPUT_JSON}")"
  SCHEDULER_ACTION=spawned
  FINAL_STATUS=spawned_recorded
else
  ACK_JSON="$(jq -c '{launch_attempts,launch_error}' <<<"${INPUT_JSON}")"
  SCHEDULER_ACTION=launch_failed
  FINAL_STATUS=launch_failed_recorded
fi

# The per-job coordinator serializes retries and keeps the private claim plus
# runtime ack durable before either downstream state machine is touched.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_driven_launch_coordinator.sh"
dlc_open "${JOB_ID}"
trap dlc_close EXIT
ACTION_JSON="$(dlc_read)" || die "durable launch action is invalid"
if [ "${ACTION_JSON}" = null ]; then
  # No coordinator action exists yet (for example an older tick emitted the
  # grant). Recover the exact current claim under scheduler.lock.
  exec {CLAIM_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  flock -x "${CLAIM_LOCK_FD}"
  CLAIM_TOKEN="$(jq -er \
    --arg job_id "${JOB_ID}" \
    --arg project "${PROJECT_FULL}" \
    --argjson iid "${IID}" \
    --argjson generation "${CLAIM_GENERATION}" '
    .active_jobs[$job_id]
    | if type == "object"
        and .job_id == $job_id
        and .project == $project
        and .iid == $iid
        and .status == "preparing"
        and .claim_generation == $generation
        and (.claim_token | type == "string" and length > 0)
      then .claim_token else error("claim is no longer current") end
  ' "${SCHEDULER_STATE_FILE}")" || {
    flock -u "${CLAIM_LOCK_FD}"
    exec {CLAIM_LOCK_FD}>&-
    die "spawn result no longer matches the active preparing claim"
  }
  flock -u "${CLAIM_LOCK_FD}"
  exec {CLAIM_LOCK_FD}>&-
  NOW_EPOCH_VALUE="$(date +%s)"
  ACTION_JSON="$(jq -cnS \
    --arg job_id "${JOB_ID}" \
    --arg project "${PROJECT_FULL}" \
    --argjson iid "${IID}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --argjson claim_generation "${CLAIM_GENERATION}" \
    --arg claim_token "${CLAIM_TOKEN}" \
    --arg outcome "${RESULT_STATUS}" \
    --argjson ack "${ACK_JSON}" \
    --argjson now "${NOW_EPOCH_VALUE}" '{
      version:1,
      job_id:$job_id,
      project:$project,
      iid:$iid,
      attempt_number:$attempt_number,
      claim_generation:$claim_generation,
      claim_token:$claim_token,
      stage:"ack_received",
      outcome:$outcome,
      ack:$ack,
      created_at:$now,
      updated_at:$now
    }')"
  dlc_write "${ACTION_JSON}"
else
  if ! jq -e \
      --arg job_id "${JOB_ID}" \
      --arg project "${PROJECT_FULL}" \
      --argjson iid "${IID}" \
      --argjson attempt_number "${ATTEMPT_NUMBER}" \
      --argjson claim_generation "${CLAIM_GENERATION}" \
      --arg outcome "${RESULT_STATUS}" \
      --argjson ack "${ACK_JSON}" '
      .job_id == $job_id
      and .project == $project
      and .iid == $iid
      and .attempt_number == $attempt_number
      and .claim_generation == $claim_generation
      and (if (.stage == "topup_prepared" or .stage == "preparing_claimed"
          or .stage == "bound" or .stage == "action_emitted")
        then (.outcome == null or .outcome == $outcome)
          and (.ack == null or .ack == $ack)
        else .outcome == $outcome and .ack == $ack
        end)
    ' <<<"${ACTION_JSON}" >/dev/null; then
    die "spawn result conflicts with the durable launch action"
  fi
  CLAIM_TOKEN="$(jq -r '.claim_token' <<<"${ACTION_JSON}")"
  case "$(jq -r '.stage' <<<"${ACTION_JSON}")" in
    preparing_claimed|bound|action_emitted)
      ACTION_JSON="$(jq -c --arg outcome "${RESULT_STATUS}" \
        --argjson ack "${ACK_JSON}" --argjson now "$(date +%s)" '
        .stage = "ack_received"
        | .outcome = $outcome
        | .ack = $ack
        | .updated_at = $now
      ' <<<"${ACTION_JSON}")"
      dlc_write "${ACTION_JSON}"
      ;;
  esac
fi

if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_ack_persist ]; then
  exit 86
fi

CURRENT_STAGE="$(jq -r '.stage' <<<"${ACTION_JSON}")"
if [ "${CURRENT_STAGE}" = scheduler_recorded ] || [ "${CURRENT_STAGE}" = completed ]; then
  if [ "${CURRENT_STAGE}" != completed ]; then
    ACTION_JSON="$(jq -c --argjson now "$(date +%s)" \
      '.stage = "completed" | .updated_at = $now' <<<"${ACTION_JSON}")"
    dlc_write "${ACTION_JSON}"
  fi
  jq -cn \
    --arg status "${FINAL_STATUS}" \
    --arg job_id "${JOB_ID}" \
    --argjson claim_generation "${CLAIM_GENERATION}" '{
    status:$status,job_id:$job_id,claim_generation:$claim_generation,
    chat_summary:("recorded " + $status + " for " + $job_id)
  }'
  exit 0
fi

GROUP_EFF="${PROJECT_FULL%/*}"
PROJECT_SLUG="${PROJECT_FULL##*/}"
RESOLVED_REPO_PATH="$(PROJECT_FULL="${PROJECT_FULL}" \
  REPO_PARENT_PATH="${REPO_PARENT_BASE}" \
  GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
  GITLAB_HOST="${GITLAB_HOST}" \
  bash "${RESOLVE_REPO_CMD}")" || die "unable to resolve project repo path"
PROJECT_REPO_PARENT="${RESOLVED_REPO_PATH%/*}"

if [ "${CURRENT_STAGE}" = ack_received ]; then
  if [ "${RESULT_STATUS}" = spawned ]; then
    set +e
    PROJECT_OUTPUT="$(PROJECT="${PROJECT_SLUG}" GROUP="${GROUP_EFF}" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" REPO_PARENT_PATH="${PROJECT_REPO_PARENT}" \
      IID="${IID}" ATTEMPT_NUMBER="${ATTEMPT_NUMBER}" STATUS=spawned \
      DRIVEN_JOB_ID="${JOB_ID}" \
      DRIVEN_CLAIM_GENERATION="${CLAIM_GENERATION}" \
      DRIVEN_CLAIM_TOKEN="${CLAIM_TOKEN}" \
      RUN_ID="$(jq -r '.run_id' <<<"${ACK_JSON}")" \
      CHILD_SESSION_KEY="$(jq -r '.child_session_key' <<<"${ACK_JSON}")" \
      bash "${PROJECT_RECORD_CMD}" 2>/dev/null)"
    PROJECT_RC=$?
    set -e
  else
    set +e
    PROJECT_OUTPUT="$(PROJECT="${PROJECT_SLUG}" GROUP="${GROUP_EFF}" \
      GITLAB_TOKEN="${GITLAB_TOKEN_EFF}" REPO_PARENT_PATH="${PROJECT_REPO_PARENT}" \
      IID="${IID}" ATTEMPT_NUMBER="${ATTEMPT_NUMBER}" STATUS=launch_failed \
      DRIVEN_JOB_ID="${JOB_ID}" \
      DRIVEN_CLAIM_GENERATION="${CLAIM_GENERATION}" \
      DRIVEN_CLAIM_TOKEN="${CLAIM_TOKEN}" \
      LAUNCH_ATTEMPTS="$(jq -r '.launch_attempts' <<<"${ACK_JSON}")" \
      LAUNCH_ERROR="$(jq -r '.launch_error' <<<"${ACK_JSON}")" \
      bash "${PROJECT_RECORD_CMD}" 2>/dev/null)"
    PROJECT_RC=$?
    set -e
  fi
  if [ "${PROJECT_RC}" -ne 0 ] || ! jq -e \
      --arg result_status "${RESULT_STATUS}" \
      --argjson iid "${IID}" \
      --argjson attempt "${ATTEMPT_NUMBER}" '
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
      if $result_status == "spawned" then
        type == "object"
        and (keys | sort) == [
          "attempt_number","chat_summary","iid",
          "remaining_pending_count","status"
        ]
        and .status == "spawned"
        and .iid == $iid
        and .attempt_number == $attempt
        and (.remaining_pending_count | type == "number"
          and . == floor and . >= 0)
        and (.chat_summary | clean_string)
      elif $result_status == "launch_failed" then
        type == "object"
        and (keys | sort) == [
          "attempt_number","chat_summary","cleanup","final_status","iid",
          "remaining_pending_count","status"
        ]
        and .status == "launch_failed_recorded"
        and .iid == $iid
        and .attempt_number == $attempt
        and .final_status == "blocked"
        and (.remaining_pending_count | type == "number"
          and . == floor and . >= 0)
        and (.chat_summary | clean_string)
        and (. as $result
          | ($result.cleanup | valid_cleanup($result.final_status)))
      else false end
    ' <<<"${PROJECT_OUTPUT}" >/dev/null 2>&1; then
    jq -cn \
      --arg job_id "${JOB_ID}" \
      --argjson claim_generation "${CLAIM_GENERATION}" '{
      status:"project_record_pending",job_id:$job_id,
      claim_generation:$claim_generation,
      chat_summary:"runtime ack is durable; project record is pending recovery"
    }'
    exit 0
  fi
  # Fault injection at the real ambiguity window: project state is durable,
  # but the coordinator has not advanced beyond ack_received yet.
  if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_project_record ]; then
    exit 87
  fi
  PROJECT_RECEIPT_SHA256="$(printf '%s' "$(jq -cS . <<<"${PROJECT_OUTPUT}")" | dlc_sha256)" \
    || die "unable to hash the durable project receipt"
  ACTION_JSON="$(jq -c \
    --arg project_receipt_sha256 "${PROJECT_RECEIPT_SHA256}" \
    --argjson now "$(date +%s)" '
    .stage = "project_recorded"
    | .project_receipt_sha256 = $project_receipt_sha256
    | .updated_at = $now
  ' <<<"${ACTION_JSON}")"
  dlc_write "${ACTION_JSON}"
  CURRENT_STAGE=project_recorded
fi

if [ "${CURRENT_STAGE}" = project_recorded ]; then
  EFFECTIVE_SCHEDULER_ACTION="${SCHEDULER_ACTION}"
  if [ "${RESULT_STATUS}" = spawned ] || [ "${RESULT_STATUS}" = launch_failed ]; then
    # reserve may have fenced an unacknowledged preparing lease back to the
    # same reserved generation before runtime reconciliation found the child.
    # Restore that exact generation; never allocate or infer a new claim here.
    exec {RECOVERY_STATE_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
    flock -x "${RECOVERY_STATE_LOCK_FD}"
    RECOVERY_SCHEDULER_JOB="$(jq -c --arg job_id "${JOB_ID}" \
      '.active_jobs[$job_id] // null' "${SCHEDULER_STATE_FILE}")"
    flock -u "${RECOVERY_STATE_LOCK_FD}"
    exec {RECOVERY_STATE_LOCK_FD}>&-
    if jq -e \
        --argjson generation "${CLAIM_GENERATION}" '
        type == "object"
        and .status == "reserved"
        and .claim_generation == $generation
        and .claim_token == null
      ' <<<"${RECOVERY_SCHEDULER_JOB}" >/dev/null; then
      if [ "${RESULT_STATUS}" = spawned ]; then
        EFFECTIVE_SCHEDULER_ACTION=recovered_spawned
      else
        EFFECTIVE_SCHEDULER_ACTION=recovered_launch_failed
      fi
    fi
  fi
  set +e
  SCHEDULER_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${JOB_ID}" \
    ACTION="${EFFECTIVE_SCHEDULER_ACTION}" \
    CLAIM_GENERATION="${CLAIM_GENERATION}" CLAIM_TOKEN="${CLAIM_TOKEN}" \
    bash "${RECORD_LAUNCH_CMD}" 2>/dev/null)"
  SCHEDULER_RC=$?
  set -e
  EXPECTED_JOB_STATUS=running
  [ "${SCHEDULER_ACTION}" = launch_failed ] && EXPECTED_JOB_STATUS=launch_failed
  if [ "${SCHEDULER_RC}" -ne 0 ] || ! jq -e \
      --arg job_id "${JOB_ID}" \
      --arg job_status "${EXPECTED_JOB_STATUS}" '
      type == "object" and .status == "recorded"
      and .job_id == $job_id and .job_status == $job_status
    ' <<<"${SCHEDULER_OUTPUT}" >/dev/null 2>&1; then
    jq -cn \
      --arg job_id "${JOB_ID}" \
      --argjson claim_generation "${CLAIM_GENERATION}" '{
      status:"scheduler_record_pending",job_id:$job_id,
      claim_generation:$claim_generation,
      chat_summary:"project result is durable; scheduler record is pending recovery"
    }'
    exit 0
  fi
  # Fault injection at the real ambiguity window: scheduler state (including
  # launch_failed deletion) is durable, but the coordinator is still only at
  # project_recorded.
  if [ "${DRIVEN_COORDINATOR_FAULT:-}" = after_scheduler_record ]; then
    exit 88
  fi
  ACTION_JSON="$(jq -c --argjson now "$(date +%s)" \
    '.stage = "scheduler_recorded" | .updated_at = $now' <<<"${ACTION_JSON}")"
  dlc_write "${ACTION_JSON}"
fi

ACTION_JSON="$(jq -c --argjson now "$(date +%s)" \
  '.stage = "completed" | .updated_at = $now' <<<"${ACTION_JSON}")"
dlc_write "${ACTION_JSON}"

jq -cn \
  --arg status "${FINAL_STATUS}" \
  --arg job_id "${JOB_ID}" \
  --argjson claim_generation "${CLAIM_GENERATION}" '{
  status:$status,
  job_id:$job_id,
  claim_generation:$claim_generation,
  chat_summary:("recorded " + $status + " for " + $job_id)
}'
