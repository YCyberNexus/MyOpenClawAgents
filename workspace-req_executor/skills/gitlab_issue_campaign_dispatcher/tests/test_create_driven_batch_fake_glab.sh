#!/usr/bin/env bash
set -euo pipefail

export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'

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

unset GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_ADDRESS GITLAB_TOKEN
unset REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS

write_gitlab_fixture_config() {
  local config_dir="$1"
  cat >"${config_dir}/gitlab.env" <<'EOF'
GITLAB_HOST=tracked-blue.invalid:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=tracked-token-must-not-reach-local-test
EOF
  cat >"${config_dir}/campaign_defaults.local.env" <<'EOF'
GITLAB_HOST=local-gitlab.invalid:9443
GITLAB_API_PROTOCOL=https
REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true
REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=local-gitlab.invalid:9443
EOF
}

write_gitlab_fixture_config "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
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
    [ "${2:-}" = graphql ] || {
      echo "offset REST pagination is forbidden: ${2:-}" >&2
      exit 90
    }
    shift 2
    query=""
    full_path=""
    after=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f|-F|--field|--raw-field)
          shift
          field="${1:-}"
          case "${field}" in
            query=*) query="${field#query=}" ;;
            fullPath=*) full_path="${field#fullPath=}" ;;
            after=*) after="${field#after=}" ;;
          esac
          ;;
      esac
      [ "$#" -gt 0 ] && shift
    done
    [ "${full_path}" = group/repo ] || {
      echo "missing GraphQL fullPath variable" >&2
      exit 91
    }
    [[ "${query}" == *'issues(first: 100, after: $after, state: opened, sort: created_asc)'* ]] \
      && [[ "${query}" == *'labels(first: 100)'* ]] \
      && [[ "${query}" == *pageInfo* ]] \
      && [[ "${query}" == *endCursor* ]] \
      && [[ "${query}" == *hasNextPage* ]] || {
      echo "GraphQL query lacks cursor pagination contract" >&2
      exit 92
    }
    printf 'graphql after=%s\n' "${after:-<null>}" >>"${FAKE_GLAB_API_LOG:?}"

    scan=0
    if [ -z "${after}" ]; then
      [ ! -f "${FAKE_GLAB_SCAN_STATE:?}" ] || scan="$(cat "${FAKE_GLAB_SCAN_STATE}")"
      scan=$((scan + 1))
      printf '%s' "${scan}" >"${FAKE_GLAB_SCAN_STATE}"
    else
      scan="$(cat "${FAKE_GLAB_SCAN_STATE:?}")"
    fi

    response() {
      local nodes="$1" has_next="$2" end_cursor_json="$3"
      nodes="$(jq -c '
        map(.labels.pageInfo = (.labels.pageInfo // {hasNextPage:false}))
      ' <<<"${nodes}")"
      jq -cn \
        --argjson nodes "${nodes}" \
        --argjson has_next "${has_next}" \
        --argjson end_cursor "${end_cursor_json}" \
        '{data:{project:{issues:{nodes:$nodes,pageInfo:{
          hasNextPage:$has_next,endCursor:$end_cursor
        }}}}}'
    }

    case "${FAKE_GLAB_MODE:-success}:${after:-first}" in
      fail_page_2:cursor-default-1)
        echo "simulated page 2 failure" >&2
        exit 93
        ;;
      malformed_page_2:cursor-default-1)
        printf '%s\n' '{"not":"an array"}'
        ;;
      repeating_front_churn:first)
        if [ "${scan}" -eq 1 ]; then
          range_start=1
          range_end=101
          boundary_cursor='"cursor-boundary-old"'
        else
          range_start=2
          range_end=102
          boundary_cursor='"cursor-boundary-stable"'
        fi
        nodes="$(jq -cn \
          --argjson range_start "${range_start}" \
          --argjson range_end "${range_end}" '[range($range_start;$range_end) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" true "${boundary_cursor}"
        ;;
      repeating_front_churn:cursor-boundary-old)
        nodes="$(jq -cn '[range(101;106) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" false null
        ;;
      repeating_front_churn:cursor-boundary-stable)
        nodes="$(jq -cn '[range(102;106) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" false null
        ;;
      duplicate_iid:first)
        nodes="$(jq -cn '[range(1;101) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" true '"cursor-duplicate-100"'
        ;;
      duplicate_iid:cursor-duplicate-100)
        nodes="$(jq -cn '[range(100;106) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" false null
        ;;
      stalled_cursor:first)
        response '[{"iid":"1","state":"opened","labels":{"nodes":[]}}]' \
          true '"cursor-stalled"'
        ;;
      stalled_cursor:cursor-stalled)
        stalled_state="${FAKE_GLAB_SCAN_STATE}.stalled"
        stalled_calls=0
        [ ! -f "${stalled_state}" ] || stalled_calls="$(cat "${stalled_state}")"
        stalled_calls=$((stalled_calls + 1))
        printf '%s' "${stalled_calls}" >"${stalled_state}"
        [ "${stalled_calls}" -le 1 ] || exit 95
        response '[{"iid":"2","state":"opened","labels":{"nodes":[]}}]' \
          true '"cursor-stalled"'
        ;;
      unsafe_cursor:first)
        response '[{"iid":"1","state":"opened","labels":{"nodes":[]}}]' \
          true '"cursor with spaces"'
        ;;
      runaway_cursor:*)
        if [ -z "${after}" ]; then
          runaway_page=1
        else
          runaway_page="${after##*-}"
          runaway_page=$((runaway_page + 1))
        fi
        [ "${runaway_page}" -le 5 ] || exit 96
        nodes="$(jq -cn --argjson iid "${runaway_page}" \
          '[{iid:($iid|tostring),state:"opened",labels:{nodes:[]}}]')"
        response "${nodes}" true "\"cursor-runaway-${runaway_page}\""
        ;;
      node_limit:first)
        nodes="$(jq -cn '[range(1;5) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" false null
        ;;
      never_stable:first)
        nodes="$(jq -cn '[range(1;101) | {
          iid:(.|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" true '"cursor-never-stable"'
        ;;
      never_stable:cursor-never-stable)
        nodes="$(jq -cn --argjson scan "${scan}" '[{
          iid:((100 + $scan)|tostring),state:"opened",labels:{nodes:[]}
        }]')"
        response "${nodes}" false null
        ;;
      truncated_labels:first)
        response '[{
          "iid":"7",
          "state":"opened",
          "labels":{
            "nodes":[{"title":"smoke"}],
            "pageInfo":{"hasNextPage":true}
          }
        }]' false null
        ;;
      *:first)
        response '[
          {"iid":"5","state":"opened","labels":{"nodes":[{"title":"finish"}]}},
          {"iid":"4","state":"opened","labels":{"nodes":[{"title":"smoke"},{"title":"timeout"}]}},
          {"iid":"2","state":"opened","labels":{"nodes":[{"title":"pr"}]}},
          {"iid":"1","state":"opened","labels":{"nodes":[]}}
        ]' true '"cursor-default-1"'
        ;;
      *:cursor-default-1)
        response '[
          {"iid":"3","state":"opened","labels":{"nodes":[{"title":"blocked-cc"}]}}
        ]' false null
        ;;
      *)
        echo "unexpected GraphQL cursor: ${after}" >&2
        exit 94
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
  local max_cursor_pages="${5:-}"
  local max_snapshot_nodes="${6:-}"

  FAKE_GLAB_API_LOG="${API_LOG}" \
    FAKE_GLAB_SCAN_STATE="${TEST_ROOT}/scan-${batch_id}" \
    FAKE_GLAB_MODE="${mode}" \
    CREATE_BATCH_MAX_CURSOR_PAGES="${max_cursor_pages}" \
    CREATE_BATCH_MAX_SNAPSHOT_NODES="${max_snapshot_nodes}" \
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
executor_agent=req_executor
callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
}

