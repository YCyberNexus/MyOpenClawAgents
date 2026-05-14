#!/usr/bin/env bash
# load_ui_accounts.sh — read the deployment-pinned UI test account from
# (<workspace>/config/ui_accounts.env) and print it to stdout.
#
# All concurrent subagents share the same account. The test team has
# confirmed the system under test does NOT log out the older session on
# duplicate login, so a single account is sufficient.
#
# Only the first valid entry in the pool file is used.
#
# Optional env vars:
#   (none — BATCH_SIZE, ACCOUNTS_PER_ISSUE are no longer used)
#
# Output (stdout):
#   <user>:<pass>
#
# Exit codes:
#   0   success
#   10  pin file missing (deployment incomplete)
#   11  pool is empty (no valid lines)
#   12  pool contains a malformed line (no ':' separator)

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

# Parse the first valid entry: strip blank lines, comment lines, and
# surrounding whitespace. Use only the first valid entry.
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
  printf '%s\n' "${USER_PART}:${PASS_PART}"
  exit 0
done < "${POOL_FILE}"

# No valid entry found
echo "load_ui_accounts: ${POOL_FILE} contains no valid entries" >&2
exit 11
