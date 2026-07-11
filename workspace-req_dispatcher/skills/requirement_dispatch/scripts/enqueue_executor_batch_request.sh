#!/usr/bin/env bash
# Atomically persist one canonical token-free I1 request before any network call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

: "${BATCH_ID:?BATCH_ID required}"
: "${CORRELATION_ID:?CORRELATION_ID required}"
: "${PROJECT:?PROJECT required}"
: "${SELECTOR_JSON:?SELECTOR_JSON required}"
: "${FORCE_RERUN_PR:?FORCE_RERUN_PR required}"
: "${EXECUTOR_AGENT:?EXECUTOR_AGENT required}"
: "${PAYLOAD:?PAYLOAD required}"
: "${REQUEST_DIGEST:?REQUEST_DIGEST required}"
TARGET_BRANCH="${TARGET_BRANCH:-}"
ORIGIN_JSON="${ORIGIN_JSON:-null}"

expected_digest="$(printf '%s' "${PAYLOAD}" | executor_batch_sha256)"
[ "${expected_digest}" = "${REQUEST_DIGEST}" ] \
  || executor_batch_outbox_die "REQUEST_DIGEST does not match PAYLOAD"
ORIGIN_JSON="$(printf '%s' "${ORIGIN_JSON}" | normalize_executor_batch_origin 2>/dev/null)" \
  || executor_batch_outbox_die "ORIGIN_JSON is invalid"

case "${FORCE_RERUN_PR}" in true|false) ;; *) executor_batch_outbox_die "FORCE_RERUN_PR must be true or false" ;; esac

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exec 9>"${LOCK_FILE}"
flock 9
outbox_json="$(load_executor_batch_outbox_locked)"
legacy_queue_json="$(load_legacy_executor_queue_locked)"

existing_count="$(jq -r --arg batch_id "${BATCH_ID}" \
  '[.requests[] | select(.batch_id == $batch_id)] | length' <<<"${outbox_json}")"
if [ "${existing_count}" -gt 1 ]; then
  executor_batch_outbox_die "duplicate batch_id in outbox: ${BATCH_ID}" 3
elif [ "${existing_count}" -eq 1 ]; then
  existing_digest="$(jq -r --arg batch_id "${BATCH_ID}" \
    '.requests[] | select(.batch_id == $batch_id) | .request_digest' <<<"${outbox_json}")"
  [ "${existing_digest}" = "${REQUEST_DIGEST}" ] \
    || executor_batch_outbox_die "batch_id conflicts with another request: ${BATCH_ID}" 3
  existing_status="$(jq -r --arg batch_id "${BATCH_ID}" \
    '.requests[] | select(.batch_id == $batch_id) | .status' <<<"${outbox_json}")"
  flock -u 9
  jq -cn \
    --arg status "${existing_status}" \
    --arg batch_id "${BATCH_ID}" \
    --arg correlation_id "${CORRELATION_ID}" \
    '{status:$status,batch_id:$batch_id,correlation_id:$correlation_id,duplicate:true}'
  exit 0
fi

if legacy_executor_queue_is_busy "${legacy_queue_json}" >/dev/null; then
  request_status=waiting_for_legacy_drain
else
  request_status=queued
fi

entry_json="$(jq -cn \
  --arg batch_id "${BATCH_ID}" \
  --arg correlation_id "${CORRELATION_ID}" \
  --arg project "${PROJECT}" \
  --argjson selector "${SELECTOR_JSON}" \
  --argjson force_rerun_pr "${FORCE_RERUN_PR}" \
  --arg target_branch "${TARGET_BRANCH}" \
  --arg executor_agent "${EXECUTOR_AGENT}" \
  --argjson origin "${ORIGIN_JSON}" \
  --arg payload "${PAYLOAD}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg status "${request_status}" \
  --arg now "${now}" '{
    batch_id:$batch_id,
    correlation_id:$correlation_id,
    project:$project,
    selector:$selector,
    force_rerun_pr:$force_rerun_pr,
    target_branch:(if $target_branch == "" then null else $target_branch end),
    executor_agent:$executor_agent,
    origin:$origin,
    payload:$payload,
    request_digest:$request_digest,
    status:$status,
    attempts:0,
    last_attempt_at:null,
    last_error:null,
    matched_count:null,
    snapshot_digest:null,
    scheduler_status:null,
    created_at:$now,
    updated_at:$now,
    received_at:null,
    accepted_at:null
  }')"
next_outbox="$(jq -c --argjson entry "${entry_json}" '.requests += [$entry]' <<<"${outbox_json}")"
publish_executor_batch_outbox_locked "${next_outbox}"
flock -u 9

jq -cn \
  --arg status "${request_status}" \
  --arg batch_id "${BATCH_ID}" \
  --arg correlation_id "${CORRELATION_ID}" \
  '{status:$status,batch_id:$batch_id,correlation_id:$correlation_id,duplicate:false}'