# Keep the full-scan accumulator out of argv. Passing every previously seen
# Issue through `jq --argjson current ...` on each cursor page grows one process
# argument until it hits ARG_MAX, well before the advertised node ceiling.
argv_accumulator_regressions=0
if grep -Eq -- '--argjson[[:space:]]+current' "${CREATE_BATCH}"; then
  echo "GraphQL cursor intake still carries the accumulated scan through argv" >&2
  argv_accumulator_regressions=1
fi
if grep -Eq -- '--argjson[[:space:]]+iids' "${CREATE_BATCH}"; then
  echo "GraphQL snapshot creation still carries every matched IID through argv" >&2
  argv_accumulator_regressions=1
fi
[ "${argv_accumulator_regressions}" -eq 0 ] || exit 1

unfinished_out="$(run_batch unfinished 'selector_type=open_unfinished')"
label_out="$(run_batch label $'selector_type=open_label\nlabel=smoke')"
range_out="$(run_batch range $'selector_type=range\niid_min=2\niid_max=4')"
single_out="$(run_batch single $'selector_type=single\niid=2')"
iid_list_out="$(run_batch iid-list $'selector_type=iid_list\niids=1,3,4')"
zero_out="$(run_batch zero $'selector_type=single\niid=999')"

BATCH_ROOT="${SCHEDULER_ROOT}/batches"
if find "${BATCH_ROOT}" -name normalized-issue-pages.jsonl -print -quit \
    | grep -q .; then
  echo "published batch retained the private GraphQL scan accumulator" >&2
  exit 1
