#!/usr/bin/env bash
# Deliver durable driven-batch callback entries. A strict same-event
# accepted/duplicate acknowledgement marks delivered_at, then the entry moves
# from the hot outbox to the directly addressable cold archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
DELIVERY_TIMEOUT_SECONDS="${DRIVEN_CALLBACK_TIMEOUT_SECONDS:-300}"
ATTEMPT_BUDGET="${DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK:-3}"
BACKOFF_BASE_SECONDS="${DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS:-30}"
BACKOFF_MAX_SECONDS="${DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS:-3600}"
ACCEPTANCE_CMD="${DRIVEN_ACCEPTANCE_CMD:-${SCRIPT_DIR}/emit_driven_batch_acceptance.sh}"
NOW_EPOCH_PROCESS_SET="${NOW_EPOCH+x}"
DRAIN_NOW="${NOW_EPOCH:-$(date +%s)}"
ACK_ONLY_INSTRUCTION='ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。'

drain_die() {
  echo "drain_driven_outbox.sh: $1" >&2
  exit "${2:-2}"
}

case "${ACCEPTANCE_CMD}" in
  /*) ;;
  *) drain_die "DRIVEN_ACCEPTANCE_CMD must be absolute" ;;
esac
case "${ACCEPTANCE_CMD}" in
  *$'\n'*|*$'\r'*|*$'\t'*) drain_die "DRIVEN_ACCEPTANCE_CMD contains control characters" ;;
esac
[ -f "${ACCEPTANCE_CMD}" ] && [ -x "${ACCEPTANCE_CMD}" ] \
  || drain_die "DRIVEN_ACCEPTANCE_CMD must be an executable regular file"

atomic_write_json() {
  local destination="$1"
  local json="$2"
  local destination_dir destination_name candidate

  destination_dir="$(dirname "${destination}")"
  destination_name="$(basename "${destination}")"
  candidate="$(mktemp "${destination_dir}/.${destination_name}.XXXXXX")"
  printf '%s\n' "${json}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null \
    || drain_die "refusing to publish invalid JSON for ${destination_name}" 3
  mv "${candidate}" "${destination}"
}

archive_delivered_entry() {
  local hot_file="$1" entry_name="$2"
  local archive_file="${CALLBACK_ARCHIVE}/${entry_name}.json"

  if [ -e "${archive_file}" ]; then
    cmp -s "${hot_file}" "${archive_file}" \
      || drain_die "delivered archive conflicts with hot outbox: ${entry_name}" 3
  fi
  # Moving the byte-identical hot copy over an existing archive is deliberate:
  # it completes the crash window without an unsafe unlink operation.
  mv "${hot_file}" "${archive_file}"
}

retry_delay_seconds() {
  local prior_attempts="$1"
  local delay="${BACKOFF_BASE_SECONDS}"
  local exponent="${prior_attempts}"

  while [ "${exponent}" -gt 0 ] && [ "${delay}" -lt "${BACKOFF_MAX_SECONDS}" ]; do
    if [ "${delay}" -gt $((BACKOFF_MAX_SECONDS / 2)) ]; then
      delay="${BACKOFF_MAX_SECONDS}"
    else
      delay=$((delay * 2))
    fi
    exponent=$((exponent - 1))
  done
  [ "${delay}" -le "${BACKOFF_MAX_SECONDS}" ] || delay="${BACKOFF_MAX_SECONDS}"
  printf '%s\n' "${delay}"
}

current_epoch() {
  if [ "${NOW_EPOCH_PROCESS_SET}" = x ]; then
    printf '%s\n' "${DRAIN_NOW}"
  else
    date +%s
  fi
}

load_entry_json() {
  local entry_file="$1" expected_event_id="$2"

  jq -ce --arg expected_event_id "${expected_event_id}" '
    if type == "object"
      and .version == 1
      and (.event_id | type == "string" and length > 0)
      and .event_id == $expected_event_id
      and (.target | type == "string"
        and test("^agent:req_dispatcher:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
      and ((has("callback_auth_mode") | not)
        or .callback_auth_mode == "nonce_v1"
        or .callback_auth_mode == "legacy_pre_upgrade")
      and (
        (((.callback_auth_mode //
            (if has("executor_agent") or has("callback_nonce")
             then "nonce_v1" else "legacy_pre_upgrade" end)) == "nonce_v1")
          and (.executor_agent | type == "string"
            and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
          and (.callback_nonce | type == "string" and test("^[0-9a-f]{64}$")))
        or
        (((.callback_auth_mode // "legacy_pre_upgrade") == "legacy_pre_upgrade")
          and (has("executor_agent") | not)
          and (has("callback_nonce") | not)))
      and (.body | type == "object")
      and (.body | keys | sort) == [
        "batch_id","event_id","iid","mr_url","project","reason","snapshot_index","status"
      ]
      and .body.event_id == .event_id
      and (.attempts | type == "number" and . == floor and . >= 0)
      and ((.last_error == null) or (.last_error | type == "string"))
      and ((.delivered_at == null)
        or (.delivered_at | type == "number" and . == floor and . >= 0))
      and ((.ready_at == null)
        or (.ready_at | type == "number" and . == floor and . >= 0))
      and ((has("next_attempt_at") | not) or (.next_attempt_at == null)
        or (.next_attempt_at | type == "number" and . == floor and . >= 0))
      and ((has("delivery_attempt") | not) or (.delivery_attempt == null)
        or (.delivery_attempt as $attempt
          | ($attempt | type == "object")
          and ($attempt | keys | sort) == ["attempt_id","expires_at","started_at"]
          and ($attempt.attempt_id | type == "string" and test("^[0-9a-f]{64}$"))
          and ($attempt.started_at | type == "number" and . == floor and . >= 0)
          and ($attempt.expires_at | type == "number" and . == floor and . >= 0)
          and $attempt.expires_at > $attempt.started_at))
      and (.created_at | type == "number" and . == floor and . >= 0)
      and (.updated_at | type == "number" and . == floor and . >= 0)
    then .
    else error("invalid outbox entry")
    end
  ' "${entry_file}" 2>/dev/null
}

acquire_entry_locks() {
  local mode="$1"

  unset ENTRY_LEGACY_LOCK_FD ENTRY_LOCK_FD
  if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ]; then
    exec {ENTRY_LEGACY_LOCK_FD}>"${entry_legacy_lock_file}"
    flock -x "${ENTRY_LEGACY_LOCK_FD}"
  fi
  exec {ENTRY_LOCK_FD}>"${entry_lock_file}"
  if [ "${mode}" = blocking ]; then
    flock -x "${ENTRY_LOCK_FD}"
    return 0
  fi
  if flock -n "${ENTRY_LOCK_FD}"; then
    return 0
  fi
  exec {ENTRY_LOCK_FD}>&-
  unset ENTRY_LOCK_FD
  if [ -n "${ENTRY_LEGACY_LOCK_FD:-}" ]; then
    flock -u "${ENTRY_LEGACY_LOCK_FD}"
    exec {ENTRY_LEGACY_LOCK_FD}>&-
    unset ENTRY_LEGACY_LOCK_FD
  fi
  return 1
}

release_entry_locks() {
  flock -u "${ENTRY_LOCK_FD}" 2>/dev/null || true
  exec {ENTRY_LOCK_FD}>&-
  unset ENTRY_LOCK_FD
  if [ -n "${ENTRY_LEGACY_LOCK_FD:-}" ]; then
    flock -u "${ENTRY_LEGACY_LOCK_FD}" 2>/dev/null || true
    exec {ENTRY_LEGACY_LOCK_FD}>&-
    unset ENTRY_LEGACY_LOCK_FD
  fi
}

case "${DELIVERY_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*) drain_die "DRIVEN_CALLBACK_TIMEOUT_SECONDS must be a positive integer" ;;
esac
if [[ "${DELIVERY_TIMEOUT_SECONDS}" =~ ^0+$ ]]; then
  drain_die "DRIVEN_CALLBACK_TIMEOUT_SECONDS must be a positive integer"
fi
for positive_setting in \
  "DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK:${ATTEMPT_BUDGET}" \
  "DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS:${BACKOFF_BASE_SECONDS}" \
  "DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS:${BACKOFF_MAX_SECONDS}"
do
  setting_name="${positive_setting%%:*}"
  setting_value="${positive_setting#*:}"
  case "${setting_value}" in
    ''|*[!0-9]*) drain_die "${setting_name} must be a positive integer" ;;
  esac
  [[ "${setting_value}" =~ ^0+$ ]] \
    && drain_die "${setting_name} must be a positive integer"
done
case "${DRAIN_NOW}" in
  ''|*[!0-9]*) drain_die "NOW_EPOCH must be a non-negative integer" ;;
esac
[ "${BACKOFF_BASE_SECONDS}" -le "${BACKOFF_MAX_SECONDS}" ] \
  || drain_die "DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS must not exceed DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS"

# scheduler_env initializes and exports callback paths under its own short
# lock. It releases that lock before this script acquires an independent
# per-entry outbox lock or performs any network call.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null

shopt -s nullglob
OUTBOX_FILES=("${CALLBACK_OUTBOX}"/*.json)

SCANNED_COUNT=0
ATTEMPTED_COUNT=0
DELIVERED_COUNT=0
FAILED_COUNT=0

for outbox_file in "${OUTBOX_FILES[@]}"; do
  [ "${ATTEMPTED_COUNT}" -lt "${ATTEMPT_BUDGET}" ] || break
  SCANNED_COUNT=$((SCANNED_COUNT + 1))
  entry_name="$(basename "${outbox_file}" .json)"
  entry_lock_digest="$(printf '%s' "${entry_name}" | scheduler_sha256_text)"
  entry_lock_file="${CALLBACK_LOCKS}/${entry_lock_digest}.lock"
  entry_legacy_lock_file="${CALLBACK_OUTBOX}/.${entry_name}.lock"
  acquire_entry_locks nonblocking || continue

  # A concurrent drainer may have delivered and archived the entry after this
  # process snapshotted the hot directory but before it acquired the event lock.
  if [ ! -f "${outbox_file}" ]; then
    release_entry_locks
    continue
  fi

  # Always re-read after acquiring the event lock. Another drain or importer
  # may have advanced delivered_at/ready_at after the initial directory scan.
  if ! entry_json="$(load_entry_json "${outbox_file}" "${entry_name}")"; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "drain_driven_outbox.sh: invalid outbox entry retained: ${outbox_file}" >&2
    release_entry_locks
    continue
  fi

  callback_auth_mode="$(jq -r '
    .callback_auth_mode //
      (if has("executor_agent") or has("callback_nonce")
       then "nonce_v1" else "legacy_pre_upgrade" end)
  ' <<<"${entry_json}")"
  if [ "$(jq -r 'has("callback_auth_mode")' <<<"${entry_json}")" != true ]; then
    # The private scheduler directory is the compatibility trust boundary.
    # Supported new intake always persists nonce fields, so an exact old shape
    # without them is upgraded once to an explicit legacy classification.
    entry_json="$(jq -c --arg mode "${callback_auth_mode}" \
      '.callback_auth_mode = $mode' <<<"${entry_json}")"
    atomic_write_json "${outbox_file}" "${entry_json}"
  fi

  if [ "$(jq -r '.delivered_at != null' <<<"${entry_json}")" = true ]; then
    archive_delivered_entry "${outbox_file}" "${entry_name}"
    release_entry_locks
    continue
  fi
  if [ "$(jq -r '.ready_at == null' <<<"${entry_json}")" = true ]; then
    release_entry_locks
    continue
  fi

  attempt_started_at="$(current_epoch)"
  next_attempt_at="$(jq -r '.next_attempt_at // .ready_at // 0' <<<"${entry_json}")"
  if [ "${next_attempt_at}" -gt "${attempt_started_at}" ]; then
    release_entry_locks
    continue
  fi

  active_attempt_expires_at="$(jq -r '.delivery_attempt.expires_at // 0' <<<"${entry_json}")"
  if [ "${active_attempt_expires_at}" -gt "${attempt_started_at}" ]; then
    release_entry_locks
    continue
  fi

  ATTEMPTED_COUNT=$((ATTEMPTED_COUNT + 1))
  event_id="$(jq -r '.event_id' <<<"${entry_json}")"
  callback_target="$(jq -r '.target' <<<"${entry_json}")"
  executor_agent="$(jq -r '.executor_agent // empty' <<<"${entry_json}")"
  callback_nonce="$(jq -r '.callback_nonce // empty' <<<"${entry_json}")"
  public_body="$(jq -cS '.body' <<<"${entry_json}")"

  target_agent=req_dispatcher
  target_session_key="${callback_target}"

  delivery_error=""
  ack_output=""
  delivery_rc=0
  if [ "${callback_auth_mode}" = nonce_v1 ] \
      && { [ "${callback_target}" != "${DISPATCHER_CALLBACK_TARGET}" ] \
        || [ "${executor_agent}" != "${EXECUTOR_AGENT}" ]; }; then
    delivery_error="invalid_callback_target"
  elif ! command -v "${OPENCLAW_BIN}" >/dev/null 2>&1; then
    delivery_error="openclaw_not_found"
  fi

  batch_acceptance=null
  if [ -z "${delivery_error}" ] && [ "${callback_auth_mode}" = nonce_v1 ]; then
    batch_id="$(jq -r '.batch_id' <<<"${public_body}")"
    snapshot_index="$(jq -r '.snapshot_index' <<<"${public_body}")"
    set +e
    acceptance_output="$(
      CONFIG_DIR="${CONFIG_DIR}" BATCH_ID="${batch_id}" \
        bash "${ACCEPTANCE_CMD}" 2>/dev/null
    )"
    acceptance_rc=$?
    set -e
    if [ "${acceptance_rc}" -ne 0 ] || ! batch_acceptance="$(
      printf '%s' "${acceptance_output}" | jq -cseS \
        --arg batch_id "${batch_id}" \
        --argjson snapshot_index "${snapshot_index}" '
        if length == 1
          and (.[0] | type == "object")
          and ((.[0] | keys | sort) == [
            "batch_id","matched_count","scheduler_status","snapshot_digest","status"
          ])
          and .[0].status == "success"
          and .[0].batch_id == $batch_id
          and (.[0].matched_count | type == "number"
            and . == floor and . > $snapshot_index)
          and (.[0].snapshot_digest | type == "string"
            and test("^[0-9a-f]{64}$"))
          and (.[0].scheduler_status == "queued"
            or .[0].scheduler_status == "running"
            or .[0].scheduler_status == "completed")
        then .[0]
        else error("invalid callback acceptance")
        end
      ' 2>/dev/null
    )"; then
      delivery_error="batch_acceptance_unavailable"
      batch_acceptance=null
    fi
  fi

  if [ -n "${delivery_error}" ]; then
    attempted_at="$(current_epoch)"
    retry_delay="$(retry_delay_seconds "$(jq -r '.attempts' <<<"${entry_json}")")"
    retry_at=$((attempted_at + retry_delay))
    next_entry="$(jq -c \
      --arg delivery_error "${delivery_error}" \
      --argjson attempted_at "${attempted_at}" \
      --argjson retry_at "${retry_at}" '
      .attempts += 1
      | .last_error = $delivery_error
      | .delivered_at = null
      | .next_attempt_at = $retry_at
      | .updated_at = $attempted_at
      | del(.delivery_attempt)
    ' <<<"${entry_json}")"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    atomic_write_json "${outbox_file}" "${next_entry}"
    release_entry_locks
    continue
  fi

  if [ "${callback_auth_mode}" = nonce_v1 ]; then
    callback_envelope="$(jq -cnS \
      --arg callback_nonce "${callback_nonce}" \
      --arg executor_agent "${executor_agent}" \
      --argjson batch_acceptance "${batch_acceptance}" \
      --argjson worker_result_json "${public_body}" '{
        batch_acceptance:$batch_acceptance,
        callback_nonce:$callback_nonce,
        executor_agent:$executor_agent,
        worker_result_json:$worker_result_json
      }')"
    callback_message="$(printf 'RUN_DRIVEN_BATCH_RESULT_ACK_ONLY\ncallback_envelope=%s\n%s\n' \
      "${callback_envelope}" "${ACK_ONLY_INSTRUCTION}")"
  else
    callback_message="$(printf 'RUN_DRIVEN_BATCH_RESULT_ACK_ONLY\nworker_result_json=%s\n%s\n' \
      "${public_body}" "${ACK_ONLY_INSTRUCTION}")"
  fi
  attempt_id="$(printf '%s' \
    "${event_id}:${attempt_started_at}:$$:${RANDOM}:$(jq -r '.attempts' <<<"${entry_json}")" \
    | scheduler_sha256_text)"
  attempt_expires_at=$((attempt_started_at + DELIVERY_TIMEOUT_SECONDS + 30))
  leased_entry="$(jq -c \
    --arg attempt_id "${attempt_id}" \
    --argjson started_at "${attempt_started_at}" \
    --argjson expires_at "${attempt_expires_at}" '
    .delivery_attempt = {
      attempt_id:$attempt_id,
      started_at:$started_at,
      expires_at:$expires_at
    }
    | .updated_at = $started_at
  ' <<<"${entry_json}")"
  atomic_write_json "${outbox_file}" "${leased_entry}"
  release_entry_locks

  set +e
  ack_output="$(
    printf '%s' "${callback_message}" | env \
      OPENCLAW_BIN="${OPENCLAW_BIN}" \
      OPENCLAW_TARGET_AGENT="${target_agent}" \
      OPENCLAW_TARGET_SESSION_KEY="${target_session_key}" \
      OPENCLAW_AGENT_TIMEOUT_SECONDS="${DELIVERY_TIMEOUT_SECONDS}" \
      OPENCLAW_RUN_ID="driven-callback-${attempt_id}" \
      OPENCLAW_STRICT_JSON_RECEIPT="${OPENCLAW_STRICT_JSON_RECEIPT:-1}" \
      "${SCRIPT_DIR}/openclaw_agent_transport.sh"
  )"
  delivery_rc=$?
  set -e
  if [ "${delivery_rc}" -ne 0 ]; then
    delivery_error="openclaw_exit_${delivery_rc}"
  elif [ -n "${callback_nonce}" ] && [[ "${ack_output}" == *"${callback_nonce}"* ]]; then
    delivery_error="callback_nonce_echo"
  else
    ack_candidate="${ack_output}"
    json_fence_prefix=$'```json\n'
    plain_fence_prefix=$'```\n'
    fence_suffix=$'\n```'
    if [[ "${ack_output}" == "${json_fence_prefix}"*"${fence_suffix}" ]]; then
      ack_candidate="${ack_output#"${json_fence_prefix}"}"
      ack_candidate="${ack_candidate%"${fence_suffix}"}"
    elif [[ "${ack_output}" == "${plain_fence_prefix}"*"${fence_suffix}" ]]; then
      ack_candidate="${ack_output#"${plain_fence_prefix}"}"
      ack_candidate="${ack_candidate%"${fence_suffix}"}"
    fi
    if ! normalized_ack="$(printf '%s' "${ack_candidate}" | jq -cse --arg event_id "${event_id}" '
    def valid_ack:
      type == "object"
      and (keys | sort) == ["event_id","status"]
      and ((.status == "accepted") or (.status == "duplicate"))
      and .event_id == $event_id;
    if length == 1 and (.[0] | valid_ack)
      then .[0]
      else error("missing or ambiguous ack")
    end
  ' 2>/dev/null)"; then
      delivery_error="malformed_or_ambiguous_ack"
    fi
  fi

  attempted_at="$(current_epoch)"
  acquire_entry_locks blocking
  if [ ! -f "${outbox_file}" ]; then
    # A newer, expired-lease retry may already have delivered and archived the
    # event. Its fence is authoritative; this late network return cannot write.
    release_entry_locks
    continue
  fi
  if ! entry_json="$(load_entry_json "${outbox_file}" "${entry_name}")"; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "drain_driven_outbox.sh: invalid outbox entry retained after delivery: ${outbox_file}" >&2
    release_entry_locks
    continue
  fi
  if [ "$(jq -r '.delivery_attempt.attempt_id // empty' <<<"${entry_json}")" \
      != "${attempt_id}" ]; then
    # The lease expired and another drainer fenced this attempt. A valid ack is
    # still harmless because dispatcher event IDs are idempotent, but only the
    # current durable attempt owner may commit outbox state.
    release_entry_locks
    continue
  fi

  if [ -z "${delivery_error}" ]; then
    next_entry="$(jq -c \
      --argjson attempted_at "${attempted_at}" '
      .attempts += 1
      | .last_error = null
      | .delivered_at = $attempted_at
      | .next_attempt_at = null
      | .updated_at = $attempted_at
      | del(.delivery_attempt)
    ' <<<"${entry_json}")"
    DELIVERED_COUNT=$((DELIVERED_COUNT + 1))
  else
    retry_delay="$(retry_delay_seconds "$(jq -r '.attempts' <<<"${entry_json}")")"
    retry_at=$((attempted_at + retry_delay))
    next_entry="$(jq -c \
      --arg delivery_error "${delivery_error}" \
      --argjson attempted_at "${attempted_at}" \
      --argjson retry_at "${retry_at}" '
      .attempts += 1
      | .last_error = $delivery_error
      | .delivered_at = null
      | .next_attempt_at = $retry_at
      | .updated_at = $attempted_at
      | del(.delivery_attempt)
    ' <<<"${entry_json}")"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
  atomic_write_json "${outbox_file}" "${next_entry}"
  if [ -z "${delivery_error}" ]; then
    archive_delivered_entry "${outbox_file}" "${entry_name}"
  fi
  release_entry_locks
done

jq -cn \
  --argjson scanned "${SCANNED_COUNT}" \
  --argjson attempted "${ATTEMPTED_COUNT}" \
  --argjson delivered "${DELIVERED_COUNT}" \
  --argjson failed "${FAILED_COUNT}" '{
    status:"drained",
    scanned:$scanned,
    attempted:$attempted,
    delivered:$delivered,
    failed:$failed
  }'
