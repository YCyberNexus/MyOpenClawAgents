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

# Phase 6 step 0 — narrow reconcile (best-effort; failure does NOT abort).
# The GitLab live state is consulted again so any reviewer relabel between
# spawn and callback (e.g. continue → reviewer-rejected → blocked) gets
# picked up at terminal-write time.
# Capture the narrow reconcile's evidence path so the completion guard below can
# consult fresh GitLab live labels before any regressing terminal write.
RECON_EVIDENCE_PATH=""
set +e
RECON_OUT="$(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
        REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
        RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" \
        MIN_IID="${IID}" MAX_IID="${IID}" \
        bash "${SCRIPT_DIR}/reconcile.sh" 2>/dev/null)"
RECON_RC=$?
set -e
if [ "${RECON_RC}" -ne 0 ]; then
  wrapper_log followup "narrow reconcile failed for iid=${IID}; proceeding with cached labels"
else
  RECON_EVIDENCE_PATH="$(printf '%s' "${RECON_OUT}" | grep -E '^/.+/reconcile-[0-9TZ]+\.json$' | tail -n 1 || true)"
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

# Synthesized-reply status for a dead subagent (empty / unparseable /
# status-less worker_result_json). 只要超时就不重试: when the run already
# outlived its acpx wall-clock budget (elapsed since spawned_at ≥
# acpx_timeout_seconds - 60s slack for ack-timestamp skew), the
# termination is timeout-shaped — the runtime's runTimeoutSeconds kill or
# a death inside the subagent's own timeout flow — so the IID is parked
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
[ -n "${ACPX_TIMEOUT_S}" ] || ACPX_TIMEOUT_S="$(printf '%s' "${STATE_JSON}" | jq -r '.acpx_timeout_seconds // 18000')"
SP_EPOCH="$(iso_to_epoch "$(printf '%s' "${PENDING_ENTRY}" | jq -r '.spawned_at // ""')")"
if [ "${SP_EPOCH}" -gt 0 ]; then
  ELAPSED_S=$(( $(date -u +%s) - SP_EPOCH ))
  TIMEOUT_FLOOR_S=$(( ACPX_TIMEOUT_S - 60 ))
  [ "${TIMEOUT_FLOOR_S}" -lt 0 ] && TIMEOUT_FLOOR_S=0
  if [ "${ELAPSED_S}" -ge "${TIMEOUT_FLOOR_S}" ]; then
    SYNTH_STATUS="timeout"
  fi
fi

# Read the compact reply from stdin. Empty stdin → synthesize a terminal
# reply: timeout when the run consumed its time budget, blocked otherwise.
RAW_REPLY="$(cat)"
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

# Persist updated campaign state.
NEW_STATE="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
persist_state "${NEW_STATE}"

# Build the chat-visible envelope.
FINAL_STATUS="$(printf '%s' "${PHASE6_OUT}" | jq -r '.final_status')"
CLEANUP="$(printf '%s' "${PHASE6_OUT}" | jq -c '.cleanup')"
REMAINING_COUNT="$(printf '%s' "${PHASE6_OUT}" | jq -r '.remaining_pending_count')"
MR_URL="$(printf '%s' "${REPLY_JSON}" | jq -r '.merge_request_url // ""')"
WIKI_URL="$(printf '%s' "${REPLY_JSON}" | jq -r '.wiki_url // ""')"
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

# Best-effort 测试结果回报，仅在终态 done/failed/timeout（never `blocked` —
# retryable, would re-post each attempt）。两条互斥路径，由本 issue 是否携带
# driven origin 决定：
#
#   • driven 路径（${ISSUE_ROOT}/dispatch_origin.json 存在且含 correlation_id +
#     dispatcher_callback_target）：req_dispatcher 经 RUN_SINGLE_ISSUE_TEST 派来的
#     单 issue 测试。把 final_status 经 I2 信封回投给 req_dispatcher
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
    if [ "${IS_DRIVEN}" = "true" ]; then
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
      RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" \
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