fi
jq -e '.iids == [1]' "${BATCH_ROOT}/unfinished/snapshot.json" >/dev/null
jq -e '.iids == [4]' "${BATCH_ROOT}/label/snapshot.json" >/dev/null
jq -e '.iids == [2,3,4]' "${BATCH_ROOT}/range/snapshot.json" >/dev/null
jq -e '.iids == [2]' "${BATCH_ROOT}/single/snapshot.json" >/dev/null
jq -e '.iids == [1,3,4]' "${BATCH_ROOT}/iid-list/snapshot.json" >/dev/null
jq -e '.iids == []' "${BATCH_ROOT}/zero/snapshot.json" >/dev/null
jq -e '.status == "completed" and .matched_count == 0' \
  "${BATCH_ROOT}/zero/state.json" >/dev/null

for batch_id in unfinished label range single iid-list; do
  for filename in request.json snapshot.json state.json; do
    [ -f "${BATCH_ROOT}/${batch_id}/${filename}" ] || {
      echo "expected persisted ${filename} for ${batch_id}" >&2
      exit 1
    }
  done
  jq -e \
    --arg batch_id "${batch_id}" \
    '.batch_id == $batch_id
      and .terminal_counts_version == 1
      and .matched_count >= 1
      and (.request_digest | type == "string" and length == 64)
      and (.snapshot_digest | type == "string" and length == 64)
      and .status == "queued"' \
    "${BATCH_ROOT}/${batch_id}/state.json" >/dev/null
done
for filename in request.json snapshot.json state.json; do
  [ -f "${BATCH_ROOT}/zero/${filename}" ] || {
    echo "expected persisted ${filename} for zero" >&2
    exit 1
  }
done
jq -e '
  .batch_id == "zero"
  and .terminal_counts_version == 1
  and .matched_count == 0
  and (.request_digest | type == "string" and length == 64)
  and (.snapshot_digest | type == "string" and length == 64)
  and .status == "completed"
' "${BATCH_ROOT}/zero/state.json" >/dev/null

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
jq -e '.matched_count == 3 and .scheduler_status == "queued"' <<<"${iid_list_out}" >/dev/null

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

# The intake tick is global and persists action_emitted before exposing its
# spawn grant. Even when that grant belongs to an older batch, a model that
# skips sessions_spawn/the fixed recorder must not be able to return the new
# batch's five-field success receipt.
LAUNCH_ACTIONS_ROOT="${SCHEDULER_ROOT}/launch_actions"
LAUNCH_ACTION_ARCHIVE_ROOT="${SCHEDULER_ROOT}/launch_action_archive"
UNACKNOWLEDGED_ACTION="${LAUNCH_ACTIONS_ROOT}/single-unacknowledged.json"
mkdir -p "${LAUNCH_ACTIONS_ROOT}" "${LAUNCH_ACTION_ARCHIVE_ROOT}"
printf '%s\n' \
  '{"version":1,"job_id":"older:snapshot-0","batch_id":"older-batch","stage":"action_emitted","outcome":null,"ack":null}' \
  >"${UNACKNOWLEDGED_ACTION}"
