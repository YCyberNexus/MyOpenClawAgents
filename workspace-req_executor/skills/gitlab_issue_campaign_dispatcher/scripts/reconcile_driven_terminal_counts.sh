#!/usr/bin/env bash
# Backfill terminal outcome classifications for batches created before
# membership.terminal_status existed, then recompute all aggregate counters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
BATCH_IDS_INPUT="${BATCH_IDS_JSON:-}"
RECONCILED_AT="${NOW_EPOCH:-$(date +%s)}"
PREPARING_LEASE_SECONDS="${DRIVEN_PREPARING_LEASE_SECONDS:-1800}"
MIGRATION_SCRIPT="${DRIVEN_MIGRATION_SCRIPT:-${SCRIPT_DIR}/reserve_driven_batch_items.sh}"
FULL_AUDIT_SECONDS="${DRIVEN_TERMINAL_COUNT_FULL_AUDIT_SECONDS:-86400}"
TERMINAL_COUNT_COMPAT_SECONDS="${DRIVEN_TERMINAL_COUNT_COMPAT_SECONDS:-86400}"
RECONCILE_RETRY_LIMIT=3
CLASSIFY_CHUNK_SIZE=64

reconcile_die() {
  echo "reconcile_driven_terminal_counts.sh: $*" >&2
  exit "${2:-2}"
}

atomic_write_json() {
  local destination="$1" json="$2" destination_dir destination_name candidate
  destination_dir="$(dirname "${destination}")"
  destination_name="$(basename "${destination}")"
  candidate="$(mktemp "${destination_dir}/.${destination_name}.XXXXXX")"
  ( umask 077; printf '%s\n' "${json}" >"${candidate}" )
  jq -e . "${candidate}" >/dev/null \
    || reconcile_die "refusing to publish invalid JSON for ${destination_name}" 3
  chmod 600 "${candidate}" 2>/dev/null \
    || reconcile_die "reconciled state must be private" 3
  mv "${candidate}" "${destination}"
}

emit_result() {
  local status="$1" scanned="$2" repaired="$3" unresolved="$4"
  jq -cn \
    --arg status "${status}" \
    --argjson scanned "${scanned}" \
    --argjson repaired "${repaired}" \
    --argjson unresolved "${unresolved}" '{
      status:$status,
      scanned:$scanned,
      repaired:$repaired,
      unresolved:$unresolved
    }'
}

scheduler_state_identity() {
  local identity
  if identity="$(stat -c '%d:%i:%s:%Y' "${SCHEDULER_STATE_FILE}" 2>/dev/null)" \
      && [[ "${identity}" =~ ^[0-9]+:[0-9]+:[0-9]+:-?[0-9]+$ ]]; then
    printf '%s\n' "${identity}"
  elif identity="$(stat -f '%d:%i:%z:%m' "${SCHEDULER_STATE_FILE}" 2>/dev/null)" \
      && [[ "${identity}" =~ ^[0-9]+:[0-9]+:[0-9]+:-?[0-9]+$ ]]; then
    printf '%s\n' "${identity}"
  else
    reconcile_die "cannot stat scheduler state" 3
  fi
}

acquire_callback_event_locks() {
  local event_id="$1" lock_digest
  unset CALLBACK_EVENT_LEGACY_LOCK_FD CALLBACK_EVENT_LOCK_FD
  if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ]; then
    exec {CALLBACK_EVENT_LEGACY_LOCK_FD}>"${CALLBACK_OUTBOX}/.${event_id}.lock"
    flock -x "${CALLBACK_EVENT_LEGACY_LOCK_FD}"
  fi
  lock_digest="$(printf '%s' "${event_id}" | scheduler_sha256_text)"
  exec {CALLBACK_EVENT_LOCK_FD}>"${CALLBACK_LOCKS}/${lock_digest}.lock"
  flock -x "${CALLBACK_EVENT_LOCK_FD}"
}

