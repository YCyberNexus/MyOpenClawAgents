#!/usr/bin/env bash
# load_ui_accounts.sh — read the deployment-pinned UI test account pool
# (<workspace>/config/ui_accounts.env) and print accounts to stdout, one
# per line in "user:pass" form, in file order.
#
# The dispatcher uses this to allocate a distinct test account per IID in
# a concurrent batch. The system under test logs out an account when the
# same credentials log in twice, so two concurrent subagents MUST NOT
# share an account.
#
# Optional env vars:
#   BATCH_SIZE   integer >= 1. If set, the script:
#                  - asserts pool_size >= BATCH_SIZE (else exits 13)
#                  - prints only the first BATCH_SIZE entries
#                If unset, the entire pool is printed.
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
#   13  pool size < BATCH_SIZE
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
    exit 12
  fi
  if [ "${POOL_SIZE}" -lt "${BATCH_SIZE}" ]; then
    echo "load_ui_accounts: pool size ${POOL_SIZE} < BATCH_SIZE ${BATCH_SIZE}; cannot satisfy concurrent batch without sharing accounts" >&2
    exit 13
  fi
  for ((i = 0; i < BATCH_SIZE; i++)); do
    printf '%s\n' "${ACCOUNTS[$i]}"
  done
else
  for entry in "${ACCOUNTS[@]}"; do
    printf '%s\n' "${entry}"
  done
fi
