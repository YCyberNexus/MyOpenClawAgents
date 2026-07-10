#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMPORT_HANDOFF="${SKILL_DIR}/scripts/import_driven_handoff.sh"
DRAIN_OUTBOX="${SKILL_DIR}/scripts/drain_driven_outbox.sh"
RECORD_LAUNCH="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

fail() {
  echo "test_driven_callback_outbox.sh: $*" >&2
  exit 1
}

[ -x "${IMPORT_HANDOFF}" ] || fail "import_driven_handoff.sh is missing or not executable"
[ -x "${DRAIN_OUTBOX}" ] || fail "drain_driven_outbox.sh is missing or not executable"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-driven-callback.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

create_batch_fixture() {
  local batch_id="$1"
  local callback_target="$2"
  local membership_status="$3"
  local batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"

  mkdir -p "${batch_dir}"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg target "${callback_target}" '{
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:"group/repo",
      selector:{type:"single",iid:42},
      force_rerun_pr:false,
      dispatcher_callback_target:$target,
      branch:"main"
    }' >"${batch_dir}/request.json"
  jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg membership_status "${membership_status}" '{
      version:1,
      batch_id:$batch_id,
      status:"running",
      matched_count:1,
      terminal_count:0,
      done_count:0,
      failed_count:0,
      timeout_count:0,
      skipped_count:0,
      next_snapshot_index:1,
      request_digest:"fixture-request",
      snapshot_digest:"fixture-snapshot",
      memberships:{
        "0":{
          snapshot_index:0,
          iid:42,
          status:$membership_status,
          job_id:"batch-A:snapshot-0"
        }
      }
    }' >"${batch_dir}/state.json"
}

create_batch_fixture batch-A agent:req_dispatcher:batch-a running
create_batch_fixture batch-B agent:req_dispatcher:batch-b attached

jq -cnS '{
  version:1,
  round_robin_cursor:"batch-B",
  batch_order:["batch-A","batch-B"],
  active_jobs:{
    "batch-A:snapshot-0":{
      job_id:"batch-A:snapshot-0",
      physical_key:"group/repo#42",
      project:"group/repo",
      iid:42,
      branch:"main",
      entry_mode:"auto",
      force_rerun_pr:false,
      status:"running",
      reservation_seq:1,
      claim_generation:1,
      claim_token:"claim-token-42",
      reserved_at:100,
      updated_at:101,
      owner:{batch_id:"batch-A",snapshot_index:0},
      memberships:[
        {batch_id:"batch-A",snapshot_index:0},
        {batch_id:"batch-B",snapshot_index:0}
      ]
    }
  }
}' >"${SCHEDULER_ROOT}/scheduler_state.json"

PHYSICAL_EVENT_ID='batch-A:snapshot-0:terminal-1'
EVENT_A='batch-A:snapshot-0:terminal-1'
EVENT_B='batch-B:snapshot-0:terminal-1'
HANDOFF_FILE="${TEST_ROOT}/driven-handoff.json"
RECEIPT_FILE="${SCHEDULER_ROOT}/callback_inbox/${PHYSICAL_EVENT_ID}.json"
OUTBOX_A="${SCHEDULER_ROOT}/callback_outbox/${EVENT_A}.json"
OUTBOX_B="${SCHEDULER_ROOT}/callback_outbox/${EVENT_B}.json"
RECORD_LOG="${TEST_ROOT}/record.log"

jq -cnS \
  --arg event_id "${PHYSICAL_EVENT_ID}" \
  --arg mr_url 'https://gitlab.example/group/repo/-/merge_requests/9' '{
    version:1,
    event_id:$event_id,
    job_id:"batch-A:snapshot-0",
    memberships:[],
    memberships_source:"scheduler_active_job",
    project:"group/repo",
    iid:42,
    status:"done",
    mr_url:$mr_url,
    reason:null
  }' >"${HANDOFF_FILE}"

FAKE_RECORD="${TEST_ROOT}/fake-record.sh"
cat >"${FAKE_RECORD}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec 8>"${EXPECT_SCHEDULER_LOCK:?}"
if ! flock -n 8; then
  echo "record was called while scheduler lock was held" >&2
  exit 90
fi
flock -u 8
exec 8>&-

for required_file in \
  "${EXPECT_RECEIPT:?}" \
  "${EXPECT_OUTBOX_A:?}" \
  "${EXPECT_OUTBOX_B:?}"
