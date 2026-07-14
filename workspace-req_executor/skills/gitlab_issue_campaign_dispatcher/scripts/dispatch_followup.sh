#!/usr/bin/env bash
# dispatch_followup.sh — Phase 6 wrapper for the callback path
# (native task_completion ingestion and legacy RUN_CHILD_COMPLETION_CALLBACK).
#
# Replaces the SKILL.md prose for the callback wake-up. The orchestrator
# LLM calls this once per callback with:
#   - the subagent's compact JSON on stdin (worker_result_json payload)
#   - IID, ATTEMPT_NUMBER, CALLBACK_RUN_ID and
#     CALLBACK_CHILD_SESSION_KEY via env for an ordinary current callback
#   - CALLBACK_LABEL when the pending entry persists a child label
#   - the standard dispatcher env (PROJECT, GROUP, GITLAB_TOKEN, plus
#     optional REPO_PARENT_PATH)
#
# This script:
#   1. Sources env_paths.sh + _dispatch_lib.sh
#   2. Acquires the dispatcher flock (non-blocking; returns lock_held on miss)
#   3. Runs scripts/reconcile.sh narrowly for the IID (GitLab is still ground truth)
#   4. Validates the compact reply against state_schema.md §Compact Subagent Reply
#   5. Matches against pending_subagents[IID] by iid + attempt_number
#   6. On stale/late callback → outputs callback_status=stale_or_already_drained, exits 0
#   7. Otherwise: runs Phase 6 (label sync, write terminal state files, classify, drain)
#   8. Decides cleanup action; outputs single-line JSON envelope to stdout
#
# The orchestrator LLM consumes stdout, prints chat_summary to chat, and
# calls `subagents kill --target <cleanup.target>` only when cleanup.action=="kill".

set -euo pipefail

: "${PROJECT:?dispatch_followup.sh: PROJECT must be set}"
: "${GROUP:?dispatch_followup.sh: GROUP must be set}"
: "${GITLAB_TOKEN:?dispatch_followup.sh: GITLAB_TOKEN must be set}"
: "${IID:?dispatch_followup.sh: IID must be set (callback IID)}"

case "${IID}" in
  *[!0-9]*|"") echo "dispatch_followup.sh: IID must be a positive integer, got: ${IID}" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Bootstrap dispatcher-level paths only (no ISSUE_IID export needed at this
# level — per-issue paths are derived inline below for state file writes).
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "dispatch_followup.sh: no SHA-256 command is available" >&2
    return 2
  fi
}

TIMEOUT_RECONCILE="${DRIVEN_TIMEOUT_RECONCILE:-0}"
COMPLETED_RECONCILE="${DRIVEN_COMPLETED_RECONCILE:-0}"
RESULT_RECONCILE="${DRIVEN_RESULT_RECONCILE:-0}"
case "${TIMEOUT_RECONCILE}" in
  0|1) ;;
  *) echo "dispatch_followup.sh: DRIVEN_TIMEOUT_RECONCILE must be 0 or 1" >&2; exit 2 ;;
esac
case "${COMPLETED_RECONCILE}" in
  0|1) ;;
  *) echo "dispatch_followup.sh: DRIVEN_COMPLETED_RECONCILE must be 0 or 1" >&2; exit 2 ;;
esac
case "${RESULT_RECONCILE}" in
  0|1) ;;
  *) echo "dispatch_followup.sh: DRIVEN_RESULT_RECONCILE must be 0 or 1" >&2; exit 2 ;;
esac
RECONCILE_MODE_COUNT=$((TIMEOUT_RECONCILE + COMPLETED_RECONCILE + RESULT_RECONCILE))
if [ "${RECONCILE_MODE_COUNT}" -gt 1 ]; then
  echo "dispatch_followup.sh: internal reconcile modes are mutually exclusive" >&2
  exit 2
