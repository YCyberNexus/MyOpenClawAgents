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
#   iso_to_epoch <iso8601>       → epoch seconds (0 when unparseable)
#   phase6_synthesize_reply <iid> <attempt_number> <status> <block_reason>
#                                → emit a synthetic compact reply JSON (status=blocked|timeout)
#   phase6_synthesize_blocked <iid> <attempt_number> <block_reason>
#                                → phase6_synthesize_reply with status=blocked
#   phase6_synthesize_timeout <iid> <attempt_number> <block_reason>
#                                → phase6_synthesize_reply with status=timeout
#   phase6_normalize_reply <reply_json> <ctx_iid> <ctx_attempt> [synth_status]
#                                → validated + normalized reply JSON; synth_status
#                                  (default blocked) is used when the raw reply is
#                                  unparseable or carries no status field
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

# Parse an ISO-8601 UTC timestamp into epoch seconds. Echoes 0 when the
# input is empty / null / unparseable so callers can branch on `-gt 0`.
iso_to_epoch() {
  local ts="$1"
  if [ -z "${ts}" ] || [ "${ts}" = "null" ]; then
    echo 0
    return 0
  fi
  date -u -d "${ts}" +%s 2>/dev/null || gdate -u -d "${ts}" +%s 2>/dev/null || echo 0
}

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

