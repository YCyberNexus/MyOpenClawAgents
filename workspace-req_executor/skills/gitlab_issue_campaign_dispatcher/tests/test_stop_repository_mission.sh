#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
STOP_CMD="${SKILL_DIR}/scripts/stop_repository_mission.sh"
EMIT_CMD="${SKILL_DIR}/scripts/emit_mission_stop_receipt.sh"
TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-mission-stop.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
REPO_ROOT="${TEST_ROOT}/repos"
RECEIPT_NONCE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if command -v sha256sum >/dev/null 2>&1; then
  RECEIPT_DIGEST="$(printf '%s' "${RECEIPT_NONCE}" | sha256sum | awk '{print $1}')"
else
  RECEIPT_DIGEST="$(printf '%s' "${RECEIPT_NONCE}" | shasum -a 256 | awk '{print $1}')"
fi
[[ "${RECEIPT_DIGEST}" =~ ^[0-9a-f]{64}$ ]]
EXPECTED_STOP_ID="mission-stop-receipt-${RECEIPT_DIGEST}"
mkdir -p "${CONFIG_DIR}" "${SCHEDULER_ROOT}/batches/batch-target" \
  "${SCHEDULER_ROOT}/batches/batch-completed-target" \
  "${SCHEDULER_ROOT}/batches/batch-other" "${SCHEDULER_ROOT}/launch_actions" \
  "${REPO_ROOT}/group/project/.req_executor/_dispatcher"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=test-token
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${REPO_ROOT}
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_ACPX_TIMEOUT_SECONDS=3600
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF
cat >"${TEST_ROOT}/reserve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${DRIVEN_SCHEDULER_MIGRATION_ONLY:-}" = 1 ]
EOF
cat >"${TEST_ROOT}/resolve.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '${REPO_ROOT}/group/project'
EOF
chmod +x "${TEST_ROOT}/reserve.sh" "${TEST_ROOT}/resolve.sh"

cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"batch-target","batch_order":["batch-target","batch-completed-target","batch-other"],"active_jobs":{"target-job":{"job_id":"target-job","project":"group/project","iid":12,"reservation_seq":1,"memberships":[{"batch_id":"batch-target","snapshot_index":0}]},"other-job":{"job_id":"other-job","project":"group/other","iid":8,"reservation_seq":2,"memberships":[{"batch_id":"batch-other","snapshot_index":0}]}}}
EOF
cat >"${SCHEDULER_ROOT}/batches/batch-target/request.json" <<'EOF'
{"project":"group/project"}
EOF
cat >"${SCHEDULER_ROOT}/batches/batch-target/state.json" <<'EOF'
{"version":1,"batch_id":"batch-target","status":"running","memberships":{"0":{"status":"running","job_id":"target-job"}},"terminal_count":0,"done_count":0,"failed_count":0,"timeout_count":0,"skipped_count":0}
EOF
cat >"${SCHEDULER_ROOT}/batches/batch-completed-target/request.json" <<'EOF'
{"project":"group/project"}
EOF
cat >"${SCHEDULER_ROOT}/batches/batch-completed-target/state.json" <<'EOF'
{"version":1,"batch_id":"batch-completed-target","status":"completed","memberships":{"0":{"status":"terminal","terminal_status":"done"}},"terminal_count":1,"done_count":1,"failed_count":0,"timeout_count":0,"skipped_count":0}
EOF
cat >"${SCHEDULER_ROOT}/batches/batch-other/request.json" <<'EOF'
{"project":"group/other"}
EOF
cat >"${SCHEDULER_ROOT}/batches/batch-other/state.json" <<'EOF'
{"version":1,"batch_id":"batch-other","status":"running","memberships":{"0":{"status":"running","job_id":"other-job"}},"terminal_count":0,"done_count":0,"failed_count":0,"timeout_count":0,"skipped_count":0}
EOF
cat >"${SCHEDULER_ROOT}/launch_actions/target.json" <<'EOF'
{"project":"group/project","job_id":"target-job","child_label":"issue-group-project-12","ack":{"child_session_key":"agent:req_executor:child-12"}}
EOF
mkdir -p "${SCHEDULER_ROOT}/callback_outbox"
cat >"${SCHEDULER_ROOT}/callback_outbox/target-event.json" <<'EOF'
{"body":{"project":"group/project"}}
EOF
cat >"${SCHEDULER_ROOT}/callback_outbox/other-event.json" <<'EOF'
{"body":{"project":"group/other"}}
EOF
cat >"${REPO_ROOT}/group/project/.req_executor/_dispatcher/campaign_state.json" <<'EOF'
{"campaign_status":"running","pending_subagents":{"12":{"child_session_key":"agent:req_executor:child-12"},"13":{"child_session_key":"agent:req_executor:child-13"}},"active_issue_iids":[12,13],"active_issue_sessions":["a","b"],"driven_handoff_intents":{"12":{"status":"prepared"}}}
EOF

