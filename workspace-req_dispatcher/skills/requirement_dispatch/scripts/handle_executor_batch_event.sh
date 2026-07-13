#!/usr/bin/env bash
# Fixed public I3 handler: strict transport unwrap, durable apply, then return
# the same-event ack. Periodic ticks recover bridges and drain notifications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

handler_die() {
  echo "handle_executor_batch_event.sh: $1" >&2
  exit "${2:-2}"
}

CALLBACK_INPUT="${CALLBACK_ENVELOPE_JSON:-${callback_envelope:-${WORKER_RESULT_JSON:-${worker_result_json:-}}}}"
INPUT_WAS_EXPLICIT_ENVELOPE=false
if [ -n "${CALLBACK_ENVELOPE_JSON:-${callback_envelope:-}}" ]; then
  INPUT_WAS_EXPLICIT_ENVELOPE=true
fi
if [ -z "${CALLBACK_INPUT}" ] && [ "$#" -gt 0 ]; then
  CALLBACK_INPUT="$1"
fi
if [ -z "${CALLBACK_INPUT}" ] && [ ! -t 0 ]; then
  CALLBACK_INPUT="$(cat)"
fi
[ -n "${CALLBACK_INPUT}" ] \
  || handler_die "CALLBACK_ENVELOPE_JSON or RUN_DRIVEN_BATCH_RESULT input required"

TRANSPORT_MODE=auto
TRANSPORT_JSON="${CALLBACK_INPUT}"
ACK_ONLY_MARKER=RUN_DRIVEN_BATCH_RESULT_ACK_ONLY
LEGACY_MARKER=RUN_DRIVEN_BATCH_RESULT
ACK_ONLY_INSTRUCTION='ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。'
TRANSPORT_WRAPPED=false
if [[ "${CALLBACK_INPUT}" == "${ACK_ONLY_MARKER}"$'\n'* ]]; then
  trigger_body="${CALLBACK_INPUT#${ACK_ONLY_MARKER}$'\n'}"
  TRANSPORT_MARKER_MODE=ack_only
  TRANSPORT_WRAPPED=true
elif [[ "${CALLBACK_INPUT}" == "${LEGACY_MARKER}"$'\n'* ]]; then
  trigger_body="${CALLBACK_INPUT#${LEGACY_MARKER}$'\n'}"
  TRANSPORT_MARKER_MODE=legacy
  TRANSPORT_WRAPPED=true
elif [[ "${CALLBACK_INPUT}" == "${ACK_ONLY_MARKER}"* ]] \
    || [[ "${CALLBACK_INPUT}" == "${LEGACY_MARKER}"* ]]; then
  handler_die "RUN_DRIVEN_BATCH_RESULT callback marker transport shape is invalid"
fi

if [ "${TRANSPORT_WRAPPED}" = true ]; then
  case "${TRANSPORT_MARKER_MODE}" in
    ack_only)
      case "${trigger_body}" in
        *$'\n'*)
          transport_line="${trigger_body%%$'\n'*}"
          instruction_line="${trigger_body#*$'\n'}"
          ;;
        *) handler_die "ACK_ONLY transport requires the fixed third-line instruction" ;;
      esac
      case "${instruction_line}" in
        *$'\n'*) handler_die "ACK_ONLY transport must contain exactly three lines" ;;
      esac
      [ "${instruction_line}" = "${ACK_ONLY_INSTRUCTION}" ] \
        || handler_die "ACK_ONLY transport instruction is missing or invalid"
      ;;
    legacy)
      transport_line="${trigger_body}"
      case "${transport_line}" in
        *$'\n'*) handler_die "legacy callback marker must contain exactly two lines" ;;
      esac
      ;;
  esac
  case "${transport_line}" in
    callback_envelope=*) TRANSPORT_MODE=authenticated ;;
    worker_result_json=*) TRANSPORT_MODE=legacy_pre_upgrade ;;
    *) handler_die "callback marker must contain exactly one callback transport line" ;;
  esac
  case "${TRANSPORT_MODE}" in
    authenticated) TRANSPORT_JSON="${transport_line#callback_envelope=}" ;;
    legacy_pre_upgrade) TRANSPORT_JSON="${transport_line#worker_result_json=}" ;;
  esac
  [ -n "${TRANSPORT_JSON}" ] \
    || handler_die "callback marker transport must not be empty"
