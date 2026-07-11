#!/usr/bin/env bash
# Deliver durable driven-batch callback entries. Entries are never deleted;
# only a strict same-event accepted/duplicate acknowledgement marks delivered_at.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
DELIVERY_TIMEOUT_SECONDS="${DRIVEN_CALLBACK_TIMEOUT_SECONDS:-300}"

drain_die() {
  echo "drain_driven_outbox.sh: $1" >&2
  exit "${2:-2}"
}

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

case "${DELIVERY_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*) drain_die "DRIVEN_CALLBACK_TIMEOUT_SECONDS must be a positive integer" ;;
esac
if [[ "${DELIVERY_TIMEOUT_SECONDS}" =~ ^0+$ ]]; then
  drain_die "DRIVEN_CALLBACK_TIMEOUT_SECONDS must be a positive integer"
fi

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
  SCANNED_COUNT=$((SCANNED_COUNT + 1))
  entry_name="$(basename "${outbox_file}" .json)"
  entry_lock_file="${CALLBACK_OUTBOX}/.${entry_name}.lock"
  exec {ENTRY_LOCK_FD}>"${entry_lock_file}"
  if ! flock -n "${ENTRY_LOCK_FD}"; then
    exec {ENTRY_LOCK_FD}>&-
    continue
  fi

  # Always re-read after acquiring the event lock. Another drain or importer
  # may have advanced delivered_at/ready_at after the initial directory scan.
  if ! entry_json="$(jq -ce --arg expected_event_id "${entry_name}" '
    if type == "object"
      and .version == 1
      and (.event_id | type == "string" and length > 0)
      and .event_id == $expected_event_id
      and (.target | type == "string" and length > 0)
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
      and (.created_at | type == "number" and . == floor and . >= 0)
      and (.updated_at | type == "number" and . == floor and . >= 0)
    then .
    else error("invalid outbox entry")
    end
  ' "${outbox_file}" 2>/dev/null)"; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "drain_driven_outbox.sh: invalid outbox entry retained: ${outbox_file}" >&2
    flock -u "${ENTRY_LOCK_FD}"
    exec {ENTRY_LOCK_FD}>&-
    continue
  fi

  if [ "$(jq -r '.delivered_at != null' <<<"${entry_json}")" = true ]; then
    flock -u "${ENTRY_LOCK_FD}"
    exec {ENTRY_LOCK_FD}>&-
    continue
  fi
  if [ "$(jq -r '.ready_at == null' <<<"${entry_json}")" = true ]; then
    flock -u "${ENTRY_LOCK_FD}"
    exec {ENTRY_LOCK_FD}>&-
    continue
  fi

  ATTEMPTED_COUNT=$((ATTEMPTED_COUNT + 1))
  event_id="$(jq -r '.event_id' <<<"${entry_json}")"
  callback_target="$(jq -r '.target' <<<"${entry_json}")"
  public_body="$(jq -cS '.body' <<<"${entry_json}")"

  target_agent="${callback_target}"
  target_session_key=""
  case "${callback_target}" in
    agent:*:*)
      target_session_key="${callback_target}"
      target_rest="${callback_target#agent:}"
      target_agent="${target_rest%%:*}"
      ;;
  esac

  delivery_error=""
  ack_output=""
  delivery_rc=0
  if [ -z "${target_agent}" ]; then
    delivery_error="invalid_callback_target"
  elif ! command -v "${OPENCLAW_BIN}" >/dev/null 2>&1; then
    delivery_error="openclaw_not_found"
  else
    callback_message="$(printf 'RUN_DRIVEN_BATCH_RESULT\nworker_result_json=%s\n' "${public_body}")"
    openclaw_args=(agent --agent "${target_agent}")
    if [ -n "${target_session_key}" ]; then
      openclaw_args+=(--session-key "${target_session_key}")
    fi
    openclaw_args+=(--message "${callback_message}" --timeout "${DELIVERY_TIMEOUT_SECONDS}")

    set +e
    ack_output="$("${OPENCLAW_BIN}" "${openclaw_args[@]}")"
    delivery_rc=$?
    set -e
    if [ "${delivery_rc}" -ne 0 ]; then
      delivery_error="openclaw_exit_${delivery_rc}"
    elif ! jq -se --arg event_id "${event_id}" '
      length == 1
      and (.[0]
        | type == "object"
        and (keys | sort) == ["event_id","status"]
        and ((.status == "accepted") or (.status == "duplicate"))
        and .event_id == $event_id)
    ' <<<"${ack_output}" >/dev/null 2>&1; then
      if ! jq -e . <<<"${ack_output}" >/dev/null 2>&1; then
        delivery_error="malformed_or_empty_ack"
      elif ! jq -e '
          (.status == "accepted") or (.status == "duplicate")
        ' <<<"${ack_output}" >/dev/null 2>&1; then
        delivery_error="ack_not_accepted_or_duplicate"
      elif [ "$(jq -r '.event_id // empty' <<<"${ack_output}")" != "${event_id}" ]; then
        delivery_error="ack_event_id_mismatch"
      else
        delivery_error="ack_shape_mismatch"
      fi
    fi
  fi

  attempted_at="$(date +%s)"
  if [ -z "${delivery_error}" ]; then
    next_entry="$(jq -c \
      --argjson attempted_at "${attempted_at}" '
      .attempts += 1
      | .last_error = null
      | .delivered_at = $attempted_at
      | .updated_at = $attempted_at
    ' <<<"${entry_json}")"
    DELIVERED_COUNT=$((DELIVERED_COUNT + 1))
  else
    next_entry="$(jq -c \
      --arg delivery_error "${delivery_error}" \
      --argjson attempted_at "${attempted_at}" '
      .attempts += 1
      | .last_error = $delivery_error
      | .delivered_at = null
      | .updated_at = $attempted_at
    ' <<<"${entry_json}")"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
  atomic_write_json "${outbox_file}" "${next_entry}"
  flock -u "${ENTRY_LOCK_FD}"
  exec {ENTRY_LOCK_FD}>&-
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