fi
INTERNAL_CLAIM_RECONCILE=0
if [ "${RECONCILE_MODE_COUNT}" -eq 1 ]; then
  INTERNAL_CLAIM_RECONCILE=1
  RECONCILE_JOB_ID="${DRIVEN_RECONCILE_JOB_ID:-${DRIVEN_TIMEOUT_JOB_ID:-}}"
  RECONCILE_CLAIM_GENERATION="${DRIVEN_RECONCILE_CLAIM_GENERATION:-${DRIVEN_TIMEOUT_CLAIM_GENERATION:-}}"
  RECONCILE_CLAIM_TOKEN_SHA256="${DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256:-${DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256:-}}"
  : "${RECONCILE_JOB_ID:?dispatch_followup.sh: DRIVEN_RECONCILE_JOB_ID required}"
  : "${RECONCILE_CLAIM_GENERATION:?dispatch_followup.sh: DRIVEN_RECONCILE_CLAIM_GENERATION required}"
  : "${RECONCILE_CLAIM_TOKEN_SHA256:?dispatch_followup.sh: DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256 required}"
  [[ "${RECONCILE_CLAIM_GENERATION}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "dispatch_followup.sh: invalid internal reconcile claim generation" >&2; exit 2; }
  [[ "${RECONCILE_CLAIM_TOKEN_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "dispatch_followup.sh: invalid internal reconcile claim digest" >&2; exit 2; }
fi
if [ "${TIMEOUT_RECONCILE}" = 1 ]; then
  : "${DRIVEN_TIMEOUT_NOW_EPOCH:?dispatch_followup.sh: DRIVEN_TIMEOUT_NOW_EPOCH required}"
  [[ "${DRIVEN_TIMEOUT_NOW_EPOCH}" =~ ^(0|[1-9][0-9]*)$ ]] \
    || { echo "dispatch_followup.sh: invalid timeout clock" >&2; exit 2; }
fi

# Run the reusable recovery entry for one stable physical event. The caller
# must release fd 9 first; the drainer itself only snapshots/updates campaign
# state under that lock and performs materialization/import lock-free.
drain_driven_handoff_event() {
  local event_id="$1"
  DRIVEN_HANDOFF_EVENT_ID="${event_id}" \
  DRIVEN_HANDOFF_IMPORTER="${DRIVEN_HANDOFF_IMPORTER:-${SCRIPT_DIR}/import_driven_handoff.sh}" \
    bash "${SCRIPT_DIR}/drain_driven_handoff_intents.sh"
}

# Acquire flock (non-blocking). The callback can safely retry later.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc --argjson iid "${IID}" \
    '{callback_status:"lock_held", iid:$iid, chat_summary:("lock_held on callback for #" + ($iid|tostring))}'
  exit 0
fi

# Load and authenticate against the pending entry before any GitLab read.  The
# ingester performs an earlier lookup, but this lock-held check is the durable
# authorization boundary and closes the lookup-to-mutation race.
STATE_JSON="$(load_state)"
PENDING_ENTRY="$(printf '%s' "${STATE_JSON}" | jq -c --argjson iid "${IID}" '.pending_subagents[($iid|tostring)] // null')"
if [ "${PENDING_ENTRY}" != "null" ]; then
  AUTH_PENDING_ATTEMPT="$(jq -r '.attempt_number' <<<"${PENDING_ENTRY}")"
  if [ "${INTERNAL_CLAIM_RECONCILE}" = 1 ]; then
    # Internal completion/timeout reconciliation has its own
    # job/generation/token-digest fence below and is not a runtime callback.
    ATTEMPT_NUMBER="${ATTEMPT_NUMBER:-${AUTH_PENDING_ATTEMPT}}"
  else
    if ! CALLBACK_AUTH_MODE="$(completion_authenticate_pending \
        "${PENDING_ENTRY}" "${ATTEMPT_NUMBER:-}" \
        "${CALLBACK_RUN_ID:-}" "${CALLBACK_CHILD_SESSION_KEY:-}" \
        "${CALLBACK_LABEL:-}")"; then
      wrapper_log followup "callback rejected iid=${IID}: completion identity mismatch"
      jq -nc --argjson iid "${IID}" '{
        callback_status:"rejected",
        iid:$iid,
        reason:"completion_identity_mismatch",
        chat_summary:("rejected callback identity for #" + ($iid|tostring))
      }'
      exit 3
    fi
    if [ "${CALLBACK_AUTH_MODE}" = legacy ] && [ -z "${ATTEMPT_NUMBER:-}" ]; then
      ATTEMPT_NUMBER="${AUTH_PENDING_ATTEMPT}"
    fi
  fi
fi

wrapper_log followup "callback received iid=${IID} attempt=${ATTEMPT_NUMBER:-?}"

# Phase 6 step 0 — narrow reconcile (best-effort; failure does NOT abort).
# The GitLab live state is consulted again so any reviewer relabel between
# spawn and callback (e.g. continue → reviewer-rejected → blocked) gets
# picked up at terminal-write time.
# Capture the narrow reconcile's evidence path so the completion guard below can
# consult fresh GitLab live labels before any regressing terminal write.
RECON_EVIDENCE_PATH=""
if [ "${PENDING_ENTRY}" != "null" ]; then
  set +e
  RECON_OUT="$(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
          REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
          MIN_IID="${IID}" MAX_IID="${IID}" \
          bash "${SCRIPT_DIR}/reconcile.sh" 2>/dev/null)"
  RECON_RC=$?
  set -e
  if [ "${RECON_RC}" -ne 0 ]; then
    wrapper_log followup "narrow reconcile failed for iid=${IID}; proceeding with cached labels"
  else
    RECON_EVIDENCE_PATH="$(printf '%s' "${RECON_OUT}" | grep -E '^/.+/reconcile-[0-9TZ]+\.json$' | tail -n 1 || true)"
  fi
fi
if [ "${PENDING_ENTRY}" = "null" ]; then
  # Phase 6 may already have atomically drained pending while retaining a
  # claim-bound durable intent. Match only this callback's IID+attempt, then
  # require the intent key to equal its canonical stable event before replay.
  RECOVERY_ATTEMPT="${ATTEMPT_NUMBER:-0}"
  if ! RECOVERY_INTENT="$(phase6_find_driven_handoff_intent \
      "${STATE_JSON}" "${IID}" "${RECOVERY_ATTEMPT}")"; then
    echo "dispatch_followup.sh: invalid durable handoff intent for iid=${IID} attempt=${RECOVERY_ATTEMPT}" >&2
    exit 3
  fi
  if [ "${RECOVERY_INTENT}" != "null" ]; then
    RECOVERY_EVENT_ID="$(jq -r '.handoff.event_id' <<<"${RECOVERY_INTENT}")"
    flock -u 9
    exec 9>&-

    set +e
    RECOVERY_DRAIN_OUT="$(drain_driven_handoff_event "${RECOVERY_EVENT_ID}" \
      2>>"${DISPATCHER_LOG_DIR}/wrapper.log")"
    RECOVERY_DRAIN_RC=$?
    set -e
    RECOVERY_RESULT=""
    if [ "${RECOVERY_DRAIN_RC}" -eq 0 ]; then
      RECOVERY_RESULT="$(jq -c --arg event_id "${RECOVERY_EVENT_ID}" \
        '.results[]? | select(.event_id == $event_id)' \
        <<<"${RECOVERY_DRAIN_OUT}" 2>/dev/null || true)"
    fi
    RECOVERY_HANDOFF_PATH=""
    RECOVERY_IMPORT_STATUS="pending"
    if [ -n "${RECOVERY_RESULT}" ]; then
      RECOVERY_HANDOFF_PATH="$(jq -r '.handoff_path // ""' <<<"${RECOVERY_RESULT}")"
      RECOVERY_RESULT_STATUS="$(jq -r '.status' <<<"${RECOVERY_RESULT}")"
      case "${RECOVERY_RESULT_STATUS}" in
        imported|imported_cleanup_pending)
          RECOVERY_IMPORT_STATUS="imported"
          ;;
      esac
    fi
    wrapper_log followup \
      "durable handoff replay iid=${IID} attempt=${RECOVERY_ATTEMPT} event_id=${RECOVERY_EVENT_ID} import_status=${RECOVERY_IMPORT_STATUS} drain_rc=${RECOVERY_DRAIN_RC}"
    jq -nc \
      --argjson iid "${IID}" \
      --argjson attempt_number "${RECOVERY_ATTEMPT}" \
      --arg handoff_event_id "${RECOVERY_EVENT_ID}" \
      --arg handoff_path "${RECOVERY_HANDOFF_PATH}" \
      --arg handoff_import_status "${RECOVERY_IMPORT_STATUS}" '{
      callback_status:"handoff_recovered",
      iid:$iid,
      attempt_number:$attempt_number,
      handoff_event_id:$handoff_event_id,
      handoff_path:$handoff_path,
      handoff_import_status:$handoff_import_status,
      chat_summary:("recovered durable handoff for #" + ($iid|tostring)
        + " event=" + $handoff_event_id
        + " handoff_import=" + $handoff_import_status)
    }'
    exit 0
  fi
  jq -nc --argjson iid "${IID}" --argjson att "${ATTEMPT_NUMBER:-0}" \
    '{callback_status:"stale_or_already_drained", iid:$iid, attempt_number:$att,
      chat_summary:("stale callback: no pending entry for #" + ($iid|tostring))}'
  exit 0
