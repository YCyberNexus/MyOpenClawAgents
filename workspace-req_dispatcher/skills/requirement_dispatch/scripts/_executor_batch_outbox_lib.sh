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
        and (keys | sort) == [
          "accepted_at","attempts","batch_id","correlation_id","created_at",
          "executor_agent","force_rerun_pr","last_attempt_at","last_error",
          "matched_count","origin","payload","project","received_at",
          "request_digest","scheduler_status","selector","snapshot_digest","status",
          "target_branch","updated_at"
        ]
        and (.batch_id | printable and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (.correlation_id | printable)
        and (.project | printable and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
        and (.selector | valid_selector)
        and (.force_rerun_pr | type == "boolean")
        and (.target_branch | nullable_printable)
        and (.executor_agent | printable)
        and (.origin | valid_origin)
        and (.payload | multiline_printable and startswith("RUN_DRIVEN_ISSUE_BATCH\n"))
        and (.request_digest | type == "string" and test("^[0-9a-f]{64}$"))
        and (.status == "waiting_for_legacy_drain"
          or .status == "queued" or .status == "received"
          or .status == "accepted")
        and (.attempts | type == "number" and . == floor and . >= 0)
        and (.last_attempt_at | nullable_printable)
        and (.last_error | nullable_printable)
        and (.matched_count == null
          or (.matched_count | type == "number" and . == floor and . >= 0))
        and (.snapshot_digest | nullable_printable)
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
