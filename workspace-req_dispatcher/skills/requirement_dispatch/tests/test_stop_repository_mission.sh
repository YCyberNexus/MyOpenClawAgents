#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/stop_repository_mission.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-mission-stop.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
STATE_ROOT="${TEST_ROOT}/state"
EXECUTOR_ROOT="${TEST_ROOT}/executor-scheduler"
CAPTURE="${TEST_ROOT}/capture.json"
FAKE_TURN="${TEST_ROOT}/run-agent-turn.sh"
mkdir -p "${CONFIG_DIR}" "${STATE_ROOT}/_dispatcher" "${EXECUTOR_ROOT}"

cat >"${CONFIG_DIR}/dispatcher.env" <<EOF
STATE_ROOT=${STATE_ROOT}
DEFAULT_EXECUTOR_AGENT=req_executor
ROUTING_FILE=
EXECUTOR_SCHEDULER_STATE_FILE=${EXECUTOR_ROOT}/scheduler_state.json
WIKI_GITLAB_HOST=gitlab.example.test
WIKI_GITLAB_API_PROTOCOL=https
WIKI_GITLAB_TOKEN=wiki-token
EOF
cat >"${FAKE_TURN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg target_agent "${TARGET_AGENT:-}" \
  --arg message "${MESSAGE:-}" \
  '{target_agent:$target_agent,message:$message}' >"${CAPTURE}"
nonce="${MESSAGE##*receipt_nonce=}"
[[ "${nonce}" =~ ^[0-9a-f]{64}$ ]]
if command -v sha256sum >/dev/null 2>&1; then
  nonce_digest="$(printf '%s' "${nonce}" | sha256sum | awk '{print $1}')"
else
  nonce_digest="$(printf '%s' "${nonce}" | shasum -a 256 | awk '{print $1}')"
fi
[[ "${nonce_digest}" =~ ^[0-9a-f]{64}$ ]]
stop_id="mission-stop-receipt-${nonce_digest}"
result="$(jq -cnS --arg stop_id "${stop_id}" '{
  status:"success",project:"group/project",stop_id:$stop_id,
  stopped_batch_ids:["batch-executor"],stopped_job_count:2,
  stopped_issue_iids:[12,13],cleanup_requested_count:2
}')"
case "${FAKE_TURN_MODE:-durable_prose}" in
  durable_prose)
    receipt_dir="${EXECUTOR_SCHEDULER_STATE_FILE%/*}/mission_stop_archive/${stop_id}"
    mkdir -p "${receipt_dir}"
    printf '%s\n' "${result}" >"${receipt_dir}/result.json"
    jq -cn '{status:"failed",exit_code:70,worker_result_json:null,raw_output:"执行成功，但模型返回了中文总结"}'
    ;;
  conflict)
    receipt_dir="${EXECUTOR_SCHEDULER_STATE_FILE%/*}/mission_stop_archive/${stop_id}"
    mkdir -p "${receipt_dir}"
    printf '%s\n' "${result}" >"${receipt_dir}/result.json"
    jq -cn --argjson result "${result}" '{
      status:"success",exit_code:0,
      worker_result_json:($result | .cleanup_requested_count = 3)
    }'
    ;;
  direct)
    jq -cn --argjson result "${result}" \
      '{status:"success",exit_code:0,worker_result_json:$result}'
    ;;
  *) exit 91 ;;
esac
EOF
chmod +x "${FAKE_TURN}"