fi

# Task6 scheduler grants carry only a physical job identity and an explicit
# dynamic-membership marker. Never resolve or freeze memberships while the
# project campaign lock is held; the lock-external importer owns that step.
IS_SCHEDULER_DRIVEN=false
if jq -e '
  .memberships_source == "scheduler_active_job"
  and (.job_id | type == "string" and length > 0)
' <<<"${PENDING_ENTRY}" >/dev/null; then
  IS_SCHEDULER_DRIVEN=true
fi

if [ "${INTERNAL_CLAIM_RECONCILE}" = 1 ]; then
  reconcile_pending_token="$(jq -r '.claim_token // empty' <<<"${PENDING_ENTRY}")"
  reconcile_pending_digest=""
  [ -z "${reconcile_pending_token}" ] \
    || reconcile_pending_digest="$(printf '%s' "${reconcile_pending_token}" | sha256_text)"
  if [ "${IS_SCHEDULER_DRIVEN}" != true ] \
      || [ "$(jq -r '.job_id // empty' <<<"${PENDING_ENTRY}")" != "${RECONCILE_JOB_ID}" ] \
      || [ "$(jq -r '.claim_generation // 0' <<<"${PENDING_ENTRY}")" != "${RECONCILE_CLAIM_GENERATION}" ] \
      || [ "${reconcile_pending_digest}" != "${RECONCILE_CLAIM_TOKEN_SHA256}" ]; then
    jq -nc --argjson iid "${IID}" '{
      callback_status:"stale_claim",iid:$iid,
      chat_summary:("stale internal reconcile claim ignored for #" + ($iid|tostring))
    }'
    exit 0
  fi
fi

PENDING_ATTEMPT="$(printf '%s' "${PENDING_ENTRY}" | jq -r '.attempt_number')"

# Positive completion recovery is intentionally independent of the running
# lease. The scheduler first observed `pr`/closed through the ordinary project
# preflight; this lock-held narrow reconcile is the authoritative re-check.
# A false/stale preflight therefore returns without touching project state.
if [ "${COMPLETED_RECONCILE}" = 1 ]; then
  if [ -z "${RECON_EVIDENCE_PATH}" ] \
      || ! phase6_evidence_shows_completed "${IID}" "$(cat "${RECON_EVIDENCE_PATH}")"; then
    jq -nc --argjson iid "${IID}" '{
      callback_status:"not_completed",iid:$iid,
      chat_summary:("GitLab completion evidence is absent for #" + ($iid|tostring))
    }'
    exit 0
  fi
