#!/usr/bin/env bash
set -euo pipefail
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-legacy-nonce.XXXXXX")"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls.jsonl"

cat >"${FAKE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = agent ] || exit 90
shift
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent|--session-key|--timeout) shift 2 ;;
    --message-file) message_file="${2:-}"; shift 2 ;;
    *) exit 91 ;;
  esac
done
[ "${message_file}" = /dev/stdin ] || exit 92
message="$(cat)"
nonce="$(awk -F= '$1 == "callback_nonce" {print $2; exit}' <<<"${message}")"
executor_agent="$(awk -F= '$1 == "executor_agent" {print $2; exit}' <<<"${message}")"
[[ "${nonce}" =~ ^[0-9a-f]{64}$ ]] || exit 93
[ "${executor_agent}" = req_executor ] || exit 94

queue_file="${STATE_ROOT:?}/_dispatcher/executor_queue.json"
pending_file="${STATE_ROOT}/_dispatcher/pending.json"
run_id="$(jq -er '.active.run_id' "${queue_file}")"
jq -e --arg nonce "${nonce}" '.active.callback_nonce == $nonce' \
  "${queue_file}" >/dev/null || exit 95
nonce_sha256="$(printf '%s' "${nonce}" | {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  else shasum -a 256 | awk '{print $1}'; fi
})"
jq -e --arg run_id "${run_id}" --arg digest "${nonce_sha256}" '
  .pending[$run_id].callback_auth_mode == "nonce_v1"
  and .pending[$run_id].callback_nonce_sha256 == $digest
  and (.pending[$run_id] | has("callback_nonce") | not)
' "${pending_file}" >/dev/null || exit 96

jq -nc --arg run_id "${run_id}" --arg nonce_sha256 "${nonce_sha256}" \
  '{run_id:$run_id,nonce_sha256:$nonce_sha256}' >>"${OPENCLAW_CALL_LOG:?}"
jq -nc '{status:"waiting_for_callbacks"}'
FAKE
chmod +x "${FAKE_OPENCLAW}"
: >"${OPENCLAW_CALL_LOG}"

initialize_state() {
  local state_root="$1"
  local queue_json="$2"

  STATE_ROOT="${state_root}" "${BASH}" -c '
    source "$1"
    ensure_state_dirs
  ' _ "${SKILL_DIR}/scripts/env_paths.sh"
  printf '%s\n' '{"pending":{}}' >"${state_root}/_dispatcher/pending.json"
  printf '%s\n' "${queue_json}" >"${state_root}/_dispatcher/executor_queue.json"
}

run_drain() {
  local state_root="$1"
  STATE_ROOT="${state_root}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main \
  EXECUTOR_AGENT_TIMEOUT_SECONDS=60 \
  EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS=0 \
  EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS=0 \
  EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS=1 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_queue.sh"
}

base_item='{
  "queue_id":"execq-1",
  "project":"group/project",
  "iid":42,
  "issue_url":null,
  "executor_agent":"req_executor",
  "target_branch":null,
  "origin":null,
  "req_digest":"pre-upgrade request",
  "queued_at":1
}'

for legacy_state in queued launching launch_failed; do
  case_root="${TEST_ROOT}/${legacy_state}"
  case "${legacy_state}" in
    queued)
      queue_json="$(jq -cn --argjson item "${base_item}" \
        '{next_id:2,active:null,queue:[$item]}')"
      ;;
    launching)
      queue_json="$(jq -cn --argjson item "${base_item}" '
        {next_id:2,queue:[],active:($item + {
          correlation_id:"reqd-old-launching",run_id:"executor-execq-1",
          launch_state:"launching",launch_attempts:1,launch_started_at:0,
          launched_at:null,next_retry_after:null,launch_error:null
        })}')"
      ;;
    launch_failed)
      queue_json="$(jq -cn --argjson item "${base_item}" '
        {next_id:2,queue:[],active:($item + {
          correlation_id:"reqd-old-failed",run_id:"executor-execq-1",
          launch_state:"launch_failed",launch_attempts:1,launch_started_at:0,
          launched_at:null,next_retry_after:0,launch_error:"old failure"
        })}')"
      ;;
  esac
  initialize_state "${case_root}" "${queue_json}"
  output="$(run_drain "${case_root}")"
  if ! jq -e '.status == "launched"' <<<"${output}" >/dev/null; then
    echo "expected ${legacy_state} pre-upgrade intent to launch with migrated nonce" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  if grep -q 'callback_nonce' <<<"${output}"; then
    echo "migrated nonce leaked through ${legacy_state} public output" >&2
    exit 1
  fi
done

launched_root="${TEST_ROOT}/launched"
launched_queue="$(jq -cn --argjson item "${base_item}" '
  {next_id:2,queue:[],active:($item + {
    correlation_id:"reqd-old-launched",run_id:"executor-execq-1",
    launch_state:"launched",launch_attempts:1,launch_started_at:1,
    launched_at:2,next_retry_after:null,launch_error:null,
    child_session_key:"agent:req_executor:legacy"
  })}')"
initialize_state "${launched_root}" "${launched_queue}"
calls_before="$(wc -l <"${OPENCLAW_CALL_LOG}" | tr -d ' ')"
launched_output="$(run_drain "${launched_root}")"
calls_after="$(wc -l <"${OPENCLAW_CALL_LOG}" | tr -d ' ')"
if ! jq -e '.status == "busy" and .reason == "active_executor_pending"' \
    <<<"${launched_output}" >/dev/null \
  || jq -e '.active | has("callback_nonce")' \
    "${launched_root}/_dispatcher/executor_queue.json" >/dev/null \
  || [ "${calls_after}" -ne "${calls_before}" ]; then
  echo "already-launched pre-upgrade active was rebound or resent" >&2
  exit 1
fi

echo "ok pre-upgrade unsent legacy queue intents migrate nonce before delivery"