if emit_acceptance single >"${TEST_ROOT}/unacknowledged-acceptance.out" \
    2>"${TEST_ROOT}/unacknowledged-acceptance.err"; then
  echo "unacknowledged spawn action produced a public success receipt" >&2
  exit 1
fi
grep -Fq 'executor spawn acknowledgement is still pending while acknowledging single' \
  "${TEST_ROOT}/unacknowledged-acceptance.err" || {
  echo "unacknowledged spawn rejection was not explicit" >&2
  exit 1
}
printf '%s\n' \
  '{"version":1,"job_id":"older:snapshot-0","batch_id":"older-batch","stage":"ack_received","outcome":"spawned","ack":{"run_id":"run-1","child_session_key":"agent:req_executor:subagent:1"}}' \
  >"${UNACKNOWLEDGED_ACTION}"
single_acknowledged_acceptance="$(emit_acceptance single)"
jq -e '
  .status == "success"
  and .batch_id == "single"
  and .scheduler_status == "queued"
' <<<"${single_acknowledged_acceptance}" >/dev/null \
  || { echo "durably acknowledged spawn was rejected" >&2; exit 1; }

# A completed coordinator may move from the live directory to the cold archive
# after the emitter snapshots the live filenames. Model that stale pathname
# with a dangling directory entry and require the matching completed archive to
# be accepted rather than reported as corrupt.
ARCHIVED_BASENAME=concurrently-archived.json
printf '%s\n' \
  '{"version":1,"job_id":"older:snapshot-1","batch_id":"older-batch","stage":"completed","outcome":"spawned","ack":{"run_id":"run-2","child_session_key":"agent:req_executor:subagent:2"}}' \
  >"${LAUNCH_ACTION_ARCHIVE_ROOT}/${ARCHIVED_BASENAME}"
ln -s "${LAUNCH_ACTIONS_ROOT}/already-archived.json" \
  "${LAUNCH_ACTIONS_ROOT}/${ARCHIVED_BASENAME}"
single_archived_acceptance="$(emit_acceptance single)"
jq -e '.status == "success" and .batch_id == "single"' \
  <<<"${single_archived_acceptance}" >/dev/null \
  || { echo "concurrently archived completed action was rejected" >&2; exit 1; }

iid_list_acceptance="$(emit_acceptance iid-list)"
jq -e '
  .status == "success"
  and .batch_id == "iid-list"
  and .matched_count == 3
  and (.snapshot_digest | type == "string" and test("^[0-9a-f]{64}$"))
  and .scheduler_status == "queued"
' <<<"${iid_list_acceptance}" >/dev/null
zero_acceptance="$(emit_acceptance zero)"
jq -e '
  .status == "success"
  and .batch_id == "zero"
  and .matched_count == 0
  and .scheduler_status == "completed"
' <<<"${zero_acceptance}" >/dev/null \
  || { echo "zero-match cold batch could not emit acceptance" >&2; exit 1; }

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
    'dispatcher_callback_target=agent:req_dispatcher:main' \
    'executor_agent=req_executor' \
    'callback_nonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')"
  request_digest="$(printf '%s' "${payload}" | sha256_text)"
  STATE_ROOT="${state_root}" \
  BATCH_ID="${batch_id}" \
  CORRELATION_ID="correlation-${batch_id}" \
  PROJECT='group/repo' \
  SELECTOR_JSON='{"type":"single","iid":2}' \
  FORCE_RERUN_PR=false \
  TARGET_BRANCH='' \
  EXECUTOR_AGENT=req_executor \
  CALLBACK_NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
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
write_gitlab_fixture_config "${HALF_CONFIG_DIR}"
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

if run_batch truncated-labels $'selector_type=open_label\nlabel=smoke' truncated_labels \
    >"${TEST_ROOT}/truncated-labels.out" \
    2>"${TEST_ROOT}/truncated-labels.err"; then
  echo "expected an incomplete nested labels connection to fail batch intake" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/truncated-labels/snapshot.json" ] || {
  echo "incomplete nested labels left a runnable partial snapshot" >&2
  exit 1
}
[ ! -e "${BATCH_ROOT}/malformed-page-2/snapshot.json" ] || {
  echo "malformed pagination left a runnable partial snapshot" >&2
  exit 1
}

