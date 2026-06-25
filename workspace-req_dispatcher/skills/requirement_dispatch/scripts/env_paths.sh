#!/usr/bin/env bash
# 路径自举：每个脚本顶部 `source` 本文件。
# 要求 STATE_ROOT 在 env（config/dispatcher.env 提供，或调用方在同一行导出）。
set -euo pipefail

: "${STATE_ROOT:?STATE_ROOT is required (set in config/dispatcher.env or export before call)}"

DISPATCHER_DIR="${STATE_ROOT}/_dispatcher"
PENDING_FILE="${DISPATCHER_DIR}/pending.json"
LEDGER_FILE="${DISPATCHER_DIR}/ledger.jsonl"
SEQ_FILE="${DISPATCHER_DIR}/seq"
LOCK_FILE="${DISPATCHER_DIR}/pending.lock"
LOG_DIR="${DISPATCHER_DIR}/log"

export DISPATCHER_DIR PENDING_FILE LEDGER_FILE SEQ_FILE LOCK_FILE LOG_DIR

# 幂等地确保 state 目录与初始文件存在。
ensure_state_dirs() {
  mkdir -p "${DISPATCHER_DIR}" "${LOG_DIR}"
  [ -f "${PENDING_FILE}" ] || printf '%s\n' '{"pending":{}}' > "${PENDING_FILE}"
  [ -f "${LEDGER_FILE}" ] || : > "${LEDGER_FILE}"
}
