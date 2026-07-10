#!/usr/bin/env bash
# Validate a RUN_DRIVEN_ISSUE_BATCH trigger, freeze its OPEN Issue membership,
# and atomically publish an idempotent executor batch.
set -euo pipefail

CREATE_BATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

batch_die() {
  echo "create_driven_batch.sh: $1" >&2
  exit "${2:-2}"
}

has_control_characters() {
  local value="$1"
  case "${value}" in
    *$'\r'*|*$'\t'*) return 0 ;;
  esac
  LC_ALL=C printf '%s' "${value}" | grep -q '[[:cntrl:]]'
}

require_field() {
  local name="$1"
  if [ "${TRIGGER_FIELDS[${name}]+x}" != x ]; then
    batch_die "missing trigger field: ${name}"
  fi
}

reject_field() {
  local name="$1"
  if [ "${TRIGGER_FIELDS[${name}]+x}" = x ]; then
    batch_die "selector_type=${SELECTOR_TYPE} does not accept ${name}"
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    batch_die "no SHA-256 command is available"
  fi
}

emit_success() {
  local batch_id="$1"
  local matched_count="$2"
  local snapshot_digest="$3"
  local scheduler_status="$4"

  jq -cn \
    --arg batch_id "${batch_id}" \
    --arg matched_count "${matched_count}" \
    --arg snapshot_digest "${snapshot_digest}" \
    --arg scheduler_status "${scheduler_status}" \
    '{
      status: "success",
      batch_id: $batch_id,
      matched_count: ($matched_count | tonumber),
      snapshot_digest: $snapshot_digest,
      scheduler_status: $scheduler_status
    }'
}

if ! IFS= read -r TRIGGER_NAME; then
  batch_die "missing trigger"
fi
[ "${TRIGGER_NAME}" = RUN_DRIVEN_ISSUE_BATCH ] || \
  batch_die "expected RUN_DRIVEN_ISSUE_BATCH trigger"

declare -A TRIGGER_FIELDS=()
while IFS= read -r trigger_line || [ -n "${trigger_line}" ]; do
  [ -n "${trigger_line}" ] || continue
  case "${trigger_line}" in
    *=*) ;;
    *) batch_die "invalid trigger line" ;;
  esac

  trigger_key="${trigger_line%%=*}"
  trigger_value="${trigger_line#*=}"
  case "${trigger_key}" in
    batch_id|correlation_id|project|selector_type|iid|iid_min|iid_max|label|force_rerun_pr|dispatcher_callback_target|branch)
      ;;
    *)
      batch_die "unsupported trigger field: ${trigger_key}"
      ;;
  esac
  if [ "${TRIGGER_FIELDS[${trigger_key}]+x}" = x ]; then
    batch_die "duplicate trigger field: ${trigger_key}"
  fi
  if has_control_characters "${trigger_value}"; then
    batch_die "trigger field contains control characters: ${trigger_key}"
  fi
  TRIGGER_FIELDS["${trigger_key}"]="${trigger_value}"
done

for required_name in \
  batch_id correlation_id project selector_type force_rerun_pr dispatcher_callback_target
do
  require_field "${required_name}"
done

BATCH_ID="${TRIGGER_FIELDS[batch_id]}"
CORRELATION_ID="${TRIGGER_FIELDS[correlation_id]}"
PROJECT_FULL="${TRIGGER_FIELDS[project]}"
SELECTOR_TYPE="${TRIGGER_FIELDS[selector_type]}"
FORCE_RERUN_PR="${TRIGGER_FIELDS[force_rerun_pr]}"
DISPATCHER_CALLBACK_TARGET="${TRIGGER_FIELDS[dispatcher_callback_target]}"
BRANCH="${TRIGGER_FIELDS[branch]:-}"

