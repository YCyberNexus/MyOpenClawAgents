#!/usr/bin/env bash
# Shared validation and atomic publishing for the dispatcher batch I1 outbox.

executor_batch_outbox_die() {
  echo "executor batch outbox: $1" >&2
  exit "${2:-2}"
}

executor_batch_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    executor_batch_outbox_die "no SHA-256 command is available"
  fi
}

validate_executor_callback_nonce() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

generate_executor_callback_nonce() {
  local nonce=""

  if command -v openssl >/dev/null 2>&1; then
    nonce="$(openssl rand -hex 32 2>/dev/null)" \
      || executor_batch_outbox_die "failed to generate callback authentication material"
  elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    nonce="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')" \
      || executor_batch_outbox_die "failed to generate callback authentication material"
  else
    executor_batch_outbox_die "no secure callback nonce generator is available"
  fi

  validate_executor_callback_nonce "${nonce}" \
    || executor_batch_outbox_die "callback nonce generator returned an invalid value"
  printf '%s\n' "${nonce}"
}

executor_callback_nonce_sha256() {
  local nonce="$1"
  validate_executor_callback_nonce "${nonce}" \
    || executor_batch_outbox_die "callback nonce must be 64 lowercase hexadecimal characters"
  printf '%s' "${nonce}" | executor_batch_sha256
}

normalize_executor_batch_origin() {
  jq -c '
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
    else error("invalid origin")
    end
  '
}

