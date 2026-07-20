#!/usr/bin/env bash
# Shared durable launch-action primitives. Callers must have sourced
# scheduler_env.sh so EXECUTOR_SCHEDULER_ROOT is fixed and validated.

set -euo pipefail

: "${EXECUTOR_SCHEDULER_ROOT:?_driven_launch_coordinator.sh: scheduler_env.sh must be sourced first}"

DLC_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_actions"
DLC_ARCHIVE_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_action_archive"
DLC_LOCK_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_action_locks"
DLC_LAYOUT_MIGRATION_LOCK="${DLC_LOCK_ROOT}/.layout-migration.lock"
mkdir -p "${DLC_ROOT}" "${DLC_ARCHIVE_ROOT}" "${DLC_LOCK_ROOT}"
chmod 700 "${DLC_ROOT}" "${DLC_ARCHIVE_ROOT}" "${DLC_LOCK_ROOT}" \
  || { echo "_driven_launch_coordinator.sh: launch state directories must be private" >&2; return 2 2>/dev/null || exit 2; }

# After the rolling compatibility window, quiesce both lock domains and retire
# only the old inode to a non-canonical history name. Never replace the new
# canonical path because another current process may already hold that inode.
if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" != true ]; then
  exec {DLC_LAYOUT_MIGRATION_LOCK_FD}>"${DLC_LAYOUT_MIGRATION_LOCK}"
  flock -x "${DLC_LAYOUT_MIGRATION_LOCK_FD}"
  shopt -s nullglob
  DLC_LEGACY_LOCKS=("${DLC_ROOT}"/.*.lock)
  for dlc_legacy_lock in "${DLC_LEGACY_LOCKS[@]}"; do
    dlc_legacy_name="$(basename "${dlc_legacy_lock}")"
    dlc_legacy_digest="${dlc_legacy_name#.}"
    dlc_legacy_digest="${dlc_legacy_digest%.lock}"
    dlc_canonical_lock="${DLC_LOCK_ROOT}/${dlc_legacy_digest}.lock"
    dlc_archived_lock="${DLC_LOCK_ROOT}/legacy-${dlc_legacy_digest}.lock"
    exec {DLC_LEGACY_MIGRATE_FD}>"${dlc_legacy_lock}"
    flock -x "${DLC_LEGACY_MIGRATE_FD}"
    exec {DLC_CANONICAL_MIGRATE_FD}>"${dlc_canonical_lock}"
    flock -x "${DLC_CANONICAL_MIGRATE_FD}"
    mv "${dlc_legacy_lock}" "${dlc_archived_lock}"
    flock -u "${DLC_CANONICAL_MIGRATE_FD}"
    exec {DLC_CANONICAL_MIGRATE_FD}>&-
    flock -u "${DLC_LEGACY_MIGRATE_FD}"
    exec {DLC_LEGACY_MIGRATE_FD}>&-
  done
  shopt -u nullglob
  flock -u "${DLC_LAYOUT_MIGRATION_LOCK_FD}"
  exec {DLC_LAYOUT_MIGRATION_LOCK_FD}>&-
fi

dlc_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "_driven_launch_coordinator.sh: no SHA-256 command is available" >&2
    return 2
  fi
}

