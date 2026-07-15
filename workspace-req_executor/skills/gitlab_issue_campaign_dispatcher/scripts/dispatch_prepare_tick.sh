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
#         "payload_path": "/data/.../spawn_payload.txt",
#         "expected_task_sha256": "<64 lowercase hex>",
#         "expected_task_bytes": 1234
#       }, ...
#     ],
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
#   1. Reads payload_path file → sessions_spawn(task=payload,
#      label=child_label, runtime="subagent", mode="run", cleanup="keep")
#      with up to max_launch_retries attempts and
#      backoff_seconds between attempts (per §No-Fallback rule 2).
#   2. Calls dispatch_record_spawn.sh STATUS=spawned ... on success, or
#      STATUS=launch_failed LAUNCH_ATTEMPTS=N LAUNCH_ERROR=... on
#      exhaustion, always forwarding EXPECTED_TASK_SHA256 and
#      EXPECTED_TASK_BYTES from the same entry. (The script handles
#      synthesized blocked reply + retry_count semantics.)
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
GITLAB_TOKEN_PROCESS_OVERRIDE="${GITLAB_TOKEN:-}"
source "${SCRIPT_DIR}/branch_utils.sh"

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    echo "dispatch_prepare_tick.sh: no SHA-256 command is available" >&2
    return 2
  fi
}

file_bytes() {
  local path="$1"
  wc -c <"${path}" | tr -d '[:space:]'
}

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

  local retire_dir="${TMPDIR:-/tmp}/req_executor.retired"
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

# emit_chat_failure: emit a tick_failed envelope and exit 0.
# CONTRACT: ${msg} MUST be a stable, named classification string (e.g.
# "reconcile_failed", "clone_or_pull_failed").
# NEVER interpolate raw stderr from a sub-script or its internal tooling
# (jq / glab / git / python3) into ${msg}. Raw diagnostics belong in
# wrapper.log only. Rationale: a tool name surfacing in the orchestrator's
# chat view primes a weak orchestrator model to "diagnose and patch the
# script" instead of classify-and-stop (SOUL.md §No-Fallback rule 1).
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

if [ "${T[run_timeout_seconds]+present}" = "present" ]; then
  emit_chat_failure "unsupported trigger field: run_timeout_seconds; configure agents.defaults.subagents.runTimeoutSeconds globally if desired"
fi

# ─── 2. Fixed-value preflight ─────────────────────────────────────
[ "${T[non_interactive]:-}"   = "true"            ] || emit_chat_failure "non_interactive must be true"
[ "${T[session_mode]:-}"      = "per_issue"       ] || emit_chat_failure "session_mode must be per_issue"
[ "${T[scheduling_mode]:-}"   = "quota_carryover" ] || emit_chat_failure "scheduling_mode must be quota_carryover"
[ "${T[blocked_policy]:-}"    = "skip_and_retry"  ] || emit_chat_failure "blocked_policy must be skip_and_retry"

DISPATCH_MODE="${T[dispatch_mode]:-scheduled}"
case "${DISPATCH_MODE}" in
  scheduled|driven_topup) ;;
  *) emit_chat_failure "invalid_dispatch_mode" ;;
esac

# ─── 3. Required scalar validation ────────────────────────────────
require() {
  local key="$1"
  [ -n "${T[$key]:-}" ] || emit_chat_failure "missing required trigger field: ${key}"
}
require group
require project
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
# Driven topups inject credentials only through the private process
# environment.  Keep the historical trigger field as a fallback for the
# existing blue-zone scheduled trigger contract, but never require it or
# serialize it into internally generated triggers.
GITLAB_TOKEN_EFFECTIVE="${GITLAB_TOKEN_PROCESS_OVERRIDE:-${T[gitlab_token]:-}}"
case "${GITLAB_TOKEN_EFFECTIVE}" in
  '') emit_chat_failure "missing_gitlab_token_private_injection" ;;
  *[[:cntrl:]]*) emit_chat_failure "invalid_gitlab_token_private_injection" ;;
esac
export GITLAB_TOKEN="${GITLAB_TOKEN_EFFECTIVE}"

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

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

# ─── 5. Flock ─────────────────────────────────────────────────────
# The campaign lock lives inside the repo runtime root
# (${RESULT_ROOT}/_dispatcher/campaign.lock), but env_paths.sh only creates
# that directory once ${REPO_PATH}/.git exists, and the routine clone_or_pull
# (§13) runs AFTER this flock. On a brand-new deployment whose repo_path has
# never been cloned, opening the lock fd here would fail with ENOENT.
# Bootstrap the clone first (only when .git is missing) so the lock's parent
# directory exists. clone_or_pull.sh is internally serialized (tmpfs +
# repo.lock) and idempotent; §13 re-runs it under the campaign lock for the
# routine fetch. We must NOT pre-`mkdir` the lock directory instead:
# clone_or_pull.sh refuses (exit 12) to clone into a ${REPO_PATH} that already
# exists without a .git/, so creating the runtime root ahead of the clone
# would convert this into a hard clone failure.
if [ ! -d "${REPO_PATH}/.git" ]; then
  BOOTSTRAP_CLONE_OUT="$(mktemp)"
  CLEANUP_FILES+=("${BOOTSTRAP_CLONE_OUT}")
  set +e
  PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
    REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
    BRANCH="${T[branch]:-}" \
    bash "${SCRIPT_DIR}/clone_or_pull.sh" >"${BOOTSTRAP_CLONE_OUT}" 2>&1
  BOOT_RC=$?
  set -e
  # Land diagnostics where an operator can find them. After a successful clone
  # DISPATCHER_LOG_DIR exists (clone_or_pull.sh created it); after a FAILED first
  # clone it does NOT — which is exactly when the error matters most — so fall
  # back to a fixed out-of-repo path. This fallback is a deliberate persistent
  # diagnostic, so it is
  # NOT registered in CLEANUP_FILES. Raw output never enters chat regardless —
  # the chat reason carries only the file path, never its contents (see the
  # emit_chat_failure contract).
  if [ -d "${DISPATCHER_LOG_DIR}" ]; then
    BOOTSTRAP_LOG_HINT="${DISPATCHER_LOG_DIR}/wrapper.log"
    cat "${BOOTSTRAP_CLONE_OUT}" >>"${BOOTSTRAP_LOG_HINT}" 2>/dev/null || true
  else
    BOOTSTRAP_LOG_HINT="${TMPDIR:-/tmp}/req_executor.bootstrap.${PROJECT}.log"
    cat "${BOOTSTRAP_CLONE_OUT}" >>"${BOOTSTRAP_LOG_HINT}" 2>/dev/null || true
  fi
  [ "${BOOT_RC}" -eq 0 ] || emit_chat_failure "clone_or_pull_failed (bootstrap before flock; exit ${BOOT_RC}; full output in ${BOOTSTRAP_LOG_HINT})"
fi
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -nc '{status:"lock_held", chat_summary:"lock_held (another dispatcher tick is running)", dispatch_entries:[], cleanup_actions:[]}'
  exit 0
fi

# Owner admission is the first campaign-state decision under the project lock.
# In particular, a rejected owner must not reach trigger overrides, pending
# eviction, reconcile, clone, or any campaign_state.json persistence.
DRIVEN_REQUEST_JSON=""
DRIVEN_GRANTS_JSON="[]"
DRIVEN_EXECUTABLE_GRANTS_JSON="[]"
DRIVEN_EXECUTABLE_GRANT_IIDS_JSON="[]"
SKIPPED_ENTRIES_JSON="[]"
if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  DRIVEN_REQUEST_RAW="${T[driven_request_json]:-}"
  if ! DRIVEN_REQUEST_JSON="$(printf '%s' "${DRIVEN_REQUEST_RAW}" | jq -ce \
    --arg project "${PROJECT_FULL}" '
    def clean_string:
      type == "string" and length > 0
      and (explode | all(. >= 32 and . != 127));
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    if type == "object" and ((.grants | type) == "array") then
      .grants |= map(
        if type == "object" then
          (if has("auto_merge") then . else .auto_merge = false end
          | if has("merge_target_branch") then . else .merge_target_branch = null end)
        else . end)
    else . end
    |
    if type != "object"
       or (exact_keys(["owner_id","grants"]) | not)
       or (.owner_id | clean_string | not)
       or ((.grants | type) != "array")
       or ((.grants | length) == 0)
       or (all(.grants[];
            type == "object"
            and exact_keys(["job_id","batch_id","snapshot_index","project","iid","branch","entry_mode","force_rerun_pr","auto_merge","merge_target_branch"])
            and (.job_id | clean_string)
            and (.batch_id | clean_string)
            and (.project == $project)
            and (.branch == null or (.branch | clean_string))
            and (.snapshot_index | type == "number" and . == floor and . >= 0)
            and (.iid | type == "number" and . == floor and . >= 1)
            and (.entry_mode == "auto" or .entry_mode == "fresh" or .entry_mode == "continue")
            and (.force_rerun_pr | type == "boolean")
            and (.auto_merge | type == "boolean")
            and (.merge_target_branch == null or (.merge_target_branch | clean_string))
            and (.auto_merge == false or (.merge_target_branch | clean_string))) | not)
       or ([.grants[] | [.project,.iid]] | group_by(.) | any(length > 1))
       or ([.grants[].job_id] | group_by(.) | any(length > 1))
       or ([.grants[] | [.batch_id,.snapshot_index]] | group_by(.) | any(length > 1))
    then error("invalid") else . end
  ' 2>/dev/null)"; then
    emit_chat_failure "invalid_driven_request_json"
  fi
  DRIVEN_GRANTS_JSON="$(printf '%s' "${DRIVEN_REQUEST_JSON}" | jq -c '.grants')"
  REQUESTED_OWNER_ID="$(printf '%s' "${DRIVEN_REQUEST_JSON}" | jq -r '.owner_id')"
  REQUESTED_OWNER_MODE="driven"
else
  REQUESTED_OWNER_ID="${T[dispatch_owner_id]:-scheduled}"
  case "${REQUESTED_OWNER_ID}" in
    ''|*[[:cntrl:]]*) emit_chat_failure "invalid_dispatch_owner_id" ;;
  esac
  REQUESTED_OWNER_MODE="scheduled"
fi

STATE_JSON="$(load_state)"
INITIAL_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
  | jq -c '(.pending_subagents // {}) | keys | map(tonumber) | sort')"
OWNER_NOW="$(utc_now)"
OWNER_DECISION="$(dispatch_owner_transition "${STATE_JSON}" \
  "${REQUESTED_OWNER_MODE}" "${REQUESTED_OWNER_ID}" "${OWNER_NOW}")"