if ! [[ "${BATCH_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  batch_die "batch_id must be a safe path component"
fi
[ -n "${CORRELATION_ID}" ] || batch_die "correlation_id must not be empty"
if ! [[ "${PROJECT_FULL}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  batch_die "project must be <group>/<project>"
fi
case "${FORCE_RERUN_PR}" in
  true|false) ;;
  *) batch_die "force_rerun_pr must be true or false" ;;
esac
if [ -n "${BRANCH}" ]; then
  case "${BRANCH}" in
    -*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*" "*|*.lock|*.)
      batch_die "branch must be a safe Git ref name"
      ;;
  esac
  [ "${BRANCH}" != @ ] || batch_die "branch must be a safe Git ref name"
fi

case "${SELECTOR_TYPE}" in
  single)
    require_field iid
    reject_field iid_min
    reject_field iid_max
    reject_field label
    IID="${TRIGGER_FIELDS[iid]}"
    [[ "${IID}" =~ ^[1-9][0-9]*$ ]] || batch_die "iid must be a positive integer"
    SELECTOR_JSON="$(jq -cnS --arg iid "${IID}" '{type:"single",iid:($iid | tonumber)}')"
    ;;
  range)
    require_field iid_min
    require_field iid_max
    reject_field iid
    reject_field label
    IID_MIN="${TRIGGER_FIELDS[iid_min]}"
    IID_MAX="${TRIGGER_FIELDS[iid_max]}"
    [[ "${IID_MIN}" =~ ^[1-9][0-9]*$ ]] || batch_die "iid_min must be a positive integer"
    [[ "${IID_MAX}" =~ ^[1-9][0-9]*$ ]] || batch_die "iid_max must be a positive integer"
    [ "${IID_MIN}" -le "${IID_MAX}" ] || batch_die "iid_min must be <= iid_max"
    SELECTOR_JSON="$(jq -cnS \
      --arg iid_min "${IID_MIN}" \
      --arg iid_max "${IID_MAX}" \
      '{type:"range",iid_min:($iid_min | tonumber),iid_max:($iid_max | tonumber)}')"
    ;;
  open_unfinished)
    reject_field iid
    reject_field iid_min
    reject_field iid_max
    reject_field label
    SELECTOR_JSON='{"type":"open_unfinished"}'
    ;;
  open_label)
    require_field label
    reject_field iid
    reject_field iid_min
    reject_field iid_max
    LABEL="${TRIGGER_FIELDS[label]}"
    if [ -z "${LABEL//[[:space:]]/}" ]; then
      batch_die "label must not be empty"
    fi
    SELECTOR_JSON="$(jq -cnS --arg label "${LABEL}" '{type:"open_label",label:$label}')"
    ;;
  *)
    batch_die "unsupported selector_type: ${SELECTOR_TYPE}"
    ;;
esac

REQUEST_JSON="$(jq -cnS \
  --arg batch_id "${BATCH_ID}" \
  --arg correlation_id "${CORRELATION_ID}" \
  --arg project "${PROJECT_FULL}" \
  --argjson selector "${SELECTOR_JSON}" \
  --argjson force_rerun_pr "${FORCE_RERUN_PR}" \
  --arg dispatcher_callback_target "${DISPATCHER_CALLBACK_TARGET}" \
  --arg branch "${BRANCH}" \
  '{
    version: 1,
    batch_id: $batch_id,
    correlation_id: $correlation_id,
    project: $project,
    selector: $selector,
    force_rerun_pr: $force_rerun_pr,
    dispatcher_callback_target: $dispatcher_callback_target,
    branch: (if $branch == "" then null else $branch end)
  }')"
REQUEST_DIGEST="$(printf '%s' "${REQUEST_JSON}" | sha256_text)"

# scheduler_env.sh loads only deployment/local scheduler settings; it never
# accepts GitLab credentials from the trigger.
# shellcheck disable=SC1091
source "${CREATE_BATCH_SCRIPT_DIR}/scheduler_env.sh" >/dev/null

