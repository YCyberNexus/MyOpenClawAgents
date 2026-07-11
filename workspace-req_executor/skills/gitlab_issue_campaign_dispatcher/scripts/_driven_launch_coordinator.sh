#!/usr/bin/env bash
# Shared durable launch-action primitives. Callers must have sourced
# scheduler_env.sh so EXECUTOR_SCHEDULER_ROOT is fixed and validated.

set -euo pipefail

: "${EXECUTOR_SCHEDULER_ROOT:?_driven_launch_coordinator.sh: scheduler_env.sh must be sourced first}"

DLC_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_actions"
mkdir -p "${DLC_ROOT}"

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
  local digest
  digest="$(printf '%s' "${job_id}" | dlc_sha256)" || return $?
  DLC_ACTION_FILE="${DLC_ROOT}/${digest}.json"
  DLC_ACTION_LOCK="${DLC_ROOT}/.${digest}.lock"
  exec {DLC_ACTION_LOCK_FD}>"${DLC_ACTION_LOCK}"
  flock -x "${DLC_ACTION_LOCK_FD}"
  export DLC_ACTION_FILE DLC_ACTION_LOCK DLC_ACTION_LOCK_FD
}

dlc_close() {
  if [ -n "${DLC_ACTION_LOCK_FD:-}" ]; then
    flock -u "${DLC_ACTION_LOCK_FD}" 2>/dev/null || true
    exec {DLC_ACTION_LOCK_FD}>&-
    unset DLC_ACTION_LOCK_FD
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
