#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREATE_BATCH="${SKILL_DIR}/scripts/create_driven_batch.sh"
EMIT_ACCEPTANCE="${SKILL_DIR}/scripts/emit_driven_batch_acceptance.sh"
REPO_ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"
DISPATCHER_SKILL_DIR="${REPO_ROOT}/workspace-req_dispatcher/skills/requirement_dispatch"
DISPATCHER_ENQUEUE="${DISPATCHER_SKILL_DIR}/scripts/enqueue_executor_batch_request.sh"
DISPATCHER_DRAIN="${DISPATCHER_SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-create-batch.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/_scheduler"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GLAB="${BIN_DIR}/glab"
API_LOG="${TEST_ROOT}/glab-api.log"
mkdir -p "${CONFIG_DIR}" "${BIN_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF

cat >"${FAKE_GLAB}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  auth)
    if [ "${2:-}" = login ]; then
      token=""
      shift 2
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --token ]; then
          shift
          token="${1:-}"
        fi
        [ "$#" -gt 0 ] && shift
      done
      [ "${token}" = "executor-owned-token" ] || {
        echo "fake glab received an unexpected auth token" >&2
        exit 89
      }
    fi
    exit 0
    ;;
  api)
    endpoint="${2:-}"
    printf '%s\n' "${endpoint}" >>"${FAKE_GLAB_API_LOG:?}"
    if [[ ! "${endpoint}" =~ ^projects/group%2Frepo/issues\?state=opened\&per_page=100\&page=([0-9]+)$ ]]; then
      echo "unexpected GitLab API endpoint: ${endpoint}" >&2
      exit 90
    fi
    page="${BASH_REMATCH[1]}"
    case "${FAKE_GLAB_MODE:-success}:${page}" in
      fail_page_2:2)
        echo "simulated page 2 failure" >&2
        exit 91
        ;;
      malformed_page_2:2)
        printf '%s\n' '{"not":"an array"}'
        ;;
      *:1)
        printf '%s\n' '[
          {"iid":4,"state":"opened","labels":["smoke","timeout"]},
          {"iid":2,"state":"opened","labels":["pr"]},
          {"iid":1,"state":"opened","labels":[]}
        ]'
        ;;
      *:2)
        printf '%s\n' '[
          {"iid":4,"state":"opened","labels":["smoke","timeout"]},
          {"iid":3,"state":"opened","labels":["blocked-cc"]},
          {"iid":5,"state":"closed","labels":["smoke"]}
        ]'
        ;;
      *:3)
        printf '%s\n' '[]'
        ;;
      *)
        echo "unexpected pagination past the empty page: ${page}" >&2
        exit 92
        ;;
    esac
    ;;
  *)
    echo "unexpected fake glab command: $*" >&2
    exit 93
    ;;
esac
EOF
chmod +x "${FAKE_GLAB}"

run_batch() {
  local batch_id="$1"
  local selector_lines="$2"
  local mode="${3:-success}"
  local config_dir="${4:-${CONFIG_DIR}}"

  FAKE_GLAB_API_LOG="${API_LOG}" \
    FAKE_GLAB_MODE="${mode}" \
    GLAB_BIN="${FAKE_GLAB}" \
    GITLAB_TOKEN="executor-owned-token" \
    CONFIG_DIR="${config_dir}" \
    bash "${CREATE_BATCH}" <<EOF
RUN_DRIVEN_ISSUE_BATCH
batch_id=${batch_id}
correlation_id=correlation-${batch_id}
project=group/repo
${selector_lines}
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
EOF
}

unfinished_out="$(run_batch unfinished 'selector_type=open_unfinished')"
label_out="$(run_batch label $'selector_type=open_label\nlabel=smoke')"
range_out="$(run_batch range $'selector_type=range\niid_min=2\niid_max=4')"
single_out="$(run_batch single $'selector_type=single\niid=2')"

BATCH_ROOT="${SCHEDULER_ROOT}/batches"
jq -e '.iids == [1]' "${BATCH_ROOT}/unfinished/snapshot.json" >/dev/null
jq -e '.iids == [4]' "${BATCH_ROOT}/label/snapshot.json" >/dev/null
jq -e '.iids == [2,3,4]' "${BATCH_ROOT}/range/snapshot.json" >/dev/null
jq -e '.iids == [2]' "${BATCH_ROOT}/single/snapshot.json" >/dev/null

