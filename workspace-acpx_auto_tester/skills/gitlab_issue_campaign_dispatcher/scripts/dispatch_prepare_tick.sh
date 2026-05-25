#!/usr/bin/env bash
# dispatch_prepare_tick.sh — Phases 1-4 wrapper for the scheduled-tick path
# (RUN_SCHEDULED_ISSUE_CAMPAIGN).
#
# The orchestrator LLM pipes the trigger text on stdin and reads a single
# JSON envelope on stdout describing what to spawn this tick:
#
#   {
#     "status": "ready" | "waiting_for_callbacks" | "no_eligible_iids" |
#               "completed" | "tick_failed",
#     "dispatch_entries": [
#       {
#         "iid": 14,
#         "attempt_number": 3,
#         "child_label": "#14-att-003",
#         "payload_path": "/data/.../spawn_payload.txt"
#       }, ...
#     ],
#     "run_timeout_seconds": 18120,
#     "max_launch_retries": 3,
#     "backoff_seconds": 2,
#     "cleanup_actions": [
#       {"action":"kill","target":"agent:...","reason":"scope_evicted_outside_trigger_range","iid":350}
#     ],
#     "chat_summary": "...",
#     "tick_outcome_per_iid": {"15": "blocked: prep failed: ..."},
#     "launch_retries_seed": {}
#   }
#
# When status=="ready", the LLM loops over dispatch_entries[] and for
# each entry:
#   1. Reads payload_path file → sessions_spawn(payload, label=child_label,
#      timeoutSeconds=30, runTimeoutSeconds=run_timeout_seconds,
#      cleanup="keep") with up to max_launch_retries attempts and
#      backoff_seconds between attempts (per §No-Fallback rule 2).
#   2. Calls dispatch_record_spawn.sh STATUS=spawned ... on success, or
#      STATUS=launch_failed LAUNCH_ATTEMPTS=N LAUNCH_ERROR=... on
#      exhaustion. (The script handles synthesized blocked reply +
#      retry_count semantics.)
#
# When status != "ready", the LLM just prints chat_summary to chat and
# stops. No sessions_spawn calls.
#
# This wrapper REPLACES the SKILL.md Phase 1-4 prose for the scheduled
# wake-up. It does NOT call sessions_spawn itself (that is an LLM-only
# tool). The wrapper is idempotent up to the point of label/git-state
# mutations performed by the underlying scripts (which are already
# idempotent — see references/glab_commands.md and prepare_attempt.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── 1. Parse trigger from stdin ──────────────────────────────────

TRIGGER_FILE="$(mktemp)"
POOL_OUT=""
POOL_ERR=""
RECONCILE_OUT=""
CLEANUP_ACTIONS_JSON="[]"
declare -a CLEANUP_FILES=()
retire_temp_file() {
  local path="${1:-}"
  [ -n "${path}" ] || return 0
  [ -e "${path}" ] || return 0

  # Trigger/payload temp files can contain credentials. Blank the file before
  # moving it out of the active temp path; keep the inode around for audit
  # instead of deleting it.
  : >"${path}" 2>/dev/null || true

  local retire_dir="${TMPDIR:-/tmp}/acpx_auto_tester_temporal.retired"
  mkdir -p "${retire_dir}" 2>/dev/null || return 0
  mv "${path}" "${retire_dir}/$(basename "${path}").$$.${RANDOM}" 2>/dev/null || true
}
cleanup_temps() {
  # Guard CLEANUP_FILES expansion: on bash <4.4 (and zsh), expanding an
  # empty array under `set -u` raises an unbound-variable error before
  # cleanup runs, leaving the temps on disk AND propagating a non-zero
  # exit back to the orchestrator.
  retire_temp_file "${TRIGGER_FILE}"
  retire_temp_file "${POOL_OUT}"
  retire_temp_file "${POOL_ERR}"
  retire_temp_file "${RECONCILE_OUT}"
  if [ "${#CLEANUP_FILES[@]}" -gt 0 ]; then
    local cleanup_file
    for cleanup_file in "${CLEANUP_FILES[@]}"; do
      retire_temp_file "${cleanup_file}"
    done
  fi
}
trap cleanup_temps EXIT
cat >"${TRIGGER_FILE}"

declare -A T
TRIGGER_NAME=""
while IFS= read -r line || [ -n "${line}" ]; do
  # Strip trailing CR (OpenClaw runtime has been observed to feed CRLF).
  line="${line%$'\r'}"
  case "${line}" in
    ''|\#*) continue ;;
    RUN_SCHEDULED_ISSUE_CAMPAIGN|RUN_CHILD_COMPLETION_CALLBACK)
      TRIGGER_NAME="${line}" ;;
    *=*)
      k="${line%%=*}"; v="${line#*=}"
      # trim ASCII whitespace around key; strip trailing CR/space from value
      k="${k##[[:space:]]}"; k="${k%%[[:space:]]}"
      v="${v%$'\r'}"; v="${v%% }"
      T["${k}"]="${v}"
      ;;
  esac
done <"${TRIGGER_FILE}"

emit_chat_failure() {
  local msg="$1"
  local cleanup_actions="${CLEANUP_ACTIONS_JSON:-[]}"
  jq -nc --arg msg "${msg}" \
    --argjson cleanup_actions "${cleanup_actions}" \
    '{status:"tick_failed", chat_summary:$msg, dispatch_entries:[], cleanup_actions:$cleanup_actions}'
  exit 0
}

if [ "${TRIGGER_NAME}" != "RUN_SCHEDULED_ISSUE_CAMPAIGN" ] && [ -z "${TRIGGER_NAME}" ]; then
  # tolerate missing header (the orchestrator may strip it)
  :
fi
if [ -n "${TRIGGER_NAME}" ] && [ "${TRIGGER_NAME}" != "RUN_SCHEDULED_ISSUE_CAMPAIGN" ]; then
  emit_chat_failure "dispatch_prepare_tick.sh is for RUN_SCHEDULED_ISSUE_CAMPAIGN only (got ${TRIGGER_NAME})"
fi

# ─── 2. Fixed-value preflight ─────────────────────────────────────
[ "${T[non_interactive]:-}"   = "true"            ] || emit_chat_failure "non_interactive must be true"
[ "${T[session_mode]:-}"      = "per_issue"       ] || emit_chat_failure "session_mode must be per_issue"
[ "${T[scheduling_mode]:-}"   = "quota_carryover" ] || emit_chat_failure "scheduling_mode must be quota_carryover"
[ "${T[blocked_policy]:-}"    = "skip_and_retry"  ] || emit_chat_failure "blocked_policy must be skip_and_retry"

# ─── 3. Required scalar validation ────────────────────────────────
require() {
  local key="$1"
  [ -n "${T[$key]:-}" ] || emit_chat_failure "missing required trigger field: ${key}"
}
require group
require project
require branch
require dev_branch
require gitlab_token
require issue_min_iid
require issue_max_iid
require hourly_issue_quota
require max_runtime_minutes
require blocked_retry_limit
require blocked_cooldown_ticks

ensure_int() {
  local key="$1" v="${T[$1]}"
  case "${v}" in *[!0-9]*|"") emit_chat_failure "invalid ${key}: must be integer, got '${v}'" ;; esac
}
for k in issue_min_iid issue_max_iid hourly_issue_quota max_runtime_minutes blocked_retry_limit blocked_cooldown_ticks; do
  ensure_int "${k}"
done

# ─── 4. Export bootstrap env for env_paths.sh ─────────────────────
export PROJECT="${T[project]}"
export GROUP="${T[group]}"
export GITLAB_TOKEN="${T[gitlab_token]}"

# Repo path: validate if supplied; env_paths.sh additionally guards.
if [ -n "${T[repo_path]:-}" ]; then
  case "${T[repo_path]}" in
    /) emit_chat_failure "invalid_repo_path: must not be /" ;;
    /*) ;;
    *)  emit_chat_failure "invalid_repo_path: must be absolute" ;;
  esac
  case "${T[repo_path]}" in
    *"/.."|*"/../"*|*"/."|*"/./"*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*)
      emit_chat_failure "invalid_repo_path: dot segments or whitespace not allowed" ;;
  esac
  case "${T[repo_path]}" in
    *[!A-Za-z0-9_./-]*) emit_chat_failure "invalid_repo_path: unsupported characters" ;;
  esac
  export REPO_PARENT_PATH="${T[repo_path]}"
fi

# Result/data basenames: per-tick override OR carry-forward from persisted state.
# We can't read persisted state until env_paths.sh is sourced. So:
#  - if trigger supplies, validate now and export.
#  - else leave unset, env_paths.sh defaults to ifp-result / ifp-data, then we
#    re-derive from persisted state below and re-source env_paths.sh if needed.
for bn in result_basename data_basename; do
  if [ -n "${T[$bn]:-}" ]; then
    case "${T[$bn]}" in
      */*|*..*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*|"")
        emit_chat_failure "invalid_${bn}: plain directory name required" ;;
    esac
  fi