boundary_out="$(run_batch boundary-stable 'selector_type=open_unfinished' repeating_front_churn)"
jq -e '
  .status == "success"
  and .matched_count == 104
  and .scheduler_status == "queued"
' <<<"${boundary_out}" >/dev/null || {
  echo "stable re-scan did not recover all IIDs across a moving page boundary" >&2
  exit 1
}
jq -e '
  (.iids | length) == 104
  and .iids[0] == 2
  and .iids[99] == 101
  and .iids[100] == 102
  and .iids[103] == 105
' "${BATCH_ROOT}/boundary-stable/snapshot.json" >/dev/null || {
  echo "moving page boundary froze a partial snapshot" >&2
  exit 1
}
[ "$(cat "${TEST_ROOT}/scan-boundary-stable")" -eq 3 ] || {
  echo "snapshot must wait for two consecutive identical full scans" >&2
  exit 1
}
if grep -Eq 'page=|per_page=|/issues\?' "${API_LOG}"; then
  echo "batch intake fell back to moving offset pagination" >&2
  exit 1
fi

if run_batch never-stable 'selector_type=open_unfinished' never_stable \
  >"${TEST_ROOT}/never-stable.out" 2>"${TEST_ROOT}/never-stable.err"; then
  echo "expected continuously changing pagination to fail closed" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/never-stable/snapshot.json" ] || {
  echo "unstable pagination left a runnable partial snapshot" >&2
  exit 1
}
unstable_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
  -path '*batch-intake-never-stable.*/failure.json' -print -quit)"
[ -n "${unstable_failure}" ] || {
  echo "unstable pagination did not retain failure evidence" >&2
  exit 1
}
jq -e '.reason == "gitlab_snapshot_unstable"' "${unstable_failure}" >/dev/null || {
  echo "unstable pagination failure was not classified" >&2
  exit 1
}

for cursor_failure in duplicate_iid stalled_cursor unsafe_cursor; do
  if run_batch "${cursor_failure}" 'selector_type=open_unfinished' "${cursor_failure}" \
      >"${TEST_ROOT}/${cursor_failure}.out" \
      2>"${TEST_ROOT}/${cursor_failure}.err"; then
    echo "expected ${cursor_failure} cursor intake to fail closed" >&2
    exit 1
  fi
  [ ! -e "${BATCH_ROOT}/${cursor_failure}/snapshot.json" ] || {
    echo "${cursor_failure} cursor intake left a runnable snapshot" >&2
    exit 1
  }
done

if run_batch cursor-page-limit 'selector_type=open_unfinished' runaway_cursor \
    "${CONFIG_DIR}" 3 100 \
    >"${TEST_ROOT}/cursor-page-limit.out" \
    2>"${TEST_ROOT}/cursor-page-limit.err"; then
  echo "expected an endlessly advancing cursor scan to hit the page limit" >&2
  exit 1
fi
page_limit_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
  -path '*batch-intake-cursor-page-limit.*/failure.json' -print -quit)"
jq -e '.reason == "gitlab_cursor_page_limit"' "${page_limit_failure}" >/dev/null || {
  echo "cursor page limit failure was not classified" >&2
  exit 1
}
[ ! -e "${BATCH_ROOT}/cursor-page-limit/snapshot.json" ] || {
  echo "cursor page limit left a runnable snapshot" >&2
  exit 1
}

if run_batch cursor-node-limit 'selector_type=open_unfinished' node_limit \
    "${CONFIG_DIR}" 10 3 \
    >"${TEST_ROOT}/cursor-node-limit.out" \
    2>"${TEST_ROOT}/cursor-node-limit.err"; then
  echo "expected an oversized full scan to hit the node limit" >&2
  exit 1
fi
node_limit_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
  -path '*batch-intake-cursor-node-limit.*/failure.json' -print -quit)"