for batch_id in unfinished label range single; do
  for filename in request.json snapshot.json state.json; do
    [ -f "${BATCH_ROOT}/${batch_id}/${filename}" ] || {
      echo "expected persisted ${filename} for ${batch_id}" >&2
      exit 1
    }
  done
  jq -e \
    --arg batch_id "${batch_id}" \
    '.batch_id == $batch_id
      and .matched_count >= 1
      and (.request_digest | type == "string" and length == 64)
      and (.snapshot_digest | type == "string" and length == 64)
      and .status == "queued"' \
    "${BATCH_ROOT}/${batch_id}/state.json" >/dev/null
done

jq -e \
  '.status == "success"
    and .batch_id == "unfinished"
    and .matched_count == 1
    and (.snapshot_digest | length == 64)
    and .scheduler_status == "queued"
    and (has("iids") | not)' \
  <<<"${unfinished_out}" >/dev/null
jq -e '.matched_count == 1 and .scheduler_status == "queued"' <<<"${label_out}" >/dev/null
jq -e '.matched_count == 3 and .scheduler_status == "queued"' <<<"${range_out}" >/dev/null
jq -e '.matched_count == 1 and .scheduler_status == "queued"' <<<"${single_out}" >/dev/null

# Public I1 acceptance is emitted only after runtime actions finish. It is
# rebuilt from durable scheduler state rather than hand-written from the rich
# orchestration envelope.
emit_acceptance() {
  local batch_id="$1"
  BATCH_ID="${batch_id}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    bash "${EMIT_ACCEPTANCE}"
}

single_acceptance="$(emit_acceptance single)"
jq -e '
  (keys | sort) == [
    "batch_id","matched_count","scheduler_status","snapshot_digest","status"
  ]
  and .status == "success"
  and .batch_id == "single"
  and .matched_count == 1
  and (.snapshot_digest | type == "string" and test("^[0-9a-f]{64}$"))
  and .scheduler_status == "queued"
' <<<"${single_acceptance}" >/dev/null

# Exercise the real req_dispatcher run_agent_turn extraction and strict
# acceptance check. A rich executor envelope and a human chat summary are not
# public receipts; only the fixed emitter's final compact line is accepted.
[ -f "${DISPATCHER_ENQUEUE}" ] || {
  echo "dispatcher enqueue fixture is missing" >&2
  exit 1
}
[ -f "${DISPATCHER_DRAIN}" ] || {
  echo "dispatcher drain fixture is missing" >&2
  exit 1
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

enqueue_dispatcher_fixture() {
  local state_root="$1"
  local batch_id="$2"
  local payload request_digest
  payload="$(printf '%s\n' \
    'RUN_DRIVEN_ISSUE_BATCH' \
    "batch_id=${batch_id}" \
    "correlation_id=correlation-${batch_id}" \
    'project=group/repo' \
    'selector_type=single' \
    'iid=2' \
    'force_rerun_pr=false' \
    'dispatcher_callback_target=agent:req_dispatcher:main')"
  request_digest="$(printf '%s' "${payload}" | sha256_text)"
  STATE_ROOT="${state_root}" \
  BATCH_ID="${batch_id}" \
  CORRELATION_ID="correlation-${batch_id}" \
  PROJECT='group/repo' \
  SELECTOR_JSON='{"type":"single","iid":2}' \
  FORCE_RERUN_PR=false \
  TARGET_BRANCH='' \
  EXECUTOR_AGENT=req_executor \
  ORIGIN_JSON=null \
  PAYLOAD="${payload}" \
  REQUEST_DIGEST="${request_digest}" \
    bash "${DISPATCHER_ENQUEUE}" >/dev/null
}

FAKE_ACCEPTANCE_AGENT="${TEST_ROOT}/fake-acceptance-agent.sh"
cat >"${FAKE_ACCEPTANCE_AGENT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

acceptance="$(
  BATCH_ID="${FAKE_BATCH_ID:?}" \
  CONFIG_DIR="${FAKE_EXECUTOR_CONFIG_DIR:?}" \
    bash "${FAKE_ACCEPTANCE_EMITTER:?}"
)"
rich_envelope="$(jq -cn --argjson acceptance "${acceptance}" '{
  status:"accepted",
  batch_id:$acceptance.batch_id,
  matched_count:$acceptance.matched_count,
  snapshot_digest:$acceptance.snapshot_digest,
  scheduler_status:$acceptance.scheduler_status,
  spawn_grants:[],
  reconcile_actions:[],
  operation_results:[{operation:"create_batch",status:"success"}],
  max_launch_retries:3,
  backoff_seconds:2,
  chat_summary:("batch " + $acceptance.batch_id + " accepted")
}')"