done
[ -n "${T[result_basename]:-}" ] && export RESULT_BASENAME="${T[result_basename]}"
[ -n "${T[data_basename]:-}" ]   && export DATA_BASENAME="${T[data_basename]}"

# ui_accounts_relpath: relative path of the UI account pool file under
# ${DATA_DIR}. Same carry-forward semantics as result_basename /
# data_basename — applied here so env_paths.sh sees the exported value
# below. Validation matches the rules enforced in load_ui_accounts.sh.
if [ -n "${T[ui_accounts_relpath]:-}" ]; then
  case "${T[ui_accounts_relpath]}" in
    /*)
      emit_chat_failure "invalid_ui_accounts_relpath: must be a relative path" ;;
  esac
  case "${T[ui_accounts_relpath]}" in
    *"/.."|*"/../"*|"../"*|".."|*"/."|*"/./"*|"./"*|"."|*$'\n'*|*$'\r'*|*$'\t'*|*" "*)
      emit_chat_failure "invalid_ui_accounts_relpath: dot segments or whitespace not allowed" ;;
  esac
  case "${T[ui_accounts_relpath]}" in
    *[!A-Za-z0-9_./-]*)
      emit_chat_failure "invalid_ui_accounts_relpath: unsupported characters" ;;
  esac
  export UI_ACCOUNTS_RELPATH="${T[ui_accounts_relpath]}"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

# If the trigger omitted basenames and the persisted state lives under a
# non-default result root, the default CAMPAIGN_STATE_FILE path will not exist.
# Discover the existing runtime root under REPO_PATH before falling back to
# a fresh default tree.
if { [ -z "${T[result_basename]:-}" ] || [ -z "${T[data_basename]:-}" ] || [ -z "${T[ui_accounts_relpath]:-}" ]; } \
   && [ ! -f "${CAMPAIGN_STATE_FILE}" ] && [ -d "${REPO_PATH}" ]; then
  shopt -s nullglob
  for candidate_state in "${REPO_PATH}"/*/_dispatcher/campaign_state.json; do
    CANDIDATE_PROJECT="$(jq -r '.project // empty' "${candidate_state}" 2>/dev/null || true)"
    [ "${CANDIDATE_PROJECT}" = "${PROJECT}" ] || continue
    candidate_result_root="$(dirname "$(dirname "${candidate_state}")")"
    candidate_result_basename="$(basename "${candidate_result_root}")"
    if [ -z "${T[result_basename]:-}" ]; then
      PERSISTED_RB="$(jq -r --arg fallback "${candidate_result_basename}" '.result_basename // $fallback' "${candidate_state}")"
      [ -n "${PERSISTED_RB}" ] && export RESULT_BASENAME="${PERSISTED_RB}"
    fi
    if [ -z "${T[data_basename]:-}" ]; then
      PERSISTED_DB="$(jq -r '.data_basename // empty' "${candidate_state}")"
      [ -n "${PERSISTED_DB}" ] && export DATA_BASENAME="${PERSISTED_DB}"
    fi
    if [ -z "${T[ui_accounts_relpath]:-}" ]; then
      PERSISTED_UAR="$(jq -r '.ui_accounts_relpath // empty' "${candidate_state}")"
      [ -n "${PERSISTED_UAR}" ] && export UI_ACCOUNTS_RELPATH="${PERSISTED_UAR}"
    fi
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/env_paths.sh"
    break
  done
fi

# Carry-forward for basenames: if trigger omitted them but a persisted
# campaign_state.json exists with non-default values, re-source env_paths
# with those values so all derived paths match the persisted layout.
if [ -z "${T[result_basename]:-}" ] && [ -f "${CAMPAIGN_STATE_FILE}" ]; then
  PERSISTED_RB="$(jq -r '.result_basename // empty' "${CAMPAIGN_STATE_FILE}")"
  if [ -n "${PERSISTED_RB}" ] && [ "${PERSISTED_RB}" != "${RESULT_BASENAME}" ]; then
    export RESULT_BASENAME="${PERSISTED_RB}"
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/env_paths.sh"
  fi
fi
if [ -z "${T[data_basename]:-}" ] && [ -f "${CAMPAIGN_STATE_FILE}" ]; then
  PERSISTED_DB="$(jq -r '.data_basename // empty' "${CAMPAIGN_STATE_FILE}")"
  if [ -n "${PERSISTED_DB}" ] && [ "${PERSISTED_DB}" != "${DATA_BASENAME}" ]; then
    export DATA_BASENAME="${PERSISTED_DB}"
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/env_paths.sh"
  fi
fi
if [ -z "${T[ui_accounts_relpath]:-}" ] && [ -f "${CAMPAIGN_STATE_FILE}" ]; then
  PERSISTED_UAR="$(jq -r '.ui_accounts_relpath // empty' "${CAMPAIGN_STATE_FILE}")"
  if [ -n "${PERSISTED_UAR}" ] && [ "${PERSISTED_UAR}" != "${UI_ACCOUNTS_RELPATH}" ]; then
    export UI_ACCOUNTS_RELPATH="${PERSISTED_UAR}"
  fi
fi

# ─── 5. Flock ─────────────────────────────────────────────────────
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc '{status:"lock_held", chat_summary:"lock_held (another dispatcher tick is running)", dispatch_entries:[], cleanup_actions:[]}'
  exit 0
fi

wrapper_log prepare_tick "tick started project=${PROJECT}"
TICK_START_TS="$(date -u +%s)"

# Self-heal: restore +x on scripts/safety_bin/* in case deployment dropped
# the mode bit. Must run before any Phase 4 prep that ends up invoking
# run_acpx_attempt.sh inside the subagent (which asserts the bit). Safe to
# call here because the wrapper log is now writeable; chmod is local-only
# (no GitLab traffic, no flock contention).
ensure_safety_bin_executable

# ─── 6. Load state + apply trigger override ──────────────────────
STATE_JSON="$(load_state)"

# Normalize integer / boolean trigger values.
to_bool() {
  case "$1" in
    true|True|TRUE|1|yes|YES|Yes) echo true ;;
    false|False|FALSE|0|no|NO|No) echo false ;;
    *) echo INVALID ;;
  esac
}

# Optional integer fields with defaults.
MAX_CONCURRENT="${T[max_concurrent_subagents]:-}"
MAX_ACCOUNTS="${T[max_accounts_per_issue]:-}"
STUCK_AFTER="${T[stuck_after_minutes]:-}"
ACPX_TIMEOUT="${T[acpx_timeout_seconds]:-}"
RUN_TIMEOUT="${T[run_timeout_seconds]:-}"
OUTER_TIMEOUT_GRACE_SECONDS=120

# Defaults when trigger omits.
[ -z "${MAX_CONCURRENT}" ] && MAX_CONCURRENT=1
[ -z "${MAX_ACCOUNTS}"   ] && MAX_ACCOUNTS=14
[ -z "${STUCK_AFTER}"    ] && STUCK_AFTER=330
[ -z "${ACPX_TIMEOUT}"   ] && ACPX_TIMEOUT=18000

case "${MAX_CONCURRENT}" in *[!0-9]*|"") emit_chat_failure "invalid_max_concurrent_subagents: must be >= 1" ;; esac
[ "${MAX_CONCURRENT}" -ge 1 ] || emit_chat_failure "invalid_max_concurrent_subagents: must be >= 1"
case "${MAX_ACCOUNTS}" in *[!0-9]*|"") emit_chat_failure "invalid_max_accounts_per_issue: must be >= 1" ;; esac
[ "${MAX_ACCOUNTS}" -ge 1 ] || emit_chat_failure "invalid_max_accounts_per_issue: must be >= 1"
case "${STUCK_AFTER}" in *[!0-9]*|"") emit_chat_failure "invalid_stuck_after_minutes: must be >= 5" ;; esac
[ "${STUCK_AFTER}" -ge 5 ] || emit_chat_failure "invalid_stuck_after_minutes: must be >= 5"
case "${ACPX_TIMEOUT}" in *[!0-9]*|"") emit_chat_failure "invalid_acpx_timeout_seconds: must be >= 60" ;; esac
[ "${ACPX_TIMEOUT}" -ge 60 ] || emit_chat_failure "invalid_acpx_timeout_seconds: must be >= 60"
[ -z "${RUN_TIMEOUT}"    ] && RUN_TIMEOUT=$((ACPX_TIMEOUT + OUTER_TIMEOUT_GRACE_SECONDS))
case "${RUN_TIMEOUT}" in *[!0-9]*|"") emit_chat_failure "invalid_run_timeout_seconds: must be >= 60" ;; esac
[ "${RUN_TIMEOUT}" -ge 60 ] || emit_chat_failure "invalid_run_timeout_seconds: must be >= 60"
MIN_RUN_TIMEOUT=$((ACPX_TIMEOUT + OUTER_TIMEOUT_GRACE_SECONDS))
[ "${RUN_TIMEOUT}" -ge "${MIN_RUN_TIMEOUT}" ] || emit_chat_failure "run_timeout_seconds_below_acpx_timeout_seconds_plus_${OUTER_TIMEOUT_GRACE_SECONDS}"