# Build the cosmetic runtime label only after a scheduler claim generation is
# known. The readable prefix keeps IID/generation visible in the Sessions UI;
# the 160-bit SHA-256 prefix binds the full project, physical job, attempt and
# generation so same-IID work in different projects cannot collide. The fixed
# character set and 96-byte ceiling stay conservative for runtime transports.
dlc_runtime_child_label() {
  local project="$1" iid="$2" job_id="$3" generation="$4" attempt_number="$5"
  local identity digest label

  case "${iid}:${generation}:${attempt_number}" in
    *[!0-9:]*|:*|*::*|*:) return 2 ;;
  esac
  [ "${iid}" -gt 0 ] && [ "${generation}" -gt 0 ] \
    && [ "${attempt_number}" -gt 0 ] || return 2
  case "${project}${job_id}" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;;
  esac
  [ -n "${project}" ] && [ -n "${job_id}" ] || return 2

  identity="$(jq -cnS \
    --arg project "${project}" \
    --arg job_id "${job_id}" \
    --argjson iid "${iid}" \
    --argjson generation "${generation}" \
    --argjson attempt_number "${attempt_number}" '{
      version:1,
      project:$project,
      job_id:$job_id,
      iid:$iid,
      claim_generation:$generation,
      attempt_number:$attempt_number
    }')" || return 2
  digest="$(printf '%s' "${identity}" | dlc_sha256)" || return 2
  label="reqx-iid${iid}-gen${generation}-${digest:0:40}"
  [ "${#label}" -le 96 ] || return 2
  [[ "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
  printf '%s\n' "${label}"
}

dlc_open() {
  local job_id="$1"
  local digest lock_wait="${DLC_LOCK_WAIT_SECONDS:-}"
  local lock_deadline=0 lock_remaining=0
  if [ -n "${lock_wait}" ]; then
    case "${lock_wait}" in
      *[!0-9]*|'') return 2 ;;
    esac
    [ "${lock_wait}" -gt 0 ] || return 2
    lock_deadline=$((SECONDS + lock_wait))
  fi
  digest="$(printf '%s' "${job_id}" | dlc_sha256)" || return $?
  DLC_ACTION_FILE="${DLC_ROOT}/${digest}.json"
  DLC_ARCHIVE_FILE="${DLC_ARCHIVE_ROOT}/${digest}.json"
  DLC_ACTION_LOCK="${DLC_LOCK_ROOT}/${digest}.lock"
  unset DLC_LEGACY_ACTION_LOCK_FD
  if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ]; then
    DLC_LEGACY_ACTION_LOCK="${DLC_ROOT}/.${digest}.lock"
    exec {DLC_LEGACY_ACTION_LOCK_FD}>"${DLC_LEGACY_ACTION_LOCK}"
    if [ -n "${lock_wait}" ]; then
      lock_remaining=$((lock_deadline - SECONDS))
      [ "${lock_remaining}" -gt 0 ] \
        && flock -w "${lock_remaining}" -x \
          "${DLC_LEGACY_ACTION_LOCK_FD}" || {
        exec {DLC_LEGACY_ACTION_LOCK_FD}>&-
        unset DLC_LEGACY_ACTION_LOCK_FD
        return 75
      }
    else
      flock -x "${DLC_LEGACY_ACTION_LOCK_FD}"
    fi
  fi
  exec {DLC_ACTION_LOCK_FD}>"${DLC_ACTION_LOCK}"
  if [ -n "${lock_wait}" ]; then
    lock_remaining=$((lock_deadline - SECONDS))
    [ "${lock_remaining}" -gt 0 ] \
      && flock -w "${lock_remaining}" -x "${DLC_ACTION_LOCK_FD}" || {
      exec {DLC_ACTION_LOCK_FD}>&-
      unset DLC_ACTION_LOCK_FD
      if [ -n "${DLC_LEGACY_ACTION_LOCK_FD:-}" ]; then
        flock -u "${DLC_LEGACY_ACTION_LOCK_FD}" 2>/dev/null || true
        exec {DLC_LEGACY_ACTION_LOCK_FD}>&-
        unset DLC_LEGACY_ACTION_LOCK_FD
      fi
      return 75
    }
  else
    flock -x "${DLC_ACTION_LOCK_FD}"
  fi
  if [ ! -f "${DLC_ACTION_FILE}" ] && [ -f "${DLC_ARCHIVE_FILE}" ]; then
    mv "${DLC_ARCHIVE_FILE}" "${DLC_ACTION_FILE}"
  fi
  export DLC_ACTION_FILE DLC_ARCHIVE_FILE DLC_ACTION_LOCK DLC_ACTION_LOCK_FD
}

