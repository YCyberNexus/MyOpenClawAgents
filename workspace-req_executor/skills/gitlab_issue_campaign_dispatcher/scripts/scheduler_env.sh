#!/usr/bin/env bash
# Load and validate executor scheduler deployment settings, initialize the
# agent-wide state layout, export derived paths, and print compact config JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"

die() {
  echo "scheduler_env.sh: $1" >&2
  exit 2
}

scheduler_sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    die "no SHA-256 command is available"
  fi
}

scheduler_atomic_write_json() {
  local destination="$1" json="$2"
  local destination_dir destination_name candidate
  destination_dir="$(dirname "${destination}")"
  destination_name="$(basename "${destination}")"
  candidate="$(mktemp "${destination_dir}/.${destination_name}.XXXXXX")"
  ( umask 077; printf '%s\n' "${json}" >"${candidate}" )
  jq -e . "${candidate}" >/dev/null \
    || die "refusing to publish invalid JSON for ${destination_name}"
  mv "${candidate}" "${destination}"
  chmod 600 "${destination}" 2>/dev/null || true
}

scheduler_migrate_hot_launch_failed_receipts() {
  local scheduler_state hot_receipts receipt job_id receipt_digest

  scheduler_state="$(jq -c . "${SCHEDULER_STATE_FILE}")"
  [ "$(jq -r 'has("launch_failed_receipts")' <<<"${scheduler_state}")" = true ] \
    || return 0
  hot_receipts="$(jq -c '.launch_failed_receipts // {}' <<<"${scheduler_state}")"
  while IFS= read -r receipt; do
    [ -n "${receipt}" ] || continue
    job_id="$(jq -r '.job_id' <<<"${receipt}")"
    receipt_digest="$(printf '%s' "${job_id}" | scheduler_sha256_text)"
    scheduler_atomic_write_json \
      "${LAUNCH_FAILED_RECEIPTS_ROOT}/${receipt_digest}.json" \
      "$(jq -cS . <<<"${receipt}")"
  done < <(jq -c '.[]' <<<"${hot_receipts}")
  scheduler_state="$(jq -c 'del(.launch_failed_receipts)' <<<"${scheduler_state}")"
  scheduler_atomic_write_json "${SCHEDULER_STATE_FILE}" "${scheduler_state}"
}

scheduler_migrate_legacy_callback_locks() {
  local legacy_lock legacy_name legacy_event digest canonical_lock archived_lock
  local LEGACY_MIGRATE_FD CANONICAL_MIGRATE_FD

  shopt -s nullglob
  LEGACY_CALLBACK_LOCK_FILES=("${CALLBACK_OUTBOX}"/.*.lock)
  for legacy_lock in "${LEGACY_CALLBACK_LOCK_FILES[@]}"; do
    legacy_name="$(basename "${legacy_lock}")"
    legacy_event="${legacy_name#.}"
    legacy_event="${legacy_event%.lock}"
    digest="$(printf '%s' "${legacy_event}" | scheduler_sha256_text)"
    canonical_lock="${CALLBACK_LOCKS}/${digest}.lock"
    archived_lock="${CALLBACK_LOCKS}/legacy-${digest}.lock"

    # Never replace the canonical inode: another new process may already hold
    # it. Quiesce both old and new lock domains, then move only the retired old
    # inode to a non-canonical history path outside the hot JSON directory.
    exec {LEGACY_MIGRATE_FD}>"${legacy_lock}"
    flock -x "${LEGACY_MIGRATE_FD}"
    exec {CANONICAL_MIGRATE_FD}>"${canonical_lock}"
    flock -x "${CANONICAL_MIGRATE_FD}"
    mv "${legacy_lock}" "${archived_lock}"
    flock -u "${CANONICAL_MIGRATE_FD}"
    exec {CANONICAL_MIGRATE_FD}>&-
    flock -u "${LEGACY_MIGRATE_FD}"
    exec {LEGACY_MIGRATE_FD}>&-
  done
  shopt -u nullglob
}

