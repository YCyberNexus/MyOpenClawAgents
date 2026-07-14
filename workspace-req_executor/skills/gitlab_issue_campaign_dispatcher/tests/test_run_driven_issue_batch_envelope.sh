#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/run_driven_issue_batch.sh"

fail() {
  echo "test_run_driven_issue_batch_envelope.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-driven-envelope.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
CREATE_BATCH="${TEST_ROOT}/create_batch.sh"
EXECUTOR_TICK="${TEST_ROOT}/executor_tick.sh"
mkdir -p "${CONFIG_DIR}"

cat >"${CREATE_BATCH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
jq -cn '{
  status:"success",batch_id:"batch-A",matched_count:1,
  snapshot_digest:"digest-A",scheduler_status:"running"
}'
EOF
cat >"${EXECUTOR_TICK}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn '{
  status:"cleanup_required",spawn_grants:[],reconcile_actions:[],
  cleanup_actions:[{
    action:"kill",target:"agent:req_executor:subagent:42",
    reason:"durable_worker_result_recovered"
  }],
  operation_results:[{
    operation:"durable_worker_result_reconcile",status:"handled"
  }],
  max_launch_retries:3,backoff_seconds:2,
  chat_summary:"durable result recovered"
}'
EOF
chmod +x "${CREATE_BATCH}" "${EXECUTOR_TICK}"

envelope="$(printf '%s\n' RUN_DRIVEN_ISSUE_BATCH | \
  CONFIG_DIR="${CONFIG_DIR}" CREATE_BATCH_CMD="${CREATE_BATCH}" \
  EXECUTOR_TICK_CMD="${EXECUTOR_TICK}" bash "${WRAPPER}")" \
  || fail "run_driven_issue_batch.sh rejected a cleanup tick"

jq -e '
  (keys | sort) == [
    "backoff_seconds","batch_id","chat_summary","cleanup_actions",
    "matched_count","max_launch_retries","operation_results",
    "reconcile_actions","scheduler_status","snapshot_digest",
    "spawn_grants","status"
  ]
  and .status == "accepted"
  and .batch_id == "batch-A"
  and .spawn_grants == []
  and .reconcile_actions == []
  and .cleanup_actions == [{
    action:"kill",target:"agent:req_executor:subagent:42",
    reason:"durable_worker_result_recovered"
  }]
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    and .status == "handled")] | length) == 1
' <<<"${envelope}" >/dev/null \
  || fail "cleanup_actions were not preserved in the rich intake envelope"

echo "ok driven intake preserves cleanup actions"