FAILED_INTAKE_ROOT="${EXECUTOR_SCHEDULER_ROOT}/failed-intake"
BATCH_LOCK_ROOT="${EXECUTOR_SCHEDULER_ROOT}/batch-locks"
mkdir -p "${FAILED_INTAKE_ROOT}" "${BATCH_LOCK_ROOT}"

exec {BATCH_LOCK_FD}>"${BATCH_LOCK_ROOT}/${BATCH_ID}.lock"
flock -x "${BATCH_LOCK_FD}"

BATCH_DIR="${BATCHES_ROOT}/${BATCH_ID}"
if [ -e "${BATCH_DIR}" ]; then
  [ -d "${BATCH_DIR}" ] || batch_die "existing batch path is not a directory" 3
  for persisted_name in request.json snapshot.json state.json; do
    [ -f "${BATCH_DIR}/${persisted_name}" ] || \
      batch_die "existing batch is incomplete: missing ${persisted_name}" 3
  done

  EXISTING_REQUEST_JSON="$(jq -ceS '
    if type == "object" then . else error("request must be an object") end
  ' "${BATCH_DIR}/request.json")" || \
    batch_die "existing request.json is invalid" 3
  EXISTING_REQUEST_DIGEST="$(printf '%s' "${EXISTING_REQUEST_JSON}" | sha256_text)"
  [ "${EXISTING_REQUEST_DIGEST}" = "${REQUEST_DIGEST}" ] || \
    batch_die "batch_id request conflict" 3

  EXISTING_SNAPSHOT_JSON="$(jq -ceS '
    if type == "object"
      and (.version == 1)
      and (.project | type == "string")
      and (.iids | type == "array")
      and (.iids | all(type == "number" and . == floor and . > 0))
    then .
    else error("snapshot shape is invalid")
    end
  ' "${BATCH_DIR}/snapshot.json")" || batch_die "existing snapshot.json is invalid" 3
  EXISTING_SNAPSHOT_DIGEST="$(printf '%s' "${EXISTING_SNAPSHOT_JSON}" | sha256_text)"

  EXISTING_STATE="$(jq -ce \
    --arg batch_id "${BATCH_ID}" \
    --arg request_digest "${REQUEST_DIGEST}" \
    --arg snapshot_digest "${EXISTING_SNAPSHOT_DIGEST}" \
    'if type == "object"
        and .batch_id == $batch_id
        and .request_digest == $request_digest
        and .snapshot_digest == $snapshot_digest
        and (.matched_count | type == "number")
        and (.status == "queued" or .status == "running" or .status == "completed")
     then .
     else error("batch state is invalid")
     end' \
    "${BATCH_DIR}/state.json")" || batch_die "existing batch state is invalid" 3

  BATCH_ORDER_COUNT="$(jq -r --arg batch_id "${BATCH_ID}" \
    '[.batch_order[] | select(. == $batch_id)] | length' "${SCHEDULER_STATE_FILE}")"
  [ "${BATCH_ORDER_COUNT}" = 1 ] || batch_die "existing batch scheduler registration is invalid" 3

  emit_success \
    "${BATCH_ID}" \
    "$(jq -r '.matched_count' <<<"${EXISTING_STATE}")" \
    "${EXISTING_SNAPSHOT_DIGEST}" \
    "$(jq -r '.status' <<<"${EXISTING_STATE}")"
  exit 0
fi

INTAKE_DIR="$(mktemp -d "${EXECUTOR_SCHEDULER_ROOT}/.batch-intake-${BATCH_ID}.XXXXXX")"
INTAKE_ACTIVE=true
INTAKE_FAILURE_REASON=intake_failed

