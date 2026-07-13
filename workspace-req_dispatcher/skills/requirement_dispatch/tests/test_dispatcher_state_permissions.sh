#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-permissions.XXXXXX")"
STATE_DIR="${TEST_ROOT}/_dispatcher"

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

umask 000
mkdir -p "${STATE_DIR}/log/old-dir" \
  "${STATE_DIR}/executor_batch_notification_attempts/old-event"
printf '%s\n' '{"pending":{}}' >"${STATE_DIR}/pending.json"
printf '%s\n' '{"next_id":1,"active":null,"queue":[]}' >"${STATE_DIR}/executor_queue.json"
printf '%s\n' old >"${STATE_DIR}/log/old-dir/existing.log"
printf '%s\n' lock >"${STATE_DIR}/executor_batch_notification.old.lock"
chmod 777 "${STATE_DIR}" "${STATE_DIR}/log" "${STATE_DIR}/log/old-dir" \
  "${STATE_DIR}/executor_batch_notification_attempts" \
  "${STATE_DIR}/executor_batch_notification_attempts/old-event"
chmod 666 "${STATE_DIR}/pending.json" "${STATE_DIR}/executor_queue.json" \
  "${STATE_DIR}/log/old-dir/existing.log" \
  "${STATE_DIR}/executor_batch_notification.old.lock"

STATE_ROOT="${TEST_ROOT}" "${BASH}" -c '
  set -euo pipefail
  source "$1"
  ensure_state_dirs
  mkdir -p "${DISPATCHER_DIR}/created-after-source"
  : >"${LOG_DIR}/created-after-source.log"
' _ "${SKILL_DIR}/scripts/env_paths.sh"

while IFS= read -r directory; do
  if [ "$(mode_of "${directory}")" != 700 ]; then
    echo "dispatcher state directory is not mode 0700: ${directory}" >&2
    exit 1
  fi
done < <(find "${STATE_DIR}" -type d -print)

while IFS= read -r file; do
  if [ "$(mode_of "${file}")" != 600 ]; then
    echo "dispatcher state file is not mode 0600: ${file}" >&2
    exit 1
  fi
done < <(find "${STATE_DIR}" -type f -print)

echo "ok dispatcher state permissions are private and migrated"