jq -e '.reason == "gitlab_snapshot_node_limit"' "${node_limit_failure}" >/dev/null || {
  echo "snapshot node limit failure was not classified" >&2
  exit 1
}
[ ! -e "${BATCH_ROOT}/cursor-node-limit/snapshot.json" ] || {
  echo "snapshot node limit left a runnable snapshot" >&2
  exit 1
}

for overflow_case in \
  'cursor-limit-overflow|9999999999999999999999999999999999999999|100|gitlab_cursor_limit_invalid' \
  'node-limit-overflow|10|9999999999999999999999999999999999999999|gitlab_snapshot_limit_invalid'
do
  IFS='|' read -r overflow_batch overflow_pages overflow_nodes overflow_reason \
    <<<"${overflow_case}"
  if run_batch "${overflow_batch}" 'selector_type=open_unfinished' success \
      "${CONFIG_DIR}" "${overflow_pages}" "${overflow_nodes}" \
      >"${TEST_ROOT}/${overflow_batch}.out" \
      2>"${TEST_ROOT}/${overflow_batch}.err"; then
    echo "expected an overlong decimal limit to fail closed: ${overflow_batch}" >&2
    exit 1
  fi
  overflow_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
    -path "*batch-intake-${overflow_batch}.*/failure.json" -print -quit)"
  jq -e --arg reason "${overflow_reason}" '.reason == $reason' \
    "${overflow_failure}" >/dev/null || {
    echo "overlong decimal limit failure was not classified: ${overflow_batch}" >&2
    exit 1
  }
done

duplicate_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
  -path '*batch-intake-duplicate_iid.*/failure.json' -print -quit)"
stalled_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
  -path '*batch-intake-stalled_cursor.*/failure.json' -print -quit)"
unsafe_failure="$(find "${SCHEDULER_ROOT}/failed-intake" -type f \
  -path '*batch-intake-unsafe_cursor.*/failure.json' -print -quit)"
jq -e '.reason == "gitlab_cursor_duplicate_iid"' "${duplicate_failure}" >/dev/null || {
  echo "duplicate cursor IID failure was not classified" >&2
  exit 1
}
jq -e '.reason == "gitlab_cursor_not_advanced"' "${stalled_failure}" >/dev/null || {
  echo "stalled cursor failure was not classified" >&2
  exit 1
}
jq -e '.reason == "gitlab_cursor_invalid"' "${unsafe_failure}" >/dev/null || {
  echo "unsafe cursor failure was not classified" >&2
  exit 1
}

FAILED_INTAKE="${SCHEDULER_ROOT}/failed-intake"
[ -d "${FAILED_INTAKE}" ] || {
  echo "expected failed intake evidence directory" >&2
  exit 1
}
failed_evidence_count="$(find "${FAILED_INTAKE}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "${failed_evidence_count}" -ge 3 ] || {
  echo "expected pagination failures to retain intake evidence" >&2
  exit 1
}
if find "${FAILED_INTAKE}" -name snapshot.json -print -quit | grep -q .; then
  echo "failed intake evidence must not contain runnable snapshot.json" >&2
  exit 1
fi

invalid_iid_list_index=0
for invalid_iids in '1' '4,1,5' '1,4,4' '1,0,5' '1, 4,5'; do
  invalid_iid_list_index=$((invalid_iid_list_index + 1))
  invalid_batch_id="invalid-iid-list-${invalid_iid_list_index}"
  if run_batch "${invalid_batch_id}" $'selector_type=iid_list\niids='"${invalid_iids}" \
      >"${TEST_ROOT}/${invalid_batch_id}.out" 2>"${TEST_ROOT}/${invalid_batch_id}.err"; then
    echo "expected a non-canonical iid_list to fail: ${invalid_iids}" >&2
    exit 1
  fi
  [ ! -e "${BATCH_ROOT}/${invalid_batch_id}" ] || {
    echo "invalid iid_list created batch state: ${invalid_iids}" >&2
    exit 1
  }
done

if FAKE_GLAB_API_LOG="${API_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN="executor-owned-token" \
  CONFIG_DIR="${CONFIG_DIR}" \
  bash "${CREATE_BATCH}" >"${TEST_ROOT}/unknown-field.out" 2>"${TEST_ROOT}/unknown-field.err" <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=unknown-field
