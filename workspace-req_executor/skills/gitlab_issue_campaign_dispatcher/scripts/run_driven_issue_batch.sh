#!/usr/bin/env bash
# Fixed shell entry for RUN_DRIVEN_ISSUE_BATCH. It freezes/idempotently reuses
# the batch and immediately runs one recovery-first executor tick. It never
# calls sessions_spawn and never returns GitLab or scheduler claim tokens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
CREATE_BATCH_CMD="${CREATE_BATCH_CMD:-${SCRIPT_DIR}/create_driven_batch.sh}"
EXECUTOR_TICK_CMD="${EXECUTOR_TICK_CMD:-${SCRIPT_DIR}/run_executor_batch_tick.sh}"

retire_sensitive_file() {
  local path="$1"
  [ -e "${path}" ] || return 0
  : >"${path}" 2>/dev/null || true
  local retired_root="${TMPDIR:-/tmp}/req_executor.retired"
  mkdir -p "${retired_root}" 2>/dev/null || return 0
  mv "${path}" "${retired_root}/$(basename "${path}").$$.${RANDOM}" 2>/dev/null || true
}

validate_command() {
  local name="$1" path="$2"
  case "${path}" in
    /*) ;;
    *) echo "run_driven_issue_batch.sh: ${name} must be absolute" >&2; exit 2 ;;
  esac
  [ -f "${path}" ] && [ -x "${path}" ] \
    || { echo "run_driven_issue_batch.sh: ${name} must be executable" >&2; exit 2; }
}

validate_command CREATE_BATCH_CMD "${CREATE_BATCH_CMD}"
validate_command EXECUTOR_TICK_CMD "${EXECUTOR_TICK_CMD}"

TRIGGER_FILE="$(mktemp "${TMPDIR:-/tmp}/req-executor-driven-trigger.XXXXXX")"
CREATE_ERR="$(mktemp "${TMPDIR:-/tmp}/req-executor-create-batch.XXXXXX")"
TICK_ERR="$(mktemp "${TMPDIR:-/tmp}/req-executor-batch-tick.XXXXXX")"
trap 'retire_sensitive_file "${TRIGGER_FILE}"; retire_sensitive_file "${CREATE_ERR}"; retire_sensitive_file "${TICK_ERR}"' EXIT
cat >"${TRIGGER_FILE}"

set +e
CREATE_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" bash "${CREATE_BATCH_CMD}" \
  <"${TRIGGER_FILE}" 2>"${CREATE_ERR}")"
CREATE_RC=$?
set -e
if [ "${CREATE_RC}" -ne 0 ]; then
  jq -cn '{
    status:"batch_failed",
    batch_id:null,
    matched_count:0,
    snapshot_digest:null,
    scheduler_status:null,
    spawn_grants:[],reconcile_actions:[],cleanup_actions:[],
    operation_results:[{operation:"create_batch",status:"failed"}],
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:"driven batch intake failed"
  }'
  exit 0
fi

if ! CREATE_JSON="$(printf '%s' "${CREATE_OUTPUT}" | jq -ce '
  if type == "object"
    and (keys | sort) == [
      "batch_id","matched_count","scheduler_status","snapshot_digest","status"
    ]
    and .status == "success"
    and (.batch_id | type == "string" and length > 0)
    and (.matched_count | type == "number" and . == floor and . >= 0)
    and (.snapshot_digest | type == "string" and length > 0)
    and (.scheduler_status == "queued" or .scheduler_status == "running"
      or .scheduler_status == "completed")
  then . else error("invalid create envelope") end
' 2>/dev/null)"; then
  jq -cn '{
    status:"batch_failed",
    batch_id:null,
    matched_count:0,
    snapshot_digest:null,
    scheduler_status:null,
    spawn_grants:[],reconcile_actions:[],cleanup_actions:[],
    operation_results:[{operation:"create_batch",status:"invalid_envelope"}],
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:"driven batch intake returned an invalid envelope"
  }'
  exit 0
fi

set +e
# I1 is invoked synchronously from req_dispatcher's main session. Delivering a
# ready I3 callback from inside this same call would synchronously target that
# occupied main session and deadlock the acceptance path. The intake tick may
# still import handoffs and prepare work, but callback transport is deferred to
# the ordinary req_executor heartbeat after the public acceptance returns.
TICK_OUTPUT="$(DEFER_DRIVEN_CALLBACK_DELIVERY=1 \
  CONFIG_DIR="${CONFIG_DIR}" bash "${EXECUTOR_TICK_CMD}" 2>"${TICK_ERR}")"
TICK_RC=$?
set -e
if [ "${TICK_RC}" -ne 0 ] || ! TICK_JSON="$(printf '%s' "${TICK_OUTPUT}" | jq -ce '
  if type == "object"
    and (keys | sort) == [
      "backoff_seconds","chat_summary","cleanup_actions",
      "max_launch_retries","operation_results","reconcile_actions",
      "spawn_grants","status"
    ]
    and (.status == "ready" or .status == "idle" or .status == "tick_failed"
      or .status == "reconcile_required" or .status == "cleanup_required")
    and (.spawn_grants | type == "array")
    and (.reconcile_actions | type == "array")
    and (.cleanup_actions | type == "array")
    and (.operation_results | type == "array")
    and .max_launch_retries == 3
    and .backoff_seconds == 2
  then . else error("invalid tick envelope") end
' 2>/dev/null)"; then
  TICK_JSON='{"status":"tick_failed","spawn_grants":[],"reconcile_actions":[],"cleanup_actions":[],"operation_results":[{"operation":"executor_tick","status":"failed"}],"max_launch_retries":3,"backoff_seconds":2,"chat_summary":"executor batch tick failed"}'
fi

RESULT_STATUS=accepted
[ "$(jq -r '.status' <<<"${TICK_JSON}")" = ready ] && RESULT_STATUS=ready
[ "$(jq -r '.status' <<<"${TICK_JSON}")" = tick_failed ] && RESULT_STATUS=tick_failed

jq -cn \
  --arg status "${RESULT_STATUS}" \
  --argjson batch "${CREATE_JSON}" \
  --argjson tick "${TICK_JSON}" '
  {
    status:$status,
    batch_id:$batch.batch_id,
    matched_count:$batch.matched_count,
    snapshot_digest:$batch.snapshot_digest,
    scheduler_status:$batch.scheduler_status,
    spawn_grants:$tick.spawn_grants,
    reconcile_actions:$tick.reconcile_actions,
    cleanup_actions:$tick.cleanup_actions,
    operation_results:([{operation:"create_batch",status:"success"}]
      + $tick.operation_results),
    max_launch_retries:3,
    backoff_seconds:2,
    chat_summary:("batch " + $batch.batch_id + " accepted; " + $tick.chat_summary)
  }'