case "${FAKE_AGENT_OUTPUT_MODE:?}" in
  rich)
    printf '%s\n' "${rich_envelope}"
    ;;
  chat_summary)
    printf 'batch %s accepted\n' "${FAKE_BATCH_ID}"
    ;;
  public_acceptance)
    printf '%s\n' "${rich_envelope}"
    printf '%s\n' "${acceptance}"
    ;;
  *)
    exit 97
    ;;
esac
EOF
chmod +x "${FAKE_ACCEPTANCE_AGENT}"

run_dispatcher_delivery() {
  local state_root="$1"
  local batch_id="$2"
  local output_mode="$3"
  STATE_ROOT="${state_root}" \
  BATCH_ID="${batch_id}" \
  OPENCLAW_BIN="${FAKE_ACCEPTANCE_AGENT}" \
  FAKE_BATCH_ID="${batch_id}" \
  FAKE_AGENT_OUTPUT_MODE="${output_mode}" \
  FAKE_ACCEPTANCE_EMITTER="${EMIT_ACCEPTANCE}" \
  FAKE_EXECUTOR_CONFIG_DIR="${CONFIG_DIR}" \
  RUN_AGENT_TURN_HEARTBEAT_SECONDS=1 \
    bash "${DISPATCHER_DRAIN}"
}

RICH_DISPATCHER_ROOT="${TEST_ROOT}/dispatcher-rich"
enqueue_dispatcher_fixture "${RICH_DISPATCHER_ROOT}" range
rich_delivery="$(run_dispatcher_delivery "${RICH_DISPATCHER_ROOT}" range rich)"
jq -e '
  .status == "retryable_failure"
  and .batch_id == "range"
  and .reason == "invalid_executor_acceptance"
' <<<"${rich_delivery}" >/dev/null || {
  echo "dispatcher accepted the rich executor envelope" >&2
  printf '%s\n' "${rich_delivery}" >&2
  exit 1
}

CHAT_DISPATCHER_ROOT="${TEST_ROOT}/dispatcher-chat"
enqueue_dispatcher_fixture "${CHAT_DISPATCHER_ROOT}" label
chat_delivery="$(run_dispatcher_delivery "${CHAT_DISPATCHER_ROOT}" label chat_summary)"
jq -e '
  .status == "retryable_failure"
  and .batch_id == "label"
  and .reason == "invalid_executor_acceptance"
' <<<"${chat_delivery}" >/dev/null || {
  echo "dispatcher accepted a human chat summary as a public receipt" >&2
  printf '%s\n' "${chat_delivery}" >&2
  exit 1
}

PUBLIC_DISPATCHER_ROOT="${TEST_ROOT}/dispatcher-public"
enqueue_dispatcher_fixture "${PUBLIC_DISPATCHER_ROOT}" single
public_delivery="$(
  run_dispatcher_delivery "${PUBLIC_DISPATCHER_ROOT}" single public_acceptance
)"
jq -e \
  --arg digest "$(jq -r '.snapshot_digest' <<<"${single_acceptance}")" '
  .status == "accepted"
  and .batch_id == "single"
  and .matched_count == 1
  and .snapshot_digest == $digest
  and .scheduler_status == "queued"
  and .record_status == "accepted"
' <<<"${public_delivery}" >/dev/null || {
  echo "dispatcher rejected the fixed public acceptance emitter" >&2
  printf '%s\n' "${public_delivery}" >&2
  exit 1
}

# An I1 acknowledgement can be lost and replayed after part of the batch has
# already reached terminal state. The public receipt follows the authoritative
# batch status/count/digest even though legacy classification counters are not
# used by the scheduler state machine.
cp "${BATCH_ROOT}/range/state.json" "${TEST_ROOT}/range.state.before-progress.json"
jq '
  .status = "running"
  | .terminal_count = 1
  | .next_snapshot_index = 1
  | .memberships = {
      "0":{snapshot_index:0,iid:2,status:"terminal",job_id:"range:snapshot-0"}
    }