fi

# Synthesized-reply status for a dead subagent (empty / unparseable /
# status-less worker_result_json). 只要超时就不重试: when the run already
# outlived its acpx wall-clock budget (elapsed since spawned_at ≥
# acpx_timeout_seconds - 60s slack for ack-timestamp skew), the
# termination is timeout-shaped — a runtime termination or a death inside
# the subagent's own timeout flow — so the IID is parked
# as `timeout` (no auto-retry) instead of `blocked` (retryable). A reply
# that parses and carries an explicit status is never reclassified: a
# live subagent's own verdict wins (phase6_normalize_reply contract).
SYNTH_STATUS="blocked"
ELAPSED_S=""
# Budget pinned in the pending entry at spawn time (Phase 4 step 19); fall
# back to the campaign-level value for entries spawned before the field
# existed. A trigger override applied while this run was in flight must not
# change which budget the run is judged against.
ACPX_TIMEOUT_S="$(printf '%s' "${PENDING_ENTRY}" | jq -r '.acpx_timeout_seconds // empty')"
[ -n "${ACPX_TIMEOUT_S}" ] || ACPX_TIMEOUT_S="$(printf '%s' "${STATE_JSON}" | jq -r '.acpx_timeout_seconds // 3600')"
SP_EPOCH="$(iso_to_epoch "$(printf '%s' "${PENDING_ENTRY}" | jq -r '.spawned_at // ""')")"
if [ "${SP_EPOCH}" -gt 0 ]; then
  CALLBACK_NOW_EPOCH="$(date -u +%s)"
  [ "${TIMEOUT_RECONCILE}" != 1 ] \
    || CALLBACK_NOW_EPOCH="${DRIVEN_TIMEOUT_NOW_EPOCH}"
  ELAPSED_S=$(( CALLBACK_NOW_EPOCH - SP_EPOCH ))
  TIMEOUT_FLOOR_S=$(( ACPX_TIMEOUT_S - 60 ))
  [ "${TIMEOUT_FLOOR_S}" -lt 0 ] && TIMEOUT_FLOOR_S=0
  if [ "${ELAPSED_S}" -ge "${TIMEOUT_FLOOR_S}" ]; then
    SYNTH_STATUS="timeout"
  fi
fi

if [ "${TIMEOUT_RECONCILE}" = 1 ] && [ "${SYNTH_STATUS}" != timeout ]; then
  jq -nc --argjson iid "${IID}" '{
    callback_status:"not_due",iid:$iid,
    chat_summary:("running claim is not yet due for timeout #" + ($iid|tostring))
  }'
  exit 0
fi

# Read the compact reply from stdin. Empty stdin → synthesize a terminal
# reply: timeout when the run consumed its time budget, blocked otherwise.
RAW_REPLY="$(cat)"
if [ "${RESULT_RECONCILE}" = 1 ] \
    && [ -z "${RAW_REPLY//[$' \t\r\n']/}" ]; then
  echo "dispatch_followup.sh: durable result reconcile requires worker JSON" >&2
  exit 2
fi
if [ -z "${RAW_REPLY//[$' \t\r\n']/}" ]; then
  if [ "${SYNTH_STATUS}" = "timeout" ]; then
    REPLY_JSON="$(phase6_synthesize_timeout "${IID}" "${PENDING_ATTEMPT}" \
      "callback worker_result_json was empty after ${ELAPSED_S}s >= acpx_timeout_seconds(${ACPX_TIMEOUT_S})-60s — timeout-shaped termination, parked without retry")"
  else
    REPLY_JSON="$(phase6_synthesize_blocked "${IID}" "${PENDING_ATTEMPT}" \
      "callback worker_result_json was empty")"
  fi
else
  REPLY_JSON="$(phase6_normalize_reply "${RAW_REPLY}" "${IID}" "${PENDING_ATTEMPT}" "${SYNTH_STATUS}")"
fi

# IID cross-check. phase6_normalize_reply preserves a parseable reply's iid, so
# reject a callback whose envelope IID and compact-reply IID disagree before any
# state mutation can drain or write the wrong issue.
REPLY_IID="$(printf '%s' "${REPLY_JSON}" | jq -r '.iid')"
if [ "${REPLY_IID}" != "${IID}" ]; then
  jq -nc --argjson iid "${IID}" --arg reply_iid "${REPLY_IID}" \
    '{callback_status:"stale_or_already_drained", iid:$iid, reply_iid:$reply_iid,
      chat_summary:("stale callback: reply iid=" + $reply_iid + " does not match callback iid #" + ($iid|tostring))}'
  exit 0
fi

# Attempt-number cross-check (Phase 6 validation rule 2).
REPLY_ATTEMPT="$(printf '%s' "${REPLY_JSON}" | jq -r '.attempt_number')"
if [ "${REPLY_ATTEMPT}" != "${PENDING_ATTEMPT}" ]; then
  jq -nc --argjson iid "${IID}" --arg att "${REPLY_ATTEMPT}" \
    '{callback_status:"stale_or_already_drained", iid:$iid, attempt_number:$att,
      chat_summary:("stale callback: reply attempt=" + ($att|tostring) + " does not match pending attempt for #" + ($iid|tostring))}'
  exit 0
fi

