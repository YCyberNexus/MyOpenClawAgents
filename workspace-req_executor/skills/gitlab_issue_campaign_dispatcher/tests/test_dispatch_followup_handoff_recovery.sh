#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRAIN_INTENTS="${SKILL_DIR}/scripts/drain_driven_handoff_intents.sh"

fail() {
  echo "test_dispatch_followup_handoff_recovery.sh: $*" >&2
  exit 1
}

[ -x "${DRAIN_INTENTS}" ] \
  || fail "drain_driven_handoff_intents.sh is missing or not executable"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-handoff-recovery.XXXXXX")"
FOLLOWUP_PARENT="${TEST_ROOT}/repos"
FOLLOWUP_REPO="${FOLLOWUP_PARENT}/repo"
FOLLOWUP_SCRIPTS="${TEST_ROOT}/scripts"
FOLLOWUP_STATE="${FOLLOWUP_REPO}/.req_executor/_dispatcher/campaign_state.json"
FOLLOWUP_LOCK="${FOLLOWUP_REPO}/.req_executor/_dispatcher/campaign.lock"
FOLLOWUP_IMPORT_LOG="${TEST_ROOT}/import.log"
FOLLOWUP_NOTIFY_LOG="${TEST_ROOT}/notify.log"

mkdir -p \
  "${FOLLOWUP_REPO}/.git" \
  "${FOLLOWUP_SCRIPTS}" \
  "${FOLLOWUP_REPO}/.req_executor/_dispatcher/log" \
  "${FOLLOWUP_REPO}/.req_executor/issues/issue-42"
cp \
  "${SKILL_DIR}/scripts/dispatch_followup.sh" \
  "${SKILL_DIR}/scripts/_dispatch_lib.sh" \
  "${SKILL_DIR}/scripts/env_paths.sh" \
  "${SKILL_DIR}/scripts/git_network_guard.sh" \
  "${DRAIN_INTENTS}" \
  "${FOLLOWUP_SCRIPTS}/"