if [ "$(printf '%s' "${OWNER_DECISION}" | jq -r '.allowed')" != "true" ]; then
  OWNER_BUSY_STATUS="$(printf '%s' "${OWNER_DECISION}" | jq -r '.status')"
  if [ "$(printf '%s' "${OWNER_DECISION}" | jq -r '.migration_required // false')" = "true" ]; then
    persist_state "$(printf '%s' "${OWNER_DECISION}" | jq -c '.updated_state')"
  fi
  jq -nc --arg status "${OWNER_BUSY_STATUS}" \
    '{status:$status, dispatch_entries:[], cleanup_actions:[], chat_summary:$status}'
  exit 0
fi
STATE_JSON="$(printf '%s' "${OWNER_DECISION}" | jq -c '.updated_state')"
DRIVEN_GRANT_IIDS_JSON="[]"
if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  DRIVEN_GRANT_IIDS_JSON="$(printf '%s' "${DRIVEN_GRANTS_JSON}" | jq -c 'map(.iid)')"
  DRIVEN_SCOPE_IIDS_JSON="$(jq -nc \
    --argjson pending "${INITIAL_PENDING_IIDS_JSON}" \
    --argjson grants "${DRIVEN_GRANT_IIDS_JSON}" \
    '($pending + $grants) | unique | sort')"
  T[issue_iids]="$(printf '%s' "${DRIVEN_SCOPE_IIDS_JSON}" | jq -r 'join(",")')"
  T[issue_min_iid]="$(printf '%s' "${DRIVEN_SCOPE_IIDS_JSON}" | jq -r 'min')"
  T[issue_max_iid]="$(printf '%s' "${DRIVEN_SCOPE_IIDS_JSON}" | jq -r 'max')"
fi

wrapper_log prepare_tick "tick started project=${PROJECT}"
TICK_START_TS="$(date -u +%s)"

if [ -z "${T[branch]:-}" ]; then
  T[branch]="$(resolve_origin_default_branch "${REPO_PATH}")" || \
    emit_chat_failure "unable_to_resolve_default_branch"
  wrapper_log prepare_tick "resolved branch from origin/HEAD: ${T[branch]}"
fi

# Self-heal: restore +x on scripts/safety_bin/* in case deployment dropped
# the mode bit. Must run before any Phase 4 prep that ends up invoking
# run_acpx_attempt.sh inside the subagent (which asserts the bit). Safe to
# call here because the wrapper log is now writeable; chmod is local-only
# (no GitLab traffic, no flock contention).
ensure_safety_bin_executable

# ─── 6. Load state + apply trigger override ──────────────────────
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
STUCK_AFTER="${T[stuck_after_minutes]:-}"
ACPX_TIMEOUT="${T[acpx_timeout_seconds]:-}"

# Defaults when trigger omits.
[ -z "${MAX_CONCURRENT}" ] && MAX_CONCURRENT=1
[ -z "${ACPX_TIMEOUT}"   ] && ACPX_TIMEOUT=3600

case "${MAX_CONCURRENT}" in *[!0-9]*|"") emit_chat_failure "invalid_max_concurrent_subagents: must be >= 1" ;; esac
[ "${MAX_CONCURRENT}" -ge 1 ] || emit_chat_failure "invalid_max_concurrent_subagents: must be >= 1"
case "${ACPX_TIMEOUT}" in *[!0-9]*|"") emit_chat_failure "invalid_acpx_timeout_seconds: must be between 60 and 18000" ;; esac
if [ "${ACPX_TIMEOUT}" -lt 60 ] || [ "${ACPX_TIMEOUT}" -gt 18000 ]; then
  emit_chat_failure "invalid_acpx_timeout_seconds: must be between 60 and 18000"
fi
# stuck_after_minutes keeps the dispatcher backstop beyond the recommended
# global OpenClaw subagent limit of acpx_timeout_seconds + 2400 seconds.
# Operators may still override explicitly for tighter or looser eviction.
[ -z "${STUCK_AFTER}" ] && STUCK_AFTER="$(derive_stuck_after_minutes "${ACPX_TIMEOUT}")"
case "${STUCK_AFTER}" in *[!0-9]*|"") emit_chat_failure "invalid_stuck_after_minutes: must be >= 5" ;; esac
[ "${STUCK_AFTER}" -ge 5 ] || emit_chat_failure "invalid_stuck_after_minutes: must be >= 5"

KILL_TERMINAL="${T[kill_subagent_on_terminal]:-}"
if [ -n "${KILL_TERMINAL}" ]; then
  KILL_TERMINAL="$(to_bool "${KILL_TERMINAL}")"
  [ "${KILL_TERMINAL}" = INVALID ] && emit_chat_failure "invalid_kill_subagent_on_terminal"
else
  KILL_TERMINAL="false"
  # Legacy compatibility: kill_subagent_on_done is accepted when the new field
  # is omitted, but terminal session cleanup is no longer enabled by default.
  if [ -n "${T[kill_subagent_on_done]:-}" ]; then
    legacy="$(to_bool "${T[kill_subagent_on_done]}")"
    [ "${legacy}" = INVALID ] && emit_chat_failure "invalid_kill_subagent_on_done"
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

# model_tiers (JSON array) + continue_upgrade_threshold (int): optional,
# carry-forward. When the trigger supplies them they override the persisted
# value; when omitted the persisted value is preserved (// $prior.* in the
# merge filter below). model_tiers is validated as a JSON array here;
# continue_upgrade_threshold is validated as an integer >= 1.
MODEL_TIERS_PROVIDED=false
MODEL_TIERS_JSON="null"
if [ -n "${T[model_tiers]:-}" ]; then
  if ! MODEL_TIERS_JSON="$(printf '%s' "${T[model_tiers]}" | jq -ce 'if type == "array" and (all(.[]; (.tier | type == "string" and (length > 0)) and (.settings | type == "string" and (length > 0)))) then . else error("invalid") end' 2>/dev/null)"; then
    emit_chat_failure "invalid_model_tiers: must be a JSON array of {tier:non-empty-string, settings:non-empty-string}"
  fi
  MODEL_TIERS_PROVIDED=true
fi

CONT_UPGRADE_THRESHOLD_PROVIDED=false
CONT_UPGRADE_THRESHOLD="null"
if [ -n "${T[continue_upgrade_threshold]:-}" ]; then
  case "${T[continue_upgrade_threshold]}" in
    *[!0-9]*|"") emit_chat_failure "invalid_continue_upgrade_threshold: must be >= 1" ;;
  esac
  [ "${T[continue_upgrade_threshold]}" -ge 1 ] || emit_chat_failure "invalid_continue_upgrade_threshold: must be >= 1"
  CONT_UPGRADE_THRESHOLD="${T[continue_upgrade_threshold]}"
  CONT_UPGRADE_THRESHOLD_PROVIDED=true
fi

# result_note_enabled (bool): optional, carry-forward. Opt-in switch for the
# Phase 6 result callback (result_notify_loop.md, option A). When the trigger
# supplies it, it overrides; when omitted, the persisted value is preserved
# (default false). Off by default so existing deployments are unaffected.
RESULT_NOTE_PROVIDED=false
RESULT_NOTE_ENABLED="false"
if [ -n "${T[result_note_enabled]:-}" ]; then
  RESULT_NOTE_ENABLED="$(to_bool "${T[result_note_enabled]}")"
  [ "${RESULT_NOTE_ENABLED}" = INVALID ] && emit_chat_failure "invalid_result_note_enabled"
  RESULT_NOTE_PROVIDED=true
fi