output="$(printf '/mission-stop https://gitlab.example.test/group/project/-/issues/12?receipt_nonce=%s\n' \
  "${RECEIPT_NONCE}" |
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=100 RESERVE_CMD="${TEST_ROOT}/reserve.sh" \
  RESOLVE_REPO_CMD="${TEST_ROOT}/resolve.sh" bash "${STOP_CMD}")"
jq -e '
  .status == "success"
  and .public_result.project == "group/project"
  and .public_result.stopped_batch_ids == ["batch-target"]
  and .public_result.stopped_job_count == 1
  and .public_result.stopped_issue_iids == [12,13]
  and [.cleanup_actions[].target] == ["agent:req_executor:child-12","agent:req_executor:child-13"]
  and .runtime_labels == ["issue-group-project-12"]
' <<<"${output}" >/dev/null
[ "$(jq -r '.public_result.stop_id' <<<"${output}")" = "${EXPECTED_STOP_ID}" ]
jq -e '
  .batch_order == ["batch-other"] and .round_robin_cursor == null
  and (.active_jobs | keys) == ["other-job"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '
  .status == "failed" and .memberships["0"].status == "skipped"
  and .mission_stop.project == "group/project"
' "${SCHEDULER_ROOT}/batches/batch-target/state.json" >/dev/null
jq -e '
  .status == "completed" and .memberships["0"].terminal_status == "done"
' "${SCHEDULER_ROOT}/batches/batch-completed-target/state.json" >/dev/null
jq -e '
  (.pending_subagents | length) == 0 and .active_issue_iids == []
  and (.driven_handoff_intents | not)
' "${REPO_ROOT}/group/project/.req_executor/_dispatcher/campaign_state.json" >/dev/null
[ ! -f "${SCHEDULER_ROOT}/launch_actions/target.json" ]
[ -f "${SCHEDULER_ROOT}/mission_stop_archive/$(jq -r '.public_result.stop_id' <<<"${output}")/launch_actions/target.json" ]
[ -f "${SCHEDULER_ROOT}/mission_stop_archive/$(jq -r '.public_result.stop_id' <<<"${output}")/callback_outbox/target-event.json" ]
[ -f "${SCHEDULER_ROOT}/callback_outbox/other-event.json" ]
[ -f "${SCHEDULER_ROOT}/mission_stop_archive/${EXPECTED_STOP_ID}/envelope.json" ]

receipt="$(CONFIG_DIR="${CONFIG_DIR}" STOP_ID="${EXPECTED_STOP_ID}" \
  bash "${EMIT_CMD}")"
[ "$(jq -cS . <<<"${receipt}")" = "$(jq -cS '.public_result' <<<"${output}")" ]

# Replaying the same private nonce returns the durable envelope so the
# orchestrator can safely repeat best-effort runtime cleanup.
replay="$(printf '/mission-stop group/project?receipt_nonce=%s\n' "${RECEIPT_NONCE}" |
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=999 RESERVE_CMD="${TEST_ROOT}/reserve.sh" \
  RESOLVE_REPO_CMD="${TEST_ROOT}/resolve.sh" bash "${STOP_CMD}")"
[ "$(jq -cS . <<<"${replay}")" = "$(jq -cS . <<<"${output}")" ]

invalid_nonce="$(printf '/mission-stop group/project?receipt_nonce=bad\n' |
  CONFIG_DIR="${CONFIG_DIR}" RESERVE_CMD="${TEST_ROOT}/reserve.sh" \
  RESOLVE_REPO_CMD="${TEST_ROOT}/resolve.sh" bash "${STOP_CMD}")"
jq -e '.status == "failed" and (.reason | contains("nonce"))' \
  <<<"${invalid_nonce}" >/dev/null

# The path form is accepted and a repeat is a successful no-op.
repeat="$(printf '/mission-stop group/project\n' |
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=101 RESERVE_CMD="${TEST_ROOT}/reserve.sh" \
  RESOLVE_REPO_CMD="${TEST_ROOT}/resolve.sh" bash "${STOP_CMD}")"
jq -e '.status == "success" and .public_result.stopped_job_count == 0' <<<"${repeat}" >/dev/null

echo "ok repository mission stop fences executor state and returns runtime cleanup targets"