retire_failed_intake() {
  local exit_status=$?
  local failed_destination=""
  trap - EXIT
  if [ "${INTAKE_ACTIVE}" = true ] && [ -d "${INTAKE_DIR}" ]; then
    jq -cn \
      --arg batch_id "${BATCH_ID}" \
      --arg reason "${INTAKE_FAILURE_REASON}" \
      '{status:"failed",batch_id:$batch_id,reason:$reason}' \
      >"${INTAKE_DIR}/failure.json" 2>/dev/null || \
      printf '%s\n' '{"status":"failed","reason":"intake_failed"}' >"${INTAKE_DIR}/failure.json"
    failed_destination="${FAILED_INTAKE_ROOT}/$(basename "${INTAKE_DIR}")"
    mv "${INTAKE_DIR}" "${failed_destination}" || true
  fi
  exit "${exit_status}"
}
trap retire_failed_intake EXIT

intake_fail() {
  INTAKE_FAILURE_REASON="$1"
  echo "create_driven_batch.sh: $2" >&2
  exit "${3:-2}"
}

printf '%s\n' "${REQUEST_JSON}" >"${INTAKE_DIR}/request.json"

# glab_auth.sh gives process env precedence over executor config and never
# consults trigger fields. Sourcing it keeps the pinned host/protocol exports.
INTAKE_FAILURE_REASON=gitlab_auth_failed
# shellcheck disable=SC1091
source "${CREATE_BATCH_SCRIPT_DIR}/glab_auth.sh" >/dev/null

PROJECT_URI="$(printf '%s' "${PROJECT_FULL}" | jq -sRr @uri)"
ALL_ISSUES='[]'
page=1
while :; do
  endpoint="projects/${PROJECT_URI}/issues?state=opened&per_page=100&page=${page}"
  INTAKE_FAILURE_REASON="gitlab_page_${page}_failed"
  if ! PAGE_JSON="$("${GLAB_BIN:-glab}" api "${endpoint}")"; then
    intake_fail "${INTAKE_FAILURE_REASON}" "GitLab Issue page ${page} request failed"
  fi
  if ! jq -e 'type == "array"' <<<"${PAGE_JSON}" >/dev/null; then
    intake_fail "gitlab_page_${page}_not_array" "GitLab Issue page ${page} is not a JSON array"
  fi
  if ! jq -e '
    all(.[ ];
      type == "object"
      and (.iid | type == "number" and . == floor and . > 0)
      and (.state | type == "string")
      and (.labels | type == "array" and all(.[ ]; type == "string")))
  ' <<<"${PAGE_JSON}" >/dev/null; then
    intake_fail "gitlab_page_${page}_invalid_issue" "GitLab Issue page ${page} contains an invalid Issue"
  fi

  page_length="$(jq -r 'length' <<<"${PAGE_JSON}")"
  [ "${page_length}" -gt 0 ] || break
  ALL_ISSUES="$(printf '%s\n%s\n' "${ALL_ISSUES}" "${PAGE_JSON}" | jq -cs '.[0] + .[1]')" || \
    intake_fail merge_failed "failed to merge GitLab Issue pages"
  page=$((page + 1))
done

INTAKE_FAILURE_REASON=selector_failed
MATCHED_IIDS="$(jq -cS \
  --arg selector_type "${SELECTOR_TYPE}" \
  --argjson selector "${SELECTOR_JSON}" \
  '
    def unfinished_terminal_label:
      . == "pr"
      or . == "timeout"
      or . == "blocked"
      or startswith("blocked-")
      or . == "failed"
      or startswith("failed-");

    map(select(.state == "opened"))
    | sort_by(.iid)
    | unique_by(.iid)
    | map(select(
        if $selector_type == "single" then
          .iid == $selector.iid
        elif $selector_type == "range" then
          .iid >= $selector.iid_min and .iid <= $selector.iid_max
        elif $selector_type == "open_unfinished" then
          ([.labels[] | select(unfinished_terminal_label)] | length) == 0
        elif $selector_type == "open_label" then
          (.labels | index($selector.label)) != null
        else
          false
        end))
    | map(.iid)
  ' <<<"${ALL_ISSUES}")" || intake_fail selector_failed "failed to select GitLab Issues"

