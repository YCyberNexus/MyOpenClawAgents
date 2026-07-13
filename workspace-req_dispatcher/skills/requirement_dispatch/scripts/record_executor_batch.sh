#!/usr/bin/env bash
# Persist a compact dispatcher-side mirror after executor accepts an I1 batch.
# The mirror stores only the batch fields consumed by dispatcher recovery.
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
: "${PROJECT:?record_executor_batch.sh: PROJECT required}"
: "${EXECUTOR_AGENT:?record_executor_batch.sh: EXECUTOR_AGENT required}"
: "${MATCHED_COUNT:?record_executor_batch.sh: MATCHED_COUNT required}"
: "${REQUEST_DIGEST:?record_executor_batch.sh: REQUEST_DIGEST required}"
ORIGIN_JSON="${ORIGIN_JSON:-null}"
CALLBACK_AUTH_MODE="${CALLBACK_AUTH_MODE:-nonce_v1}"
CALLBACK_NONCE_SHA256="${CALLBACK_NONCE_SHA256:-}"
ALLOW_LEGACY_PRE_UPGRADE="${ALLOW_LEGACY_PRE_UPGRADE:-false}"

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

if ! [[ "${PROJECT}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  record_die "PROJECT must be a safe multi-segment project path"
fi

case "${CALLBACK_AUTH_MODE}" in
  nonce_v1)
    if ! [[ "${CALLBACK_NONCE_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
      record_die "CALLBACK_NONCE_SHA256 is required for nonce_v1 mirrors"
    fi
    ;;
  legacy_pre_upgrade)
    [ "${ALLOW_LEGACY_PRE_UPGRADE}" = true ] \
      || record_die "legacy_pre_upgrade mirror creation requires explicit authorization"
    [ -z "${CALLBACK_NONCE_SHA256}" ] \
      || record_die "legacy_pre_upgrade mirrors must not carry a callback nonce digest"
    ;;
  *) record_die "CALLBACK_AUTH_MODE must be nonce_v1 or legacy_pre_upgrade" ;;
esac

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
      and (
        (keys | sort) == [
          "batch_id","created_at","executor_agent","matched_count","origin",
          "request_digest","status","terminal_count","updated_at"
        ]
        or (keys | sort) == [
          "batch_id","callback_auth_mode","callback_nonce_sha256","created_at",
          "executor_agent","matched_count","origin","project","request_digest",
          "status","terminal_count","updated_at"
        ]
      )
      and .batch_id == $batch_id
      and (.executor_agent | printable)
      and (if has("callback_auth_mode") then
        (
          (.callback_auth_mode == "nonce_v1"
            and (.project | printable
              and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
            and (.callback_nonce_sha256 | type == "string"
              and test("^[0-9a-f]{64}$")))
          or (.callback_auth_mode == "legacy_pre_upgrade"
            and (.project == null
              or (.project | printable
                and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$")))
            and .callback_nonce_sha256 == null)
        )
      else true end)
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
  needs_legacy_migration=false
  if ! jq -e '
    has("callback_auth_mode")
    and ((.callback_auth_mode != "legacy_pre_upgrade") or (.project != null))
  ' <<<"${existing_json}" >/dev/null; then
    needs_legacy_migration=true
  fi

  # Validate every immutable receipt fact against the original durable row
  # before publishing compatibility metadata. A conflicting replay must not be
  # able to bind a project or auth marker to a pre-upgrade mirror.
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

  if [ "${needs_legacy_migration}" = true ]; then
    [ "${CALLBACK_AUTH_MODE}" = legacy_pre_upgrade ] \
      || record_die "pre-upgrade mirror cannot be upgraded to nonce_v1" 3
  else
    if [ "$(jq -r '.project // ""' <<<"${existing_json}")" != "${PROJECT}" ]; then
      record_die "batch receipt conflicts with project: ${BATCH_ID}" 3
    fi
    if [ "$(jq -r '.callback_auth_mode // ""' <<<"${existing_json}")" != "${CALLBACK_AUTH_MODE}" ]; then
      record_die "batch receipt conflicts with callback_auth_mode: ${BATCH_ID}" 3
    fi
    if [ "$(jq -r '.callback_nonce_sha256 // ""' <<<"${existing_json}")" != "${CALLBACK_NONCE_SHA256}" ]; then
      record_die "batch receipt conflicts with callback nonce digest: ${BATCH_ID}" 3
    fi
  fi

  if [ "${needs_legacy_migration}" = true ]; then
    mirror_json="$(jq -c \
      --arg batch_id "${BATCH_ID}" \
      --arg project "${PROJECT}" '
      .batches[$batch_id] += {
        project:$project,
        callback_auth_mode:"legacy_pre_upgrade",
        callback_nonce_sha256:null
      }
    ' <<<"${mirror_json}")"
    migration_candidate="$(mktemp "${DISPATCHER_DIR}/executor_batches.migrate.XXXXXX")"
    printf '%s\n' "${mirror_json}" >"${migration_candidate}"
    jq -e . "${migration_candidate}" >/dev/null \
      || record_die "refusing to publish an invalid pre-upgrade mirror migration" 3
    mv "${migration_candidate}" "${EXECUTOR_BATCH_MIRROR_FILE}"
    existing_json="$(jq -c --arg batch_id "${BATCH_ID}" \
      '.batches[$batch_id]' <<<"${mirror_json}")"
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
  --arg project "${PROJECT}" \
  --arg executor_agent "${EXECUTOR_AGENT}" \
  --arg callback_auth_mode "${CALLBACK_AUTH_MODE}" \
  --arg callback_nonce_sha256 "${CALLBACK_NONCE_SHA256}" \
  --argjson origin "${ORIGIN_JSON}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --arg status "${batch_status}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg recorded_at "${recorded_at}" '
  .batches[$batch_id] = {
    batch_id:$batch_id,
    project:$project,
    executor_agent:$executor_agent,
    callback_auth_mode:$callback_auth_mode,
    callback_nonce_sha256:(if $callback_nonce_sha256 == "" then null else $callback_nonce_sha256 end),
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
