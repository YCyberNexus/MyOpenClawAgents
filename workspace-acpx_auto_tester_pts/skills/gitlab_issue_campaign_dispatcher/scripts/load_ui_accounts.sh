#!/usr/bin/env bash
# load_ui_accounts.sh — read the deployment-pinned UI test account pool
# (<workspace>/config/ui_accounts.env) and print accounts to stdout, one
# per line in "user:pass" form, in file order.
#
# The dispatcher uses this to allocate distinct test accounts per IID in
# a concurrent batch. The system under test logs out an account when the
# same credentials log in twice, so two concurrent subagents — and two
# concurrent robot executions within a subagent — MUST NOT share an
# account. The pool is therefore divided into per-subagent slots whose
# size is computed automatically from the pool size and
# MAX_CONCURRENT_SUBAGENTS (the configured concurrency cap, NOT the
# actual batch size — slot sizes stay stable across batches that may
# pick fewer IIDs than the cap).
#
# Optional env vars:
#   MAX_CONCURRENT_SUBAGENTS   integer ≥ 1, ≤ pool_size. Required for
#                              batch allocation (info-only mode runs
#                              when omitted: just dumps the pool).
#
# When MAX_CONCURRENT_SUBAGENTS is set:
#   - The script validates 1 ≤ MAX_CONCURRENT_SUBAGENTS ≤ pool_size.
#   - It computes per-slot sizes by dividing pool_size by
#     MAX_CONCURRENT_SUBAGENTS. The integer remainder is front-loaded
#     onto the first slots so every account is reachable. Examples:
#       pool=3,  max=2 → SLOT_SIZES=2,1
#       pool=50, max=4 → SLOT_SIZES=13,13,12,12
#       pool=14, max=1 → SLOT_SIZES=14
#   - It prints `POOL_SIZE=<n>` and `SLOT_SIZES=<csv>` to stderr; the
#     orchestrator captures these to slice stdout into per-IID blocks.
#   - The csv length equals MAX_CONCURRENT_SUBAGENTS. The k-th IID of
#     the batch (0-indexed) takes SLOT_SIZES[k] accounts starting at
#     offset SUM(SLOT_SIZES[0..k-1]) in the stdout pool listing.
#
# Output (stdout):
#   <user1>:<pass1>
#   <user2>:<pass2>
#   ...                   (pool_size lines, in file order)
#
# Output (stderr, info only — captured by the orchestrator when
# MAX_CONCURRENT_SUBAGENTS is set):
#   POOL_SIZE=<n>
#   SLOT_SIZES=<count_0>,<count_1>,...,<count_{MAX_CONCURRENT_SUBAGENTS-1}>
#
# Exit codes:
#   0   success
#   10  pin file missing (deployment incomplete)
#   11  pool is empty (no valid lines)
#   12  pool contains a malformed line (no ':' separator)
#   13  MAX_CONCURRENT_SUBAGENTS > pool_size (each in-flight subagent
#       MUST hold at least one distinct UI account; cannot satisfy)
#   14  MAX_CONCURRENT_SUBAGENTS is set but not a positive integer
#
# On failure: the dispatcher MUST abort the tick (No-Fallback Policy —
# never improvise an account; never share an account between subagents).

set -euo pipefail

# Resolve workspace root from this script's location:
#   <workspace>/skills/<name>/scripts/load_ui_accounts.sh -> ../../..
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
POOL_FILE="${WORKSPACE_ROOT}/config/ui_accounts.env"

if [ ! -f "${POOL_FILE}" ]; then
  echo "load_ui_accounts: missing pool file ${POOL_FILE}; deployment incomplete" >&2
  exit 10
fi

# Parse: strip blank lines, comment lines, and surrounding whitespace.
# Validate each remaining line contains exactly one ':' separator with
# non-empty user and pass.
ACCOUNTS=()
LINE_NO=0
while IFS= read -r RAW || [ -n "${RAW}" ]; do
  LINE_NO=$((LINE_NO + 1))
  TRIMMED="$(echo "${RAW}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "${TRIMMED}" in
    ''|\#*) continue ;;
  esac
  USER_PART="${TRIMMED%%:*}"
  PASS_PART="${TRIMMED#*:}"
  if [ "${USER_PART}" = "${TRIMMED}" ] || [ -z "${USER_PART}" ] || [ -z "${PASS_PART}" ]; then
    echo "load_ui_accounts: ${POOL_FILE}:${LINE_NO}: malformed entry '${TRIMMED}' (expected 'user:pass')" >&2
    exit 12
  fi
  ACCOUNTS+=("${USER_PART}:${PASS_PART}")
done < "${POOL_FILE}"

POOL_SIZE="${#ACCOUNTS[@]}"
if [ "${POOL_SIZE}" -eq 0 ]; then
  echo "load_ui_accounts: ${POOL_FILE} contains no valid entries" >&2
  exit 11
fi

if [ -n "${MAX_CONCURRENT_SUBAGENTS:-}" ]; then
  if ! [[ "${MAX_CONCURRENT_SUBAGENTS}" =~ ^[0-9]+$ ]] || [ "${MAX_CONCURRENT_SUBAGENTS}" -lt 1 ]; then
    echo "load_ui_accounts: MAX_CONCURRENT_SUBAGENTS must be a positive integer, got '${MAX_CONCURRENT_SUBAGENTS}'" >&2
    exit 14
  fi
  if [ "${MAX_CONCURRENT_SUBAGENTS}" -gt "${POOL_SIZE}" ]; then
    echo "load_ui_accounts: MAX_CONCURRENT_SUBAGENTS ${MAX_CONCURRENT_SUBAGENTS} > pool size ${POOL_SIZE}; cannot give every concurrent subagent at least one distinct account" >&2
    exit 13
  fi

  BASE=$((POOL_SIZE / MAX_CONCURRENT_SUBAGENTS))
  REM=$((POOL_SIZE % MAX_CONCURRENT_SUBAGENTS))
  SLOT_SIZES=""
  for ((k = 0; k < MAX_CONCURRENT_SUBAGENTS; k++)); do
    if [ "${k}" -lt "${REM}" ]; then
      SIZE=$((BASE + 1))
    else
      SIZE="${BASE}"
    fi
    if [ -z "${SLOT_SIZES}" ]; then
      SLOT_SIZES="${SIZE}"
    else
      SLOT_SIZES="${SLOT_SIZES},${SIZE}"
    fi
  done
  echo "POOL_SIZE=${POOL_SIZE}" >&2
  echo "SLOT_SIZES=${SLOT_SIZES}" >&2
fi

for entry in "${ACCOUNTS[@]}"; do
  printf '%s\n' "${entry}"
done