correlation_id=correlation-unknown-field
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unexpected_field=unsupported
EOF
then
  echo "expected an unsupported trigger field to be rejected" >&2
  exit 1
fi

run_branch_validation_case() {
  local case_id="$1"
  local branch="$2"
  local auto_merge="$3"
  local merge_target_branch="$4"
  local trigger

  trigger="$(printf '%s\n' \
    RUN_DRIVEN_ISSUE_BATCH \
    "batch_id=${case_id}" \
    "correlation_id=correlation-${case_id}" \
    'project=group/repo' \
    'selector_type=single' \
    'iid=1' \
    'force_rerun_pr=false' \
    "auto_merge=${auto_merge}" \
    'dispatcher_callback_target=agent:req_dispatcher:main' \
    'executor_agent=req_executor' \
    'callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
  [ -z "${branch}" ] || trigger+=$'\n'"branch=${branch}"
  [ -z "${merge_target_branch}" ] \
    || trigger+=$'\n'"merge_target_branch=${merge_target_branch}"

  FAKE_GLAB_API_LOG="${API_LOG}" \
    FAKE_GLAB_SCAN_STATE="${TEST_ROOT}/scan-${case_id}" \
    GLAB_BIN="${FAKE_GLAB}" \
    GITLAB_TOKEN="executor-owned-token" \
    CONFIG_DIR="${CONFIG_DIR}" \
    bash "${CREATE_BATCH}" <<<"${trigger}"
}

valid_auto_merge_out="$(
  run_branch_validation_case valid-auto-merge develop true release
)"
if ! jq -e '
    .status == "success"
    and .batch_id == "valid-auto-merge"
    and .matched_count == 1
    and .scheduler_status == "queued"
  ' <<<"${valid_auto_merge_out}" >/dev/null \
  || ! jq -e '
    .branch == "develop"
    and .auto_merge == true
    and .merge_target_branch == "release"
  ' "${BATCH_ROOT}/valid-auto-merge/request.json" >/dev/null; then
  echo "executor intake did not persist the exact automatic merge intent" >&2
  exit 1
fi

deferred_auto_merge_out="$(
  run_branch_validation_case missing-auto-merge-target '' true ''
)"
if ! jq -e '
    .status == "success"
    and .batch_id == "missing-auto-merge-target"
    and .matched_count == 1
  ' <<<"${deferred_auto_merge_out}" >/dev/null \
  || ! jq -e '
    .branch == null
    and .auto_merge == true
    and .merge_target_branch == null
  ' "${BATCH_ROOT}/missing-auto-merge-target/request.json" >/dev/null; then
  echo "expected executor intake to defer automatic-merge branch resolution to the Issue" >&2
  exit 1
fi
deferred_auto_merge_acceptance="$(emit_acceptance missing-auto-merge-target)"
if ! jq -e '
    .status == "success"
    and .batch_id == "missing-auto-merge-target"
    and .matched_count == 1
    and .scheduler_status == "queued"
  ' <<<"${deferred_auto_merge_acceptance}" >/dev/null; then
  echo "acceptance emitter rejected deferred per-Issue branch resolution" >&2
  exit 1
fi

if run_branch_validation_case unsafe-base-backtick 'feature/`id`' false '' \
    >"${TEST_ROOT}/unsafe-base-backtick.out" \
    2>"${TEST_ROOT}/unsafe-base-backtick.err"; then
  echo "expected a backtick-bearing base branch to fail closed at executor intake" >&2
  exit 1
fi
if run_branch_validation_case unsafe-target-backtick develop true 'feature/`id`' \
    >"${TEST_ROOT}/unsafe-target-backtick.out" \
    2>"${TEST_ROOT}/unsafe-target-backtick.err"; then
  echo "expected a backtick-bearing merge target to fail closed at executor intake" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/unsafe-base-backtick" ] \
  || { echo "unsafe base branch created batch state" >&2; exit 1; }
