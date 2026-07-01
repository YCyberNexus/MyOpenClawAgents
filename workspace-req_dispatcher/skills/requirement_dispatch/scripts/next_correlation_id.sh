#!/usr/bin/env bash
# Generate the next req_dispatcher correlation id under the dispatcher flock.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

exec 9>"${LOCK_FILE}"
flock 9

current_raw=""
if [ -f "${SEQ_FILE}" ]; then
  current_raw="$(tr -d '[:space:]' < "${SEQ_FILE}")"
fi

if [ -z "${current_raw}" ]; then
  current=0
else
  case "${current_raw}" in
    *[!0-9]*)
      echo "next_correlation_id: ${SEQ_FILE} must contain a non-negative integer, got: ${current_raw}" >&2
      exit 1
      ;;
    *)
      current=$((10#${current_raw}))
      ;;
  esac
fi

next=$((current + 1))
printf '%s\n' "${next}" > "${SEQ_FILE}"
flock -u 9

printf 'reqd-%s\n' "${next}"
