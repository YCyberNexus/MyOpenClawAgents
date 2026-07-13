#!/usr/bin/env bash
# ingest_subagent_completion.sh — authenticate an OpenClaw native subagent
# completion and pass its sole compact worker reply into Phase 6.
#
# Accepted stdin shapes are deliberately strict:
#   1. an OpenClaw 2026.4.9 protected raw internal completion context. Its
#      Result block is ignored; local registry, transcript, bootstrap, durable
#      launch-action, and pending-state evidence authenticate the completion;
#   2. a task_completion event (direct, under `event`, or the sole member of
#      `internalEvents`) with child runtime identity and final result text;
#   3. a `sessions_history_terminal` envelope containing the exact terminal
#      run/session identity and a non-truncated history whose last message is
#      the child's assistant reply.
#
# Chat prose and legacy trigger text are not accepted here.  The script treats
# every result string as untrusted data, extracts exactly one current compact
# worker JSON line, and authorizes it only against pending_subagents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FOLLOWUP_SCRIPT="${DISPATCH_FOLLOWUP_CMD:-${SCRIPT_DIR}/dispatch_followup.sh}"
if [ ! -f "${FOLLOWUP_SCRIPT}" ]; then
  echo "ingest_subagent_completion.sh: dispatch followup script is missing" >&2
  exit 2
fi

reject_completion() {
  local reason="$1"
  echo "ingest_subagent_completion.sh: rejected ${reason}" >&2
  jq -nc --arg reason "${reason}" '{
    completion_status:"rejected",
    reason:$reason
  }'
  exit 3
}

RAW_INPUT="$(cat)"
INPUT_BYTES="$(printf '%s' "${RAW_INPUT}" | wc -c | tr -d ' ')"
if [ "${INPUT_BYTES}" -eq 0 ] || [ "${INPUT_BYTES}" -gt 1048576 ]; then
  reject_completion invalid_input_size
fi
INPUT_IS_JSON=false
INTERNAL_CONTEXT_MODE=false
if INPUT_JSON="$(printf '%s' "${RAW_INPUT}" | jq -ce '
  if type == "object" then . else error("completion input must be an object") end
 ' 2>/dev/null)"; then
  INPUT_IS_JSON=true
fi

if [ "${INPUT_IS_JSON}" = true ]; then
IS_HISTORY=false
if jq -e '
  (.kind == "sessions_history_terminal")
  or (.type == "sessions_history_terminal")
' <<<"${INPUT_JSON}" >/dev/null; then
  IS_HISTORY=true
fi

