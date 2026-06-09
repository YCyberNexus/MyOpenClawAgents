#!/usr/bin/env bash
# dispatch_followup.sh — Phase 6 wrapper for the callback path
# (RUN_CHILD_COMPLETION_CALLBACK).
#
# Replaces the SKILL.md prose for the callback wake-up. The orchestrator
# LLM calls this once per callback with:
#   - the subagent's compact JSON on stdin (worker_result_json payload)
#   - IID and (optionally) ATTEMPT_NUMBER / RUN_ID via env
#   - the standard dispatcher env (PROJECT, GROUP, GITLAB_TOKEN, plus
#     optional REPO_PARENT_PATH / RESULT_BASENAME / DATA_BASENAME)
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

# Acquire flock (non-blocking). The callback can safely retry later.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc --argjson iid "${IID}" \
    '{callback_status:"lock_held", iid:$iid, chat_summary:("lock_held on callback for #" + ($iid|tostring))}'
  exit 0
fi

wrapper_log followup "callback received iid=${IID} attempt=${ATTEMPT_NUMBER:-?}"

# Resolved, configuration-driven model tier list (ordered, comma-separated)
# read straight from the persisted campaign state so the narrow reconcile maps
# model:{tier} labels against the SAME list the prepare tick used. Defaults to
# "flash,pro,max" when the state file is absent or has no override.
MODEL_TIERS_CSV="$(
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    jq -r '(.model_tiers // ["flash","pro","max"]) | join(",")' "${CAMPAIGN_STATE_FILE}" 2>/dev/null
  fi
)"
[ -z "${MODEL_TIERS_CSV}" ] && MODEL_TIERS_CSV="flash,pro,max"

# Narrow reconcile must map model:{tier} labels against the EFFECTIVE ladder
# (tiers whose <tier>-settings.json exist), identical to what the prepare tick
# used — otherwise the cached integer model_tier would drift between paths.
# model_settings_dir is read from the same persisted state (already path-validated
# at the prepare entry before it was persisted; here it only feeds the read-only
# `[ -r <tier>-settings.json ]` probe inside derive_effective_model_tiers — never
# a cp / exec — so it is intentionally not re-validated. Anyone later reusing
# this value for a cp/exec-class op MUST re-validate). empty → effective equals
# full. On the callback path an empty effective (should not happen for an IID
# that was actually spawned) falls back to full rather than aborting, since this
# narrow reconcile is best-effort.
MODEL_SETTINGS_DIR_FU="$(
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    jq -r '.model_settings_dir // empty' "${CAMPAIGN_STATE_FILE}" 2>/dev/null
  fi
)"
EFFECTIVE_TIERS_CSV="$(derive_effective_model_tiers "${MODEL_TIERS_CSV}" "${MODEL_SETTINGS_DIR_FU}")"
[ -z "${EFFECTIVE_TIERS_CSV}" ] && EFFECTIVE_TIERS_CSV="${MODEL_TIERS_CSV}"

# Phase 6 step 0 — narrow reconcile (best-effort; failure does NOT abort).
# The GitLab live state is consulted again so any reviewer relabel between
# spawn and callback (e.g. continue → reviewer-rejected → blocked) gets
# picked up at terminal-write time.
if ! PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
        REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
        RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" \
        MODEL_TIERS="${EFFECTIVE_TIERS_CSV}" \
        MIN_IID="${IID}" MAX_IID="${IID}" \
        bash "${SCRIPT_DIR}/reconcile.sh" >/dev/null 2>&1; then
  wrapper_log followup "narrow reconcile failed for iid=${IID}; proceeding with cached labels"
fi

# Load campaign state.
STATE_JSON="$(load_state)"

# Lookup the pending entry.
PENDING_ENTRY="$(printf '%s' "${STATE_JSON}" | jq -c --argjson iid "${IID}" '.pending_subagents[($iid|tostring)] // null')"
if [ "${PENDING_ENTRY}" = "null" ]; then
  jq -nc --argjson iid "${IID}" --argjson att "${ATTEMPT_NUMBER:-0}" \
    '{callback_status:"stale_or_already_drained", iid:$iid, attempt_number:$att,
      chat_summary:("stale callback: no pending entry for #" + ($iid|tostring))}'
  exit 0
