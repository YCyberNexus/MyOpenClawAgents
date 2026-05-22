#!/usr/bin/env bash
# _dispatch_lib.sh — shared helpers for the dispatcher wrappers
# (dispatch_prepare_tick.sh, dispatch_record_spawn.sh, dispatch_followup.sh).
#
# This file is SOURCED, not executed. It assumes the caller has already
# sourced env_paths.sh so dispatcher-level vars (CAMPAIGN_STATE_FILE,
# DISPATCHER_LOG_DIR, ISSUES_ROOT, LOCK_FILE, GITLAB_HOST, etc.) and
# project handles (PROJECT_FULL, PROJECT_URI) are exported. It also
# assumes the caller holds the dispatcher flock — none of these helpers
# acquire or release locks.
#
# Functions exported:
#   utc_now                      → ISO-8601 Z timestamp string
#   atomic_write_json <path>     ← reads JSON from stdin, atomic mv
#   load_state                   → cat CAMPAIGN_STATE_FILE (or fresh init)
#   wrapper_log <phase> <msg...> → append to dispatcher log
#   phase6_synthesize_blocked <iid> <attempt_number> <block_reason>
#                                → emit a synthetic compact reply JSON
#   phase6_normalize_reply <reply_json> <ctx_iid> <ctx_attempt>
#                                → validated + normalized reply JSON
#   phase6_sync_labels <iid> <final_status>
#                                → run set_issue_label.sh ops; echo any append-on-failure text
#   phase6_write_state_files <iid> <attempt_number> <reply_json> <final_status>
#                                                  <prior_state_json> <prior_retry_count>
#                                                  <is_launch_synth>
#                                → writes ATTEMPT_STATE_FILE + ISSUE_STATE_FILE atomically;
#                                  prints the new retry_count on stdout (one line)
#   phase6_apply_state_classify <state_json> <iid> <final_status> <child_session_key>
#                                → echoes updated campaign_state JSON; the caller atomically writes it
#   phase6_decide_cleanup <state_json> <iid> <final_status> <child_session_key>
#                                → echoes cleanup decision JSON {action,target,reason}
#
# All helpers print only what they document; debugging goes to stderr
# (which the wrappers tee into the wrapper log file).

set -euo pipefail

: "${CAMPAIGN_STATE_FILE:?_dispatch_lib.sh: env_paths.sh must be sourced first}"
: "${PROJECT_URI:?_dispatch_lib.sh: env_paths.sh must be sourced first (PROJECT_URI missing)}"
: "${ISSUES_ROOT:?_dispatch_lib.sh: env_paths.sh must be sourced first (ISSUES_ROOT missing)}"

# ─── Generic helpers ───────────────────────────────────────────────

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

atomic_write_json() {
  local target="$1"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat >"${tmp}"
  mv -f "${tmp}" "${target}"
}

wrapper_log() {
  local phase="$1"; shift
  local ts="$(utc_now)"
  mkdir -p "${DISPATCHER_LOG_DIR}"
  printf '[%s] [%s] %s\n' "${ts}" "${phase}" "$*" >>"${DISPATCHER_LOG_DIR}/wrapper.log"
}

load_state() {
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    cat "${CAMPAIGN_STATE_FILE}"
  else
    fresh_init_state
  fi
}

fresh_init_state() {
  jq -n \
    --arg project "${PROJECT}" \
    --arg repo_path "${REPO_PARENT_PATH}" \
    --arg result_basename "${RESULT_BASENAME}" \
    --arg data_basename "${DATA_BASENAME}" \
    '{
      project: $project,
      repo_path: $repo_path,
      branch: null,
      issue_min_iid: null,
      issue_max_iid: null,
      hourly_issue_quota: null,
      max_runtime_minutes: null,
      blocked_retry_limit: null,
      blocked_cooldown_ticks: null,
      max_concurrent_subagents: 1,
      max_accounts_per_issue: 14,
      stuck_after_minutes: 330,
      run_timeout_seconds: 18120,
      acpx_timeout_seconds: 18000,
      kill_subagent_on_terminal: true,
      kill_subagent_on_done: true,
      issue_iids_whitelist: [],
      require_labels: [],
      require_labels_match: "or",
      result_basename: $result_basename,
      data_basename: $data_basename,
      next_new_issue_iid: null,
      tick_seq: 0,
      active_issue_iids: [],
      active_issue_sessions: [],
      pending_subagents: {},
      blocked_at_tick_by_iid: {},
      unfinished_iids: [],
      completed_iids: [],
      blocked_iids: [],
      failed_iids: [],
      timeout_iids: [],
      campaign_status: "running",
      quota_launched_this_tick: 0,
      last_reconcile_evidence: null,
      updated_at: null
    }'
}