unsafe_scheduler_root() {
  die "unsafe EXECUTOR_SCHEDULER_ROOT: $1"
}

normalize_allowed_root() {
  local root="$1"
  while [ "${root}" != "/" ] && [[ "${root}" == */ ]]; do
    root="${root%/}"
  done
  printf '%s' "${root}"
}

is_strict_child_of() {
  local path="$1"
  local parent="$2"
  [ -n "${parent}" ] && [ "${parent}" != "/" ] && [[ "${path}" == "${parent}/"* ]]
}

ROOT_ENV_SET="${EXECUTOR_SCHEDULER_ROOT+x}"
ROOT_ENV_VALUE="${EXECUTOR_SCHEDULER_ROOT:-}"
CONCURRENCY_ENV_SET="${EXECUTOR_MAX_CONCURRENCY+x}"
CONCURRENCY_ENV_VALUE="${EXECUTOR_MAX_CONCURRENCY:-}"
ACPX_TIMEOUT_ENV_SET="${EXECUTOR_ACPX_TIMEOUT_SECONDS+x}"
ACPX_TIMEOUT_ENV_VALUE="${EXECUTOR_ACPX_TIMEOUT_SECONDS:-}"
RUNNING_LEASE_ENV_SET="${EXECUTOR_RUNNING_LEASE_SECONDS+x}"
RUNNING_LEASE_ENV_VALUE="${EXECUTOR_RUNNING_LEASE_SECONDS:-}"
EXECUTOR_AGENT_ENV_SET="${EXECUTOR_AGENT+x}"
EXECUTOR_AGENT_ENV_VALUE="${EXECUTOR_AGENT:-}"
CALLBACK_TARGET_ENV_SET="${DISPATCHER_CALLBACK_TARGET+x}"
CALLBACK_TARGET_ENV_VALUE="${DISPATCHER_CALLBACK_TARGET:-}"
LOCK_COMPAT_ENV_SET="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS+x}"
LOCK_COMPAT_ENV_VALUE="${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS:-}"

DEFAULT_CONFIG="${CONFIG_DIR}/campaign_defaults.env"
LOCAL_CONFIG="${CONFIG_DIR}/campaign_defaults.local.env"
[ -f "${DEFAULT_CONFIG}" ] || die "missing deployment config: ${DEFAULT_CONFIG}"

EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler
EXECUTOR_MAX_CONCURRENCY=10
EXECUTOR_ACPX_TIMEOUT_SECONDS=3600
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=86400
# shellcheck disable=SC1090
source "${DEFAULT_CONFIG}"
if [ -f "${LOCAL_CONFIG}" ]; then
  # shellcheck disable=SC1090
  source "${LOCAL_CONFIG}"
fi

if [ "${ROOT_ENV_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${ROOT_ENV_VALUE}"
fi
if [ "${CONCURRENCY_ENV_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${CONCURRENCY_ENV_VALUE}"
fi
if [ "${ACPX_TIMEOUT_ENV_SET}" = x ]; then
  EXECUTOR_ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_ENV_VALUE}"
fi
if [ "${RUNNING_LEASE_ENV_SET}" = x ]; then
  EXECUTOR_RUNNING_LEASE_SECONDS="${RUNNING_LEASE_ENV_VALUE}"
fi
if [ "${EXECUTOR_AGENT_ENV_SET}" = x ]; then
  EXECUTOR_AGENT="${EXECUTOR_AGENT_ENV_VALUE}"
fi
if [ "${CALLBACK_TARGET_ENV_SET}" = x ]; then
  DISPATCHER_CALLBACK_TARGET="${CALLBACK_TARGET_ENV_VALUE}"
fi
if [ "${LOCK_COMPAT_ENV_SET}" = x ]; then
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS="${LOCK_COMPAT_ENV_VALUE}"
fi

case "${EXECUTOR_SCHEDULER_ROOT}" in
  *//*) unsafe_scheduler_root "must not contain double slashes" ;;
esac
while [ "${EXECUTOR_SCHEDULER_ROOT}" != "/" ] && [[ "${EXECUTOR_SCHEDULER_ROOT}" == */ ]]; do
  EXECUTOR_SCHEDULER_ROOT="${EXECUTOR_SCHEDULER_ROOT%/}"
done

case "${EXECUTOR_SCHEDULER_ROOT}" in
  /*) ;;
  *) unsafe_scheduler_root "must be an absolute path" ;;
esac
case "${EXECUTOR_SCHEDULER_ROOT}" in
  */./*|*/.|*/../*|*/..)
    unsafe_scheduler_root "must not contain current or parent path segments"
    ;;
