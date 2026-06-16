#!/usr/bin/env bash
# dispatch_record_spawn.sh — record a sessions_spawn outcome for one IID.
#
# Called by the orchestrator LLM after each sessions_spawn attempt. Two
# modes, selected by the STATUS env var:
#
#   STATUS=spawned     — valid launch ack. Update pending_subagents[iid]
#                        with run_id, child_session_key, spawned_at; drop
#                        the placeholder flag.
#   STATUS=launch_failed — all 3 launch retries exhausted. Synthesize a
#                        blocked Phase 6 reply (via the shared library)
#                        with the verbatim last error, write terminal
#                        state files, drain pending entry, and classify
#                        as blocked WITHOUT incrementing retry_count
#                        (launch-side failures don't consume the cross-
#                        tick retry budget; the IID gets its reschedule
#                        for free via blocked_iids).
#
# Required env:
#   PROJECT, GROUP, GITLAB_TOKEN, IID, ATTEMPT_NUMBER, STATUS
#   When STATUS=spawned:        RUN_ID, CHILD_SESSION_KEY
#   When STATUS=launch_failed:  LAUNCH_ATTEMPTS (default 3), LAUNCH_ERROR
# Optional (forwarded when non-default deployment):
#   REPO_PARENT_PATH, RESULT_BASENAME, DATA_BASENAME
#
# Stdout: one-line JSON envelope describing the recorded outcome:
#   {"status":"spawned|launch_failed_recorded", "iid":N, "attempt_number":N,
#    "remaining_pending_count":N, "cleanup":{...} (only for launch_failed),
#    "chat_summary":"..."}
#
# Exit codes:
#   0 — recorded successfully (state mutated)
#   2 — invalid input (missing env, unknown STATUS, etc.)
#   3 — flock could not be acquired (caller should retry on next tick)
#
# Notes:
#   - This script does NOT itself call sessions_spawn. The LLM owns that.
#   - For STATUS=launch_failed, the cleanup decision will normally be
#     {action:"skip", reason:"no_child_session_key"} because the failed
#     launch never produced a usable child_session_key.

set -euo pipefail

: "${PROJECT:?dispatch_record_spawn.sh: PROJECT must be set}"
: "${GROUP:?dispatch_record_spawn.sh: GROUP must be set}"
: "${GITLAB_TOKEN:?dispatch_record_spawn.sh: GITLAB_TOKEN must be set}"
: "${IID:?dispatch_record_spawn.sh: IID must be set}"
: "${ATTEMPT_NUMBER:?dispatch_record_spawn.sh: ATTEMPT_NUMBER must be set}"
: "${STATUS:?dispatch_record_spawn.sh: STATUS must be set (spawned|launch_failed)}"

case "${IID}" in *[!0-9]*|"") echo "dispatch_record_spawn.sh: IID must be a positive integer" >&2; exit 2 ;; esac
case "${ATTEMPT_NUMBER}" in *[!0-9]*|"") echo "dispatch_record_spawn.sh: ATTEMPT_NUMBER must be a positive integer" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc --argjson iid "${IID}" \
    '{status:"lock_held", iid:$iid, chat_summary:"lock_held while recording spawn (retry on next callback or next tick)"}'
  exit 3
fi

STATE_JSON="$(load_state)"
PENDING="$(printf '%s' "${STATE_JSON}" | jq -c --argjson iid "${IID}" '.pending_subagents[($iid|tostring)] // null')"
if [ "${PENDING}" = "null" ]; then
  echo "dispatch_record_spawn.sh: no pending entry for iid=${IID} — refusing to record" >&2
  exit 2
fi
PENDING_ATTEMPT="$(printf '%s' "${PENDING}" | jq -r '.attempt_number')"
if [ "${PENDING_ATTEMPT}" != "${ATTEMPT_NUMBER}" ]; then
  echo "dispatch_record_spawn.sh: attempt_number mismatch (pending=${PENDING_ATTEMPT} caller=${ATTEMPT_NUMBER})" >&2
  exit 2
fi