release_callback_event_locks() {
  flock -u "${CALLBACK_EVENT_LOCK_FD}" 2>/dev/null || true
  exec {CALLBACK_EVENT_LOCK_FD}>&-
  unset CALLBACK_EVENT_LOCK_FD
  if [ -n "${CALLBACK_EVENT_LEGACY_LOCK_FD:-}" ]; then
    flock -u "${CALLBACK_EVENT_LEGACY_LOCK_FD}" 2>/dev/null || true
    exec {CALLBACK_EVENT_LEGACY_LOCK_FD}>&-
    unset CALLBACK_EVENT_LEGACY_LOCK_FD
  fi
}

run_scheduler_migration() {
  CONFIG_DIR="${CONFIG_DIR}" \
  NOW_EPOCH="${RECONCILED_AT}" \
  DRIVEN_PREPARING_LEASE_SECONDS="${PREPARING_LEASE_SECONDS}" \
  DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
  bash "${MIGRATION_SCRIPT}" >/dev/null \
    || reconcile_die "scheduler migration-only recovery failed" 3
}

case "${RECONCILED_AT}" in
  ''|*[!0-9]*) reconcile_die "NOW_EPOCH must be a non-negative integer" ;;
esac
case "${PREPARING_LEASE_SECONDS}" in
  ''|*[!0-9]*) reconcile_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer" ;;
esac
[[ "${PREPARING_LEASE_SECONDS}" =~ ^0+$ ]] \
  && reconcile_die "DRIVEN_PREPARING_LEASE_SECONDS must be a positive integer"
case "${FULL_AUDIT_SECONDS}" in
  ''|*[!0-9]*) reconcile_die "DRIVEN_TERMINAL_COUNT_FULL_AUDIT_SECONDS must be a positive integer" ;;
esac
[[ "${FULL_AUDIT_SECONDS}" =~ ^0+$ ]] \
  && reconcile_die "DRIVEN_TERMINAL_COUNT_FULL_AUDIT_SECONDS must be a positive integer"
case "${TERMINAL_COUNT_COMPAT_SECONDS}" in
  ''|*[!0-9]*) reconcile_die "DRIVEN_TERMINAL_COUNT_COMPAT_SECONDS must be a non-negative integer" ;;