do
  [ -f "${required_file}" ] || {
    echo "record ran before durable callback file: ${required_file}" >&2
    exit 91
  }
done

jq -nc \
  --arg job_id "${JOB_ID:-}" \
  --arg status "${STATUS:-}" \
  --arg claim_token "${CLAIM_TOKEN:-}" \
  '{job_id:$job_id,status:$status,claim_token:$claim_token}' \
  >>"${RECORD_LOG:?}"

exec env \
  CONFIG_DIR="${CONFIG_DIR:?}" \
  JOB_ID="${JOB_ID:-}" \
  STATUS="${STATUS:-}" \
  CLAIM_TOKEN="${CLAIM_TOKEN:-}" \
  bash "${ACTUAL_RECORD:?}"
EOF
chmod +x "${FAKE_RECORD}"

IMPORT_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  HANDOFF_FILE="${HANDOFF_FILE}" \
  DRIVEN_RECORD_SCRIPT="${FAKE_RECORD}" \
  ACTUAL_RECORD="${RECORD_LAUNCH}" \
  EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
  EXPECT_RECEIPT="${RECEIPT_FILE}" \
  EXPECT_OUTBOX_A="${OUTBOX_A}" \
  EXPECT_OUTBOX_B="${OUTBOX_B}" \
  RECORD_LOG="${RECORD_LOG}" \
  bash "${IMPORT_HANDOFF}"
)"
jq -e '
  .status == "imported"
  and .job_id == "batch-A:snapshot-0"
  and .outbox_count == 2
  and .terminal_recorded == true
' <<<"${IMPORT_OUTPUT}" >/dev/null \
  || fail "importer did not report a completed two-membership import"

[ -f "${RECEIPT_FILE}" ] || fail "import receipt was not persisted"
[ -f "${OUTBOX_A}" ] || fail "batch-A outbox entry was not persisted"
[ -f "${OUTBOX_B}" ] || fail "batch-B outbox entry was not persisted"
jq -e '
  .event_id == "batch-A:snapshot-0:terminal-1"
  and .job_id == "batch-A:snapshot-0"
  and [.memberships[] | {batch_id,snapshot_index,target}] == [
    {batch_id:"batch-A",snapshot_index:0,target:"agent:req_dispatcher:batch-a"},
    {batch_id:"batch-B",snapshot_index:0,target:"agent:req_dispatcher:batch-b"}
  ]
  and .claim_token == "claim-token-42"
  and .scheduler_status == "running"
' "${RECEIPT_FILE}" >/dev/null \
  || fail "receipt did not freeze the scheduler-locked membership resolution"

for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}"; do
  jq -e '
    .version == 1
    and (.target | startswith("agent:req_dispatcher:"))
    and .attempts == 0
    and .delivered_at == null
    and .last_error == null
    and (.body | keys | sort) == [
      "batch_id","event_id","iid","mr_url","project","reason","snapshot_index","status"
    ]
    and .body.project == "group/repo"
    and .body.iid == 42
    and .body.status == "done"
    and (.body | has("target") | not)
    and (.body | has("correlation_id") | not)
  ' "${outbox_file}" >/dev/null \
    || fail "outbox entry mixed internal delivery fields into its public body"
done
jq -e --arg event_id "${EVENT_A}" \
  '.event_id == $event_id and .body.event_id == $event_id and .body.batch_id == "batch-A"' \
  "${OUTBOX_A}" >/dev/null || fail "batch-A event identity is unstable"
jq -e --arg event_id "${EVENT_B}" \
  '.event_id == $event_id and .body.event_id == $event_id and .body.batch_id == "batch-B"' \
  "${OUTBOX_B}" >/dev/null || fail "batch-B event identity is unstable"
jq -e '.active_jobs | has("batch-A:snapshot-0") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "scheduler job was not recorded terminal"
jq -e '.memberships["0"].status == "terminal"' \
  "${SCHEDULER_ROOT}/batches/batch-A/state.json" >/dev/null \
  || fail "owner membership was not recorded terminal"
jq -e '.memberships["0"].status == "terminal"' \
  "${SCHEDULER_ROOT}/batches/batch-B/state.json" >/dev/null \
  || fail "attached membership was not recorded terminal"
jq -e '
  length == 1
  and .[0].job_id == "batch-A:snapshot-0"
  and .[0].status == "terminal"
  and .[0].claim_token == "claim-token-42"
' --slurp "${RECORD_LOG}" >/dev/null \
  || fail "terminal record did not carry the current claim token exactly once"