# Persist a state JSON object to CAMPAIGN_STATE_FILE, stamping updated_at.
persist_state() {
  local state_json="$1"
  local ts
  ts="$(utc_now)"
  printf '%s' "${state_json}" | jq --arg ts "${ts}" '.updated_at = $ts' \
    | atomic_write_json "${CAMPAIGN_STATE_FILE}"
}

# ─── Phase 6 helpers ───────────────────────────────────────────────

phase6_synthesize_blocked() {
  local iid="$1" attempt_number="$2" block_reason="$3"
  jq -n \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt_number}" \
    --arg block_reason "${block_reason}" \
    '{
      iid: $iid,
      attempt_number: $attempt_number,
      status: "blocked",
      mode_actual: "",
      work_branch: "",
      local_branch: "",
      commit_sha: "",
      merge_request_url: "",
      mr_action: "none",
      wiki_url: "",
      labels_added: [],
      labels_removed: [],
      summary_posted: false,
      block_reason: $block_reason,
      log_dir: ""
    }'
}

# Validate the compact reply per state_schema.md §Compact Subagent Reply.
# Inputs:
#   $1 = the reply JSON (raw text — may be invalid JSON)
#   $2 = expected iid (from pending entry)
#   $3 = expected attempt_number (from pending entry)
# Output (stdout): a normalized JSON object (always valid; synthesized on
# parse failure / iid mismatch). The orchestrator's "drop stale callback"
# check happens BEFORE this — by the time the caller gets here, the IID
# is known to match a pending entry.
phase6_normalize_reply() {
  local raw="$1" exp_iid="$2" exp_attempt="$3"
  local parsed
  if ! parsed="$(printf '%s' "${raw}" | jq -c . 2>/dev/null)"; then
    local first200
    first200="$(printf '%s' "${raw}" | head -c 200 | tr -d '\r' | tr '\n' ' ')"
    phase6_synthesize_blocked "${exp_iid}" "${exp_attempt}" \
      "callback worker_result_json not valid JSON: ${first200}"
    return 0
  fi
  # Normalize: tolerate null/empty fields, normalize legacy no_changes,
  # require non-empty block_reason for blocked/failed/timeout.
  printf '%s' "${parsed}" | jq -c \
    --argjson exp_iid "${exp_iid}" \
    --argjson exp_attempt "${exp_attempt}" '
    def s: if . == null then "" else . end;
    def a: if . == null then [] else . end;
    {
      iid: (.iid // $exp_iid),
      attempt_number: (.attempt_number // $exp_attempt),
      status: (.status // "blocked"),
      mode_actual: (.mode_actual | s),
      work_branch: (.work_branch | s),
      local_branch: (.local_branch | s),
      commit_sha: (.commit_sha | s),
      merge_request_url: (.merge_request_url | s),
      mr_action: (.mr_action // "none"),
      wiki_url: (.wiki_url | s),
      labels_added: (.labels_added | a),
      labels_removed: (.labels_removed | a),
      summary_posted: (.summary_posted // false),
      block_reason: (.block_reason | s),
      log_dir: (.log_dir | s)
    }
    | if .status == "no_changes" then
        .status = "blocked"
        | (if (.block_reason | length) == 0 then .block_reason = "subagent produced no staged changes" else . end)
      else . end
    | if ((.status == "blocked" or .status == "failed" or .status == "timeout") and (.block_reason | length) == 0) then
        .block_reason = ("subagent reply status=" + .status + " with empty block_reason")
      else . end
  '
}

# Synchronize live workflow labels via set_issue_label.sh.
# Inputs: $1=iid, $2=final_status (done|blocked|failed|timeout)
# Returns: 0 on success, non-zero with stderr if any required op fails.
phase6_sync_labels() {
  local iid="$1" final_status="$2"
  local rc=0
  case "${final_status}" in
    done)
      _label_op "${iid}" remove doing   || rc=$?
      _label_op "${iid}" remove blocked || rc=$?
      _label_op "${iid}" remove failed  || rc=$?
      _label_op "${iid}" remove timeout || rc=$?
      _label_op "${iid}" add done       || rc=$?
      _label_op "${iid}" add pr         || rc=$?
      ;;
    blocked)
      _label_op "${iid}" remove doing   || rc=$?
      _label_op "${iid}" remove timeout || rc=$?
      _label_op "${iid}" add blocked    || rc=$?
      ;;
    failed)
      _label_op "${iid}" remove doing   || rc=$?
      _label_op "${iid}" remove blocked || rc=$?
      _label_op "${iid}" remove timeout || rc=$?
      _label_op "${iid}" add failed     || rc=$?
      ;;
    timeout)
      _label_op "${iid}" remove doing   || rc=$?
      _label_op "${iid}" remove blocked || rc=$?
      _label_op "${iid}" remove failed  || rc=$?
      _label_op "${iid}" add timeout    || rc=$?
      ;;
    *)
      echo "phase6_sync_labels: unsupported final_status=${final_status}" >&2
      return 2
      ;;
  esac
  return ${rc}
}