# Apply trigger overrides into the state JSON.
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
  --arg project "${PROJECT}" \
  --argjson result_note_provided "${RESULT_NOTE_PROVIDED}" \
  --argjson result_note_enabled "${RESULT_NOTE_ENABLED}" \
  --argjson model_tiers_provided "${MODEL_TIERS_PROVIDED}" \
  --argjson model_tiers "${MODEL_TIERS_JSON}" \
  --argjson cont_threshold_provided "${CONT_UPGRADE_THRESHOLD_PROVIDED}" \
  --argjson cont_threshold "${CONT_UPGRADE_THRESHOLD}" \
  --arg branch "${T[branch]}" \
  --arg repo_path "${REPO_PARENT_PATH}" \
  --argjson issue_min_iid "${T[issue_min_iid]}" \
  --argjson issue_max_iid "${T[issue_max_iid]}" \
  --argjson hourly_issue_quota "${T[hourly_issue_quota]}" \
  --argjson max_runtime_minutes "${T[max_runtime_minutes]}" \
  --argjson blocked_retry_limit "${T[blocked_retry_limit]}" \
  --argjson blocked_cooldown_ticks "${T[blocked_cooldown_ticks]}" \
  --argjson max_concurrent_subagents "${MAX_CONCURRENT}" \
  --argjson stuck_after_minutes "${STUCK_AFTER}" \
  --argjson acpx_timeout_seconds "${ACPX_TIMEOUT}" \
  --argjson kill_subagent_on_terminal "${KILL_TERMINAL}" \
  --argjson issue_iids_whitelist "${ISSUE_IIDS_JSON}" \
  --argjson require_labels "${REQ_LABELS_JSON}" \
  --arg require_labels_match "${REQ_LABELS_MATCH}" '
  . + {
    project: $project,
    branch: $branch,
    repo_path: $repo_path,
    model_tiers: (if $model_tiers_provided then $model_tiers else (.model_tiers // null) end),
    continue_upgrade_threshold: (if $cont_threshold_provided then $cont_threshold else (.continue_upgrade_threshold // 2) end),
    issue_min_iid: $issue_min_iid,
    issue_max_iid: $issue_max_iid,
    hourly_issue_quota: $hourly_issue_quota,
    max_runtime_minutes: $max_runtime_minutes,
    blocked_retry_limit: $blocked_retry_limit,
    blocked_cooldown_ticks: $blocked_cooldown_ticks,
    max_concurrent_subagents: $max_concurrent_subagents,
    stuck_after_minutes: $stuck_after_minutes,
    acpx_timeout_seconds: $acpx_timeout_seconds,
    kill_subagent_on_terminal: $kill_subagent_on_terminal,
    result_note_enabled: (if $result_note_provided then $result_note_enabled else (.result_note_enabled // false) end),
    issue_iids_whitelist: $issue_iids_whitelist,
    require_labels: $require_labels,
    require_labels_match: $require_labels_match,
    tick_seq: ((.tick_seq // 0) + 1),
    blocked_at_tick_by_iid: (.blocked_at_tick_by_iid // {}),
    quota_launched_this_tick: 0,
    quota_completed_this_tick: 0
  }
  | del(.accounts_per_issue, .run_timeout_seconds)')"

# Diagnostic for the "stale scalar in campaign_state.json" class of report
# (e.g. blocked_cooldown_ticks edited 10->1 but the file still shows 10). The
# override merge above unconditionally re-applies every trigger scalar, and
# persist_state below flushes it BEFORE any early return, so a persisted stale
# value can ONLY mean this tick's trigger stdin still literally carried the old
# value (a stale scheduler payload), or no tick reached this point since the
# edit. Logging the values ACTUALLY parsed from this tick's stdin makes that
# self-diagnosing: compare wrapper.log against what you believe you sent.
wrapper_log prepare_tick "trigger scalars parsed: blocked_cooldown_ticks=${T[blocked_cooldown_ticks]} blocked_retry_limit=${T[blocked_retry_limit]} hourly_issue_quota=${T[hourly_issue_quota]} max_runtime_minutes=${T[max_runtime_minutes]} max_concurrent_subagents=${MAX_CONCURRENT}"

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
  | .pending_subagents |= with_entries(
      .value |= (
        if type == "object" then
          (if has("auto_merge") then . else .auto_merge = false end
          | if has("merge_target_branch") then . else .merge_target_branch = null end)
        else . end))
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
  # A driven topup treats the pending set at admission as occupied project
  # capacity. Agent-level orchestration owns those grants; this bridge neither
  # scope-evicts nor re-dispatches them while adding the current grants.
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    continue
  fi
  ENTRY="$(printf '%s' "${STATE_JSON}" | jq -c --arg k "${piid}" '.pending_subagents[$k]')"
  SP_AT="$(printf '%s' "${ENTRY}" | jq -r '.spawned_at // ""')"
  PA_NUM="$(printf '%s' "${ENTRY}" | jq -r '.attempt_number')"
  CHILD_SESSION_KEY="$(printf '%s' "${ENTRY}" | jq -r '.child_session_key // ""')"
  EVICT=false
  EVICT_KIND=""
  # 只要超时就不重试: a stuck-evicted run that already outlived its acpx
  # wall-clock budget is a timeout-shaped termination — synthesize `timeout`
  # (parked in timeout_iids, no auto-retry) instead of `blocked` (retryable).
  # Scope evictions and surviving placeholders are not time-based failures
  # and stay `blocked`. With the default stuck_after_minutes
  # (ceil((acpx_timeout_seconds+2400)/60)+30) every stuck eviction passes the budget
  # check; only an operator-shortened stuck_after_minutes can evict a run
  # early enough to stay `blocked`.
  EVICT_SYNTH="blocked"
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
    SP_EPOCH="$(iso_to_epoch "${SP_AT}")"
    if [ "${SP_EPOCH}" -gt 0 ]; then
      ELAPSED_S=$(( NOW_TS - SP_EPOCH ))
      DELTA=$(( ELAPSED_S / 60 ))
      if [ "${DELTA}" -ge "${STUCK_AFTER}" ]; then
        EVICT=true
        EVICT_KIND="stuck"
        # Judge against the budget pinned in the entry at spawn time; fall
        # back to this tick's value for entries spawned before the field
        # existed. A trigger override applied mid-flight must not change
        # which budget the run is judged against.
        ENTRY_ACPX="$(printf '%s' "${ENTRY}" | jq -r '.acpx_timeout_seconds // empty')"
        [ -n "${ENTRY_ACPX}" ] || ENTRY_ACPX="${ACPX_TIMEOUT}"
        TIMEOUT_FLOOR_S=$(( ENTRY_ACPX - 60 ))
        [ "${TIMEOUT_FLOOR_S}" -lt 0 ] && TIMEOUT_FLOOR_S=0
        if [ "${ELAPSED_S}" -ge "${TIMEOUT_FLOOR_S}" ]; then
          EVICT_SYNTH="timeout"
          REASON="no callback received within stuck_after_minutes (${DELTA} min) and the run outlived acpx_timeout_seconds(${ENTRY_ACPX}) — timeout-shaped, parked without retry"
        else
          REASON="no callback received within stuck_after_minutes (${DELTA} min)"
        fi
      fi
    fi
  fi
  if [ "${EVICT}" = true ]; then
    # Completion guard (Source-of-Truth). A stale pending entry for an earlier
    # attempt can survive an out-of-band `subagents kill` + a later attempt's
    # success across a gateway restart. Regressing it here calls phase6_process
    # → phase6_sync_labels → set_issue_label.sh: the eviction's `add timeout` /
    # `add blocked-dispatcher` STRIPS the live `pr` completion label via the
    # workflow-label mutual-exclusion group (the keep-table never preserves
    # `pr`) — silently destroying a finished issue's terminal state. reconcile
    # can no longer recover a stripped label (the
    # ground truth is already overwritten) and §11 deliberately skips just-
    # evicted IIDs. So consult GitLab live labels BEFORE any regressing write:
    # if the issue is already completed/closed, drain the stale ghost WITHOUT
    # regressing and let §11's reconcile correction classify it completed (we do
    # NOT add it to EVICTED_IIDS_JSON, so §11 does not skip it). We do NOT call
    # phase6_process for the ghost on purpose — the later attempt already wrote
    # the terminal state files and counted quota; re-running phase6_process with
    # a synthesized reply would clobber that completion metadata with nulls and
    # double-count. Best-effort: on reconcile failure the eviction proceeds, so
    # the stuck-eviction backstop stays live when GitLab is unreachable.
    if phase6_iid_completed_live "${piid}"; then
      wrapper_log prepare_tick "completed-ghost-drain iid=${piid}: GitLab live labels show completed/closed — draining stale pending entry without regressing (was about to ${EVICT_KIND}-evict synth=${EVICT_SYNTH})"
      STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c --argjson iid "${piid}" --arg project "${PROJECT}" '
        .pending_subagents       = (.pending_subagents | del(.[($iid|tostring)]))
        | .active_issue_iids     = (.pending_subagents | keys | map(tonumber) | sort)
        | .active_issue_sessions = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))')"
      continue
    fi
    wrapper_log prepare_tick "${EVICT_KIND}-evict iid=${piid} synth=${EVICT_SYNTH} reason='${REASON}'"
    if [ "${EVICT_SYNTH}" = "timeout" ]; then
      REPLY_JSON="$(phase6_synthesize_timeout "${piid}" "${PA_NUM}" "${REASON}")"
    else
      REPLY_JSON="$(phase6_synthesize_blocked "${piid}" "${PA_NUM}" "${REASON}")"
    fi
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

# ─── 9. (relocated) waiting_for_callbacks gate ───────────────────
# The pending gate USED to short-circuit here, BEFORE reconcile. That meant a
# live GitLab label edit made while a batch was in flight (pending non-empty)
# never reached campaign_state.json until the batch drained. The gate now runs
# AFTER reconcile + disk-cache correction (§11 below), so live labels are synced
# on EVERY scheduled tick. See "§11b. Pending gate" just after the correction.

# ─── 10. Reconcile ────────────────────────────────────────────────
RECONCILE_ARGS=(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}"
  REPO_PARENT_PATH="${REPO_PARENT_PATH}")

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
  # Stable, named reason only. The full reconcile.sh output (which may carry
  # raw jq / glab / git stderr) was already appended to wrapper.log above; do
  # NOT tail it into chat_summary (see emit_chat_failure contract).
  emit_chat_failure "reconcile_failed (rc=${RECONCILE_RC}; full output in dispatcher wrapper.log)"
fi
EVIDENCE_PATH="$(grep -E '^/.+/reconcile-[0-9TZ]+\.json$' "${RECONCILE_OUT}" | tail -n 1 || true)"
if [ -z "${EVIDENCE_PATH}" ] || [ ! -f "${EVIDENCE_PATH}" ]; then
  emit_chat_failure "reconcile_failed: evidence file not produced"
fi
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c --arg p "${EVIDENCE_PATH}" '.last_reconcile_evidence = $p')"

# ─── 11. Disk cache correction from evidence ─────────────────────
EVIDENCE_JSON="$(cat "${EVIDENCE_PATH}")"
# Defensive guard: EVIDENCE_JSON is read from a file and is fed straight to
# `jq --argjson ev`, which on an empty / non-JSON / non-array value throws the
# generic "invalid JSON text passed to --argjson". That message surfaces far
# from its cause (a truncated or half-written reconcile evidence file) and
# historically invited a misdiagnosis as a "jq bug". Validate the shape up
# front and fail with a named, terminal reason instead. Every downstream
# consumer ($ev[], $ev | map, $ev | length) requires a JSON array.
EV_KIND="$(printf '%s' "${EVIDENCE_JSON}" | jq -r 'type' 2>/dev/null || echo invalid)"
if [ "${EV_KIND}" != "array" ]; then
  emit_chat_failure "reconcile_failed: evidence file at ${EVIDENCE_PATH} is ${EV_KIND}, expected a JSON array (reconcile.sh produced an empty or malformed file)"
fi
if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  DRIVEN_PREFLIGHT_JSON="$(jq -nc \
    --argjson grants "${DRIVEN_GRANTS_JSON}" \
    --argjson evidence "${EVIDENCE_JSON}" '
    ($evidence | map({key:(.iid|tostring), value:.}) | from_entries) as $by_iid
    | reduce $grants[] as $grant ({executable:[], skipped:[]};
        ($by_iid[($grant.iid|tostring)] // {}) as $live
        | if ($live.is_closed_on_gitlab // false) == true then
            .skipped += [($grant | {
              job_id,batch_id,snapshot_index,project,iid,
              status:"skipped",reason:"closed"
            })]
          elif (((($live.has_done_pr // false) == true)
                  or (($live.has_finish // false) == true)
                  or (($live.is_done_on_gitlab // false) == true)
                 ) and ($grant.force_rerun_pr == false)) then
            .skipped += [($grant | {
              job_id,batch_id,snapshot_index,project,iid,
              status:"skipped",reason:"pr_without_force_rerun"
            })]
          else
            .executable += [($grant
              | if .force_rerun_pr then .entry_mode = "fresh" else . end)]
          end)
  ')"
  DRIVEN_EXECUTABLE_GRANTS_JSON="$(printf '%s' "${DRIVEN_PREFLIGHT_JSON}" | jq -c '.executable')"
  DRIVEN_EXECUTABLE_GRANT_IIDS_JSON="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANTS_JSON}" | jq -c 'map(.iid)')"
  SKIPPED_ENTRIES_JSON="$(printf '%s' "${DRIVEN_PREFLIGHT_JSON}" | jq -c '.skipped')"
fi
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c --argjson ev "${EVIDENCE_JSON}" --argjson evicted "${EVICTED_IIDS_JSON}" '
  . as $s
  | ($s.pending_subagents | keys | map(tonumber)) as $pending
  | reduce $ev[] as $e ($s;
      .completed_iids = (.completed_iids // [])
      | .unfinished_iids = (.unfinished_iids // [])
      | .blocked_iids   = (.blocked_iids // [])
      | .failed_iids    = (.failed_iids // [])
      | .timeout_iids   = (.timeout_iids // [])
      | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid // {})
      | if (($pending | index($e.iid)) != null) or (($evicted | index($e.iid)) != null) then
          # In-flight (doing) IID owned by Phase 6, or an IID this same tick
          # eviction loop just classified blocked/timeout: the live-label pass
          # must NOT reclassify or drain it. Skipping protects pending
          # bookkeeping and the blocked_cooldown_ticks stamp the eviction just
          # wrote (GitLab may still show a slow subagent as doing if its
          # terminal-label sync has not landed, which would otherwise look
          # like user_reopened).
          .
        elif $e.is_closed_on_gitlab == true then
          .completed_iids = (([$e.iid] + .completed_iids) | unique)
          | .unfinished_iids = (.unfinished_iids - [$e.iid])
          | .blocked_iids    = (.blocked_iids    - [$e.iid])
          | .failed_iids     = (.failed_iids     - [$e.iid])
          | .timeout_iids    = (.timeout_iids    - [$e.iid])
          | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid | del(.[$e.iid|tostring]))
        elif (($e.has_done_pr == true) or (($e.has_finish // false) == true)) and $e.needs_continue != true then
          .completed_iids = (([$e.iid] + .completed_iids) | unique)
          | .unfinished_iids = (.unfinished_iids - [$e.iid])
          | .blocked_iids    = (.blocked_iids - [$e.iid])
          | .failed_iids     = (.failed_iids - [$e.iid])
          | .timeout_iids    = (.timeout_iids    - [$e.iid])
          | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid | del(.[$e.iid|tostring]))
        elif $e.needs_continue == true then
          .unfinished_iids = (([$e.iid] + .unfinished_iids) | unique)
          | .completed_iids = (.completed_iids - [$e.iid])
          | .blocked_iids   = (.blocked_iids - [$e.iid])
          | .failed_iids    = (.failed_iids - [$e.iid])
          | .timeout_iids   = (.timeout_iids - [$e.iid])
          | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid | del(.[$e.iid|tostring]))
          | .campaign_status = "running"
        elif $e.has_retry == true then
          # A live `retry` label re-enqueues from scratch and WINS over a
          # lingering blocked / failed / timeout (a reviewer asked to re-run).
          # user_reopened is false whenever blocked/failed is present, so this
          # explicit branch is what makes a stacked blocked+retry / failed+retry
          # actually re-run instead of falling through to the no-op else.
          .unfinished_iids = (([$e.iid] + .unfinished_iids) | unique)
          | .completed_iids = (.completed_iids - [$e.iid])
          | .blocked_iids   = (.blocked_iids - [$e.iid])
          | .failed_iids    = (.failed_iids - [$e.iid])
          | .timeout_iids   = (.timeout_iids - [$e.iid])
          | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid | del(.[$e.iid|tostring]))
        elif $e.user_reopened == true then
          .unfinished_iids = (([$e.iid] + .unfinished_iids) | unique)
          | .completed_iids = (.completed_iids - [$e.iid])
          | .blocked_iids   = (.blocked_iids - [$e.iid])
          | .failed_iids    = (.failed_iids - [$e.iid])
          | .timeout_iids   = (.timeout_iids - [$e.iid])
          | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid | del(.[$e.iid|tostring]))
        elif $e.has_timeout == true then
          # Live label says timeout but our cache disagrees — adopt the truth.
          .timeout_iids     = (([$e.iid] + .timeout_iids) | unique)
          | .unfinished_iids = (.unfinished_iids - [$e.iid])
          | .completed_iids  = (.completed_iids - [$e.iid])
          | .blocked_iids    = (.blocked_iids - [$e.iid])
          | .failed_iids     = (.failed_iids - [$e.iid])
          | .blocked_at_tick_by_iid = (.blocked_at_tick_by_iid | del(.[$e.iid|tostring]))
        else .
      end)
  ')"
persist_state "${STATE_JSON}"

# ─── 11b. Pending gate (relocated from §9) → waiting_for_callbacks ──
# Now runs AFTER reconcile + correction so the cache reflects live GitLab labels
# even while a batch is in flight. Still short-circuits the rest of the tick: no
# new batch forms while pending is non-empty (single-batch-in-flight invariant).
PENDING_COUNT="$(printf '%s' "${STATE_JSON}" | jq -r '.pending_subagents | keys | length')"
if [ "${DISPATCH_MODE}" = "scheduled" ] && [ "${PENDING_COUNT}" -gt 0 ]; then
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.campaign_status = "waiting_for_callbacks"')"
  persist_state "${STATE_JSON}"
  PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.pending_subagents | keys | map(tonumber)')"
  jq -nc \
    --arg ev "${EVIDENCE_PATH}" \
    --argjson pending "${PENDING_IIDS_JSON}" \
    --argjson evicted "${EVICTED_IIDS_JSON}" \
    --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    --arg chat "waiting_for_callbacks; pending=$(jq -c . <<<"${PENDING_IIDS_JSON}") evicted=$(jq -c . <<<"${EVICTED_IIDS_JSON}") scope_evicted=$(jq -c . <<<"${SCOPE_EVICTED_IIDS_JSON}")" '
    {status:"waiting_for_callbacks", dispatch_entries:[], pending_iids:$pending,
     evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
     cleanup_actions:$cleanup_actions, last_reconcile_evidence:$ev, chat_summary:$chat}'
  exit 0
fi

if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  CURRENT_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
    | jq -c '.pending_subagents | keys | map(tonumber) | sort')"
  DRIVEN_EXECUTABLE_GRANT_COUNT="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANT_IIDS_JSON}" | jq 'length')"
  if [ "${DRIVEN_EXECUTABLE_GRANT_COUNT}" -eq 0 ]; then
    jq -nc \
      --arg ev "${EVIDENCE_PATH}" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson pending_iids "${CURRENT_PENDING_IIDS_JSON}" \
      --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[], pending_iids:$pending_iids,
        skipped_entries:$skipped_entries,
        cleanup_actions:$cleanup_actions, chat_summary:"all driven grants skipped by live preflight",
        last_reconcile_evidence:$ev}'
    exit 0
  fi
  DRIVEN_NEW_GRANT_IIDS_JSON="$(jq -nc \
    --argjson grants "${DRIVEN_EXECUTABLE_GRANT_IIDS_JSON}" \
    --argjson initial_pending "${INITIAL_PENDING_IIDS_JSON}" \
    --argjson current_pending "${CURRENT_PENDING_IIDS_JSON}" '
    $grants
    | map(select(. as $iid
        | ($initial_pending | index($iid) == null)
        and ($current_pending | index($iid) == null)))')"
  DRIVEN_AVAILABLE_SLOTS=$(( MAX_CONCURRENT - PENDING_COUNT ))
  [ "${DRIVEN_AVAILABLE_SLOTS}" -lt 0 ] && DRIVEN_AVAILABLE_SLOTS=0
  DRIVEN_NEW_GRANT_COUNT="$(printf '%s' "${DRIVEN_NEW_GRANT_IIDS_JSON}" | jq 'length')"
  if [ "${DRIVEN_NEW_GRANT_COUNT}" -eq 0 ] \
     || [ "${DRIVEN_NEW_GRANT_COUNT}" -gt "${DRIVEN_AVAILABLE_SLOTS}" ]; then
    STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.campaign_status = "waiting_for_callbacks"')"
    persist_state "${STATE_JSON}"
    PENDING_IIDS_JSON="${CURRENT_PENDING_IIDS_JSON}"
    jq -nc \
      --arg ev "${EVIDENCE_PATH}" \
      --argjson pending "${PENDING_IIDS_JSON}" \
      --argjson evicted "${EVICTED_IIDS_JSON}" \
      --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
      --arg chat "waiting_for_callbacks; driven topup has no unoccupied grant slots" '
      {status:"waiting_for_callbacks", dispatch_entries:[], pending_iids:$pending,
       evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
       cleanup_actions:$cleanup_actions, skipped_entries:$skipped_entries,
       last_reconcile_evidence:$ev, chat_summary:$chat}'
    exit 0
  fi
fi

# ─── 12. Early-return: all done? ─────────────────────────────────
ALL_DONE="$(printf '%s' "${STATE_JSON}" | jq -r --argjson ev "${EVIDENCE_JSON}" --argjson universe "${EFF_UNIVERSE_JSON}" '
  if (.issue_iids_whitelist | length) > 0 then false
  elif ((.pending_subagents // {}) | length) > 0 then false
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
  MODEL_TIERS="$(printf '%s' "${STATE_JSON}" | jq -c '.model_tiers // empty')" \
  bash "${SCRIPT_DIR}/ensure_labels.sh" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1
EL_RC=$?
set -e
[ "${EL_RC}" -eq 0 ] || emit_chat_failure "ensure_labels_failed (exit ${EL_RC})"

set +e
(
  export PROJECT GROUP GITLAB_TOKEN REPO_PARENT_PATH
  export BRANCH="${T[branch]:-}"
  bash "${SCRIPT_DIR}/clone_or_pull.sh" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1
)
CP_RC=$?
set -e
[ "${CP_RC}" -eq 0 ] || emit_chat_failure "clone_or_pull_failed (exit ${CP_RC})"

# ─── 14. require_labels filter ────────────────────────────────────
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
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    CURRENT_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
      | jq -c '.pending_subagents | keys | map(tonumber) | sort')"
    jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "time_budget reached before launch (elapsed_min=${ELAPSED_MIN})" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson pending_iids "${CURRENT_PENDING_IIDS_JSON}" \
      --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[], pending_iids:$pending_iids,
        skipped_entries:$skipped_entries,
        cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  else
    jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "time_budget reached before launch (elapsed_min=${ELAPSED_MIN})" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[], cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  fi
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

if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  # Agent scheduler grants already account for agent-wide capacity. At the
  # project layer, only the slots not occupied by current pending entries are
  # available to this topup; hourly scheduled quota does not re-filter grants.
  BATCH_CAP="${DRIVEN_AVAILABLE_SLOTS}"
else
  BATCH_CAP="${MAX_CONCURRENT}"
  [ "${QUOTA_LEFT}" -lt "${BATCH_CAP}" ] && BATCH_CAP="${QUOTA_LEFT}"
fi

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
        and (((($e.has_done_pr // false) != true) and (($e.has_finish // false) != true))
             or ($e.needs_continue // false) == true)
      ))) as $eligible
  | ($eligible | map(select(. as $i |
      (($s.blocked_iids // []) | index($i) | not)
      and (($s.timeout_iids // []) | index($i) | not)
      and (($s.unfinished_iids // []) | index($i))
      and (($byiid[($i|tostring)] // {}) as $e
           | ((($e.has_blocked // false) != true) and (($e.has_failed // false) != true))
             or (($e.has_retry // false) == true) or (($e.needs_continue // false) == true))
    )) | sort) as $backlog
  | ($eligible | map(select(. as $i |
      (($s.blocked_iids // []) | index($i) | not)
      and (($s.unfinished_iids // []) | index($i) | not)
      and (($s.completed_iids // []) | index($i) | not)
      and (($s.failed_iids // []) | index($i) | not)
      and (($s.timeout_iids // []) | index($i) | not)
      and ($i >= $next_new)
      and (($byiid[($i|tostring)] // {}) as $e
           | ((($e.has_blocked // false) != true) and (($e.has_failed // false) != true))
             or (($e.has_retry // false) == true) or (($e.needs_continue // false) == true))
    )) | sort) as $fresh
  | ($eligible | map(select(. as $i |
      (($s.blocked_iids // []) | index($i))
      and (($s.timeout_iids // []) | index($i) | not)
    )) | sort) as $blocked_retryable_raw
  | # blocked_iids invariant: only retryable entries are in this list.
    # Phase 6 promotes blocked → failed (and moves the IID into failed_iids)
    # whenever retry_count > blocked_retry_limit. Launch-side synthesized
    # blocked replies (dispatch_record_spawn.sh STATUS=launch_failed) and
    # the rare early stuck-pending evictions that stay blocked (run did NOT
    # outlive acpx_timeout_seconds — possible only under an operator-shortened
    # stuck_after_minutes; budget-exhausted evictions synthesize timeout and
    # land in timeout_iids instead) both DO NOT
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

if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  BATCH_JSON="$(jq -nc \
    --argjson grants "${DRIVEN_EXECUTABLE_GRANT_IIDS_JSON}" \
    --argjson initial_pending "${INITIAL_PENDING_IIDS_JSON}" \
    --argjson current_pending "${CURRENT_PENDING_IIDS_JSON}" \
    --argjson cap "${BATCH_CAP}" '
    $grants
    | map(select(. as $iid
        | ($initial_pending | index($iid) == null)
        and ($current_pending | index($iid) == null)))
    | .[0:$cap]')"
fi

BATCH_SIZE="$(printf '%s' "${BATCH_JSON}" | jq -r 'length')"
if [ "${BATCH_SIZE}" = "0" ]; then
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    CURRENT_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
      | jq -c '.pending_subagents | keys | map(tonumber) | sort')"
    jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "no eligible IIDs this tick" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson pending_iids "${CURRENT_PENDING_IIDS_JSON}" \
      --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[], pending_iids:$pending_iids,
        skipped_entries:$skipped_entries,
        cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  else
    jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "no eligible IIDs this tick" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[], cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  fi
  exit 0
fi

# Move the fresh-issue cursor past any fresh IID selected for this batch. The
# backlog/blocked paths do not affect it.
if [ "${DISPATCH_MODE}" = "scheduled" ]; then
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
    --argjson batch "${BATCH_JSON}" \
    --argjson fresh "${FRESH_JSON}" '
    ($batch - ($batch - $fresh)) as $fresh_batch
    | if ($fresh_batch | length) > 0 then
        .next_new_issue_iid = ([.next_new_issue_iid // .issue_min_iid, (($fresh_batch | max) + 1)] | max)
      else . end')"
fi

# ─── 17. Allocate attempt numbers ─────────────────────────────────
declare -A ATTEMPT
mapfile -t BATCH_IIDS < <(printf '%s' "${BATCH_JSON}" | jq -r '.[]')
# allocate_attempt.sh prints ONLY the integer attempt number on stdout. Capture
# its exit code and stderr explicitly: under `set -e` a non-zero exit inside the
# `N="$(...)"` assignment aborts the whole tick with a raw, unclassified error
# and no JSON envelope on stdout — exactly the failure shape a weak orchestrator
# model tries to "diagnose" and self-heal. Convert it into a named, terminal
# tick failure instead. (An rc=0-but-empty/non-numeric stdout is caught by the
# integer guard before step 19.)
ALLOC_ERR="$(mktemp)"
CLEANUP_FILES+=("${ALLOC_ERR}")
for iid in "${BATCH_IIDS[@]}"; do
  set +e
  N="$(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
       REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
       IID="${iid}" \
       bash "${SCRIPT_DIR}/allocate_attempt.sh" 2>"${ALLOC_ERR}")"
  _rc=$?
  set -e
  if [ "${_rc}" -ne 0 ]; then
    # Capture allocate_attempt.sh stderr to wrapper.log first, then emit a
    # stable, named reason only — never tail raw sub-tool stderr into
    # chat_summary (see emit_chat_failure contract + SOUL.md §No-Fallback).
    wrapper_log prepare_tick "allocate_attempt_failed iid=${iid} rc=${_rc} (stderr follows)"
    cat "${ALLOC_ERR}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>/dev/null || true
    emit_chat_failure "allocate_attempt_failed: iid=${iid} (rc=${_rc}; stderr in dispatcher wrapper.log)"
  fi
  ATTEMPT["${iid}"]="${N}"
done

# ─── 18. Pre-spawn persist (placeholder pending entries) ──────────
# Defensive guard: every value below is passed to `jq --argjson`, which rejects
# a non-JSON token with the generic "invalid JSON text passed to --argjson".
# An empty ATTEMPT[$iid] (allocate_attempt.sh printed nothing) would surface
# far from its real cause and invite a misdiagnosis as a "jq version bug".
# Validate it here once and fail with a named, terminal reason.
for iid in "${BATCH_IIDS[@]}"; do
  for _pair in "iid:${iid}" "attempt:${ATTEMPT[$iid]:-}"; do
    _field="${_pair%%:*}"; _val="${_pair#*:}"
    case "${_val}" in
      ''|*[!0-9]*)
        emit_chat_failure "prep_invariant_violation: iid=${iid} ${_field}='${_val}' is not a non-negative integer (allocate_attempt.sh produced an empty/non-numeric value); refusing to build a malformed jq --argjson call"
        ;;
    esac
  done
done

PRE_PENDING_JQ_ARGS=()
for iid in "${BATCH_IIDS[@]}"; do
  PRE_PENDING_JQ_ARGS+=( --argjson "iid_${iid}" "${iid}"
                         --argjson "att_${iid}" "${ATTEMPT[$iid]}" )
done
# Build the placeholder additions in one jq pass to avoid quoting hell.
# active_issue_sessions uses the canonical "issue-<project>-<iid>" format
# per state_schema.md §active_issue_iids / active_issue_sessions.
# acpx_timeout_seconds pins the wall-clock budget in effect at spawn time:
# the timeout-shaped classification (followup empty/unparseable callback,
# stuck eviction) must compare elapsed time against THIS run's budget, not
# against whatever a later trigger overrode the campaign-level value to.
PRE_PENDING_JQ_ARGS+=( --arg project "${PROJECT}" --argjson acpx_timeout "${ACPX_TIMEOUT}" )
FILTER='.pending_subagents = (.pending_subagents // {})'
for iid in "${BATCH_IIDS[@]}"; do
  FILTER+=" | .pending_subagents[\"${iid}\"] = {attempt_number: \$att_${iid}, run_id: null, child_session_key: null, spawned_at: null, placeholder: true, acpx_timeout_seconds: \$acpx_timeout, auto_merge: false, merge_target_branch: null}"
done
FILTER+=' | .active_issue_iids = (.pending_subagents | keys | map(tonumber) | sort)'
FILTER+=' | .active_issue_sessions = (.active_issue_iids | map("issue-" + $project + "-" + (.|tostring)))'
STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c "${PRE_PENDING_JQ_ARGS[@]}" "${FILTER}")"
if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  # Task 7 contract: after this project campaign lock is released, Task 7 must
  # resolve the latest memberships by job_id under the agent scheduler lock while
  # the scheduler job is still active and before recording that scheduler job terminal.
  # batch_id/snapshot_index below identify this grant only; they are never a
  # frozen membership array, and this script never reads agent scheduler state.
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
    --argjson grants "${DRIVEN_EXECUTABLE_GRANTS_JSON}" \
    --argjson batch "${BATCH_JSON}" '
    reduce ($grants[] | select(.iid as $iid | $batch | index($iid) != null)) as $grant (.;
      .pending_subagents[($grant.iid | tostring)] +=
        (($grant | {job_id,batch_id,snapshot_index,branch,entry_mode,force_rerun_pr,auto_merge,merge_target_branch})
         + {memberships_source:"scheduler_active_job"}))')"
fi
persist_state "${STATE_JSON}"

# ─── 19. Per-IID prep ─────────────────────────────────────────────
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
  IID_BRANCH="${T[branch]}"
  GRANT_ENTRY_MODE="auto"
  IID_FORCE_RERUN_PR="false"
  IID_AUTO_MERGE="false"
  IID_MERGE_TARGET_BRANCH="${T[branch]}"
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    IID_GRANT_JSON="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANTS_JSON}" \
      | jq -c --argjson iid "${iid}" '.[] | select(.iid == $iid)')"
    IID_BRANCH="$(printf '%s' "${IID_GRANT_JSON}" \
      | jq -r --arg default_branch "${T[branch]}" '.branch // $default_branch')"
    GRANT_ENTRY_MODE="$(printf '%s' "${IID_GRANT_JSON}" | jq -r '.entry_mode')"
    IID_FORCE_RERUN_PR="$(printf '%s' "${IID_GRANT_JSON}" | jq -r '.force_rerun_pr')"
    IID_AUTO_MERGE="$(printf '%s' "${IID_GRANT_JSON}" | jq -r '.auto_merge')"
    IID_MERGE_TARGET_BRANCH="$(printf '%s' "${IID_GRANT_JSON}" \
      | jq -r --arg default_branch "${IID_BRANCH}" '.merge_target_branch // $default_branch')"
  fi
  IID_BRANCH_QUOTED="'${IID_BRANCH//\'/\'\\\'\'}'"
  IID_MERGE_TARGET_BRANCH_QUOTED="'${IID_MERGE_TARGET_BRANCH//\'/\'\\\'\'}'"

  # Per-IID env for env_paths-derived paths.
  iid_env=(
    PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}"
    REPO_PARENT_PATH="${REPO_PARENT_PATH}"
    ISSUE_IID="${iid}" ATTEMPT_NUMBER="${attempt}"
  )

  # Resolve ISSUE_MODE from live labels. `continue` / `contiune` is the only
  # resume signal. Every other entry path (`todo`, `retry`, `new`,
  # `blocked`, trigger require_labels) resets from the target branch
  # baseline, even if this IID has prior attempts on disk.
  ISSUE_MODE="fresh"
  if [ "${DISPATCH_MODE}" = "driven_topup" ] && [ "${GRANT_ENTRY_MODE}" != "auto" ]; then
    ISSUE_MODE="${GRANT_ENTRY_MODE}"
  else
    NEEDS_CONTINUE="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | .needs_continue // false')"
    RESET_REQUESTED="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '
      (.[] | select(.iid==$i) | .labels // []) as $labels
      | (($labels | index("retry") != null) or ($labels | index("todo") != null))
    ')"
    if [ "${NEEDS_CONTINUE}" = "true" ] && [ "${RESET_REQUESTED}" != "true" ]; then
      ISSUE_MODE="continue"
    fi
  fi
  ALLOW_TERMINAL_RERUN="false"
  if [ "${ISSUE_MODE}" = "continue" ] \
      || [ "${IID_FORCE_RERUN_PR}" = "true" ]; then
    ALLOW_TERMINAL_RERUN="true"
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

  # Reconciliation is a snapshot.  A terminal label/state may land after that
  # snapshot but before this IID reaches its mutation boundary.  Drain the
  # placeholder as a completed skip instead of routing the race through
  # prep_blocked (which would overwrite the stronger terminal state).
  prep_terminal_skip() {
    local reason="$1"
    wrapper_log prepare_tick \
      "iid=${iid} terminal-race skip during prep: ${reason}"
    STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
      --argjson iid "${iid}" --arg project "${PROJECT}" '
        .pending_subagents = ((.pending_subagents // {}) | del(.[($iid|tostring)]))
        | .active_issue_iids = (.pending_subagents | keys | map(tonumber) | sort)
        | .active_issue_sessions = (.active_issue_iids
            | map("issue-" + $project + "-" + (.|tostring)))
        | .completed_iids = (([ $iid ] + (.completed_iids // [])) | unique)
        | .unfinished_iids = ((.unfinished_iids // []) - [$iid])
        | .blocked_iids = ((.blocked_iids // []) - [$iid])
        | .failed_iids = ((.failed_iids // []) - [$iid])
        | .timeout_iids = ((.timeout_iids // []) - [$iid])
        | .blocked_at_tick_by_iid = ((.blocked_at_tick_by_iid // {})
            | del(.[($iid|tostring)]))
      ')"
    if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
      SKIPPED_ENTRIES_JSON="$(printf '%s' "${SKIPPED_ENTRIES_JSON}" | jq -c \
        --argjson grant "${IID_GRANT_JSON}" --arg reason "${reason}" '
          if any(.[]; .job_id == $grant.job_id) then .
          else . + [($grant | {
            job_id,batch_id,snapshot_index,project,iid,
            status:"skipped",reason:$reason
          })]
          end
        ')"
    fi
    persist_state "${STATE_JSON}"
    TICK_OUTCOMES="$(printf '%s' "${TICK_OUTCOMES}" | jq -c \
      --arg k "${iid}" --arg v "skipped: ${reason}" '. + {($k):$v}')"
  }

  # prepare_attempt.sh — keep stdout clean (the script's contract is two
  # lines on stdout: mode_actual, LOCAL_ATTEMPT_BRANCH). `git fetch` /
  # `git worktree add` etc. write progress to stderr; we capture stderr
  # to a separate file so it does NOT contaminate the two output lines.
  PA_OUT="$(mktemp)"
  PA_ERR="$(mktemp)"
  CLEANUP_FILES+=("${PA_OUT}" "${PA_ERR}")
  set +e
  env "${iid_env[@]}" BRANCH="${IID_BRANCH}" \
    ISSUE_MODE="${ISSUE_MODE}" \
    bash "${SCRIPT_DIR}/prepare_attempt.sh" >"${PA_OUT}" 2>"${PA_ERR}"
  PA_RC=$?
  set -e
  # Mirror stderr into wrapper.log for post-mortem (even on success — git
  # progress is interesting context).
  cat "${PA_ERR}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>/dev/null || true
  if [ "${PA_RC}" -ne 0 ]; then
    # PA_ERR (raw git fetch / worktree stderr) is already mirrored to
    # wrapper.log on the preceding cat; emit a stable, named reason only so
    # raw git output never reaches block_reason / tick_outcome_per_iid (see
    # emit_chat_failure contract + SOUL.md §No-Fallback rule 1).
    prep_blocked "prepare_attempt_failed (rc=${PA_RC}; stderr in dispatcher wrapper.log)"
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

  # ── resolve_model_tier（D：model:{tier} 文件式自动升档；仅当 model_tiers 配置）──
  RESOLVED_MODEL_TIER=""
  MODEL_SETTINGS_SRC=""
  MT_JSON="$(printf '%s' "${STATE_JSON}" | jq -c '.model_tiers // empty')"
  if [ -n "${MT_JSON}" ] && [ "${MT_JSON}" != "null" ] && [ "$(printf '%s' "${MT_JSON}" | jq 'length')" -gt 0 ]; then
    mapfile -t MT_TIERS < <(printf '%s' "${MT_JSON}" | jq -r '.[].tier')
    if [ "${#MT_TIERS[@]}" -eq 0 ]; then
      prep_blocked "model_tiers configured but empty/invalid"; continue
    fi
    DEFAULT_TIER="${MT_TIERS[0]}"
    CAP_TIER="${MT_TIERS[$(( ${#MT_TIERS[@]} - 1 ))]}"
    # 当前档：live model 标签（reconcile evidence）→ state.json 缓存 → TIER_0
    CUR_TIER="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | .model_tier // empty')"
    [ -n "${CUR_TIER}" ] || CUR_TIER="$( [ -f "${ISSUES_ROOT}/issue-${iid}/state.json" ] && jq -r '.model_tier // empty' "${ISSUES_ROOT}/issue-${iid}/state.json" || true )"
    [ -n "${CUR_TIER}" ] || CUR_TIER="${DEFAULT_TIER}"
    PRIOR_STATE="$( [ -f "${ISSUES_ROOT}/issue-${iid}/state.json" ] && cat "${ISSUES_ROOT}/issue-${iid}/state.json" || echo '{}' )"
    PRIOR_STATUS="$(printf '%s' "${PRIOR_STATE}" | jq -r '.status // ""')"
    PRIOR_SIDE="$(printf '%s' "${PRIOR_STATE}" | jq -r '.block_side // ""')"
    CONT_COUNT="$(printf '%s' "${PRIOR_STATE}" | jq -r '.continue_count // 0')"
    CONT_THRESHOLD="$(printf '%s' "${STATE_JSON}" | jq -r '.continue_upgrade_threshold // 2')"
    HAS_QUALITY_LOW="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | (.labels // []) | index("quality:low") != null')"
    UPGRADE="no"
    # 硬触发：CC 侧 {blocked-cc, timeout, failed-cc}（timeout 恒 CC）
    case "${PRIOR_STATUS}" in
      timeout) UPGRADE="yes" ;;
      blocked|failed) [ "${PRIOR_SIDE}" = "cc" ] && UPGRADE="yes" ;;
    esac
    # 软触发：quality:low ∨ continue 累计 ≥ 阈值（自动评分=占位 no-op）
    [ "${HAS_QUALITY_LOW}" = "true" ] && UPGRADE="yes"
    # 计入当前这次 continue：本 tick 的 continue_count 自增发生在 state.json init（晚于本块），
    # 故这里用 effective = 磁盘值 + 当前是否 continue，确保第 N 次 continue 即触发（而非第 N+1 次）。
    EFFECTIVE_CONT_COUNT="${CONT_COUNT}"
    [ "${MODE_ACTUAL}" = "continue" ] && EFFECTIVE_CONT_COUNT=$(( CONT_COUNT + 1 ))
    [ "${EFFECTIVE_CONT_COUNT}" -ge "${CONT_THRESHOLD}" ] && [ "${CONT_THRESHOLD}" -ge 1 ] && UPGRADE="yes"
    # 定位当前档索引；未知/失效缓存档（如运维改了 tier 名）→ 回落 DEFAULT_TIER（TIER_0）
    cur_idx=-1
    for i_t in "${!MT_TIERS[@]}"; do [ "${MT_TIERS[$i_t]}" = "${CUR_TIER}" ] && cur_idx="${i_t}"; done
    if [ "${cur_idx}" -lt 0 ]; then
      echo "resolve_model_tier: iid=${iid} cached model_tier '${CUR_TIER}' not in current model_tiers; resetting to default '${DEFAULT_TIER}'" >>"${DISPATCHER_LOG_DIR}/wrapper.log"
      CUR_TIER="${DEFAULT_TIER}"; cur_idx=0
    fi
    # 求新档（单调升、封顶）；cur_idx 此时恒有效 → NEW_TIER 恒为列表内合法档
    NEW_TIER="${CUR_TIER}"
    if [ "${UPGRADE}" = "yes" ] && [ "$(( cur_idx + 1 ))" -lt "${#MT_TIERS[@]}" ]; then
      NEW_TIER="${MT_TIERS[$(( cur_idx + 1 ))]}"
    fi
    RESOLVED_MODEL_TIER="${NEW_TIER}"
    MODEL_SETTINGS_SRC="$(printf '%s' "${MT_JSON}" | jq -r --arg t "${NEW_TIER}" '.[] | select(.tier==$t) | .settings // empty')"
    # model 维度互斥：移除该 issue 现有所有 model:* 标签（除新档），再 add 新档。
    # 按 reconcile 证据枚举现有标签，可一并清掉因 tier 改名残留的孤儿档。
    while IFS= read -r _ml; do
      [ -z "${_ml}" ] && continue
      [ "${_ml}" = "model:${NEW_TIER}" ] && continue
      env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" remove "${_ml}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    done < <(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | (.labels // [])[] | select(startswith("model:"))')
    env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" add "model:${NEW_TIER}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    if [ "${HAS_QUALITY_LOW}" = "true" ]; then
      env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" remove "quality:low" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    fi
  fi

  # claude_settings_path
  # model_tiers 档位 settings 优先（D）
  if [ -n "${MODEL_SETTINGS_SRC}" ]; then
    case "${MODEL_SETTINGS_SRC}" in
      /) prep_blocked "model_tiers settings must not be /"; continue ;;
      /*) : ;;
      *) prep_blocked "model_tiers settings must be absolute: ${MODEL_SETTINGS_SRC}"; continue ;;
    esac
    case "${MODEL_SETTINGS_SRC}" in
      *..*|*' '*|*[!A-Za-z0-9_./-]*) prep_blocked "invalid model_tiers settings path: ${MODEL_SETTINGS_SRC}"; continue ;;
    esac
    if [ ! -r "${MODEL_SETTINGS_SRC}" ]; then
      prep_blocked "model_tiers settings file not found or not readable: ${MODEL_SETTINGS_SRC}"; continue
    fi
    # WORKTREE_DIR is derivable via env_paths.sh, but env_paths.sh exits if
    # ATTEMPT_NUMBER is missing. We already set it for this iid; source in subshell.
    WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
    if ! cp "${MODEL_SETTINGS_SRC}" "${WORKTREE_DIR_X}/.claude/settings.json"; then
      prep_blocked "model_tiers settings copy failed"; continue
    fi
    git -C "${WORKTREE_DIR_X}" update-index \
      --skip-worktree .claude/settings.json || true
  elif [ -n "${T[claude_settings_path]:-}" ]; then
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
    git -C "${WORKTREE_DIR_X}" update-index \
      --skip-worktree .claude/settings.json || true
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
  ISSUE_LIVE_STATE="$(printf '%s' "${ISSUE_JSON}" | jq -r '.state // "opened"')"
  ISSUE_HAS_FINISH="$(printf '%s' "${ISSUE_JSON}" | jq -r \
    '(.labels // [] | index("finish")) != null')"
  ISSUE_HAS_PR="$(printf '%s' "${ISSUE_JSON}" | jq -r \
    '(.labels // [] | index("pr")) != null')"
  # Truncate by Unicode codepoint (jq `.[a:b]`), NOT bytes: issue bodies are
  # almost always Chinese, and a byte-wise `head -c 4096` could split a
  # multibyte char, leaving an invalid byte that breaks the python renderer's
  # UTF-8 encoding and mis-classifies the IID as prep_blocked.
  ISSUE_BODY="$(printf '%s' "${ISSUE_JSON}" | jq -r '(.description // "")[0:4096]')"
  ISSUE_TITLE_QUOTED="'${ISSUE_TITLE//\'/\'\\\'\'}'"

  if [ "${ISSUE_LIVE_STATE}" = "closed" ]; then
    prep_terminal_skip "closed"
    continue
  fi
  if [ "${ALLOW_TERMINAL_RERUN}" != "true" ] \
      && { [ "${ISSUE_HAS_FINISH}" = "true" ] \
           || [ "${ISSUE_HAS_PR}" = "true" ]; }; then
    prep_terminal_skip "pr_without_force_rerun"
    continue
  fi

  # Transition labels: remove entry labels + add doing.
  # `timeout` is included so that a reviewer who re-enqueued the IID (e.g. by
  # adding `retry` on top of `timeout`) doesn't end up with a `timeout +
  # doing` mix between this prep and `set_issue_label.sh add doing`.
  REMOVE_LBLS=(todo retry new continue contiune blocked blocked-cc blocked-dispatcher failed failed-cc failed-dispatcher done timeout)
  if [ "${ALLOW_TERMINAL_RERUN}" = "true" ]; then
    REMOVE_LBLS+=(pr finish)
  fi
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
  LABEL_ADD_OUT=""
  TERMINAL_PRESERVE_REASON=""
  if [ "${LABEL_OK}" = true ]; then
    if LABEL_ADD_OUT="$(env "${iid_env[@]}" \
        bash "${SCRIPT_DIR}/set_issue_label.sh" add doing \
        2>>"${DISPATCHER_LOG_DIR}/wrapper.log")"; then
      [ -z "${LABEL_ADD_OUT}" ] \
        || printf '%s\n' "${LABEL_ADD_OUT}" >>"${DISPATCHER_LOG_DIR}/wrapper.log"
      case "${LABEL_ADD_OUT}" in
        *preserve:closed*) TERMINAL_PRESERVE_REASON="closed" ;;
        *preserve:finish*|*preserve:pr*)
          TERMINAL_PRESERVE_REASON="pr_without_force_rerun"
          ;;
      esac
    else
      LABEL_OK=false
    fi
  fi
  if [ -n "${TERMINAL_PRESERVE_REASON}" ]; then
    prep_terminal_skip "${TERMINAL_PRESERVE_REASON}"
    continue
  fi
  if [ "${LABEL_OK}" != true ]; then
    prep_blocked "set_issue_label transition to doing failed"
    continue
  fi

  # build_prompt.sh
  set +e
  env "${iid_env[@]}" BRANCH="${IID_BRANCH}" \
    AUTO_MERGE="${IID_AUTO_MERGE}" \
    MERGE_TARGET_BRANCH="${IID_MERGE_TARGET_BRANCH:-${IID_BRANCH}}" \
    ISSUE_MODE="${MODE_ACTUAL}" \
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
  PRIOR_CONTINUE_COUNT="$( [ -f "${ISSUE_STATE_X}" ] && jq -r '.continue_count // 0' "${ISSUE_STATE_X}" || echo 0 )"
  NEW_CONTINUE_COUNT="${PRIOR_CONTINUE_COUNT}"
  [ "${MODE_ACTUAL}" = "continue" ] && NEW_CONTINUE_COUNT=$(( PRIOR_CONTINUE_COUNT + 1 ))
  PRIOR_MODEL_TIER="$( [ -f "${ISSUE_STATE_X}" ] && jq -r '.model_tier // empty' "${ISSUE_STATE_X}" || true )"
  jq -n \
    --argjson iid "${iid}" \
    --argjson attempts_total "${attempt}" \
    --argjson latest_attempt_number "${attempt}" \
    --arg latest_attempt_dir "${ISSUE_ROOT_X}" \
    --argjson retry_count "${PRIOR_RETRY}" \
    --argjson continue_count "${NEW_CONTINUE_COUNT}" \
    --arg model_tier "${RESOLVED_MODEL_TIER:-}" \
    --arg prior_model_tier "${PRIOR_MODEL_TIER}" \
    --arg session "issue-${PROJECT}-${iid}" \
    --arg mode "${MODE_ACTUAL}" \
    --arg updated_at "${NOW}" \
    '{iid:$iid, session:$session, status:"in_progress", mode:$mode,
      continue_count:$continue_count,
      model_tier:(if $model_tier == "" then (if $prior_model_tier == "" then null else $prior_model_tier end) else $model_tier end),
      attempts_total:$attempts_total, latest_attempt_number:$latest_attempt_number,
      latest_attempt_dir:$latest_attempt_dir, retry_count:$retry_count,
      block_reason:null, commit_sha:null, merge_request_url:null,
      updated_at:$updated_at}' | atomic_write_json "${ISSUE_STATE_X}"

  # Render the full executor workflow to a private local file. sessions_spawn
  # receives only the small secret-free bootstrap written to spawn_payload.txt;
  # the child verifies the manifest and full payload before reading either as
  # instructions. This removes the large model-copied task from the runtime
  # boundary and gives every launch a stable byte/hash identity.
  executor_payload_path="${LOG_DIR_X}/executor_payload.txt"
  manifest_path="${LOG_DIR_X}/spawn_manifest.json"
  payload_path="${LOG_DIR_X}/spawn_payload.txt"
  mkdir -p "${LOG_DIR_X}"

  # Extract the fenced "Rendered Prompt" block from executor_prompt.md.
  # Use the paired sentinels (which are part of the prompt itself) as the
  # opener AND closer so a future markdown edit introducing nested ```code```
  # examples inside the fenced block does not silently truncate the template
  # at the first inner fence. The closer sentinel is consumed by the awk
  # extractor (exit before printing) and never appears in the rendered payload.
  set +e
  template="$(awk '
    /^# REQ_EXECUTOR_EXECUTOR_PROMPT_V1$/ { found=1 }
    found {
      if ($0 == "# REQ_EXECUTOR_EXECUTOR_PROMPT_V1_END") { closed=1; exit }
      print
    }
    END { if (found && !closed) exit 2 }
  ' "${SKILL_DIR}/references/executor_prompt.md")"
  template_rc=$?
  set -e

  if [ "${template_rc}" -eq 2 ]; then
    prep_blocked "executor_prompt.md missing end-sentinel '# REQ_EXECUTOR_EXECUTOR_PROMPT_V1_END' — template extraction would be truncated"
    continue
  fi
  if [ "${template_rc}" -ne 0 ]; then
    prep_blocked "executor_prompt.md awk extraction failed: rc=${template_rc}"
    continue
  fi
  if [ -z "${template}" ]; then
    prep_blocked "executor_prompt.md fenced block missing or sentinel not found"
    continue
  fi
  first_template_line="$(first_line "${template}")"
  if [ "${first_template_line}" != "# REQ_EXECUTOR_EXECUTOR_PROMPT_V1" ]; then
    prep_blocked "executor_prompt.md fenced block does not start with sentinel"
    continue
  fi

  ACPX_MIN=$(( ACPX_TIMEOUT / 60 ))
  WORK_BRANCH_X="issue/${iid}"

  RENDER_ERR="$(mktemp)"
  CLEANUP_FILES+=("${RENDER_ERR}")
  set +e
  rendered="$(TPL_PROJECT="${PROJECT}" \
              TPL_GROUP="${GROUP}" \
              TPL_GITLAB_HOST="${GITLAB_HOST}" \
              TPL_GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
              TPL_ISSUE_IID="${iid}" \
              TPL_ATTEMPT_NUMBER="${attempt}" \
              TPL_ATTEMPT_NUMBER_PADDED="${attempt_padded}" \
              TPL_ISSUE_TITLE="${ISSUE_TITLE}" \
              TPL_ISSUE_TITLE_QUOTED="${ISSUE_TITLE_QUOTED}" \
              TPL_ISSUE_URL="${ISSUE_URL}" \
              TPL_ISSUE_LABELS="${ISSUE_LABELS}" \
              TPL_ISSUE_BODY="${ISSUE_BODY}" \
              TPL_ISSUE_MODE="${MODE_ACTUAL}" \
              TPL_BRANCH="${IID_BRANCH}" \
              TPL_BRANCH_QUOTED="${IID_BRANCH_QUOTED}" \
              TPL_AUTO_MERGE="${IID_AUTO_MERGE}" \
              TPL_MERGE_TARGET_BRANCH="${IID_MERGE_TARGET_BRANCH}" \
              TPL_MERGE_TARGET_BRANCH_QUOTED="${IID_MERGE_TARGET_BRANCH_QUOTED}" \
              TPL_WORK_BRANCH="${WORK_BRANCH_X}" \
              TPL_LOCAL_ATTEMPT_BRANCH="${LOCAL_ATTEMPT_BRANCH}" \
              TPL_REPO_PATH="${REPO_PATH}" \
              TPL_WORKTREE_DIR="${WORKTREE_DIR_X}" \
              TPL_OUTPUT_DIR="${OUTPUT_DIR_X}" \
              TPL_LOG_DIR="${LOG_DIR_X}" \
              TPL_ISSUE_ROOT="${ISSUE_ROOT_X}" \
              TPL_SCRIPTS_DIR="${SCRIPT_DIR}" \
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
    miss="$(awk '/^UNSUBSTITUTED_PLACEHOLDER=/{sub(/^UNSUBSTITUTED_PLACEHOLDER=/, ""); print; exit}' "${RENDER_ERR}")"
    prep_blocked "prompt template render incomplete: ${miss:-unknown}"
    continue
  fi

  # Sentinel check.
  sentinel_first_line="$(first_line "${rendered}")"
  if [ "${sentinel_first_line}" != "# REQ_EXECUTOR_EXECUTOR_PROMPT_V1" ]; then
    prep_blocked "executor payload missing sentinel — refused to publish a manifest or spawn bootstrap"
    continue
  fi

  ( umask 077; printf '%s' "${rendered}" >"${executor_payload_path}" )
  chmod 600 "${executor_payload_path}" 2>/dev/null \
    || { prep_blocked "executor payload must be private"; continue; }
  executor_payload_sha256="$(sha256_file "${executor_payload_path}")" || {
    prep_blocked "unable to hash executor payload"
    continue
  }
  executor_payload_bytes="$(file_bytes "${executor_payload_path}")"
  case "${executor_payload_bytes}" in
    ''|*[!0-9]*) prep_blocked "unable to size executor payload"; continue ;;
  esac

  manifest_job_id=""
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    manifest_job_id="$(jq -r '.job_id' <<<"${IID_GRANT_JSON}")"
  fi
  manifest_json="$(jq -cnS \
    --arg project "${GROUP}/${PROJECT}" \
    --arg job_id "${manifest_job_id}" \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt}" \
    --arg executor_payload_path "${executor_payload_path}" \
    --arg executor_payload_sha256 "${executor_payload_sha256}" \
    --argjson executor_payload_bytes "${executor_payload_bytes}" '{
      version:1,
      project:$project,
      job_id:(if $job_id == "" then null else $job_id end),
      iid:$iid,
      attempt_number:$attempt_number,
      executor_payload_path:$executor_payload_path,
      executor_payload_sha256:$executor_payload_sha256,
      executor_payload_bytes:$executor_payload_bytes
    }')"
  ( umask 077; printf '%s\n' "${manifest_json}" >"${manifest_path}" )
  chmod 600 "${manifest_path}" 2>/dev/null \
    || { prep_blocked "spawn manifest must be private"; continue; }
  manifest_sha256="$(sha256_file "${manifest_path}")" || {
    prep_blocked "unable to hash spawn manifest"
    continue
  }
  manifest_bytes="$(file_bytes "${manifest_path}")"
  case "${manifest_bytes}" in
    ''|*[!0-9]*) prep_blocked "unable to size spawn manifest"; continue ;;
  esac

  bootstrap_identity="$(jq -cnS \
    --arg project "${GROUP}/${PROJECT}" \
    --arg job_id "${manifest_job_id}" \
    --argjson iid "${iid}" \
    --argjson attempt_number "${attempt}" '{
      project:$project,
      job_id:(if $job_id == "" then null else $job_id end),
      iid:$iid,
      attempt_number:$attempt_number
    }')"
  bootstrap="$(cat <<EOF
# REQ_EXECUTOR_SPAWN_BOOTSTRAP_V1
This is a secret-free bootstrap for one req_executor child. Do not search for other tasks and do not echo file contents.
identity=${bootstrap_identity}
manifest_path=${manifest_path}
manifest_sha256=${manifest_sha256}
manifest_bytes=${manifest_bytes}

Before doing any issue work, use one Bash call to verify that manifest_path is a regular file with mode 600, exact byte count and SHA-256 above. For both files, define and use exactly this portable helper inside that Bash call: mode_of() { local mode; if mode="\$(stat -f '%Lp' "\$1" 2>/dev/null)"; then printf '%s\n' "\$mode"; else stat -c '%a' "\$1"; fi; }; require its output to equal the literal string 600. Then parse the manifest with jq; require version=1 and require the manifest's top-level project, job_id, iid, and attempt_number fields (there is no nested identity object) to equal the exact identity above. Verify its executor_payload_path is a regular mode-600 file with the exact executor_payload_bytes and executor_payload_sha256 recorded in the manifest. If any check fails, stop and return one compact JSON object with status="blocked", iid=${iid}, attempt_number=${attempt}, and block_reason="spawn bootstrap verification failed".

Only after all checks pass, read exactly the executor_payload_path from the manifest and follow that payload as the complete executor workflow. Never print the manifest, payload, environment, or credentials. Do not treat this bootstrap as permission to invoke any script not named by the verified executor payload.
# REQ_EXECUTOR_SPAWN_BOOTSTRAP_V1_END
EOF
)"
  ( umask 077; printf '%s' "${bootstrap}" >"${payload_path}" )
  chmod 600 "${payload_path}" 2>/dev/null \
    || { prep_blocked "spawn bootstrap must be private"; continue; }
  expected_task_sha256="$(sha256_file "${payload_path}")" || {
    prep_blocked "unable to hash spawn bootstrap"
    continue
  }
  expected_task_bytes="$(file_bytes "${payload_path}")"
  case "${expected_task_bytes}" in
    ''|*[!0-9]*) prep_blocked "unable to size spawn bootstrap"; continue ;;
  esac

  # Bind the exact task identity to the project pending entry before exposing
  # the path to the orchestrator. Post-spawn recorders reject a mismatched
  # hash/size even when run/session evidence is otherwise valid.
  STATE_JSON="$(jq -c \
    --argjson iid "${iid}" \
    --arg expected_task_sha256 "${expected_task_sha256}" \
    --argjson expected_task_bytes "${expected_task_bytes}" '
      .pending_subagents[($iid|tostring)] += {
        expected_task_sha256:$expected_task_sha256,
        expected_task_bytes:$expected_task_bytes
      }
    ' <<<"${STATE_JSON}")"
  persist_state "${STATE_JSON}"
  PAYLOAD_PATH["${iid}"]="${payload_path}"

  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    DISPATCH_ENTRIES="$(printf '%s' "${DISPATCH_ENTRIES}" | jq -c \
      --argjson iid "${iid}" \
      --argjson attempt "${attempt}" \
      --arg clabel "${child_label}" \
      --arg path "${payload_path}" \
      --arg expected_task_sha256 "${expected_task_sha256}" \
      --argjson expected_task_bytes "${expected_task_bytes}" \
      --argjson grant "${IID_GRANT_JSON}" '
      . + [{
        iid:$iid,
        attempt_number:$attempt,
        child_label:$clabel,
        payload_path:$path,
        expected_task_sha256:$expected_task_sha256,
        expected_task_bytes:$expected_task_bytes,
        job_id:$grant.job_id,
        batch_id:$grant.batch_id,
        snapshot_index:$grant.snapshot_index,
        memberships_source:"scheduler_active_job"
      }]')"
  else
    DISPATCH_ENTRIES="$(printf '%s' "${DISPATCH_ENTRIES}" | jq -c \
      --argjson iid "${iid}" \
      --argjson attempt "${attempt}" \
      --arg clabel "${child_label}" \
      --arg path "${payload_path}" \
      --arg expected_task_sha256 "${expected_task_sha256}" \
      --argjson expected_task_bytes "${expected_task_bytes}" '
      . + [{
        iid:$iid,
        attempt_number:$attempt,
        child_label:$clabel,
        payload_path:$path,
        expected_task_sha256:$expected_task_sha256,
        expected_task_bytes:$expected_task_bytes
      }]')"
  fi

  wrapper_log prepare_tick "prepared iid=${iid} attempt=${attempt} payload=${payload_path}"
done

# ─── 21. Emit envelope ───────────────────────────────────────────
SURVIVOR_COUNT="$(printf '%s' "${DISPATCH_ENTRIES}" | jq 'length')"
SUMMARY="$(printf 'prepared %s/%s IIDs for spawn (max_concurrent=%s)' \
  "${SURVIVOR_COUNT}" "${BATCH_SIZE}" "${MAX_CONCURRENT}")"

if [ "${SURVIVOR_COUNT}" -eq 0 ]; then
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    CURRENT_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
      | jq -c '.pending_subagents | keys | map(tonumber) | sort')"
    jq -nc \
      --argjson outcomes "${TICK_OUTCOMES}" \
      --argjson evicted "${EVICTED_IIDS_JSON}" \
      --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson pending_iids "${CURRENT_PENDING_IIDS_JSON}" \
      --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
      --arg ev "${EVIDENCE_PATH}" \
      --arg chat "all batch IIDs blocked during prep — see tick_outcome_per_iid" '
      {status:"no_eligible_iids", dispatch_entries:[], pending_iids:$pending_iids,
       skipped_entries:$skipped_entries,
       evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
       cleanup_actions:$cleanup_actions,
       max_launch_retries:3, backoff_seconds:2,
       tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev, chat_summary:$chat}'
  else
    jq -nc \
      --argjson outcomes "${TICK_OUTCOMES}" \
      --argjson evicted "${EVICTED_IIDS_JSON}" \
      --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --arg ev "${EVIDENCE_PATH}" \
      --arg chat "all batch IIDs blocked during prep — see tick_outcome_per_iid" '
      {status:"no_eligible_iids", dispatch_entries:[],
       evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
       cleanup_actions:$cleanup_actions,
       max_launch_retries:3, backoff_seconds:2,
       tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev, chat_summary:$chat}'
  fi
  exit 0
fi

if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  CURRENT_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
    | jq -c '.pending_subagents | keys | map(tonumber) | sort')"
  jq -nc \
    --argjson dispatch_entries "${DISPATCH_ENTRIES}" \
    --argjson pending_iids "${CURRENT_PENDING_IIDS_JSON}" \
    --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
    --argjson outcomes "${TICK_OUTCOMES}" \
    --argjson evicted "${EVICTED_IIDS_JSON}" \
    --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    --argjson label_in "${LABEL_FILTERED_IN_JSON}" \
    --argjson label_out "${LABEL_FILTERED_OUT_JSON}" \
    --arg ev "${EVIDENCE_PATH}" \
    --arg chat "${SUMMARY}" '
    {status:"ready", dispatch_entries:$dispatch_entries, pending_iids:$pending_iids,
     skipped_entries:$skipped_entries,
     max_launch_retries:3, backoff_seconds:2,
     evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
     cleanup_actions:$cleanup_actions,
     label_filtered_in:$label_in, label_filtered_out:$label_out,
     tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev,
     chat_summary:$chat}'
else
  jq -nc \
    --argjson dispatch_entries "${DISPATCH_ENTRIES}" \
    --argjson outcomes "${TICK_OUTCOMES}" \
    --argjson evicted "${EVICTED_IIDS_JSON}" \
    --argjson scope_evicted "${SCOPE_EVICTED_IIDS_JSON}" \
    --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
    --argjson label_in "${LABEL_FILTERED_IN_JSON}" \
    --argjson label_out "${LABEL_FILTERED_OUT_JSON}" \
    --arg ev "${EVIDENCE_PATH}" \
    --arg chat "${SUMMARY}" '
    {status:"ready", dispatch_entries:$dispatch_entries,
     max_launch_retries:3, backoff_seconds:2,
     evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
     cleanup_actions:$cleanup_actions,
     label_filtered_in:$label_in, label_filtered_out:$label_out,
     tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev,
     chat_summary:$chat}'
fi