# Completion guard (Source-of-Truth). A stale/orphan callback for an earlier
# attempt can arrive after a later attempt already completed the issue (e.g.
# att1 killed out-of-band, att2 done, gateway restarted, att1's dead-session
# callback re-delivered while pending_subagents[IID] still holds att1 so the
# attempt-number cross-check above passes). Applying its regressing status would
# call phase6_sync_labels → set_issue_label.sh: a regressing `timeout`/`failed` /
# `blocked-*` maps to an `add` that STRIPS the live `pr` completion label via the
# workflow-label mutual-exclusion group (the keep-table never preserves `pr`).
# So if GitLab live labels already show this issue completed/closed, DROP the
# regressing reply without touching labels and drain the stale pending entry.
# `done` replies are never dropped (a success on a completed issue is idempotent).
REPLY_STATUS="$(printf '%s' "${REPLY_JSON}" | jq -r '.status')"
if [ "${REPLY_STATUS}" != "done" ] && [ -n "${RECON_EVIDENCE_PATH}" ] \
   && phase6_evidence_shows_completed "${IID}" "$(cat "${RECON_EVIDENCE_PATH}")"; then
  if [ "${INTERNAL_CLAIM_RECONCILE}" = 1 ] && [ "${IS_SCHEDULER_DRIVEN}" = true ]; then
    # A scheduler-owned running claim still needs its exact terminal I3 even
    # when GitLab already shows a completed/closed issue. Classify this as a
    # non-regressing `skipped` handoff instead of running Phase 6 label sync.
    # The pending claim digest was checked above; the importer independently
    # rechecks generation+token against active_jobs before releasing the slot.
    if [ "${COMPLETED_RECONCILE}" = 1 ]; then
      COMPLETED_REASON="GitLab live state already completed/closed during heartbeat completion reconciliation"
    else
      COMPLETED_REASON="GitLab live state already completed/closed during running-timeout reconciliation"
    fi
    COMPLETED_STATE="$(printf '%s' "${STATE_JSON}" | jq -c \
      --argjson iid "${IID}" --arg project "${PROJECT}" '
      .pending_subagents       = (.pending_subagents | del(.[($iid|tostring)]))
      | .active_issue_iids     = (.pending_subagents | keys | map(tonumber) | sort)
      | .active_issue_sessions = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))
      | if (.active_issue_iids | length) == 0 and .campaign_status == "waiting_for_callbacks"
        then .campaign_status = "running"
        else .
        end
    ')"
    COMPLETED_INTENT="$(phase6_build_driven_handoff_intent \
      "${PENDING_ENTRY}" "${IID}" "${REPLY_ATTEMPT}" \
      skipped "" "${COMPLETED_REASON}")"
    COMPLETED_EVENT_ID="$(jq -r '.handoff.event_id' <<<"${COMPLETED_INTENT}")"
    COMPLETED_STATE="$(phase6_put_driven_handoff_intent \
      "${COMPLETED_STATE}" "${COMPLETED_INTENT}")"
    persist_state "${COMPLETED_STATE}"
    if [ "${DRIVEN_HANDOFF_TEST_FAULT:-}" = crash_after_intent_persist ]; then
      wrapper_log followup \
        "live-completed handoff crash fault after intent persist iid=${IID} event_id=${COMPLETED_EVENT_ID}"
      exit 86
    fi

    COMPLETED_CLEANUP="$(phase6_decide_cleanup \
      "${COMPLETED_STATE}" "${IID}" skipped \
      "$(jq -r '.child_session_key // empty' <<<"${PENDING_ENTRY}")")"
    COMPLETED_REMAINING="$(jq -c '.pending_subagents | keys | map(tonumber)' \
      <<<"${COMPLETED_STATE}")"
    COMPLETED_CAMPAIGN_STATUS="$(jq -r '.campaign_status // "running"' \
      <<<"${COMPLETED_STATE}")"

    flock -u 9
    exec 9>&-
    set +e
    COMPLETED_DRAIN_OUT="$(drain_driven_handoff_event "${COMPLETED_EVENT_ID}" \
      2>>"${DISPATCHER_LOG_DIR}/wrapper.log")"
    COMPLETED_DRAIN_RC=$?
    set -e
    COMPLETED_DRAIN_RESULT=""
    if [ "${COMPLETED_DRAIN_RC}" -eq 0 ]; then
      COMPLETED_DRAIN_RESULT="$(jq -c --arg event_id "${COMPLETED_EVENT_ID}" \
        '.results[]? | select(.event_id == $event_id)' \
        <<<"${COMPLETED_DRAIN_OUT}" 2>/dev/null || true)"
    fi
    COMPLETED_HANDOFF_PATH=""
    COMPLETED_IMPORT_STATUS="pending"
    if [ -n "${COMPLETED_DRAIN_RESULT}" ]; then
      COMPLETED_HANDOFF_PATH="$(jq -r '.handoff_path // ""' \
        <<<"${COMPLETED_DRAIN_RESULT}")"
      case "$(jq -r '.status' <<<"${COMPLETED_DRAIN_RESULT}")" in
        imported|imported_cleanup_pending) COMPLETED_IMPORT_STATUS="imported" ;;
      esac
    fi
    wrapper_log followup \
      "live-completed handoff iid=${IID} event_id=${COMPLETED_EVENT_ID} import_status=${COMPLETED_IMPORT_STATUS} drain_rc=${COMPLETED_DRAIN_RC}"
    jq -nc \
      --argjson iid "${IID}" \
      --argjson attempt_number "${REPLY_ATTEMPT}" \
      --arg block_reason "${COMPLETED_REASON}" \
      --argjson cleanup "${COMPLETED_CLEANUP}" \
      --argjson remaining_pending_iids "${COMPLETED_REMAINING}" \
      --arg campaign_status "${COMPLETED_CAMPAIGN_STATUS}" \
      --arg handoff_path "${COMPLETED_HANDOFF_PATH}" \
      --arg handoff_import_status "${COMPLETED_IMPORT_STATUS}" '{
      callback_status:"handled",
      iid:$iid,
      attempt_number:$attempt_number,
      terminal_status:"skipped",
      merge_request_url:"",
      block_reason:$block_reason,
      cleanup:$cleanup,
      remaining_pending_iids:$remaining_pending_iids,
      campaign_status:$campaign_status,
      handoff_path:$handoff_path,
      handoff_import_status:$handoff_import_status,
      chat_summary:("#" + ($iid|tostring) + " skipped reason=" + $block_reason
        + " handoff_import=" + $handoff_import_status)
    }'
    exit 0
  fi

  DRAINED_STATE="$(printf '%s' "${STATE_JSON}" | jq -c --argjson iid "${IID}" --arg project "${PROJECT}" '
    .pending_subagents       = (.pending_subagents | del(.[($iid|tostring)]))
    | .active_issue_iids     = (.pending_subagents | keys | map(tonumber) | sort)
    | .active_issue_sessions = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))')"
  persist_state "${DRAINED_STATE}"
  wrapper_log followup "completed-ghost-drop iid=${IID} reply_status=${REPLY_STATUS}: GitLab live labels show completed/closed — dropped regressing callback without label change, drained pending"
  jq -nc --argjson iid "${IID}" --arg st "${REPLY_STATUS}" \
    '{callback_status:"stale_or_already_drained", iid:$iid, reply_status:$st,
      chat_summary:("stale callback: GitLab live labels show #" + ($iid|tostring) + " already completed/closed — dropped regressing " + $st + " reply without touching labels, drained pending")}'
  exit 0