load_executor_batch_outbox_locked() {
  jq -ce '
    def printable:
      type == "string"
      and length > 0
      and (explode | all(. >= 32 and . != 127));
    def nullable_printable:
      . == null or printable;
    def multiline_printable:
      type == "string"
      and length > 0
      and (explode | all(. == 10 or (. >= 32 and . != 127)));
    def valid_origin:
      . == null
      or (type == "object"
        and ((keys - [
          "channel","conversation","reply_agent","source_agent",
          "source_session","user"
        ]) | length == 0)
        and all(to_entries[]; .value | printable));
    def valid_selector:
      type == "object"
      and (
        (.type == "single"
          and (keys | sort) == ["iid","type"]
          and (.iid | type == "number" and . == floor and . > 0))
        or (.type == "iid_list"
          and (keys | sort) == ["iids","type"]
          and (.iids | type == "array" and length >= 2)
          and (.iids | all(type == "number" and . == floor and . > 0))
          and (.iids == (.iids | sort | unique)))
        or (.type == "range"
          and (keys | sort) == ["iid_max","iid_min","type"]
          and (.iid_min | type == "number" and . == floor and . > 0)
          and (.iid_max | type == "number" and . == floor and . > 0)
          and (.iid_max >= .iid_min))
        or (.type == "open_unfinished" and keys == ["type"])
        or (.type == "open_label"
          and (keys | sort) == ["label","type"]
          and (.label | printable))
      );
    if type == "object"
      and (keys | sort) == ["requests","version"]
      and .version == 1
      and (.requests | type == "array")
      and all(.requests[];
        type == "object"
        and (
          (keys | sort) == [
            "accepted_at","attempts","batch_id","correlation_id","created_at",
            "executor_agent","force_rerun_pr","last_attempt_at","last_error",
            "matched_count","origin","payload","project","received_at",
            "request_digest","scheduler_status","selector","snapshot_digest","status",
            "target_branch","updated_at"
          ]
          or (keys | sort) == [
            "accepted_at","attempts","batch_id","callback_nonce","correlation_id",
            "created_at","executor_agent","force_rerun_pr","last_attempt_at",
            "last_error","matched_count","origin","payload","project","received_at",
            "request_digest","scheduler_status","selector","snapshot_digest","status",
            "target_branch","updated_at"
          ]
        )
        and (.batch_id | printable and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (.correlation_id | printable)
        and (.project | printable and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
        and (.selector | valid_selector)
        and (.force_rerun_pr | type == "boolean")
        and (.target_branch | nullable_printable)
        and (.executor_agent | printable)
        and ((has("callback_nonce") | not)
          or (.callback_nonce | type == "string" and test("^[0-9a-f]{64}$")))
        and (.origin | valid_origin)
        and (.payload | multiline_printable and startswith("RUN_DRIVEN_ISSUE_BATCH\n"))
        and (if has("callback_nonce") then . as $request
          | ($request.payload | split("\n")
            | index("executor_agent=" + $request.executor_agent) != null)
          and ($request.payload | split("\n")
            | index("callback_nonce=" + $request.callback_nonce) != null)
        else true end)
        and (.request_digest | type == "string" and test("^[0-9a-f]{64}$"))
        and (.status == "waiting_for_legacy_drain"
          or .status == "queued" or .status == "received"
          or .status == "accepted")
        and (.attempts | type == "number" and . == floor and . >= 0)
        and (.last_attempt_at | nullable_printable)
        and (.last_error | nullable_printable)
        and (.matched_count == null
          or (.matched_count | type == "number" and . == floor and . >= 0))
        and (if .snapshot_digest == null then true
          elif has("callback_nonce") then
            (.snapshot_digest | type == "string" and test("^[0-9a-f]{64}$"))
          else (.snapshot_digest | printable)
          end)
        and (.scheduler_status == null or .scheduler_status == "queued"
          or .scheduler_status == "running" or .scheduler_status == "completed")
        and (.created_at | printable)
        and (.updated_at | printable)
        and (.received_at | nullable_printable)
        and (.accepted_at | nullable_printable)
        and (if .status == "accepted" then
          .matched_count != null
          and .snapshot_digest != null
          and .scheduler_status != null
          and .received_at != null
          and .accepted_at != null
        elif .status == "received" then
          .matched_count != null
          and .snapshot_digest != null
          and .scheduler_status != null
          and .received_at != null
          and .accepted_at == null
        else
          .matched_count == null
          and .snapshot_digest == null
          and .scheduler_status == null
          and .received_at == null
          and .accepted_at == null
        end)
      )
      and ([.requests[].batch_id] | length == (unique | length))
      and ([.requests[].correlation_id] | length == (unique | length))
    then .
    else error("invalid executor batch outbox")
    end
  ' "${EXECUTOR_BATCH_OUTBOX_FILE}" 2>/dev/null \
    || executor_batch_outbox_die "${EXECUTOR_BATCH_OUTBOX_FILE} is invalid" 3
}

publish_executor_batch_outbox_locked() {
  local json="$1"
  local candidate

  candidate="$(mktemp "${DISPATCHER_DIR}/.executor_batch_outbox.json.XXXXXX")"
  printf '%s\n' "${json}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null \
    || executor_batch_outbox_die "refusing to publish invalid JSON" 3
  mv "${candidate}" "${EXECUTOR_BATCH_OUTBOX_FILE}"
}

load_executor_accepted_intent_file() {
  local archive_file="$1"

  jq -ce '
    def printable:
      type == "string"
      and length > 0
      and (explode | all(. >= 32 and . != 127));
    if type == "object"
      and (keys | sort) == [
        "accepted_at","batch_id","callback_auth_mode","correlation_id",
        "matched_count","scheduler_status","snapshot_digest","version"
      ]
      and .version == 1
      and (.batch_id | printable and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and (.correlation_id | printable)
      and (.callback_auth_mode == "nonce_v1"
        or .callback_auth_mode == "legacy_pre_upgrade")
      and (.matched_count | type == "number" and . == floor and . >= 0)
      and (if .callback_auth_mode == "nonce_v1" then
        (.snapshot_digest | type == "string" and test("^[0-9a-f]{64}$"))
      else (.snapshot_digest | printable)
      end)
      and (.scheduler_status == "queued" or .scheduler_status == "running"
        or .scheduler_status == "completed")
      and (if .matched_count == 0 then .scheduler_status == "completed" else true end)
      and (.accepted_at | printable)
    then .
    else error("invalid accepted intent archive")
    end
  ' "${archive_file}" 2>/dev/null \
    || executor_batch_outbox_die "accepted intent archive is invalid: ${archive_file}" 3
}

compact_executor_accepted_entry() {
  local accepted_entry="$1"

  jq -ce '
    if type == "object" and .status == "accepted" then {
      version:1,
      batch_id:.batch_id,
      correlation_id:.correlation_id,
      callback_auth_mode:(if has("callback_nonce") then "nonce_v1" else "legacy_pre_upgrade" end),
      matched_count:.matched_count,
      snapshot_digest:.snapshot_digest,
      scheduler_status:.scheduler_status,
      accepted_at:.accepted_at
    }
    else error("cannot archive a non-accepted intent")
    end
  ' <<<"${accepted_entry}" 2>/dev/null \
    || executor_batch_outbox_die "cannot compact accepted intent" 3
}

archive_executor_accepted_entry_locked() {
  local accepted_entry="$1"
  local compact_entry batch_id archive_key archive_file candidate validated existing

  compact_entry="$(compact_executor_accepted_entry "${accepted_entry}")"
  batch_id="$(jq -r '.batch_id' <<<"${compact_entry}")"
  archive_key="$(printf '%s' "${batch_id}" | executor_batch_sha256)"
  [[ "${archive_key}" =~ ^[0-9a-f]{64}$ ]] \
    || executor_batch_outbox_die "accepted intent archive key is invalid" 3
  archive_file="${EXECUTOR_BATCH_ACCEPTED_INTENTS_DIR}/${archive_key}.json"

  if [ -e "${archive_file}" ]; then
    [ -f "${archive_file}" ] \
      || executor_batch_outbox_die "accepted intent archive path is not a regular file: ${archive_file}" 3
    existing="$(load_executor_accepted_intent_file "${archive_file}")"
    if [ "$(jq -cS . <<<"${existing}")" != "$(jq -cS . <<<"${compact_entry}")" ]; then
      executor_batch_outbox_die "accepted intent archive conflicts with hot state: ${batch_id}" 3
    fi
    return 0
  fi

  candidate="$(mktemp "${EXECUTOR_BATCH_ACCEPTED_INTENTS_DIR}/.${archive_key}.json.XXXXXX")"
  printf '%s\n' "${compact_entry}" >"${candidate}"
  validated="$(load_executor_accepted_intent_file "${candidate}")"
  [ "$(jq -cS . <<<"${validated}")" = "$(jq -cS . <<<"${compact_entry}")" ] \
    || executor_batch_outbox_die "accepted intent archive changed during validation: ${batch_id}" 3
  mv "${candidate}" "${archive_file}"
}

compact_executor_accepted_outbox_locked() {
  local outbox_json="$1"
  local accepted_entry next_outbox

  while IFS= read -r accepted_entry; do
    [ -n "${accepted_entry}" ] || continue
    archive_executor_accepted_entry_locked "${accepted_entry}"
  done < <(jq -c '.requests[] | select(.status == "accepted")' <<<"${outbox_json}")

  next_outbox="$(jq -c '.requests |= map(select(.status != "accepted"))' <<<"${outbox_json}")"
  if [ "$(jq -cS . <<<"${next_outbox}")" != "$(jq -cS . <<<"${outbox_json}")" ]; then
    publish_executor_batch_outbox_locked "${next_outbox}"
  fi
  printf '%s' "${next_outbox}"
}

load_executor_accepted_intent_by_batch_id_locked() {
  local batch_id="$1"
  local archive_key archive_file accepted_entry

  archive_key="$(printf '%s' "${batch_id}" | executor_batch_sha256)"
  [[ "${archive_key}" =~ ^[0-9a-f]{64}$ ]] \
    || executor_batch_outbox_die "accepted intent archive key is invalid" 3
  archive_file="${EXECUTOR_BATCH_ACCEPTED_INTENTS_DIR}/${archive_key}.json"

  if [ ! -e "${archive_file}" ]; then
    printf '%s' null
    return 0
  fi
  [ -f "${archive_file}" ] \
    || executor_batch_outbox_die "accepted intent archive path is not a regular file: ${archive_file}" 3
  accepted_entry="$(load_executor_accepted_intent_file "${archive_file}")"
  [ "$(jq -r '.batch_id' <<<"${accepted_entry}")" = "${batch_id}" ] \
    || executor_batch_outbox_die "accepted intent archive identity does not match lookup key: ${batch_id}" 3
  printf '%s' "${accepted_entry}"
}

reconcile_executor_accepted_hot_entries_locked() {
  local outbox_json="$1"
  local next_outbox hot_entry batch_id cold_entry

  next_outbox="${outbox_json}"
  while IFS= read -r hot_entry; do
    [ -n "${hot_entry}" ] || continue
    batch_id="$(jq -r '.batch_id' <<<"${hot_entry}")"
    cold_entry="$(load_executor_accepted_intent_by_batch_id_locked "${batch_id}")"
    [ "${cold_entry}" != null ] || continue

    if ! jq -en \
      --argjson hot "${hot_entry}" \
      --argjson cold "${cold_entry}" '
        $hot.status == "received"
        and $hot.batch_id == $cold.batch_id
        and $hot.correlation_id == $cold.correlation_id
        and (if ($hot | has("callback_nonce"))
          then "nonce_v1" else "legacy_pre_upgrade" end) == $cold.callback_auth_mode
        and $hot.matched_count == $cold.matched_count
        and $hot.snapshot_digest == $cold.snapshot_digest
        and $hot.scheduler_status == $cold.scheduler_status
      ' >/dev/null; then
      executor_batch_outbox_die \
        "accepted intent archive conflicts with hot state: ${batch_id}" 3
    fi

    next_outbox="$(jq -c --arg batch_id "${batch_id}" '
      .requests |= map(select(.batch_id != $batch_id))
    ' <<<"${next_outbox}")"
  done < <(jq -c '.requests[]' <<<"${outbox_json}")

  if [ "$(jq -cS . <<<"${next_outbox}")" != "$(jq -cS . <<<"${outbox_json}")" ]; then
    publish_executor_batch_outbox_locked "${next_outbox}"
  fi
  printf '%s' "${next_outbox}"
}

load_executor_delivered_notification_file() {
  local archive_file="$1"

  jq -ce '
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
        "attempts","delivered_at","event_id","iid","mr_url","origin",
        "project","reason","status","version"
      ]
      and .version == 1
      and (.event_id | printable)
      and (.origin | valid_origin)
      and (.project | printable)
      and (
        ((.status == "done" or .status == "failed"
            or .status == "timeout" or .status == "skipped")
          and (.iid | type == "number" and . == floor and . > 0)
          and (.mr_url == null or (.mr_url | type == "string"))
          and (.reason == null or (.reason | type == "string")))
        or (.status == "no_matches"
          and .iid == null
          and .mr_url == null
          and .reason == "无匹配 OPEN Issue")
      )
      and (.attempts | type == "number" and . == floor and . >= 0)
      and (.delivered_at | printable)
    then .
    else error("invalid delivered notification archive")
    end
  ' "${archive_file}" 2>/dev/null \
    || executor_batch_outbox_die \
      "delivered notification archive is invalid: ${archive_file}" 3
}

load_executor_delivered_notification_by_event_id_locked() {
  local event_id="$1"
  local archive_key archive_file notification_item

  archive_key="$(printf '%s' "${event_id}" | executor_batch_sha256)"
  [[ "${archive_key}" =~ ^[0-9a-f]{64}$ ]] \
    || executor_batch_outbox_die "delivered notification archive key is invalid" 3
  archive_file="${EXECUTOR_BATCH_DELIVERED_NOTIFICATIONS_DIR}/${archive_key}.json"

  if [ ! -e "${archive_file}" ]; then
    printf '%s' null
    return 0
  fi
  [ -f "${archive_file}" ] \
    || executor_batch_outbox_die \
      "delivered notification archive path is not a regular file: ${archive_file}" 3
  notification_item="$(load_executor_delivered_notification_file "${archive_file}")"
  [ "$(jq -r '.event_id' <<<"${notification_item}")" = "${event_id}" ] \
    || executor_batch_outbox_die \
      "delivered notification archive identity does not match lookup key: ${event_id}" 3
  printf '%s' "${notification_item}"
}

load_legacy_executor_queue_locked() {
  jq -ce '
    if type == "object"
      and (.active == null or (.active | type == "object"))
      and (.queue | type == "array")
    then .
    else error("invalid legacy executor queue")
    end
  ' "${EXECUTOR_QUEUE_FILE}" 2>/dev/null \
    || executor_batch_outbox_die "${EXECUTOR_QUEUE_FILE} is invalid" 3
}

legacy_executor_queue_is_busy() {
  jq -er '(.active != null) or ((.queue | length) > 0)' <<<"$1"
}