# Self-heal the executable bit on every file under scripts/safety_bin/.
# Some deployment pipelines (rsync without -p, zip/tar extraction under a
# restrictive umask, git clones with core.fileMode=false) strip the mode
# bit when shipping this workspace to the runner. run_acpx_attempt.sh
# asserts `[ -x safety_bin/rm ]` before invoking acpx — when the assertion
# fails the attempt exits 2 in FAIL flow before any business logic runs.
# Restoring the bit here keeps the no-fallback rule intact at the business
# layer while preventing a deployment-side regression from blocking every
# subagent. No-op when files are already executable (steady state).
ensure_safety_bin_executable() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local safety_bin="${lib_dir}/safety_bin"
  [ -d "${safety_bin}" ] || return 0
  local f
  for f in "${safety_bin}"/*; do
    # Skip symlinks: chmod without -h follows the link and would touch a
    # target outside safety_bin/. Today the dir holds only regular files;
    # this is forward-defense for future contributors.
    if [ ! -f "${f}" ] || [ -L "${f}" ]; then
      continue
    fi
    [ -x "${f}" ] && continue
    if chmod +x "${f}" 2>/dev/null; then
      wrapper_log dispatch_bootstrap "self-heal: chmod +x ${f} (deployment dropped mode bit)"
    else
      wrapper_log dispatch_bootstrap "self-heal failed: chmod +x ${f} returned non-zero"
    fi
  done
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
    --arg ui_accounts_relpath "${UI_ACCOUNTS_RELPATH}" \
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
      stuck_after_minutes: 332,
      run_timeout_seconds: 18120,
      acpx_timeout_seconds: 18000,
      kill_subagent_on_terminal: true,
      kill_subagent_on_done: true,
      result_note_enabled: false,
      issue_iids_whitelist: [],
      require_labels: [],
      require_labels_match: "or",
      result_basename: $result_basename,
      data_basename: $data_basename,
      ui_accounts_relpath: $ui_accounts_relpath,
      model_tiers: null,
      continue_upgrade_threshold: 2,
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

# Emit a synthetic compact reply. status MUST be blocked or timeout:
# `blocked` re-enters the retry pool; `timeout` parks the IID in
# timeout_iids with no auto-retry (只要超时就不重试 — see SKILL.md
# §Timeout-shaped synthesized replies).
phase6_synthesize_reply() {
  local iid="$1" attempt_number="$2" status="$3" block_reason="$4"
  case "${status}" in
    blocked|timeout) ;;
    *) status="blocked" ;;
  esac
  jq -n \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt_number}" \
    --arg status "${status}" \
    --arg block_reason "${block_reason}" \
    '{
      iid: $iid,
      attempt_number: $attempt_number,
      status: $status,
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
      log_dir: "",
      block_side: "dispatcher"
    }'
}

phase6_synthesize_blocked() {
  phase6_synthesize_reply "$1" "$2" blocked "$3"
}

phase6_synthesize_timeout() {
  phase6_synthesize_reply "$1" "$2" timeout "$3"
}

# phase6_evidence_shows_completed <iid> <evidence_json>
# Pure check (NO GitLab call): returns 0 (true) iff the reconcile evidence array
# in <evidence_json> marks <iid> as already in a GitLab-completed/closed terminal
# state. Tolerant of both label vocabularies — v2 `pr` via has_done_pr /
# is_done_on_gitlab, benchmark-test `done` via is_done_on_gitlab — and of missing
# fields (null → false). This is the Source-of-Truth guard: a completed/closed
# issue must NEVER be regressed to timeout/blocked/failed by a stale earlier
# attempt's late callback or stuck-eviction. (needs_continue is intentionally NOT
# excluded here — a `pr`+`continue` issue must also be protected from a stale
# regression; §11 reconcile correction still routes it to continue afterwards.)
phase6_evidence_shows_completed() {
  local iid="$1" evidence_json="$2"
  [ -n "${evidence_json}" ] || return 1
  printf '%s' "${evidence_json}" | jq -e --argjson iid "${iid}" '
    (type == "array") and any(.[];
      (.iid == $iid) and (
        (.is_closed_on_gitlab == true)
        or (.is_done_on_gitlab == true)
        or (.has_done_pr == true)))' >/dev/null 2>&1
}

# phase6_iid_completed_live <iid>
# Best-effort: narrowly reconcile ONE iid against GitLab live labels (reconcile.sh
# is the only sanctioned GitLab access path; it self-auths via env_paths.sh) and
# return 0 (true) iff it is already completed/closed. On ANY failure (reconcile
# error, missing/malformed evidence) returns 1 (false) so the caller proceeds with
# its normal eviction/regression — the stuck-eviction backstop stays live even
# when GitLab is unreachable; the guard only suppresses a regression when fresh
# ground truth is actually available.
phase6_iid_completed_live() {
  local iid="$1"
  local script_dir out ev_path ev_json
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  out="$(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
        REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
        RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" \
        MIN_IID="${iid}" MAX_IID="${iid}" \
        bash "${script_dir}/reconcile.sh" 2>/dev/null)" || return 1
  ev_path="$(printf '%s' "${out}" | grep -E '^/.+/reconcile-[0-9TZ]+\.json$' | tail -n 1)" || return 1
  [ -n "${ev_path}" ] && [ -f "${ev_path}" ] || return 1
  ev_json="$(cat "${ev_path}")" || return 1
  phase6_evidence_shows_completed "${iid}" "${ev_json}"
}

# Validate the compact reply per state_schema.md §Compact Subagent Reply.
# Inputs:
#   $1 = the reply JSON (raw text — may be invalid JSON)
#   $2 = expected iid (from pending entry)
#   $3 = expected attempt_number (from pending entry)
#   $4 = synth_status (optional, default "blocked"): the status used when the
#        raw reply is unparseable or carries no status field. The caller passes
#        "timeout" when the run already outlived its acpx wall-clock budget, so
#        a dead subagent's garbled/empty terminal payload parks the IID as
#        timeout (no auto-retry) instead of re-entering the blocked retry pool.
#        A parseable reply with an explicit status keeps that status — a live
#        subagent's own verdict always wins.
# Output (stdout): a normalized JSON object (always valid; synthesized on
# parse failure / iid mismatch). The orchestrator's "drop stale callback"
# check happens BEFORE this — by the time the caller gets here, the IID
# is known to match a pending entry.
phase6_normalize_reply() {
  local raw="$1" exp_iid="$2" exp_attempt="$3" synth_status="${4:-blocked}"
  case "${synth_status}" in
    blocked|timeout) ;;
    *) synth_status="blocked" ;;
  esac
  local parsed
  if ! parsed="$(printf '%s' "${raw}" | jq -c . 2>/dev/null)"; then
    local first200
    # Codepoint-safe truncation (jq raw-input slice): a byte-wise `head -c 200`
    # could split a multibyte UTF-8 char and leave a dangling byte. jq -Rs reads
    # the (possibly non-JSON) raw as one string, replacing any invalid bytes with
    # U+FFFD, then slices by codepoint and flattens CR/LF for a one-line reason.
    first200="$(printf '%s' "${raw}" | jq -Rsr '.[0:200] | gsub("\\r";"") | gsub("\\n";" ")' 2>/dev/null || printf '%s' "${raw}" | head -c 200 | tr -d '\r' | tr '\n' ' ')"
    phase6_synthesize_reply "${exp_iid}" "${exp_attempt}" "${synth_status}" \
      "callback worker_result_json not valid JSON: ${first200}"
    return 0
  fi
  # Normalize: tolerate null/empty fields, normalize legacy no_changes,
  # require non-empty block_reason for blocked/failed/timeout.
  printf '%s' "${parsed}" | jq -c \
    --argjson exp_iid "${exp_iid}" \
    --argjson exp_attempt "${exp_attempt}" \
    --arg synth_status "${synth_status}" '
    def s: if . == null then "" else . end;
    def a: if . == null then [] else . end;
    {
      iid: (.iid // $exp_iid),
      attempt_number: (.attempt_number // $exp_attempt),
      status: (.status // $synth_status),
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
      log_dir: (.log_dir | s),
      block_side: "cc"
    }
    | .status as $st
    | if (($st | type) != "string")
         or ((["done","no_changes","blocked","failed","timeout"] | index($st)) == null) then
        # Status present but empty/garbage — the subagent did not author a
        # usable verdict, so this is a dead-subagent shape like a missing
        # status: coerce to synth_status (timeout when the run outlived its
        # budget) instead of letting phase6_sync_labels reject it and the
        # sync-failure path demote it to retryable blocked.
        .status = $synth_status
        | .block_side = "dispatcher"
        | (if (.block_reason | length) == 0 then
             .block_reason = ("subagent reply carried unsupported status " + ($st | tostring) + " — coerced to " + $synth_status)
           else . end)
      else . end
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
#         $3=block_side (cc|dispatcher, 默认 dispatcher) — selects
#            blocked-cc/blocked-dispatcher and failed-cc/failed-dispatcher.
# Returns: 0 on success, non-zero with stderr if any required op fails.
phase6_sync_labels() {
  local iid="$1" final_status="$2" block_side="${3:-dispatcher}"
  case "${block_side}" in cc|dispatcher) ;; *) block_side="dispatcher" ;; esac
  local rc=0
  case "${final_status}" in
    done)
      # C: pr 替换 done —— 终态只留 pr。
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove blocked-cc         || rc=$?
      _label_op "${iid}" remove blocked-dispatcher || rc=$?
      _label_op "${iid}" remove failed-cc          || rc=$?
      _label_op "${iid}" remove failed-dispatcher  || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" remove timeout            || rc=$?
      _label_op "${iid}" add pr                    || rc=$?
      _label_op "${iid}" remove done               || rc=$?
      ;;
    blocked)
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove timeout            || rc=$?
      _label_op "${iid}" remove failed-cc          || rc=$?
      _label_op "${iid}" remove failed-dispatcher  || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      if [ "${block_side}" = "cc" ]; then
        _label_op "${iid}" remove blocked-dispatcher || rc=$?
        _label_op "${iid}" add blocked-cc            || rc=$?
      else
        _label_op "${iid}" remove blocked-cc         || rc=$?
        _label_op "${iid}" add blocked-dispatcher    || rc=$?
      fi
      ;;
    failed)
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove blocked-cc         || rc=$?
      _label_op "${iid}" remove blocked-dispatcher || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" remove timeout            || rc=$?
      if [ "${block_side}" = "cc" ]; then
        _label_op "${iid}" remove failed-dispatcher || rc=$?
        _label_op "${iid}" add failed-cc            || rc=$?
      else
        _label_op "${iid}" remove failed-cc         || rc=$?
        _label_op "${iid}" add failed-dispatcher    || rc=$?
      fi
      ;;
    timeout)
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove blocked-cc         || rc=$?
      _label_op "${iid}" remove blocked-dispatcher || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      _label_op "${iid}" remove failed-cc          || rc=$?
      _label_op "${iid}" remove failed-dispatcher  || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" add timeout               || rc=$?
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
        prior_issue_state="$5" is_launch_synth="$6" block_side="${7:-}"

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
    --arg block_side "${block_side}" \
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
        block_reason: (if ($reply.block_reason // "") == "" then null else $reply.block_reason end),
        block_side: (if ($final_status == "blocked" or $final_status == "failed") and ($block_side != "") then $block_side else null end)
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
    --arg block_side "${block_side}" \
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
        updated_at: $now,
        block_side: (if ($final_status == "blocked" or $final_status == "failed") and ($block_side != "") then $block_side else ($prior.block_side // null) end)
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
  local block_side
  block_side="$(printf '%s' "${reply_json}" | jq -r '.block_side // "dispatcher"')"

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
  if ! _err="$(phase6_sync_labels "${iid}" "${final_status}" "${block_side}" 2>&1 >/dev/null)"; then
    label_err="${_err}"
    if [ "${final_status}" = "timeout" ]; then
      reply_json="$(printf '%s' "${reply_json}" | jq -c \
        --arg le "phase6 label sync failed: ${label_err}" '
        (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
      ')"
      # best-effort timeout sync — leaves issue without `doing` removal in worst case,
      # but the dispatcher refuses to spawn for an IID in timeout_iids on the next tick,
      # so no parallel acpx can start regardless. The lingering `doing` also keeps
      # reconcile's user_reopened false (reconcile.sh excludes live `doing`), so the
      # live-label correction cannot silently un-park the cached timeout either.
      phase6_sync_labels "${iid}" timeout >/dev/null 2>&1 || true
    elif [ "${final_status}" != "failed" ]; then
      final_status="blocked"
      block_side="dispatcher"
      # append to block_reason
      reply_json="$(printf '%s' "${reply_json}" | jq -c \
        --arg le "phase6 label sync failed: ${label_err}" '
        .status = "blocked"
        | .block_side = "dispatcher"
        | (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
      ')"
      # best-effort blocked sync
      phase6_sync_labels "${iid}" blocked "dispatcher" >/dev/null 2>&1 || true
    fi
  fi

  # Write per-issue state files (computes new retry_count).
  local prior_issue_state
  prior_issue_state="$(phase6_read_prior_issue_state "${iid}")"
  local new_retry_count blocked_retry_limit
  new_retry_count="$(phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
    "${final_status}" "${prior_issue_state}" "${is_launch_synth}" "${block_side}")"

  # Promote blocked → failed if retry_count > blocked_retry_limit.
  blocked_retry_limit="$(printf '%s' "${state_json}" | jq -r '.blocked_retry_limit // 0')"
  if [ "${final_status}" = "blocked" ] && [ "${is_launch_synth}" != "true" ] \
     && [ "${new_retry_count}" -gt "${blocked_retry_limit}" ]; then
    final_status="failed"
    phase6_sync_labels "${iid}" failed "${block_side}" >/dev/null 2>&1 || true
    # rewrite issue state with final_status=failed (retry_count already incremented)
    phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
      "${final_status}" "${prior_issue_state}" "${is_launch_synth}" "${block_side}" >/dev/null
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
