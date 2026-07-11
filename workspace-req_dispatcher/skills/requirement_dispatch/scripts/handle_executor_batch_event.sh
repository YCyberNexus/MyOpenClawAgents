#!/usr/bin/env bash
# Fixed public I3 handler: strict transport unwrap, durable apply, same-event
# ack, then notification drain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

handler_die() {
  echo "handle_executor_batch_event.sh: $1" >&2
  exit "${2:-2}"
}

WORKER_RESULT_INPUT="${WORKER_RESULT_JSON:-${worker_result_json:-}}"
if [ -z "${WORKER_RESULT_INPUT}" ] && [ "$#" -gt 0 ]; then
  WORKER_RESULT_INPUT="$1"
fi
if [ -z "${WORKER_RESULT_INPUT}" ] && [ ! -t 0 ]; then
  WORKER_RESULT_INPUT="$(cat)"
fi
[ -n "${WORKER_RESULT_INPUT}" ] \
  || handler_die "WORKER_RESULT_JSON or RUN_DRIVEN_BATCH_RESULT input required"

PUBLIC_I3_INPUT="${WORKER_RESULT_INPUT}"
if [[ "${WORKER_RESULT_INPUT}" == RUN_DRIVEN_BATCH_RESULT$'\n'* ]]; then
  trigger_body="${WORKER_RESULT_INPUT#RUN_DRIVEN_BATCH_RESULT$'\n'}"
  case "${trigger_body}" in
    worker_result_json=*) ;;
    *) handler_die "RUN_DRIVEN_BATCH_RESULT must contain exactly one worker_result_json line" ;;
  esac
  PUBLIC_I3_INPUT="${trigger_body#worker_result_json=}"
  [ -n "${PUBLIC_I3_INPUT}" ] \
    || handler_die "RUN_DRIVEN_BATCH_RESULT worker_result_json must not be empty"
  case "${PUBLIC_I3_INPUT}" in
    *$'\n'*) handler_die "RUN_DRIVEN_BATCH_RESULT must not contain extra or duplicate lines" ;;
  esac
elif [[ "${WORKER_RESULT_INPUT}" == RUN_DRIVEN_BATCH_RESULT* ]]; then
  handler_die "RUN_DRIVEN_BATCH_RESULT transport shape is invalid"
fi

if ! PUBLIC_I3_JSON="$(jq -cseS '
  if length == 1
    and (.[0] | type == "object")
    and ((.[0] | keys | sort) == [
      "batch_id","event_id","iid","mr_url","project","reason",
      "snapshot_index","status"
    ])
  then .[0]
  else error("expected exactly one public I3 object with eight fields")
  end
' <<<"${PUBLIC_I3_INPUT}" 2>/dev/null)"; then
  handler_die "worker_result_json must be exactly one public I3 object with eight fields"
fi

set +e
ack="$(
  WORKER_RESULT_JSON="${PUBLIC_I3_JSON}" \
    "${BASH}" "${SCRIPT_DIR}/apply_executor_batch_event.sh"
)"
apply_rc=$?
set -e
if [ "${apply_rc}" -ne 0 ]; then
  [ -z "${ack}" ] || printf '%s\n' "${ack}"
  exit "${apply_rc}"
fi
if ! jq -e '
  type == "object"
  and (keys | sort) == ["event_id","status"]
  and (.status == "accepted" or .status == "duplicate")
  and (.event_id | type == "string" and length > 0)
' <<<"${ack}" >/dev/null; then
  echo "handle_executor_batch_event.sh: apply returned an invalid ack" >&2
  exit 3
fi

set +e
bridge_result="$("${BASH}" "${SCRIPT_DIR}/recover_legacy_executor_batch_bridge.sh")"
bridge_rc=$?
set -e
if [ "${bridge_rc}" -ne 0 ]; then
  echo "handle_executor_batch_event.sh: legacy bridge recovery failed rc=${bridge_rc}; retained for tick" >&2
  bridge_result='{"status":"recovery_failed"}'
fi

set +e
"${BASH}" "${SCRIPT_DIR}/drain_executor_batch_notifications.sh" >/dev/null
notification_rc=$?
set -e
if [ "${notification_rc}" -ne 0 ]; then
  echo "handle_executor_batch_event.sh: notification drain failed rc=${notification_rc}; ack remains durable" >&2
fi

if [ "$(jq -r '.status // ""' <<<"${bridge_result}" 2>/dev/null)" = cleared ]; then
  set +e
  "${BASH}" "${SCRIPT_DIR}/run_executor_batch_tick.sh" >/dev/null
  tick_rc=$?
  set -e
  if [ "${tick_rc}" -ne 0 ]; then
    echo "handle_executor_batch_event.sh: follow-up tick failed rc=${tick_rc}; periodic tick will retry" >&2
  fi
fi
printf '%s\n' "${ack}"
