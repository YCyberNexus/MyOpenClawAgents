#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-correlation.XXXXXX")"
STATE_ROOT="${TEST_ROOT}/state"

cid1="$(STATE_ROOT="${STATE_ROOT}" bash "${SKILL_DIR}/scripts/next_correlation_id.sh")"
cid2="$(STATE_ROOT="${STATE_ROOT}" bash "${SKILL_DIR}/scripts/next_correlation_id.sh")"

if [ "${cid1}" != "reqd-1" ]; then
  echo "expected first correlation id to be reqd-1, got: ${cid1}" >&2
  exit 1
fi

if [ "${cid2}" != "reqd-2" ]; then
  echo "expected second correlation id to be reqd-2, got: ${cid2}" >&2
  exit 1
fi

STATE_ROOT="${STATE_ROOT}" \
RUN_ID="executor-run-1" \
STAGE="executor" \
PROJECT="claw_gitlab/px_ifp_hulat_test" \
IID="42" \
CORRELATION_ID="${cid1}" \
bash "${SKILL_DIR}/scripts/record_pending.sh" >/dev/null

if [ "$(jq -r '.pending["executor-run-1"].stuck_after_minutes' \
    "${STATE_ROOT}/_dispatcher/pending.json")" != "390" ]; then
  echo "expected record_pending.sh to persist its creation-time stuck budget" >&2
  exit 1
fi

# An executor pending entry is discoverable through the legacy I2 helper only
# when the same pre-upgrade launched active exists. find_pending.sh atomically
# projects both records to explicit legacy_pre_upgrade state.
queue_candidate="$(mktemp "${STATE_ROOT}/_dispatcher/executor_queue.XXXXXX")"
jq \
  --arg run_id "executor-run-1" \
  --arg correlation_id "${cid1}" '
  .active = {
    queue_id:"legacy-correlation-fixture",
    run_id:$run_id,
    correlation_id:$correlation_id,
    project:"claw_gitlab/px_ifp_hulat_test",
    iid:42,
    executor_agent:"req_executor",
    launch_state:"launched"
  }
' "${STATE_ROOT}/_dispatcher/executor_queue.json" >"${queue_candidate}"
mv "${queue_candidate}" "${STATE_ROOT}/_dispatcher/executor_queue.json"

found="$(STATE_ROOT="${STATE_ROOT}" CORRELATION_ID="${cid1}" bash "${SKILL_DIR}/scripts/find_pending.sh")"
run_id="$(printf '%s' "${found}" | jq -r '.run_id')"
stage="$(printf '%s' "${found}" | jq -r '.stage')"

if [ "${run_id}" != "executor-run-1" ]; then
  echo "expected find_pending.sh to return executor-run-1, got: ${run_id}" >&2
  exit 1
fi

if [ "${stage}" != "executor" ]; then
  echo "expected find_pending.sh stage executor, got: ${stage}" >&2
  exit 1
fi

if STATE_ROOT="${STATE_ROOT}" CORRELATION_ID="missing" bash "${SKILL_DIR}/scripts/find_pending.sh" >/dev/null 2>&1; then
  echo "expected find_pending.sh to fail for missing correlation id" >&2
  exit 1
fi

echo "ok correlation helpers"