elif [ "${INPUT_WAS_EXPLICIT_ENVELOPE}" = true ]; then
  TRANSPORT_MODE=authenticated
fi

if [ "${TRANSPORT_MODE}" = auto ]; then
  if jq -e '
    type == "object"
    and (keys | sort) == ["callback_nonce","executor_agent","worker_result_json"]
  ' <<<"${TRANSPORT_JSON}" >/dev/null 2>&1; then
    TRANSPORT_MODE=authenticated
  else
    TRANSPORT_MODE=legacy_pre_upgrade
  fi
fi

if [ "${TRANSPORT_MODE}" = authenticated ]; then
  if ! CALLBACK_ENVELOPE="$(jq -cseS '
    def printable:
      type == "string" and length > 0
      and (explode | all(. >= 32 and . != 127));
    def public_i3:
      type == "object"
      and (keys | sort) == [
        "batch_id","event_id","iid","mr_url","project","reason",
        "snapshot_index","status"
      ];
    if length == 1
      and (.[0] | type == "object")
      and ((.[0] | keys | sort) == [
        "callback_nonce","executor_agent","worker_result_json"
      ])
      and (.[0].callback_nonce | type == "string"
        and test("^[0-9a-f]{64}$"))
      and (.[0].executor_agent | printable)
      and (.[0].worker_result_json | public_i3)
    then .[0]
    else error("invalid authenticated callback envelope")
    end
  ' <<<"${TRANSPORT_JSON}" 2>/dev/null)"; then
    handler_die "callback_envelope must be the exact authenticated callback object"
  fi
else
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
  ' <<<"${TRANSPORT_JSON}" 2>/dev/null)"; then
    handler_die "worker_result_json must be exactly one public I3 object with eight fields"
  fi
fi

# The authenticated transport is needed only by the durable apply subprocess.
# Remove caller-provided envelope variables before bridge/notification children
# can inherit the nonce-bearing value.
unset CALLBACK_ENVELOPE_JSON callback_envelope WORKER_RESULT_JSON worker_result_json
unset CALLBACK_INPUT TRANSPORT_JSON trigger_body transport_line instruction_line
unset ACK_ONLY_MARKER LEGACY_MARKER ACK_ONLY_INSTRUCTION
unset TRANSPORT_WRAPPED TRANSPORT_MARKER_MODE

set +e
if [ "${TRANSPORT_MODE}" = authenticated ]; then
  ack="$(
    CALLBACK_ENVELOPE_JSON="${CALLBACK_ENVELOPE}" \
      "${BASH}" "${SCRIPT_DIR}/apply_executor_batch_event.sh"
  )"
else
  ack="$(
    WORKER_RESULT_JSON="${PUBLIC_I3_JSON}" \
      "${BASH}" "${SCRIPT_DIR}/apply_executor_batch_event.sh"
  )"
fi
apply_rc=$?
set -e
if [ "${apply_rc}" -ne 0 ]; then
  [ -z "${ack}" ] || printf '%s\n' "${ack}"
  exit "${apply_rc}"
fi
unset CALLBACK_ENVELOPE PUBLIC_I3_JSON
if ! jq -e '
  type == "object"
  and (keys | sort) == ["event_id","status"]
  and (.status == "accepted" or .status == "duplicate")
  and (.event_id | type == "string" and length > 0)
' <<<"${ack}" >/dev/null; then
  echo "handle_executor_batch_event.sh: apply returned an invalid ack" >&2
  exit 3
fi

# The durable apply is the I3 acknowledgement boundary. Bridge recovery,
# notification delivery, and follow-up scheduling are periodic tick work; none
# may delay or contaminate the executor-facing ack.
printf '%s\n' "${ack}"
