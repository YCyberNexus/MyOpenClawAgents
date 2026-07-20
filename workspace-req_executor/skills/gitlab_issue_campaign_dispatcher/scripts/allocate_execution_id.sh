#!/usr/bin/env bash
# Generate one opaque execution identity for a per-IID launch.
#
# This identity is deliberately random rather than sequential. It fences files,
# callbacks, and recovery actions without recording how many times an Issue has
# run. The value stays below 2^48 so jq 1.5 can represent it exactly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

: "${IID:?allocate_execution_id.sh: IID must be set}"
case "${IID}" in
  ''|*[!0-9]*)
    echo "allocate_execution_id.sh: IID must be a positive integer" >&2
    exit 2
    ;;
esac
[ "${IID}" -gt 0 ] || {
  echo "allocate_execution_id.sh: IID must be a positive integer" >&2
  exit 2
}

generate_execution_id() {
  local hex value
  hex="$(od -An -N6 -tx1 /dev/urandom | tr -d '[:space:]')"
  case "${hex}" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  value="$((16#${hex}))"
  [ "${value}" -gt 0 ] || return 1
  [ ! -e "${ISSUES_ROOT}/issue-${IID}/executions/execution-${value}.json" ] \
    || return 1
  printf '%s\n' "${value}"
}

for _ in 1 2 3; do
  if generate_execution_id; then
    exit 0
  fi
done

echo "allocate_execution_id.sh: unable to generate an execution identity" >&2
exit 2