if [ "${IS_HISTORY}" = true ]; then
  if ! NORMALIZED="$(jq -ce '
    def one_string($values; $required):
      [$values[] | select(. != null)] as $present
      | if any($present[]; type != "string" or length == 0) then
          error("invalid string alias")
        elif ($present | unique | length) > 1 then
          error("conflicting string aliases")
        elif ($present | length) == 0 then
          if $required then error("missing string") else "" end
        else $present[0]
        end;
    . as $root
    | (if (.history | type) == "object" then .history else . end) as $history
    | one_string([
        $root.childSessionKey, $root.child_session_key,
        $history.sessionKey, $history.session_key
      ]; true) as $child_key
    | one_string([
        $root.childRunId, $root.runId, $root.run_id
      ]; true) as $run_id
    | one_string([
        $root.childLabel, $root.taskLabel, $root.label
      ]; false) as $label
    | one_string([$root.status, $root.runStatus, $root.run_status]; true) as $status
    | (if $root.source != "sessions_history" then
        error("history source is not trusted")
      elif (["done","completed","ok","failed","error","timeout","timed_out","killed"]
        | index($status)) == null then
        error("history is not terminal")
      elif (($history.truncated // false) != false)
        or (($history.droppedMessages // false) != false)
        or (($history.contentTruncated // false) != false)
        or (($history.contentRedacted // false) != false) then
        error("history is incomplete")
      elif ($history.messages | type) != "array"
        or ($history.messages | length) == 0 then
        error("history messages are missing")
      else $history.messages[-1]
      end) as $last
    | (if ($last | type) != "object" or $last.role != "assistant" then
        error("last history message is not assistant")
      elif ($last.content | type) == "string" then
        $last.content
      elif ($last.content | type) == "array" then
        [$last.content[]
          | select(type == "object" and .type == "text" and (.text | type) == "string")
          | .text] as $texts
        | if ($texts | length) == 0 then error("assistant text is missing")
          else ($texts | join("\n")) end
      else error("assistant content is invalid")
      end) as $assistant_text
    | {
        origin:"sessions_history",
        child_session_key:$child_key,
        run_id:$run_id,
        announce_id:"",
        label:$label,
        runtime_status:$status,
        assistant_text:$assistant_text
      }
  ' <<<"${INPUT_JSON}" 2>/dev/null)"; then
    reject_completion invalid_sessions_history_terminal
  fi
else
  if ! NORMALIZED="$(jq -ce '
    def one_string($values; $required):
      [$values[] | select(. != null)] as $present
      | if any($present[]; type != "string" or length == 0) then
          error("invalid string alias")
        elif ($present | unique | length) > 1 then
          error("conflicting string aliases")
        elif ($present | length) == 0 then
          if $required then error("missing string") else "" end
        else $present[0]
        end;
    . as $root
    | (if has("internalEvents") then
         if (.internalEvents | type) == "array" and (.internalEvents | length) == 1
         then .internalEvents[0]
         else error("ambiguous internal events")
         end
       elif (.event | type) == "object" then .event
       else .
       end) as $event
    | one_string([
        $event.childSessionKey, $event.child_session_key, $event.sessionKey,
        $root.childSessionKey, $root.child_session_key
      ]; true) as $child_key
    | one_string([
        $event.childRunId, $event.runId, $event.run_id,
        $root.childRunId, $root.runId, $root.run_id
      ]; false) as $run_id
    | one_string([
        $event.announceId, $event.announce_id,
        $root.announceId, $root.announce_id
      ]; false) as $announce_id
    | one_string([
        $event.taskLabel, $event.childLabel, $event.label,
        $root.taskLabel, $root.childLabel, $root.label
      ]; false) as $label
    | one_string([$event.status, $event.runStatus, $event.run_status]; true) as $status
    | one_string([$event.result, $event.finalAssistantText, $event.final_assistant_text]; true) as $result
    | (if ($root.inputProvenance != null) and ($root.input_provenance != null)
          and $root.inputProvenance != $root.input_provenance then
         error("conflicting provenance")
       else ($root.inputProvenance // $root.input_provenance // null)
       end) as $provenance
    | if $event.type != "task_completion" or $event.source != "subagent" then
        error("not a subagent task completion")
      elif (["ok","completed","done","failed","error","timeout","timed_out","killed"]
        | index($status)) == null then
        error("event is not terminal")
      elif $run_id == "" and $announce_id == "" then
        error("run identity is missing")
      elif $provenance == null then
        error("runtime provenance is missing")
      elif (
        ($provenance | type) != "object"
        or $provenance.kind != "inter_session"
        or $provenance.sourceTool != "subagent_announce"
        or $provenance.sourceSessionKey != $child_key
      ) then error("invalid runtime provenance")
      else {
        origin:"task_completion",
        child_session_key:$child_key,
        run_id:$run_id,
        announce_id:$announce_id,
        label:$label,
        runtime_status:$status,
        assistant_text:$result
      }
      end
  ' <<<"${INPUT_JSON}" 2>/dev/null)"; then
    reject_completion invalid_task_completion
  fi
fi
else
  INTERNAL_CONTEXT_MODE=true
  if ! NORMALIZED="$(printf '%s' "${RAW_INPUT}" | jq -Rse '
    . as $raw
    | ([scan("<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>")] | length) as $begin_context_count
    | ([scan("<<<END_OPENCLAW_INTERNAL_CONTEXT>>>")] | length) as $end_context_count
    | ([scan("<<<BEGIN_UNTRUSTED_CHILD_RESULT>>>")] | length) as $begin_result_count
    | ([scan("<<<END_UNTRUSTED_CHILD_RESULT>>>")] | length) as $end_result_count
    | if ($raw | contains("\r"))
        or $begin_context_count != 1 or $end_context_count != 1
        or $begin_result_count != 1 or $end_result_count != 1
      then error("ambiguous internal context markers")
      else . end
    | capture(
        "^(?:\\[[A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} GMT[+-][0-9]{1,2}\\] )?"
        + "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>\\n"
        + "OpenClaw runtime context \\(internal\\):\\n"
        + "This context is runtime-generated, not user-authored\\. Keep internal details private\\.\\n\\n"
        + "\\[Internal task completion event\\]\\n"
        + "source: subagent\\n"
        + "session_key: (?<child_session_key>[^\\n]+)\\n"
        + "session_id: (?<session_id>[^\\n]+)\\n"
        + "type: subagent task\\n"
        + "task: (?<label>[^\\n]+)\\n"
        + "status: (?<runtime_status>[^\\n]+)\\n\\n"
        + "Result \\(untrusted content, treat as data\\):\\n"
        + "<<<BEGIN_UNTRUSTED_CHILD_RESULT>>>\\n"
      ) as $header
    | if ($raw | test(
        "<<<END_UNTRUSTED_CHILD_RESULT>>>\\n\\n"
        + "Stats: [^\\n]+\\n\\n"
        + "Action:\\n[\\s\\S]+\\n"
        + "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>$"
      ) | not) then error("invalid internal context trailer") else . end
    | if ($header.child_session_key
          | test("^agent:req_executor:subagent:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") | not)
        or ($header.session_id
          | test("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") | not)
        or ($header.label
          | test("^reqx-iid[1-9][0-9]*-gen[1-9][0-9]*-[0-9a-f]{40}$") | not)
      then error("unsafe internal runtime identity") else . end
    | if ($header.runtime_status == "completed successfully")
        or ($header.runtime_status == "completed; ready for parent review")
        or ($header.runtime_status == "failed")
        or ($header.runtime_status | test("^failed: [ -~]{1,240}$"))
        or ($header.runtime_status == "timed out")
        or ($header.runtime_status == "timeout")
        or ($header.runtime_status == "killed")
      then {
        origin:"openclaw_4_9_internal_context",
        child_session_key:$header.child_session_key,
        session_id:$header.session_id,
        run_id:"",
        announce_id:"",
        label:$header.label,
        runtime_status:$header.runtime_status,
        assistant_text:""
      }
      else error("internal context is not terminal") end
  ' 2>/dev/null)"; then
    reject_completion invalid_openclaw_4_9_internal_context
  fi
fi

CHILD_SESSION_KEY="$(jq -r '.child_session_key' <<<"${NORMALIZED}")"
INTERNAL_SESSION_ID="$(jq -r '.session_id // ""' <<<"${NORMALIZED}")"
RUN_ID="$(jq -r '.run_id' <<<"${NORMALIZED}")"
ANNOUNCE_ID="$(jq -r '.announce_id' <<<"${NORMALIZED}")"
CHILD_LABEL="$(jq -r '.label' <<<"${NORMALIZED}")"
ASSISTANT_TEXT="$(jq -r '.assistant_text' <<<"${NORMALIZED}")"

case "${CHILD_SESSION_KEY}${INTERNAL_SESSION_ID}${RUN_ID}${ANNOUNCE_ID}${CHILD_LABEL}" in
  *$'\n'*|*$'\r'*|*$'\t'*) reject_completion invalid_runtime_identity ;;
esac

if [ "${INTERNAL_CONTEXT_MODE}" = true ]; then
  OPENCLAW_STATE_ROOT="${OPENCLAW_STATE_DIR:-${HOME:?}/.openclaw}"
  case "${OPENCLAW_STATE_ROOT}" in
    /*) ;;
    *) reject_completion unsafe_openclaw_state_root ;;
  esac
  case "/${OPENCLAW_STATE_ROOT#/}/" in
    */../*|*/./*) reject_completion unsafe_openclaw_state_root ;;
  esac
  case "${OPENCLAW_STATE_ROOT}" in
    /|*$'\n'*|*$'\r'*|*$'\t'*) reject_completion unsafe_openclaw_state_root ;;
  esac
  if [ ! -d "${OPENCLAW_STATE_ROOT}" ] || [ -L "${OPENCLAW_STATE_ROOT}" ]; then
    reject_completion unsafe_openclaw_state_root
  fi

  OPENCLAW_SESSIONS_DIR="${OPENCLAW_STATE_ROOT}/agents/req_executor/sessions"
  if [ ! -d "${OPENCLAW_SESSIONS_DIR}" ] \
      || [ -L "${OPENCLAW_SESSIONS_DIR}" ]; then
    reject_completion invalid_openclaw_sessions_registry
  fi
  OPENCLAW_SESSIONS_DIR_CANON="$(cd -P "${OPENCLAW_SESSIONS_DIR}" && pwd)"
  OPENCLAW_REGISTRY_FILE="${OPENCLAW_SESSIONS_DIR_CANON}/sessions.json"
  if [ ! -f "${OPENCLAW_REGISTRY_FILE}" ] \
      || [ -L "${OPENCLAW_REGISTRY_FILE}" ]; then
    reject_completion invalid_openclaw_sessions_registry
  fi
  REGISTRY_BYTES="$(wc -c <"${OPENCLAW_REGISTRY_FILE}" | tr -d ' ')"
  if [ "${REGISTRY_BYTES}" -eq 0 ] || [ "${REGISTRY_BYTES}" -gt 16777216 ]; then
    reject_completion invalid_openclaw_sessions_registry
  fi

  EXPECTED_SESSION_FILE="${OPENCLAW_SESSIONS_DIR_CANON}/${INTERNAL_SESSION_ID}.jsonl"
  if ! REGISTRY_MATCH="$(jq -ce \
      --arg child_session_key "${CHILD_SESSION_KEY}" \
      --arg session_id "${INTERNAL_SESSION_ID}" \
      --arg child_label "${CHILD_LABEL}" \
      --arg expected_session_file "${EXPECTED_SESSION_FILE}" '
      def clean_string:
        type == "string" and length > 0
        and (explode | all(. >= 32 and . != 127));
      if type != "object" then error("registry is not an object") else . end
      | [to_entries[]
          | select(
              .key == $child_session_key
              or ((.value | type) == "object" and (
                .value.sessionId == $session_id
                or .value.sessionFile == $expected_session_file
                or .value.label == $child_label
              ))
            )] as $related
      | if ($related | length) != 1 then
          error("registry identity is missing or conflicting")
        else $related[0] end
      | if .key != $child_session_key
          or (.value | type) != "object"
          or .value.sessionId != $session_id
          or .value.sessionFile != $expected_session_file
          or .value.label != $child_label
          or .value.status != "done"
          or (.value.endedAt | type != "number" or . != floor or . < 0)
          or (.value.spawnDepth | type != "number" or . != floor or . < 1)
          or .value.subagentRole != "leaf"
          or (.value.spawnedBy | clean_string | not)
          or (.value.spawnedBy | startswith("agent:req_executor:") | not)
        then error("registry entry is not an exact terminal child")
        else {
          session_file:.value.sessionFile,
          status:.value.status,
          ended_at:.value.endedAt
        } end
    ' "${OPENCLAW_REGISTRY_FILE}" 2>/dev/null)"; then
    reject_completion invalid_or_conflicting_openclaw_session_registry
  fi
  SESSION_FILE="$(jq -r '.session_file' <<<"${REGISTRY_MATCH}")"
  if [ "${SESSION_FILE}" != "${EXPECTED_SESSION_FILE}" ] \
      || [ ! -f "${SESSION_FILE}" ] \
      || [ -L "${SESSION_FILE}" ]; then
    reject_completion unsafe_openclaw_session_file
  fi
  SESSION_FILE_BYTES="$(wc -c <"${SESSION_FILE}" | tr -d ' ')"
  if [ "${SESSION_FILE_BYTES}" -eq 0 ] \
      || [ "${SESSION_FILE_BYTES}" -gt 67108864 ]; then
    reject_completion invalid_openclaw_session_file_size
  fi

  if ! SESSION_TERMINAL_JSON="$(jq -sce --arg session_id "${INTERNAL_SESSION_ID}" '
      def clean_string:
        type == "string" and length > 0
        and length <= 512
        and (explode | all(. >= 32 and . != 127));
      if length == 0 or any(.[]; type != "object") then
        error("session jsonl is empty or malformed")
      elif .[0].type != "session" or .[0].version != 3
          or .[0].id != $session_id then
        error("session header does not match registry identity")
      elif ([.[] | select(.type == "session" and .id == $session_id)] | length) != 1 then
        error("session header is ambiguous")
      elif ([.[] | select(
          .type == "custom"
          and .customType == "openclaw:bootstrap-context:full"
        )] | length) != 1 then
        error("full bootstrap identity is missing or ambiguous")
      elif (.[-1].type != "custom")
          or .[-1].customType != "openclaw:bootstrap-context:full"
          or (.[-1].data | type) != "object"
          or ((.[-1].data | keys | sort) != ["runId","sessionId","timestamp"])
          or .[-1].data.sessionId != $session_id
          or (.[-1].data.runId | clean_string | not)
        then error("full bootstrap identity is invalid")
      else {
        bootstrap_run_id:.[-1].data.runId,
        messages:[ .[] | select(.type == "message") ]
      } end
      | . as $terminal
      | (if ($terminal.messages | length) == 0 then
          error("session has no messages")
        else $terminal.messages[-1] end) as $last
      | (if ($last.message | type) != "object"
            or $last.message.role != "assistant"
            or $last.message.stopReason != "stop"
          then error("last session message is not a terminal assistant")
          elif ($last.message.content | type) == "string" then
            $last.message.content
          elif ($last.message.content | type) == "array" then
            $last.message.content as $content
            | if any($content[];
                type != "object" or (.type != "thinking" and .type != "text"))
              then error("terminal assistant content has unsupported parts")
              else [$content[]
                | select(.type == "text" and (.text | type) == "string")
                | .text] end
            | if length != 1 then error("terminal assistant text is ambiguous")
              else .[0] end
          else error("terminal assistant content is invalid") end) as $assistant_text
      | if ($assistant_text | length) == 0
          or ($assistant_text | length) > 1048576
          or ($assistant_text | explode
            | all(. == 10 or (. >= 32 and . != 127)) | not)
        then error("terminal assistant text is unsafe")
        else {
          bootstrap_run_id:$terminal.bootstrap_run_id,
          assistant_text:$assistant_text
        } end
    ' "${SESSION_FILE}" 2>/dev/null)"; then
    reject_completion invalid_openclaw_terminal_session_jsonl
  fi
  SESSION_BOOTSTRAP_RUN_ID="$(jq -r '.bootstrap_run_id' <<<"${SESSION_TERMINAL_JSON}")"
  ASSISTANT_TEXT="$(jq -r '.assistant_text' <<<"${SESSION_TERMINAL_JSON}")"
fi

# OpenClaw 2026.4.9's internal event omits childRunId, but its structured
# announcement id is exactly v1:<childSessionKey>:<childRunId>.  Strip only the
# already-validated full session-key prefix; never split on a bare colon.
if [ "${INTERNAL_CONTEXT_MODE}" != true ] && [ -z "${RUN_ID}" ]; then
  ANNOUNCE_PREFIX="v1:${CHILD_SESSION_KEY}:"
  case "${ANNOUNCE_ID}" in
    "${ANNOUNCE_PREFIX}"*) RUN_ID="${ANNOUNCE_ID#"${ANNOUNCE_PREFIX}"}" ;;
    *) reject_completion invalid_announce_identity ;;
  esac
  [ -n "${RUN_ID}" ] || reject_completion invalid_announce_identity
fi
if [ "${INTERNAL_CONTEXT_MODE}" != true ] \
    && [ -n "${ANNOUNCE_ID}" ] \
    && [ "${ANNOUNCE_ID}" != "v1:${CHILD_SESSION_KEY}:${RUN_ID}" ]; then
  reject_completion conflicting_announce_identity
fi

if [ "${#CHILD_SESSION_KEY}" -gt 512 ] \
    || [ "${#RUN_ID}" -gt 512 ] \
    || [ "${#ANNOUNCE_ID}" -gt 1536 ] \
    || [ "${#CHILD_LABEL}" -gt 96 ]; then
  reject_completion invalid_runtime_identity
fi

# A legacy/direct caller may still provide PROJECT + GROUP + GITLAB_TOKEN.
# Native OpenClaw completion delivery deliberately does not need any of those:
# its project route is recovered from the scheduler's durable spawn ack only
# after the structured runtime identity above has been validated.
PROJECT_ENV_SET="${PROJECT+x}"
GROUP_ENV_SET="${GROUP+x}"
CALLER_PROJECT="${PROJECT:-}"
CALLER_GROUP="${GROUP:-}"
CALLER_REPO_PARENT_SET="${REPO_PARENT_PATH+x}"
CALLER_REPO_PARENT="${REPO_PARENT_PATH:-}"
CALLER_REPO_PATH_SET="${REPO_PATH+x}"
CALLER_REPO_PATH="${REPO_PATH:-}"
CALLER_EXPLICIT_ROUTE=false
ROUTE_MODE=durable_required
if [ "${PROJECT_ENV_SET}" = x ] || [ "${GROUP_ENV_SET}" = x ]; then
  CALLER_EXPLICIT_ROUTE=true
  ROUTE_MODE=legacy_explicit
fi

ROUTED_IID=""
ROUTED_ATTEMPT_NUMBER=""
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd)/config}"
SCHEDULER_ENV_SCRIPT="${SCRIPT_DIR}/scheduler_env.sh"
GITLAB_RESOLVER_SCRIPT="${SCRIPT_DIR}/gitlab_env_resolver.sh"
REPO_RESOLVER_SCRIPT="${SCRIPT_DIR}/resolve_driven_repo_path.sh"
TRY_DURABLE_ROUTE=true
if [ "${INTERNAL_CONTEXT_MODE}" != true ] \
    && [ "${CALLER_EXPLICIT_ROUTE}" = true ] \
    && { [ ! -f "${SCHEDULER_ENV_SCRIPT}" ] \
      || [ ! -f "${CONFIG_DIR}/campaign_defaults.env" ]; }; then
  # Compatibility for isolated legacy callers/tests that have no scheduler
  # installation at all. A deployed scheduler is always authoritative when
  # its ack matches this runtime identity.
  TRY_DURABLE_ROUTE=false
fi

if [ "${TRY_DURABLE_ROUTE}" = true ]; then
  [ -f "${SCHEDULER_ENV_SCRIPT}" ] \
    || reject_completion scheduler_route_unavailable

  if ! SCHEDULER_CONFIG_JSON="$(
    CONFIG_DIR="${CONFIG_DIR}" bash "${SCHEDULER_ENV_SCRIPT}"
  )"; then
    reject_completion invalid_scheduler_config
  fi
  if ! EXECUTOR_SCHEDULER_ROOT="$(jq -er '
      if type == "object"
        and (.scheduler_root | type == "string" and startswith("/"))
      then .scheduler_root
      else error("invalid scheduler root")
      end
    ' <<<"${SCHEDULER_CONFIG_JSON}" 2>/dev/null)"; then
    reject_completion invalid_scheduler_config
  fi

  ACTION_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_actions"
  ACTION_ARCHIVE_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_action_archive"
  ACTION_LOCK_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_action_locks"
  ACTION_DIGESTS=()
  shopt -s nullglob
  for ACTION_PATH in "${ACTION_ROOT}"/*.json "${ACTION_ARCHIVE_ROOT}"/*.json; do
    ACTION_NAME="$(basename "${ACTION_PATH}")"
    if ! [[ "${ACTION_NAME}" =~ ^[0-9a-f]{64}\.json$ ]]; then
      reject_completion invalid_durable_launch_action
    fi
    ACTION_DIGESTS+=("${ACTION_NAME%.json}")
  done
  shopt -u nullglob

  if [ "${#ACTION_DIGESTS[@]}" -gt 0 ]; then
    if [ ! -d "${ACTION_LOCK_ROOT}" ] || [ -L "${ACTION_LOCK_ROOT}" ]; then
      reject_completion invalid_durable_launch_layout
    fi
    IFS=$'\n' ACTION_DIGESTS=($(printf '%s\n' "${ACTION_DIGESTS[@]}" \
      | LC_ALL=C sort -u))
    unset IFS
  fi

  sha256_text() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 | awk '{print $1}'
    else
      return 2
    fi
  }

  ROUTE_MATCH_COUNT=0
  ROUTE_ACTION_JSON=""
  for ACTION_DIGEST in "${ACTION_DIGESTS[@]}"; do
    ACTION_LOCK_FILE="${ACTION_LOCK_ROOT}/${ACTION_DIGEST}.lock"
    if [ ! -f "${ACTION_LOCK_FILE}" ] || [ -L "${ACTION_LOCK_FILE}" ]; then
      reject_completion invalid_durable_launch_layout
    fi
    exec {ACTION_LOCK_FD}>"${ACTION_LOCK_FILE}"
    flock -s "${ACTION_LOCK_FD}"

    HOT_ACTION_FILE="${ACTION_ROOT}/${ACTION_DIGEST}.json"
    COLD_ACTION_FILE="${ACTION_ARCHIVE_ROOT}/${ACTION_DIGEST}.json"
    HOT_PRESENT=false
    COLD_PRESENT=false
    [ -e "${HOT_ACTION_FILE}" ] && HOT_PRESENT=true
    [ -e "${COLD_ACTION_FILE}" ] && COLD_PRESENT=true
    if [ "${HOT_PRESENT}" = true ] && [ "${COLD_PRESENT}" = true ]; then
      reject_completion duplicate_durable_launch_identity
    elif [ "${HOT_PRESENT}" = true ]; then
      ACTION_FILE="${HOT_ACTION_FILE}"
    elif [ "${COLD_PRESENT}" = true ]; then
      ACTION_FILE="${COLD_ACTION_FILE}"
    else
      flock -u "${ACTION_LOCK_FD}"
      exec {ACTION_LOCK_FD}>&-
      continue
    fi
    if [ ! -f "${ACTION_FILE}" ] || [ -L "${ACTION_FILE}" ]; then
      reject_completion invalid_durable_launch_action
    fi

    if ! ACTION_JSON="$(jq -ce '
      def clean_string:
        type == "string" and length > 0
        and (explode | all(. >= 32 and . != 127));
      def safe_project:
        type == "string" and length <= 512
        and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$")
        and (split("/") | all(. != "." and . != ".."));
      if type == "object"
        and .version == 1
        and (.job_id | clean_string and length <= 1024)
        and (.project | safe_project)
        and (.iid | type == "number" and . == floor and . > 0)
        and (.attempt_number | type == "number" and . == floor and . > 0)
        and (.expected_task_sha256 | type == "string"
          and test("^[0-9a-f]{64}$"))
        and (.expected_task_bytes | type == "number"
          and . == floor and . > 0)
        and (.claim_generation | type == "number" and . == floor and . >= 0)
        and ((.claim_token == null) or (.claim_token | clean_string))
        and (.stage == "topup_prepared" or .stage == "preparing_claimed"
          or .stage == "bound" or .stage == "action_emitted"
          or .stage == "ack_received" or .stage == "project_recorded"
          or .stage == "scheduler_recorded" or .stage == "completed")
        and (if .stage == "topup_prepared"
          then .claim_generation == 0 and .claim_token == null
          else .claim_generation > 0 and (.claim_token | clean_string)
          end)
        and (.outcome == null or .outcome == "spawned"
          or .outcome == "launch_failed")
        and (.ack == null or (.ack | type == "object"))
        and ((has("child_label") | not)
          or (.child_label | clean_string and length <= 96))
        and ((has("runtime_label_version") | not)
          or (.runtime_label_version == 1
            and (.child_label
              | test("^reqx-iid[1-9][0-9]*-gen[1-9][0-9]*-[0-9a-f]{40}$"))))
        and (.created_at | type == "number" and . == floor and . >= 0)
        and (.updated_at | type == "number" and . == floor and . >= 0)
      then . else error("invalid durable launch action") end
    ' "${ACTION_FILE}" 2>/dev/null)"; then
      reject_completion invalid_durable_launch_action
    fi
    if [ "$(printf '%s' "$(jq -r '.job_id' <<<"${ACTION_JSON}")" \
        | sha256_text)" != "${ACTION_DIGEST}" ]; then
      reject_completion invalid_durable_launch_action_path
    fi

    ACTION_RUNTIME_MATCH=false
    if [ "${INTERNAL_CONTEXT_MODE}" = true ]; then
      if jq -e \
          --arg child_session_key "${CHILD_SESSION_KEY}" \
          --arg child_label "${CHILD_LABEL}" '
          (.ack | type == "object")
          and .ack.child_session_key == $child_session_key
          and (.child_label | type == "string")
          and .child_label == $child_label
        ' <<<"${ACTION_JSON}" >/dev/null; then
        ACTION_RUNTIME_MATCH=true
      fi
    elif jq -e \
        --arg run_id "${RUN_ID}" \
        --arg child_session_key "${CHILD_SESSION_KEY}" '
        (.ack | type == "object")
        and .ack.run_id == $run_id
        and .ack.child_session_key == $child_session_key
      ' <<<"${ACTION_JSON}" >/dev/null; then
      ACTION_RUNTIME_MATCH=true
    fi
    if [ "${ACTION_RUNTIME_MATCH}" = true ]; then
      if ! jq -e '
          def clean_string:
            type == "string" and length > 0
            and (explode | all(. >= 32 and . != 127));
          (.stage == "ack_received" or .stage == "project_recorded"
            or .stage == "scheduler_recorded" or .stage == "completed")
          and .outcome == "spawned"
          and (.ack | type == "object"
            and (keys | sort) == ["child_session_key","run_id"]
            and (.run_id | clean_string and length <= 512)
            and (.child_session_key | clean_string and length <= 512))
        ' <<<"${ACTION_JSON}" >/dev/null; then
        reject_completion invalid_matching_durable_launch_action
      fi
      ROUTE_MATCH_COUNT=$((ROUTE_MATCH_COUNT + 1))
      ROUTE_ACTION_JSON="$(jq -c '{
        project,
        iid,
        attempt_number,
        child_label:(.child_label // ""),
        run_id:.ack.run_id
      }' <<<"${ACTION_JSON}")"
    fi
    flock -u "${ACTION_LOCK_FD}"
    exec {ACTION_LOCK_FD}>&-
  done
  unset -f sha256_text

  if [ "${ROUTE_MATCH_COUNT}" -eq 0 ]; then
    if [ "${INTERNAL_CONTEXT_MODE}" != true ] \
        && [ "${CALLER_EXPLICIT_ROUTE}" = true ]; then
      ROUTE_MODE=legacy_explicit
    else
      reject_completion unknown_durable_launch_identity
    fi
  elif [ "${ROUTE_MATCH_COUNT}" -ne 1 ]; then
    reject_completion duplicate_durable_launch_identity
  fi
  if [ "${ROUTE_MATCH_COUNT}" -eq 1 ]; then
    ROUTE_MODE=durable
    if [ "${INTERNAL_CONTEXT_MODE}" = true ]; then
      RUN_ID="$(jq -r '.run_id' <<<"${ROUTE_ACTION_JSON}")"
      if [ -z "${RUN_ID}" ] || [ "${#RUN_ID}" -gt 512 ]; then
        reject_completion invalid_durable_launch_run_identity
      fi
      if [ "${RUN_ID}" != "${SESSION_BOOTSTRAP_RUN_ID}" ]; then
        reject_completion openclaw_bootstrap_run_identity_mismatch
      fi
    fi
    ACTION_CHILD_LABEL="$(jq -r '.child_label' <<<"${ROUTE_ACTION_JSON}")"
    if [ -n "${CHILD_LABEL}" ] \
        && [ -n "${ACTION_CHILD_LABEL}" ] \
        && [ "${CHILD_LABEL}" != "${ACTION_CHILD_LABEL}" ]; then
      reject_completion conflicting_durable_launch_label
    fi

    PROJECT_FULL="$(jq -r '.project' <<<"${ROUTE_ACTION_JSON}")"
    if [ "${PROJECT_ENV_SET}" = x ] \
        && [ "${CALLER_PROJECT}" != "${PROJECT_FULL##*/}" ]; then
      reject_completion explicit_project_conflicts_with_durable_route
    fi
    if [ "${GROUP_ENV_SET}" = x ] \
        && [ "${CALLER_GROUP}" != "${PROJECT_FULL%/*}" ]; then
      reject_completion explicit_group_conflicts_with_durable_route
    fi
    ROUTED_IID="$(jq -r '.iid' <<<"${ROUTE_ACTION_JSON}")"
    ROUTED_ATTEMPT_NUMBER="$(jq -r '.attempt_number' <<<"${ROUTE_ACTION_JSON}")"
    PROJECT="${PROJECT_FULL##*/}"
    GROUP="${PROJECT_FULL%/*}"

    [ -f "${GITLAB_RESOLVER_SCRIPT}" ] \
      || reject_completion gitlab_route_unavailable
    [ -f "${REPO_RESOLVER_SCRIPT}" ] \
      || reject_completion repo_route_unavailable
    DEFAULT_CONFIG="${CONFIG_DIR}/campaign_defaults.env"
    LOCAL_CONFIG="${CONFIG_DIR}/campaign_defaults.local.env"
    [ -f "${DEFAULT_CONFIG}" ] || reject_completion invalid_campaign_config

    # Resolve the complete target tuple before reading campaign path defaults.
    # gitlab_env_resolver uses GLAB_AUTH_RESOLVE_ONLY, so this performs no auth
    # request and never prints the token it returns into this shell.
    # shellcheck disable=SC1090
    source "${GITLAB_RESOLVER_SCRIPT}"
    GITLAB_HOST_RESOLVED="${GITLAB_HOST}"
    GITLAB_PROTOCOL_RESOLVED="${GITLAB_API_PROTOCOL}"
    GITLAB_TOKEN_RESOLVED="${GITLAB_TOKEN}"

    if ! REPO_PARENT_EFFECTIVE="$(
      unset REPO_PARENT_PATH
      # shellcheck disable=SC1090
      source "${DEFAULT_CONFIG}"
      if [ -f "${LOCAL_CONFIG}" ]; then
        # shellcheck disable=SC1090
        source "${LOCAL_CONFIG}"
      fi
      printf '%s' "${REPO_PARENT_PATH:-/data}"
    )"; then
      reject_completion invalid_campaign_config
    fi

    if ! RESOLVED_REPO_PATH="$(
      PROJECT_FULL="${PROJECT_FULL}" \
      REPO_PARENT_PATH="${REPO_PARENT_EFFECTIVE}" \
      GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_RESOLVED}" \
      GITLAB_HOST="${GITLAB_HOST_RESOLVED}" \
        bash "${REPO_RESOLVER_SCRIPT}"
    )"; then
      reject_completion invalid_routed_repo_path
    fi
    if [ "${CALLER_REPO_PARENT_SET}" = x ]; then
      CALLER_REPO_PARENT_NORMALIZED="${CALLER_REPO_PARENT}"
      while [ "${CALLER_REPO_PARENT_NORMALIZED}" != "/" ] \
          && [[ "${CALLER_REPO_PARENT_NORMALIZED}" == */ ]]; do
        CALLER_REPO_PARENT_NORMALIZED="${CALLER_REPO_PARENT_NORMALIZED%/}"
      done
      if [ "${CALLER_REPO_PARENT_NORMALIZED}/${PROJECT}" \
          != "${RESOLVED_REPO_PATH}" ]; then
        reject_completion explicit_repo_parent_conflicts_with_durable_route
      fi
    fi
    if [ "${CALLER_REPO_PATH_SET}" = x ] \
        && [ "${CALLER_REPO_PATH}" != "${RESOLVED_REPO_PATH}" ]; then
      reject_completion explicit_repo_path_conflicts_with_durable_route
    fi

    REPO_PARENT_PATH="${RESOLVED_REPO_PATH%/*}"
    GITLAB_HOST="${GITLAB_HOST_RESOLVED}"
    GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_RESOLVED}"
    GITLAB_TOKEN="${GITLAB_TOKEN_RESOLVED}"
    unset PROJECT_URI
    export PROJECT GROUP PROJECT_FULL REPO_PARENT_PATH
    export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
  fi
fi

if [ "${ROUTE_MODE}" = legacy_explicit ]; then
  if [ "${PROJECT_ENV_SET}" != x ] \
      || [ "${GROUP_ENV_SET}" != x ] \
      || [ -z "${CALLER_PROJECT}" ] \
      || [ -z "${CALLER_GROUP}" ] \
      || [ -z "${GITLAB_TOKEN:-}" ]; then
    reject_completion incomplete_explicit_route
  fi
  if ! [[ "${CALLER_PROJECT}" =~ ^[A-Za-z0-9._-]+$ ]] \
      || [ "${CALLER_PROJECT}" = . ] \
      || [ "${CALLER_PROJECT}" = .. ]; then
    reject_completion invalid_explicit_project_slug
  fi
  if ! [[ "${CALLER_GROUP}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
      || [[ "/${CALLER_GROUP}/" == *"/../"* ]] \
      || [[ "/${CALLER_GROUP}/" == *"/./"* ]]; then
    reject_completion invalid_explicit_group
  fi
  unset PROJECT_FULL PROJECT_URI
fi

# Route and target resolution are complete before these project-scoped helpers
# are loaded. env_paths repeats the local-test host fence; _dispatch_lib then
# supplies the pending-state authentication and strict worker parser.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

if ! WORKER_JSON="$(completion_extract_unique_worker_reply "${ASSISTANT_TEXT}")"; then
  reject_completion invalid_or_ambiguous_worker_json
fi
IID="$(jq -r '.iid' <<<"${WORKER_JSON}")"
ATTEMPT_NUMBER="$(jq -r '.attempt_number' <<<"${WORKER_JSON}")"

if [ "${ROUTE_MODE}" = durable ] \
    && { [ "${IID}" != "${ROUTED_IID}" ] \
      || [ "${ATTEMPT_NUMBER}" != "${ROUTED_ATTEMPT_NUMBER}" ]; }; then
  reject_completion worker_identity_mismatch
fi

# The unlocked lookup is only an early rejection/route decision.  The invoked
# followup repeats the exact check while holding the campaign lock.
STATE_JSON="$(load_state)"
PENDING_AT_IID="$(jq -c --argjson iid "${IID}" \
  '.pending_subagents[($iid|tostring)] // null' <<<"${STATE_JSON}")"
IDENTITY_MATCHES="$(jq -c \
  --arg run_id "${RUN_ID}" \
  --arg child_session_key "${CHILD_SESSION_KEY}" '
  [(.pending_subagents // {}) | to_entries[]
    | select(.value.run_id == $run_id
      and .value.child_session_key == $child_session_key)]
' <<<"${STATE_JSON}")"
MATCH_COUNT="$(jq -r 'length' <<<"${IDENTITY_MATCHES}")"

if [ "${MATCH_COUNT}" -gt 1 ]; then
  reject_completion ambiguous_pending_identity
fi
if [ "${PENDING_AT_IID}" != null ]; then
  if [ "${MATCH_COUNT}" -ne 1 ] \
      || [ "$(jq -r '.[0].key' <<<"${IDENTITY_MATCHES}")" != "${IID}" ]; then
    reject_completion pending_identity_mismatch
  fi
  if ! completion_authenticate_pending \
      "${PENDING_AT_IID}" "${ATTEMPT_NUMBER}" "${RUN_ID}" \
      "${CHILD_SESSION_KEY}" "${CHILD_LABEL}" >/dev/null; then
    reject_completion pending_identity_mismatch
  fi
elif [ "${MATCH_COUNT}" -ne 0 ]; then
  # The worker JSON named a different IID than the unique pending identity.
  reject_completion worker_identity_mismatch
fi

# With no pending entry this is a harmless duplicate/stale delivery.  Let the
# followup return its existing idempotent stale or durable-handoff-recovery
# envelope; it performs no terminal mutation without current pending state.
CALLBACK_RUN_ID="${RUN_ID}" \
CALLBACK_CHILD_SESSION_KEY="${CHILD_SESSION_KEY}" \
CALLBACK_LABEL="${CHILD_LABEL}" \
IID="${IID}" ATTEMPT_NUMBER="${ATTEMPT_NUMBER}" \
  bash "${FOLLOWUP_SCRIPT}" <<<"${WORKER_JSON}"