cat >"${STATE_ROOT}/_dispatcher/executor_batch_outbox.json" <<'EOF'
{"version":1,"requests":[{"accepted_at":null,"attempts":0,"auto_merge":false,"batch_id":"batch-outbox","callback_nonce":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","correlation_id":"reqd-1","created_at":"2026-07-22T00:00:00Z","executor_agent":"req_executor","force_rerun_pr":false,"last_attempt_at":null,"last_error":null,"matched_count":null,"merge_target_branch":null,"origin":null,"payload":"RUN_DRIVEN_ISSUE_BATCH\nbatch_id=batch-outbox\nproject=group/project\nexecutor_agent=req_executor\ncallback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","project":"group/project","received_at":null,"request_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","scheduler_status":null,"selector":{"type":"single","iid":12},"snapshot_digest":null,"status":"queued","target_branch":null,"updated_at":"2026-07-22T00:00:00Z"}]}
EOF
cat >"${STATE_ROOT}/_dispatcher/executor_batches.json" <<'EOF'
{"batches":{"batch-outbox":{"batch_id":"batch-outbox","project":"group/project","executor_agent":"req_executor","callback_auth_mode":"nonce_v1","callback_nonce_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","origin":null,"matched_count":2,"terminal_count":0,"status":"queued","request_digest":"digest","created_at":"2026-07-22T00:00:00Z","updated_at":"2026-07-22T00:00:00Z"},"batch-other":{"batch_id":"batch-other","project":"group/other","status":"running"}}}
EOF
cat >"${STATE_ROOT}/_dispatcher/executor_queue.json" <<'EOF'
{"next_id":3,"active":{"queue_id":"execq-1","project":"group/project"},"queue":[{"queue_id":"execq-2","project":"group/project"},{"queue_id":"execq-3","project":"group/other"}]}
EOF
cat >"${STATE_ROOT}/_dispatcher/pending.json" <<'EOF'
{"pending":{"run-target":{"run_id":"run-target","stage":"executor","project":"group/project"},"run-issuer":{"run_id":"run-issuer","stage":"git_issuer","project":"group/project"},"run-other":{"run_id":"run-other","stage":"executor","project":"group/other"}}}
EOF
cat >"${STATE_ROOT}/_dispatcher/executor_batch_notifications.json" <<'EOF'
{"notifications":[{"batch_id":"batch-outbox","event_id":"old"},{"batch_id":"batch-other","event_id":"keep"}]}
EOF

output="$(printf '/mission-stop https://gitlab.example.test/group/project/-/issues/12\n' |
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" bash "${WRAPPER}")"
jq -e '
  .status == "success" and .project == "group/project"
  and .executor_agent == "req_executor"
  and .stopped_batch_ids == ["batch-executor","batch-outbox"]
  and .cleared_dispatcher_request_count == 1
  and .cleared_legacy_queue_count == 2
  and .cleared_pending_count == 2
  and .cleared_notification_count == 1
' <<<"${output}" >/dev/null
if jq -e '.target_agent == "req_executor" and .message == "/mission-stop group/project"' \
    "${CAPTURE}" >/dev/null 2>&1; then
  echo "dispatcher omitted the private mission stop receipt nonce" >&2
  exit 1
fi
captured_message="$(jq -r '.message' "${CAPTURE}")"
[[ "${captured_message}" =~ ^/mission-stop\ group/project\?receipt_nonce=([0-9a-f]{64})$ ]]
receipt_nonce="${BASH_REMATCH[1]}"
if command -v sha256sum >/dev/null 2>&1; then
  receipt_digest="$(printf '%s' "${receipt_nonce}" | sha256sum | awk '{print $1}')"
else
  receipt_digest="$(printf '%s' "${receipt_nonce}" | shasum -a 256 | awk '{print $1}')"
fi
[[ "${receipt_digest}" =~ ^[0-9a-f]{64}$ ]]
[ "$(jq -r '.stop_id' <<<"${output}")" = "mission-stop-receipt-${receipt_digest}" ]
jq -e '.requests == []' "${STATE_ROOT}/_dispatcher/executor_batch_outbox.json" >/dev/null
jq -e '.batches["batch-outbox"].status == "failed" and .batches["batch-other"].status == "running"' \
  "${STATE_ROOT}/_dispatcher/executor_batches.json" >/dev/null
jq -e '.active == null and [.queue[].project] == ["group/other"]' \
  "${STATE_ROOT}/_dispatcher/executor_queue.json" >/dev/null
jq -e '(.pending | keys | sort) == ["run-other"]' \
  "${STATE_ROOT}/_dispatcher/pending.json" >/dev/null
jq -e '[.notifications[].event_id] == ["keep"]' \
  "${STATE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null
[ -f "${STATE_ROOT}/_dispatcher/mission_stop_archive/mission-stop-receipt-${receipt_digest}.json" ]

conflict="$(MESSAGE='/mission-stop group/project' \
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  FAKE_TURN_MODE=conflict CAPTURE="${CAPTURE}" bash "${WRAPPER}")"
jq -e '.status == "failed" and (.reason | contains("direct and durable"))' \
  <<<"${conflict}" >/dev/null

capture_before="$(jq -cS . "${CAPTURE}")"
invalid="$(MESSAGE='/mission-stop https://evil.example/group/project' \
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" bash "${WRAPPER}")"
jq -e '.status == "failed" and (.reason | contains("configured GitLab host"))' \
  <<<"${invalid}" >/dev/null
[ "${capture_before}" = "$(jq -cS . "${CAPTURE}")" ]

echo "ok dispatcher mission stop routes by repository and clears durable local chains"