cat >"${FOLLOWUP_SCRIPTS}/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
evidence="${DISPATCHER_LOG_DIR}/reconcile-20260711T000000Z.json"
jq -cn --argjson iid "${MIN_IID:?}" '[{
  iid:$iid,
  is_closed_on_gitlab:false,
  is_done_on_gitlab:false,
  has_done_pr:false
}]' >"${evidence}"
printf '%s\n' "${evidence}"
EOF
cat >"${FOLLOWUP_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FOLLOWUP_SCRIPTS}/notify_dispatcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called >>"${FOLLOWUP_NOTIFY_LOG:?}"
exit 0
EOF
cat >"${FOLLOWUP_SCRIPTS}/post_result_note.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FOLLOWUP_SCRIPTS}"/*.sh

write_followup_state() {
  local attempt_number="$1"
  local claim_generation="$2"
  local claim_token="$3"
  jq -cnS \
    --argjson attempt_number "${attempt_number}" \
    --argjson claim_generation "${claim_generation}" \
    --arg claim_token "${claim_token}" '{
    project:"repo",
    repo_path:"unused",
    blocked_retry_limit:3,
    tick_seq:1,
    result_note_enabled:false,
    kill_subagent_on_terminal:false,
    pending_subagents:{
      "42":{
        attempt_number:$attempt_number,
        run_id:("run-42-" + ($attempt_number|tostring)),
        child_session_key:"agent:req_executor:subagent:42",
        spawned_at:"2026-07-11T00:00:00Z",
        placeholder:false,
        acpx_timeout_seconds:18000,
        job_id:"batch-A:snapshot-0",
        batch_id:"batch-A",
        snapshot_index:0,
        branch:"main",
        entry_mode:"auto",
        force_rerun_pr:false,
        memberships_source:"scheduler_active_job",
        claim_generation:$claim_generation,
        claim_token:$claim_token,
        bound_at:"2026-07-11T00:01:00Z"
      }
    },
    active_issue_iids:[42],
    active_issue_sessions:["issue-repo-42"],
    blocked_at_tick_by_iid:{},
    unfinished_iids:[],
    completed_iids:[],
    blocked_iids:[],
    failed_iids:[],
    timeout_iids:[],
    campaign_status:"waiting_for_callbacks"
  }' >"${FOLLOWUP_STATE}"
}

FAKE_IMPORTER="${TEST_ROOT}/fake-importer.sh"
cat >"${FAKE_IMPORTER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec 8>"${EXPECT_CAMPAIGN_LOCK:?}"
if ! flock -n 8; then
  echo "importer observed the campaign lock held" >&2
  exit 93
fi
flock -u 8
exec 8>&-

jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
' "${EXPECT_CAMPAIGN_STATE:?}" >/dev/null
jq -e \
  --arg event_id "${EXPECTED_EVENT_ID:?}" \
  --arg claim_token "${EXPECTED_CLAIM_TOKEN:?}" \
  --argjson claim_generation "${EXPECTED_CLAIM_GENERATION:?}" '
  .event_id == $event_id
  and .job_id == "batch-A:snapshot-0"
  and .memberships == []
  and .memberships_source == "scheduler_active_job"
  and .claim_generation == $claim_generation
  and .claim_token == $claim_token
  and .project == "group/repo"
  and .iid == 42
  and .status == "done"
' "${HANDOFF_FILE:?}" >/dev/null
printf '%s\n' "${HANDOFF_FILE}" >>"${FOLLOWUP_IMPORT_LOG:?}"
[ "${FOLLOWUP_IMPORT_RESULT:-success}" = success ] || exit 47
EOF
chmod +x "${FAKE_IMPORTER}"

run_followup() {
  local attempt_number="$1"
  local claim_generation="$2"
  local claim_token="$3"
  local import_result="$4"
  local fault="${5:-}"
  local event_id="batch-A:snapshot-0:claim-${claim_generation}:terminal-1"

  printf '%s\n' "{
    \"iid\":42,
    \"attempt_number\":${attempt_number},
    \"status\":\"done\",
    \"merge_request_url\":\"https://gitlab.example/group/repo/-/merge_requests/9\"
  }" | \
  PROJECT=repo \
  PROJECT_FULL=group/repo \
  GROUP=group \
  GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example \
  GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" \
  IID=42 \
  ATTEMPT_NUMBER="${attempt_number}" \
  CALLBACK_RUN_ID="run-42-${attempt_number}" \
  CALLBACK_CHILD_SESSION_KEY="agent:req_executor:subagent:42" \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  DRIVEN_HANDOFF_TEST_FAULT="${fault}" \
  EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  EXPECTED_EVENT_ID="${event_id}" \
  EXPECTED_CLAIM_GENERATION="${claim_generation}" \
  EXPECTED_CLAIM_TOKEN="${claim_token}" \
  FOLLOWUP_IMPORT_RESULT="${import_result}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh"
}

run_drain() {
  local event_id="$1"
  local claim_generation="$2"
  local claim_token="$3"
  local import_result="$4"
  local fault="${5:-}"

  PROJECT=repo \
  PROJECT_FULL=group/repo \
  GROUP=group \
  GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example \
  GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" \
  DRIVEN_HANDOFF_EVENT_ID="${event_id}" \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  DRIVEN_HANDOFF_TEST_FAULT="${fault}" \
  EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  EXPECTED_EVENT_ID="${event_id}" \
  EXPECTED_CLAIM_GENERATION="${claim_generation}" \
  EXPECTED_CLAIM_TOKEN="${claim_token}" \
  FOLLOWUP_IMPORT_RESULT="${import_result}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/drain_driven_handoff_intents.sh"
}

# First persist atomically drains pending and carries the complete canonical
# handoff intent. A deterministic crash before materialization must therefore
# leave enough claim-bound data for either callback replay or a periodic drain.
write_followup_state 1 1 claim-token-42
EVENT_1='batch-A:snapshot-0:claim-1:terminal-1'
HANDOFF_1="${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs/${EVENT_1}.json"
set +e
CRASH_OUTPUT="$(run_followup 1 1 claim-token-42 success crash_after_intent_persist \
  2>"${TEST_ROOT}/crash.err")"
CRASH_RC=$?
set -e
[ "${CRASH_RC}" -eq 86 ] \
  || fail "persist-to-handoff crash injection did not exit 86"
[ -z "${CRASH_OUTPUT}" ] \
  || fail "crash injection emitted a handled callback envelope"
[ ! -e "${HANDOFF_1}" ] \
  || fail "crash injection ran after handoff materialization"
[ ! -e "${FOLLOWUP_IMPORT_LOG}" ] \
  || fail "crash injection reached the importer"
jq -e --arg event_id "${EVENT_1}" '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
  and (.driven_handoff_intents | keys) == [$event_id]
  and .driven_handoff_intents[$event_id].version == 1
  and .driven_handoff_intents[$event_id].attempt_number == 1
  and .driven_handoff_intents[$event_id].handoff == {
    version:1,
    event_id:$event_id,
    job_id:"batch-A:snapshot-0",
    memberships:[],
    memberships_source:"scheduler_active_job",
    claim_generation:1,
    claim_token:"claim-token-42",
    project:"group/repo",
    iid:42,
    status:"done",
    mr_url:"https://gitlab.example/group/repo/-/merge_requests/9",
    reason:null
  }
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "persisted recovery intent was missing or non-canonical"

# Materialization failure is non-destructive: the periodic entry reports the
# pending event without calling importer or deleting the durable intent.
MATERIALIZE_FAILURE_OUTPUT="$(
  run_drain "${EVENT_1}" 1 claim-token-42 success fail_materialize
)"
jq -e --arg event_id "${EVENT_1}" '
  .status == "drained"
  and .intent_count == 1
  and .results == [{
    event_id:$event_id,
    status:"materialize_pending",
    handoff_path:null,
    importer_rc:null,
    intent_cleared:false
  }]
' <<<"${MATERIALIZE_FAILURE_OUTPUT}" >/dev/null \
  || fail "materialization failure did not remain explicitly pending"
[ ! -e "${HANDOFF_1}" ] \
  || fail "faulted materialization created a handoff"
[ ! -e "${FOLLOWUP_IMPORT_LOG}" ] \
  || fail "faulted materialization called importer"
jq -e --arg event_id "${EVENT_1}" \
  '.driven_handoff_intents[$event_id].handoff.event_id == $event_id' \
  "${FOLLOWUP_STATE}" >/dev/null \
  || fail "materialization failure deleted the durable intent"

# Redelivering the same callback now has no pending entry. It must select the
# exact IID+attempt intent, materialize the same stable event, import without
# holding the project lock, and only then clear that exact intent.
RECOVERY_OUTPUT="$(run_followup 1 1 claim-token-42 success)"
jq -e --arg event_id "${EVENT_1}" '
  .callback_status == "handoff_recovered"
  and .iid == 42
  and .attempt_number == 1
  and .handoff_event_id == $event_id
  and .handoff_import_status == "imported"
  and .handoff_path != ""
' <<<"${RECOVERY_OUTPUT}" >/dev/null \
  || fail "stale callback did not recover its durable handoff intent"
[ -f "${HANDOFF_1}" ] \
  || fail "stale callback recovery did not materialize the handoff"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 1 ] \
  || fail "stale callback recovery did not import exactly once"
jq -e '
  ((.driven_handoff_intents // {}) | length) == 0
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "successful stale recovery did not clear its exact intent"

# A normal callback with an importer failure still returns handled/pending and
# retains both the materialized handoff and intent. The independent drain entry
# must later finish it without any callback redelivery.
write_followup_state 2 2 claim-token-43
EVENT_2='batch-A:snapshot-0:claim-2:terminal-1'
HANDOFF_2="${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs/${EVENT_2}.json"
PENDING_OUTPUT="$(run_followup 2 2 claim-token-43 fail)"
jq -e --arg event_id "${EVENT_2}" '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .handoff_import_status == "pending"
  and .handoff_path != ""
  and (.chat_summary | contains("handoff_import=pending"))
' <<<"${PENDING_OUTPUT}" >/dev/null \
  || fail "normal callback did not expose the pending durable handoff"
[ -f "${HANDOFF_2}" ] \
  || fail "import failure rolled back its materialized handoff"
jq -e --arg event_id "${EVENT_2}" '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
  and .driven_handoff_intents[$event_id].handoff.event_id == $event_id
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "import failure did not retain the durable intent"

PERIODIC_OUTPUT="$(run_drain "${EVENT_2}" 2 claim-token-43 success)"
jq -e --arg event_id "${EVENT_2}" '
  .status == "drained"
  and .intent_count == 1
  and .results == [{
    event_id:$event_id,
    status:"imported",
    handoff_path:(.results[0].handoff_path),
    importer_rc:0,
    intent_cleared:true
  }]
' <<<"${PERIODIC_OUTPUT}" >/dev/null \
  || fail "periodic drain did not finish the retained handoff intent"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 3 ] \
  || fail "periodic recovery did not perform the expected importer replay"
jq -e '
  ((.driven_handoff_intents // {}) | length) == 0
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "periodic recovery did not clear the imported intent"

# Once import and exact cleanup have completed, both recovery entry points are
# strict no-ops: neither may reconstruct an event from stale callback input nor
# invoke the importer again.
NOOP_DRAIN_OUTPUT="$(run_drain "${EVENT_2}" 2 claim-token-43 success)"
jq -e '
  .status == "drained"
  and .intent_count == 0
  and .results == []
' <<<"${NOOP_DRAIN_OUTPUT}" >/dev/null \
  || fail "completed periodic drain was not idempotent"
NOOP_CALLBACK_OUTPUT="$(run_followup 2 2 claim-token-43 success)"
jq -e '
  .callback_status == "stale_or_already_drained"
  and .iid == 42
  and .attempt_number == 2
' <<<"${NOOP_CALLBACK_OUTPUT}" >/dev/null \
  || fail "completed callback replay was not idempotently stale"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 3 ] \
  || fail "completed recovery replay invoked importer again"
[ ! -s "${FOLLOWUP_NOTIFY_LOG}" ] \
  || fail "scheduler-driven recovery called notify_dispatcher directly"

exec 8>"${FOLLOWUP_LOCK}"
flock -n 8 || fail "handoff recovery left the campaign lock held"
flock -u 8
exec 8>&-

echo "ok dispatch followup handoff recovery"
