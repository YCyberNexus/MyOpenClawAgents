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
#   phase6_synthesize_blocked <iid> <attempt_number> <block_reason> [block_side]
#                                → emit a synthetic compact reply JSON
#                                  (block_side defaults to "dispatcher"; pass
#                                   "cc" for real subagent callbacks)
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
      issue_iids_whitelist: [],
      require_labels: [],
      require_labels_match: "or",
      model_tiers: ["flash", "pro", "max"],
      model_upgrade_continue_threshold: 0,
      result_basename: $result_basename,
      data_basename: $data_basename,
      ui_accounts_relpath: $ui_accounts_relpath,
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

# Synthesize a blocked reply. The 4th arg (block_side) selects the side:
#   - "dispatcher" (default): DISPATCHER-SIDE failure (prep failure, spawn
#     launch failure, scope/stuck eviction). No subagent ever ran acpx, so the
#     model-upgrade decision excludes it. Maps to the `blocked-dispatcher`
#     workflow label (promotes to `failed-dispatcher` on retry exhaustion).
#   - "cc": a REAL subagent callback that already spawned and ran acpx but
#     returned an empty / unparseable compact reply. Per §4, real callbacks are
#     CC-side, so they map to `blocked-cc` (promotes to `failed-cc`) and DO feed
#     the model-upgrade path — "subagent ran but failed / produced no usable
#     output" is exactly the scenario the upgrade is meant to cover.
# The `block_side` field is read by phase6_process to pick the side.
phase6_synthesize_blocked() {
  local iid="$1" attempt_number="$2" block_reason="$3" block_side="${4:-dispatcher}"
  # Guard against typos in callers: anything other than "cc" maps to dispatcher.
  if [ "${block_side}" != "cc" ]; then
    block_side="dispatcher"
  fi
  jq -n \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt_number}" \
    --arg block_reason "${block_reason}" \
    --arg block_side "${block_side}" \
    '{
      iid: $iid,
      attempt_number: $attempt_number,
      status: "blocked",
      block_side: $block_side,
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
    # Codepoint-safe truncation (jq raw-input slice): a byte-wise `head -c 200`
    # could split a multibyte UTF-8 char and leave a dangling byte. jq -Rs reads
    # the (possibly non-JSON) raw as one string, replacing any invalid bytes with
    # U+FFFD, then slices by codepoint and flattens CR/LF for a one-line reason.
    first200="$(printf '%s' "${raw}" | jq -Rsr '.[0:200] | gsub("\\r";"") | gsub("\\n";" ")' 2>/dev/null || printf '%s' "${raw}" | head -c 200 | tr -d '\r' | tr '\n' ' ')"
    # A callback arrived but its compact reply is unparseable. Per the v2
    # decision this is attributed to the DISPATCHER side (an unusable payload
    # is an orchestration/transport anomaly, not a Claude-Code work failure),
    # so it defaults to block_side "dispatcher" → blocked-dispatcher. A
    # *parseable* reply (normalized below) still defaults to CC-side.
    phase6_synthesize_blocked "${exp_iid}" "${exp_attempt}" \
      "callback worker_result_json not valid JSON: ${first200}"
    return 0
  fi
  # Normalize: tolerate null/empty fields, normalize legacy no_changes,
  # require non-empty block_reason for blocked/failed/timeout.
  #
  # v2: a real subagent reply is always a Claude-Code-side outcome (the
  # subagent ran acpx and/or its post-acpx steps), so its blocked/failed
  # outcomes are CC-side. We stamp `block_side: "cc"` here unless the reply
  # explicitly carries a side (forward-compat). The dispatcher-side
  # `block_side: "dispatcher"` is only ever produced by
  # phase6_synthesize_blocked.
  printf '%s' "${parsed}" | jq -c \
    --argjson exp_iid "${exp_iid}" \
    --argjson exp_attempt "${exp_attempt}" '
    def s: if . == null then "" else . end;
    def a: if . == null then [] else . end;
    {
      iid: (.iid // $exp_iid),
      attempt_number: (.attempt_number // $exp_attempt),
      status: (.status // "blocked"),
      block_side: (if (.block_side // "") == "dispatcher" then "dispatcher" else "cc" end),
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
# Inputs: $1=iid, $2=final_status — one of the v2 internal terminal states:
#   done | blocked_cc | blocked_dispatcher | failed_cc | failed_dispatcher | timeout
# Returns: 0 on success, non-zero with stderr if any required op fails.
#
# `set_issue_label.sh add <workflow-label>` already removes the rest of the
# workflow mutual-exclusion group in the same GitLab update (and never touches
# the orthogonal model:{tier} / quality:low dimensions), so each branch only
# needs the single `add` plus a defensive `remove doing` to guarantee the
# transient `doing` label is gone. v2: `add pr` removes `done`, so a `done`
# outcome ends carrying ONLY `pr` (pr replaces done).
phase6_sync_labels() {
  local iid="$1" final_status="$2"
  local rc=0
  case "${final_status}" in
    done)
      # pr replaces done: add pr last so the issue ends with only `pr`.
      _label_op "${iid}" remove doing || rc=$?
      _label_op "${iid}" add pr       || rc=$?
      ;;
    blocked_cc)
      _label_op "${iid}" remove doing       || rc=$?
      _label_op "${iid}" add blocked-cc     || rc=$?
      ;;
    blocked_dispatcher)
      _label_op "${iid}" remove doing            || rc=$?
      _label_op "${iid}" add blocked-dispatcher  || rc=$?
      ;;
    failed_cc)
      _label_op "${iid}" remove doing     || rc=$?
      _label_op "${iid}" add failed-cc    || rc=$?
      ;;
    failed_dispatcher)
      _label_op "${iid}" remove doing            || rc=$?
      _label_op "${iid}" add failed-dispatcher   || rc=$?
      ;;
    timeout)
      _label_op "${iid}" remove doing || rc=$?
      _label_op "${iid}" add timeout  || rc=$?
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
  # v2: every blocked/failed side variant (blocked_cc / blocked_dispatcher /
  # failed_cc / failed_dispatcher) consumes the budget except launch-side synth.
  local prior_retry_count
  prior_retry_count="$(printf '%s' "${prior_issue_state}" | jq -r '.retry_count // 0')"
  local new_retry_count="${prior_retry_count}"
  if [ "${is_launch_synth}" != "true" ]; then
    case "${final_status}" in
      blocked_cc|blocked_dispatcher|failed_cc|failed_dispatcher)
        new_retry_count=$((prior_retry_count + 1))
        ;;
    esac
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
#   $3 = final_status — v2 internal terminal state:
#        done | blocked_cc | blocked_dispatcher | failed_cc | failed_dispatcher | timeout
# Output: the updated state JSON on stdout.
# Caller persists.
#
# active_issue_sessions is rebuilt from the post-drain active_issue_iids
# using the canonical `issue-<project>-<iid>` format (per state_schema.md
# §active_issue_iids / active_issue_sessions semantics). This avoids the
# substring trap of regex-filtering by IID suffix (IID 14 vs 114).
#
# The campaign-level `blocked_iids` / `failed_iids` lists are side-agnostic
# unions: both `*_cc` and `*_dispatcher` outcomes land in the same list, since
# batch scheduling only cares whether an IID is blocked-and-retryable or
# terminally-failed regardless of which side produced it. The side only drives
# the live label (`blocked-cc` vs `blocked-dispatcher`) and the model-upgrade
# decision in PREPARE.
#
# `timeout` lands in `timeout_iids` and is NOT added to `unfinished_iids`,
# so the dispatcher does NOT auto-retry it. A human reviewer strips the
# `timeout`, adds `retry`, or applies `continue` to re-enqueue.
phase6_apply_state_classify() {
  local state_json="$1" iid="$2" final_status="$3"
  # Collapse the side variants into the campaign-list bucket.
  local bucket
  case "${final_status}" in
    done)                              bucket="done" ;;
    blocked_cc|blocked_dispatcher)     bucket="blocked" ;;
    failed_cc|failed_dispatcher)       bucket="failed" ;;
    timeout)                           bucket="timeout" ;;
    *)                                 bucket="failed" ;;
  esac
  printf '%s' "${state_json}" | jq -c \
    --argjson iid "${iid}" \
    --arg bucket "${bucket}" \
    --arg project "${PROJECT}" '
    . as $s
    | .pending_subagents        = ($s.pending_subagents        | del(.[($iid|tostring)]))
    | .active_issue_iids        = (.pending_subagents | keys | map(tonumber) | sort)
    | .active_issue_sessions    = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))
    | (if $bucket == "done" then
         .completed_iids    = (((.completed_iids // []) + [$iid]) | unique)
         | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {}) | del(.[($iid|tostring)]))
         | .unfinished_iids = ((.unfinished_iids // []) | map(select(. != $iid)))
         | .blocked_iids    = ((.blocked_iids    // []) | map(select(. != $iid)))
         | .failed_iids     = ((.failed_iids     // []) | map(select(. != $iid)))
         | .timeout_iids    = ((.timeout_iids    // []) | map(select(. != $iid)))
         | .quota_completed_this_tick = (((.quota_completed_this_tick // 0)) + 1)
       elif $bucket == "blocked" then
         .blocked_iids      = (((.blocked_iids   // []) + [$iid]) | unique)
         | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {}) + {($iid|tostring): (.tick_seq // 0)})
         | .unfinished_iids = (((.unfinished_iids // []) + [$iid]) | unique)
         | .completed_iids  = ((.completed_iids // []) | map(select(. != $iid)))
         | .failed_iids     = ((.failed_iids    // []) | map(select(. != $iid)))
         | .timeout_iids    = ((.timeout_iids   // []) | map(select(. != $iid)))
       elif $bucket == "timeout" then
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

  # Local-evidence gate for non-done outcomes (every v2 blocked/failed side
  # variant + timeout). Only `done` skips this gate.
  if [ "${final_status}" != "done" ]; then
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
  local iid attempt_number reply_status block_side
  iid="$(printf '%s' "${reply_json}" | jq -r '.iid')"
  attempt_number="$(printf '%s' "${reply_json}" | jq -r '.attempt_number')"
  reply_status="$(printf '%s' "${reply_json}" | jq -r '.status')"
  # block_side: "cc" for real subagent replies, "dispatcher" for synthesized
  # dispatcher-side failures (prep / launch / eviction). Default to "cc".
  block_side="$(printf '%s' "${reply_json}" | jq -r 'if (.block_side // "") == "dispatcher" then "dispatcher" else "cc" end')"

  # Map the compact-reply status + side onto the v2 internal terminal state.
  #   reply done                         → done
  #   reply blocked/no_changes, cc       → blocked_cc
  #   reply blocked/no_changes, disp.    → blocked_dispatcher
  #   reply failed, cc                   → failed_cc       (direct, rare)
  #   reply failed, dispatcher           → failed_dispatcher
  #   reply timeout                      → timeout
  local final_status
  case "${reply_status}" in
    done)              final_status="done" ;;
    timeout)           final_status="timeout" ;;
    failed)            final_status="failed_${block_side}" ;;
    blocked|no_changes|*) final_status="blocked_${block_side}" ;;
  esac

  # Capture child_session_key BEFORE drain.
  local child_session_key
  child_session_key="$(printf '%s' "${state_json}" \
    | jq -r --argjson iid "${iid}" '.pending_subagents[($iid|tostring)].child_session_key // ""')"

  # Sync labels for the preliminary status. On sync failure:
  #   - failed_* → keep the failed side variant (retry-budget exhaustion is sticky).
  #   - timeout  → keep `timeout` (terminal, no retry; append diagnostic to
  #                block_reason and retry the sync best-effort once).
  #   - done / blocked_* → demote to the blocked side variant (historical safety
  #                net for transient GitLab API failures), preserving the side.
  local label_err=""
  local _err=""
  if ! _err="$(phase6_sync_labels "${iid}" "${final_status}" 2>&1 >/dev/null)"; then
    label_err="${_err}"
    case "${final_status}" in
      timeout)
        reply_json="$(printf '%s' "${reply_json}" | jq -c \
          --arg le "phase6 label sync failed: ${label_err}" '
          (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
        ')"
        # best-effort timeout sync — leaves issue without `doing` removal in worst case,
        # but the dispatcher refuses to spawn for an IID in timeout_iids on the next tick,
        # so no parallel acpx can start regardless.
        phase6_sync_labels "${iid}" timeout >/dev/null 2>&1 || true
        ;;
      failed_cc|failed_dispatcher)
        : # keep the failed side variant; nothing further to do.
        ;;
      *)
        # done / blocked_* → demote to the same-side blocked variant.
        final_status="blocked_${block_side}"
        reply_json="$(printf '%s' "${reply_json}" | jq -c \
          --arg le "phase6 label sync failed: ${label_err}" '
          .status = "blocked"
          | (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
        ')"
        # best-effort blocked sync
        phase6_sync_labels "${iid}" "${final_status}" >/dev/null 2>&1 || true
        ;;
    esac
  fi

  # Write per-issue state files (computes new retry_count).
  local prior_issue_state
  prior_issue_state="$(phase6_read_prior_issue_state "${iid}")"
  local new_retry_count blocked_retry_limit
  new_retry_count="$(phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
    "${final_status}" "${prior_issue_state}" "${is_launch_synth}")"

  # Promote blocked_* → failed_* (same side) if retry_count > blocked_retry_limit.
  blocked_retry_limit="$(printf '%s' "${state_json}" | jq -r '.blocked_retry_limit // 0')"
  case "${final_status}" in
    blocked_cc|blocked_dispatcher)
      if [ "${is_launch_synth}" != "true" ] && [ "${new_retry_count}" -gt "${blocked_retry_limit}" ]; then
        final_status="failed_${block_side}"
        phase6_sync_labels "${iid}" "${final_status}" >/dev/null 2>&1 || true
        # rewrite issue state with the promoted status (retry_count already incremented)
        phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
          "${final_status}" "${prior_issue_state}" "${is_launch_synth}" >/dev/null
      fi
      ;;
  esac

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
