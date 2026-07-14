#!/usr/bin/env bash
# Repair a missing dispatcher receipt/mirror from an authenticated I3 envelope.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

recover_die() {
  echo "recover_executor_batch_callback_acceptance.sh: $1" >&2
  exit "${2:-3}"
}

: "${CALLBACK_ENVELOPE_JSON:?CALLBACK_ENVELOPE_JSON required}"
if ! envelope_json="$(jq -cseS '
  def printable:
    type == "string" and length > 0
    and (explode | all(. >= 32 and . != 127));
  def public_i3:
    type == "object"
    and (keys | sort) == [
      "batch_id","event_id","iid","mr_url","project","reason",
      "snapshot_index","status"
    ];
  def acceptance:
    type == "object"
    and (keys | sort) == [
      "batch_id","matched_count","scheduler_status","snapshot_digest","status"
    ]
    and .status == "success"
    and (.batch_id | printable)
    and (.matched_count | type == "number" and . == floor and . > 0)
    and (.snapshot_digest | type == "string" and test("^[0-9a-f]{64}$"))
    and (.scheduler_status == "queued" or .scheduler_status == "running"
      or .scheduler_status == "completed");
  if length == 1
    and (.[0] | type == "object")
    and ((.[0] | keys | sort) == [
      "batch_acceptance","callback_nonce","executor_agent","worker_result_json"
    ])
    and (.[0].callback_nonce | type == "string" and test("^[0-9a-f]{64}$"))
    and (.[0].executor_agent | printable)
    and (.[0].worker_result_json | public_i3)
    and (.[0].batch_acceptance | acceptance)
    and .[0].batch_acceptance.batch_id == .[0].worker_result_json.batch_id
    and .[0].worker_result_json.snapshot_index < .[0].batch_acceptance.matched_count
  then .[0]
  else error("invalid callback acceptance envelope")
  end
' <<<"${CALLBACK_ENVELOPE_JSON}" 2>/dev/null)"; then
  recover_die "callback acceptance envelope is invalid"
fi

batch_id="$(jq -r '.batch_acceptance.batch_id' <<<"${envelope_json}")"
matched_count="$(jq -r '.batch_acceptance.matched_count' <<<"${envelope_json}")"
snapshot_digest="$(jq -r '.batch_acceptance.snapshot_digest' <<<"${envelope_json}")"
scheduler_status="$(jq -r '.batch_acceptance.scheduler_status' <<<"${envelope_json}")"
callback_nonce="$(jq -r '.callback_nonce' <<<"${envelope_json}")"
executor_agent="$(jq -r '.executor_agent' <<<"${envelope_json}")"
project="$(jq -r '.worker_result_json.project' <<<"${envelope_json}")"

# Keep authentication material in shell variables only. No child below needs
# the plaintext nonce or the original envelope.
unset CALLBACK_ENVELOPE_JSON envelope_json

callback_nonce_sha256="$(executor_callback_nonce_sha256 "${callback_nonce}")"
exec 9>"${LOCK_FILE}"
flock 9
if ! mirror_json="$(jq -ce '
  if type == "object" and (.batches | type == "object") then .
  else error("invalid mirror") end
' "${EXECUTOR_BATCH_MIRROR_FILE}" 2>/dev/null)"; then
  recover_die "executor batch mirror is invalid"
fi

