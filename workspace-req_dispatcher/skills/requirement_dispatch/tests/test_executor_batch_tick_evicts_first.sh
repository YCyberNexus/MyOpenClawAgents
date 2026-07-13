#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-tick-order.XXXXXX")"
STATE_ROOT_PATH="${TEST_ROOT}/state"
ORDER_LOG="${TEST_ROOT}/order.log"
FIXTURE="${SCRIPT_DIR}/fixtures/executor_tick_stage.sh"

for stage in evict recover queue outbox notifications; do
  ln -s "${FIXTURE}" "${TEST_ROOT}/${stage}.sh"
done

STATE_ROOT="${STATE_ROOT_PATH}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"

result="$(
  STATE_ROOT="${STATE_ROOT_PATH}" \
  DISPATCHER_CALLBACK_TARGET=req_dispatcher \
  TICK_ORDER_LOG="${ORDER_LOG}" \
  EVICT_STUCK_SCRIPT="${TEST_ROOT}/evict.sh" \
  RECOVER_LEGACY_EXECUTOR_BATCH_BRIDGE_SCRIPT="${TEST_ROOT}/recover.sh" \
  DRAIN_EXECUTOR_QUEUE_SCRIPT="${TEST_ROOT}/queue.sh" \
  DRAIN_EXECUTOR_BATCH_OUTBOX_SCRIPT="${TEST_ROOT}/outbox.sh" \
  DRAIN_EXECUTOR_BATCH_NOTIFICATIONS_SCRIPT="${TEST_ROOT}/notifications.sh" \
    "${BASH}" "${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
)"

actual_order=""
if [ -f "${ORDER_LOG}" ]; then
  actual_order="$(paste -sd, "${ORDER_LOG}")"
fi
expected_order="evict,recover,queue,recover,outbox,notifications"
if [ "${actual_order}" != "${expected_order}" ]; then
  echo "expected tick order ${expected_order}; got ${actual_order:-<empty>}" >&2
  exit 1
fi

if ! jq -e '
  .status == "tick"
  and .legacy_recovery_before.stage == "recover"
  and .legacy_queue.stage == "queue"
  and .legacy_recovery_after.stage == "recover"
  and .batch_outbox.stage == "outbox"
  and .notifications.stage == "notifications"
' <<<"${result}" >/dev/null; then
  echo "tick output did not preserve stage results" >&2
  exit 1
fi

echo "ok executor batch tick evicts stuck work before every drain stage"