SNAPSHOT_JSON="$(jq -cnS \
  --arg project "${PROJECT_FULL}" \
  --argjson iids "${MATCHED_IIDS}" \
  '{version:1,project:$project,iids:$iids}')"
SNAPSHOT_DIGEST="$(printf '%s' "${SNAPSHOT_JSON}" | sha256_text)"
MATCHED_COUNT="$(jq -r 'length' <<<"${MATCHED_IIDS}")"
if [ "${MATCHED_COUNT}" -eq 0 ]; then
  SCHEDULER_STATUS=completed
else
  SCHEDULER_STATUS=queued
fi

STATE_JSON="$(jq -cnS \
  --arg batch_id "${BATCH_ID}" \
  --arg status "${SCHEDULER_STATUS}" \
  --arg matched_count "${MATCHED_COUNT}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  '{
    version: 1,
    batch_id: $batch_id,
    status: $status,
    matched_count: ($matched_count | tonumber),
    terminal_count: 0,
    done_count: 0,
    failed_count: 0,
    timeout_count: 0,
    skipped_count: 0,
    next_snapshot_index: 0,
    request_digest: $request_digest,
    snapshot_digest: $snapshot_digest,
    memberships: {}
  }')"

printf '%s\n' "${SNAPSHOT_JSON}" >"${INTAKE_DIR}/snapshot.json"
printf '%s\n' "${STATE_JSON}" >"${INTAKE_DIR}/state.json"

for intake_name in request.json snapshot.json state.json; do
  jq -e . "${INTAKE_DIR}/${intake_name}" >/dev/null || \
    intake_fail invalid_persisted_json "failed to validate ${intake_name}"
done

# Publish the complete directory and register it while holding only the
# scheduler state lock. No GitLab or project operation happens under it.
exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"
if jq -e --arg batch_id "${BATCH_ID}" '.batch_order | index($batch_id) != null' \
  "${SCHEDULER_STATE_FILE}" >/dev/null; then
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  intake_fail stale_scheduler_registration "scheduler already contains batch_id without a batch directory" 3
fi

UPDATED_SCHEDULER_STATE="$(jq -c --arg batch_id "${BATCH_ID}" \
  '.batch_order += [$batch_id]' "${SCHEDULER_STATE_FILE}")" || {
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  intake_fail scheduler_state_update_failed "failed to update scheduler state"
}
SCHEDULER_STATE_TMP="$(mktemp "${EXECUTOR_SCHEDULER_ROOT}/.scheduler_state.json.XXXXXX")"
printf '%s' "${UPDATED_SCHEDULER_STATE}" >"${SCHEDULER_STATE_TMP}"

INTAKE_FAILURE_REASON=atomic_publish_failed
if ! mv "${INTAKE_DIR}" "${BATCH_DIR}"; then
  mv "${SCHEDULER_STATE_TMP}" "${FAILED_INTAKE_ROOT}/$(basename "${SCHEDULER_STATE_TMP}")" || true
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  intake_fail atomic_publish_failed "failed to publish batch directory"
fi
INTAKE_ACTIVE=false

if ! mv "${SCHEDULER_STATE_TMP}" "${SCHEDULER_STATE_FILE}"; then
  PUBLISHED_FAILURE_DIR="${FAILED_INTAKE_ROOT}/published-${BATCH_ID}-$$-${RANDOM}"
  mv "${BATCH_DIR}" "${PUBLISHED_FAILURE_DIR}" || true
  if [ -e "${SCHEDULER_STATE_TMP}" ]; then
    mv "${SCHEDULER_STATE_TMP}" "${PUBLISHED_FAILURE_DIR}/scheduler_state.candidate.json" || true
  fi
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  batch_die "failed to publish scheduler state" 2
fi

flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-
trap - EXIT

emit_success "${BATCH_ID}" "${MATCHED_COUNT}" "${SNAPSHOT_DIGEST}" "${SCHEDULER_STATUS}"