if jq -e --arg batch_id "${batch_id}" '.batches | has($batch_id)' \
    <<<"${mirror_json}" >/dev/null; then
  mirror_entry="$(jq -c --arg batch_id "${batch_id}" '.batches[$batch_id]' \
    <<<"${mirror_json}")"
  if ! jq -e \
      --arg project "${project}" \
      --arg executor_agent "${executor_agent}" \
      --arg callback_nonce_sha256 "${callback_nonce_sha256}" \
      --argjson matched_count "${matched_count}" '
      .callback_auth_mode == "nonce_v1"
      and .project == $project
      and .executor_agent == $executor_agent
      and .callback_nonce_sha256 == $callback_nonce_sha256
      and .matched_count == $matched_count
    ' <<<"${mirror_entry}" >/dev/null; then
    recover_die "callback acceptance conflicts with the existing mirror"
  fi
  cold_entry="$(load_executor_accepted_intent_by_batch_id_locked "${batch_id}")"
  if [ "${cold_entry}" != null ] && ! jq -e \
      --arg snapshot_digest "${snapshot_digest}" \
      --argjson matched_count "${matched_count}" '
      .matched_count == $matched_count and .snapshot_digest == $snapshot_digest
    ' <<<"${cold_entry}" >/dev/null; then
    recover_die "callback acceptance conflicts with the accepted intent archive"
  fi
  flock -u 9
  jq -cn --arg batch_id "${batch_id}" '{status:"existing",batch_id:$batch_id}'
  exit 0
fi

outbox_json="$(load_executor_batch_outbox_locked)"
matches="$(jq -c --arg batch_id "${batch_id}" \
  '[.requests[] | select(.batch_id == $batch_id)]' <<<"${outbox_json}")"
[ "$(jq -r 'length' <<<"${matches}")" -eq 1 ] \
  || recover_die "callback acceptance has no unique durable I1 intent"
entry_json="$(jq -c '.[0]' <<<"${matches}")"
if ! jq -e \
    --arg callback_nonce "${callback_nonce}" \
    --arg executor_agent "${executor_agent}" \
    --arg project "${project}" '
    has("callback_nonce")
    and .callback_nonce == $callback_nonce
    and .executor_agent == $executor_agent
    and .project == $project
    and (.status == "waiting_for_legacy_drain" or .status == "queued"
      or .status == "received")
  ' <<<"${entry_json}" >/dev/null; then
  recover_die "callback authentication does not match the durable I1 intent"
fi
flock -u 9

# The regular receipt writer owns immutable-field and scheduler-status checks.
# It receives no callback secret; the nonce/project authentication boundary is
# the locked comparison above.
set +e
STATE_ROOT="${STATE_ROOT}" \
BATCH_ID="${batch_id}" \
EXECUTOR_AGENT="${executor_agent}" \
MATCHED_COUNT="${matched_count}" \
SNAPSHOT_DIGEST="${snapshot_digest}" \
SCHEDULER_STATUS="${scheduler_status}" \
  "${BASH}" "${SCRIPT_DIR}/record_executor_batch_receipt.sh" >/dev/null
receipt_rc=$?
set -e
if [ "${receipt_rc}" -ne 0 ]; then
  # A concurrent synchronous acceptance may have completed the same recovery.
  if jq -e --arg batch_id "${batch_id}" '.batches | has($batch_id)' \
      "${EXECUTOR_BATCH_MIRROR_FILE}" >/dev/null 2>&1; then
    jq -cn --arg batch_id "${batch_id}" '{status:"existing",batch_id:$batch_id}'
    exit 0
  fi
  recover_die "callback acceptance could not become a durable receipt"
fi

repair_result="$(
  STATE_ROOT="${STATE_ROOT}" BATCH_ID="${batch_id}" \
    "${BASH}" "${SCRIPT_DIR}/drain_executor_batch_outbox.sh"
)"
if jq -e --arg batch_id "${batch_id}" '
    .status == "accepted" and .batch_id == $batch_id
  ' <<<"${repair_result}" >/dev/null; then
  jq -cn --arg batch_id "${batch_id}" '{status:"recovered",batch_id:$batch_id}'
  exit 0
fi

# A still-running synchronous delivery can temporarily own the per-batch lock.
# The durable receipt remains `received`; the current I3 gets unknown_batch and
# its ordinary retry (or the dispatcher tick) finishes mirror construction.
if jq -e '
    .status == "retryable_failure" and .reason == "delivery_in_progress"
  ' <<<"${repair_result}" >/dev/null; then
  jq -cn --arg batch_id "${batch_id}" '{status:"pending",batch_id:$batch_id}'
  exit 0
fi
recover_die "callback receipt recovery returned an invalid result"