' "${BATCH_ROOT}/range/state.json" >"${BATCH_ROOT}/range/state.progressed.json"
mv "${BATCH_ROOT}/range/state.progressed.json" "${BATCH_ROOT}/range/state.json"
progressed_acceptance="$(emit_acceptance range)"
jq -e '
  .status == "success"
  and .batch_id == "range"
  and .matched_count == 3
  and .scheduler_status == "running"
' <<<"${progressed_acceptance}" >/dev/null || {
  echo "acceptance emitter rejected a valid progressed batch replay" >&2
  printf '%s\n' "${progressed_acceptance}" >&2
  exit 1
}
cp "${TEST_ROOT}/range.state.before-progress.json" "${BATCH_ROOT}/range/state.json"

cp "${BATCH_ROOT}/single/snapshot.json" "${TEST_ROOT}/single.snapshot.before-tamper.json"
jq '.iids += [999]' "${BATCH_ROOT}/single/snapshot.json" \
  >"${BATCH_ROOT}/single/snapshot.tampered.json"
mv "${BATCH_ROOT}/single/snapshot.tampered.json" "${BATCH_ROOT}/single/snapshot.json"
if emit_acceptance single >"${TEST_ROOT}/tampered-acceptance.out" \
  2>"${TEST_ROOT}/tampered-acceptance.err"; then
  echo "acceptance emitter trusted a snapshot that disagreed with durable state" >&2
  exit 1
fi
cp "${TEST_ROOT}/single.snapshot.before-tamper.json" "${BATCH_ROOT}/single/snapshot.json"

api_calls_before_replay="$(wc -l <"${API_LOG}" | tr -d ' ')"
snapshot_before_replay="$(<"${BATCH_ROOT}/label/snapshot.json")"
label_replay_out="$(run_batch label $'selector_type=open_label\nlabel=smoke')"
api_calls_after_replay="$(wc -l <"${API_LOG}" | tr -d ' ')"

[ "${api_calls_after_replay}" = "${api_calls_before_replay}" ] || {
  echo "idempotent replay unexpectedly queried GitLab" >&2
  exit 1
}
jq -e \
  --arg digest "$(jq -r '.snapshot_digest' <<<"${label_out}")" \
  '.snapshot_digest == $digest and .matched_count == 1' \
  <<<"${label_replay_out}" >/dev/null
[ "$(<"${BATCH_ROOT}/label/snapshot.json")" = "${snapshot_before_replay}" ] || {
  echo "idempotent replay mutated immutable snapshot.json" >&2
  exit 1
}

if run_batch label $'selector_type=open_label\nlabel=other' >"${TEST_ROOT}/conflict.out" 2>"${TEST_ROOT}/conflict.err"; then
  echo "expected changed request for an existing batch ID to fail" >&2
  exit 1
fi
[ "$(<"${BATCH_ROOT}/label/snapshot.json")" = "${snapshot_before_replay}" ] || {
  echo "conflicting replay mutated immutable snapshot.json" >&2
  exit 1
}

HALF_CONFIG_DIR="${TEST_ROOT}/half-published-config"
HALF_SCHEDULER_ROOT="${TEST_ROOT}/half-published-scheduler"
HALF_BATCH_ROOT="${HALF_SCHEDULER_ROOT}/batches"
mkdir -p "${HALF_CONFIG_DIR}"
cat >"${HALF_CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${HALF_SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF
CONFIG_DIR="${HALF_CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
mkdir -p "${HALF_BATCH_ROOT}/label"
cp \
  "${BATCH_ROOT}/label/request.json" \
  "${BATCH_ROOT}/label/snapshot.json" \
  "${BATCH_ROOT}/label/state.json" \
  "${HALF_BATCH_ROOT}/label/"
jq -e '.batch_order == []' "${HALF_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

half_snapshot_before="$(<"${HALF_BATCH_ROOT}/label/snapshot.json")"
half_api_calls_before="$(wc -l <"${API_LOG}" | tr -d ' ')"
if run_batch label $'selector_type=open_label\nlabel=other' success "${HALF_CONFIG_DIR}" \
  >"${TEST_ROOT}/half-conflict.out" 2>"${TEST_ROOT}/half-conflict.err"; then
  echo "expected a conflicting half-published replay to fail" >&2
  exit 1
fi
[ "$(wc -l <"${API_LOG}" | tr -d ' ')" = "${half_api_calls_before}" ] || {
  echo "conflicting half-published replay unexpectedly queried GitLab" >&2
  exit 1
}
jq -e '.batch_order == []' "${HALF_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

