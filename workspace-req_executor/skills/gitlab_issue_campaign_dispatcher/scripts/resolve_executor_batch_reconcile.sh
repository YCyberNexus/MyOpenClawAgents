#!/usr/bin/env bash
# Resolve one durable action_emitted crash window from explicit runtime
# evidence. This fixed wrapper owns all private coordinator/scheduler state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
SCHEDULER_ENV_CMD="${SCHEDULER_ENV_CMD:-${SCRIPT_DIR}/scheduler_env.sh}"
RECORD_SPAWN_CMD="${RECORD_SPAWN_CMD:-${SCRIPT_DIR}/record_executor_batch_spawn.sh}"

die() {
  echo "resolve_executor_batch_reconcile.sh: $*" >&2
  exit 2
}

validate_command() {
  local name="$1" path="$2"
  case "${path}" in
    /*) ;;
    *) die "${name} must be absolute" ;;
  esac
  case "${path}" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "${name} contains control characters" ;;
  esac
  [ -f "${path}" ] && [ -x "${path}" ] \
    || die "${name} must be an executable regular file"
}

validate_command SCHEDULER_ENV_CMD "${SCHEDULER_ENV_CMD}"
validate_command RECORD_SPAWN_CMD "${RECORD_SPAWN_CMD}"

if ! INPUT_JSON="$(jq -ce '
  def clean_string:
    type == "string" and length > 0
    and (explode | all(. >= 32 and . != 127));
  def common:
    (.job_id | clean_string)
    and (.claim_generation | type == "number" and . == floor and . > 0);
  if type != "object" or (common | not) then error("invalid common fields")
  elif .resolution == "spawned" then
    if (keys | sort) == [
        "child_session_key","claim_generation","job_id","resolution","run_id"
      ]
      and (.run_id | clean_string)
      and (.child_session_key | clean_string)
    then . else error("invalid spawned evidence") end
  elif .resolution == "not_found" then
    if (keys | sort) == ["claim_generation","evidence","job_id","resolution"]
      and (.evidence == "subagents_list_no_matching_label"
        or .evidence == "session_terminal_without_ack")
    then . else error("invalid not_found evidence") end
  else error("unsupported resolution") end
' 2>/dev/null)"; then
  die "stdin must be one strict spawned or not_found reconciliation object"
fi

# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_driven_launch_coordinator.sh"

JOB_ID="$(jq -r '.job_id' <<<"${INPUT_JSON}")"
CLAIM_GENERATION="$(jq -r '.claim_generation' <<<"${INPUT_JSON}")"
RESOLUTION="$(jq -r '.resolution' <<<"${INPUT_JSON}")"

dlc_open "${JOB_ID}"
trap dlc_close EXIT
ACTION_JSON="$(dlc_read)" || die "durable launch action is invalid"
[ "${ACTION_JSON}" != null ] || die "durable launch action does not exist"
if [ "$(jq -r '.legacy_execution_schema // false' <<<"${ACTION_JSON}")" = true ]; then
  die "legacy execution schema must drain before runtime reconciliation"
fi

if [ "${RESOLUTION}" = not_found ]; then
  EVIDENCE="$(jq -r '.evidence' <<<"${INPUT_JSON}")"
  if jq -e \
      --arg job_id "${JOB_ID}" \
      --argjson generation "${CLAIM_GENERATION}" \
      --arg evidence "${EVIDENCE}" '
      .job_id == $job_id
      and .stage == "topup_prepared"
      and .claim_generation == 0 and .claim_token == null
      and .reconciliation.generation == $generation
      and .reconciliation.resolution == "not_found"
      and .reconciliation.evidence == $evidence
    ' <<<"${ACTION_JSON}" >/dev/null; then
    jq -cn --arg job_id "${JOB_ID}" \
      --argjson claim_generation "${CLAIM_GENERATION}" '{
      status:"reset_for_next_generation",
      job_id:$job_id,
      claim_generation:$claim_generation
    }'
    exit 0
  fi

  jq -e \
    --arg job_id "${JOB_ID}" \
    --argjson generation "${CLAIM_GENERATION}" '
    .job_id == $job_id
    and .stage == "action_emitted"
    and .claim_generation == $generation
    and (.claim_token | type == "string" and length > 0)
    and .outcome == null and .ack == null
  ' <<<"${ACTION_JSON}" >/dev/null \
    || die "not_found evidence no longer matches the emitted action"

  # Preserve lock ordering used by the tick and post-spawn recorder:
  # launch-action lock first, scheduler lock second.
  exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  flock -x "${SCHEDULER_LOCK_FD}"
  SCHEDULER_JOB="$(jq -ce --arg job_id "${JOB_ID}" \
    '.active_jobs[$job_id] // null' "${SCHEDULER_STATE_FILE}")" \
    || die "scheduler state is invalid"
  if ! jq -e \
      --arg project "$(jq -r '.project' <<<"${ACTION_JSON}")" \
      --argjson iid "$(jq -r '.iid' <<<"${ACTION_JSON}")" \
      --argjson generation "${CLAIM_GENERATION}" '
      type == "object"
      and .project == $project and .iid == $iid
      and .status == "reserved"
      and .claim_generation == $generation
      and .claim_token == null
    ' <<<"${SCHEDULER_JOB}" >/dev/null; then
    flock -u "${SCHEDULER_LOCK_FD}"
    exec {SCHEDULER_LOCK_FD}>&-
    die "not_found reset requires the matching fenced reserved generation"
  fi

  NOW_EPOCH_VALUE="$(date +%s)"
  ACTION_JSON="$(jq -c \
    --argjson generation "${CLAIM_GENERATION}" \
    --arg evidence "${EVIDENCE}" \
    --argjson now "${NOW_EPOCH_VALUE}" '
    .claim_generation = 0
    | .claim_token = null
    | .stage = "topup_prepared"
    | .outcome = null
    | .ack = null
    | .reconciliation = {
        generation:$generation,
        resolution:"not_found",
        evidence:$evidence,
        resolved_at:$now
      }
    | .updated_at = $now
  ' <<<"${ACTION_JSON}")"
  dlc_write "${ACTION_JSON}"
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-

  jq -cn --arg job_id "${JOB_ID}" \
    --argjson claim_generation "${CLAIM_GENERATION}" '{
    status:"reset_for_next_generation",
    job_id:$job_id,
    claim_generation:$claim_generation
  }'
  exit 0
fi

RUNTIME_ACK="$(jq -c '{run_id,child_session_key}' <<<"${INPUT_JSON}")"
if ! jq -e \
    --arg job_id "${JOB_ID}" \
    --argjson generation "${CLAIM_GENERATION}" \
    --argjson ack "${RUNTIME_ACK}" '
    .job_id == $job_id
    and .claim_generation == $generation
    and (.stage == "action_emitted" or .stage == "ack_received"
      or .stage == "project_recorded" or .stage == "scheduler_recorded"
      or .stage == "completed")
    and (.outcome == null or .outcome == "spawned")
    and (.ack == null or .ack == $ack)
  ' <<<"${ACTION_JSON}" >/dev/null; then
  die "spawned evidence conflicts with the durable launch action"
fi

PROJECT_FULL="$(jq -r '.project' <<<"${ACTION_JSON}")"
IID="$(jq -r '.iid' <<<"${ACTION_JSON}")"
EXECUTION_ID="$(jq -r '.execution_id' <<<"${ACTION_JSON}")"
dlc_close
trap - EXIT

POST_INPUT="$(jq -cn \
  --arg job_id "${JOB_ID}" \
  --argjson claim_generation "${CLAIM_GENERATION}" \
  --arg project "${PROJECT_FULL}" \
  --argjson iid "${IID}" \
  --argjson execution_id "${EXECUTION_ID}" \
  --arg run_id "$(jq -r '.run_id' <<<"${INPUT_JSON}")" \
  --arg child_session_key "$(jq -r '.child_session_key' <<<"${INPUT_JSON}")" '{
  job_id:$job_id,
  claim_generation:$claim_generation,
  project:$project,
  iid:$iid,
  execution_id:$execution_id,
  status:"spawned",
  run_id:$run_id,
  child_session_key:$child_session_key
}')"

set +e
POST_OUTPUT="$(printf '%s' "${POST_INPUT}" | \
  CONFIG_DIR="${CONFIG_DIR}" bash "${RECORD_SPAWN_CMD}" 2>/dev/null)"
POST_RC=$?
set -e
if [ "${POST_RC}" -ne 0 ] || ! POST_JSON="$(printf '%s' "${POST_OUTPUT}" | jq -ce \
    --arg job_id "${JOB_ID}" \
    --argjson generation "${CLAIM_GENERATION}" '
    if type == "object"
      and (.status == "spawned_recorded"
        or .status == "project_record_pending"
        or .status == "scheduler_record_pending")
      and .job_id == $job_id
      and .claim_generation == $generation
    then . else error("invalid post-spawn result") end
  ' 2>/dev/null)"; then
  die "fixed post-spawn recorder rejected the runtime evidence"
fi

jq -cn \
  --arg status "$(jq -r '.status' <<<"${POST_JSON}")" \
  --arg job_id "${JOB_ID}" \
  --argjson claim_generation "${CLAIM_GENERATION}" '{
  status:$status,
  job_id:$job_id,
  claim_generation:$claim_generation
}'