dlc_archive_completed() {
  [ -f "${DLC_ACTION_FILE}" ] || return 0
  jq -e '.stage == "completed"' "${DLC_ACTION_FILE}" >/dev/null \
    || return 2
  if [ -e "${DLC_ARCHIVE_FILE}" ]; then
    cmp -s "${DLC_ACTION_FILE}" "${DLC_ARCHIVE_FILE}" || return 3
  fi
  mv "${DLC_ACTION_FILE}" "${DLC_ARCHIVE_FILE}"
}

dlc_close() {
  if [ -n "${DLC_ACTION_LOCK_FD:-}" ]; then
    flock -u "${DLC_ACTION_LOCK_FD}" 2>/dev/null || true
    exec {DLC_ACTION_LOCK_FD}>&-
    unset DLC_ACTION_LOCK_FD
  fi
  if [ -n "${DLC_LEGACY_ACTION_LOCK_FD:-}" ]; then
    flock -u "${DLC_LEGACY_ACTION_LOCK_FD}" 2>/dev/null || true
    exec {DLC_LEGACY_ACTION_LOCK_FD}>&-
    unset DLC_LEGACY_ACTION_LOCK_FD
  fi
}

dlc_read() {
  if [ ! -f "${DLC_ACTION_FILE}" ]; then
    printf '%s\n' null
    return 0
  fi
  jq -ce '
    if type == "object"
      and .version == 1
      and (.job_id | type == "string" and length > 0)
      and (.project | type == "string" and length > 0)
      and (.iid | type == "number" and . == floor and . > 0)
      and (.attempt_number | type == "number" and . == floor and . > 0)
      and (.expected_task_sha256 | type == "string"
        and test("^[0-9a-f]{64}$"))
      and (.expected_task_bytes | type == "number"
        and . == floor and . > 0)
      and ((has("runtime_label_version") | not)
        or (.runtime_label_version == 1
          and (.child_label | type == "string" and length > 0
            and (explode | all(. >= 32 and . != 127)))
          and (.child_label | length) <= 96
          and (.child_label
            | test("^reqx-iid[1-9][0-9]*-gen[1-9][0-9]*-[0-9a-f]{40}$"))))
      and (.claim_generation | type == "number" and . == floor and . >= 0)
      and ((.claim_token == null) or (.claim_token | type == "string" and length > 0))
      and (.stage == "topup_prepared" or .stage == "preparing_claimed" or .stage == "bound"
        or .stage == "action_emitted" or .stage == "ack_received"
        or .stage == "project_recorded" or .stage == "scheduler_recorded"
        or .stage == "completed")
      and (if .stage == "topup_prepared"
        then .claim_generation == 0 and .claim_token == null
        else .claim_generation > 0 and (.claim_token | type == "string" and length > 0)
        end)
      and (.outcome == null or .outcome == "spawned" or .outcome == "launch_failed")
      and (.ack == null or (.ack | type == "object"))
      and (.created_at | type == "number" and . == floor and . >= 0)
      and (.updated_at | type == "number" and . == floor and . >= 0)
    then . else error("invalid durable launch action") end
  ' "${DLC_ACTION_FILE}"
}

dlc_write() {
  local json="$1"
  local candidate
  candidate="$(mktemp "${DLC_ROOT}/.$(basename "${DLC_ACTION_FILE}").XXXXXX")"
  ( umask 077; printf '%s\n' "${json}" >"${candidate}" )
  chmod 600 "${candidate}" 2>/dev/null || true
  jq -e . "${candidate}" >/dev/null || {
    echo "_driven_launch_coordinator.sh: refusing invalid launch action" >&2
    return 3
  }
  mv "${candidate}" "${DLC_ACTION_FILE}"
  chmod 600 "${DLC_ACTION_FILE}" 2>/dev/null || true
}