fi

# Run Phase 6 inline.
PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "false")"

# Build the final envelope inputs before the one campaign-state transaction.
NEW_STATE="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
FINAL_STATUS="$(printf '%s' "${PHASE6_OUT}" | jq -r '.final_status')"
CLEANUP="$(printf '%s' "${PHASE6_OUT}" | jq -c '.cleanup')"
# A claim-fenced durable worker result means the fixed all-in-one wrapper
# finished even if OpenClaw never scheduled the outer model's final reply. The
# project result is now committed by Phase 6, so the still-live native child is
# pure leaked capacity and should be stopped. Ordinary native completions remain
# preserved for diagnosis by phase6_decide_cleanup.
if [ "${RESULT_RECONCILE}" = 1 ]; then
  RESULT_CHILD_SESSION_KEY="$(jq -r '.child_session_key // empty' <<<"${PENDING_ENTRY}")"
  if [ -n "${RESULT_CHILD_SESSION_KEY}" ]; then
    CLEANUP="$(jq -cn --arg target "${RESULT_CHILD_SESSION_KEY}" '{
      action:"kill",target:$target,reason:"durable_worker_result_recovered"
    }')"
  fi
fi
REMAINING_COUNT="$(printf '%s' "${PHASE6_OUT}" | jq -r '.remaining_pending_count')"
MR_URL="$(printf '%s' "${REPLY_JSON}" | jq -r '.merge_request_url // ""')"
WIKI_URL=""
CAMPAIGN_STATUS="$(printf '%s' "${NEW_STATE}" | jq -r '.campaign_status // "running"')"
if [ "${REMAINING_COUNT}" = "0" ] && [ "${CAMPAIGN_STATUS}" = "waiting_for_callbacks" ]; then
  CAMPAIGN_STATUS="running"
  NEW_STATE="$(printf '%s' "${NEW_STATE}" | jq -c '.campaign_status = "running"')"
fi
REMAINING_PENDING="$(printf '%s' "${NEW_STATE}" | jq -c '.pending_subagents | keys | map(tonumber)')"
BLOCK_REASON="$(printf '%s' "${REPLY_JSON}" | jq -r '.block_reason // ""')"

# Scheduler-driven terminal outcomes add the complete canonical physical-job
# handoff intent to the same atomic state write that drains pending. Thus every
# post-persist crash point retains job/claim identity even before the handoff
# file exists. Retryable `blocked` never creates an intent or releases the job.
HANDOFF_PATH=""
HANDOFF_IMPORT_STATUS=""
HANDOFF_INTENT=""
HANDOFF_EVENT_ID=""
if [ "${IS_SCHEDULER_DRIVEN}" = true ]; then
  case "${FINAL_STATUS}" in
    done|failed|timeout)
      HANDOFF_INTENT="$(phase6_build_driven_handoff_intent \
        "${PENDING_ENTRY}" "${IID}" "${REPLY_ATTEMPT}" \
        "${FINAL_STATUS}" "${MR_URL}" "${BLOCK_REASON}")"
      HANDOFF_EVENT_ID="$(jq -r '.handoff.event_id' <<<"${HANDOFF_INTENT}")"
      NEW_STATE="$(phase6_put_driven_handoff_intent \
        "${NEW_STATE}" "${HANDOFF_INTENT}")"
      ;;
  esac