esac
if [[ ! "${EXECUTOR_SCHEDULER_ROOT}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  unsafe_scheduler_root "contains whitespace, control, or unsupported characters"
fi

ALLOWED_HOME_ROOT="$(normalize_allowed_root "${HOME:-}")"
ALLOWED_TMP_ROOT="$(normalize_allowed_root "${TMPDIR:-/tmp}")"
if [[ "${EXECUTOR_SCHEDULER_ROOT}" == /data/* ]] \
  || is_strict_child_of "${EXECUTOR_SCHEDULER_ROOT}" "${ALLOWED_HOME_ROOT}" \
  || is_strict_child_of "${EXECUTOR_SCHEDULER_ROOT}" "${ALLOWED_TMP_ROOT}"
then
  :
else
  unsafe_scheduler_root "must be strictly nested under /data, HOME, or TMPDIR"
fi

case "${EXECUTOR_MAX_CONCURRENCY}" in
  ''|*[!0-9]*) die "EXECUTOR_MAX_CONCURRENCY must be a positive integer" ;;
esac
if [[ "${EXECUTOR_MAX_CONCURRENCY}" =~ ^0+$ ]]; then
  die "EXECUTOR_MAX_CONCURRENCY must be a positive integer"
fi
case "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*) die "EXECUTOR_ACPX_TIMEOUT_SECONDS must be an integer between 60 and 18000" ;;
esac
if [ "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" -lt 60 ] \
    || [ "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" -gt 18000 ]; then
  die "EXECUTOR_ACPX_TIMEOUT_SECONDS must be between 60 and 18000"
fi
case "${EXECUTOR_RUNNING_LEASE_SECONDS}" in
  ''|*[!0-9]*) die "EXECUTOR_RUNNING_LEASE_SECONDS must be a positive integer" ;;
esac
if [[ "${EXECUTOR_RUNNING_LEASE_SECONDS}" =~ ^0+$ ]]; then
  die "EXECUTOR_RUNNING_LEASE_SECONDS must be a positive integer"
fi
if ! [[ "${EXECUTOR_AGENT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  die "EXECUTOR_AGENT must be a safe agent identifier"
fi
if ! [[ "${DISPATCHER_CALLBACK_TARGET}" =~ ^agent:req_dispatcher:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
  die "DISPATCHER_CALLBACK_TARGET must pin agent:req_dispatcher:<safe-session>"
fi
case "${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS}" in
  ''|*[!0-9]*) die "DRIVEN_LEGACY_LOCK_COMPAT_SECONDS must be a non-negative integer" ;;
esac

SCHEDULER_STATE_FILE="${EXECUTOR_SCHEDULER_ROOT}/scheduler_state.json"
SCHEDULER_LOCK_FILE="${EXECUTOR_SCHEDULER_ROOT}/scheduler.lock"
BATCHES_ROOT="${EXECUTOR_SCHEDULER_ROOT}/batches"
CALLBACK_INBOX="${EXECUTOR_SCHEDULER_ROOT}/callback_inbox"
CALLBACK_OUTBOX="${EXECUTOR_SCHEDULER_ROOT}/callback_outbox"
CALLBACK_ARCHIVE="${EXECUTOR_SCHEDULER_ROOT}/callback_archive"
CALLBACK_LOCKS="${EXECUTOR_SCHEDULER_ROOT}/callback_locks"
LAUNCH_FAILED_RECEIPTS_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_failed_receipts"
LOCK_LAYOUT_V2_MARKER="${EXECUTOR_SCHEDULER_ROOT}/lock_layout_v2.json"

export EXECUTOR_SCHEDULER_ROOT EXECUTOR_MAX_CONCURRENCY
export EXECUTOR_ACPX_TIMEOUT_SECONDS
export EXECUTOR_RUNNING_LEASE_SECONDS
export EXECUTOR_AGENT DISPATCHER_CALLBACK_TARGET
export SCHEDULER_STATE_FILE SCHEDULER_LOCK_FILE BATCHES_ROOT CALLBACK_INBOX CALLBACK_OUTBOX CALLBACK_ARCHIVE CALLBACK_LOCKS
export LAUNCH_FAILED_RECEIPTS_ROOT
export DRIVEN_LEGACY_LOCK_COMPAT_SECONDS LOCK_LAYOUT_V2_MARKER

mkdir -p "${BATCHES_ROOT}" "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}" \
  "${CALLBACK_ARCHIVE}" "${CALLBACK_LOCKS}"
mkdir -p "${LAUNCH_FAILED_RECEIPTS_ROOT}"
chmod 700 "${EXECUTOR_SCHEDULER_ROOT}" "${BATCHES_ROOT}" \
  "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}" "${CALLBACK_ARCHIVE}" \
  "${CALLBACK_LOCKS}" \
  "${LAUNCH_FAILED_RECEIPTS_ROOT}" \
  || die "scheduler state directories must be private to the executor account"

exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"
LOCK_LAYOUT_WALL_NOW="$(date +%s)"
if [ ! -e "${LOCK_LAYOUT_V2_MARKER}" ]; then
  scheduler_atomic_write_json "${LOCK_LAYOUT_V2_MARKER}" \
    "$(jq -cnS --argjson started_at "${LOCK_LAYOUT_WALL_NOW}" \
      '{version:1,started_at:$started_at}')"
fi
LOCK_LAYOUT_STARTED_AT="$(jq -er '
  if type == "object" and .version == 1
    and (.started_at | type == "number" and . == floor and . >= 0)
  then .started_at else error("invalid lock layout marker") end
' "${LOCK_LAYOUT_V2_MARKER}")" \
  || die "lock layout marker is invalid: ${LOCK_LAYOUT_V2_MARKER}"
LEGACY_LOCK_COMPAT_ACTIVE=false
if [ "${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS}" -gt 0 ] \
    && [ "${LOCK_LAYOUT_WALL_NOW}" -lt \
      $((LOCK_LAYOUT_STARTED_AT + DRIVEN_LEGACY_LOCK_COMPAT_SECONDS)) ]; then
  LEGACY_LOCK_COMPAT_ACTIVE=true
fi
export LEGACY_LOCK_COMPAT_ACTIVE
if [ "${LEGACY_LOCK_COMPAT_ACTIVE}" != true ]; then
  scheduler_migrate_legacy_callback_locks
fi
if [ ! -e "${SCHEDULER_STATE_FILE}" ]; then
  INITIAL_STATE='{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[]}'
  STATE_TMP="$(mktemp "${EXECUTOR_SCHEDULER_ROOT}/.scheduler_state.json.XXXXXX")"
  printf '%s' "${INITIAL_STATE}" >"${STATE_TMP}"
  mv "${STATE_TMP}" "${SCHEDULER_STATE_FILE}"
elif ! jq -e '
  def valid_launch_failed_receipts:
    (has("launch_failed_receipts") | not)
    or (.launch_failed_receipts | type == "object"
      and (to_entries | all(. as $entry |
        ($entry.value | type == "object")
        and ($entry.value | keys | sort) == [
          "action","claim_generation","claim_token_sha256",
          "job_id","recorded_at","version"
        ]
        and $entry.value.version == 1
        and $entry.value.job_id == $entry.key
        and ($entry.value.job_id | type == "string" and length > 0)
        and ($entry.value.claim_generation | type == "number"
          and . == floor and . > 0)
        and ($entry.value.claim_token_sha256 | type == "string"
          and test("^[0-9a-f]{64}$"))
        and $entry.value.action == "launch_failed"
        and ($entry.value.recorded_at | type == "number"
          and . == floor and . >= 0))));
  type == "object"
  and .version == 1
  and ((has("max_concurrency") | not)
    or (.max_concurrency | type == "number" and . == floor and . > 0))
  and ((has("acpx_timeout_seconds") | not)
    or (.acpx_timeout_seconds | type == "number" and . == floor
      and . >= 60 and . <= 18000))
  and ((.round_robin_cursor == null) or (.round_robin_cursor | type == "string"))
  and (.active_jobs | type == "object")
  and (.batch_order | type == "array")
  and valid_launch_failed_receipts
' "${SCHEDULER_STATE_FILE}" >/dev/null; then
  die "existing scheduler state is invalid: ${SCHEDULER_STATE_FILE}"
fi
scheduler_migrate_hot_launch_failed_receipts
RUNTIME_MAX_CONCURRENCY="$(jq -r '.max_concurrency // empty' "${SCHEDULER_STATE_FILE}")"
if [ -n "${RUNTIME_MAX_CONCURRENCY}" ]; then
  EXECUTOR_MAX_CONCURRENCY="${RUNTIME_MAX_CONCURRENCY}"
  export EXECUTOR_MAX_CONCURRENCY
fi
RUNTIME_ACPX_TIMEOUT_SECONDS="$(jq -r '.acpx_timeout_seconds // empty' "${SCHEDULER_STATE_FILE}")"
if [ -n "${RUNTIME_ACPX_TIMEOUT_SECONDS}" ]; then
  EXECUTOR_ACPX_TIMEOUT_SECONDS="${RUNTIME_ACPX_TIMEOUT_SECONDS}"
  export EXECUTOR_ACPX_TIMEOUT_SECONDS
fi
flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-

jq -cn \
  --arg scheduler_root "${EXECUTOR_SCHEDULER_ROOT}" \
  --arg max_concurrency "${EXECUTOR_MAX_CONCURRENCY}" \
  --arg acpx_timeout_seconds "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" \
  --arg running_lease_seconds "${EXECUTOR_RUNNING_LEASE_SECONDS}" \
  --arg scheduler_state_file "${SCHEDULER_STATE_FILE}" \
  --arg scheduler_lock_file "${SCHEDULER_LOCK_FILE}" \
  --arg batches_root "${BATCHES_ROOT}" \
  --arg callback_inbox "${CALLBACK_INBOX}" \
  --arg callback_outbox "${CALLBACK_OUTBOX}" \
  --arg callback_archive "${CALLBACK_ARCHIVE}" \
  --arg callback_locks "${CALLBACK_LOCKS}" \
  --arg launch_failed_receipts "${LAUNCH_FAILED_RECEIPTS_ROOT}" \
  --arg executor_agent "${EXECUTOR_AGENT}" \
  --arg dispatcher_callback_target "${DISPATCHER_CALLBACK_TARGET}" \
  '{
    scheduler_root: $scheduler_root,
    max_concurrency: ($max_concurrency | tonumber),
    acpx_timeout_seconds: ($acpx_timeout_seconds | tonumber),
    running_lease_seconds: ($running_lease_seconds | tonumber),
    scheduler_state_file: $scheduler_state_file,
    scheduler_lock_file: $scheduler_lock_file,
    batches_root: $batches_root,
    callback_inbox: $callback_inbox,
    callback_outbox: $callback_outbox,
    callback_archive: $callback_archive,
    callback_locks: $callback_locks,
    launch_failed_receipts: $launch_failed_receipts,
    executor_agent: $executor_agent,
    dispatcher_callback_target: $dispatcher_callback_target
  }'