# A replay after record removed active_jobs must finish from the receipt and
# must not invoke record again.
CONFIG_DIR="${CONFIG_DIR}" \
HANDOFF_FILE="${HANDOFF_FILE}" \
DRIVEN_RECORD_SCRIPT="${FAKE_RECORD}" \
ACTUAL_RECORD="${RECORD_LAUNCH}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
EXPECT_RECEIPT="${RECEIPT_FILE}" \
EXPECT_OUTBOX_A="${OUTBOX_A}" \
EXPECT_OUTBOX_B="${OUTBOX_B}" \
RECORD_LOG="${RECORD_LOG}" \
bash "${IMPORT_HANDOFF}" >/dev/null
[ "$(wc -l <"${RECORD_LOG}" | tr -d ' ')" = 1 ] \
  || fail "receipt replay recursively recorded an already-terminal job"

CONFLICT_HANDOFF="${TEST_ROOT}/conflicting-handoff.json"
jq '.status = "failed" | .reason = "changed terminal body"' \
  "${HANDOFF_FILE}" >"${CONFLICT_HANDOFF}"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${CONFLICT_HANDOFF}" \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/conflict.out" 2>"${TEST_ROOT}/conflict.err"; then
  fail "same physical event with a different body did not fail closed"
fi

ORPHAN_HANDOFF="${TEST_ROOT}/orphan-handoff.json"
jq '.event_id = "orphan:snapshot-0:terminal-1" | .job_id = "orphan:snapshot-0"' \
  "${HANDOFF_FILE}" >"${ORPHAN_HANDOFF}"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${ORPHAN_HANDOFF}" \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/orphan.out" 2>"${TEST_ROOT}/orphan.err"; then
  fail "missing scheduler job without a receipt was forged as success"
fi

# Delivery keeps failed entries durable, rejects a wrong accepted event, and
# retries with byte-identical public event bodies. The fake also proves that
# no scheduler lock is held during the network call.
OPENCLAW_LOG="${TEST_ROOT}/openclaw.jsonl"
FAKE_OPENCLAW="${TEST_ROOT}/fake-openclaw.sh"
cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-key)
      shift
      target="${1:-}"
      ;;
    --message)
      shift
      message="${1:-}"
      ;;
  esac
  [ "$#" -gt 0 ] && shift
done

exec 8>"${EXPECT_SCHEDULER_LOCK:?}"
if ! flock -n 8; then
  echo "openclaw was called while scheduler lock was held" >&2
  exit 92
fi
flock -u 8
exec 8>&-

body="${message#*worker_result_json=}"
event_id="$(jq -er '.event_id' <<<"${body}")"
jq -nc \
  --arg event_id "${event_id}" \
  --arg target "${target}" \
  --argjson body "${body}" \
  '{event_id:$event_id,target:$target,body:$body}' \
  >>"${OPENCLAW_LOG:?}"
call_count="$(jq -sr --arg event_id "${event_id}" \
  '[.[] | select(.event_id == $event_id)] | length' "${OPENCLAW_LOG}")"

if [ "${call_count}" -eq 1 ] && [ "${event_id}" = "batch-A:snapshot-0:terminal-1" ]; then
  exit 23
fi
if [ "${call_count}" -eq 1 ] && [ "${event_id}" = "batch-B:snapshot-0:terminal-1" ]; then
  jq -nc '{status:"accepted",event_id:"wrong-event"}'
  exit 0
fi
jq -nc --arg event_id "${event_id}" '{status:"accepted",event_id:$event_id}'
EOF
chmod +x "${FAKE_OPENCLAW}"

CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >/dev/null
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}"; do
  jq -e '
    .attempts == 1
    and .delivered_at == null
    and (.last_error | type == "string" and length > 0)
  ' "${outbox_file}" >/dev/null \
    || fail "failed or wrong-ack delivery was not retained for retry"
done

CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/drain-a.out" &
DRAIN_PID_A=$!
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/drain-b.out" &
DRAIN_PID_B=$!
wait "${DRAIN_PID_A}"
wait "${DRAIN_PID_B}"

for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}"; do
  jq -e '
    .attempts == 2
    and (.delivered_at | type == "number" and . >= 0)
    and .last_error == null
  ' "${outbox_file}" >/dev/null \
    || fail "accepted matching ack did not atomically mark delivery"
done
[ -f "${OUTBOX_A}" ] && [ -f "${OUTBOX_B}" ] \
  || fail "drain deleted durable outbox evidence"