KILL_TERMINAL="${T[kill_subagent_on_terminal]:-}"
if [ -n "${KILL_TERMINAL}" ]; then
  KILL_TERMINAL="$(to_bool "${KILL_TERMINAL}")"
  [ "${KILL_TERMINAL}" = INVALID ] && emit_chat_failure "invalid_kill_subagent_on_terminal"
else
  KILL_TERMINAL="true"
  # Legacy compatibility: kill_subagent_on_done=false disables when new field is omitted.
  if [ -n "${T[kill_subagent_on_done]:-}" ]; then
    legacy="$(to_bool "${T[kill_subagent_on_done]}")"
    [ "${legacy}" = "false" ] && KILL_TERMINAL="false"
  fi
fi

# Optional filter fields.
ISSUE_IIDS_RAW="${T[issue_iids]:-}"
REQ_LABELS_RAW="${T[require_labels]:-}"
REQ_LABELS_MATCH="${T[require_labels_match]:-or}"

ISSUE_IIDS_JSON="[]"
if [ -n "${ISSUE_IIDS_RAW}" ]; then
  ISSUE_IIDS_JSON="$(printf '%s' "${ISSUE_IIDS_RAW}" | tr ',' '\n' | awk 'NF{gsub(/[[:space:]]/,""); print}' | jq -Rsc 'split("\n") | map(select(length>0))')"
  if printf '%s' "${ISSUE_IIDS_JSON}" | jq -e 'map(test("^[0-9]+$") | not) | any' >/dev/null; then
    emit_chat_failure "invalid_issue_iids: non-integer token"
  fi
  ISSUE_IIDS_JSON="$(printf '%s' "${ISSUE_IIDS_JSON}" | jq -c 'map(tonumber)')"
fi

REQ_LABELS_JSON="[]"
if [ -n "${REQ_LABELS_RAW}" ]; then
  REQ_LABELS_JSON="$(printf '%s' "${REQ_LABELS_RAW}" | tr ',' '\n' | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/,""); if(length>0) print}' | jq -Rsc 'split("\n") | map(select(length>0))')"
fi

case "${REQ_LABELS_MATCH}" in
  or|and) ;;
  *)
    # only meaningful if require_labels non-empty
    if [ "$(printf '%s' "${REQ_LABELS_JSON}" | jq 'length')" != "0" ]; then
      emit_chat_failure "invalid_require_labels_match"
    fi
    REQ_LABELS_MATCH="or"
    ;;
esac