[ ! -e "${BATCH_ROOT}/unsafe-target-backtick" ] \
  || { echo "unsafe merge target created batch state" >&2; exit 1; }

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
executor_agent=req_executor
callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
then
  echo "expected empty dispatcher_callback_target to fail closed before snapshot creation" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/empty-callback" ] || {
  echo "empty callback target left a permanently undeliverable batch" >&2
  exit 1
}

for bad_case in wrong-target wrong-executor bad-nonce; do
  callback_target=agent:req_dispatcher:main
  executor_agent=req_executor
  callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case "${bad_case}" in
    wrong-target) callback_target=agent:other_agent:main ;;
    wrong-executor) executor_agent=other_executor ;;
    bad-nonce) callback_nonce=short ;;
  esac
  if FAKE_GLAB_API_LOG="${API_LOG}" GLAB_BIN="${FAKE_GLAB}" \
      GITLAB_TOKEN="executor-owned-token" CONFIG_DIR="${CONFIG_DIR}" \
      bash "${CREATE_BATCH}" >"${TEST_ROOT}/${bad_case}.out" \
        2>"${TEST_ROOT}/${bad_case}.err" <<EOF
RUN_DRIVEN_ISSUE_BATCH
batch_id=${bad_case}
correlation_id=correlation-${bad_case}
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=${callback_target}
executor_agent=${executor_agent}
callback_nonce=${callback_nonce}
EOF
  then
    echo "expected ${bad_case} to fail before snapshot creation" >&2
    exit 1
  fi
  [ ! -e "${BATCH_ROOT}/${bad_case}" ] || {
    echo "invalid authenticated routing left batch ${bad_case}" >&2
    exit 1
  }
done

# The compatibility marker is derived only while reading trusted scheduler
# files created before auth existed. New intake cannot omit auth or request a
# legacy downgrade explicitly.
if FAKE_GLAB_API_LOG="${API_LOG}" GLAB_BIN="${FAKE_GLAB}" \
    GITLAB_TOKEN="executor-owned-token" CONFIG_DIR="${CONFIG_DIR}" \
    bash "${CREATE_BATCH}" >"${TEST_ROOT}/missing-auth.out" \
      2>"${TEST_ROOT}/missing-auth.err" <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=missing-auth
correlation_id=correlation-missing-auth
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
EOF
then
  echo "expected new intake without callback auth to fail closed" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/missing-auth" ] || {
  echo "missing-auth intake created a legacy-compatible batch" >&2
  exit 1
}

if FAKE_GLAB_API_LOG="${API_LOG}" GLAB_BIN="${FAKE_GLAB}" \
    GITLAB_TOKEN="executor-owned-token" CONFIG_DIR="${CONFIG_DIR}" \
    bash "${CREATE_BATCH}" >"${TEST_ROOT}/legacy-downgrade.out" \
      2>"${TEST_ROOT}/legacy-downgrade.err" <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=legacy-downgrade
correlation_id=correlation-legacy-downgrade
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
callback_auth_mode=legacy_pre_upgrade
EOF
then
  echo "expected new intake to reject a requested legacy_pre_upgrade downgrade" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/legacy-downgrade" ] || {
  echo "legacy downgrade intake created a batch" >&2
  exit 1
}

jq -e '
  .executor_agent == "req_executor"
  and .callback_nonce == ("a" * 64)
  and (has("terminal_counts_version") | not)
' "${BATCH_ROOT}/single/request.json" >/dev/null || {
  echo "authenticated callback fields were not privately persisted" >&2
  exit 1
}
if printf '%s\n' "${single_out}" | grep -q 'callback_nonce\|executor_agent'; then
  echo "private callback authentication leaked into public acceptance" >&2
  exit 1
fi

jq -e '
  .batch_order == ["unfinished","label","range","single","iid-list","boundary-stable","valid-auto-merge","missing-auto-merge-target"]
  and (.batch_order | length) == (.batch_order | unique | length)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

zero_replay="$(run_batch zero $'selector_type=single\niid=999')"
[ "${zero_out}" = "${zero_replay}" ] || {
  echo "zero-match replay returned a different acceptance" >&2
  exit 1
}
jq -e '.batch_order | index("zero") == null' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null || {
  echo "zero-match replay re-entered the hot runnable index" >&2
  exit 1
}

echo 'ok create driven batch snapshot'