scrub_spawn_payload() {
  local attempt_padded glob_base payload_file any nullglob_prev
  attempt_padded="$(printf '%03d' "${ATTEMPT_NUMBER}")"
  # LOG_DIR now carries the pinned model tier as a `-<tier>` suffix
  # (env_paths.sh: log/attempt-NNN-<tier>/), so the payload that
  # dispatch_prepare_tick.sh wrote lives under the tier-suffixed dir. This
  # script does NOT source the per-issue env_paths layer (it uses IID, not
  # ISSUE_IID, and the tier is not in its required env), so match by prefix
  # instead of hardcoding the old bare `attempt-NNN` name: the glob covers the
  # tier-suffixed dir AND any legacy bare dir (or an attempt spawned just
  # before this change deployed). The spawn payload holds the GitLab token in
  # cleartext until this scrub runs, so missing the path would be a
  # token-exposure regression — prefix-matching keeps the scrub robust without
  # needing to know the tier here.
  glob_base="${WORKTREES_ROOT}/issue-${IID}/${RESULT_BASENAME}/issue-${IID}/log/attempt-${attempt_padded}"
  any=false
  # Save and restore the caller's nullglob state rather than blindly disabling
  # it — nullglob must be ON so a no-match glob expands to nothing (instead of
  # the literal pattern, which `: >` would then create as a stray file), but we
  # leave the shell option set exactly as we found it.
  nullglob_prev="$(shopt -p nullglob)"
  shopt -s nullglob
  for payload_file in "${glob_base}"/spawn_payload.txt "${glob_base}"-*/spawn_payload.txt; do
    any=true
    : >"${payload_file}" 2>/dev/null \
      && wrapper_log record_spawn "scrubbed spawn payload iid=${IID} (${payload_file})" \
      || wrapper_log record_spawn "warn: could not scrub spawn payload at ${payload_file}"
  done
  eval "${nullglob_prev}"
  [ "${any}" = true ] || wrapper_log record_spawn "no spawn payload found to scrub iid=${IID} attempt=${attempt_padded}"
}

case "${STATUS}" in
  spawned)
    : "${RUN_ID:?dispatch_record_spawn.sh: RUN_ID required for STATUS=spawned}"
    : "${CHILD_SESSION_KEY:?dispatch_record_spawn.sh: CHILD_SESSION_KEY required for STATUS=spawned}"
    NOW="$(utc_now)"
    NEW_STATE="$(printf '%s' "${STATE_JSON}" | jq -c \
      --argjson iid "${IID}" \
      --arg run_id "${RUN_ID}" \
      --arg child_session_key "${CHILD_SESSION_KEY}" \
      --arg now "${NOW}" '
      .pending_subagents[($iid|tostring)] = (
        .pending_subagents[($iid|tostring)]
        + {run_id:$run_id, child_session_key:$child_session_key, spawned_at:$now}
        | del(.placeholder)
      )
      | .quota_launched_this_tick = ((.quota_launched_this_tick // 0) + 1)
      | .campaign_status = "waiting_for_callbacks"
    ')"
    persist_state "${NEW_STATE}"
    REMAINING="$(printf '%s' "${NEW_STATE}" | jq -r '.pending_subagents | keys | length')"

    # The file holds the GitLab token in cleartext until the launch outcome is
    # recorded. Best-effort: failure is logged but does not fail writeback.
    scrub_spawn_payload

    wrapper_log record_spawn "spawned iid=${IID} attempt=${ATTEMPT_NUMBER} run_id=${RUN_ID}"
    jq -nc \
      --argjson iid "${IID}" \
      --argjson att "${ATTEMPT_NUMBER}" \
      --argjson remaining "${REMAINING}" \
      --arg chat "spawned #${IID} att=${ATTEMPT_NUMBER}" '
      {status:"spawned", iid:$iid, attempt_number:$att,
       remaining_pending_count:$remaining, chat_summary:$chat}'
    ;;
  launch_failed)
    : "${LAUNCH_ERROR:=unspecified}"
    : "${LAUNCH_ATTEMPTS:=3}"
    BLOCK_REASON="sessions_spawn failed after ${LAUNCH_ATTEMPTS} attempts (2s backoff): ${LAUNCH_ERROR}"
    REPLY_JSON="$(phase6_synthesize_blocked "${IID}" "${ATTEMPT_NUMBER}" "${BLOCK_REASON}")"
    scrub_spawn_payload

    # Run Phase 6 with is_launch_synth=true so retry_count is NOT incremented.
    PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "true")"
    NEW_STATE="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
    persist_state "${NEW_STATE}"

    FINAL_STATUS="$(printf '%s' "${PHASE6_OUT}" | jq -r '.final_status')"
    CLEANUP="$(printf '%s' "${PHASE6_OUT}" | jq -c '.cleanup')"
    REMAINING="$(printf '%s' "${PHASE6_OUT}" | jq -r '.remaining_pending_count')"

    wrapper_log record_spawn "launch_failed iid=${IID} attempt=${ATTEMPT_NUMBER} attempts=${LAUNCH_ATTEMPTS} err=${LAUNCH_ERROR}"

    jq -nc \
      --argjson iid "${IID}" \
      --argjson att "${ATTEMPT_NUMBER}" \
      --arg final_status "${FINAL_STATUS}" \
      --argjson cleanup "${CLEANUP}" \
      --argjson remaining "${REMAINING}" \
      --arg chat "launch_failed #${IID} att=${ATTEMPT_NUMBER} attempts=${LAUNCH_ATTEMPTS} → blocked" '
      {status:"launch_failed_recorded", iid:$iid, attempt_number:$att,
       final_status:$final_status, cleanup:$cleanup,
       remaining_pending_count:$remaining, chat_summary:$chat}'
    ;;
  *)
    echo "dispatch_record_spawn.sh: unknown STATUS=${STATUS} (want spawned|launch_failed)" >&2
    exit 2
    ;;
esac
