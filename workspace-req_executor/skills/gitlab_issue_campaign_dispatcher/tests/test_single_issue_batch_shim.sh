#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "test_single_issue_batch_shim.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-single-batch-shim.XXXXXX")"
CAPTURE_FILE="${TEST_ROOT}/driven-trigger.txt"
FIRST_CAPTURE="${TEST_ROOT}/driven-trigger-first.txt"
DRIVEN_BATCH_CMD="${TEST_ROOT}/run_driven_issue_batch.sh"

mkdir -p "${TEST_ROOT}/config"
cat >"${TEST_ROOT}/config/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=fixture-secret-must-not-be-forwarded
EOF
cat >"${TEST_ROOT}/config/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${TEST_ROOT}/scheduler
EXECUTOR_MAX_CONCURRENCY=3
EOF

cat >"${DRIVEN_BATCH_CMD}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
cat >"${CAPTURE_FILE}"
jq -cn '{
  status:"accepted",
  batch_id:"fake",
  matched_count:1,
  snapshot_digest:"fake-digest",
  scheduler_status:"queued",
  spawn_grants:[],
  reconcile_actions:[],
  operation_results:[],
  max_launch_retries:3,
  backoff_seconds:2,
  chat_summary:"accepted"
}'
EOF
chmod +x "${DRIVEN_BATCH_CMD}"

run_single() {
  CONFIG_DIR="${TEST_ROOT}/config" \
  DRIVEN_BATCH_CMD="${DRIVEN_BATCH_CMD}" \
  CAPTURE_FILE="${CAPTURE_FILE}" \
    bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" <<'EOF'
RUN_SINGLE_ISSUE
project=group/repo
iid=42
dispatcher_callback_target=agent:req_dispatcher:main
branch=release/2026.07
EOF
}

first_output="$(run_single)" || fail "RUN_SINGLE_ISSUE without correlation_id must enter the batch shim"
cp "${CAPTURE_FILE}" "${FIRST_CAPTURE}"
second_output="$(run_single)" || fail "idempotent RUN_SINGLE_ISSUE replay must succeed"

[ "${first_output}" = "${second_output}" ] \
  || fail "idempotent single replay returned a different envelope"
cmp -s "${FIRST_CAPTURE}" "${CAPTURE_FILE}" \
  || fail "idempotent single replay generated a different driven trigger"

[ "$(sed -n '1p' "${CAPTURE_FILE}")" = "RUN_DRIVEN_ISSUE_BATCH" ] \
  || fail "single shim did not delegate to RUN_DRIVEN_ISSUE_BATCH"
grep -Eq '^batch_id=single-[0-9a-f]{64}$' "${CAPTURE_FILE}" \
  || fail "single shim did not generate a stable content-addressed batch_id"
grep -Eq '^correlation_id=single-correlation-[0-9a-f]{64}$' "${CAPTURE_FILE}" \
  || fail "single shim did not generate a stable correlation_id"
grep -qx 'project=group/repo' "${CAPTURE_FILE}" \
  || fail "single shim did not preserve the full project"
grep -qx 'selector_type=single' "${CAPTURE_FILE}" \
  || fail "single shim did not generate a single selector"
grep -qx 'iid=42' "${CAPTURE_FILE}" \
  || fail "single shim did not preserve iid=42"
grep -qx 'force_rerun_pr=false' "${CAPTURE_FILE}" \
  || fail "single shim did not pin force_rerun_pr=false"
grep -qx 'dispatcher_callback_target=agent:req_dispatcher:main' "${CAPTURE_FILE}" \
  || fail "single shim did not preserve the callback target"
grep -qx 'branch=release/2026.07' "${CAPTURE_FILE}" \
  || fail "single shim did not preserve the optional branch"

if grep -Eq 'RUN_SCHEDULED_ISSUE_CAMPAIGN|max_concurrent_subagents|gitlab_token|GITLAB_TOKEN|fixture-secret' \
    "${CAPTURE_FILE}"; then
  fail "single shim leaked legacy campaign fields or a GitLab token"
fi

explicit_capture="${TEST_ROOT}/explicit-trigger.txt"
CONFIG_DIR="${TEST_ROOT}/config" \
DRIVEN_BATCH_CMD="${DRIVEN_BATCH_CMD}" \
CAPTURE_FILE="${explicit_capture}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null <<'EOF'
RUN_SINGLE_ISSUE
project=group/repo
iid=42
correlation_id=reqd-existing-correlation
dispatcher_callback_target=agent:req_dispatcher:main
EOF
grep -qx 'correlation_id=reqd-existing-correlation' "${explicit_capture}" \
  || fail "single shim did not preserve an explicit correlation_id"

empty_callback_capture="${TEST_ROOT}/empty-callback-trigger.txt"
set +e
CONFIG_DIR="${TEST_ROOT}/config" \
DRIVEN_BATCH_CMD="${DRIVEN_BATCH_CMD}" \
CAPTURE_FILE="${empty_callback_capture}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null \
    2>"${TEST_ROOT}/empty-callback.err" <<'EOF'
RUN_SINGLE_ISSUE
project=group/repo
iid=42
dispatcher_callback_target=
EOF
empty_callback_rc=$?
set -e
[ "${empty_callback_rc}" -eq 2 ] \
  || fail "empty dispatcher_callback_target was accepted"
[ ! -e "${empty_callback_capture}" ] \
  || fail "empty callback target reached the driven batch wrapper"

jq -e '
  (keys | sort) == [
    "backoff_seconds","batch_id","chat_summary","matched_count",
    "max_launch_retries","operation_results","reconcile_actions","scheduler_status",
    "snapshot_digest","spawn_grants","status"
  ]
  and .status == "accepted"
  and .spawn_grants == []
  and .reconcile_actions == []
' <<<"${first_output}" >/dev/null \
  || fail "single shim did not forward the fixed driven-batch envelope"

echo "ok single issue uses stable agent-scheduler batch shim"