half_recovery_out="$(run_batch label $'selector_type=open_label\nlabel=smoke' success "${HALF_CONFIG_DIR}")"
[ "$(wc -l <"${API_LOG}" | tr -d ' ')" = "${half_api_calls_before}" ] || {
  echo "half-published recovery unexpectedly queried GitLab" >&2
  exit 1
}
jq -e \
  --arg digest "$(jq -r '.snapshot_digest' <<<"${label_out}")" \
  '.matched_count == 1 and .snapshot_digest == $digest and .scheduler_status == "queued"' \
  <<<"${half_recovery_out}" >/dev/null
[ "$(<"${HALF_BATCH_ROOT}/label/snapshot.json")" = "${half_snapshot_before}" ] || {
  echo "half-published recovery mutated immutable snapshot.json" >&2
  exit 1
}
jq -e \
  '.batch_order == ["label"]
    and ([.batch_order[] | select(. == "label")] | length) == 1' \
  "${HALF_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

half_registered_replay_out="$(run_batch label $'selector_type=open_label\nlabel=smoke' success "${HALF_CONFIG_DIR}")"
[ "$(wc -l <"${API_LOG}" | tr -d ' ')" = "${half_api_calls_before}" ] || {
  echo "registered recovery replay unexpectedly queried GitLab" >&2
  exit 1
}
jq -e \
  --arg digest "$(jq -r '.snapshot_digest' <<<"${half_recovery_out}")" \
  '.matched_count == 1 and .snapshot_digest == $digest' \
  <<<"${half_registered_replay_out}" >/dev/null
jq -e \
  '.batch_order == ["label"]
    and ([.batch_order[] | select(. == "label")] | length) == 1' \
  "${HALF_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

if run_batch failed-page-2 'selector_type=open_unfinished' fail_page_2 \
  >"${TEST_ROOT}/failed-page-2.out" 2>"${TEST_ROOT}/failed-page-2.err"; then
  echo "expected a GitLab pagination failure to fail batch intake" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/failed-page-2/snapshot.json" ] || {
  echo "pagination failure left a runnable partial snapshot" >&2
  exit 1
}

if run_batch malformed-page-2 'selector_type=open_unfinished' malformed_page_2 \
  >"${TEST_ROOT}/malformed-page-2.out" 2>"${TEST_ROOT}/malformed-page-2.err"; then
  echo "expected a non-array GitLab page to fail batch intake" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/malformed-page-2/snapshot.json" ] || {
  echo "malformed pagination left a runnable partial snapshot" >&2
  exit 1
}

FAILED_INTAKE="${SCHEDULER_ROOT}/failed-intake"
[ -d "${FAILED_INTAKE}" ] || {
  echo "expected failed intake evidence directory" >&2
  exit 1
}
failed_evidence_count="$(find "${FAILED_INTAKE}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "${failed_evidence_count}" -ge 2 ] || {
  echo "expected pagination failures to retain intake evidence" >&2
  exit 1
}
if find "${FAILED_INTAKE}" -name snapshot.json -print -quit | grep -q .; then
  echo "failed intake evidence must not contain runnable snapshot.json" >&2
  exit 1
fi

if FAKE_GLAB_API_LOG="${API_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN="executor-owned-token" \
  CONFIG_DIR="${CONFIG_DIR}" \
  bash "${CREATE_BATCH}" >"${TEST_ROOT}/token-field.out" 2>"${TEST_ROOT}/token-field.err" <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=token-field
correlation_id=correlation-token-field
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
gitlab_token=must-not-be-accepted
EOF
then
  echo "expected token material in the trigger to be rejected" >&2
  exit 1
fi

if FAKE_GLAB_API_LOG="${API_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN="executor-owned-token" \
  CONFIG_DIR="${CONFIG_DIR}" \
  bash "${CREATE_BATCH}" >"${TEST_ROOT}/empty-callback.out" 2>"${TEST_ROOT}/empty-callback.err" <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=empty-callback
correlation_id=correlation-empty-callback
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=
EOF
then
  echo "expected empty dispatcher_callback_target to fail closed before snapshot creation" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/empty-callback" ] || {
  echo "empty callback target left a permanently undeliverable batch" >&2
  exit 1
}

jq -e '
  .batch_order == ["unfinished","label","range","single"]
  and (.batch_order | length) == (.batch_order | unique | length)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

echo 'ok create driven batch snapshot'
