#!/usr/bin/env bash
# load_ui_accounts.sh — read the deployment-pinned UI test account pool
# (<workspace>/config/ui_accounts.env) and print accounts to stdout, one
# per line in "user:pass" form, in file order.
#
# The dispatcher uses this to allocate distinct test accounts per IID in
# a concurrent batch. Each subagent receives ACCOUNTS_PER_ISSUE accounts
# (one per robot test file). The system under test logs out an account when
# the same credentials log in twice, so two concurrent subagents — and two
# concurrent robot executions within a subagent — MUST NOT share an account.
#
# Optional env vars:
#   BATCH_SIZE           integer >= 1. Number of IIDs in this batch.
#   ACCOUNTS_PER_ISSUE   integer >= 1, defaults to 1 (backward compat).
#                         Number of accounts allocated per IID.
#
#   When both are set: TOTAL_NEEDED = BATCH_SIZE * ACCOUNTS_PER_ISSUE.
#   The script asserts pool_size >= TOTAL_NEEDED (else exits 13) and
#   prints the first TOTAL_NEEDED entries.
#
# Output (stdout):
#   <user1>:<pass1>
#   <user2>:<pass2>
#   ...
#
# Exit codes:
#   0   success
#   10  pin file missing (deployment incomplete)
#   11  pool is empty (no valid lines)
#   12  pool contains a malformed line (no ':' separator)
#   13  pool size < BATCH_SIZE * ACCOUNTS_PER_ISSUE
#   14  ACCOUNTS_PER_ISSUE is set but not a positive integer
#   15  BATCH_SIZE is set but not a positive integer
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

if [ -n "${BATCH_SIZE:-}" ]; then
  if ! [[ "${BATCH_SIZE}" =~ ^[0-9]+$ ]] || [ "${BATCH_SIZE}" -lt 1 ]; then
    echo "load_ui_accounts: BATCH_SIZE must be a positive integer, got '${BATCH_SIZE}'" >&2
    exit 15
  fi

  # ACCOUNTS_PER_ISSUE defaults to 1 for backward compatibility
  if [ -n "${ACCOUNTS_PER_ISSUE:-}" ]; then
    if ! [[ "${ACCOUNTS_PER_ISSUE}" =~ ^[0-9]+$ ]] || [ "${ACCOUNTS_PER_ISSUE}" -lt 1 ]; then
      echo "load_ui_accounts: ACCOUNTS_PER_ISSUE must be a positive integer, got '${ACCOUNTS_PER_ISSUE}'" >&2
      exit 14
    fi
  else
    ACCOUNTS_PER_ISSUE=1
  fi

  TOTAL_NEEDED=$((BATCH_SIZE * ACCOUNTS_PER_ISSUE))
  if [ "${POOL_SIZE}" -lt "${TOTAL_NEEDED}" ]; then
    echo "load_ui_accounts: pool size ${POOL_SIZE} < BATCH_SIZE ${BATCH_SIZE} * ACCOUNTS_PER_ISSUE ${ACCOUNTS_PER_ISSUE} = ${TOTAL_NEEDED}; cannot satisfy concurrent batch without sharing accounts" >&2
    exit 13
  fi
  for ((i = 0; i < TOTAL_NEEDED; i++)); do
    printf '%s\n' "${ACCOUNTS[$i]}"
  done
else
  for entry in "${ACCOUNTS[@]}"; do
    printf '%s\n' "${entry}"
  done
fi
