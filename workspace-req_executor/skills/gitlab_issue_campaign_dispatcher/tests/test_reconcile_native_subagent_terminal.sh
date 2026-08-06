#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECONCILE_SCRIPT="${SKILL_DIR}/scripts/reconcile_native_subagent_terminal.sh"

fail() {
  echo "test_reconcile_native_subagent_terminal.sh: $*" >&2
  exit 1
}

[ -x "${RECONCILE_SCRIPT}" ] \
  || fail "native runtime reconciliation wrapper is missing or not executable"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-native-runtime.XXXXXX")"
OPENCLAW_STATE_ROOT="${TEST_ROOT}/openclaw"
SESSIONS_DIR="${OPENCLAW_STATE_ROOT}/agents/req_executor/sessions"
FAKE_BIN="${TEST_ROOT}/fake-bin"
CALL_LOG="${TEST_ROOT}/ingest-calls.log"
mkdir -p "${SESSIONS_DIR}" "${FAKE_BIN}"
SESSIONS_DIR="$(cd -P "${SESSIONS_DIR}" && pwd)"
: >"${CALL_LOG}"

CHILD_SESSION_KEY='agent:req_executor:subagent:11111111-1111-4111-8111-111111111111'
SESSION_ID='22222222-2222-4222-8222-222222222222'
CHILD_LABEL='reqx-iid42-gen3-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
SESSION_FILE="${SESSIONS_DIR}/${SESSION_ID}.jsonl"

cat >"${FAKE_BIN}/ingest.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
jq -e '
  (keys | sort) == ["childSessionKey","kind"]
  and .kind == "openclaw_4_9_terminal_reference"
  and .childSessionKey == "agent:req_executor:subagent:11111111-1111-4111-8111-111111111111"
' <<<"${input}" >/dev/null
[ "${PROJECT+x}" != x ] \
  && [ "${GROUP+x}" != x ] \
  && [ "${PROJECT_FULL+x}" != x ] \
  && [ "${PROJECT_URI+x}" != x ] \
  && [ "${REPO_PATH+x}" != x ]
printf '%s\n' called >>"${CALL_LOG}"
if [ "${FAKE_INGEST_REJECT:-0}" = 1 ]; then
  jq -cn '{completion_status:"rejected",reason:"fixture_rejection"}'
  exit 3
fi
jq -cn '{
  callback_status:"handled",iid:42,execution_id:7,
  terminal_status:"blocked",
  cleanup:{action:"skip",target:"",reason:"terminal child already stopped"}
}'
EOF
chmod +x "${FAKE_BIN}/ingest.sh"

INPUT_JSON="$(jq -cn \
  --arg child_session_key "${CHILD_SESSION_KEY}" \
  --arg child_label "${CHILD_LABEL}" '{
  job_id:"A:snapshot-0",
  claim_generation:3,
  iid:42,
  execution_id:7,
  run_id:"runtime-run-42",
  child_session_key:$child_session_key,
  child_label:$child_label
}')"

write_registry() {
  local status="$1" ended_at="$2"
  jq -cnS \
    --arg child_session_key "${CHILD_SESSION_KEY}" \
    --arg session_id "${SESSION_ID}" \
    --arg session_file "${SESSION_FILE}" \
    --arg child_label "${CHILD_LABEL}" \
    --arg status "${status}" \
    --argjson ended_at "${ended_at}" '{
    ($child_session_key):({
      sessionId:$session_id,
      sessionFile:$session_file,
      label:$child_label,
      spawnDepth:1,
      subagentRole:"leaf",
      spawnedBy:"agent:req_executor:batch-A"
    }
    + (if $status == "" then {} else {status:$status} end)
    + (if $ended_at == null then {} else {endedAt:$ended_at} end))
  }' >"${SESSIONS_DIR}/sessions.json"
}

run_reconcile() {
  printf '%s' "${INPUT_JSON}" | \
    OPENCLAW_STATE_DIR="${OPENCLAW_STATE_ROOT}" \
    INGEST_COMPLETION_CMD="${FAKE_BIN}/ingest.sh" \
    CALL_LOG="${CALL_LOG}" \
    PROJECT=ambient-project GROUP=ambient-group \
    PROJECT_FULL=ambient/full PROJECT_URI=ambient-uri REPO_PATH=ambient-path \
      bash "${RECONCILE_SCRIPT}"
}

# An active runtime child is observational only. It must not invoke the
# completion ingester or mutate anything through a fabricated terminal result.
write_registry running null
active_output="$(run_reconcile)" || fail "active child probe failed"
jq -e '
  (keys | sort) == [
    "callback_status","claim_generation","cleanup","execution_id",
    "iid","job_id","status","terminal_status"
  ]
  and .status == "runtime_active"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 3
  and .iid == 42 and .execution_id == 7
  and .callback_status == "" and .terminal_status == ""
  and .cleanup.action == "skip"