# Apply trigger overrides into the state JSON.
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
  --arg project "${PROJECT}" \
  --arg branch "${T[branch]}" \
  --arg dev_branch "${T[dev_branch]}" \
  --arg repo_path "${REPO_PARENT_PATH}" \
  --arg result_basename "${RESULT_BASENAME}" \
  --arg data_basename "${DATA_BASENAME}" \
  --arg ui_accounts_relpath "${UI_ACCOUNTS_RELPATH}" \
  --argjson issue_min_iid "${T[issue_min_iid]}" \
  --argjson issue_max_iid "${T[issue_max_iid]}" \
  --argjson hourly_issue_quota "${T[hourly_issue_quota]}" \
  --argjson max_runtime_minutes "${T[max_runtime_minutes]}" \
  --argjson blocked_retry_limit "${T[blocked_retry_limit]}" \
  --argjson blocked_cooldown_ticks "${T[blocked_cooldown_ticks]}" \
  --argjson max_concurrent_subagents "${MAX_CONCURRENT}" \
  --argjson max_accounts_per_issue "${MAX_ACCOUNTS}" \
  --argjson stuck_after_minutes "${STUCK_AFTER}" \
  --argjson run_timeout_seconds "${RUN_TIMEOUT}" \
  --argjson acpx_timeout_seconds "${ACPX_TIMEOUT}" \
  --argjson kill_subagent_on_terminal "${KILL_TERMINAL}" \
  --argjson issue_iids_whitelist "${ISSUE_IIDS_JSON}" \
  --argjson require_labels "${REQ_LABELS_JSON}" \
  --arg require_labels_match "${REQ_LABELS_MATCH}" '
  . + {
    project: $project,
    branch: $branch,
    dev_branch: $dev_branch,
    repo_path: $repo_path,
    result_basename: $result_basename,
    data_basename: $data_basename,
    ui_accounts_relpath: $ui_accounts_relpath,
    issue_min_iid: $issue_min_iid,
    issue_max_iid: $issue_max_iid,
    hourly_issue_quota: $hourly_issue_quota,
    max_runtime_minutes: $max_runtime_minutes,
    blocked_retry_limit: $blocked_retry_limit,
    blocked_cooldown_ticks: $blocked_cooldown_ticks,
    max_concurrent_subagents: $max_concurrent_subagents,
    max_accounts_per_issue: $max_accounts_per_issue,
    stuck_after_minutes: $stuck_after_minutes,
    run_timeout_seconds: $run_timeout_seconds,
    acpx_timeout_seconds: $acpx_timeout_seconds,
    kill_subagent_on_terminal: $kill_subagent_on_terminal,
    issue_iids_whitelist: $issue_iids_whitelist,
    require_labels: $require_labels,
    require_labels_match: $require_labels_match,
    tick_seq: ((.tick_seq // 0) + 1),
    blocked_at_tick_by_iid: (.blocked_at_tick_by_iid // {}),
    quota_launched_this_tick: 0,
    quota_completed_this_tick: 0
  }
  | del(.accounts_per_issue)')"

# Schema migration: legacy scalar active_issue_iid (singular). The
# legacy active_issue_session field is intentionally dropped because the
# next block unconditionally rebuilds active_issue_sessions from
# pending_subagents in the canonical "issue-<project>-<iid>" format.
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '
  if has("active_issue_iid") and (has("active_issue_iids") | not) then
    .active_issue_iids = (if .active_issue_iid == null then [] else [.active_issue_iid] end)
  else . end
  | del(.active_issue_iid)
  | del(.active_issue_session)
  | if has("pending_subagents") | not then .pending_subagents = {} else . end
  | if .pending_subagents == null then .pending_subagents = {} else . end
  | if has("blocked_at_tick_by_iid") | not then .blocked_at_tick_by_iid = {} else . end
  | if .blocked_at_tick_by_iid == null then .blocked_at_tick_by_iid = {} else . end
  | if has("timeout_iids") | not then .timeout_iids = [] else . end
  | if .timeout_iids == null then .timeout_iids = [] else . end
  ')"

# Drop active_issue_iids entries with no matching pending entry (legacy stale).
# active_issue_sessions uses the canonical "issue-<project>-<iid>" format
# per state_schema.md.
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c --arg project "${PROJECT}" '
  (.pending_subagents | keys | map(tonumber) | sort) as $pk
  | .active_issue_iids     = $pk
  | .active_issue_sessions = ($pk | map("issue-" + $project + "-" + (.|tostring)))')"

# ─── 7. Effective IID universe ────────────────────────────────────
EFF_UNIVERSE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '
  (.issue_min_iid) as $lo | (.issue_max_iid) as $hi
  | (.issue_iids_whitelist // []) as $wl
  | if ($wl | length) == 0 then
      [range($lo; $hi+1)]
    else
      [range($lo; $hi+1)] | map(select(. as $i | $wl | index($i) != null)) | unique | sort
    end')"

# ─── 8. Pending eviction ──────────────────────────────────────────
NOW_TS="$(date -u +%s)"
EVICTED_IIDS_JSON="[]"
SCOPE_EVICTED_IIDS_JSON="[]"
PENDING_KEYS="$(printf '%s' "${STATE_JSON}" | jq -r '.pending_subagents | keys[]?')"
for piid in ${PENDING_KEYS}; do
  ENTRY="$(printf '%s' "${STATE_JSON}" | jq -c --arg k "${piid}" '.pending_subagents[$k]')"
  SP_AT="$(printf '%s' "${ENTRY}" | jq -r '.spawned_at // ""')"
  PA_NUM="$(printf '%s' "${ENTRY}" | jq -r '.attempt_number')"
  CHILD_SESSION_KEY="$(printf '%s' "${ENTRY}" | jq -r '.child_session_key // ""')"
  EVICT=false
  EVICT_KIND=""
  if ! printf '%s' "${EFF_UNIVERSE_JSON}" | jq -e --argjson iid "${piid}" 'index($iid) != null' >/dev/null; then
    EVICT=true
    EVICT_KIND="scope"
    REASON="pending IID outside current trigger scope issue_iids∩[issue_min_iid,issue_max_iid]"
  elif [ -z "${SP_AT}" ] || [ "${SP_AT}" = "null" ]; then
    # placeholder that survived a previous crash — evict on next tick
    if [ "$(printf '%s' "${ENTRY}" | jq -r '.placeholder // false')" = "true" ]; then
      EVICT=true
      EVICT_KIND="stuck"
      REASON="placeholder pending entry survived: spawn was never observed to land"
    fi
  else
    # parse spawned_at as ISO-8601
    SP_EPOCH="$(date -u -d "${SP_AT}" +%s 2>/dev/null || gdate -u -d "${SP_AT}" +%s 2>/dev/null || echo 0)"
    if [ "${SP_EPOCH}" -gt 0 ]; then
      DELTA=$(( (NOW_TS - SP_EPOCH) / 60 ))
      if [ "${DELTA}" -ge "${STUCK_AFTER}" ]; then
        EVICT=true
        EVICT_KIND="stuck"
        REASON="no callback received within stuck_after_minutes (${DELTA} min)"
      fi
    fi
  fi
  if [ "${EVICT}" = true ]; then
    wrapper_log prepare_tick "${EVICT_KIND}-evict iid=${piid} reason='${REASON}'"
    REPLY_JSON="$(phase6_synthesize_blocked "${piid}" "${PA_NUM}" "${REASON}")"
    PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "true")"
    STATE_JSON="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
    EVICTED_IIDS_JSON="$(printf '%s' "${EVICTED_IIDS_JSON}" | jq -c --argjson v "${piid}" '. + [$v]')"
    if [ "${EVICT_KIND}" = "scope" ]; then
      SCOPE_EVICTED_IIDS_JSON="$(printf '%s' "${SCOPE_EVICTED_IIDS_JSON}" | jq -c --argjson v "${piid}" '. + [$v]')"
      if [ -n "${CHILD_SESSION_KEY}" ] && [ "${CHILD_SESSION_KEY}" != "null" ]; then
        CLEANUP_ACTIONS_JSON="$(printf '%s' "${CLEANUP_ACTIONS_JSON}" | jq -c \
          --arg target "${CHILD_SESSION_KEY}" \
          --arg reason "scope_evicted_outside_trigger_range" \
          --argjson iid "${piid}" \
          '. + [{action:"kill", target:$target, reason:$reason, iid:$iid}]')"
      fi
    fi
  fi
done
persist_state "${STATE_JSON}"

# ─── 9. If pending still non-empty → waiting_for_callbacks ───────
PENDING_COUNT="$(printf '%s' "${STATE_JSON}" | jq -r '.pending_subagents | keys | length')"
if [ "${PENDING_COUNT}" -gt 0 ]; then
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.campaign_status = "waiting_for_callbacks"')"
  persist_state "${STATE_JSON}"
  PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.pending_subagents | keys | map(tonumber)')"
  jq -nc \
    --argjson pending "${PENDING_IIDS_JSON}" \
    --argjson evicted "${EVICTED_IIDS_JSON}" \
    --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    --arg chat "waiting_for_callbacks; pending=$(jq -c . <<<"${PENDING_IIDS_JSON}") evicted=$(jq -c . <<<"${EVICTED_IIDS_JSON}") scope_evicted=$(jq -c . <<<"${SCOPE_EVICTED_IIDS_JSON}")" '
    {status:"waiting_for_callbacks", dispatch_entries:[], pending_iids:$pending,
     evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
     cleanup_actions:$cleanup_actions, chat_summary:$chat}'
  exit 0
fi

# ─── 10. Reconcile ────────────────────────────────────────────────
RECONCILE_ARGS=(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}"
  REPO_PARENT_PATH="${REPO_PARENT_PATH}"
  RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH}")

WHITELIST_NONEMPTY="$(printf '%s' "${STATE_JSON}" | jq -r '.issue_iids_whitelist | length')"
if [ "${WHITELIST_NONEMPTY}" -gt 0 ]; then
  IID_LIST_CSV="$(printf '%s' "${EFF_UNIVERSE_JSON}" | jq -r 'join(",")')"
  RECONCILE_ARGS+=(IID_LIST="${IID_LIST_CSV}")
else
  RECONCILE_ARGS+=(MIN_IID="${T[issue_min_iid]}" MAX_IID="${T[issue_max_iid]}")
fi

RECONCILE_OUT="$(mktemp)"
set +e
env "${RECONCILE_ARGS[@]}" bash "${SCRIPT_DIR}/reconcile.sh" >"${RECONCILE_OUT}" 2>&1
RECONCILE_RC=$?
set -e
cat "${RECONCILE_OUT}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>/dev/null || true
if [ "${RECONCILE_RC}" -ne 0 ]; then
  emit_chat_failure "reconcile_failed: $(tail -n 1 "${RECONCILE_OUT}")"
fi
EVIDENCE_PATH="$(grep -E '^/.+/reconcile-[0-9TZ]+\.json$' "${RECONCILE_OUT}" | tail -n 1 || true)"
if [ -z "${EVIDENCE_PATH}" ] || [ ! -f "${EVIDENCE_PATH}" ]; then
  emit_chat_failure "reconcile_failed: evidence file not produced"
fi
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c --arg p "${EVIDENCE_PATH}" '.last_reconcile_evidence = $p')"

# ─── 11. Disk cache correction from evidence ─────────────────────
EVIDENCE_JSON="$(cat "${EVIDENCE_PATH}")"
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c --argjson ev "${EVIDENCE_JSON}" '
  . as $s
  | reduce $ev[] as $e ($s;
      .completed_iids = (.completed_iids // [])
      | .unfinished_iids = (.unfinished_iids // [])
      | .blocked_iids   = (.blocked_iids // [])
      | .failed_iids    = (.failed_iids // [])
      | .timeout_iids   = (.timeout_iids // [])
      | if $e.is_closed_on_gitlab == true then
          .completed_iids = (([$e.iid] + .completed_iids) | unique)
          | .unfinished_iids = (.unfinished_iids - [$e.iid])
          | .blocked_iids    = (.blocked_iids    - [$e.iid])
          | .failed_iids     = (.failed_iids     - [$e.iid])
          | .timeout_iids    = (.timeout_iids    - [$e.iid])
        elif $e.has_done_pr == true and $e.needs_continue != true then
          .completed_iids = (([$e.iid] + .completed_iids) | unique)
          | .unfinished_iids = (.unfinished_iids - [$e.iid])
          | .timeout_iids    = (.timeout_iids    - [$e.iid])
        elif $e.needs_continue == true then
          .unfinished_iids = (([$e.iid] + .unfinished_iids) | unique)
          | .completed_iids = (.completed_iids - [$e.iid])
          | .blocked_iids   = (.blocked_iids - [$e.iid])
          | .failed_iids    = (.failed_iids - [$e.iid])
          | .timeout_iids   = (.timeout_iids - [$e.iid])
          | .campaign_status = "running"
        elif $e.user_reopened == true then
          .unfinished_iids = (([$e.iid] + .unfinished_iids) | unique)
          | .completed_iids = (.completed_iids - [$e.iid])
          | .blocked_iids   = (.blocked_iids - [$e.iid])
          | .failed_iids    = (.failed_iids - [$e.iid])
          | .timeout_iids   = (.timeout_iids - [$e.iid])
        elif $e.has_timeout == true then
          # Live label says timeout but our cache disagrees — adopt the truth.
          .timeout_iids     = (([$e.iid] + .timeout_iids) | unique)
          | .unfinished_iids = (.unfinished_iids - [$e.iid])
          | .completed_iids  = (.completed_iids - [$e.iid])
          | .blocked_iids    = (.blocked_iids - [$e.iid])
          | .failed_iids     = (.failed_iids - [$e.iid])
        else .
      end)
  ')"
persist_state "${STATE_JSON}"

# ─── 12. Early-return: all done? ─────────────────────────────────
ALL_DONE="$(printf '%s' "${STATE_JSON}" | jq -r --argjson ev "${EVIDENCE_JSON}" --argjson universe "${EFF_UNIVERSE_JSON}" '
  if (.issue_iids_whitelist | length) > 0 then false
  else
    ($ev | map(.is_done_on_gitlab == true and .needs_continue != true) | all)
    and (($universe | length) == ($ev | length))
  end')"
if [ "${ALL_DONE}" = "true" ]; then
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.campaign_status = "completed"')"
  persist_state "${STATE_JSON}"
  jq -nc --arg ev "${EVIDENCE_PATH}" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    '{status:"completed", dispatch_entries:[], chat_summary:"all IIDs in range terminal — campaign completed",
      last_reconcile_evidence:$ev, cleanup_actions:$cleanup_actions}'
  exit 0
fi

# ─── 13. Tick-level prep ──────────────────────────────────────────
set +e
PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
  REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
  RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH}" \
  bash "${SCRIPT_DIR}/ensure_labels.sh" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1
EL_RC=$?
set -e
[ "${EL_RC}" -eq 0 ] || emit_chat_failure "ensure_labels_failed (exit ${EL_RC})"

set +e
PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
  REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
  RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH}" \
  BRANCH="${T[branch]}" \
  bash "${SCRIPT_DIR}/clone_or_pull.sh" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1
CP_RC=$?
set -e
[ "${CP_RC}" -eq 0 ] || emit_chat_failure "clone_or_pull_failed (exit ${CP_RC})"

# ─── 14. Validate UI account pool ────────────────────────────────
# The source lives inside the cloned project data directory, so this must
# run after clone_or_pull.sh.
POOL_OUT="$(mktemp)"
POOL_ERR="$(mktemp)"
chmod 600 "${POOL_OUT}" "${POOL_ERR}" 2>/dev/null || true
set +e
PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
  REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
  RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH}" \
  MAX_CONCURRENT_SUBAGENTS="${MAX_CONCURRENT}" \
  MAX_ACCOUNTS_PER_ISSUE="${MAX_ACCOUNTS}" \
  bash "${SCRIPT_DIR}/load_ui_accounts.sh" >"${POOL_OUT}" 2>"${POOL_ERR}"
POOL_RC=$?
set -e
case "${POOL_RC}" in
  0) ;;
  10) emit_chat_failure "ui_accounts_pool_file_missing (deployment incomplete): ${DATA_BASENAME}/${UI_ACCOUNTS_RELPATH}" ;;
  11) emit_chat_failure "ui_accounts_pool_empty: ${DATA_BASENAME}/${UI_ACCOUNTS_RELPATH}" ;;
  12) emit_chat_failure "ui_accounts_pool_malformed: ${DATA_BASENAME}/${UI_ACCOUNTS_RELPATH}" ;;
  13)
    POOL_SIZE_X="$(awk -F= '/^POOL_SIZE=/{print $2}' "${POOL_ERR}")"
    emit_chat_failure "ui_account_pool_too_small: pool=${POOL_SIZE_X} max_concurrent_subagents=${MAX_CONCURRENT}" ;;
  14) emit_chat_failure "invalid_max_concurrent_subagents: must be >= 1" ;;
  15) emit_chat_failure "invalid_max_accounts_per_issue: must be >= 1" ;;
  16) emit_chat_failure "invalid_ui_accounts_relpath: ${UI_ACCOUNTS_RELPATH}" ;;
  *)  emit_chat_failure "load_ui_accounts.sh failed exit=${POOL_RC}" ;;
