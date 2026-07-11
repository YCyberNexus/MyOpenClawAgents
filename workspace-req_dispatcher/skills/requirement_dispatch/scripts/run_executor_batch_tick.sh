#!/usr/bin/env bash
# Dispatcher recovery tick: advance legacy FIFO first, then I1 outbox and notifications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

legacy_recovery_before="$("${BASH}" "${SCRIPT_DIR}/recover_legacy_executor_batch_bridge.sh")"
legacy_queue_result="$("${BASH}" "${SCRIPT_DIR}/drain_executor_queue.sh")"
legacy_recovery_after="$("${BASH}" "${SCRIPT_DIR}/recover_legacy_executor_batch_bridge.sh")"
batch_outbox_result="$("${BASH}" "${SCRIPT_DIR}/drain_executor_batch_outbox.sh")"
notification_result="$("${BASH}" "${SCRIPT_DIR}/drain_executor_batch_notifications.sh")"

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