' <<<"${active_output}" >/dev/null \
  || fail "active child returned an invalid safe envelope"
[ ! -s "${CALL_LOG}" ] || fail "active child reached the completion ingester"

# A registry miss is not terminal evidence. Leave the scheduler claim intact
# for a later heartbeat or the ordinary deadline-based timeout backstop.
printf '%s\n' '{}' >"${SESSIONS_DIR}/sessions.json"
not_found_output="$(run_reconcile)" || fail "missing child probe failed"
jq -e '.status == "runtime_not_found" and .cleanup.action == "skip"' \
  <<<"${not_found_output}" >/dev/null \
  || fail "missing child was not left untouched"
[ ! -s "${CALL_LOG}" ] || fail "missing child reached the completion ingester"

# A terminal runtime entry delegates exactly one minimal selector to the fixed
# ingester. The runtime wrapper never forwards worker prose or ambient routing.
write_registry done 1000
terminal_output="$(run_reconcile)" || fail "terminal child reconciliation failed"
jq -e '
  .status == "runtime_terminal_reconciled"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 3
  and .iid == 42 and .execution_id == 7
  and .callback_status == "handled"
  and .terminal_status == "blocked"
  and .cleanup == {
    action:"skip",target:"",reason:"terminal child already stopped"
  }
' <<<"${terminal_output}" >/dev/null \
  || fail "terminal child did not preserve the authenticated ingester outcome"
[ "$(cat "${CALL_LOG}")" = called ] \
  || fail "terminal child did not invoke the completion ingester exactly once"

# A terminal-looking record with a conflicting duplicate label is ambiguous
# runtime evidence and must fail before ingestion.
: >"${CALL_LOG}"
jq --arg duplicate_key \
    'agent:req_executor:subagent:33333333-3333-4333-8333-333333333333' \
   --arg session_file "${SESSIONS_DIR}/44444444-4444-4444-8444-444444444444.jsonl" \
   --arg child_label "${CHILD_LABEL}" '
  . + {($duplicate_key):{
    sessionId:"44444444-4444-4444-8444-444444444444",
    sessionFile:$session_file,
    label:$child_label,
    status:"done",endedAt:1001,spawnDepth:1,subagentRole:"leaf",
    spawnedBy:"agent:req_executor:batch-B"
  }}
' "${SESSIONS_DIR}/sessions.json" >"${TEST_ROOT}/ambiguous-sessions.json"
mv "${TEST_ROOT}/ambiguous-sessions.json" "${SESSIONS_DIR}/sessions.json"
set +e
ambiguous_output="$(run_reconcile 2>&1)"
ambiguous_rc=$?
set -e
[ "${ambiguous_rc}" -eq 2 ] \
  || fail "ambiguous runtime identity was accepted"
[ ! -s "${CALL_LOG}" ] \
  || fail "ambiguous runtime identity reached the completion ingester"
case "${ambiguous_output}" in
  *runtime-run-42*|*ambient-project*)
    fail "runtime reconciliation error leaked caller identity"
    ;;
esac

# A trusted terminal entry is still not enough when the authenticated ingester
# rejects its transcript/durable route. No successful reconcile envelope may
# be fabricated around that rejection.
write_registry failed 1002
: >"${CALL_LOG}"
set +e
rejected_output="$(FAKE_INGEST_REJECT=1 run_reconcile 2>&1)"
rejected_rc=$?
set -e
[ "${rejected_rc}" -eq 2 ] \
  || fail "completion ingester rejection was hidden"
[ "$(cat "${CALL_LOG}")" = called ] \
  || fail "terminal rejection fixture did not reach the ingester once"
case "${rejected_output}" in
  *fixture_rejection*|*runtime-run-42*|*ambient-project*)
    fail "ingester rejection leaked untrusted or ambient details"
    ;;
esac

# Missing runtime storage is a non-mutating availability result, not proof that
# the child ended or authorization to synthesize a callback.
MISSING_STATE_ROOT="${TEST_ROOT}/missing-openclaw"
unavailable_output="$(printf '%s' "${INPUT_JSON}" | \
  OPENCLAW_STATE_DIR="${MISSING_STATE_ROOT}" \
  INGEST_COMPLETION_CMD="${FAKE_BIN}/ingest.sh" \
    bash "${RECONCILE_SCRIPT}")" \
  || fail "missing runtime storage was not handled safely"
jq -e '.status == "runtime_unavailable" and .cleanup.action == "skip"' \
  <<<"${unavailable_output}" >/dev/null \
  || fail "runtime unavailability was mistaken for terminal evidence"

echo "ok heartbeat reconciles only authoritative terminal native children"
