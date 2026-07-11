#!/usr/bin/env bash
# Persist a compact dispatcher-side mirror after executor accepts an I1 batch.
# This script deliberately has no GitLab credential input or output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

record_die() {
  echo "record_executor_batch.sh: $1" >&2
  exit "${2:-2}"
}

: "${BATCH_ID:?record_executor_batch.sh: BATCH_ID required}"
: "${EXECUTOR_AGENT:?record_executor_batch.sh: EXECUTOR_AGENT required}"
: "${MATCHED_COUNT:?record_executor_batch.sh: MATCHED_COUNT required}"
: "${REQUEST_DIGEST:?record_executor_batch.sh: REQUEST_DIGEST required}"
ORIGIN_JSON="${ORIGIN_JSON:-null}"

case "${MATCHED_COUNT}" in
  ''|*[!0-9]*) record_die "MATCHED_COUNT must be a non-negative integer" ;;
esac

if ! jq -en --arg value "${BATCH_ID}" '
  ($value | length > 0)
  and ($value | explode | all(. >= 32 and . != 127))
' >/dev/null; then
  record_die "BATCH_ID must be a non-empty printable string"
fi

if ! jq -en --arg value "${EXECUTOR_AGENT}" '
  ($value | length > 0)
  and ($value | explode | all(. >= 32 and . != 127))
' >/dev/null; then
  record_die "EXECUTOR_AGENT must be a non-empty printable string"
fi

if ! jq -en --arg value "${REQUEST_DIGEST}" '
  ($value | length > 0)
  and ($value | explode | all(. >= 32 and . != 127))
' >/dev/null; then
  record_die "REQUEST_DIGEST must be a non-empty printable string"
fi

if ! ORIGIN_JSON="$(jq -c '
  def printable:
    type == "string"
    and length > 0
    and (explode | all(. >= 32 and . != 127));
  if . == null then .
  elif type == "object"
    and ((keys - [
      "channel","conversation","reply_agent","source_agent",
      "source_session","user"
    ]) | length == 0)
    and all(to_entries[]; .value | printable)
  then .
  else error("origin must be an object or null")
  end
' <<<"${ORIGIN_JSON}" 2>/dev/null)"; then
  record_die "ORIGIN_JSON must contain only printable capture_origin metadata or null"
fi

exec 9>"${LOCK_FILE}"
flock 9

if ! mirror_json="$(jq -ce '
  if type == "object" and (.batches | type == "object") then .
  else error("invalid executor batch mirror")
  end
' "${EXECUTOR_BATCH_MIRROR_FILE}" 2>/dev/null)"; then
  record_die "executor batch mirror is invalid" 3
fi

existing_json="$(jq -c --arg batch_id "${BATCH_ID}" '.batches[$batch_id] // null' \
  <<<"${mirror_json}")"
if [ "${existing_json}" != null ]; then
  if ! existing_json="$(jq -ce --arg batch_id "${BATCH_ID}" '
    def printable:
      type == "string"
      and length > 0
      and (explode | all(. >= 32 and . != 127));
    def valid_origin:
      . == null
      or (type == "object"
        and ((keys - [
          "channel","conversation","reply_agent","source_agent",
          "source_session","user"
        ]) | length == 0)
        and all(to_entries[]; .value | printable));
    if type == "object"
      and (keys | sort) == [
        "batch_id","created_at","executor_agent","matched_count","origin",
        "request_digest","status","terminal_count","updated_at"
      ]
      and .batch_id == $batch_id
      and (.executor_agent | printable)
      and (.origin | valid_origin)
      and (.matched_count | type == "number" and . == floor and . >= 0)
      and (.terminal_count | type == "number" and . == floor and . >= 0)
      and .terminal_count <= .matched_count
      and (.status == "resolving" or .status == "queued"
        or .status == "running" or .status == "completed"
        or .status == "failed" or .status == "waiting_for_legacy_drain")
      and (if .status == "completed"
        then .terminal_count == .matched_count else true end)
      and (.request_digest | printable)
      and (.created_at | printable)
      and (.updated_at | printable)
    then .
    else error("invalid batch mirror entry")
    end
  ' <<<"${existing_json}" 2>/dev/null)"; then
    record_die "existing batch mirror entry is invalid: ${BATCH_ID}" 3
  fi
  existing_digest="$(jq -r '.request_digest // empty' <<<"${existing_json}")"
  if [ "${existing_digest}" != "${REQUEST_DIGEST}" ]; then
    record_die "batch ID conflicts with a different request digest: ${BATCH_ID}" 3
  fi
  if [ "$(jq -r '.executor_agent' <<<"${existing_json}")" != "${EXECUTOR_AGENT}" ]; then
    record_die "batch receipt conflicts with executor_agent: ${BATCH_ID}" 3
  fi
  if [ "$(jq -r '.matched_count' <<<"${existing_json}")" != "${MATCHED_COUNT}" ]; then
    record_die "batch receipt conflicts with matched_count: ${BATCH_ID}" 3
  fi
  if [ "$(jq -cS '.origin' <<<"${existing_json}")" != "$(jq -cS . <<<"${ORIGIN_JSON}")" ]; then
    record_die "batch receipt conflicts with origin: ${BATCH_ID}" 3
  fi
  flock -u 9
  jq -cn --arg batch_id "${BATCH_ID}" '{status:"duplicate",batch_id:$batch_id}'
  exit 0
fi

recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "${MATCHED_COUNT}" -eq 0 ]; then
  batch_status="completed"
else
  batch_status="queued"
fi

next_mirror="$(jq -c \
  --arg batch_id "${BATCH_ID}" \
  --arg executor_agent "${EXECUTOR_AGENT}" \
  --argjson origin "${ORIGIN_JSON}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --arg status "${batch_status}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg recorded_at "${recorded_at}" '
  .batches[$batch_id] = {
    batch_id:$batch_id,
    executor_agent:$executor_agent,
    origin:$origin,
    matched_count:$matched_count,
    terminal_count:0,
    status:$status,
    request_digest:$request_digest,
    created_at:$recorded_at,
    updated_at:$recorded_at
  }
' <<<"${mirror_json}")"

candidate="$(mktemp "${DISPATCHER_DIR}/executor_batches.XXXXXX")"
printf '%s\n' "${next_mirror}" >"${candidate}"
jq -e . "${candidate}" >/dev/null \
  || record_die "refusing to publish an invalid executor batch mirror" 3
mv "${candidate}" "${EXECUTOR_BATCH_MIRROR_FILE}"
flock -u 9

jq -cn --arg batch_id "${BATCH_ID}" '{status:"accepted",batch_id:$batch_id}'