fi

# This is the transaction commit: pending removal, terminal classification,
# campaign status, and the durable intent become visible together.
persist_state "${NEW_STATE}"

if [ -n "${HANDOFF_INTENT}" ]; then
  if [ "${DRIVEN_HANDOFF_TEST_FAULT:-}" = crash_after_intent_persist ]; then
    wrapper_log followup \
      "driven handoff crash fault injected after intent persist iid=${IID} event_id=${HANDOFF_EVENT_ID}"
    exit 86
  fi

  # Materialization and scheduler import are delegated to the reusable recovery
  # entry after releasing the project lock. Import failure is non-fatal because
  # both intent and any materialized handoff remain durable for callback replay
  # or an independent periodic drain.
  flock -u 9
  exec 9>&-
  set +e
  HANDOFF_DRAIN_OUT="$(drain_driven_handoff_event "${HANDOFF_EVENT_ID}" \
    2>>"${DISPATCHER_LOG_DIR}/wrapper.log")"
  HANDOFF_DRAIN_RC=$?
  set -e
  HANDOFF_DRAIN_RESULT=""
  if [ "${HANDOFF_DRAIN_RC}" -eq 0 ]; then
    HANDOFF_DRAIN_RESULT="$(jq -c --arg event_id "${HANDOFF_EVENT_ID}" \
      '.results[]? | select(.event_id == $event_id)' \
      <<<"${HANDOFF_DRAIN_OUT}" 2>/dev/null || true)"
  fi
  HANDOFF_IMPORT_STATUS="pending"
  if [ -n "${HANDOFF_DRAIN_RESULT}" ]; then
    HANDOFF_PATH="$(jq -r '.handoff_path // ""' <<<"${HANDOFF_DRAIN_RESULT}")"
    HANDOFF_DRAIN_STATUS="$(jq -r '.status' <<<"${HANDOFF_DRAIN_RESULT}")"
    case "${HANDOFF_DRAIN_STATUS}" in
      imported|imported_cleanup_pending)
        HANDOFF_IMPORT_STATUS="imported"
        ;;
    esac
  fi
  wrapper_log followup \
    "driven handoff drain iid=${IID} event_id=${HANDOFF_EVENT_ID} import_status=${HANDOFF_IMPORT_STATUS} drain_rc=${HANDOFF_DRAIN_RC} path=${HANDOFF_PATH:-pending}"
fi

CHAT_SUMMARY="#${IID} ${FINAL_STATUS}"
[ -n "${MR_URL}" ]       && CHAT_SUMMARY="${CHAT_SUMMARY} mr=${MR_URL}"
[ -n "${BLOCK_REASON}" ] && CHAT_SUMMARY="${CHAT_SUMMARY} reason=${BLOCK_REASON}"
CLEANUP_REASON="$(printf '%s' "${CLEANUP}" | jq -r '.reason')"
CLEANUP_ACTION="$(printf '%s' "${CLEANUP}" | jq -r '.action')"
CHAT_SUMMARY="${CHAT_SUMMARY} cleanup=${CLEANUP_ACTION}:${CLEANUP_REASON}"
[ -n "${HANDOFF_IMPORT_STATUS}" ] \
  && CHAT_SUMMARY="${CHAT_SUMMARY} handoff_import=${HANDOFF_IMPORT_STATUS}"

# Best-effort 结果回报，仅在终态 done/failed/timeout（never `blocked` —
# retryable, would re-post each attempt）。两条互斥路径，由本 issue 是否携带
# driven origin 决定：
#
#   • driven 路径（${ISSUE_ROOT}/dispatch_origin.json 存在且含 correlation_id +
#     dispatcher_callback_target）：req_dispatcher 经 RUN_SINGLE_ISSUE 派来的
#     单 issue 执行。把 final_status 经 I2 信封回投给 req_dispatcher
#     (notify_dispatcher.sh, A3)，并**跳过** post_result_note.sh —— driven 链路的
#     用户回投由 req_dispatcher 负责，不再走 git_issuer 的 req_origin/req_result
#     note 闭环（active-orchestration 设计稿 §I2 / docs/integration/result_notify_loop.md）。
#
#   • cron 路径（无 dispatch_origin.json）：保持原 result_note_enabled 门控的
#     req_result note 回报（result_notify_loop.md, option A）。
#
# Isolation（两条均比照旧 post_result_note 写法）：stdout → /dev/null（下面的
# envelope 是 LLM 的唯一 stdout），`set +e` 隔离使任一回报失败都 NEVER 中断
# Phase 6。notify_dispatcher.sh 通道未配置即 no-op；post_result_note.sh 在 issue
# 无 req_origin 标记时即 no-op。
#
# ISSUE_IID 未在本脚本 source env_paths.sh 时设置（callback 级只导出 dispatcher
# 级路径），所以 ISSUE_ROOT 未被导出 —— 这里按 ${ISSUES_ROOT}/issue-${IID} 内联派生，
# 与 dispatch_single_issue.sh 写入时使用的路径一致。
DISPATCH_ORIGIN_FILE="${ISSUES_ROOT}/issue-${IID}/dispatch_origin.json"
DRIVEN_CORRELATION_ID=""
DRIVEN_CALLBACK_TARGET=""
DRIVEN_PROJECT=""
if [ -f "${DISPATCH_ORIGIN_FILE}" ]; then
  DRIVEN_CORRELATION_ID="$(jq -r '.correlation_id // ""' "${DISPATCH_ORIGIN_FILE}" 2>/dev/null || true)"
  DRIVEN_CALLBACK_TARGET="$(jq -r '.dispatcher_callback_target // ""' "${DISPATCH_ORIGIN_FILE}" 2>/dev/null || true)"
  # dispatch_origin.json carries the FULL <group>/<project> name (dispatch_single_issue.sh),
  # which is the form the I2 envelope's `project` field must use — the callback-path
  # PROJECT env is only the bare slug.
  DRIVEN_PROJECT="$(jq -r '.project // ""' "${DISPATCH_ORIGIN_FILE}" 2>/dev/null || true)"