esac
case "${MIGRATION_SCRIPT}" in
  /*) ;;
  *) reconcile_die "DRIVEN_MIGRATION_SCRIPT must be an absolute path" ;;
esac
case "${MIGRATION_SCRIPT}" in
  *$'\n'*|*$'\r'*|*$'\t'*) reconcile_die "DRIVEN_MIGRATION_SCRIPT contains control characters" ;;
esac
[ -f "${MIGRATION_SCRIPT}" ] && [ -x "${MIGRATION_SCRIPT}" ] \
  || reconcile_die "DRIVEN_MIGRATION_SCRIPT must be an executable regular file"

if [ -n "${BATCH_IDS_INPUT}" ]; then
  BATCH_IDS="$(jq -ce '
    if type == "array"
      and all(type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and length == (unique | length)
    then sort
    else error("invalid batch scope")
    end
  ' <<<"${BATCH_IDS_INPUT}" 2>/dev/null)" \
    || reconcile_die "BATCH_IDS_JSON must be a unique array of safe batch ids"
  SCOPED_RUN=true
else
  BATCH_IDS=null
  SCOPED_RUN=false
fi

# scheduler_env initializes all paths and migrates legacy callback lock files.
# It releases its initialization lock before any evidence lock is acquired.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null
MIGRATION_MARKER="${EXECUTOR_SCHEDULER_ROOT}/terminal-count-reconcile-v1.json"

ATTEMPT=0
while [ "${ATTEMPT}" -lt "${RECONCILE_RETRY_LIMIT}" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  SCHEDULER_IDENTITY="$(scheduler_state_identity)"

  MARKER_PRESENT=false
  MARKER_DIGEST=absent
  MARKER_PENDING_BATCH_IDS='[]'
  MARKER_LAST_FULL_SCAN_AT=null
  MARKER_ROLLING_SCAN_UNTIL=null
  if [ "${SCOPED_RUN}" = false ] && [ -e "${MIGRATION_MARKER}" ]; then
    [ -f "${MIGRATION_MARKER}" ] && [ ! -L "${MIGRATION_MARKER}" ] \
      || reconcile_die "terminal count reconciliation marker is unsafe" 3
    marker_raw="$(<"${MIGRATION_MARKER}")"
    marker_json="$(jq -ce '
      if type == "object"
        and .version == 1
        and (.status == "complete" or .status == "partial")
        and (.pending_batch_ids | type == "array")
        and (.pending_batch_ids | all(type == "string"
          and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
        and ((.pending_batch_ids | length)
          == (.pending_batch_ids | unique | length))
        and (.updated_at | type == "number" and . == floor and . >= 0)
        and ((has("last_full_scan_at") | not)
          or (.last_full_scan_at | type == "number" and . == floor and . >= 0))
        and ((has("rolling_scan_until") | not)
          or (.rolling_scan_until | type == "number" and . == floor and . >= 0))
        and (if .status == "complete"
          then (.pending_batch_ids | length) == 0
          else (.pending_batch_ids | length) > 0 end)
      then . else error("invalid reconciliation marker") end
    ' <<<"${marker_raw}")" \
      || reconcile_die "terminal count reconciliation marker is invalid" 3
    MARKER_PRESENT=true
    MARKER_DIGEST="$(printf '%s' "${marker_raw}" | scheduler_sha256_text)"
    MARKER_PENDING_BATCH_IDS="$(jq -c '.pending_batch_ids | sort' <<<"${marker_json}")"
    MARKER_LAST_FULL_SCAN_AT="$(jq -r '.last_full_scan_at // "null"' <<<"${marker_json}")"
    MARKER_ROLLING_SCAN_UNTIL="$(jq -r '.rolling_scan_until // "null"' <<<"${marker_json}")"
  fi

  if [ "${MARKER_ROLLING_SCAN_UNTIL}" = null ]; then
    ROLLING_SCAN_UNTIL=$((RECONCILED_AT + TERMINAL_COUNT_COMPAT_SECONDS))
  else
    ROLLING_SCAN_UNTIL="${MARKER_ROLLING_SCAN_UNTIL}"
  fi
  ROLLING_SCAN_ACTIVE=false
  if [ "${TERMINAL_COUNT_COMPAT_SECONDS}" -gt 0 ] \
      && [ "${RECONCILED_AT}" -lt "${ROLLING_SCAN_UNTIL}" ]; then
    ROLLING_SCAN_ACTIVE=true
  fi

  declare -a STATE_FILES=()
  FULL_SCAN_PERFORMED=false
  if [ "${SCOPED_RUN}" = true ]; then
    while IFS= read -r batch_id; do
      state_file="${BATCHES_ROOT}/${batch_id}/state.json"
      [ -f "${state_file}" ] && [ ! -L "${state_file}" ] \
        || reconcile_die "scoped batch state is missing or unsafe: ${batch_id}"
      STATE_FILES+=("${state_file}")
    done < <(jq -r '.[]' <<<"${BATCH_IDS}")
  else
    AUDIT_DUE=false
    if [ "${MARKER_LAST_FULL_SCAN_AT}" = null ] \
        || [ "${RECONCILED_AT}" -lt "${MARKER_LAST_FULL_SCAN_AT}" ] \
        || [ $((RECONCILED_AT - MARKER_LAST_FULL_SCAN_AT)) -ge "${FULL_AUDIT_SECONDS}" ]; then
      AUDIT_DUE=true
    fi
    if [ "${ROLLING_SCAN_ACTIVE}" = true ] \
        || [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ] \
        || [ "${MARKER_PRESENT}" = false ] \
        || [ "${AUDIT_DUE}" = true ]; then
      FULL_SCAN_PERFORMED=true
    fi
  fi

  if [ "${SCOPED_RUN}" = false ] && [ "${FULL_SCAN_PERFORMED}" = true ]; then
    shopt -s nullglob
    STATE_FILES=("${BATCHES_ROOT}"/*/state.json)
    shopt -u nullglob
  elif [ "${SCOPED_RUN}" = false ]; then
    HOT_BATCH_IDS="$(jq -ce '
      if type == "object" and .version == 1
        and (.batch_order | type == "array")
        and (.batch_order | all(type == "string"
          and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
        and ((.batch_order | length) == (.batch_order | unique | length))
      then .batch_order else error("invalid hot batch index") end
    ' "${SCHEDULER_STATE_FILE}")" \
      || reconcile_die "scheduler hot batch index is invalid" 3
    BATCH_IDS_TO_SCAN="$(jq -cn \
      --argjson hot "${HOT_BATCH_IDS}" \
      --argjson pending "${MARKER_PENDING_BATCH_IDS}" \
      '$hot + $pending | unique | sort')"
    while IFS= read -r batch_id; do
      state_file="${BATCHES_ROOT}/${batch_id}/state.json"
      [ -f "${state_file}" ] && [ ! -L "${state_file}" ] \
        || reconcile_die "indexed batch state is missing or unsafe: ${batch_id}"
      STATE_FILES+=("${state_file}")
    done < <(jq -r '.[]' <<<"${BATCH_IDS_TO_SCAN}")
  fi
  if [ "${#STATE_FILES[@]}" -gt 0 ]; then
    IFS=$'\n' STATE_FILES=($(printf '%s\n' "${STATE_FILES[@]}" | LC_ALL=C sort))
    unset IFS
  fi

  for state_file in "${STATE_FILES[@]}"; do
    batch_dir="${state_file%/*}"
    batch_id="${batch_dir##*/}"
    [[ "${batch_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
      || reconcile_die "batch directory has an unsafe name"
    [ -d "${batch_dir}" ] && [ ! -L "${batch_dir}" ] \
      && [ -f "${state_file}" ] && [ ! -L "${state_file}" ] \
      || reconcile_die "batch state path is unsafe: ${batch_id}"
  done

  # Keep both process startup and argv size bounded during a historical scan.
  # Small fixed jq chunks classify current states, while detailed parsing stays
  # limited to legacy or internally inconsistent candidates.
  declare -a CANDIDATE_FILES=()
  if [ "${SCOPED_RUN}" = true ]; then
    CANDIDATE_FILES=("${STATE_FILES[@]}")
  elif [ "${#STATE_FILES[@]}" -gt 0 ]; then
    CLASSIFY_OFFSET=0
    while [ "${CLASSIFY_OFFSET}" -lt "${#STATE_FILES[@]}" ]; do
      CLASSIFY_FILES=("${STATE_FILES[@]:${CLASSIFY_OFFSET}:${CLASSIFY_CHUNK_SIZE}}")
      if ! CLASSIFY_OUTPUT="$(
        jq -r '
          def nonnegative_integer:
            type == "number" and . == floor and . >= 0;
          def valid_terminal_status:
            . == "done" or . == "failed" or . == "timeout" or . == "skipped";
          (.terminal_counts_version == 1
          and (.memberships | type == "object")
          and (.terminal_count | nonnegative_integer)
          and (.done_count | nonnegative_integer)
          and (.failed_count | nonnegative_integer)
          and (.timeout_count | nonnegative_integer)
          and (.skipped_count | nonnegative_integer)
          and (.memberships | all(
            (.status == "pending" or .status == "reserved"
              or .status == "preparing" or .status == "running"
              or .status == "attached" or .status == "retry_wait"
              or .status == "terminal" or .status == "skipped")
            and (if .status == "terminal" then (.terminal_status | valid_terminal_status)
              else (has("terminal_status") | not)
              end)))
          and (.terminal_count == ([.memberships[]
            | select(.status == "terminal" or .status == "skipped")] | length))
          and (.done_count == ([.memberships[]
            | select(.status == "terminal" and .terminal_status == "done")] | length))
          and (.failed_count == ([.memberships[]
            | select(.status == "terminal" and .terminal_status == "failed")] | length))
          and (.timeout_count == ([.memberships[]
            | select(.status == "terminal" and .terminal_status == "timeout")] | length))
          and (.skipped_count == ([.memberships[]
            | select(.status == "skipped"
              or (.status == "terminal" and .terminal_status == "skipped"))] | length))
          and (.terminal_count == (.done_count + .failed_count
            + .timeout_count + .skipped_count))) as $valid
          | if $valid then empty else input_filename end
        ' "${CLASSIFY_FILES[@]}"
      )"; then
        reconcile_die "failed to classify terminal count batch states" 3
      fi
      while IFS= read -r state_file; do
        [ -n "${state_file}" ] && CANDIDATE_FILES+=("${state_file}")
      done <<<"${CLASSIFY_OUTPUT}"
      CLASSIFY_OFFSET=$((CLASSIFY_OFFSET + CLASSIFY_CHUNK_SIZE))
    done
  fi

  SCANNED=0
  REPAIRED=0
  UNRESOLVED=0
  UNRESOLVED_BATCH_IDS='[]'
  declare -A ORIGINAL_DIGESTS=()
  declare -A NEXT_STATES=()

  # Phase 1: read callback evidence under only its per-event lock. Never wait
  # for a network drainer while holding the scheduler-wide transaction lock.
  for state_file in "${CANDIDATE_FILES[@]}"; do
    batch_dir="${state_file%/*}"
    batch_id="${batch_dir##*/}"
    [[ "${batch_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
      || reconcile_die "batch directory has an unsafe name"
    [ -d "${batch_dir}" ] && [ ! -L "${batch_dir}" ] \
      && [ -f "${state_file}" ] && [ ! -L "${state_file}" ] \
      || reconcile_die "batch state path is unsafe: ${batch_id}"
    # Parse and fingerprint one immutable byte snapshot. Reading the file once
    # through a single descriptor prevents an atomic batch-only writer from
    # replacing it between parsing and digesting, which would otherwise let
    # phase 2 overwrite a newer state with a result derived from older bytes.
    state_raw="$(<"${state_file}")"
    state_json="$(jq -ce --arg batch_id "${batch_id}" '
      def valid_membership_status:
        . == "pending" or . == "reserved" or . == "preparing"
        or . == "running" or . == "attached" or . == "retry_wait"
        or . == "terminal" or . == "skipped";
      def valid_terminal_status:
        . == "done" or . == "failed" or . == "timeout" or . == "skipped";
      if type == "object"
        and .version == 1
        and .batch_id == $batch_id
        and ((has("terminal_counts_version") | not)
          or .terminal_counts_version == 1)
        and (.matched_count | type == "number" and . == floor and . >= 0)
        and (.terminal_count | type == "number" and . == floor and . >= 0)
        and (.done_count | type == "number" and . == floor and . >= 0)
        and (.failed_count | type == "number" and . == floor and . >= 0)
        and (.timeout_count | type == "number" and . == floor and . >= 0)
        and (.skipped_count | type == "number" and . == floor and . >= 0)
        and (.next_snapshot_index | type == "number" and . == floor and . >= 0)
        and (.memberships | type == "object")
        and (.memberships | to_entries | all(
          (.key | test("^(0|[1-9][0-9]*)$"))
          and (.value | type == "object")
          and .value.snapshot_index == (.key | tonumber)
          and (.value.iid | type == "number" and . == floor and . > 0)
          and (.value.status | type == "string" and valid_membership_status)
          and (if (.value | has("terminal_status"))
            then .value.status == "terminal"
              and (.value.terminal_status | valid_terminal_status)
            else true end)))
      then .
      else error("invalid batch state")
      end
    ' <<<"${state_raw}")" \
      || reconcile_die "batch state is invalid: ${batch_id}"
    ORIGINAL_DIGESTS["${state_file}"]="$(
      printf '%s' "${state_raw}" | scheduler_sha256_text
    )"
    SCANNED=$((SCANNED + 1))

    inferred='{}'
    batch_unresolved=0
    while IFS=$'\t' read -r snapshot_index iid; do
      [ -n "${snapshot_index}" ] || continue
      event_id="${batch_id}:snapshot-${snapshot_index}:terminal-1"
      found_status=""
      acquire_callback_event_locks "${event_id}"
      for evidence_file in \
        "${CALLBACK_ARCHIVE}/${event_id}.json" \
        "${CALLBACK_OUTBOX}/${event_id}.json"
      do
        [ -e "${evidence_file}" ] || continue
        [ -f "${evidence_file}" ] && [ ! -L "${evidence_file}" ] \
          || reconcile_die "terminal outcome evidence path is unsafe: ${event_id}"
        evidence_status="$(jq -er \
          --arg batch_id "${batch_id}" \
          --arg event_id "${event_id}" \
          --argjson snapshot_index "${snapshot_index}" \
          --argjson iid "${iid}" '
          if type == "object"
            and .version == 1
            and .event_id == $event_id
            and (.body | type == "object")
            and .body.batch_id == $batch_id
            and .body.event_id == $event_id
            and .body.snapshot_index == $snapshot_index
            and .body.iid == $iid
            and (.body.status == "done" or .body.status == "failed"
              or .body.status == "timeout" or .body.status == "skipped")
          then .body.status
          else error("invalid terminal outcome evidence")
          end
        ' "${evidence_file}")" \
          || reconcile_die "terminal outcome evidence is invalid: ${event_id}"
        if [ -n "${found_status}" ] && [ "${found_status}" != "${evidence_status}" ]; then
          reconcile_die "terminal outcome evidence conflicts: ${event_id}"
        fi
        found_status="${evidence_status}"
      done
      release_callback_event_locks
      if [ -z "${found_status}" ]; then
        batch_unresolved=$((batch_unresolved + 1))
        UNRESOLVED=$((UNRESOLVED + 1))
        continue
      fi
      inferred="$(jq -c \
        --arg index "${snapshot_index}" \
        --arg status "${found_status}" \
        '.[$index] = $status' <<<"${inferred}")"
    done < <(jq -r '
      .memberships | to_entries[]
      | select(.value.status == "terminal")
      | select(.value | has("terminal_status") | not)
      | [.key, (.value.iid | tostring)] | @tsv
    ' <<<"${state_json}")

    if [ "${batch_unresolved}" -gt 0 ]; then
      UNRESOLVED_BATCH_IDS="$(jq -c --arg batch_id "${batch_id}" \
        '. + [$batch_id] | unique | sort' <<<"${UNRESOLVED_BATCH_IDS}")"
      continue
    fi
    next_state="$(jq -ceS --argjson inferred "${inferred}" '
      def valid_terminal_status:
        . == "done" or . == "failed" or . == "timeout" or . == "skipped";
      .memberships |= with_entries(
        if .value.status == "terminal"
          and (.value | has("terminal_status") | not)
        then .value.terminal_status = $inferred[.key]
        else .
        end)
      | .terminal_counts_version = 1
      | .terminal_count = ([.memberships[]
          | select(.status == "terminal" or .status == "skipped")] | length)
      | .done_count = ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "done")] | length)
      | .failed_count = ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "failed")] | length)
      | .timeout_count = ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "timeout")] | length)
      | .skipped_count = ([.memberships[]
          | select(.status == "skipped"
            or (.status == "terminal" and .terminal_status == "skipped"))] | length)
      | if (.memberships | all(
          if .status == "terminal" then (.terminal_status | valid_terminal_status)
          else (has("terminal_status") | not)
          end))
          and .terminal_count == (.done_count + .failed_count
            + .timeout_count + .skipped_count)
        then . else error("inconsistent terminal outcome counters") end
    ' <<<"${state_json}")" \
      || reconcile_die "reconciled batch state is inconsistent: ${batch_id}"
    NEXT_STATES["${state_file}"]="${next_state}"
  done

  # Phase 2: take the global lock only to fence the scheduler generation,
  # compare the exact batch bytes observed above, and publish atomic updates.
  exec {RECONCILE_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  flock -x "${RECONCILE_LOCK_FD}"
  CURRENT_IDENTITY="$(scheduler_state_identity)"
  PENDING_TRANSACTION="$(jq -r '
    if type == "object" and .version == 1
    then has("pending_transaction")
    else error("invalid scheduler state") end
  ' "${SCHEDULER_STATE_FILE}")" \
    || reconcile_die "scheduler state is invalid" 3
  RETRY_REQUIRED=false
  if [ "${CURRENT_IDENTITY}" != "${SCHEDULER_IDENTITY}" ] \
      || [ "${PENDING_TRANSACTION}" = true ]; then
    RETRY_REQUIRED=true
  else
    if [ "${SCOPED_RUN}" = false ]; then
      CURRENT_MARKER_DIGEST=absent
      if [ -e "${MIGRATION_MARKER}" ]; then
        [ -f "${MIGRATION_MARKER}" ] && [ ! -L "${MIGRATION_MARKER}" ] \
          || reconcile_die "terminal count reconciliation marker became unsafe" 3
        current_marker_raw="$(<"${MIGRATION_MARKER}")"
        CURRENT_MARKER_DIGEST="$(printf '%s' "${current_marker_raw}" | scheduler_sha256_text)"
      fi
      if [ "${CURRENT_MARKER_DIGEST}" != "${MARKER_DIGEST}" ]; then
        RETRY_REQUIRED=true
      fi
    fi
    if [ "${RETRY_REQUIRED}" = false ]; then
      for state_file in "${CANDIDATE_FILES[@]}"; do
        [ -f "${state_file}" ] && [ ! -L "${state_file}" ] \
          || { RETRY_REQUIRED=true; break; }
        current_raw="$(<"${state_file}")"
        current_digest="$(printf '%s' "${current_raw}" | scheduler_sha256_text)"
        if [ "${current_digest}" != "${ORIGINAL_DIGESTS["${state_file}"]}" ]; then
          RETRY_REQUIRED=true
          break
        fi
      done
    fi
  fi

  if [ "${RETRY_REQUIRED}" = true ]; then
    flock -u "${RECONCILE_LOCK_FD}"
    exec {RECONCILE_LOCK_FD}>&-
    if [ "${ATTEMPT}" -ge "${RECONCILE_RETRY_LIMIT}" ]; then
      reconcile_die "scheduler changed throughout terminal count reconciliation" 3
    fi
    run_scheduler_migration
    continue
  fi

  for state_file in "${CANDIDATE_FILES[@]}"; do
    [ -n "${NEXT_STATES["${state_file}"]+x}" ] || continue
    next_state="${NEXT_STATES["${state_file}"]}"
    if [ "$(jq -cS . "${state_file}")" != "${next_state}" ]; then
      atomic_write_json "${state_file}" "${next_state}"
      REPAIRED=$((REPAIRED + 1))
    fi
  done

  if [ "${SCOPED_RUN}" = false ]; then
    if [ "${UNRESOLVED}" -eq 0 ]; then
      MARKER_STATUS=complete
      UNRESOLVED_BATCH_IDS='[]'
    else
      MARKER_STATUS=partial
    fi
    if [ "${FULL_SCAN_PERFORMED}" = true ]; then
      LAST_FULL_SCAN_AT="${RECONCILED_AT}"
    else
      LAST_FULL_SCAN_AT="${MARKER_LAST_FULL_SCAN_AT}"
    fi
    MARKER_JSON="$(jq -cnS \
      --arg status "${MARKER_STATUS}" \
      --argjson pending_batch_ids "${UNRESOLVED_BATCH_IDS}" \
      --argjson last_full_scan_at "${LAST_FULL_SCAN_AT}" \
      --argjson rolling_scan_until "${ROLLING_SCAN_UNTIL}" \
      --argjson updated_at "${RECONCILED_AT}" '{
        version:1,
        status:$status,
        pending_batch_ids:$pending_batch_ids,
        last_full_scan_at:$last_full_scan_at,
        rolling_scan_until:$rolling_scan_until,
        updated_at:$updated_at
      }')"
    atomic_write_json "${MIGRATION_MARKER}" "${MARKER_JSON}"
  fi

  flock -u "${RECONCILE_LOCK_FD}"
  exec {RECONCILE_LOCK_FD}>&-

  if [ "${UNRESOLVED}" -eq 0 ]; then
    RESULT_STATUS=reconciled
  else
    RESULT_STATUS=partial
  fi
  emit_result "${RESULT_STATUS}" "${SCANNED}" "${REPAIRED}" "${UNRESOLVED}"
  exit 0
done

reconcile_die "terminal count reconciliation retry limit exhausted" 3
