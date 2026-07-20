#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECONCILE_SCRIPT="${SKILL_DIR}/scripts/resolve_executor_batch_reconcile.sh"

fail() {
  echo "test_executor_batch_reconcile.sh: $*" >&2
  exit 1
}

[ -x "${RECONCILE_SCRIPT}" ] || fail "fixed reconcile wrapper is missing or not executable"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-reconcile.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_BIN="${TEST_ROOT}/fake-bin"
CALL_LOG="${TEST_ROOT}/calls.log"
mkdir -p "${CONFIG_DIR}" "${SCHEDULER_ROOT}/launch_actions" "${FAKE_BIN}"
: >"${CALL_LOG}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF
cat >"${FAKE_BIN}/scheduler_env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}"
export EXECUTOR_MAX_CONCURRENCY=3
export SCHEDULER_STATE_FILE="${SCHEDULER_ROOT}/scheduler_state.json"
export SCHEDULER_LOCK_FILE="${SCHEDULER_ROOT}/scheduler.lock"
export BATCHES_ROOT="${SCHEDULER_ROOT}/batches"
export CALLBACK_INBOX="${SCHEDULER_ROOT}/callback_inbox"
export CALLBACK_OUTBOX="${SCHEDULER_ROOT}/callback_outbox"
mkdir -p "${BATCHES_ROOT}" "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}"
EOF
cat >"${FAKE_BIN}/record_spawn.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
jq -e '
  (keys | sort) == [
    "child_session_key","claim_generation","execution_id","iid",
    "job_id","project","run_id","status"
  ]
  and .job_id == "A:snapshot-0"
  and .claim_generation == 1
  and .project == "group/repo"
  and .iid == 42
  and .execution_id == 1
  and .status == "spawned"
  and .run_id == "runtime-run-1"
  and .child_session_key == "agent:req_executor:subagent:runtime-1"
' <<<"${input}" >/dev/null
printf '%s\n' found >>"${CALL_LOG}"
jq -cn '{status:"spawned_recorded",job_id:"A:snapshot-0",claim_generation:1}'
EOF
chmod +x "${FAKE_BIN}"/*.sh

action_path() {
  local digest
  digest="$(printf '%s' 'A:snapshot-0' | shasum -a 256 | awk '{print $1}')"
  printf '%s\n' "${SCHEDULER_ROOT}/launch_actions/${digest}.json"
}

write_fixture() {
  cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","project":"group/repo","iid":42,
    "status":"reserved","claim_generation":1,"claim_token":null
  }
}}
EOF
  jq -cnS '{
    version:1,job_id:"A:snapshot-0",project:"group/repo",iid:42,
    batch_id:"A",snapshot_index:0,execution_id:1,
    child_label:"#42-att-001",payload_path:"/private/payload/path",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    claim_generation:1,claim_token:"private-claim-must-not-leak",
    stage:"action_emitted",outcome:null,ack:null,created_at:1,updated_at:1
  }' >"$(action_path)"
  chmod 600 "$(action_path)"
}

run_reconcile() {
  local input="$1"
  printf '%s' "${input}" | \
    CONFIG_DIR="${CONFIG_DIR}" SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    CALL_LOG="${CALL_LOG}" \
    SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
    RECORD_SPAWN_CMD="${FAKE_BIN}/record_spawn.sh" \
    bash "${RECONCILE_SCRIPT}"
}

# Explicit no-match evidence is the only path that may reset the durable
# action. It leaves the scheduler's fenced generation intact so the next tick
# can allocate generation 2, and never exposes the private claim or payload.
write_fixture
not_found_input="$(jq -cn '{
  job_id:"A:snapshot-0",claim_generation:1,resolution:"not_found",
  evidence:"subagents_list_no_matching_label"
}')"
not_found_output="$(run_reconcile "${not_found_input}")" || fail "not_found reconciliation failed"
jq -e '
  (keys | sort) == ["claim_generation","job_id","status"]
  and .status == "reset_for_next_generation"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 1
  and (tostring | contains("private-claim") | not)
  and (tostring | contains("/private/payload") | not)
' <<<"${not_found_output}" >/dev/null || fail "not_found returned an unsafe envelope"
jq -e '
  .stage == "topup_prepared"
  and .claim_generation == 0 and .claim_token == null
  and .reconciliation == {
    generation:1,resolution:"not_found",
    evidence:"subagents_list_no_matching_label",resolved_at:.reconciliation.resolved_at
  }
' "$(action_path)" >/dev/null || fail "not_found did not durably reset the action"
jq -e '
  .active_jobs["A:snapshot-0"].status == "reserved"
  and .active_jobs["A:snapshot-0"].claim_generation == 1
  and .active_jobs["A:snapshot-0"].claim_token == null
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "not_found mutated the scheduler fence"
replayed="$(run_reconcile "${not_found_input}")" || fail "not_found replay failed"
[ "${replayed}" = "${not_found_output}" ] || fail "not_found replay is not idempotent"

# A runtime match supplements the lost acknowledgement and delegates to the
# project-first post-spawn recorder with the original generation.
write_fixture
: >"${CALL_LOG}"
found_input="$(jq -cn '{
  job_id:"A:snapshot-0",claim_generation:1,resolution:"spawned",
  run_id:"runtime-run-1",
  child_session_key:"agent:req_executor:subagent:runtime-1"
}')"
found_output="$(run_reconcile "${found_input}")" || fail "spawned reconciliation failed"
jq -e '
  (keys | sort) == ["claim_generation","job_id","status"]
  and .status == "spawned_recorded"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 1
  and (tostring | contains("private-claim") | not)
  and (tostring | contains("/private/payload") | not)
' <<<"${found_output}" >/dev/null || fail "spawned reconciliation returned an unsafe envelope"
[ "$(cat "${CALL_LOG}")" = found ] || fail "spawned reconciliation did not call fixed recorder once"

# Loose evidence and extra fields are rejected before any state change.
write_fixture
: >"${CALL_LOG}"
set +e
bad_output="$(run_reconcile '{"job_id":"A:snapshot-0","claim_generation":1,"resolution":"not_found","evidence":"I think it is gone","extra":true}' 2>&1)"
bad_rc=$?
set -e
[ "${bad_rc}" -eq 2 ] || fail "loose reconciliation input was accepted"
[ -z "$(cat "${CALL_LOG}")" ] || fail "invalid reconciliation reached a recorder"
case "${bad_output}" in
  *private-claim*|*/private/payload*) fail "validation error leaked private state" ;;
esac

# Pre-upgrade large-payload actions have no exact bootstrap identity. They are
# intentionally rejected instead of being silently migrated; operators must
# explicitly re-enqueue the item through the normal scheduler wrappers.
write_fixture
jq 'del(.expected_task_sha256,.expected_task_bytes)' "$(action_path)" \
  >"${TEST_ROOT}/legacy-action.json"
mv "${TEST_ROOT}/legacy-action.json" "$(action_path)"
cp "$(action_path)" "${TEST_ROOT}/legacy-action-before.json"
set +e
legacy_output="$(run_reconcile "${not_found_input}" 2>&1)"
legacy_rc=$?
set -e
[ "${legacy_rc}" -ne 0 ] \
  || fail "legacy action without exact task identity was silently migrated"
cmp -s "$(action_path)" "${TEST_ROOT}/legacy-action-before.json" \
  || fail "rejected legacy action was mutated instead of requiring re-enqueue"
case "${legacy_output}" in
  *private-claim*|*/private/payload*) fail "legacy rejection leaked private state" ;;
esac

echo "ok emitted spawn reconciliation requires explicit runtime evidence"