fi
# driven iff the origin file exists AND carries a non-empty correlation_id +
# dispatcher_callback_target. A truncated/未带 target 的 origin 退回 cron 语义。
IS_DRIVEN=false
if [ -n "${DRIVEN_CORRELATION_ID}" ] && [ -n "${DRIVEN_CALLBACK_TARGET}" ]; then
  IS_DRIVEN=true
fi

RESULT_NOTE_ENABLED="$(printf '%s' "${NEW_STATE}" | jq -r '.result_note_enabled // false')"
case "${FINAL_STATUS}" in
  done|failed|timeout)
    if [ "${IS_SCHEDULER_DRIVEN}" = true ]; then
      # Task6 batch callback is already durable in handoff/outbox. Never invoke
      # the legacy best-effort direct notifier for this path.
      :
    elif [ "${IS_DRIVEN}" = "true" ]; then
      # driven：回投 req_dispatcher（I2 信封），跳过 post_result_note。
      set +e
      CORRELATION_ID="${DRIVEN_CORRELATION_ID}" \
      DISPATCHER_CALLBACK_TARGET="${DRIVEN_CALLBACK_TARGET}" \
      IID="${IID}" STATUS="${FINAL_STATUS}" PROJECT="${DRIVEN_PROJECT:-${PROJECT}}" \
      MR_URL="${MR_URL}" WIKI_URL="${WIKI_URL}" REASON="${BLOCK_REASON}" \
      WORK_ROOT="${WORK_ROOT}" \
      bash "${SCRIPT_DIR}/notify_dispatcher.sh" >/dev/null 2>>"${DISPATCHER_LOG_DIR}/wrapper.log"
      ND_RC=$?
      set -e
      [ "${ND_RC}" -eq 0 ] || wrapper_log followup "notify-dispatcher best-effort rc=${ND_RC} iid=${IID} (non-fatal)"
    elif [ "${RESULT_NOTE_ENABLED}" = "true" ]; then
      # cron：原 req_origin/req_result note 回报。
      set +e
      PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
      REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
      IID="${IID}" ATTEMPT_NUMBER="${REPLY_ATTEMPT}" \
      FINAL_STATUS="${FINAL_STATUS}" MR_URL="${MR_URL}" WIKI_URL="${WIKI_URL}" BLOCK_REASON="${BLOCK_REASON}" \
      bash "${SCRIPT_DIR}/post_result_note.sh" >/dev/null 2>>"${DISPATCHER_LOG_DIR}/wrapper.log"
      RN_RC=$?
      set -e
      [ "${RN_RC}" -eq 0 ] || wrapper_log followup "result-note best-effort rc=${RN_RC} iid=${IID} (non-fatal)"
    fi
    ;;
esac

jq -nc \
  --argjson iid "${IID}" \
  --argjson attempt_number "${REPLY_ATTEMPT}" \
  --arg terminal_status "${FINAL_STATUS}" \
  --arg merge_request_url "${MR_URL}" \
  --arg block_reason "${BLOCK_REASON}" \
  --argjson cleanup "${CLEANUP}" \
  --argjson remaining_pending_iids "${REMAINING_PENDING}" \
  --arg campaign_status "${CAMPAIGN_STATUS}" \
  --arg handoff_path "${HANDOFF_PATH}" \
  --arg handoff_import_status "${HANDOFF_IMPORT_STATUS}" \
  --arg chat_summary "${CHAT_SUMMARY}" '
  {
    callback_status: "handled",
    iid: $iid,
    attempt_number: $attempt_number,
    terminal_status: $terminal_status,
    merge_request_url: $merge_request_url,
    block_reason: $block_reason,
    cleanup: $cleanup,
    remaining_pending_iids: $remaining_pending_iids,
    campaign_status: $campaign_status,
    chat_summary: $chat_summary
  }
  + (if $handoff_import_status == "" then {}
     else {
       handoff_path:$handoff_path,
       handoff_import_status:$handoff_import_status
     }
     end)'

wrapper_log followup "callback handled iid=${IID} attempt=${REPLY_ATTEMPT} final_status=${FINAL_STATUS} cleanup=${CLEANUP_ACTION}"
