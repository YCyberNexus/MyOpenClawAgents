#!/usr/bin/env bash
# Dispatcher recovery tick: evict stuck work, advance legacy FIFO, then I1 work.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

EVICT_STUCK_SCRIPT="${EVICT_STUCK_SCRIPT:-${SCRIPT_DIR}/evict_stuck.sh}"
RECOVER_LEGACY_EXECUTOR_BATCH_BRIDGE_SCRIPT="${RECOVER_LEGACY_EXECUTOR_BATCH_BRIDGE_SCRIPT:-${SCRIPT_DIR}/recover_legacy_executor_batch_bridge.sh}"
DRAIN_EXECUTOR_QUEUE_SCRIPT="${DRAIN_EXECUTOR_QUEUE_SCRIPT:-${SCRIPT_DIR}/drain_executor_queue.sh}"
DRAIN_EXECUTOR_BATCH_OUTBOX_SCRIPT="${DRAIN_EXECUTOR_BATCH_OUTBOX_SCRIPT:-${SCRIPT_DIR}/drain_executor_batch_outbox.sh}"
DRAIN_EXECUTOR_BATCH_NOTIFICATIONS_SCRIPT="${DRAIN_EXECUTOR_BATCH_NOTIFICATIONS_SCRIPT:-${SCRIPT_DIR}/drain_executor_batch_notifications.sh}"

"${BASH}" "${EVICT_STUCK_SCRIPT}" >/dev/null
legacy_recovery_before="$("${BASH}" "${RECOVER_LEGACY_EXECUTOR_BATCH_BRIDGE_SCRIPT}")"
legacy_queue_result="$("${BASH}" "${DRAIN_EXECUTOR_QUEUE_SCRIPT}")"
legacy_recovery_after="$("${BASH}" "${RECOVER_LEGACY_EXECUTOR_BATCH_BRIDGE_SCRIPT}")"
batch_outbox_result="$("${BASH}" "${DRAIN_EXECUTOR_BATCH_OUTBOX_SCRIPT}")"
notification_result="$("${BASH}" "${DRAIN_EXECUTOR_BATCH_NOTIFICATIONS_SCRIPT}")"

jq -cn \
  --argjson legacy_recovery_before "${legacy_recovery_before}" \
  --argjson legacy_queue "${legacy_queue_result}" \
  --argjson legacy_recovery_after "${legacy_recovery_after}" \
  --argjson batch_outbox "${batch_outbox_result}" \
  --argjson notifications "${notification_result}" '{
    status:"tick",
    legacy_recovery_before:$legacy_recovery_before,
    legacy_queue:$legacy_queue,
    legacy_recovery_after:$legacy_recovery_after,
    batch_outbox:$batch_outbox,
    notifications:$notifications
  }'
