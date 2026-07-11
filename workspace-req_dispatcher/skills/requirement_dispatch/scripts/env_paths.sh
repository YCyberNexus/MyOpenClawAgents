#!/usr/bin/env bash
# 路径自举：每个脚本顶部 `source` 本文件。
# 要求 STATE_ROOT 在 env（config/dispatcher.env 提供，或调用方在同一行导出）。
set -euo pipefail

: "${STATE_ROOT:?STATE_ROOT is required (set in config/dispatcher.env or export before call)}"

DISPATCHER_DIR="${STATE_ROOT}/_dispatcher"
PENDING_FILE="${DISPATCHER_DIR}/pending.json"
EXECUTOR_QUEUE_FILE="${DISPATCHER_DIR}/executor_queue.json"
LEDGER_FILE="${DISPATCHER_DIR}/ledger.jsonl"
SEQ_FILE="${DISPATCHER_DIR}/seq"
LOCK_FILE="${DISPATCHER_DIR}/pending.lock"
LOG_DIR="${DISPATCHER_DIR}/log"
EXECUTOR_BATCH_MIRROR_FILE="${DISPATCHER_DIR}/executor_batches.json"
EXECUTOR_BATCH_OUTBOX_FILE="${DISPATCHER_DIR}/executor_batch_outbox.json"
EXECUTOR_BATCH_EVENT_LEDGER_FILE="${DISPATCHER_DIR}/executor_batch_events.jsonl"
EXECUTOR_BATCH_NOTIFICATIONS_FILE="${DISPATCHER_DIR}/executor_batch_notifications.json"
EXECUTOR_BATCH_NOTIFICATION_ATTEMPTS_DIR="${DISPATCHER_DIR}/executor_batch_notification_attempts"

export DISPATCHER_DIR PENDING_FILE EXECUTOR_QUEUE_FILE LEDGER_FILE SEQ_FILE LOCK_FILE LOG_DIR
export EXECUTOR_BATCH_MIRROR_FILE EXECUTOR_BATCH_EVENT_LEDGER_FILE
export EXECUTOR_BATCH_OUTBOX_FILE
export EXECUTOR_BATCH_NOTIFICATIONS_FILE EXECUTOR_BATCH_NOTIFICATION_ATTEMPTS_DIR

# 幂等地确保 state 目录与初始文件存在。
ensure_state_dirs() {
  mkdir -p "${DISPATCHER_DIR}" "${LOG_DIR}"

  local state_init_lock_fd
  exec {state_init_lock_fd}>"${LOCK_FILE}"
  flock "${state_init_lock_fd}"
  mkdir -p "${EXECUTOR_BATCH_NOTIFICATION_ATTEMPTS_DIR}"
  [ -f "${PENDING_FILE}" ] || printf '%s\n' '{"pending":{}}' > "${PENDING_FILE}"
  [ -f "${EXECUTOR_QUEUE_FILE}" ] || printf '%s\n' '{"next_id":1,"active":null,"queue":[]}' > "${EXECUTOR_QUEUE_FILE}"
  [ -f "${LEDGER_FILE}" ] || : > "${LEDGER_FILE}"
  [ -f "${EXECUTOR_BATCH_MIRROR_FILE}" ] || printf '%s\n' '{"batches":{}}' > "${EXECUTOR_BATCH_MIRROR_FILE}"
  [ -f "${EXECUTOR_BATCH_OUTBOX_FILE}" ] || printf '%s\n' '{"version":1,"requests":[]}' > "${EXECUTOR_BATCH_OUTBOX_FILE}"
  [ -f "${EXECUTOR_BATCH_EVENT_LEDGER_FILE}" ] || : > "${EXECUTOR_BATCH_EVENT_LEDGER_FILE}"
  [ -f "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" ] || printf '%s\n' '{"notifications":[]}' > "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}"
  flock -u "${state_init_lock_fd}"
  exec {state_init_lock_fd}>&-
}