fi

PENDING_ATTEMPT="$(printf '%s' "${PENDING_ENTRY}" | jq -r '.attempt_number')"

# Read the compact reply from stdin. Empty stdin → synthesize blocked.
# A callback arrived but carried no usable compact reply. Per the v2 decision
# this is attributed to the DISPATCHER side (an empty payload is an
# orchestration/transport anomaly, not a Claude-Code work outcome), so it
# defaults to block_side "dispatcher" → blocked-dispatcher and does NOT feed
# the model-upgrade path.
RAW_REPLY="$(cat)"
if [ -z "${RAW_REPLY//[$' \t\r\n']/}" ]; then
  REPLY_JSON="$(phase6_synthesize_blocked "${IID}" "${PENDING_ATTEMPT}" \
    "callback worker_result_json was empty")"
else
  REPLY_JSON="$(phase6_normalize_reply "${RAW_REPLY}" "${IID}" "${PENDING_ATTEMPT}")"
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

# Run Phase 6 inline.
PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "false")"

# Persist updated campaign state.
NEW_STATE="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
persist_state "${NEW_STATE}"

# Build the chat-visible envelope.
FINAL_STATUS="$(printf '%s' "${PHASE6_OUT}" | jq -r '.final_status')"
CLEANUP="$(printf '%s' "${PHASE6_OUT}" | jq -c '.cleanup')"
REMAINING_COUNT="$(printf '%s' "${PHASE6_OUT}" | jq -r '.remaining_pending_count')"
MR_URL="$(printf '%s' "${REPLY_JSON}" | jq -r '.merge_request_url // ""')"
CAMPAIGN_STATUS="$(printf '%s' "${NEW_STATE}" | jq -r '.campaign_status // "running"')"
if [ "${REMAINING_COUNT}" = "0" ] && [ "${CAMPAIGN_STATUS}" = "waiting_for_callbacks" ]; then
  CAMPAIGN_STATUS="running"
  NEW_STATE="$(printf '%s' "${NEW_STATE}" | jq -c '.campaign_status = "running"')"
  persist_state "${NEW_STATE}"
fi
REMAINING_PENDING="$(printf '%s' "${NEW_STATE}" | jq -c '.pending_subagents | keys | map(tonumber)')"
BLOCK_REASON="$(printf '%s' "${REPLY_JSON}" | jq -r '.block_reason // ""')"

CHAT_SUMMARY="#${IID} ${FINAL_STATUS}"
[ -n "${MR_URL}" ]       && CHAT_SUMMARY="${CHAT_SUMMARY} mr=${MR_URL}"
[ -n "${BLOCK_REASON}" ] && CHAT_SUMMARY="${CHAT_SUMMARY} reason=${BLOCK_REASON}"
CLEANUP_REASON="$(printf '%s' "${CLEANUP}" | jq -r '.reason')"
CLEANUP_ACTION="$(printf '%s' "${CLEANUP}" | jq -r '.action')"
CHAT_SUMMARY="${CHAT_SUMMARY} cleanup=${CLEANUP_ACTION}:${CLEANUP_REASON}"

jq -nc \
  --argjson iid "${IID}" \
  --argjson attempt_number "${REPLY_ATTEMPT}" \
  --arg terminal_status "${FINAL_STATUS}" \
  --arg merge_request_url "${MR_URL}" \
  --arg block_reason "${BLOCK_REASON}" \
  --argjson cleanup "${CLEANUP}" \
  --argjson remaining_pending_iids "${REMAINING_PENDING}" \
  --arg campaign_status "${CAMPAIGN_STATUS}" \
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
  }'

wrapper_log followup "callback handled iid=${IID} attempt=${REPLY_ATTEMPT} final_status=${FINAL_STATUS} cleanup=${CLEANUP_ACTION}"