_label_op() {
  local iid="$1" op="$2" lbl="$3"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # ATTEMPT_NUMBER=1 is a placeholder — env_paths.sh requires the var
  # when ISSUE_IID is set, but set_issue_label.sh itself never reads any
  # attempt-scoped path (it only touches the GitLab issue label set).
  PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
    REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
    RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" \
    ISSUE_IID="${iid}" ATTEMPT_NUMBER=1 \
    bash "${script_dir}/set_issue_label.sh" "${op}" "${lbl}"
}

# Read prior issue state.json (if it exists) and echo it as JSON, or "{}".
phase6_read_prior_issue_state() {
  local iid="$1"
  local f="${ISSUES_ROOT}/issue-${iid}/state.json"
  if [ -f "${f}" ]; then cat "${f}"; else echo '{}'; fi
}

# Write the terminal ATTEMPT_STATE_FILE + ISSUE_STATE_FILE for a given
# (iid, attempt_number) pair. Caller passes the validated reply JSON and
# the final status (after label sync + retry promotion).
#
# Inputs (positional):
#   $1 = iid
#   $2 = attempt_number
#   $3 = reply JSON (normalized)
#   $4 = final_status
#   $5 = prior issue state JSON (or "{}")
#   $6 = is_launch_synth ("true" | "false") — when "true", retry_count is
#         preserved (launch-side failures don't consume retry budget).
#
# Side effects: rewrites ATTEMPT_STATE_FILE + ISSUE_STATE_FILE atomically.
# Stdout: a single line with the new retry_count (so the caller can persist
# campaign-level classification with the same value).
phase6_write_state_files() {
  local iid="$1" attempt_number="$2" reply="$3" final_status="$4" \
        prior_issue_state="$5" is_launch_synth="$6"

  local issue_root="${ISSUES_ROOT}/issue-${iid}"
  local attempt_padded
  attempt_padded="$(printf '%03d' "${attempt_number}")"
  local attempt_dir="${issue_root}"
  local attempt_state_file="${attempt_dir}/attempt_state.json"
  local issue_state_file="${issue_root}/state.json"
  local summary_file="${attempt_dir}/summary.md"

  mkdir -p "${issue_root}"

  local now
  now="$(utc_now)"

  # Compute retry_count. `timeout` is terminal-but-not-failed and DOES NOT
  # consume retry budget — it stays parked until a human strips the label.
  local prior_retry_count
  prior_retry_count="$(printf '%s' "${prior_issue_state}" | jq -r '.retry_count // 0')"
  local new_retry_count="${prior_retry_count}"
  if [ "${is_launch_synth}" != "true" ] && { [ "${final_status}" = "blocked" ] || [ "${final_status}" = "failed" ]; }; then
    new_retry_count=$((prior_retry_count + 1))
  fi

  # ─── ATTEMPT_STATE_FILE ───
  local prior_attempt_state='{}'
  if [ -f "${attempt_state_file}" ]; then
    prior_attempt_state="$(cat "${attempt_state_file}")"
  fi
  local summary_exists=false
  [ -f "${summary_file}" ] && summary_exists=true

  local new_attempt_state
  new_attempt_state="$(printf '%s' "${prior_attempt_state}" | jq \
    --arg now "${now}" \
    --arg final_status "${final_status}" \
    --arg summary_file "${summary_file}" \
    --argjson summary_exists "${summary_exists}" \
    --argjson reply "${reply}" \
    '
    . as $prior
    | $prior
    + {
        status: $final_status,
        attempt_finished_at: $now,
        commit_sha: (if $reply.commit_sha == "" then null else $reply.commit_sha end),
        wiki_artifacts_file: (if $reply.wiki_url == "" then null else (($prior.log_dir // "") + "/wiki_artifacts.md") end),
        attempt_artifacts_posted_to_wiki: ($reply.wiki_url != ""),
        summary_file: (if $summary_exists then $summary_file else null end),
        summary_posted_to_issue: ($reply.summary_posted // false),
        block_reason: (if ($reply.block_reason // "") == "" then null else $reply.block_reason end)
      }
    ')"
  printf '%s' "${new_attempt_state}" | atomic_write_json "${attempt_state_file}"

  # ─── ISSUE_STATE_FILE ───
  local new_issue_state
  new_issue_state="$(printf '%s' "${prior_issue_state}" | jq \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt_number}" \
    --arg now "${now}" \
    --arg final_status "${final_status}" \
    --arg issue_root "${issue_root}" \
    --argjson new_retry_count "${new_retry_count}" \
    --argjson reply "${reply}" \
    '
    . as $prior
    | $prior
    + {
        iid: $iid,
        session: ($prior.session // ("issue-" + ($iid|tostring))),
        status: $final_status,
        mode: $reply.mode_actual,
        attempts_total: (if ($prior.attempts_total // 0) >= $attempt_number then $prior.attempts_total else $attempt_number end),
        latest_attempt_number: $attempt_number,
        latest_attempt_dir: $issue_root,
        retry_count: $new_retry_count,
        block_reason: (if ($reply.block_reason // "") == "" then null else $reply.block_reason end),
        commit_sha: (if $reply.commit_sha == "" then null else $reply.commit_sha end),
        merge_request_url: (if $reply.merge_request_url == "" then null else $reply.merge_request_url end),
        updated_at: $now
      }
    ')"
  printf '%s' "${new_issue_state}" | atomic_write_json "${issue_state_file}"

  echo "${new_retry_count}"
}

# Update the in-memory campaign state JSON: drain pending entry + classify.
# Inputs:
#   $1 = current state JSON
#   $2 = iid
#   $3 = final_status (done|blocked|failed|timeout)
# Output: the updated state JSON on stdout.
# Caller persists.
#
# active_issue_sessions is rebuilt from the post-drain active_issue_iids
# using the canonical `issue-<project>-<iid>` format (per state_schema.md
# §active_issue_iids / active_issue_sessions semantics). This avoids the
# substring trap of regex-filtering by IID suffix (IID 14 vs 114).
#
# `timeout` lands in `timeout_iids` and is NOT added to `unfinished_iids`,
# so the dispatcher does NOT auto-retry it. A human reviewer strips the
# `timeout`, adds `retry`, or applies `continue` to re-enqueue.
phase6_apply_state_classify() {
  local state_json="$1" iid="$2" final_status="$3"
  printf '%s' "${state_json}" | jq -c \
    --argjson iid "${iid}" \
    --arg final_status "${final_status}" \
    --arg project "${PROJECT}" '
    . as $s
    | .pending_subagents        = ($s.pending_subagents        | del(.[($iid|tostring)]))
    | .active_issue_iids        = (.pending_subagents | keys | map(tonumber) | sort)
    | .active_issue_sessions    = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))
    | (if $final_status == "done" then
         .completed_iids    = (((.completed_iids // []) + [$iid]) | unique)
         | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {}) | del(.[($iid|tostring)]))
         | .unfinished_iids = ((.unfinished_iids // []) | map(select(. != $iid)))
         | .blocked_iids    = ((.blocked_iids    // []) | map(select(. != $iid)))
         | .failed_iids     = ((.failed_iids     // []) | map(select(. != $iid)))
         | .timeout_iids    = ((.timeout_iids    // []) | map(select(. != $iid)))
         | .quota_completed_this_tick = (((.quota_completed_this_tick // 0)) + 1)
       elif $final_status == "blocked" then
         .blocked_iids      = (((.blocked_iids   // []) + [$iid]) | unique)
         | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {}) + {($iid|tostring): (.tick_seq // 0)})
         | .unfinished_iids = (((.unfinished_iids // []) + [$iid]) | unique)
         | .completed_iids  = ((.completed_iids // []) | map(select(. != $iid)))
         | .failed_iids     = ((.failed_iids    // []) | map(select(. != $iid)))
         | .timeout_iids    = ((.timeout_iids   // []) | map(select(. != $iid)))
       elif $final_status == "timeout" then
         .timeout_iids      = (((.timeout_iids   // []) + [$iid]) | unique)
         | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {}) | del(.[($iid|tostring)]))
         | .unfinished_iids = ((.unfinished_iids // []) | map(select(. != $iid)))
         | .completed_iids  = ((.completed_iids // []) | map(select(. != $iid)))
         | .blocked_iids    = ((.blocked_iids   // []) | map(select(. != $iid)))
         | .failed_iids     = ((.failed_iids    // []) | map(select(. != $iid)))
       else
         .failed_iids       = (((.failed_iids    // []) + [$iid]) | unique)
         | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {}) | del(.[($iid|tostring)]))
         | .unfinished_iids = ((.unfinished_iids // []) | map(select(. != $iid)))
         | .blocked_iids    = ((.blocked_iids    // []) | map(select(. != $iid)))
         | .completed_iids  = ((.completed_iids  // []) | map(select(. != $iid)))
         | .timeout_iids    = ((.timeout_iids    // []) | map(select(. != $iid)))
       end)
  '
}

# Decide whether to call `subagents kill` for this terminal entry.
# Returns a one-line cleanup-decision JSON to stdout.
#   {"action":"kill"|"skip","target":"<key>","reason":"<text>"}
# Caller (LLM) is responsible for actually invoking the runtime kill tool
# when action == "kill" — the wrapper cannot.
phase6_decide_cleanup() {
  local state_json="$1" iid="$2" final_status="$3" child_session_key="$4"

  local issue_root="${ISSUES_ROOT}/issue-${iid}"
  local issue_state_file="${issue_root}/state.json"
  local attempt_state_file="${issue_root}/attempt_state.json"
  local summary_file="${issue_root}/summary.md"

  local kill_setting
  kill_setting="$(printf '%s' "${state_json}" | jq -r '
    if (.kill_subagent_on_terminal // null) != null then
      .kill_subagent_on_terminal
    else
      ((.kill_subagent_on_done // true) and true)
    end')"

  if [ "${kill_setting}" != "true" ]; then
    jq -n --arg target "${child_session_key}" \
      '{action:"skip", target:$target, reason:"cleanup_disabled"}'
    return 0
  fi
  if [ -z "${child_session_key}" ] || [ "${child_session_key}" = "null" ]; then
    jq -n '{action:"skip", target:"", reason:"no_child_session_key"}'
    return 0
  fi

  # Local-evidence gate for non-done outcomes.
  if [ "${final_status}" = "blocked" ] || [ "${final_status}" = "failed" ] || [ "${final_status}" = "timeout" ]; then
    if [ ! -f "${issue_state_file}" ] || [ ! -f "${attempt_state_file}" ] || [ ! -f "${summary_file}" ]; then
      jq -n --arg target "${child_session_key}" \
        '{action:"skip", target:$target, reason:"local_evidence_missing"}'
      return 0
    fi
  fi

  jq -n --arg target "${child_session_key}" \
    '{action:"kill", target:$target, reason:"terminal_cleanup"}'
}

# All-in-one Phase 6 processor. Reads the validated reply, syncs labels,
# writes terminal state files, applies state classification, decides
# cleanup, persists campaign state. Does NOT touch the flock.
#
# Inputs (positional):
#   $1 = current state JSON (typically: load_state output already mutated upstream)
#   $2 = reply JSON (normalized)
#   $3 = is_launch_synth ("true"|"false")
# Output (stdout): one-line JSON envelope:
#   {"final_status":"...","cleanup":{...},"remaining_pending_count":N,"updated_state":<json>}
phase6_process() {
  local state_json="$1" reply_json="$2" is_launch_synth="$3"
  local iid attempt_number reply_status
  iid="$(printf '%s' "${reply_json}" | jq -r '.iid')"
  attempt_number="$(printf '%s' "${reply_json}" | jq -r '.attempt_number')"
  reply_status="$(printf '%s' "${reply_json}" | jq -r '.status')"

  # Capture child_session_key BEFORE drain.
  local child_session_key
  child_session_key="$(printf '%s' "${state_json}" \
    | jq -r --argjson iid "${iid}" '.pending_subagents[($iid|tostring)].child_session_key // ""')"

  # Sync labels for the preliminary status. On sync failure:
  #   - `failed`  → keep `failed` (retry-budget exhaustion is sticky).
  #   - `timeout` → keep `timeout` (terminal, no retry; only append diagnostic
  #                 to block_reason and retry the sync best-effort once).
  #   - else      → demote to `blocked` (the historical safety net for
  #                 transient GitLab API failures on done/blocked outcomes).
  local label_err=""
  local final_status="${reply_status}"
  local _err=""
  if ! _err="$(phase6_sync_labels "${iid}" "${final_status}" 2>&1 >/dev/null)"; then
    label_err="${_err}"
    if [ "${final_status}" = "timeout" ]; then
      reply_json="$(printf '%s' "${reply_json}" | jq -c \
        --arg le "phase6 label sync failed: ${label_err}" '
        (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
      ')"
      # best-effort timeout sync — leaves issue without `doing` removal in worst case,
      # but the dispatcher refuses to spawn for an IID in timeout_iids on the next tick,
      # so no parallel acpx can start regardless.
      phase6_sync_labels "${iid}" timeout >/dev/null 2>&1 || true
    elif [ "${final_status}" != "failed" ]; then
      final_status="blocked"
      # append to block_reason
      reply_json="$(printf '%s' "${reply_json}" | jq -c \
        --arg le "phase6 label sync failed: ${label_err}" '
        .status = "blocked"
        | (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
      ')"
      # best-effort blocked sync
      phase6_sync_labels "${iid}" blocked >/dev/null 2>&1 || true
    fi
  fi

  # Write per-issue state files (computes new retry_count).
  local prior_issue_state
  prior_issue_state="$(phase6_read_prior_issue_state "${iid}")"
  local new_retry_count blocked_retry_limit
  new_retry_count="$(phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
    "${final_status}" "${prior_issue_state}" "${is_launch_synth}")"

  # Promote blocked → failed if retry_count > blocked_retry_limit.
  blocked_retry_limit="$(printf '%s' "${state_json}" | jq -r '.blocked_retry_limit // 0')"
  if [ "${final_status}" = "blocked" ] && [ "${is_launch_synth}" != "true" ] \
     && [ "${new_retry_count}" -gt "${blocked_retry_limit}" ]; then
    final_status="failed"
    phase6_sync_labels "${iid}" failed >/dev/null 2>&1 || true
    # rewrite issue state with final_status=failed (retry_count already incremented)
    phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
      "${final_status}" "${prior_issue_state}" "${is_launch_synth}" >/dev/null
  fi

  # Apply campaign-state classification + drain.
  local updated_state
  updated_state="$(phase6_apply_state_classify "${state_json}" "${iid}" "${final_status}")"

  # Decide cleanup.
  local cleanup
  cleanup="$(phase6_decide_cleanup "${updated_state}" "${iid}" "${final_status}" "${child_session_key}")"

  local remaining_pending_count
  remaining_pending_count="$(printf '%s' "${updated_state}" | jq -r '.pending_subagents | keys | length')"

  jq -nc \
    --arg final_status "${final_status}" \
    --argjson cleanup "${cleanup}" \
    --argjson remaining_pending_count "${remaining_pending_count}" \
    --argjson updated_state "${updated_state}" '
    {
      final_status: $final_status,
      cleanup: $cleanup,
      remaining_pending_count: $remaining_pending_count,
      updated_state: $updated_state
    }'
}