jq -se \
  --arg event_a "${EVENT_A}" \
  --arg event_b "${EVENT_B}" '
  def bodies($event): [.[] | select(.event_id == $event) | (.body | @json)];
  ((bodies($event_a) | length) == 2 and (bodies($event_a) | unique | length) == 1)
  and ((bodies($event_b) | length) == 2 and (bodies($event_b) | unique | length) == 1)
' "${OPENCLAW_LOG}" >/dev/null \
  || fail "drain changed the public event body across retries or duplicated a concurrent send"

# Run the real followup wrapper in a small project fixture. Its importer exits
# non-zero deliberately after proving the campaign lock is available and both
# campaign state and handoff are durable.
FOLLOWUP_ROOT="${TEST_ROOT}/followup"
FOLLOWUP_PARENT="${FOLLOWUP_ROOT}/repos"
FOLLOWUP_REPO="${FOLLOWUP_PARENT}/repo"
FOLLOWUP_SCRIPTS="${FOLLOWUP_ROOT}/scripts"
FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_ROOT}/notify.log"
FOLLOWUP_IMPORT_LOG="${FOLLOWUP_ROOT}/import.log"
mkdir -p \
  "${FOLLOWUP_REPO}/.git" \
  "${FOLLOWUP_SCRIPTS}" \
  "${FOLLOWUP_REPO}/.req_executor/_dispatcher/log" \
  "${FOLLOWUP_REPO}/.req_executor/issues/issue-42"
cp \
  "${SKILL_DIR}/scripts/dispatch_followup.sh" \
  "${SKILL_DIR}/scripts/_dispatch_lib.sh" \
  "${SKILL_DIR}/scripts/env_paths.sh" \
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

FOLLOWUP_STATE="${FOLLOWUP_REPO}/.req_executor/_dispatcher/campaign_state.json"
FOLLOWUP_LOCK="${FOLLOWUP_REPO}/.req_executor/_dispatcher/campaign.lock"
jq -cnS '{
  project:"repo",
  repo_path:"unused",
  blocked_retry_limit:3,
  tick_seq:1,
  result_note_enabled:false,
  kill_subagent_on_terminal:false,
  pending_subagents:{
    "42":{
      attempt_number:1,
      run_id:"run-42",
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
      memberships_source:"scheduler_active_job"
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

FAKE_IMPORTER="${FOLLOWUP_ROOT}/fake-importer.sh"
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
jq -e '
  .event_id == "batch-A:snapshot-0:terminal-1"
  and .job_id == "batch-A:snapshot-0"
  and .memberships == []
  and .memberships_source == "scheduler_active_job"
  and .project == "group/repo"
  and .iid == 42
  and .status == "done"
' "${HANDOFF_FILE:?}" >/dev/null
printf '%s\n' "${HANDOFF_FILE}" >>"${FOLLOWUP_IMPORT_LOG:?}"
exit 47
EOF
chmod +x "${FAKE_IMPORTER}"

FOLLOWUP_OUTPUT="$(
  printf '%s\n' '{
    "iid":42,
    "attempt_number":1,
    "status":"done",
    "merge_request_url":"https://gitlab.example/group/repo/-/merge_requests/9"
  }' | \
  PROJECT=repo \
  PROJECT_FULL=group/repo \
  GROUP=group \
  GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example \
  GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" \
  IID=42 \
  ATTEMPT_NUMBER=1 \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh"
)"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .handoff_import_status == "pending"
  and (.handoff_path | type == "string" and length > 0)
' <<<"${FOLLOWUP_OUTPUT}" >/dev/null \
  || fail "followup did not expose the non-fatal pending handoff import"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 1 ] \
  || fail "followup did not call the importer exactly once"
FOLLOWUP_HANDOFF="$(cat "${FOLLOWUP_IMPORT_LOG}")"
[ -f "${FOLLOWUP_HANDOFF}" ] || fail "followup rolled back its handoff after import failure"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "import failure rolled back completed Phase 6 state"
[ ! -s "${FOLLOWUP_NOTIFY_LOG}" ] \
  || fail "scheduler-driven followup still called notify_dispatcher directly"
grep -Fq 'handoff import pending' \
  "${FOLLOWUP_REPO}/.req_executor/_dispatcher/log/wrapper.log" \
  || fail "followup log did not retain the pending import reason"
exec 8>"${FOLLOWUP_LOCK}"
flock -n 8 || fail "followup left the campaign lock held"
flock -u 8
exec 8>&-

echo "ok driven callback outbox"