esac
POOL_SIZE="$(awk -F= '/^POOL_SIZE=/{print $2}' "${POOL_ERR}")"
SLOT_SIZES_CSV="$(awk -F= '/^SLOT_SIZES=/{print $2}' "${POOL_ERR}")"
mapfile -t POOL_LINES <"${POOL_OUT}"
# POOL_OUT now lives only in the bash array; scrub the on-disk copy
# before any other step can fail and leak passwords via trap cleanup.
: >"${POOL_OUT}"

# Cache pool data on state for the chat summary.
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
  --argjson pool_size "${POOL_SIZE}" '.ui_account_pool_size = $pool_size')"

# ─── 15. require_labels filter ────────────────────────────────────
LABEL_FILTERED_IN_JSON="[]"
LABEL_FILTERED_OUT_JSON="[]"
if [ "$(printf '%s' "${STATE_JSON}" | jq -r '.require_labels | length')" -gt 0 ]; then
  LF_OUT="$(printf '%s' "${STATE_JSON}" | jq -c --argjson ev "${EVIDENCE_JSON}" '
    .require_labels as $req
    | .require_labels_match as $m
    | (
        $ev | map(select(
          (.missing // false) == false
          and (
            if $m == "and" then
              ($req - (.labels // [])) | length == 0
            else
              (((.labels // []) - ((.labels // []) - $req)) | length) > 0
            end
          )
        )) | map(.iid)
      ) as $in
    | (($ev | map(.iid)) - $in) as $out
    | {in:$in, out:$out}')"
  LABEL_FILTERED_IN_JSON="$(printf '%s' "${LF_OUT}" | jq -c '.in')"
  LABEL_FILTERED_OUT_JSON="$(printf '%s' "${LF_OUT}" | jq -c '.out')"
fi

# ─── 16. Batch formation ──────────────────────────────────────────
ELAPSED_MIN=$(( ($(date -u +%s) - TICK_START_TS) / 60 ))
if [ "${ELAPSED_MIN}" -ge "${T[max_runtime_minutes]}" ]; then
  jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "time_budget reached before launch (elapsed_min=${ELAPSED_MIN})" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    '{status:"no_eligible_iids", dispatch_entries:[], cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  exit 0
fi

# Batch picking jq filter — keeps the priority order from SKILL.md:
#   1. lowest-IID non-blocked unfinished backlog
#   2. lowest-IID fresh from next_new_issue_iid upward
#   3. lowest-IID retryable blocked (only after 1+2 exhausted)
HOURLY_QUOTA="$(printf '%s' "${STATE_JSON}" | jq -r '.hourly_issue_quota')"
QUOTA_LAUNCHED="$(printf '%s' "${STATE_JSON}" | jq -r '.quota_launched_this_tick // 0')"
QUOTA_LEFT=$(( HOURLY_QUOTA - QUOTA_LAUNCHED ))
[ "${QUOTA_LEFT}" -lt 0 ] && QUOTA_LEFT=0

BATCH_CAP="${MAX_CONCURRENT}"
[ "${QUOTA_LEFT}" -lt "${BATCH_CAP}" ] && BATCH_CAP="${QUOTA_LEFT}"

NEXT_NEW="$(printf '%s' "${STATE_JSON}" | jq -r '.next_new_issue_iid // .issue_min_iid')"

# eligibility candidates per category
BATCH_CANDIDATES_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
  --argjson ev "${EVIDENCE_JSON}" \
  --argjson universe "${EFF_UNIVERSE_JSON}" \
  --argjson label_in "${LABEL_FILTERED_IN_JSON}" \
  --argjson next_new "${NEXT_NEW}" '
  . as $s
  | ($ev | map({iid:.iid, e:.})) as $evmap
  | ($evmap | map({(.iid|tostring): .e}) | add // {}) as $byiid
  | (if ($s.require_labels | length) > 0 then ($label_in) else $universe end) as $considered
  | ($considered | map(select(. as $i
        | ($byiid[($i|tostring)] // null) as $e
        | $e != null
        and ($e.is_closed_on_gitlab // false) != true
        and (($e.has_done_pr // false) != true or ($e.needs_continue // false) == true)
      ))) as $eligible
  | ($eligible | map(select(. as $i |
      (($s.blocked_iids // []) | index($i) | not)
      and (($s.timeout_iids // []) | index($i) | not)
      and (($s.unfinished_iids // []) | index($i))
    )) | sort) as $backlog
  | ($eligible | map(select(. as $i |
      (($s.blocked_iids // []) | index($i) | not)
      and (($s.unfinished_iids // []) | index($i) | not)
      and (($s.completed_iids // []) | index($i) | not)
      and (($s.failed_iids // []) | index($i) | not)
      and (($s.timeout_iids // []) | index($i) | not)
      and ($i >= $next_new)
    )) | sort) as $fresh
  | ($eligible | map(select(. as $i |
      (($s.blocked_iids // []) | index($i))
      and (($s.timeout_iids // []) | index($i) | not)
    )) | sort) as $blocked_retryable_raw
  | # blocked_iids invariant: only retryable entries are in this list.
    # Phase 6 promotes blocked → failed (and moves the IID into failed_iids)
    # whenever retry_count > blocked_retry_limit. Launch-side synthesized
    # blocked replies (dispatch_record_spawn.sh STATUS=launch_failed) and
    # stuck-pending evictions (dispatch_prepare_tick.sh) both DO NOT
    # increment retry_count, but they also do not violate the invariant —
    # they just defer one extra tick before another launch attempt. Per-
    # issue retry_count lives in issues/issue-<iid>/state.json and is
    # consulted only inside phase6_process; blocked_cooldown_ticks is tracked
    # at campaign level with tick_seq so blocked entries can sit out N
    # scheduled wake-ups before retrying.
    ($blocked_retryable_raw | map(select(. as $i |
      (($s.blocked_cooldown_ticks // 0) <= 0)
      or (($s.blocked_at_tick_by_iid[($i|tostring)] // null) == null)
      or ((($s.tick_seq // 0) - ($s.blocked_at_tick_by_iid[($i|tostring)] | tonumber)) >= ($s.blocked_cooldown_ticks // 0))
    ))) as $blocked_retryable
  | {backlog: $backlog, fresh: $fresh, blocked_retryable: $blocked_retryable}')"

BACKLOG_JSON="$(printf '%s' "${BATCH_CANDIDATES_JSON}" | jq -c '.backlog')"
FRESH_JSON="$(printf '%s' "${BATCH_CANDIDATES_JSON}" | jq -c '.fresh')"
BLOCKED_JSON="$(printf '%s' "${BATCH_CANDIDATES_JSON}" | jq -c '.blocked_retryable')"

# Pick batch: unfinished backlog first, then fresh, then cooled-down blocked,
# up to BATCH_CAP.
BATCH_JSON="$(jq -nc \
  --argjson backlog "${BACKLOG_JSON}" \
  --argjson fresh "${FRESH_JSON}" \
  --argjson blocked "${BLOCKED_JSON}" \
  --argjson cap "${BATCH_CAP}" '
  ($backlog + $fresh + $blocked) | unique_by(.) | .[0:$cap]')"

BATCH_SIZE="$(printf '%s' "${BATCH_JSON}" | jq -r 'length')"
if [ "${BATCH_SIZE}" = "0" ]; then
  jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "no eligible IIDs this tick" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    '{status:"no_eligible_iids", dispatch_entries:[], cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  exit 0
fi

# Move the fresh-issue cursor past any fresh IID selected for this batch. The
# backlog/blocked paths do not affect it.
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
  --argjson batch "${BATCH_JSON}" \
  --argjson fresh "${FRESH_JSON}" '
  ($batch - ($batch - $fresh)) as $fresh_batch
  | if ($fresh_batch | length) > 0 then
      .next_new_issue_iid = ([.next_new_issue_iid // .issue_min_iid, (($fresh_batch | max) + 1)] | max)
    else . end')"

# ─── 17. Allocate attempt numbers ─────────────────────────────────
declare -A ATTEMPT
mapfile -t BATCH_IIDS < <(printf '%s' "${BATCH_JSON}" | jq -r '.[]')
for iid in "${BATCH_IIDS[@]}"; do
  N="$(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
       REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
       RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH}" \
       IID="${iid}" \
       bash "${SCRIPT_DIR}/allocate_attempt.sh")"
  ATTEMPT["${iid}"]="${N}"
done

# ─── 18. Slice UI accounts per IID using SLOT_SIZES ─────────────
IFS=',' read -ra SLOT_SIZES_ARR <<<"${SLOT_SIZES_CSV}"
declare -A UI_OFFSET UI_COUNT UI_ACCOUNTS_JSON
offset=0
for k in "${!BATCH_IIDS[@]}"; do
  iid="${BATCH_IIDS[$k]}"
  size="${SLOT_SIZES_ARR[$k]:-0}"
  UI_OFFSET["${iid}"]="${offset}"
  UI_COUNT["${iid}"]="${size}"
  acct_block="["
  sep=""
  for (( j=0; j<size; j++ )); do
    idx=$(( offset + j ))
    line="${POOL_LINES[$idx]:-}"
    user="${line%%:*}"
    pass="${line#*:}"
    acct_block+="${sep}$(jq -cn --arg u "${user}" --arg p "${pass}" '{u:$u,p:$p}')"
    sep=","
  done
  acct_block+="]"
  UI_ACCOUNTS_JSON["${iid}"]="${acct_block}"
  offset=$(( offset + size ))
done

# ─── 19. Pre-spawn persist (placeholder pending entries) ──────────
PRE_PENDING_JQ_ARGS=()
for iid in "${BATCH_IIDS[@]}"; do
  PRE_PENDING_JQ_ARGS+=( --argjson "iid_${iid}" "${iid}"
                         --argjson "att_${iid}" "${ATTEMPT[$iid]}"
                         --argjson "off_${iid}" "${UI_OFFSET[$iid]}"
                         --argjson "cnt_${iid}" "${UI_COUNT[$iid]}" )
done
# Build the placeholder additions in one jq pass to avoid quoting hell.
# active_issue_sessions uses the canonical "issue-<project>-<iid>" format
# per state_schema.md §active_issue_iids / active_issue_sessions.
PRE_PENDING_JQ_ARGS+=( --arg project "${PROJECT}" )
FILTER='.pending_subagents = (.pending_subagents // {})'
for iid in "${BATCH_IIDS[@]}"; do
  FILTER+=" | .pending_subagents[\"${iid}\"] = {attempt_number: \$att_${iid}, run_id: null, child_session_key: null, ui_account_index_start: \$off_${iid}, ui_account_count: \$cnt_${iid}, spawned_at: null, placeholder: true}"
done
FILTER+=' | .active_issue_iids = (.pending_subagents | keys | map(tonumber) | sort)'
FILTER+=' | .active_issue_sessions = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))'
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c "${PRE_PENDING_JQ_ARGS[@]}" "${FILTER}")"
persist_state "${STATE_JSON}"

# ─── 20. Per-IID prep ─────────────────────────────────────────────
TICK_OUTCOMES='{}'
DISPATCH_ENTRIES='[]'
declare -A PAYLOAD_PATH CHILD_LABEL_BY_IID
for iid in "${BATCH_IIDS[@]}"; do
  attempt="${ATTEMPT[$iid]}"
  attempt_padded="$(printf '%03d' "${attempt}")"
  child_label="#${iid}-att-${attempt_padded}"
  CHILD_LABEL_BY_IID["${iid}"]="${child_label}"

  # Initialize per-iteration locals so set -u cannot trip a later read of
  # an unset var on the failure paths below.
  MODE_ACTUAL=""
  LOCAL_ATTEMPT_BRANCH=""
  ISSUE_TITLE=""
  ISSUE_URL=""
  ISSUE_LABELS=""
  ISSUE_BODY=""
  ISSUE_TITLE_QUOTED="''"

  # Per-IID env for env_paths-derived paths.
  iid_env=(
    PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}"
    REPO_PARENT_PATH="${REPO_PARENT_PATH}"
    RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH}"
    ISSUE_IID="${iid}" ATTEMPT_NUMBER="${attempt}"
  )

  # Resolve ISSUE_MODE from live labels. `continue` / `contiune` is the only
  # resume signal. Every other entry path (`todo`, `retry`, `new`,
  # `blocked`, trigger require_labels) resets from the clean DEV_BRANCH
  # baseline, even if this IID has prior attempts on disk.
  ISSUE_MODE="fresh"
  NEEDS_CONTINUE="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | .needs_continue // false')"
  RESET_REQUESTED="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '
    (.[] | select(.iid==$i) | .labels // []) as $labels
    | (($labels | index("retry") != null) or ($labels | index("todo") != null))
  ')"
  if [ "${NEEDS_CONTINUE}" = "true" ] && [ "${RESET_REQUESTED}" != "true" ]; then
    ISSUE_MODE="continue"
  fi

  prep_blocked() {
    local reason="$1"
    wrapper_log prepare_tick "iid=${iid} blocked during prep: ${reason}"
    REPLY_JSON="$(phase6_synthesize_blocked "${iid}" "${attempt}" "dispatcher prep failed: ${reason}")"
    PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "false")"
    STATE_JSON="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
    persist_state "${STATE_JSON}"
    TICK_OUTCOMES="$(printf '%s' "${TICK_OUTCOMES}" | jq -c --arg k "${iid}" --arg v "blocked: ${reason}" '. + {($k):$v}')"
  }

  # prepare_attempt.sh — keep stdout clean (the script's contract is two
  # lines on stdout: mode_actual, LOCAL_ATTEMPT_BRANCH). `git fetch` /
  # `git worktree add` etc. write progress to stderr; we capture stderr
  # to a separate file so it does NOT contaminate the two output lines.
  PA_OUT="$(mktemp)"
  PA_ERR="$(mktemp)"
  CLEANUP_FILES+=("${PA_OUT}" "${PA_ERR}")
  set +e
  env "${iid_env[@]}" BRANCH="${T[branch]}" DEV_BRANCH="${T[dev_branch]}" \
    ISSUE_MODE="${ISSUE_MODE}" \
    bash "${SCRIPT_DIR}/prepare_attempt.sh" >"${PA_OUT}" 2>"${PA_ERR}"
  PA_RC=$?
  set -e
  # Mirror stderr into wrapper.log for post-mortem (even on success — git
  # progress is interesting context).
  cat "${PA_ERR}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>/dev/null || true
  if [ "${PA_RC}" -ne 0 ]; then
    prep_blocked "prepare_attempt: $(tail -n 1 "${PA_ERR}")"
    retire_temp_file "${PA_OUT}"
    retire_temp_file "${PA_ERR}"
    continue
  fi
  MODE_ACTUAL="$(sed -n '1p' "${PA_OUT}")"
  LOCAL_ATTEMPT_BRANCH="$(sed -n '2p' "${PA_OUT}")"
  retire_temp_file "${PA_OUT}"
  retire_temp_file "${PA_ERR}"
  if [ -z "${MODE_ACTUAL}" ] || [ -z "${LOCAL_ATTEMPT_BRANCH}" ]; then
    prep_blocked "prepare_attempt: empty stdout (script printed no mode/branch lines)"
    continue
  fi
  case "${MODE_ACTUAL}" in
    fresh|continue) ;;
    *)
      prep_blocked "prepare_attempt: invalid mode_actual on stdout: ${MODE_ACTUAL}"
      continue
      ;;
  esac

  # claude_settings_path
  if [ -n "${T[claude_settings_path]:-}" ]; then
    csp="${T[claude_settings_path]}"
    case "${csp}" in
      /) prep_blocked "claude_settings_path must not be /"; continue ;;
      /*) ;;
      *) prep_blocked "claude_settings_path must be absolute: ${csp}"; continue ;;
    esac
    case "${csp}" in
      *"/.."|*"/../"*|*"/."|*"/./"*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*|*[!A-Za-z0-9_./-]*)
        prep_blocked "invalid_claude_settings_path: ${csp}"; continue ;;
    esac
    if [ ! -r "${csp}" ]; then
      prep_blocked "claude_settings_path file not found or not readable: ${csp}"; continue
    fi
    # WORKTREE_DIR is derivable via env_paths.sh, but env_paths.sh exits if
    # ATTEMPT_NUMBER is missing. We already set it for this iid; source in subshell.
    WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
    if ! cp "${csp}" "${WORKTREE_DIR_X}/.claude/settings.json"; then
      prep_blocked "claude_settings copy failed"; continue
    fi
    git -C "${WORKTREE_DIR_X}" update-index --skip-worktree .claude/settings.json || true
  fi

  # Read live issue via glab.
  ISSUE_JSON="$(glab api "projects/${PROJECT_URI}/issues/${iid}" 2>/dev/null || true)"
  if [ -z "${ISSUE_JSON}" ]; then
    prep_blocked "glab api issues/${iid} returned empty"
    continue
  fi
  ISSUE_TITLE="$(printf '%s' "${ISSUE_JSON}" | jq -r '.title // ""')"
  ISSUE_URL="$(printf '%s' "${ISSUE_JSON}" | jq -r '.web_url // ""')"
  ISSUE_LABELS="$(printf '%s' "${ISSUE_JSON}" | jq -r '.labels // [] | join(",")')"
  ISSUE_BODY="$(printf '%s' "${ISSUE_JSON}" | jq -r '.description // ""' | head -c 4096)"
  ISSUE_TITLE_QUOTED="'${ISSUE_TITLE//\'/\'\\\'\'}'"

  # Transition labels: remove entry labels + add doing.
  # `timeout` is included so that a reviewer who re-enqueued the IID (e.g. by
  # adding `retry` on top of `timeout`) doesn't end up with a `timeout +
  # doing` mix between this prep and `set_issue_label.sh add doing`.
  REMOVE_LBLS=(todo retry new continue contiune blocked done pr timeout)
  # Plus require_labels intersected with current snapshot.
  if [ "$(printf '%s' "${STATE_JSON}" | jq -r '.require_labels | length')" -gt 0 ]; then
    mapfile -t REQ_TO_REMOVE < <(printf '%s' "${STATE_JSON}" | jq -r \
      --argjson cur "$(printf '%s' "${ISSUE_LABELS}" | jq -Rsc 'split(",") | map(select(length>0))')" '
      .require_labels - (.require_labels - $cur) | .[]')
    for l in "${REQ_TO_REMOVE[@]}"; do
      REMOVE_LBLS+=("${l}")
    done
  fi
  LABEL_OK=true
  for lbl in "${REMOVE_LBLS[@]}"; do
    if ! env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" remove "${lbl}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1; then
      LABEL_OK=false; break
    fi
  done
  if [ "${LABEL_OK}" = true ]; then
    env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" add doing \
      >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || LABEL_OK=false
  fi
  if [ "${LABEL_OK}" != true ]; then
    prep_blocked "set_issue_label transition to doing failed"
    continue
  fi

  # build_prompt.sh
  set +e
  env "${iid_env[@]}" BRANCH="${T[branch]}" DEV_BRANCH="${T[dev_branch]}" \
    ISSUE_MODE="${MODE_ACTUAL}" \
    UI_ACCOUNTS="${UI_ACCOUNTS_JSON[$iid]}" \
    bash "${SCRIPT_DIR}/build_prompt.sh" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1
  BP_RC=$?
  set -e
  if [ "${BP_RC}" -ne 0 ]; then
    prep_blocked "build_prompt failed (exit ${BP_RC})"
    continue
  fi

  # Init/refresh attempt + issue state files.
  WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  LOG_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$LOG_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  OUTPUT_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$OUTPUT_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  ISSUE_ROOT_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$ISSUE_ROOT"' "${SCRIPT_DIR}/env_paths.sh")"
  ATTEMPT_STATE_X="${ISSUE_ROOT_X}/attempt_state.json"
  ISSUE_STATE_X="${ISSUE_ROOT_X}/state.json"
  NOW="$(utc_now)"
  MODE_DOWNGRADED="null"
  if [ "${ISSUE_MODE}" = "continue" ] && [ "${MODE_ACTUAL}" = "fresh" ]; then
    MODE_DOWNGRADED='"continue"'
  fi
  jq -n \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt}" \
    --arg started_at "${NOW}" \
    --arg mode_requested "${ISSUE_MODE}" \
    --arg mode_actual "${MODE_ACTUAL}" \
    --argjson mode_downgraded "${MODE_DOWNGRADED}" \
    --arg local_branch "${LOCAL_ATTEMPT_BRANCH}" \
    --arg log_dir "${LOG_DIR_X}" \
    '{iid:$iid, attempt_number:$attempt_number, attempt_started_at:$started_at,
      mode_requested:$mode_requested, mode_actual:$mode_actual,
      mode_downgraded_from:$mode_downgraded,
      no_reviewer_comments:false, prior_attempt_count:0,
      local_branch:$local_branch, log_dir:$log_dir,
      status:"in_progress"}' | atomic_write_json "${ATTEMPT_STATE_X}"

  PRIOR_RETRY="$(test -f "${ISSUE_STATE_X}" && jq -r '.retry_count // 0' "${ISSUE_STATE_X}" || echo 0)"
  jq -n \
    --argjson iid "${iid}" \
    --argjson attempts_total "${attempt}" \
    --argjson latest_attempt_number "${attempt}" \
    --arg latest_attempt_dir "${ISSUE_ROOT_X}" \
    --argjson retry_count "${PRIOR_RETRY}" \
    --arg session "issue-${PROJECT}-${iid}" \
    --arg mode "${MODE_ACTUAL}" \
    --arg updated_at "${NOW}" \
    '{iid:$iid, session:$session, status:"in_progress", mode:$mode,
      attempts_total:$attempts_total, latest_attempt_number:$latest_attempt_number,
      latest_attempt_dir:$latest_attempt_dir, retry_count:$retry_count,
      block_reason:null, commit_sha:null, merge_request_url:null,
      updated_at:$updated_at}' | atomic_write_json "${ISSUE_STATE_X}"

  # Render executor prompt to ${LOG_DIR}/spawn_payload.txt.
  payload_path="${LOG_DIR_X}/spawn_payload.txt"
  mkdir -p "${LOG_DIR_X}"

  # Extract the fenced "Rendered Prompt" block from executor_prompt.md.
  # Use the sentinel line (which is part of the prompt itself) as the
  # opener so a future markdown edit introducing extra code fences in
  # the surrounding documentation does not silently mis-extract.
  template="$(awk '
    /^# ACPX_AUTO_TESTER_TEMPORAL_EXECUTOR_PROMPT_V1$/ { found=1 }
    found {
      if ($0 == "```") exit
      print
    }
  ' "${SKILL_DIR}/references/executor_prompt.md")"

  if [ -z "${template}" ]; then
    prep_blocked "executor_prompt.md fenced block missing or sentinel not found"
    continue
  fi
  first_template_line="$(printf '%s\n' "${template}" | head -n 1)"
  if [ "${first_template_line}" != "# ACPX_AUTO_TESTER_TEMPORAL_EXECUTOR_PROMPT_V1" ]; then
    prep_blocked "executor_prompt.md fenced block does not start with sentinel"
    continue
  fi

  ACPX_MIN=$(( ACPX_TIMEOUT / 60 ))
  WORK_BRANCH_X="issue/${iid}-auto-fix"

  RENDER_ERR="$(mktemp)"
  CLEANUP_FILES+=("${RENDER_ERR}")
  set +e
  rendered="$(TPL_PROJECT="${PROJECT}" \
              TPL_GROUP="${GROUP}" \
              TPL_GITLAB_HOST="${GITLAB_HOST}" \
              TPL_GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
              TPL_GITLAB_TOKEN="${GITLAB_TOKEN}" \
              TPL_ISSUE_IID="${iid}" \
              TPL_ATTEMPT_NUMBER="${attempt}" \
              TPL_ATTEMPT_NUMBER_PADDED="${attempt_padded}" \
              TPL_ISSUE_TITLE="${ISSUE_TITLE}" \
              TPL_ISSUE_TITLE_QUOTED="${ISSUE_TITLE_QUOTED}" \
              TPL_ISSUE_URL="${ISSUE_URL}" \
              TPL_ISSUE_LABELS="${ISSUE_LABELS}" \
              TPL_ISSUE_BODY="${ISSUE_BODY}" \
              TPL_ISSUE_MODE="${MODE_ACTUAL}" \
              TPL_BRANCH="${T[branch]}" \
              TPL_DEV_BRANCH="${T[dev_branch]}" \
              TPL_WORK_BRANCH="${WORK_BRANCH_X}" \
              TPL_LOCAL_ATTEMPT_BRANCH="${LOCAL_ATTEMPT_BRANCH}" \
              TPL_REPO_PATH="${REPO_PATH}" \
              TPL_WORKTREE_DIR="${WORKTREE_DIR_X}" \
              TPL_OUTPUT_DIR="${OUTPUT_DIR_X}" \
              TPL_LOG_DIR="${LOG_DIR_X}" \
              TPL_ISSUE_ROOT="${ISSUE_ROOT_X}" \
              TPL_SCRIPTS_DIR="${SCRIPT_DIR}" \
              TPL_RESULT_BASENAME="${RESULT_BASENAME}" \
              TPL_DATA_BASENAME="${DATA_BASENAME}" \
              TPL_ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT}" \
              TPL_ACPX_TIMEOUT_MINUTES="${ACPX_MIN}" \
              python3 - "${template}" 2>"${RENDER_ERR}" <<'PYEOF'
import os, re, sys
text = sys.argv[1]
for k, v in os.environ.items():
    if k.startswith("TPL_"):
        placeholder = "{" + k[4:] + "}"
        text = re.sub(r'(?<!\$)' + re.escape(placeholder), lambda _m: v, text)
m = re.search(r'(?<!\$)\{[A-Z_][A-Z0-9_]*\}', text)
if m:
    sys.stderr.write("UNSUBSTITUTED_PLACEHOLDER=" + m.group(0) + "\n")
    sys.exit(1)
sys.stdout.write(text)
PYEOF
)"
  RENDER_RC=$?
  set -e
  if [ "${RENDER_RC}" -ne 0 ] || [ -z "${rendered}" ]; then
    miss="$(sed -n 's/^UNSUBSTITUTED_PLACEHOLDER=//p' "${RENDER_ERR}" | head -n 1)"
    prep_blocked "prompt template render incomplete: ${miss:-unknown}"
    continue
  fi

  # Sentinel check.
  sentinel_first_line="$(printf '%s\n' "${rendered}" | head -n 1)"
  if [ "${sentinel_first_line}" != "# ACPX_AUTO_TESTER_TEMPORAL_EXECUTOR_PROMPT_V1" ]; then
    prep_blocked "spawn payload missing executor sentinel — refused to ship inner Claude Code prompt (${LOG_DIR_X}/prompt.txt) as the outer spawn payload"
    continue
  fi

  # The rendered payload contains the GitLab token (substituted from
  # {GITLAB_TOKEN}). Tighten permissions so only the agent user can read
  # it; dispatch_record_spawn.sh STATUS=spawned scrubs the file once the
  # subagent is launched (the runtime already has the prompt in memory).
  ( umask 077; printf '%s' "${rendered}" >"${payload_path}" )
  chmod 600 "${payload_path}" 2>/dev/null || true
  PAYLOAD_PATH["${iid}"]="${payload_path}"
  # Clear the in-memory variable so any future diagnostic (a stray
  # `wrapper_log "rendered ..."`) cannot accidentally leak the token.
  rendered=""

  DISPATCH_ENTRIES="$(printf '%s' "${DISPATCH_ENTRIES}" | jq -c \
    --argjson iid "${iid}" \
    --argjson attempt "${attempt}" \
    --arg label "${child_label}" \
    --arg path "${payload_path}" '. + [{iid:$iid, attempt_number:$attempt, child_label:$label, payload_path:$path}]')"

  wrapper_log prepare_tick "prepared iid=${iid} attempt=${attempt} payload=${payload_path}"
done

# ─── 21. Emit envelope ───────────────────────────────────────────
SURVIVOR_COUNT="$(printf '%s' "${DISPATCH_ENTRIES}" | jq 'length')"
SUMMARY="$(printf 'prepared %s/%s IIDs for spawn (max_concurrent=%s, pool=%s)' \
  "${SURVIVOR_COUNT}" "${BATCH_SIZE}" "${MAX_CONCURRENT}" "${POOL_SIZE}")"

if [ "${SURVIVOR_COUNT}" -eq 0 ]; then
  jq -nc \
    --argjson run_timeout "${RUN_TIMEOUT}" \
    --argjson outcomes "${TICK_OUTCOMES}" \
    --argjson evicted "${EVICTED_IIDS_JSON}" \
    --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    --arg ev "${EVIDENCE_PATH}" \
    --arg chat "all batch IIDs blocked during prep — see tick_outcome_per_iid" '
    {status:"no_eligible_iids", dispatch_entries:[], run_timeout_seconds:$run_timeout,
     evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
     cleanup_actions:$cleanup_actions,
     max_launch_retries:3, backoff_seconds:2,
     tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev, chat_summary:$chat}'
  exit 0
fi

jq -nc \
  --argjson dispatch_entries "${DISPATCH_ENTRIES}" \
  --argjson run_timeout "${RUN_TIMEOUT}" \
  --argjson outcomes "${TICK_OUTCOMES}" \
  --argjson evicted "${EVICTED_IIDS_JSON}" \
  --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
  --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
  --argjson label_in "${LABEL_FILTERED_IN_JSON}" \
  --argjson label_out "${LABEL_FILTERED_OUT_JSON}" \
  --arg ev "${EVIDENCE_PATH}" \
  --arg chat "${SUMMARY}" '
  {status:"ready", dispatch_entries:$dispatch_entries,
   run_timeout_seconds:$run_timeout, max_launch_retries:3, backoff_seconds:2,
   evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
   cleanup_actions:$cleanup_actions,
   label_filtered_in:$label_in, label_filtered_out:$label_out,
   tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev,
   chat_summary:$chat}'
