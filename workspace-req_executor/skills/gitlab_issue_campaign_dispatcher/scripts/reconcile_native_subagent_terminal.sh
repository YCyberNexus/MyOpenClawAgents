#!/usr/bin/env bash
# Reconcile a callback-lost OpenClaw child from the authoritative local runtime
# registry. The caller supplies only the already-persisted scheduler identity;
# this wrapper never accepts worker output and never invents a successful
# terminal result. A terminal registry entry is delegated to the existing
# authenticated completion ingester, which revalidates the transcript, durable
# launch action, and project pending claim before Phase 6 can mutate state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGEST_COMPLETION_CMD="${INGEST_COMPLETION_CMD:-${SCRIPT_DIR}/ingest_subagent_completion.sh}"

die() {
  echo "reconcile_native_subagent_terminal.sh: $*" >&2
  exit 2
}

case "${INGEST_COMPLETION_CMD}" in
  /*) ;;
  *) die "INGEST_COMPLETION_CMD must be absolute" ;;
esac
case "${INGEST_COMPLETION_CMD}" in
  *$'\n'*|*$'\r'*|*$'\t'*) die "INGEST_COMPLETION_CMD contains control characters" ;;
esac
[ -f "${INGEST_COMPLETION_CMD}" ] && [ -r "${INGEST_COMPLETION_CMD}" ] \
  || die "INGEST_COMPLETION_CMD must be a readable regular file"

if ! INPUT_JSON="$(jq -ce '
  def clean_string($max):
    type == "string" and length > 0 and length <= $max
    and (explode | all(. >= 32 and . != 127));
  if type == "object"
    and (keys | sort) == [
      "child_label","child_session_key","claim_generation",
      "execution_id","iid","job_id","run_id"
    ]
    and (.job_id | clean_string(1024))
    and (.claim_generation | type == "number" and . == floor and . > 0)
    and (.iid | type == "number" and . == floor and . > 0)
    and (.execution_id | type == "number" and . == floor and . > 0)
    and (.run_id | clean_string(512))
    and (.child_session_key | type == "string"
      and test("^agent:req_executor:subagent:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
    and (.child_label | type == "string"
      and test("^reqx-iid[1-9][0-9]*-gen[1-9][0-9]*-[0-9a-f]{40}$"))
  then . else error("invalid runtime reconciliation identity") end
' 2>/dev/null)"; then
  die "stdin must be one strict native-subagent reconciliation identity"
fi

JOB_ID="$(jq -r '.job_id' <<<"${INPUT_JSON}")"
CLAIM_GENERATION="$(jq -r '.claim_generation' <<<"${INPUT_JSON}")"
IID="$(jq -r '.iid' <<<"${INPUT_JSON}")"
EXECUTION_ID="$(jq -r '.execution_id' <<<"${INPUT_JSON}")"
CHILD_SESSION_KEY="$(jq -r '.child_session_key' <<<"${INPUT_JSON}")"
CHILD_LABEL="$(jq -r '.child_label' <<<"${INPUT_JSON}")"

emit_nonterminal() {
  local status="$1" reason="$2"
  jq -cn \
    --arg status "${status}" \
    --arg job_id "${JOB_ID}" \
    --argjson claim_generation "${CLAIM_GENERATION}" \
    --argjson iid "${IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg reason "${reason}" '{
    status:$status,
    job_id:$job_id,
    claim_generation:$claim_generation,
    iid:$iid,
    execution_id:$execution_id,
    callback_status:"",
    terminal_status:"",
    cleanup:{action:"skip",target:"",reason:$reason}
  }'
}

OPENCLAW_STATE_ROOT="${OPENCLAW_STATE_DIR:-${HOME:?}/.openclaw}"
case "${OPENCLAW_STATE_ROOT}" in
  /*) ;;
  *) emit_nonterminal runtime_unavailable unsafe_openclaw_state_root; exit 0 ;;
esac
case "/${OPENCLAW_STATE_ROOT#/}/" in
  */../*|*/./*) emit_nonterminal runtime_unavailable unsafe_openclaw_state_root; exit 0 ;;
esac
case "${OPENCLAW_STATE_ROOT}" in
  /|*$'\n'*|*$'\r'*|*$'\t'*)
    emit_nonterminal runtime_unavailable unsafe_openclaw_state_root
    exit 0
    ;;
esac
if [ ! -d "${OPENCLAW_STATE_ROOT}" ] || [ -L "${OPENCLAW_STATE_ROOT}" ]; then
  emit_nonterminal runtime_unavailable openclaw_state_root_unavailable
  exit 0
fi

OPENCLAW_SESSIONS_DIR="${OPENCLAW_STATE_ROOT}/agents/req_executor/sessions"
if [ ! -d "${OPENCLAW_SESSIONS_DIR}" ] \
    || [ -L "${OPENCLAW_SESSIONS_DIR}" ]; then
  emit_nonterminal runtime_unavailable openclaw_sessions_registry_unavailable
  exit 0
fi
OPENCLAW_SESSIONS_DIR_CANON="$(cd -P "${OPENCLAW_SESSIONS_DIR}" && pwd)"
OPENCLAW_REGISTRY_FILE="${OPENCLAW_SESSIONS_DIR_CANON}/sessions.json"
if [ ! -f "${OPENCLAW_REGISTRY_FILE}" ] \
    || [ -L "${OPENCLAW_REGISTRY_FILE}" ]; then
  emit_nonterminal runtime_unavailable openclaw_sessions_registry_unavailable
  exit 0
fi
REGISTRY_BYTES="$(wc -c <"${OPENCLAW_REGISTRY_FILE}" | tr -d '[:space:]')"
if ! [[ "${REGISTRY_BYTES}" =~ ^[1-9][0-9]*$ ]] \
    || [ "${REGISTRY_BYTES}" -gt 16777216 ]; then
  die "OpenClaw sessions registry has an invalid size"
fi

if ! RUNTIME_ENTRY="$(jq -ce \
    --arg child_session_key "${CHILD_SESSION_KEY}" \
    --arg child_label "${CHILD_LABEL}" \
    --arg sessions_dir "${OPENCLAW_SESSIONS_DIR_CANON}" '
    def clean_string:
      type == "string" and length > 0
      and (explode | all(. >= 32 and . != 127));
    if type != "object" then error("registry is not an object") else . end
    | [to_entries[]
        | select(.key == $child_session_key
          or ((.value | type) == "object" and .value.label == $child_label))
      ] as $related
    | if ($related | length) == 0 then
        {runtime_state:"not_found",runtime_status:""}
      elif ($related | length) != 1 or $related[0].key != $child_session_key then
        error("runtime identity is ambiguous")
      else $related[0].value as $entry
      | if ($entry | type) != "object"
          or ($entry.sessionId | type) != "string"
          or ($entry.sessionId
            | test("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") | not)
          or $entry.sessionFile != ($sessions_dir + "/" + $entry.sessionId + ".jsonl")
          or $entry.label != $child_label
          or ($entry.spawnDepth | type != "number" or . != floor or . < 1)
          or $entry.subagentRole != "leaf"
          or ($entry.spawnedBy | clean_string | not)
          or ($entry.spawnedBy | startswith("agent:req_executor:") | not)
        then error("runtime identity does not match an executor child")
        elif (["done","failed","timeout","killed"] | index($entry.status)) != null
          and ($entry.endedAt | type == "number" and . == floor and . >= 0)
        then {
          runtime_state:"terminal",
          runtime_status:$entry.status
        }
        elif (($entry.status // "") == "" or $entry.status == "running")
          and (($entry.endedAt // null) == null)
        then {
          runtime_state:"active",
          runtime_status:($entry.status // "running")
        }
        else error("runtime entry is neither active nor terminal")
        end
      end
  ' "${OPENCLAW_REGISTRY_FILE}" 2>/dev/null)"; then
  die "OpenClaw sessions registry has conflicting runtime identity"
fi

RUNTIME_STATE="$(jq -r '.runtime_state' <<<"${RUNTIME_ENTRY}")"
case "${RUNTIME_STATE}" in
  not_found)
    emit_nonterminal runtime_not_found runtime_registry_has_no_matching_child
    exit 0
    ;;
  active)
    emit_nonterminal runtime_active runtime_child_is_still_active
    exit 0
    ;;
  terminal) ;;
  *) die "unsupported runtime registry state" ;;
esac

TERMINAL_REFERENCE="$(jq -cn \
  --arg child_session_key "${CHILD_SESSION_KEY}" '{
  kind:"openclaw_4_9_terminal_reference",
  childSessionKey:$child_session_key
}')"
set +e
INGEST_OUTPUT="$(printf '%s' "${TERMINAL_REFERENCE}" | \
  env -u PROJECT -u GROUP -u PROJECT_FULL -u PROJECT_URI -u REPO_PATH \
    bash "${INGEST_COMPLETION_CMD}" 2>/dev/null)"
INGEST_RC=$?
set -e
if [ "${INGEST_RC}" -ne 0 ] \
    || ! INGEST_JSON="$(jq -ce \
      --argjson iid "${IID}" \
      --argjson execution_id "${EXECUTION_ID}" '
      def clean_string:
        type == "string" and length > 0 and length <= 128
        and (explode | all(. >= 32 and . != 127));
      if type == "object"
        and (.callback_status | clean_string)
        and .iid == $iid
        and ((has("execution_id") | not) or .execution_id == $execution_id)
      then . else error("invalid completion ingester result") end
    ' <<<"${INGEST_OUTPUT}" 2>/dev/null)"; then
  die "authenticated completion ingester rejected the terminal runtime entry"
fi

CALLBACK_STATUS="$(jq -r '.callback_status' <<<"${INGEST_JSON}")"
TERMINAL_STATUS="$(jq -r '
  if (.terminal_status | type) == "string"
    and (.terminal_status | length) <= 128
    and (.terminal_status | explode | all(. >= 32 and . != 127))
  then .terminal_status else "" end
' <<<"${INGEST_JSON}")"
CLEANUP="$(jq -c '
  def safe_string($max):
    type == "string" and length <= $max
    and (explode | all(. >= 32 and . != 127));
  def clean_string($max):
    safe_string($max) and length > 0;
  if (.cleanup | type) == "object"
    and ((.cleanup.action == "kill"
      and (.cleanup.target | clean_string(512))
      and (.cleanup.reason | clean_string(512)))
      or (.cleanup.action == "skip"
        and (.cleanup.target | safe_string(512))
        and (.cleanup.reason | clean_string(512))))
  then .cleanup
  else {
    action:"skip",target:"",
    reason:"terminal runtime reconciliation requested no cleanup"
  } end
' <<<"${INGEST_JSON}")"

jq -cn \
  --arg job_id "${JOB_ID}" \
  --argjson claim_generation "${CLAIM_GENERATION}" \
  --argjson iid "${IID}" \
  --argjson execution_id "${EXECUTION_ID}" \
  --arg callback_status "${CALLBACK_STATUS}" \
  --arg terminal_status "${TERMINAL_STATUS}" \
  --argjson cleanup "${CLEANUP}" '{
  status:"runtime_terminal_reconciled",
  job_id:$job_id,
  claim_generation:$claim_generation,
  iid:$iid,
  execution_id:$execution_id,
  callback_status:$callback_status,
  terminal_status:$terminal_status,
  cleanup:$cleanup
}'
