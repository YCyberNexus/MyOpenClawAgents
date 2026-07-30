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
#         "execution_id": 3,
#         "child_label": "#14-exec-104729681223",
#         "payload_path": "/data/.../spawn_payload-104729681223.txt",
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

# Owner admission remains the first campaign-state decision. Only an admitted
# owner may run the exclusive, quiescent legacy sweep. Reload and recompute the
# pure transition afterwards so a later state write cannot restore scrubbed
# historical fields from the pre-migration snapshot.
LEGACY_EXECUTION_MIGRATION_RC=0
migrate_legacy_execution_state_locked || LEGACY_EXECUTION_MIGRATION_RC=$?
case "${LEGACY_EXECUTION_MIGRATION_RC}" in
  0) ;;
  2) emit_chat_failure "legacy_execution_identity_drain_required" ;;
  *) emit_chat_failure "legacy_execution_identity_cleanup_failed" ;;
esac
STATE_JSON="$(load_state)"
INITIAL_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
  | jq -c '(.pending_subagents // {}) | keys | map(tonumber) | sort')"
OWNER_DECISION="$(dispatch_owner_transition "${STATE_JSON}" \
  "${REQUESTED_OWNER_MODE}" "${REQUESTED_OWNER_ID}" "${OWNER_NOW}")"
[ "$(printf '%s' "${OWNER_DECISION}" | jq -r '.allowed')" = "true" ] \
  || emit_chat_failure "dispatch_owner_changed_during_locked_migration"
STATE_JSON="$(printf '%s' "${OWNER_DECISION}" | jq -c '.updated_state')"
DRIVEN_GRANT_IIDS_JSON="[]"
if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  DRIVEN_GRANT_IIDS_JSON="$(printf '%s' "${DRIVEN_GRANTS_JSON}" | jq -c 'map(.iid)')"
  DRIVEN_SCOPE_IIDS_JSON="$(jq -nc \
    --argjson pending "${INITIAL_PENDING_IIDS_JSON}" \
    --argjson grants "${DRIVEN_GRANT_IIDS_JSON}" \
    '($pending + $grants) | unique | sort')"
  T[issue_iids]="$(printf '%s' "${DRIVEN_SCOPE_IIDS_JSON}" | jq -r 'map(tostring) | join(",")')"
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

# The executable universe remains grant-scoped. Dependency graph planning has
# a separate immutable scope so A can see a later C from the same driven batch
# before C owns a scheduler slot.
DEPENDENCY_SCOPE_MAX_IIDS=200
DEPENDENCY_SCOPES_JSON='[]'
SCHEDULED_DEPENDENCY_SCOPE_INCOMPLETE=false
if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  if ! DEPENDENCY_SCOPES_JSON="$(printf '%s' "${T[dependency_scopes_json]:-}" \
      | jq -ce --argjson grants "${DRIVEN_GRANTS_JSON}" \
        --argjson max_iids "${DEPENDENCY_SCOPE_MAX_IIDS}" '
        def clean_id:
          type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
        . as $scopes
        | if type == "array" and length > 0
          and all(.[];
            type == "object"
            and (keys | sort) == ["complete","iids","scope_id"]
            and (.scope_id | clean_id)
            and (.complete | type == "boolean")
            and (.iids | type == "array" and length > 0
              and length <= $max_iids
              and all(.[]; type == "number" and . == floor and . > 0)
              and length == (unique | length)))
          and ([.[].scope_id] | length == (unique | length))
          and ($grants | all(.[];
            . as $grant
            | any($scopes[]; .scope_id == $grant.batch_id
              and (.iids | index($grant.iid) != null))))
        then . else error("invalid dependency scopes") end
      ' 2>/dev/null)"; then
    emit_chat_failure "invalid_dependency_planning_scopes"
  fi
else
  scheduled_scope_count="$(printf '%s' "${EFF_UNIVERSE_JSON}" | jq -r 'length')"
  scheduled_scope_complete=true
  scheduled_scope_iids="${EFF_UNIVERSE_JSON}"
  if [ "${scheduled_scope_count}" -gt "${DEPENDENCY_SCOPE_MAX_IIDS}" ]; then
    scheduled_scope_complete=false
    SCHEDULED_DEPENDENCY_SCOPE_INCOMPLETE=true
    scheduled_scope_iids="$(printf '%s' "${EFF_UNIVERSE_JSON}" \
      | jq -c --argjson max "${DEPENDENCY_SCOPE_MAX_IIDS}" '.[0:$max]')"
  fi
  DEPENDENCY_SCOPES_JSON="$(jq -nc \
    --argjson complete "${scheduled_scope_complete}" \
    --argjson iids "${scheduled_scope_iids}" \
    '[{scope_id:"scheduled",complete:$complete,iids:$iids}]')"
fi
DEPENDENCY_SCOPE_IIDS_JSON="$(printf '%s' "${DEPENDENCY_SCOPES_JSON}" \
  | jq -c '[.[].iids[]] | unique | sort')"
RECONCILE_UNIVERSE_JSON="$(jq -nc \
  --argjson execution "${EFF_UNIVERSE_JSON}" \
  --argjson planning "${DEPENDENCY_SCOPE_IIDS_JSON}" \
  '($execution + $planning) | unique | sort')"

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
  PA_NUM="$(printf '%s' "${ENTRY}" | jq -r '.execution_id')"
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

IID_LIST_CSV="$(printf '%s' "${RECONCILE_UNIVERSE_JSON}" | jq -r 'map(tostring) | join(",")')"
RECONCILE_ARGS+=(IID_LIST="${IID_LIST_CSV}")

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
DEPENDENCY_EVIDENCE_JSON="${EVIDENCE_JSON}"
# Planning-only members must not become executable or mutate the existing
# campaign completion/backlog bookkeeping. Keep their live descriptions in a
# separate snapshot and retain the historical execution-scoped evidence below.
EVIDENCE_JSON="$(printf '%s' "${EVIDENCE_JSON}" | jq -c \
  --argjson execution "${EFF_UNIVERSE_JSON}" \
  '[.[] | select(.iid as $iid | $execution | index($iid) != null)]')"
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

# Build the ordered candidate stream first. Dependency preflight below scans
# this stream until it finds BATCH_CAP runnable IIDs, so a waiting dependent
# does not hide an independent later Issue or advance the fresh cursor past
# itself.
CANDIDATE_ORDER_JSON="$(jq -nc \
  --argjson backlog "${BACKLOG_JSON}" \
  --argjson fresh "${FRESH_JSON}" \
  --argjson blocked "${BLOCKED_JSON}" '
  ($backlog + $fresh + $blocked) | unique_by(.)')"

if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
  CANDIDATE_ORDER_JSON="$(jq -nc \
    --argjson grants "${DRIVEN_EXECUTABLE_GRANT_IIDS_JSON}" \
    --argjson initial_pending "${INITIAL_PENDING_IIDS_JSON}" \
    --argjson current_pending "${CURRENT_PENDING_IIDS_JSON}" '
    $grants
    | map(select(. as $iid
        | ($initial_pending | index($iid) == null)
        and ($current_pending | index($iid) == null)))')"
fi

# ─── 16b. Issue-dependency preflight ─────────────────────────────
#
# An Issue may declare one same-project prerequisite or a bounded fan-in, for
# example `依赖 Issue #123` or `依赖 Issue #123,#124`. The first prerequisite
# anchors `issue/<dependency IID>+<dependent IID>`; a fan-in first aggregates
# every fixed source commit, while each executable member still owns one fixed
# local issue branch.
#
# Do this before attempt allocation and placeholder persistence. If the
# prerequisite branch has not been pushed yet, leave the IID/grant untouched
# and retry it on a later tick: waiting is workflow ordering, not an execution
# failure, and must not consume retry/attempt budget or add blocked labels.
declare -A ISSUE_JSON_CACHE DEPENDENCY_IID_BY_IID DEPENDENCY_BRANCH_BY_IID
declare -A DEPENDENCY_BASE_SHA_BY_IID
declare -A DEPENDENCY_ERROR_BY_IID
declare -A WORK_BRANCH_BY_IID BRANCH_MEMBERS_JSON_BY_IID SHARED_BRANCH_ROLE_BY_IID
declare -A MULTI_DEPENDENCY_IIDS_JSON_BY_TAIL
declare -A FAN_IN_AUXILIARY_GROUP_BY_IID
declare -A SHARED_GRAPH_SCOPE_BY_IID SHARED_GRAPH_SCOPE_COMPLETE_BY_IID
declare -A SHARED_GRAPH_WAIT_BY_IID
declare -A LATE_SHARED_HEAD_BY_TAIL LATE_SHARED_TAIL_BY_HEAD
declare -A LATE_SHARED_BRANCH_BY_TAIL LATE_SHARED_MEMBERS_BY_TAIL
declare -A LATE_SHARED_SCOPE_BY_TAIL
declare -A EXPECTED_WORK_BRANCH_SHA_BY_IID
declare -A DEPENDENCY_PARSE_RESULT_BY_IID DEPENDENCY_PARSE_STATUS_BY_IID
declare -A DEPENDENCY_PARSE_OUTCOME_BY_IID
declare -A DEPENDENCY_PARSE_DESCRIPTION_BY_IID
declare -A CONTINUE_BASE_REQUIRED_BY_IID
declare -A CONTINUE_BASE_SHA_BY_IID
declare -A CONTINUE_BASE_REF_BY_IID
DEPENDENCY_WAITING_JSON='[]'
DEFERRED_ENTRIES_JSON='[]'
BATCH_JSON='[]'

append_batch_iid() {
  local iid="$1"
  BATCH_JSON="$(printf '%s' "${BATCH_JSON}" | jq -c \
    --argjson iid "${iid}" '. + [$iid]')"
}

record_dependency_wait() {
  local iid="$1" dependency_iid="$2" dependency_branch="$3" reason="$4"
  local grant_json=""

  DEPENDENCY_WAITING_JSON="$(printf '%s' "${DEPENDENCY_WAITING_JSON}" | jq -c \
    --argjson iid "${iid}" \
    --argjson dependency_iid "${dependency_iid}" \
    --arg branch "${dependency_branch}" \
    --arg reason "${reason}" \
    '. + [{iid:$iid,dependency_iid:$dependency_iid,branch:$branch,reason:$reason}]')"
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    grant_json="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANTS_JSON}" \
      | jq -c --argjson iid "${iid}" '.[] | select(.iid == $iid)')"
    DEFERRED_ENTRIES_JSON="$(printf '%s' "${DEFERRED_ENTRIES_JSON}" | jq -c \
      --argjson grant "${grant_json}" \
      --argjson dependency_iid "${dependency_iid}" \
      --arg dependency_branch "${dependency_branch}" \
      --arg reason "${reason}" '
      . + [($grant | {
        job_id,batch_id,snapshot_index,project,iid,
        status:"deferred",reason:$reason,
        dependency_iid:$dependency_iid,
        dependency_branch:$dependency_branch
      })]')"
  fi
}

record_dependency_preflight_wait() {
  local iid="$1" reason="$2"
  local grant_json=""

  DEPENDENCY_WAITING_JSON="$(printf '%s' "${DEPENDENCY_WAITING_JSON}" | jq -c \
    --argjson iid "${iid}" \
    --arg reason "${reason}" \
    '. + [{iid:$iid,dependency_iid:null,branch:null,reason:$reason}]')"
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    grant_json="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANTS_JSON}" \
      | jq -c --argjson iid "${iid}" '.[] | select(.iid == $iid)')"
    DEFERRED_ENTRIES_JSON="$(printf '%s' "${DEFERRED_ENTRIES_JSON}" | jq -c \
      --argjson grant "${grant_json}" \
      --arg reason "${reason}" '
      . + [($grant | {
        job_id,batch_id,snapshot_index,project,iid,
        status:"deferred",reason:$reason,
        dependency_iid:null,
        dependency_branch:null
      })]')"
  fi
}

DEPENDENCY_CANDIDATE_COUNT="$(printf '%s' "${CANDIDATE_ORDER_JSON}" | jq -r 'length')"
DEPENDENCY_SCAN_CURSOR_IID=""
if [ "${DISPATCH_MODE}" = scheduled ] \
    && [ "${DEPENDENCY_CANDIDATE_COUNT}" -gt 0 ]; then
  DEPENDENCY_SCAN_CURSOR_IID="$(printf '%s' "${STATE_JSON}" \
    | jq -r '.dependency_scan_cursor_iid // empty')"
  if [ -n "${DEPENDENCY_SCAN_CURSOR_IID}" ] \
      && ! [[ "${DEPENDENCY_SCAN_CURSOR_IID}" =~ ^[1-9][0-9]*$ ]]; then
    DEPENDENCY_SCAN_CURSOR_IID=""
  fi
  if [ -n "${DEPENDENCY_SCAN_CURSOR_IID}" ]; then
    # Rotate only the bounded dependency-preflight view. The fresh cursor is
    # still advanced solely by selected IIDs below. Every scanned waiter is
    # inserted into unfinished_iids, so a later fresh selection cannot lose it.
    CANDIDATE_ORDER_JSON="$(printf '%s' "${CANDIDATE_ORDER_JSON}" | jq -c \
      --argjson cursor "${DEPENDENCY_SCAN_CURSOR_IID}" '
      (map(select(. >= $cursor)) + map(select(. < $cursor)))')"
  fi
fi

mapfile -t DEPENDENCY_CANDIDATE_IIDS < <(
  printf '%s' "${CANDIDATE_ORDER_JSON}" | jq -r '.[]'
)
DEPENDENCY_PREFLIGHT_SCAN_LIMIT=$((BATCH_CAP * 10))
[ "${DEPENDENCY_PREFLIGHT_SCAN_LIMIT}" -lt 50 ] \
  && DEPENDENCY_PREFLIGHT_SCAN_LIMIT=50
[ "${DEPENDENCY_PREFLIGHT_SCAN_LIMIT}" -gt 200 ] \
  && DEPENDENCY_PREFLIGHT_SCAN_LIMIT=200
DEPENDENCY_PREFLIGHT_SCANNED=0
DEPENDENCY_PREFLIGHT_LAST_SCANNED_IID=""
DEPENDENCY_CHAIN_MAX_DEPTH=32
DEPENDENCY_DIRECT_LOOKUP_BUDGET=200
DEPENDENCY_DIRECT_LOOKUPS_USED=0
DEPENDENCY_CHAIN_LOOKUP_BUDGET=200
DEPENDENCY_CHAIN_LOOKUPS_USED=0
DEPENDENCY_ROOT_PARSE_BUDGET=200
DEPENDENCY_ROOT_PARSES_USED=0
DEPENDENCY_CHAIN_PARSE_BUDGET=200
DEPENDENCY_CHAIN_PARSES_USED=0
DEPENDENCY_GRAPH_PHASE_DEADLINE_SECONDS=$((SECONDS + 60))
DEPENDENCY_CHAIN_ISSUE_JSON=""
DEPENDENCY_CHAIN_STATUS=""
DEPENDENCY_CHAIN_LOAD_OUTCOME="error"
DEPENDENCY_PARSE_RESULT=""
DEPENDENCY_PARSE_STATUS="parser_error"
DEPENDENCY_PARSE_OUTCOME="error"

parse_dependency_snapshot() {
  local parse_iid="$1" parse_description="$2" parse_scope="$3"
  local parse_result="" parse_rc=0

  if [ "${DEPENDENCY_PARSE_OUTCOME_BY_IID[${parse_iid}]+present}" = "present" ] \
      && [ "${DEPENDENCY_PARSE_DESCRIPTION_BY_IID[${parse_iid}]}" = \
        "${parse_description}" ]; then
    DEPENDENCY_PARSE_RESULT="${DEPENDENCY_PARSE_RESULT_BY_IID[${parse_iid}]}"
    DEPENDENCY_PARSE_STATUS="${DEPENDENCY_PARSE_STATUS_BY_IID[${parse_iid}]}"
    DEPENDENCY_PARSE_OUTCOME="${DEPENDENCY_PARSE_OUTCOME_BY_IID[${parse_iid}]}"
    [ "${DEPENDENCY_PARSE_OUTCOME}" = "ok" ]
    return
  fi
  case "${parse_scope}" in
    root)
      if [ "${SECONDS}" -ge "${DEPENDENCY_GRAPH_PHASE_DEADLINE_SECONDS}" ]; then
        DEPENDENCY_PARSE_RESULT=""
        DEPENDENCY_PARSE_STATUS="parser_error"
        DEPENDENCY_PARSE_OUTCOME="deadline"
        return 2
      fi
      if [ "${DEPENDENCY_ROOT_PARSES_USED}" -ge \
          "${DEPENDENCY_ROOT_PARSE_BUDGET}" ]; then
        DEPENDENCY_PARSE_RESULT=""
        DEPENDENCY_PARSE_STATUS="parser_error"
        DEPENDENCY_PARSE_OUTCOME="budget"
        return 2
      fi
      DEPENDENCY_ROOT_PARSES_USED=$((DEPENDENCY_ROOT_PARSES_USED + 1))
      ;;
    chain)
      if [ "${SECONDS}" -ge "${DEPENDENCY_GRAPH_PHASE_DEADLINE_SECONDS}" ]; then
        DEPENDENCY_PARSE_RESULT=""
        DEPENDENCY_PARSE_STATUS="parser_error"
        DEPENDENCY_PARSE_OUTCOME="deadline"
        return 2
      fi
      if [ "${DEPENDENCY_CHAIN_PARSES_USED}" -ge \
          "${DEPENDENCY_CHAIN_PARSE_BUDGET}" ]; then
        DEPENDENCY_PARSE_RESULT=""
        DEPENDENCY_PARSE_STATUS="parser_error"
        DEPENDENCY_PARSE_OUTCOME="budget"
        return 2
      fi
      DEPENDENCY_CHAIN_PARSES_USED=$((DEPENDENCY_CHAIN_PARSES_USED + 1))
      ;;
    *)
      DEPENDENCY_PARSE_RESULT=""
      DEPENDENCY_PARSE_STATUS="parser_error"
      DEPENDENCY_PARSE_OUTCOME="error"
      return 2
      ;;
  esac
  set +e
  parse_result="$(
    timeout --kill-after=1s 5s env \
      ISSUE_IID="${parse_iid}" \
      bash "${SCRIPT_DIR}/parse_issue_dependency.sh" \
      <<<"${parse_description}"
  )"
  parse_rc=$?
  set -e
  DEPENDENCY_PARSE_RESULT="${parse_result}"
  DEPENDENCY_PARSE_STATUS="parser_error"
  DEPENDENCY_PARSE_OUTCOME="error"
  if [ "${parse_rc}" -eq 124 ] || [ "${parse_rc}" -eq 137 ]; then
    DEPENDENCY_PARSE_OUTCOME="timeout"
  elif [ "${parse_rc}" -eq 0 ] \
      && printf '%s' "${parse_result}" | jq -e . >/dev/null 2>&1; then
    DEPENDENCY_PARSE_STATUS="$(printf '%s' "${parse_result}" | jq -r '.status')"
    DEPENDENCY_PARSE_OUTCOME="ok"
  fi
  DEPENDENCY_PARSE_RESULT_BY_IID["${parse_iid}"]="${DEPENDENCY_PARSE_RESULT}"
  DEPENDENCY_PARSE_STATUS_BY_IID["${parse_iid}"]="${DEPENDENCY_PARSE_STATUS}"
  DEPENDENCY_PARSE_OUTCOME_BY_IID["${parse_iid}"]="${DEPENDENCY_PARSE_OUTCOME}"
  DEPENDENCY_PARSE_DESCRIPTION_BY_IID["${parse_iid}"]="${parse_description}"
  [ "${DEPENDENCY_PARSE_OUTCOME}" = "ok" ]
}

load_dependency_issue_snapshot() {
  local chain_iid="$1" lookup_scope="$2"
  local chain_issue_json="" chain_issue_rc=0

  if [ "${ISSUE_JSON_CACHE[${chain_iid}]+present}" = "present" ]; then
    DEPENDENCY_CHAIN_ISSUE_JSON="${ISSUE_JSON_CACHE[${chain_iid}]}"
    DEPENDENCY_CHAIN_LOAD_OUTCOME="ok"
    return 0
  fi
  if [ "${SECONDS}" -ge "${DEPENDENCY_GRAPH_PHASE_DEADLINE_SECONDS}" ]; then
    DEPENDENCY_CHAIN_ISSUE_JSON=""
    DEPENDENCY_CHAIN_LOAD_OUTCOME="deadline"
    return 2
  fi
  case "${lookup_scope}" in
    root)
      ;;
    direct)
      if [ "${DEPENDENCY_DIRECT_LOOKUPS_USED}" -ge \
          "${DEPENDENCY_DIRECT_LOOKUP_BUDGET}" ]; then
        DEPENDENCY_CHAIN_ISSUE_JSON=""
        DEPENDENCY_CHAIN_LOAD_OUTCOME="budget"
        return 2
      fi
      DEPENDENCY_DIRECT_LOOKUPS_USED=$((DEPENDENCY_DIRECT_LOOKUPS_USED + 1))
      ;;
    chain)
      if [ "${DEPENDENCY_CHAIN_LOOKUPS_USED}" -ge \
          "${DEPENDENCY_CHAIN_LOOKUP_BUDGET}" ]; then
        DEPENDENCY_CHAIN_ISSUE_JSON=""
        DEPENDENCY_CHAIN_LOAD_OUTCOME="budget"
        return 2
      fi
      DEPENDENCY_CHAIN_LOOKUPS_USED=$((DEPENDENCY_CHAIN_LOOKUPS_USED + 1))
      ;;
    *)
      DEPENDENCY_CHAIN_ISSUE_JSON=""
      DEPENDENCY_CHAIN_LOAD_OUTCOME="error"
      return 2
      ;;
  esac
  set +e
  chain_issue_json="$(
    timeout --kill-after=1s 10s \
      glab api "projects/${PROJECT_URI}/issues/${chain_iid}" 2>/dev/null
  )"
  chain_issue_rc=$?
  set -e
  if [ "${chain_issue_rc}" -eq 124 ] || [ "${chain_issue_rc}" -eq 137 ]; then
    DEPENDENCY_CHAIN_ISSUE_JSON=""
    DEPENDENCY_CHAIN_LOAD_OUTCOME="timeout"
    return 3
  fi
  if [ "${chain_issue_rc}" -ne 0 ] \
      || ! chain_issue_json="$(printf '%s' "${chain_issue_json}" | jq -ce '
        if type == "object"
          and ((.description == null) or (.description | type == "string"))
          and ((.labels // []) | type == "array")
          and (all((.labels // [])[]; type == "string"))
        then . else error("invalid dependency-chain Issue response") end
      ' 2>/dev/null)"; then
    DEPENDENCY_CHAIN_ISSUE_JSON=""
    DEPENDENCY_CHAIN_LOAD_OUTCOME="error"
    return 1
  fi
  ISSUE_JSON_CACHE["${chain_iid}"]="${chain_issue_json}"
  DEPENDENCY_CHAIN_ISSUE_JSON="${chain_issue_json}"
  DEPENDENCY_CHAIN_LOAD_OUTCOME="ok"
}

detect_live_dependency_cycle() {
  local root_iid="$1" current_iid="$2"
  local visited=",${root_iid},"
  local depth=0 chain_description="" chain_parse_status="" next_iid=""
  local chain_completed="false"

  DEPENDENCY_CHAIN_STATUS="lookup_failed"
  while :; do
    case "${visited}" in
      *",${current_iid},"*)
        DEPENDENCY_CHAIN_STATUS="cycle"
        return 0
        ;;
    esac
    if [ "${depth}" -ge "${DEPENDENCY_CHAIN_MAX_DEPTH}" ]; then
      DEPENDENCY_CHAIN_STATUS="too_deep"
      return 0
    fi
    if [ "${SECONDS}" -ge "${DEPENDENCY_GRAPH_PHASE_DEADLINE_SECONDS}" ]; then
      DEPENDENCY_CHAIN_STATUS="deferred_budget"
      return 0
    fi
    visited="${visited}${current_iid},"
    if load_dependency_issue_snapshot "${current_iid}" chain; then
      :
    else
      case "${DEPENDENCY_CHAIN_LOAD_OUTCOME}" in
        budget|deadline) DEPENDENCY_CHAIN_STATUS="deferred_budget" ;;
        timeout) DEPENDENCY_CHAIN_STATUS="deferred_timeout" ;;
        *) DEPENDENCY_CHAIN_STATUS="lookup_failed" ;;
      esac
      return 0
    fi

    # A stable completed node no longer waits on its declaration, so a cycle
    # beyond that point cannot keep the candidate blocked.
    chain_completed="$(printf '%s' "${DEPENDENCY_CHAIN_ISSUE_JSON}" | jq -r '
      (.labels // []) as $labels
      | ((($labels | index("pr")) != null)
          or (($labels | index("finish")) != null))
        and ([$labels[] | select(
          . == "continue" or . == "contiune" or . == "doing"
          or . == "retry" or . == "todo" or . == "new"
          or . == "timeout" or . == "blocked" or startswith("blocked-")
          or . == "failed" or startswith("failed-"))] | length) == 0
    ')"
    if [ "${chain_completed}" = "true" ]; then
      DEPENDENCY_CHAIN_STATUS="acyclic"
      return 0
    fi

    chain_description="$(printf '%s' "${DEPENDENCY_CHAIN_ISSUE_JSON}" \
      | jq -r '.description // ""')"
    if parse_dependency_snapshot "${current_iid}" "${chain_description}" chain; then
      chain_parse_status="${DEPENDENCY_PARSE_STATUS}"
    else
      case "${DEPENDENCY_PARSE_OUTCOME}" in
        budget|deadline) DEPENDENCY_CHAIN_STATUS="deferred_budget" ;;
        timeout) DEPENDENCY_CHAIN_STATUS="deferred_timeout" ;;
        *) DEPENDENCY_CHAIN_STATUS="parser_failed" ;;
      esac
      return 0
    fi
    case "${chain_parse_status}" in
      none)
        DEPENDENCY_CHAIN_STATUS="acyclic"
        return 0
        ;;
      resolved)
        next_iid="$(printf '%s' "${DEPENDENCY_PARSE_RESULT}" \
          | jq -r '.dependency_iid')"
        if ! [[ "${next_iid}" =~ ^[1-9][0-9]*$ ]]; then
          DEPENDENCY_CHAIN_STATUS="chain_invalid"
          return 0
        fi
        current_iid="${next_iid}"
        ;;
      *)
        DEPENDENCY_CHAIN_STATUS="chain_invalid"
        return 0
        ;;
    esac
    depth=$((depth + 1))
  done
}

# ── Shared dependency branch planning ─────────────────────────────
#
# A cannot infer the reverse edge C -> A from A's own body, so A always starts
# as an ordinary issue/A job.  Scope discovery below is advisory validation for
# dependencies that are already visible; it must never delay or change A just
# because another Issue might later declare a dependency.  C binds the pair
# only when C itself is processed, after A has completed safely on issue/A.
mark_shared_dependency_error() {
  local error_iid="$1" error_reason="$2"
  if [ -z "${DEPENDENCY_ERROR_BY_IID[${error_iid}]:-}" ]; then
    DEPENDENCY_ERROR_BY_IID["${error_iid}"]="${error_reason}"
  fi
}

if ! STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -ce '
    if ((.shared_branch_groups // {}) | type) != "object" then
      error("invalid shared branch groups")
    else
      .shared_branch_groups = (.shared_branch_groups // {})
      | if all(.shared_branch_groups | to_entries[];
          (.key | test("^issue/[1-9][0-9]*\\+[1-9][0-9]*$"))
          and (.value | type == "object")
          and (.value.work_branch == .key)
          and (.value.head_iid | type == "number" and . == floor and . > 0)
          and (.value.tail_iid | type == "number" and . == floor and . > 0)
          and (.value.head_iid != .value.tail_iid)
          and (.value.members == [.value.head_iid,.value.tail_iid])
          and (.key == ("issue/" + (.value.head_iid | tostring)
            + "+" + (.value.tail_iid | tostring)))
          and (.value.scope_id | type == "string" and length > 0)
          and (.value as $group
            | if (($group.dependency_iids // null) == null) then
                (($group.dependency_mode // null) == null)
              else
                ($group.dependency_mode == "fan_in")
                and ($group.dependency_iids | type == "array")
                and ($group.dependency_iids | length) >= 2
                and ($group.dependency_iids | length) <= 8
                and ($group.dependency_iids[0] == $group.head_iid)
                and ($group.dependency_iids | index($group.tail_iid) == null)
                and (all($group.dependency_iids[];
                  type == "number" and . == floor and . > 0))
                and (($group.dependency_iids | length)
                  == ($group.dependency_iids | unique | length))
              end)
          and (((.value.merge_target_branch // null) == null)
            or (.value.merge_target_branch | type == "string" and length > 0)))
        and (([.shared_branch_groups[]
              | ((.dependency_iids // [.head_iid]) + [.tail_iid])[]] | length)
          == ([.shared_branch_groups[]
              | ((.dependency_iids // [.head_iid]) + [.tail_iid])[]]
            | unique | length))
        then . else error("invalid shared branch group entry") end
    end
  ' 2>/dev/null)"; then
  emit_chat_failure "invalid_persisted_shared_branch_groups"
fi
while IFS= read -r persisted_shared_group; do
  persisted_shared_branch="$(jq -r '.work_branch' <<<"${persisted_shared_group}")"
  persisted_shared_head="$(jq -r '.head_iid' <<<"${persisted_shared_group}")"
  persisted_shared_tail="$(jq -r '.tail_iid' <<<"${persisted_shared_group}")"
  persisted_shared_members="$(jq -c '.members' <<<"${persisted_shared_group}")"
  WORK_BRANCH_BY_IID["${persisted_shared_head}"]="${persisted_shared_branch}"
  WORK_BRANCH_BY_IID["${persisted_shared_tail}"]="${persisted_shared_branch}"
  BRANCH_MEMBERS_JSON_BY_IID["${persisted_shared_head}"]="${persisted_shared_members}"
  BRANCH_MEMBERS_JSON_BY_IID["${persisted_shared_tail}"]="${persisted_shared_members}"
  SHARED_BRANCH_ROLE_BY_IID["${persisted_shared_head}"]=head
  SHARED_BRANCH_ROLE_BY_IID["${persisted_shared_tail}"]=tail
  persisted_dependency_iids="$(jq -c \
    '.dependency_iids // [.head_iid]' <<<"${persisted_shared_group}")"
  if [ "$(jq -r 'length' <<<"${persisted_dependency_iids}")" -gt 1 ]; then
    MULTI_DEPENDENCY_IIDS_JSON_BY_TAIL["${persisted_shared_tail}"]="${persisted_dependency_iids}"
    while IFS= read -r persisted_auxiliary_iid; do
      FAN_IN_AUXILIARY_GROUP_BY_IID["${persisted_auxiliary_iid}"]="${persisted_shared_branch}"
    done < <(jq -r '.[1:][]' <<<"${persisted_dependency_iids}")
  fi
done < <(printf '%s' "${STATE_JSON}" | jq -c '.shared_branch_groups[]')

# Reuse the exact reconciliation snapshot for graph discovery. This prevents a
# description edit between reverse-edge planning and the attempt prompt from
# silently changing branch ownership.
while IFS= read -r planning_evidence; do
  planning_iid="$(jq -r '.iid' <<<"${planning_evidence}")"
  if jq -e '
      .missing == false
      and (.state | type == "string")
      and (.labels | type == "array" and all(.[]; type == "string"))
      and (.title | type == "string")
      and (.description | type == "string")
    ' <<<"${planning_evidence}" >/dev/null 2>&1; then
    ISSUE_JSON_CACHE["${planning_iid}"]="$(printf '%s' "${planning_evidence}" \
      | jq -c '{iid,state,labels,title,description}')"
  fi
done < <(printf '%s' "${DEPENDENCY_EVIDENCE_JSON}" | jq -c '.[]')

declare -A SHARED_GRAPH_DEP_BY_KEY SHARED_GRAPH_REVERSE_COUNT_BY_KEY
declare -A SHARED_GRAPH_STATUS_BY_KEY
while IFS= read -r planning_scope; do
  planning_scope_id="$(jq -r '.scope_id' <<<"${planning_scope}")"
  planning_scope_complete="$(jq -r '.complete' <<<"${planning_scope}")"
  mapfile -t planning_scope_iids < <(jq -r '.iids[]' <<<"${planning_scope}")

  for planning_iid in "${planning_scope_iids[@]}"; do
    if [ -z "${SHARED_GRAPH_SCOPE_BY_IID[${planning_iid}]:-}" ]; then
      SHARED_GRAPH_SCOPE_BY_IID["${planning_iid}"]="${planning_scope_id}"
      SHARED_GRAPH_SCOPE_COMPLETE_BY_IID["${planning_iid}"]="${planning_scope_complete}"
    fi
    WORK_BRANCH_BY_IID["${planning_iid}"]="${WORK_BRANCH_BY_IID[${planning_iid}]:-issue/${planning_iid}}"
    BRANCH_MEMBERS_JSON_BY_IID["${planning_iid}"]="${BRANCH_MEMBERS_JSON_BY_IID[${planning_iid}]:-[$planning_iid]}"
  done
  if [ "${planning_scope_complete}" != true ]; then
    # An incomplete reverse-edge scope says nothing about an ordinary A.  The
    # candidate's own dependency declaration is still parsed below and can be
    # late-bound using A's durable completed state.
    continue
  fi

  planning_scope_deferred=false
  planning_scope_invalid=false
  for planning_iid in "${planning_scope_iids[@]}"; do
    planning_key="${planning_scope_id}|${planning_iid}"
    if ! load_dependency_issue_snapshot "${planning_iid}" root; then
      planning_scope_deferred=true
      SHARED_GRAPH_WAIT_BY_IID["${planning_iid}"]="dependency_graph_preflight_deferred"
      continue
    fi
    planning_completed="$(printf '%s' "${DEPENDENCY_CHAIN_ISSUE_JSON}" | jq -r '
      (.labels // []) as $labels
      | ((($labels | index("pr")) != null)
          or (($labels | index("finish")) != null))
        and ([$labels[] | select(
          . == "continue" or . == "contiune" or . == "doing"
          or . == "retry" or . == "todo" or . == "new"
          or . == "timeout" or . == "blocked" or startswith("blocked-")
          or . == "failed" or startswith("failed-"))] | length) == 0
    ')"
    if [ "${planning_completed}" = true ]; then
      SHARED_GRAPH_STATUS_BY_KEY["${planning_key}"]=none
      SHARED_GRAPH_DEP_BY_KEY["${planning_key}"]=""
      continue
    fi
    planning_description="$(printf '%s' "${DEPENDENCY_CHAIN_ISSUE_JSON}" \
      | jq -r '.description // ""')"
    if ! parse_dependency_snapshot \
        "${planning_iid}" "${planning_description}" root; then
      planning_scope_deferred=true
      continue
    fi
    planning_status="${DEPENDENCY_PARSE_STATUS}"
    SHARED_GRAPH_STATUS_BY_KEY["${planning_key}"]="${planning_status}"
    case "${planning_status}" in
      none)
        SHARED_GRAPH_DEP_BY_KEY["${planning_key}"]=""
        ;;
      resolved)
        planning_dependency_iid="$(printf '%s' "${DEPENDENCY_PARSE_RESULT}" \
          | jq -r '.dependency_iid')"
        SHARED_GRAPH_DEP_BY_KEY["${planning_key}"]="${planning_dependency_iid}"
        ;;
      resolved_multiple)
        # Multi-head fan-in is late-bound from the dependent's direct
        # declaration after every source has a durable ordinary result. The
        # pair-oriented advisory graph cannot represent its extra heads.
        SHARED_GRAPH_DEP_BY_KEY["${planning_key}"]=""
        ;;
      *)
        planning_scope_invalid=true
        mark_shared_dependency_error "${planning_iid}" \
          "$(printf '%s' "${DEPENDENCY_PARSE_RESULT}" \
            | jq -r '.reason // "invalid_dependency"')"
        ;;
    esac
  done
  if [ "${planning_scope_deferred}" = true ]; then
    continue
  fi
  if [ "${planning_scope_invalid}" = true ]; then
    continue
  fi

  for planning_iid in "${planning_scope_iids[@]}"; do
    planning_key="${planning_scope_id}|${planning_iid}"
    planning_dependency_iid="${SHARED_GRAPH_DEP_BY_KEY[${planning_key}]:-}"
    [ -n "${planning_dependency_iid}" ] || continue
    if ! printf '%s' "${planning_scope}" | jq -e \
        --argjson iid "${planning_dependency_iid}" \
        '.iids | index($iid) != null' >/dev/null; then
      # A dependency may have completed in an earlier immutable batch.  The
      # direct C -> A gate and migration checkpoint validate that external
      # head; absence from C's current scope is not itself an error.
      continue
    fi
    reverse_key="${planning_scope_id}|${planning_dependency_iid}"
    reverse_count="${SHARED_GRAPH_REVERSE_COUNT_BY_KEY[${reverse_key}]:-0}"
    SHARED_GRAPH_REVERSE_COUNT_BY_KEY["${reverse_key}"]=$((reverse_count + 1))
  done

  for planning_iid in "${planning_scope_iids[@]}"; do
    planning_key="${planning_scope_id}|${planning_iid}"
    planning_dependency_iid="${SHARED_GRAPH_DEP_BY_KEY[${planning_key}]:-}"
    [ -n "${planning_dependency_iid}" ] || continue
    [ -z "${DEPENDENCY_ERROR_BY_IID[${planning_iid}]:-}" ] || continue
    head_key="${planning_scope_id}|${planning_dependency_iid}"
    head_dependency_iid="${SHARED_GRAPH_DEP_BY_KEY[${head_key}]:-}"
    head_reverse_count="${SHARED_GRAPH_REVERSE_COUNT_BY_KEY[${head_key}]:-0}"
    tail_reverse_count="${SHARED_GRAPH_REVERSE_COUNT_BY_KEY[${planning_key}]:-0}"
    detect_live_dependency_cycle "${planning_iid}" "${planning_dependency_iid}"
    case "${DEPENDENCY_CHAIN_STATUS}" in
      cycle)
        mark_shared_dependency_error "${planning_iid}" "dependency_cycle"
        continue
        ;;
      too_deep)
        mark_shared_dependency_error "${planning_iid}" \
          "dependency_chain_too_deep"
        continue
        ;;
      chain_invalid)
        mark_shared_dependency_error "${planning_iid}" \
          "dependency_chain_invalid"
        continue
        ;;
      deferred_timeout|deferred_budget)
        SHARED_GRAPH_WAIT_BY_IID["${planning_iid}"]="dependency_cycle_check_deferred"
        continue
        ;;
    esac
    if [ "${head_reverse_count}" -gt 1 ]; then
      mark_shared_dependency_error "${planning_iid}" \
        "shared_branch_fanout_unsupported"
      continue
    fi
    if [ -n "${head_dependency_iid}" ] || [ "${tail_reverse_count}" -gt 0 ]; then
      mark_shared_dependency_error "${planning_iid}" \
        "shared_branch_chain_unsupported"
      continue
    fi

    shared_head_iid="${planning_dependency_iid}"
    shared_tail_iid="${planning_iid}"
    shared_work_branch="issue/${shared_head_iid}+${shared_tail_iid}"
    shared_members_json="[${shared_head_iid},${shared_tail_iid}]"
    existing_member_branch="$(printf '%s' "${STATE_JSON}" | jq -r \
      --argjson head "${shared_head_iid}" --argjson tail "${shared_tail_iid}" '
      [.shared_branch_groups | to_entries[]
       | select(.value as $group
         | (($group.dependency_iids // [$group.head_iid]) + [$group.tail_iid])
         | (index($head) != null or index($tail) != null))
       | .key] | unique | if length == 0 then "" else join(",") end')"
    if [ -n "${existing_member_branch}" ] \
        && [ "${existing_member_branch}" != "${shared_work_branch}" ]; then
      mark_shared_dependency_error "${shared_head_iid}" \
        "shared_branch_binding_conflict"
      mark_shared_dependency_error "${shared_tail_iid}" \
        "shared_branch_binding_conflict"
      continue
    fi
    if [ -n "${existing_member_branch}" ]; then
      # Persisted groups were loaded above and stay immutable. New reverse
      # edges remain desired-only until C observes A completed on issue/A and
      # the late-binding migration succeeds.
      continue
    fi
    LATE_SHARED_HEAD_BY_TAIL["${shared_tail_iid}"]="${shared_head_iid}"
    LATE_SHARED_TAIL_BY_HEAD["${shared_head_iid}"]="${shared_tail_iid}"
    LATE_SHARED_BRANCH_BY_TAIL["${shared_tail_iid}"]="${shared_work_branch}"
    LATE_SHARED_MEMBERS_BY_TAIL["${shared_tail_iid}"]="${shared_members_json}"
    LATE_SHARED_SCOPE_BY_TAIL["${shared_tail_iid}"]="${planning_scope_id}"
  done
done < <(printf '%s' "${DEPENDENCY_SCOPES_JSON}" | jq -c '.[]')

for candidate_iid in "${DEPENDENCY_CANDIDATE_IIDS[@]:-}"; do
  [ -n "${candidate_iid}" ] || continue
  current_batch_size="$(printf '%s' "${BATCH_JSON}" | jq -r 'length')"
  [ "${current_batch_size}" -lt "${BATCH_CAP}" ] || break

  # A dependency-heavy backlog must not turn one scheduler tick into an
  # unbounded GitLab/API scan. Unscanned candidates remain behind the durable
  # cursor and are reconsidered on a later tick.
  [ "${DEPENDENCY_PREFLIGHT_SCANNED}" -lt "${DEPENDENCY_PREFLIGHT_SCAN_LIMIT}" ] \
    || break
  dependency_elapsed_seconds=$(( $(date -u +%s) - TICK_START_TS ))
  [ "${dependency_elapsed_seconds}" -lt "$(( ${T[max_runtime_minutes]} * 60 ))" ] \
    || break
  DEPENDENCY_PREFLIGHT_SCANNED=$((DEPENDENCY_PREFLIGHT_SCANNED + 1))
  DEPENDENCY_PREFLIGHT_LAST_SCANNED_IID="${candidate_iid}"
  candidate_work_branch="${WORK_BRANCH_BY_IID[${candidate_iid}]:-issue/${candidate_iid}}"
  WORK_BRANCH_BY_IID["${candidate_iid}"]="${candidate_work_branch}"
  BRANCH_MEMBERS_JSON_BY_IID["${candidate_iid}"]="${BRANCH_MEMBERS_JSON_BY_IID[${candidate_iid}]:-[${candidate_iid}]}"

  if [ -n "${SHARED_GRAPH_WAIT_BY_IID[${candidate_iid}]:-}" ]; then
    record_dependency_preflight_wait \
      "${candidate_iid}" "${SHARED_GRAPH_WAIT_BY_IID[${candidate_iid}]}"
    wrapper_log prepare_tick \
      "iid=${candidate_iid} ${SHARED_GRAPH_WAIT_BY_IID[${candidate_iid}]}"
    if [ "${DISPATCH_MODE}" = scheduled ]; then
      break
    fi
    continue
  fi

  if load_dependency_issue_snapshot "${candidate_iid}" root; then
    candidate_issue_json="${DEPENDENCY_CHAIN_ISSUE_JSON}"
  else
    # Issue reads are external preflight I/O. A timeout, malformed response,
    # or temporary API failure must release the scheduler slot without
    # allocating an attempt or turning the Issue terminal.
    record_dependency_preflight_wait \
      "${candidate_iid}" "dependency_preflight_deferred"
    wrapper_log prepare_tick \
      "iid=${candidate_iid} dependency_preflight_deferred detail=issue_lookup_${DEPENDENCY_CHAIN_LOAD_OUTCOME}"
    if [ "${DISPATCH_MODE}" = scheduled ]; then
      break
    fi
    continue
  fi
  candidate_description="$(printf '%s' "${candidate_issue_json}" \
    | jq -r '.description // ""')"

  # Continue mode resumes C's already-created shared branch. If that branch (or
  # the fixed local issue branch) is recoverable, changes to A's later labels/ref must
  # not prevent C from resuming. Only a continue that would downgrade to fresh
  # still needs the dependency gate below.
  candidate_entry_mode="auto"
  candidate_force_rerun_pr="false"
  candidate_auto_merge="false"
  candidate_merge_target="${T[branch]}"
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    candidate_grant_json="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANTS_JSON}" \
      | jq -c --argjson iid "${candidate_iid}" \
        '.[] | select(.iid == $iid)')"
    candidate_entry_mode="$(printf '%s' "${candidate_grant_json}" \
      | jq -r '.entry_mode')"
    candidate_force_rerun_pr="$(printf '%s' "${candidate_grant_json}" \
      | jq -r '.force_rerun_pr')"
    candidate_auto_merge="$(printf '%s' "${candidate_grant_json}" \
      | jq -r '.auto_merge')"
    candidate_merge_target="$(printf '%s' "${candidate_grant_json}" \
      | jq -r --arg default_branch "${T[branch]}" \
        '.merge_target_branch // .branch // $default_branch')"
  fi
  candidate_has_desired_shared_pair=false
  if [ -n "${LATE_SHARED_HEAD_BY_TAIL[${candidate_iid}]:-}" ]; then
    candidate_has_desired_shared_pair=true
  fi
  if [ -n "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" ] \
      || [ "${candidate_has_desired_shared_pair}" = true ]; then
    if [ "${candidate_auto_merge}" = true ]; then
      mark_shared_dependency_error "${candidate_iid}" \
        "shared_branch_auto_merge_unsupported"
    fi
  fi
  if [ -n "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" ]; then
    shared_candidate_branch="${WORK_BRANCH_BY_IID[${candidate_iid}]}"
    persisted_shared_target="$(printf '%s' "${STATE_JSON}" | jq -r \
      --arg branch "${shared_candidate_branch}" \
      '.shared_branch_groups[$branch].merge_target_branch // ""')"
    if [ -n "${persisted_shared_target}" ] \
        && [ "${persisted_shared_target}" != "${candidate_merge_target}" ]; then
      mark_shared_dependency_error "${candidate_iid}" \
        "shared_branch_merge_target_changed"
    elif [ -z "${persisted_shared_target}" ]; then
      STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
        --arg branch "${shared_candidate_branch}" \
        --arg target "${candidate_merge_target}" \
        '.shared_branch_groups[$branch].merge_target_branch = $target')"
      persist_state "${STATE_JSON}"
    fi
  fi
  candidate_live_continue="$(printf '%s' "${candidate_issue_json}" | jq -r '
    (.labels // []) as $labels
    | (($labels | index("continue")) != null
        or ($labels | index("contiune")) != null)
      and (($labels | index("retry")) == null)
      and (($labels | index("todo")) == null)
  ')"
  candidate_requests_continue=false
  if [ "${candidate_entry_mode}" = "continue" ] \
      || { [ "${candidate_entry_mode}" = "auto" ] \
        && [ "${candidate_live_continue}" = "true" ]; }; then
    candidate_requests_continue=true
  fi

  # The shared head A is the immutable parent of C's single commit. Resuming A
  # would either move that parent or route an otherwise completed A through the
  # ordinary prep-blocked/Phase-6 path, overwriting the verified state C needs
  # for its dependency gate. Keep the scheduler job retryable until the user
  # removes continue; do not allocate an attempt, create a pending placeholder,
  # mutate workflow labels, or touch A's per-Issue state.json.
  if [ "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" = head ] \
      && [ "${candidate_requests_continue}" = true ]; then
    record_dependency_preflight_wait \
      "${candidate_iid}" "shared_branch_head_continue_unsupported"
    wrapper_log prepare_tick \
      "iid=${candidate_iid} shared_branch_head_continue_unsupported"
    if [ "${DISPATCH_MODE}" = scheduled ]; then
      break
    fi
    continue
  fi
  if [ -n "${FAN_IN_AUXILIARY_GROUP_BY_IID[${candidate_iid}]:-}" ] \
      && [ "${candidate_requests_continue}" = true ]; then
    record_dependency_preflight_wait \
      "${candidate_iid}" "shared_branch_source_continue_unsupported"
    wrapper_log prepare_tick \
      "iid=${candidate_iid} shared_branch_source_continue_unsupported group=${FAN_IN_AUXILIARY_GROUP_BY_IID[${candidate_iid}]}"
    if [ "${DISPATCH_MODE}" = scheduled ]; then
      break
    fi
    continue
  fi

  # Reconciliation is only a snapshot. If C itself became closed/pr/finish
  # after that snapshot, let the existing prep-time terminal-race path drain
  # the grant. Its old dependency must not keep an already-finished C deferred.
  candidate_live_state="$(printf '%s' "${candidate_issue_json}" \
    | jq -r '.state // "opened"')"
  candidate_live_terminal="$(printf '%s' "${candidate_issue_json}" | jq -r '
    (.labels // []) as $labels
    | (($labels | index("pr")) != null)
      or (($labels | index("finish")) != null)
  ')"
  if [ "${candidate_live_state}" = "closed" ] \
      || { [ "${candidate_live_terminal}" = "true" ] \
        && [ "${candidate_requests_continue}" != "true" ] \
        && [ "${candidate_force_rerun_pr}" != "true" ]; }; then
    append_batch_iid "${candidate_iid}"
    continue
  fi
  if [ -n "${FAN_IN_AUXILIARY_GROUP_BY_IID[${candidate_iid}]:-}" ]; then
    DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_source_rerun_unsupported"
    append_batch_iid "${candidate_iid}"
    continue
  fi

  # Parse once from the same Issue snapshot used by the prompt. Continue may
  # skip A's live completion/branch gate, but automatic merge still needs the
  # declared or previously pinned dependency SHA for its target-ancestry fence.
  if parse_dependency_snapshot \
      "${candidate_iid}" "${candidate_description}" root; then
    dependency_result="${DEPENDENCY_PARSE_RESULT}"
    dependency_status="${DEPENDENCY_PARSE_STATUS}"
  else
    dependency_result="${DEPENDENCY_PARSE_RESULT}"
    case "${DEPENDENCY_PARSE_OUTCOME}" in
      timeout|budget|deadline)
        record_dependency_preflight_wait \
          "${candidate_iid}" "dependency_preflight_deferred"
        wrapper_log prepare_tick \
          "iid=${candidate_iid} dependency_preflight_deferred detail=parser_${DEPENDENCY_PARSE_OUTCOME}"
        if [ "${DISPATCH_MODE}" = scheduled ]; then
          break
        fi
        continue
        ;;
      *)
        dependency_status="parser_error"
        ;;
    esac
  fi

  if [ "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" = tail ]; then
    shared_expected_head="$(printf '%s' \
      "${BRANCH_MEMBERS_JSON_BY_IID[${candidate_iid}]}" | jq -r '.[0]')"
    shared_expected_dependencies="${MULTI_DEPENDENCY_IIDS_JSON_BY_TAIL[${candidate_iid}]:-[${shared_expected_head}]}"
    shared_declared_dependencies='[]'
    case "${dependency_status}" in
      resolved)
        shared_declared_dependencies="$(printf '%s' "${dependency_result}" \
          | jq -c '[.dependency_iid]')"
        ;;
      resolved_multiple)
        shared_declared_dependencies="$(printf '%s' "${dependency_result}" \
          | jq -c '.dependency_iids')"
        ;;
    esac
    if [ "${shared_declared_dependencies}" != "${shared_expected_dependencies}" ]; then
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_dependency_changed"
      append_batch_iid "${candidate_iid}"
      continue
    fi
  elif [ "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" = head ] \
      && [ "${dependency_status}" != none ]; then
    DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_dependency_changed"
    append_batch_iid "${candidate_iid}"
    continue
  fi

  candidate_resume_ref_ready=false
  candidate_resume_is_remote=false
  candidate_resume_ref=""
  candidate_resume_sha=""
  if candidate_resume_sha="$(GIT_NO_REPLACE_OBJECTS=1 \
      git -C "${REPO_PATH}" rev-parse --verify \
      "refs/remotes/origin/${candidate_work_branch}^{commit}" 2>/dev/null)"; then
    candidate_resume_ref_ready=true
    candidate_resume_is_remote=true
    candidate_resume_ref="refs/remotes/origin/${candidate_work_branch}"
  else
    candidate_resume_ref="refs/heads/issue/${candidate_iid}"
    if GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" rev-parse \
        --verify --quiet "${candidate_resume_ref}^{commit}" >/dev/null; then
      candidate_resume_sha="$(GIT_NO_REPLACE_OBJECTS=1 \
        git -C "${REPO_PATH}" rev-parse --verify \
        "${candidate_resume_ref}^{commit}" 2>/dev/null || true)"
      [ -z "${candidate_resume_sha}" ] \
        || candidate_resume_ref_ready=true
    else
      candidate_resume_ref=""
    fi
  fi
  if [ "${candidate_requests_continue}" = "true" ] \
      && [ "${candidate_resume_ref_ready}" = "true" ]; then
    # A recoverable C branch can outlive this workstation's local state. Until
    # state.json proves either "no dependency" or the exact pinned dependency,
    # its history is unknown. In particular, an Issue body edited after C was
    # created must not be allowed to erase A from a later auto-merge decision.
    prior_dependency_status="missing"
    prior_dependency_iid=""
    prior_dependency_branch=""
    prior_dependency_sha=""
    prior_work_branch_sha=""
    candidate_state_file="${ISSUES_ROOT}/issue-${candidate_iid}/state.json"
    if [ -L "${candidate_state_file}" ]; then
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="invalid_persisted_dependency_metadata"
      append_batch_iid "${candidate_iid}"
      continue
    elif [ -f "${candidate_state_file}" ]; then
      if prior_dependency_json="$(jq -ce \
          --arg expected_work_branch "${candidate_work_branch}" \
          --argjson expected_members "${BRANCH_MEMBERS_JSON_BY_IID[${candidate_iid}]}" '
          def work_identity_ok:
            if ($expected_members | length) == 2 then
              .work_branch == $expected_work_branch
              and .branch_members == $expected_members
            else
              (.work_branch // $expected_work_branch) == $expected_work_branch
              and (.branch_members // $expected_members) == $expected_members
            end;
          if ($expected_members | length) != 2
              and work_identity_ok
              and (.dependency_history_verified == true)
              and (.work_branch_sha | type == "string"
                and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
              and ((.dependency_iid // null) == null
              and (.dependency_branch // null) == null
              and (.dependency_base_sha // null) == null) then
            {status:"none",work_branch_sha:.work_branch_sha,
             work_branch:$expected_work_branch,branch_members:$expected_members}
          elif work_identity_ok
              and (.dependency_history_verified == true)
              and (.work_branch_sha | type == "string"
                and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
              and (.dependency_iid | type == "number" and . == floor and . > 0)
              and .dependency_branch ==
                (if ($expected_members | length) == 2 then $expected_work_branch
                 else ("issue/" + (.dependency_iid | tostring)) end)
              and (.dependency_base_sha | type == "string"
                and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")) then
            {status:"resolved",dependency_iid:.dependency_iid,
             dependency_branch:.dependency_branch,
             dependency_base_sha:.dependency_base_sha,
             work_branch_sha:.work_branch_sha,
             work_branch:$expected_work_branch,branch_members:$expected_members}
          else error("invalid persisted dependency metadata") end
        ' "${candidate_state_file}" 2>/dev/null)"; then
        prior_dependency_status="$(printf '%s' "${prior_dependency_json}" \
          | jq -r '.status')"
        prior_work_branch_sha="$(printf '%s' "${prior_dependency_json}" \
          | jq -r '.work_branch_sha')"
        if [ "${prior_dependency_status}" = "resolved" ]; then
          prior_dependency_iid="$(printf '%s' "${prior_dependency_json}" \
            | jq -r '.dependency_iid')"
          prior_dependency_branch="$(printf '%s' "${prior_dependency_json}" \
            | jq -r '.dependency_branch')"
          prior_dependency_sha="$(printf '%s' "${prior_dependency_json}" \
            | jq -r '.dependency_base_sha')"
          # Preserve the actual baseline across ordinary continue attempts so
          # a later switch to auto_merge cannot forget A's unmerged commit.
          DEPENDENCY_IID_BY_IID["${candidate_iid}"]="${prior_dependency_iid}"
          DEPENDENCY_BRANCH_BY_IID["${candidate_iid}"]="${prior_dependency_branch}"
          DEPENDENCY_BASE_SHA_BY_IID["${candidate_iid}"]="${prior_dependency_sha}"
        fi
      else
        DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="invalid_persisted_dependency_metadata"
        append_batch_iid "${candidate_iid}"
        continue
      fi
    else
      # The existing C ref proves only that there is work to resume. Neither
      # today's Issue body nor today's A/B branch heads can reconstruct the
      # commit ancestry that C originally inherited. Block every such resume,
      # including non-auto runs, so one manual continue cannot create a new
      # dependency-free state record that a later auto-merge would trust.
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="unverified_continue_dependency_history"
      append_batch_iid "${candidate_iid}"
      continue
    fi

    if [ "${prior_work_branch_sha,,}" != "${candidate_resume_sha,,}" ]; then
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="continue_branch_history_mismatch"
      append_batch_iid "${candidate_iid}"
      continue
    fi
    if [ "${prior_dependency_status}" = "resolved" ] \
        && ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
          merge-base --is-ancestor \
          "${prior_dependency_sha}" "${candidate_resume_sha}" \
          >/dev/null 2>&1; then
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="continue_dependency_not_in_resume_history"
      append_batch_iid "${candidate_iid}"
      continue
    fi

    if [ "${candidate_auto_merge}" = "true" ]; then
      continue_dependency_iid="${prior_dependency_iid}"
      continue_dependency_branch="${prior_dependency_branch}"
      continue_dependency_sha="${prior_dependency_sha}"
      case "${dependency_status}" in
        none)
          ;;
        invalid)
          DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="$(
            printf '%s' "${dependency_result}" \
              | jq -r '.reason // "invalid_dependency"'
          )"
          append_batch_iid "${candidate_iid}"
          continue
          ;;
        resolved)
          declared_dependency_iid="$(printf '%s' "${dependency_result}" \
            | jq -r '.dependency_iid')"
          if [ -n "${continue_dependency_iid}" ] \
              && [ "${continue_dependency_iid}" != "${declared_dependency_iid}" ]; then
            DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_changed_during_continue"
            append_batch_iid "${candidate_iid}"
            continue
          fi
          if [ -z "${continue_dependency_iid}" ]; then
            # A continue branch already has immutable, verified history. Do
            # not reinterpret a newly added dependency declaration as though
            # that baseline had been present when the branch was created.
            DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_changed_during_continue"
            append_batch_iid "${candidate_iid}"
            continue
          fi
          ;;
        *)
          DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_parser_failed"
          append_batch_iid "${candidate_iid}"
          continue
          ;;
      esac

      if [ -n "${continue_dependency_iid}" ]; then
        if [ -z "${continue_dependency_sha}" ] \
            || ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" cat-file -e \
              "${continue_dependency_sha}^{commit}" 2>/dev/null; then
          record_dependency_wait "${candidate_iid}" \
            "${continue_dependency_iid}" "${continue_dependency_branch}" \
            "dependency_commit_unverified"
          continue
        fi
        if ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
            merge-base --is-ancestor \
            "${continue_dependency_sha}" \
            "refs/remotes/origin/${candidate_merge_target}" \
            >/dev/null 2>&1; then
          record_dependency_wait "${candidate_iid}" \
            "${continue_dependency_iid}" "${continue_dependency_branch}" \
            "dependency_not_in_merge_target"
          continue
        fi
        DEPENDENCY_IID_BY_IID["${candidate_iid}"]="${continue_dependency_iid}"
        DEPENDENCY_BRANCH_BY_IID["${candidate_iid}"]="${continue_dependency_branch}"
        DEPENDENCY_BASE_SHA_BY_IID["${candidate_iid}"]="${continue_dependency_sha}"
      fi
    fi

    # Pin the decision, not the ref name: prepare_attempt fetches once more. If
    # C's recoverable ref disappears in that window, it must fail closed rather
    # than silently downgrade to a fresh default-branch checkout that skipped
    # dependency validation.
    CONTINUE_BASE_REQUIRED_BY_IID["${candidate_iid}"]=true
    CONTINUE_BASE_SHA_BY_IID["${candidate_iid}"]="${candidate_resume_sha}"
    CONTINUE_BASE_REF_BY_IID["${candidate_iid}"]="${candidate_resume_ref}"
    if [ -n "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" ]; then
      EXPECTED_WORK_BRANCH_SHA_BY_IID["${candidate_iid}"]="${candidate_resume_sha}"
    fi
    append_batch_iid "${candidate_iid}"
    wrapper_log prepare_tick \
      "iid=${candidate_iid} dependency_gate_bypassed_for_continue"
    continue
  fi

  if [ "${dependency_status}" = "parser_error" ]; then
    DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_parser_failed"
    append_batch_iid "${candidate_iid}"
    continue
  fi
  if [ -n "${DEPENDENCY_ERROR_BY_IID[${candidate_iid}]:-}" ]; then
    append_batch_iid "${candidate_iid}"
    continue
  fi

  # A direct fan-in declaration is normalized to the existing scalar shared
  # branch contract only after all ordinary heads have been atomically
  # aggregated. The first dependency is the compatibility anchor; the complete
  # ordered source list remains frozen in shared_branch_groups and in the
  # anchor's private dependency_aggregation checkpoint.
  if [ "${dependency_status}" = resolved_multiple ]; then
    multi_dependency_iids="$(printf '%s' "${dependency_result}" \
      | jq -ce '
        if (.dependency_iids | type == "array")
          and (.dependency_iids | length) >= 2
          and (.dependency_iids | length) <= 8
          and all(.dependency_iids[];
            type == "number" and . == floor and . > 0)
          and ((.dependency_iids | length)
            == (.dependency_iids | unique | length))
          and .dependency_iid == .dependency_iids[0]
          and .base_branch == ("issue/" + (.dependency_iid | tostring))
        then .dependency_iids else error("invalid multi dependency result") end
      ' 2>/dev/null)" || {
        DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="invalid_dependency_parser_result"
        append_batch_iid "${candidate_iid}"
        continue
      }
    if printf '%s' "${multi_dependency_iids}" | jq -e \
        --argjson iid "${candidate_iid}" 'index($iid) != null' >/dev/null; then
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="self_dependency"
      append_batch_iid "${candidate_iid}"
      continue
    fi
    multi_anchor_iid="$(jq -r '.[0]' <<<"${multi_dependency_iids}")"
    multi_work_branch="issue/${multi_anchor_iid}+${candidate_iid}"
    multi_members_json="[${multi_anchor_iid},${candidate_iid}]"
    if [ "${candidate_auto_merge}" = true ]; then
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_auto_merge_unsupported"
      append_batch_iid "${candidate_iid}"
      continue
    fi

    proposed_multi_participants="$(jq -cn \
      --argjson dependencies "${multi_dependency_iids}" \
      --argjson tail "${candidate_iid}" '$dependencies + [$tail]')"
    existing_multi_overlaps="$(printf '%s' "${STATE_JSON}" | jq -c \
      --argjson participants "${proposed_multi_participants}" '
      [.shared_branch_groups | to_entries[]
        | .value as $group
        | (($group.dependency_iids // [$group.head_iid]) + [$group.tail_iid])
          as $bound
        | select(any($bound[]; . as $iid
            | $participants | index($iid) != null))]')"
    existing_multi_count="$(jq -r 'length' <<<"${existing_multi_overlaps}")"
    if [ "${existing_multi_count}" -gt 0 ]; then
      if [ "${existing_multi_count}" -ne 1 ] \
          || ! jq -e --arg branch "${multi_work_branch}" \
            --argjson head "${multi_anchor_iid}" \
            --argjson tail "${candidate_iid}" \
            --argjson dependencies "${multi_dependency_iids}" \
            --arg target "${candidate_merge_target}" '
            .[0].key == $branch
            and .[0].value.head_iid == $head
            and .[0].value.tail_iid == $tail
            and .[0].value.dependency_iids == $dependencies
            and .[0].value.merge_target_branch == $target
          ' <<<"${existing_multi_overlaps}" >/dev/null 2>&1; then
        DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_binding_conflict"
        append_batch_iid "${candidate_iid}"
        continue
      fi
    else
      multi_sources_ready=true
      multi_wait_recorded=false
      while IFS= read -r multi_source_iid; do
        if ! load_dependency_issue_snapshot "${multi_source_iid}" direct; then
          case "${DEPENDENCY_CHAIN_LOAD_OUTCOME}" in
            timeout|budget|deadline)
              record_dependency_wait "${candidate_iid}" "${multi_source_iid}" \
                "${multi_work_branch}" "dependency_fan_in_preflight_deferred"
              multi_wait_recorded=true
              ;;
            *)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_issue_lookup_failed"
              ;;
          esac
          multi_sources_ready=false
          break
        fi
        multi_source_issue_json="${DEPENDENCY_CHAIN_ISSUE_JSON}"
        multi_source_completed="$(printf '%s' "${multi_source_issue_json}" | jq -r '
          (.labels // []) as $labels
          | ((($labels | index("pr")) != null)
              or (($labels | index("finish")) != null))
            and ([$labels[] | select(
              . == "continue" or . == "contiune" or . == "doing"
              or . == "retry" or . == "todo" or . == "new"
              or . == "timeout" or . == "blocked" or startswith("blocked-")
              or . == "failed" or startswith("failed-"))] | length) == 0
        ')"
        multi_source_settled="$(printf '%s' "${STATE_JSON}" | jq -r \
          --argjson iid "${multi_source_iid}" '
          ((.pending_subagents // {})[($iid | tostring)] // null) == null')"
        if [ "${multi_source_completed}" != true ] \
            || [ "${multi_source_settled}" != true ]; then
          if [ "${multi_source_completed}" != true ]; then
            detect_live_dependency_cycle "${candidate_iid}" "${multi_source_iid}"
            case "${DEPENDENCY_CHAIN_STATUS}" in
              cycle)
                DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_cycle"
                ;;
              too_deep)
                DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_chain_too_deep"
                ;;
              chain_invalid)
                DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_chain_invalid"
                ;;
              lookup_failed)
                DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_issue_lookup_failed"
                ;;
              parser_failed)
                DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_parser_failed"
                ;;
              deferred_timeout|deferred_budget)
                record_dependency_wait "${candidate_iid}" "${multi_source_iid}" \
                  "${multi_work_branch}" "dependency_cycle_check_deferred"
                multi_wait_recorded=true
                ;;
            esac
          fi
          if [ -z "${DEPENDENCY_ERROR_BY_IID[${candidate_iid}]:-}" ] \
              && [ "${multi_wait_recorded}" != true ]; then
            record_dependency_wait "${candidate_iid}" "${multi_source_iid}" \
              "${multi_work_branch}" "dependency_not_completed"
            multi_wait_recorded=true
          fi
          multi_sources_ready=false
          break
        fi
      done < <(jq -r '.[]' <<<"${multi_dependency_iids}")
      if [ -n "${DEPENDENCY_ERROR_BY_IID[${candidate_iid}]:-}" ]; then
        append_batch_iid "${candidate_iid}"
        continue
      fi
      if [ "${multi_sources_ready}" != true ]; then
        wrapper_log prepare_tick \
          "iid=${candidate_iid} dependency_fan_in_waiting dependencies=${multi_dependency_iids}"
        if [ "${DISPATCH_MODE}" = scheduled ]; then
          break
        fi
        continue
      fi

      multi_migration_output=""
      multi_migration_rc=0
      set +e
      multi_migration_output="$(
        MIGRATION_DEPENDENCY_IIDS_JSON="${multi_dependency_iids}" \
        MIGRATION_TAIL_IID="${candidate_iid}" \
        MIGRATION_TARGET_BRANCH="${candidate_merge_target}" \
        timeout --kill-after=30s 900s \
          bash "${SCRIPT_DIR}/migrate_multi_dependency_heads.sh"
      )"
      multi_migration_rc=$?
      set -e
      if [ "${multi_migration_rc}" -eq 75 ] \
          || [ "${multi_migration_rc}" -eq 124 ] \
          || [ "${multi_migration_rc}" -eq 137 ]; then
        record_dependency_wait "${candidate_iid}" "${multi_anchor_iid}" \
          "${multi_work_branch}" "dependency_fan_in_migration_pending"
        wrapper_log prepare_tick \
          "iid=${candidate_iid} dependency_fan_in_migration_pending anchor_iid=${multi_anchor_iid}"
        continue
      fi
      if [ "${multi_migration_rc}" -ne 0 ] \
          || ! jq -e --argjson head "${multi_anchor_iid}" \
            --argjson tail "${candidate_iid}" \
            --argjson dependencies "${multi_dependency_iids}" \
            --arg branch "${multi_work_branch}" '
            .status == "ready" and .head_iid == $head and .tail_iid == $tail
            and .dependency_iids == $dependencies and .work_branch == $branch
            and (.commit_sha | type == "string"
              and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
          ' <<<"${multi_migration_output}" >/dev/null 2>&1; then
        multi_migration_reason="$(printf '%s' "${multi_migration_output}" \
          | jq -r '.reason // "dependency_fan_in_migration_failed"' \
            2>/dev/null || printf '%s' dependency_fan_in_migration_failed)"
        DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="${multi_migration_reason}"
        append_batch_iid "${candidate_iid}"
        wrapper_log prepare_tick \
          "iid=${candidate_iid} dependency_fan_in_migration_failed anchor_iid=${multi_anchor_iid} rc=${multi_migration_rc} reason=${multi_migration_reason}"
        continue
      fi

      multi_scope_suffix="$(jq -r 'map(tostring) | join("+")' \
        <<<"${multi_dependency_iids}")"
      multi_scope_id="${SHARED_GRAPH_SCOPE_BY_IID[${candidate_iid}]:-fan-in:${PROJECT_FULL}:${multi_scope_suffix}+${candidate_iid}}"
      if ! STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -ce \
          --arg branch "${multi_work_branch}" \
          --argjson head "${multi_anchor_iid}" \
          --argjson tail "${candidate_iid}" \
          --argjson dependencies "${multi_dependency_iids}" \
          --arg scope_id "${multi_scope_id}" \
          --arg target "${candidate_merge_target}" '
          [.shared_branch_groups | to_entries[]
            | .value as $group
            | (($group.dependency_iids // [$group.head_iid]) + [$group.tail_iid])
              as $bound
            | select(any($bound[]; . as $iid
                | ($dependencies + [$tail]) | index($iid) != null))] as $overlaps
          | if ($overlaps | length) == 0 then
              .shared_branch_groups[$branch] = {
                work_branch:$branch,head_iid:$head,tail_iid:$tail,
                members:[$head,$tail],dependency_iids:$dependencies,
                dependency_mode:"fan_in",scope_id:$scope_id,
                merge_target_branch:$target
              }
            elif ($overlaps | length) == 1
              and $overlaps[0].key == $branch
              and $overlaps[0].value.head_iid == $head
              and $overlaps[0].value.tail_iid == $tail
              and $overlaps[0].value.dependency_iids == $dependencies
              and $overlaps[0].value.merge_target_branch == $target
            then . else error("multi shared branch binding conflict") end
        ' 2>/dev/null)"; then
        DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_binding_conflict"
        append_batch_iid "${candidate_iid}"
        continue
      fi
      persist_state "${STATE_JSON}"
    fi

    WORK_BRANCH_BY_IID["${multi_anchor_iid}"]="${multi_work_branch}"
    WORK_BRANCH_BY_IID["${candidate_iid}"]="${multi_work_branch}"
    BRANCH_MEMBERS_JSON_BY_IID["${multi_anchor_iid}"]="${multi_members_json}"
    BRANCH_MEMBERS_JSON_BY_IID["${candidate_iid}"]="${multi_members_json}"
    SHARED_BRANCH_ROLE_BY_IID["${multi_anchor_iid}"]=head
    SHARED_BRANCH_ROLE_BY_IID["${candidate_iid}"]=tail
    MULTI_DEPENDENCY_IIDS_JSON_BY_TAIL["${candidate_iid}"]="${multi_dependency_iids}"
    while IFS= read -r multi_auxiliary_iid; do
      FAN_IN_AUXILIARY_GROUP_BY_IID["${multi_auxiliary_iid}"]="${multi_work_branch}"
    done < <(jq -r '.[1:][]' <<<"${multi_dependency_iids}")
    dependency_status=resolved
    dependency_result="$(jq -nc --argjson dependency_iid "${multi_anchor_iid}" \
      --arg base_branch "issue/${multi_anchor_iid}" '{
        status:"resolved",dependency_iid:$dependency_iid,base_branch:$base_branch
      }')"
    wrapper_log prepare_tick \
      "iid=${candidate_iid} dependency_fan_in_ready dependencies=${multi_dependency_iids} branch=${multi_work_branch}"
  fi

  case "${dependency_status}" in
    none)
      append_batch_iid "${candidate_iid}"
      ;;
    invalid)
      dependency_reason="$(
        printf '%s' "${dependency_result}" | jq -r '.reason // "invalid_dependency"'
      )"
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="${dependency_reason}"
      append_batch_iid "${candidate_iid}"
      ;;
    resolved)
      dependency_iid="$(printf '%s' "${dependency_result}" | jq -r '.dependency_iid')"
      parsed_dependency_branch="$(printf '%s' "${dependency_result}" | jq -r '.base_branch')"
      late_binding_pair=false
      expected_shared_branch="issue/${dependency_iid}+${candidate_iid}"
      if ! [[ "${dependency_iid}" =~ ^[1-9][0-9]*$ ]] \
          || [ "${parsed_dependency_branch}" != "issue/${dependency_iid}" ]; then
        DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="invalid_dependency_parser_result"
        append_batch_iid "${candidate_iid}"
      elif [ "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" = tail ] \
          && [ "${WORK_BRANCH_BY_IID[${candidate_iid}]:-}" = \
            "${expected_shared_branch}" ]; then
        dependency_branch="${WORK_BRANCH_BY_IID[${candidate_iid}]}"
      elif [ "${LATE_SHARED_HEAD_BY_TAIL[${candidate_iid}]:-}" = \
            "${dependency_iid}" ] \
          && [ "${LATE_SHARED_BRANCH_BY_TAIL[${candidate_iid}]:-}" = \
            "${expected_shared_branch}" ]; then
        late_binding_pair=true
        dependency_branch="${expected_shared_branch}"
        BRANCH_MEMBERS_JSON_BY_IID["${candidate_iid}"]="${LATE_SHARED_MEMBERS_BY_TAIL[${candidate_iid}]}"
      else
        existing_dependency_binding="$(printf '%s' "${STATE_JSON}" | jq -r \
          --argjson head "${dependency_iid}" \
          --argjson tail "${candidate_iid}" '
          [.shared_branch_groups | to_entries[]
            | select(.value as $group
              | (($group.dependency_iids // [$group.head_iid]) + [$group.tail_iid])
              | (index($head) != null or index($tail) != null))
            | .key] | unique | join(",")')"
        if [ -n "${existing_dependency_binding}" ]; then
          DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_binding_conflict"
        elif [ "${candidate_auto_merge}" = true ]; then
          DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_auto_merge_unsupported"
        else
          # C can arrive in a later batch whose frozen scope no longer contains
          # A.  Bind from C's direct declaration; the migration helper proves
          # that A is a completed ordinary head and serializes the mutation.
          late_binding_pair=true
          dependency_branch="${expected_shared_branch}"
          late_members_json="[${dependency_iid},${candidate_iid}]"
          late_scope_id="${SHARED_GRAPH_SCOPE_BY_IID[${candidate_iid}]:-late:${PROJECT_FULL}:${dependency_iid}+${candidate_iid}}"
          LATE_SHARED_HEAD_BY_TAIL["${candidate_iid}"]="${dependency_iid}"
          LATE_SHARED_TAIL_BY_HEAD["${dependency_iid}"]="${candidate_iid}"
          LATE_SHARED_BRANCH_BY_TAIL["${candidate_iid}"]="${expected_shared_branch}"
          LATE_SHARED_MEMBERS_BY_TAIL["${candidate_iid}"]="${late_members_json}"
          LATE_SHARED_SCOPE_BY_TAIL["${candidate_iid}"]="${late_scope_id}"
          BRANCH_MEMBERS_JSON_BY_IID["${candidate_iid}"]="${late_members_json}"
        fi
        if [ -n "${DEPENDENCY_ERROR_BY_IID[${candidate_iid}]:-}" ]; then
          append_batch_iid "${candidate_iid}"
        fi
      fi
      if [ -z "${DEPENDENCY_ERROR_BY_IID[${candidate_iid}]:-}" ] \
          && { [ "${SHARED_BRANCH_ROLE_BY_IID[${candidate_iid}]:-}" = tail ] \
            || [ "${late_binding_pair}" = true ]; }; then
        if load_dependency_issue_snapshot "${dependency_iid}" direct; then
          dependency_issue_json="${DEPENDENCY_CHAIN_ISSUE_JSON}"
        else
          case "${DEPENDENCY_CHAIN_LOAD_OUTCOME}" in
            timeout|budget|deadline)
              record_dependency_wait "${candidate_iid}" "${dependency_iid}" \
                "${dependency_branch}" "dependency_cycle_check_deferred"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_cycle_check_deferred dependency_iid=${dependency_iid} detail=direct_lookup_${DEPENDENCY_CHAIN_LOAD_OUTCOME}"
              if [ "${DISPATCH_MODE}" = scheduled ]; then
                break
              fi
              continue
              ;;
            *)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_issue_lookup_failed"
              append_batch_iid "${candidate_iid}"
              continue
              ;;
          esac
        fi

        dependency_completed="false"
        dependency_completed="$(printf '%s' "${dependency_issue_json}" | jq -r '
          (.labels // []) as $labels
          | ((($labels | index("pr")) != null)
              or (($labels | index("finish")) != null))
            and ([$labels[] | select(
              . == "continue" or . == "contiune" or . == "doing"
              or . == "retry" or . == "todo" or . == "new"
              or . == "timeout" or . == "blocked" or startswith("blocked-")
              or . == "failed" or startswith("failed-"))] | length) == 0
        ')"
        if [ "${dependency_completed}" != "true" ]; then
          detect_live_dependency_cycle "${candidate_iid}" "${dependency_iid}"
          case "${DEPENDENCY_CHAIN_STATUS}" in
            cycle)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_cycle"
              append_batch_iid "${candidate_iid}"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_cycle dependency_iid=${dependency_iid}"
              continue
              ;;
            too_deep)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_chain_too_deep"
              append_batch_iid "${candidate_iid}"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_chain_too_deep dependency_iid=${dependency_iid} max_depth=${DEPENDENCY_CHAIN_MAX_DEPTH}"
              continue
              ;;
            chain_invalid)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_chain_invalid"
              append_batch_iid "${candidate_iid}"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_chain_invalid dependency_iid=${dependency_iid}"
              continue
              ;;
            lookup_failed)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_issue_lookup_failed"
              append_batch_iid "${candidate_iid}"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_chain_lookup_failed dependency_iid=${dependency_iid}"
              continue
              ;;
            parser_failed)
              DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_parser_failed"
              append_batch_iid "${candidate_iid}"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_chain_parser_failed dependency_iid=${dependency_iid}"
              continue
              ;;
            deferred_timeout|deferred_budget)
              record_dependency_wait "${candidate_iid}" "${dependency_iid}" \
                "${dependency_branch}" "dependency_cycle_check_deferred"
              wrapper_log prepare_tick \
                "iid=${candidate_iid} dependency_cycle_check_deferred dependency_iid=${dependency_iid} detail=${DEPENDENCY_CHAIN_STATUS}"
              if [ "${DISPATCH_MODE}" = scheduled ]; then
                break
              fi
              continue
              ;;
          esac
        fi
        # Live labels alone can become success-shaped before A's Phase 6 has
        # durably drained its scheduler claim.  A pending claim always blocks
        # C.  For a late-bound pair, A may belong to an earlier campaign whose
        # completed_iids is no longer present here; the migration helper then
        # supplies the stronger proof by validating A's private done state,
        # exact remote SHA and unique live MR before performing any mutation.
        dependency_campaign_settled="$(jq -r \
          --argjson dependency_iid "${dependency_iid}" \
          --argjson late_binding_pair "${late_binding_pair}" \
          --argjson multi_fan_in "$([ -n "${MULTI_DEPENDENCY_IIDS_JSON_BY_TAIL[${candidate_iid}]:-}" ] \
            && printf true || printf false)" '
          ((.pending_subagents // {})[($dependency_iid|tostring)] // null) == null
          and ($late_binding_pair or $multi_fan_in
            or ((.completed_iids // []) | index($dependency_iid) != null))
        ' <<<"${STATE_JSON}")"
        if [ "${dependency_campaign_settled}" != "true" ]; then
          dependency_completed="false"
        fi
        if [ "${late_binding_pair}" = true ] \
            && [ "${dependency_completed}" = true ]; then
          migration_output=""
          migration_rc=0
          set +e
          migration_output="$(
            MIGRATION_HEAD_IID="${dependency_iid}" \
            MIGRATION_TAIL_IID="${candidate_iid}" \
            MIGRATION_TARGET_BRANCH="${candidate_merge_target}" \
            timeout --kill-after=30s 600s \
              bash "${SCRIPT_DIR}/migrate_shared_dependency_head.sh"
          )"
          migration_rc=$?
          set -e
          if [ "${migration_rc}" -eq 75 ] \
              || [ "${migration_rc}" -eq 124 ] \
              || [ "${migration_rc}" -eq 137 ]; then
            record_dependency_wait "${candidate_iid}" "${dependency_iid}" \
              "${dependency_branch}" "dependency_branch_migration_pending"
            wrapper_log prepare_tick \
              "iid=${candidate_iid} dependency_branch_migration_pending dependency_iid=${dependency_iid}"
            continue
          fi
          if [ "${migration_rc}" -ne 0 ] \
              || ! jq -e \
                --argjson head "${dependency_iid}" \
                --argjson tail "${candidate_iid}" \
                --arg branch "${dependency_branch}" '
                .status == "ready"
                and .head_iid == $head and .tail_iid == $tail
                and .work_branch == $branch
                and (.commit_sha | type == "string"
                  and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
              ' <<<"${migration_output}" >/dev/null 2>&1; then
            DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="dependency_branch_migration_failed"
            append_batch_iid "${candidate_iid}"
            wrapper_log prepare_tick \
              "iid=${candidate_iid} dependency_branch_migration_failed dependency_iid=${dependency_iid} rc=${migration_rc}"
            continue
          fi

          migration_scope_id="${LATE_SHARED_SCOPE_BY_TAIL[${candidate_iid}]}"
          if ! STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -ce \
              --arg branch "${dependency_branch}" \
              --argjson head "${dependency_iid}" \
              --argjson tail "${candidate_iid}" \
              --arg scope_id "${migration_scope_id}" \
              --arg target "${candidate_merge_target}" '
              [.shared_branch_groups | to_entries[]
                | select(.value as $group
                  | (($group.dependency_iids // [$group.head_iid]) + [$group.tail_iid])
                  | (index($head) != null or index($tail) != null))] as $overlaps
              | if ($overlaps | length) == 0 then
                  .shared_branch_groups[$branch] = {
                    work_branch:$branch,head_iid:$head,tail_iid:$tail,
                    members:[$head,$tail],scope_id:$scope_id,
                    merge_target_branch:$target
                  }
                elif ($overlaps | length) == 1
                  and $overlaps[0].key == $branch
                  and $overlaps[0].value.head_iid == $head
                  and $overlaps[0].value.tail_iid == $tail
                  and $overlaps[0].value.merge_target_branch == $target
                then .
                else error("late shared branch binding conflict") end
            ' 2>/dev/null)"; then
            DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="shared_branch_binding_conflict"
            append_batch_iid "${candidate_iid}"
            continue
          fi
          persist_state "${STATE_JSON}"
          WORK_BRANCH_BY_IID["${dependency_iid}"]="${dependency_branch}"
          WORK_BRANCH_BY_IID["${candidate_iid}"]="${dependency_branch}"
          BRANCH_MEMBERS_JSON_BY_IID["${dependency_iid}"]="[${dependency_iid},${candidate_iid}]"
          BRANCH_MEMBERS_JSON_BY_IID["${candidate_iid}"]="[${dependency_iid},${candidate_iid}]"
          SHARED_BRANCH_ROLE_BY_IID["${dependency_iid}"]=head
          SHARED_BRANCH_ROLE_BY_IID["${candidate_iid}"]=tail
          late_binding_pair=false
          wrapper_log prepare_tick \
            "iid=${candidate_iid} dependency_branch_migrated dependency_iid=${dependency_iid} branch=${dependency_branch}"
        fi
        dependency_branch_ready="false"
        dependency_branch_sha=""
        if dependency_branch_sha="$(GIT_NO_REPLACE_OBJECTS=1 \
            git -C "${REPO_PATH}" rev-parse --verify \
            "refs/remotes/origin/${dependency_branch}^{commit}" 2>/dev/null)"; then
          dependency_branch_ready="true"
        fi

        dependency_recorded_sha=""
        dependency_recorded_identity=""
        dependency_state_file="${ISSUES_ROOT}/issue-${dependency_iid}/state.json"
        dependency_state_mode=""
        dependency_state_owner=""
        dependency_state_bytes=""
        if [ -f "${dependency_state_file}" ] \
            && [ ! -L "${dependency_state_file}" ]; then
          dependency_state_mode="$(phase6_file_mode \
            "${dependency_state_file}" 2>/dev/null || true)"
          dependency_state_owner="$(phase6_file_owner \
            "${dependency_state_file}" 2>/dev/null || true)"
          dependency_state_bytes="$(wc -c <"${dependency_state_file}" \
            2>/dev/null | tr -d '[:space:]' || true)"
        fi
        if [ -f "${dependency_state_file}" ] \
            && [ ! -L "${dependency_state_file}" ] \
            && [ "${dependency_state_mode}" = 600 ] \
            && [ "${dependency_state_owner}" = "$(id -u)" ] \
            && [[ "${dependency_state_bytes}" =~ ^[1-9][0-9]*$ ]] \
            && [ "${dependency_state_bytes}" -le 65536 ]; then
          dependency_recorded_identity="$(jq -ec \
            --argjson head_iid "${dependency_iid}" \
            --arg work_branch "${dependency_branch}" \
            --arg target_branch "${candidate_merge_target}" \
            --argjson members "${BRANCH_MEMBERS_JSON_BY_IID[${candidate_iid}]}" '
            if .iid == $head_iid
              and .status == "done"
              and .work_branch == $work_branch
              and .branch_members == $members
              and .shared_branch_role == "head"
              and (.dependency_iid // null) == null
              and (.dependency_branch // null) == null
              and (.dependency_base_sha // null) == null
              and (.commit_sha | type == "string")
              and (.commit_sha | test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
              and .dependency_history_verified == true
              and .work_branch_sha == .commit_sha
              and (.merge_request_url | type == "string"
                and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
              and (.mr_finalization | type == "object")
              and ((.mr_finalization | keys | sort) == ([
                "branch_members","commit_sha","iid","intent_id","mr_action",
                "shared_branch_role","source_execution_id","status",
                "target_branch","verified_at","web_url","work_branch"
              ] | sort))
              and .mr_finalization.status == "verified_open"
              and (.mr_finalization.source_execution_id | type == "number"
                and . == floor and . > 0)
              and .mr_finalization.source_execution_id == .latest_execution_id
              and .mr_finalization.source_execution_id ==
                .dependency_pinned_execution_id
              and .mr_finalization.work_branch == $work_branch
              and .mr_finalization.branch_members == $members
              and .mr_finalization.shared_branch_role == "head"
              and .mr_finalization.commit_sha == .commit_sha
              and (.mr_finalization.intent_id | type == "string"
                and test("^[0-9a-f]{64}$"))
              and .mr_finalization.target_branch == $target_branch
              and (.mr_finalization.iid | type == "number"
                and . == floor and . > 0)
              and .mr_finalization.web_url == .merge_request_url
              and (.mr_finalization as $mr
                | $mr.web_url | test(
                  "/-/merge_requests/" + ($mr.iid | tostring) + "/?$"))
              and .mr_finalization.mr_action == "created"
              and (.mr_finalization.verified_at | type == "string" and length > 0)
            then {
              commit_sha:.commit_sha,
              intent_id:.mr_finalization.intent_id,
              mr_iid:.mr_finalization.iid,
              mr_url:.mr_finalization.web_url,
              target_branch:.mr_finalization.target_branch,
              work_branch:.mr_finalization.work_branch,
              branch_members:.mr_finalization.branch_members
            } else empty end
          ' "${dependency_state_file}" 2>/dev/null || true)"
          if [ -n "${dependency_recorded_identity}" ]; then
            dependency_recorded_sha="$(jq -r '.commit_sha' \
              <<<"${dependency_recorded_identity}")"
          fi
        fi
        dependency_commit_verified="false"
        if [ -n "${dependency_recorded_sha}" ] \
            && [ "${dependency_recorded_sha,,}" = "${dependency_branch_sha,,}" ]; then
          dependency_live_mr=""
          if dependency_live_mr="$(shared_mr_query_live_identity \
              "$(jq -r '.mr_iid' <<<"${dependency_recorded_identity}")" \
              "$(jq -r '.mr_url' <<<"${dependency_recorded_identity}")" \
              "$(jq -r '.work_branch' <<<"${dependency_recorded_identity}")" \
              "$(jq -r '.target_branch' <<<"${dependency_recorded_identity}")" \
              "${dependency_recorded_sha}" \
              "$(jq -r '.intent_id' <<<"${dependency_recorded_identity}")" \
              "$(jq -r '.branch_members[0]' <<<"${dependency_recorded_identity}")" \
              "$(jq -r '.branch_members[1]' <<<"${dependency_recorded_identity}")")" \
              && [ "$(jq -r '.identity_matches' <<<"${dependency_live_mr}")" = true ] \
              && [ "$(jq -r '.state' <<<"${dependency_live_mr}")" = opened ]; then
            dependency_commit_verified="true"
          fi
        fi

        dependency_wait_reason=""
        if [ "${dependency_completed}" != "true" ]; then
          dependency_wait_reason="dependency_not_completed"
        elif [ "${dependency_branch_ready}" != "true" ]; then
          dependency_wait_reason="dependency_branch_missing"
        elif [ "${dependency_commit_verified}" != "true" ]; then
          dependency_wait_reason="dependency_commit_unverified"
        fi

        # Automatic merge may target an integration branch independent of the
        # development baseline. Never let C auto-merge A's still-unmerged
        # commits into that target: the pinned A commit must already be an
        # ancestor of the exact target ref.
        if [ -z "${dependency_wait_reason}" ] \
            && [ "${DISPATCH_MODE}" = "driven_topup" ]; then
          candidate_grant_json="$(printf '%s' "${DRIVEN_EXECUTABLE_GRANTS_JSON}" \
            | jq -c --argjson iid "${candidate_iid}" \
              '.[] | select(.iid == $iid)')"
          candidate_auto_merge="$(printf '%s' "${candidate_grant_json}" \
            | jq -r '.auto_merge')"
          candidate_merge_target="$(printf '%s' "${candidate_grant_json}" \
            | jq -r '.merge_target_branch // .branch // empty')"
          if [ "${candidate_auto_merge}" = "true" ] \
              && { [ -z "${candidate_merge_target}" ] \
                || ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
                  merge-base --is-ancestor \
                  "${dependency_branch_sha}" \
                  "refs/remotes/origin/${candidate_merge_target}" \
                  >/dev/null 2>&1; }; then
            dependency_wait_reason="dependency_not_in_merge_target"
          fi
        fi

        if [ -z "${dependency_wait_reason}" ]; then
          DEPENDENCY_IID_BY_IID["${candidate_iid}"]="${dependency_iid}"
          DEPENDENCY_BRANCH_BY_IID["${candidate_iid}"]="${dependency_branch}"
          DEPENDENCY_BASE_SHA_BY_IID["${candidate_iid}"]="${dependency_branch_sha}"
          EXPECTED_WORK_BRANCH_SHA_BY_IID["${candidate_iid}"]="${dependency_branch_sha}"
          append_batch_iid "${candidate_iid}"
          wrapper_log prepare_tick \
            "iid=${candidate_iid} dependency_ready dependency_iid=${dependency_iid} base_branch=${dependency_branch} base_sha=${dependency_branch_sha}"
          continue
        fi
        record_dependency_wait "${candidate_iid}" "${dependency_iid}" \
          "${dependency_branch}" "${dependency_wait_reason}"
        wrapper_log prepare_tick \
          "iid=${candidate_iid} dependency_waiting dependency_iid=${dependency_iid} branch=${dependency_branch} reason=${dependency_wait_reason}"
      fi
      ;;
    *)
      DEPENDENCY_ERROR_BY_IID["${candidate_iid}"]="invalid_dependency_parser_status"
      append_batch_iid "${candidate_iid}"
      ;;
  esac
done

# A fixed scan prefix lets a large set of waiting dependencies starve every
# later candidate forever. When the bounded scan stopped before covering the
# rotated stream and still did not fill the batch, persist the IID after the
# last inspected entry as the next starting point. A complete scan or a full
# batch resets normal priority order.
if [ "${DISPATCH_MODE}" = scheduled ]; then
  PRELIMINARY_BATCH_SIZE="$(printf '%s' "${BATCH_JSON}" | jq -r 'length')"
  NEXT_DEPENDENCY_SCAN_CURSOR=""
  if [ "${DEPENDENCY_PREFLIGHT_SCANNED}" -lt "${DEPENDENCY_CANDIDATE_COUNT}" ] \
      && [ "${PRELIMINARY_BATCH_SIZE}" -lt "${BATCH_CAP}" ] \
      && [ -n "${DEPENDENCY_PREFLIGHT_LAST_SCANNED_IID}" ]; then
    NEXT_DEPENDENCY_SCAN_CURSOR=$((DEPENDENCY_PREFLIGHT_LAST_SCANNED_IID + 1))
  fi
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
    --arg cursor "${NEXT_DEPENDENCY_SCAN_CURSOR}" '
      .dependency_scan_cursor_iid =
        (if $cursor == "" then null else ($cursor | tonumber) end)')"
  persist_state "${STATE_JSON}"
fi

# Keep waiting IIDs in the backlog even if runnable later candidates move the
# fresh cursor forward. The dependency is re-read from live Issue content on
# every tick, so editing/removing the declaration takes effect without a state
# migration.
DEPENDENCY_WAITING_IIDS_JSON="$(
  printf '%s' "${DEPENDENCY_WAITING_JSON}" | jq -c 'map(.iid)'
)"
if [ "$(printf '%s' "${DEPENDENCY_WAITING_IIDS_JSON}" | jq -r 'length')" -gt 0 ]; then
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
    --argjson waiting "${DEPENDENCY_WAITING_IIDS_JSON}" '
      .unfinished_iids = (((.unfinished_iids // []) + $waiting) | unique | sort)
      | .campaign_status = "running"
    ')"
  persist_state "${STATE_JSON}"
fi

BATCH_SIZE="$(printf '%s' "${BATCH_JSON}" | jq -r 'length')"
if [ "${BATCH_SIZE}" = "0" ]; then
  if [ "${DISPATCH_MODE}" = "driven_topup" ]; then
    CURRENT_PENDING_IIDS_JSON="$(printf '%s' "${STATE_JSON}" \
      | jq -c '.pending_subagents | keys | map(tonumber) | sort')"
    jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "no runnable IIDs this tick" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson pending_iids "${CURRENT_PENDING_IIDS_JSON}" \
      --argjson skipped_entries "${SKIPPED_ENTRIES_JSON}" \
      --argjson dependency_waiting "${DEPENDENCY_WAITING_JSON}" \
      --argjson deferred_entries "${DEFERRED_ENTRIES_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[], pending_iids:$pending_iids,
        skipped_entries:$skipped_entries,
        dependency_waiting:$dependency_waiting,
        deferred_entries:$deferred_entries,
        cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
  else
    jq -nc --arg ev "${EVIDENCE_PATH}" --arg chat "no runnable IIDs this tick" \
      --argjson cleanup_actions "${CLEANUP_ACTIONS_JSON}" \
      --argjson dependency_waiting "${DEPENDENCY_WAITING_JSON}" \
      '{status:"no_eligible_iids", dispatch_entries:[],
        dependency_waiting:$dependency_waiting,
        cleanup_actions:$cleanup_actions, chat_summary:$chat, last_reconcile_evidence:$ev}'
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

# ─── 17. Generate execution identities ─────────────────────────────────
declare -A EXECUTION_ID_BY_IID
mapfile -t BATCH_IIDS < <(printf '%s' "${BATCH_JSON}" | jq -r '.[]')
# allocate_execution_id.sh prints ONLY the integer execution identity on stdout. Capture
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
       bash "${SCRIPT_DIR}/allocate_execution_id.sh" 2>"${ALLOC_ERR}")"
  _rc=$?
  set -e
  if [ "${_rc}" -ne 0 ]; then
    # Capture allocate_execution_id.sh stderr to wrapper.log first, then emit a
    # stable, named reason only — never tail raw sub-tool stderr into
    # chat_summary (see emit_chat_failure contract + SOUL.md §No-Fallback).
    wrapper_log prepare_tick "allocate_execution_id_failed iid=${iid} rc=${_rc} (stderr follows)"
    cat "${ALLOC_ERR}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>/dev/null || true
    emit_chat_failure "allocate_execution_id_failed: iid=${iid} (rc=${_rc}; stderr in dispatcher wrapper.log)"
  fi
  EXECUTION_ID_BY_IID["${iid}"]="${N}"
done

# ─── 18. Pre-spawn persist (placeholder pending entries) ──────────
# Defensive guard: every value below is passed to `jq --argjson`, which rejects
# a non-JSON token with the generic "invalid JSON text passed to --argjson".
# An empty execution identity would surface
# far from its real cause and invite a misdiagnosis as a "jq version bug".
# Validate it here once and fail with a named, terminal reason.
for iid in "${BATCH_IIDS[@]}"; do
  for _pair in "iid:${iid}" "execution_id:${EXECUTION_ID_BY_IID[$iid]:-}"; do
    _field="${_pair%%:*}"; _val="${_pair#*:}"
    case "${_val}" in
      ''|*[!0-9]*)
        emit_chat_failure "prep_invariant_violation: iid=${iid} ${_field}='${_val}' is not a positive numeric execution identity"
        ;;
    esac
  done
done

PRE_PENDING_JQ_ARGS=()
for iid in "${BATCH_IIDS[@]}"; do
  PRE_PENDING_JQ_ARGS+=( --argjson "iid_${iid}" "${iid}"
                         --argjson "exec_${iid}" "${EXECUTION_ID_BY_IID[$iid]}" )
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
  FILTER+=" | .pending_subagents[\"${iid}\"] = {execution_id: \$exec_${iid}, run_id: null, child_session_key: null, spawned_at: null, placeholder: true, acpx_timeout_seconds: \$acpx_timeout, auto_merge: false, merge_target_branch: null}"
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
for iid in "${BATCH_IIDS[@]}"; do
  STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
    --arg iid "${iid}" \
    --arg work_branch "${WORK_BRANCH_BY_IID[${iid}]:-issue/${iid}}" \
    --argjson branch_members "${BRANCH_MEMBERS_JSON_BY_IID[${iid}]:-[${iid}]}" \
    --arg shared_branch_role "${SHARED_BRANCH_ROLE_BY_IID[${iid}]:-}" \
    --arg expected_work_branch_sha "${EXPECTED_WORK_BRANCH_SHA_BY_IID[${iid}]:-}" '
    .pending_subagents[$iid] += {
      work_branch:$work_branch,
      branch_members:$branch_members,
      shared_branch_role:(if $shared_branch_role == "" then null else $shared_branch_role end),
      expected_work_branch_sha:(if $expected_work_branch_sha == "" then null else $expected_work_branch_sha end)
    }')"
  if [ -n "${DEPENDENCY_BASE_SHA_BY_IID[${iid}]:-}" ]; then
    STATE_JSON="$(printf '%s' "${STATE_JSON}" | jq -c \
      --arg iid "${iid}" \
      --argjson dependency_iid "${DEPENDENCY_IID_BY_IID[${iid}]}" \
      --arg dependency_branch "${DEPENDENCY_BRANCH_BY_IID[${iid}]}" \
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA_BY_IID[${iid}]}" '
      .pending_subagents[$iid] += {
        dependency_iid:$dependency_iid,
        dependency_branch:$dependency_branch,
        dependency_base_sha:$dependency_base_sha
      }')"
  fi
done
persist_state "${STATE_JSON}"

# ─── 19. Per-IID prep ─────────────────────────────────────────────
TICK_OUTCOMES='{}'
DISPATCH_ENTRIES='[]'
declare -A PAYLOAD_PATH CHILD_LABEL_BY_IID
for iid in "${BATCH_IIDS[@]}"; do
  execution_id="${EXECUTION_ID_BY_IID[$iid]}"
  child_label="#${iid}-exec-${execution_id}"
  CHILD_LABEL_BY_IID["${iid}"]="${child_label}"

  # Initialize per-iteration locals so set -u cannot trip a later read of
  # an unset var on the failure paths below.
  MODE_ACTUAL=""
  LOCAL_ISSUE_BRANCH=""
  ISSUE_TITLE=""
  ISSUE_LABELS=""
  IID_BRANCH="${T[branch]}"
  GRANT_ENTRY_MODE="auto"
  IID_FORCE_RERUN_PR="false"
  IID_AUTO_MERGE="false"
  IID_MERGE_TARGET_BRANCH="${T[branch]}"
  IID_DEPENDENCY_IID="${DEPENDENCY_IID_BY_IID[${iid}]:-}"
  IID_DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH_BY_IID[${iid}]:-}"
  IID_DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA_BY_IID[${iid}]:-}"
  IID_WORK_BRANCH="${WORK_BRANCH_BY_IID[${iid}]:-issue/${iid}}"
  IID_BRANCH_MEMBERS_JSON="${BRANCH_MEMBERS_JSON_BY_IID[${iid}]:-[${iid}]}"
  IID_SHARED_BRANCH_ROLE="${SHARED_BRANCH_ROLE_BY_IID[${iid}]:-}"
  IID_EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA_BY_IID[${iid}]:-}"
  IID_EXPECTED_COMMIT_PARENT_SHA=""
  if [ "${IID_SHARED_BRANCH_ROLE}" = tail ]; then
    IID_EXPECTED_COMMIT_PARENT_SHA="${IID_DEPENDENCY_BASE_SHA}"
  fi
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
  IID_CONFIG_BRANCH="${IID_BRANCH}"

  # A ready dependency overrides only this Issue's processing baseline. The
  # dependent pushes its commit to the pair's frozen WORK_BRANCH=issue/<A>+<C>;
  # the request's independently resolved MR target remains unchanged.
  if [ -n "${DEPENDENCY_BRANCH_BY_IID[${iid}]:-}" ] \
      && [ "${CONTINUE_BASE_REQUIRED_BY_IID[${iid}]:-false}" != true ]; then
    IID_BRANCH="${DEPENDENCY_BRANCH_BY_IID[${iid}]}"
  fi
  IID_BRANCH_QUOTED="'${IID_BRANCH//\'/\'\\\'\'}'"
  IID_MERGE_TARGET_BRANCH_QUOTED="'${IID_MERGE_TARGET_BRANCH//\'/\'\\\'\'}'"
  IID_WORK_BRANCH_QUOTED="'${IID_WORK_BRANCH//\'/\'\\\'\'}'"

  # Per-IID env for env_paths-derived paths.
  iid_env=(
    PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}"
    REPO_PARENT_PATH="${REPO_PARENT_PATH}"
    ISSUE_IID="${iid}" EXECUTION_ID="${execution_id}"
    WORK_BRANCH="${IID_WORK_BRANCH}"
  )

  # Resolve ISSUE_MODE from live labels. `continue` / `contiune` is the only
  # resume signal. Every other entry path (`todo`, `retry`, `new`,
  # `blocked`, trigger require_labels) resets from the target branch
  # baseline, even if this IID has prior run state on disk.
  ISSUE_MODE="fresh"
  if [ "${DISPATCH_MODE}" = "driven_topup" ] && [ "${GRANT_ENTRY_MODE}" != "auto" ]; then
    ISSUE_MODE="${GRANT_ENTRY_MODE}"
  elif [ "${ISSUE_JSON_CACHE[${iid}]+present}" = "present" ]; then
    NEEDS_CONTINUE="$(printf '%s' "${ISSUE_JSON_CACHE[${iid}]}" | jq -r '
      (.labels // []) as $labels
      | (($labels | index("continue")) != null
          or ($labels | index("contiune")) != null)
    ')"
    RESET_REQUESTED="$(printf '%s' "${ISSUE_JSON_CACHE[${iid}]}" | jq -r '
      (.labels // []) as $labels
      | (($labels | index("retry")) != null
          or ($labels | index("todo")) != null)
    ')"
    if [ "${NEEDS_CONTINUE}" = "true" ] \
        && [ "${RESET_REQUESTED}" != "true" ]; then
      ISSUE_MODE="continue"
    fi
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
    REPLY_JSON="$(phase6_synthesize_blocked "${iid}" "${execution_id}" "dispatcher prep failed: ${reason}")"
    PHASE6_OUT="$(phase6_process "${STATE_JSON}" "${REPLY_JSON}" "false")"
    STATE_JSON="$(printf '%s' "${PHASE6_OUT}" | jq -c '.updated_state')"
    persist_state "${STATE_JSON}"
    TICK_OUTCOMES="$(printf '%s' "${TICK_OUTCOMES}" | jq -c --arg k "${iid}" --arg v "blocked: ${reason}" '. + {($k):$v}')"
  }

  append_driven_scheduler_skip() {
    local reason="$1"
    [ "${DISPATCH_MODE}" = "driven_topup" ] || return 0
    SKIPPED_ENTRIES_JSON="$(printf '%s' "${SKIPPED_ENTRIES_JSON}" | jq -c \
      --argjson grant "${IID_GRANT_JSON}" --arg reason "${reason}" '
        if any(.[]; .job_id == $grant.job_id) then .
        else . + [($grant | {
          job_id,batch_id,snapshot_index,project,iid,
          status:"skipped",reason:$reason
        })]
        end
      ')"
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
    append_driven_scheduler_skip "${reason}"
    persist_state "${STATE_JSON}"
    TICK_OUTCOMES="$(printf '%s' "${TICK_OUTCOMES}" | jq -c \
      --arg k "${iid}" --arg v "skipped: ${reason}" '. + {($k):$v}')"
  }

  # Use the dependency preflight's live Issue response when available. This
  # keeps the description used for branch selection identical to the body
  # rendered into the attempt prompt. A transient preflight read failure is
  # retried once here and classified through the existing per-IID prep path.
  if [ "${ISSUE_JSON_CACHE[${iid}]+present}" = "present" ]; then
    ISSUE_JSON="${ISSUE_JSON_CACHE[${iid}]}"
  else
    ISSUE_JSON="$(
      timeout --kill-after=1s 10s \
        glab api "projects/${PROJECT_URI}/issues/${iid}" 2>/dev/null \
        || true
    )"
  fi
  if [ -z "${ISSUE_JSON}" ]; then
    prep_blocked "glab api issues/${iid} returned empty"
    continue
  fi
  if ! ISSUE_JSON="$(printf '%s' "${ISSUE_JSON}" | jq -ce '
      if type == "object" then . else error("invalid Issue response") end
    ' 2>/dev/null)"; then
    prep_blocked "glab api issues/${iid} returned invalid JSON"
    continue
  fi
  ISSUE_TITLE="$(printf '%s' "${ISSUE_JSON}" | jq -r '.title // ""')"
  ISSUE_LABELS="$(printf '%s' "${ISSUE_JSON}" | jq -r '.labels // [] | join(",")')"
  ISSUE_LIVE_STATE="$(printf '%s' "${ISSUE_JSON}" | jq -r '.state // "opened"')"
  ISSUE_HAS_FINISH="$(printf '%s' "${ISSUE_JSON}" | jq -r \
    '(.labels // [] | index("finish")) != null')"
  ISSUE_HAS_PR="$(printf '%s' "${ISSUE_JSON}" | jq -r \
    '(.labels // [] | index("pr")) != null')"
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
  if [ -n "${DEPENDENCY_ERROR_BY_IID[${iid}]:-}" ]; then
    dependency_error_reason="${DEPENDENCY_ERROR_BY_IID[${iid}]}"
    prep_blocked "issue_dependency_invalid: ${dependency_error_reason}"
    append_driven_scheduler_skip "${dependency_error_reason}"
    continue
  fi

  # Persist the exact proposed baseline identity before prepare_attempt mutates
  # or creates the worktree. This issue-local file records the current
  # execution_id and is the fixed wrapper's trust source for the run, but it
  # is deliberately not durable proof
  # that C contains the dependency: Issue state promotes the tuple only after
  # the canonical remote work branch is pushed and independently verified.
  ISSUE_ROOT_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$ISSUE_ROOT"' "${SCRIPT_DIR}/env_paths.sh")"
  LOG_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$LOG_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  EXECUTION_STATE_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$EXECUTION_STATE_FILE"' "${SCRIPT_DIR}/env_paths.sh")"
  ISSUE_STATE_X="${ISSUE_ROOT_X}/state.json"
  mkdir -p "${ISSUE_ROOT_X}"
  PREP_IDENTITY_NOW="$(utc_now)"

  if ! jq -n \
      --argjson iid "${iid}" \
      --argjson execution_id "${execution_id}" \
      --arg started_at "${PREP_IDENTITY_NOW}" \
      --arg issue_title "${ISSUE_TITLE}" \
      --arg mode_requested "${ISSUE_MODE}" \
      --arg config_branch "${IID_CONFIG_BRANCH}" \
      --arg work_branch "${IID_WORK_BRANCH}" \
      --argjson branch_members "${IID_BRANCH_MEMBERS_JSON}" \
      --arg shared_branch_role "${IID_SHARED_BRANCH_ROLE}" \
      --arg expected_work_branch_sha "${IID_EXPECTED_WORK_BRANCH_SHA}" \
      --arg expected_commit_parent_sha "${IID_EXPECTED_COMMIT_PARENT_SHA}" \
      --argjson auto_merge "${IID_AUTO_MERGE}" \
      --arg merge_target_branch "${IID_MERGE_TARGET_BRANCH}" \
      --arg dependency_iid "${IID_DEPENDENCY_IID}" \
      --arg dependency_branch "${IID_DEPENDENCY_BRANCH}" \
      --arg dependency_base_sha "${IID_DEPENDENCY_BASE_SHA}" \
      --arg log_dir "${LOG_DIR_X}" '
      {iid:$iid, execution_id:$execution_id,
       execution_started_at:$started_at,
       issue_title:$issue_title,
       mode_requested:$mode_requested, mode_actual:null,
       mode_downgraded_from:null,
       no_reviewer_comments:false,
       config_branch:$config_branch,
       work_branch:$work_branch,
       branch_members:$branch_members,
       shared_branch_role:(if $shared_branch_role == "" then null else $shared_branch_role end),
       expected_work_branch_sha:(if $expected_work_branch_sha == "" then null else $expected_work_branch_sha end),
       expected_commit_parent_sha:(if $expected_commit_parent_sha == "" then null else $expected_commit_parent_sha end),
       auto_merge:$auto_merge,
       merge_target_branch:$merge_target_branch,
       dependency_iid:(if $dependency_iid == "" then null else ($dependency_iid | tonumber) end),
       dependency_branch:(if $dependency_branch == "" then null else $dependency_branch end),
       dependency_base_sha:(if $dependency_base_sha == "" then null else $dependency_base_sha end),
       local_branch:null, log_dir:$log_dir,
       status:"preparing"}' | atomic_write_json "${EXECUTION_STATE_X}"; then
    prep_blocked "unable to persist fixed pre-prepare execution identity"
    continue
  fi
  if ! chmod 600 "${EXECUTION_STATE_X}"; then
    prep_blocked "fixed pre-prepare execution identity must be private"
    continue
  fi

  # prepare_attempt.sh — keep stdout clean (the script's contract is two
  # lines on stdout: mode_actual, LOCAL_ISSUE_BRANCH). `git fetch` /
  # `git worktree add` etc. write progress to stderr; we capture stderr
  # to a separate file so it does NOT contaminate the two output lines.
  PA_OUT="$(mktemp)"
  PA_ERR="$(mktemp)"
  CLEANUP_FILES+=("${PA_OUT}" "${PA_ERR}")
  set +e
  env "${iid_env[@]}" BRANCH="${IID_BRANCH}" \
    CONFIG_BRANCH="${IID_CONFIG_BRANCH}" \
    DEPENDENCY_BASE_SHA="${IID_DEPENDENCY_BASE_SHA}" \
    SHARED_BRANCH_ROLE="${IID_SHARED_BRANCH_ROLE}" \
    EXPECTED_COMMIT_PARENT_SHA="${IID_EXPECTED_COMMIT_PARENT_SHA}" \
    CONTINUE_BASE_REQUIRED="${CONTINUE_BASE_REQUIRED_BY_IID[${iid}]:-false}" \
    CONTINUE_BASE_SHA="${CONTINUE_BASE_SHA_BY_IID[${iid}]:-}" \
    CONTINUE_BASE_REF="${CONTINUE_BASE_REF_BY_IID[${iid}]:-}" \
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
  LOCAL_ISSUE_BRANCH="$(sed -n '2p' "${PA_OUT}")"
  retire_temp_file "${PA_OUT}"
  retire_temp_file "${PA_ERR}"
  if [ -z "${MODE_ACTUAL}" ] || [ -z "${LOCAL_ISSUE_BRANCH}" ]; then
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

  if [ -n "${IID_SHARED_BRANCH_ROLE}" ]; then
    IID_EXPECTED_COMMIT_PARENT_SHA="$(GIT_NO_REPLACE_OBJECTS=1 \
      git -C "${REPO_PATH}" rev-parse --verify \
      "refs/heads/${LOCAL_ISSUE_BRANCH}^{commit}" 2>/dev/null || true)"
    if ! [[ "${IID_EXPECTED_COMMIT_PARENT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
      prep_blocked "shared branch prepared commit parent is unavailable"
      continue
    fi
    if [ "${IID_SHARED_BRANCH_ROLE}" = tail ] \
        && [ "${IID_EXPECTED_COMMIT_PARENT_SHA,,}" != \
          "${IID_DEPENDENCY_BASE_SHA,,}" ]; then
      prep_blocked "shared tail was not compressed onto its frozen dependency commit"
      continue
    fi
  fi

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
    # EXECUTION_ID is missing. We already set it for this iid; source in subshell.
    WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
    if ! cp "${MODEL_SETTINGS_SRC}" "${WORKTREE_DIR_X}/.claude/settings.json"; then
      prep_blocked "model_tiers settings copy failed"; continue
    fi
    GIT_ATTR_NOSYSTEM=1 git \
      -c core.hooksPath=/dev/null \
      -c core.fsmonitor=false \
      -c core.attributesFile=/dev/null \
      -c submodule.recurse=false \
      -C "${WORKTREE_DIR_X}" update-index \
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
    # EXECUTION_ID is missing. We already set it for this iid; source in subshell.
    WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
    if ! cp "${csp}" "${WORKTREE_DIR_X}/.claude/settings.json"; then
      prep_blocked "claude_settings copy failed"; continue
    fi
    GIT_ATTR_NOSYSTEM=1 git \
      -c core.hooksPath=/dev/null \
      -c core.fsmonitor=false \
      -c core.attributesFile=/dev/null \
      -c submodule.recurse=false \
      -C "${WORKTREE_DIR_X}" update-index \
      --skip-worktree .claude/settings.json || true
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
  ISSUE_SNAPSHOT_FILE="$(mktemp)"
  CLEANUP_FILES+=("${ISSUE_SNAPSHOT_FILE}")
  if ! (umask 077; printf '%s\n' "${ISSUE_JSON}" >"${ISSUE_SNAPSHOT_FILE}"); then
    prep_blocked "unable to persist the dependency-fenced Issue snapshot"
    continue
  fi
  chmod 600 "${ISSUE_SNAPSHOT_FILE}" 2>/dev/null \
    || { prep_blocked "Issue snapshot must be private"; continue; }
  set +e
  env "${iid_env[@]}" BRANCH="${IID_BRANCH}" \
    AUTO_MERGE="${IID_AUTO_MERGE}" \
    MERGE_TARGET_BRANCH="${IID_MERGE_TARGET_BRANCH:-${IID_BRANCH}}" \
    ISSUE_JSON_FILE="${ISSUE_SNAPSHOT_FILE}" \
    ISSUE_MODE="${MODE_ACTUAL}" \
    bash "${SCRIPT_DIR}/build_prompt.sh" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1
  BP_RC=$?
  set -e
  retire_temp_file "${ISSUE_SNAPSHOT_FILE}"
  if [ "${BP_RC}" -ne 0 ]; then
    prep_blocked "build_prompt failed (exit ${BP_RC})"
    continue
  fi

  # Init/refresh execution + issue state files.
  WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  LOG_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$LOG_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  OUTPUT_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$OUTPUT_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
  ISSUE_ROOT_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$ISSUE_ROOT"' "${SCRIPT_DIR}/env_paths.sh")"
  EXECUTION_STATE_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$EXECUTION_STATE_FILE"' "${SCRIPT_DIR}/env_paths.sh")"
  ISSUE_STATE_X="${ISSUE_ROOT_X}/state.json"
  NOW="$(utc_now)"
  MODE_DOWNGRADED="null"
  if [ "${ISSUE_MODE}" = "continue" ] && [ "${MODE_ACTUAL}" = "fresh" ]; then
    MODE_DOWNGRADED='"continue"'
  fi
  jq -n \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg started_at "${NOW}" \
    --arg issue_title "${ISSUE_TITLE}" \
    --arg mode_requested "${ISSUE_MODE}" \
    --arg mode_actual "${MODE_ACTUAL}" \
    --argjson mode_downgraded "${MODE_DOWNGRADED}" \
    --arg local_branch "${LOCAL_ISSUE_BRANCH}" \
    --arg config_branch "${IID_CONFIG_BRANCH}" \
    --arg work_branch "${IID_WORK_BRANCH}" \
    --argjson branch_members "${IID_BRANCH_MEMBERS_JSON}" \
    --arg shared_branch_role "${IID_SHARED_BRANCH_ROLE}" \
    --arg expected_work_branch_sha "${IID_EXPECTED_WORK_BRANCH_SHA}" \
    --arg expected_commit_parent_sha "${IID_EXPECTED_COMMIT_PARENT_SHA}" \
    --argjson auto_merge "${IID_AUTO_MERGE}" \
    --arg merge_target_branch "${IID_MERGE_TARGET_BRANCH}" \
    --arg dependency_iid "${IID_DEPENDENCY_IID}" \
    --arg dependency_branch "${IID_DEPENDENCY_BRANCH}" \
    --arg dependency_base_sha "${IID_DEPENDENCY_BASE_SHA}" \
    --arg log_dir "${LOG_DIR_X}" \
    '{iid:$iid, execution_id:$execution_id, execution_started_at:$started_at,
      issue_title:$issue_title,
      mode_requested:$mode_requested, mode_actual:$mode_actual,
      mode_downgraded_from:$mode_downgraded,
      no_reviewer_comments:false,
      config_branch:$config_branch,
      work_branch:$work_branch,
      branch_members:$branch_members,
      shared_branch_role:(if $shared_branch_role == "" then null else $shared_branch_role end),
      expected_work_branch_sha:(if $expected_work_branch_sha == "" then null else $expected_work_branch_sha end),
      expected_commit_parent_sha:(if $expected_commit_parent_sha == "" then null else $expected_commit_parent_sha end),
      auto_merge:$auto_merge,
      merge_target_branch:$merge_target_branch,
      dependency_iid:(if $dependency_iid == "" then null else ($dependency_iid | tonumber) end),
      dependency_branch:(if $dependency_branch == "" then null else $dependency_branch end),
      dependency_base_sha:(if $dependency_base_sha == "" then null else $dependency_base_sha end),
      local_branch:$local_branch, log_dir:$log_dir,
      status:"in_progress"}' | atomic_write_json "${EXECUTION_STATE_X}"
  chmod 600 "${EXECUTION_STATE_X}" 2>/dev/null \
    || { prep_blocked "execution identity must remain private"; continue; }

  PRIOR_ISSUE_STATE_JSON='{}'
  if [ -f "${ISSUE_STATE_X}" ]; then
    if ! PRIOR_ISSUE_STATE_JSON="$(jq -ce \
        'if type == "object" then . else error("invalid issue state") end' \
        "${ISSUE_STATE_X}" 2>/dev/null)"; then
      prep_blocked "persisted Issue state is invalid before executor launch"
      continue
    fi
  fi
  PRIOR_RETRY="$(printf '%s' "${PRIOR_ISSUE_STATE_JSON}" | jq -r '.retry_count // 0')"
  PRIOR_CONTINUE_COUNT="$(printf '%s' "${PRIOR_ISSUE_STATE_JSON}" | jq -r '.continue_count // 0')"
  NEW_CONTINUE_COUNT="${PRIOR_CONTINUE_COUNT}"
  [ "${MODE_ACTUAL}" = "continue" ] && NEW_CONTINUE_COUNT=$(( PRIOR_CONTINUE_COUNT + 1 ))
  PRIOR_MODEL_TIER="$(printf '%s' "${PRIOR_ISSUE_STATE_JSON}" | jq -r '.model_tier // empty')"
  printf '%s' "${PRIOR_ISSUE_STATE_JSON}" | jq \
    --argjson iid "${iid}" \
    --argjson latest_execution_id "${execution_id}" \
    --argjson retry_count "${PRIOR_RETRY}" \
    --argjson continue_count "${NEW_CONTINUE_COUNT}" \
    --arg model_tier "${RESOLVED_MODEL_TIER:-}" \
    --arg prior_model_tier "${PRIOR_MODEL_TIER}" \
    --arg session "issue-${PROJECT}-${iid}" \
    --arg mode "${MODE_ACTUAL}" \
    --arg config_branch "${IID_CONFIG_BRANCH}" \
    --arg work_branch "${IID_WORK_BRANCH}" \
    --argjson branch_members "${IID_BRANCH_MEMBERS_JSON}" \
    --arg shared_branch_role "${IID_SHARED_BRANCH_ROLE}" \
    --arg expected_work_branch_sha "${IID_EXPECTED_WORK_BRANCH_SHA}" \
    --arg expected_commit_parent_sha "${IID_EXPECTED_COMMIT_PARENT_SHA}" \
    --arg dependency_iid "${IID_DEPENDENCY_IID}" \
    --arg dependency_branch "${IID_DEPENDENCY_BRANCH}" \
    --arg dependency_base_sha "${IID_DEPENDENCY_BASE_SHA}" \
    --arg updated_at "${NOW}" \
    'del(.attempts_total,.latest_attempt_number,.preparing_attempt_number,
         .latest_attempt_dir,.prior_attempt_count)
    | . + {iid:$iid, session:$session, status:"in_progress", mode:$mode,
      proposed_config_branch:$config_branch,
      proposed_work_branch:$work_branch,
      proposed_branch_members:$branch_members,
      proposed_shared_branch_role:(if $shared_branch_role == "" then null else $shared_branch_role end),
      proposed_expected_work_branch_sha:(if $expected_work_branch_sha == "" then null else $expected_work_branch_sha end),
      proposed_expected_commit_parent_sha:(if $expected_commit_parent_sha == "" then null else $expected_commit_parent_sha end),
      proposed_dependency_iid:(if $dependency_iid == "" then null else ($dependency_iid | tonumber) end),
      proposed_dependency_branch:(if $dependency_branch == "" then null else $dependency_branch end),
      proposed_dependency_base_sha:(if $dependency_base_sha == "" then null else $dependency_base_sha end),
      preparing_execution_id:$latest_execution_id,
      continue_count:$continue_count,
      model_tier:(if $model_tier == "" then (if $prior_model_tier == "" then null else $prior_model_tier end) else $model_tier end),
      latest_execution_id:$latest_execution_id, retry_count:$retry_count,
      block_reason:null, commit_sha:null, merge_request_url:null,
      updated_at:$updated_at}' | atomic_write_json "${ISSUE_STATE_X}"

  # Render the full executor workflow to a private local file. sessions_spawn
  # receives only the small secret-free bootstrap written to its execution-scoped file;
  # the child verifies the manifest and full payload before reading either as
  # instructions. This removes the large model-copied task from the runtime
  # boundary and gives every launch a stable byte/hash identity.
  executor_payload_path="${LOG_DIR_X}/executor_payload-${execution_id}.txt"
  manifest_path="${LOG_DIR_X}/spawn_manifest-${execution_id}.json"
  payload_path="${LOG_DIR_X}/spawn_payload-${execution_id}.txt"
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
  WORK_BRANCH_X="${IID_WORK_BRANCH}"

  RENDER_ERR="$(mktemp)"
  CLEANUP_FILES+=("${RENDER_ERR}")
  set +e
  rendered="$(TPL_PROJECT="${PROJECT}" \
              TPL_GROUP="${GROUP}" \
              TPL_GITLAB_HOST="${GITLAB_HOST}" \
              TPL_GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
              TPL_ISSUE_IID="${iid}" \
              TPL_EXECUTION_ID="${execution_id}" \
              TPL_ISSUE_MODE="${MODE_ACTUAL}" \
              TPL_BRANCH="${IID_BRANCH}" \
              TPL_BRANCH_QUOTED="${IID_BRANCH_QUOTED}" \
              TPL_CONFIG_BRANCH="${IID_CONFIG_BRANCH}" \
              TPL_DEPENDENCY_IID="${IID_DEPENDENCY_IID}" \
              TPL_DEPENDENCY_BRANCH="${IID_DEPENDENCY_BRANCH}" \
              TPL_DEPENDENCY_BASE_SHA="${IID_DEPENDENCY_BASE_SHA}" \
              TPL_AUTO_MERGE="${IID_AUTO_MERGE}" \
              TPL_MERGE_TARGET_BRANCH="${IID_MERGE_TARGET_BRANCH}" \
              TPL_MERGE_TARGET_BRANCH_QUOTED="${IID_MERGE_TARGET_BRANCH_QUOTED}" \
              TPL_WORK_BRANCH="${WORK_BRANCH_X}" \
              TPL_WORK_BRANCH_QUOTED="${IID_WORK_BRANCH_QUOTED}" \
              TPL_EXPECTED_WORK_BRANCH_SHA="${IID_EXPECTED_WORK_BRANCH_SHA}" \
              TPL_EXPECTED_COMMIT_PARENT_SHA="${IID_EXPECTED_COMMIT_PARENT_SHA}" \
              TPL_LOCAL_ISSUE_BRANCH="${LOCAL_ISSUE_BRANCH}" \
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
    --argjson execution_id "${execution_id}" \
    --arg executor_payload_path "${executor_payload_path}" \
    --arg executor_payload_sha256 "${executor_payload_sha256}" \
    --argjson executor_payload_bytes "${executor_payload_bytes}" '{
      version:1,
      project:$project,
      job_id:(if $job_id == "" then null else $job_id end),
      iid:$iid,
      execution_id:$execution_id,
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
    --argjson execution_id "${execution_id}" '{
      project:$project,
      job_id:(if $job_id == "" then null else $job_id end),
      iid:$iid,
      execution_id:$execution_id
    }')"
  bootstrap="$(cat <<EOF
# REQ_EXECUTOR_SPAWN_BOOTSTRAP_V1
This is a secret-free bootstrap for one req_executor child. Do not search for other tasks and do not echo file contents.
identity=${bootstrap_identity}
manifest_path=${manifest_path}
manifest_sha256=${manifest_sha256}
manifest_bytes=${manifest_bytes}

Before doing any issue work, use one Bash call to verify that manifest_path is a regular file with mode 600, exact byte count and SHA-256 above. For both files, define and use exactly this portable helper inside that Bash call: mode_of() { local mode; if mode="\$(stat -f '%Lp' "\$1" 2>/dev/null)"; then printf '%s\n' "\$mode"; else stat -c '%a' "\$1"; fi; }; require its output to equal the literal string 600. Then parse the manifest with jq; require version=1 and require the manifest's top-level project, job_id, iid, and execution_id fields (there is no nested identity object) to equal the exact identity above. Verify its executor_payload_path is a regular mode-600 file with the exact executor_payload_bytes and executor_payload_sha256 recorded in the manifest. If any check fails, stop and return one compact JSON object with status="blocked", iid=${iid}, execution_id=${execution_id}, and block_reason="spawn bootstrap verification failed".

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
      --argjson execution_id "${execution_id}" \
      --arg clabel "${child_label}" \
      --arg path "${payload_path}" \
      --arg expected_task_sha256 "${expected_task_sha256}" \
      --argjson expected_task_bytes "${expected_task_bytes}" \
      --argjson grant "${IID_GRANT_JSON}" '
      . + [{
        iid:$iid,
        execution_id:$execution_id,
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
      --argjson execution_id "${execution_id}" \
      --arg clabel "${child_label}" \
      --arg path "${payload_path}" \
      --arg expected_task_sha256 "${expected_task_sha256}" \
      --argjson expected_task_bytes "${expected_task_bytes}" '
      . + [{
        iid:$iid,
        execution_id:$execution_id,
        child_label:$clabel,
        payload_path:$path,
        expected_task_sha256:$expected_task_sha256,
        expected_task_bytes:$expected_task_bytes
      }]')"
  fi

  wrapper_log prepare_tick "prepared iid=${iid} execution_id=${execution_id} payload=${payload_path}"
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
      --argjson dependency_waiting "${DEPENDENCY_WAITING_JSON}" \
      --argjson deferred_entries "${DEFERRED_ENTRIES_JSON}" \
      --arg ev "${EVIDENCE_PATH}" \
      --arg chat "all batch IIDs blocked during prep — see tick_outcome_per_iid" '
      {status:"no_eligible_iids", dispatch_entries:[], pending_iids:$pending_iids,
       skipped_entries:$skipped_entries,
       dependency_waiting:$dependency_waiting,
       deferred_entries:$deferred_entries,
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
      --argjson dependency_waiting "${DEPENDENCY_WAITING_JSON}" \
      --arg ev "${EVIDENCE_PATH}" \
      --arg chat "all batch IIDs blocked during prep — see tick_outcome_per_iid" '
      {status:"no_eligible_iids", dispatch_entries:[],
       dependency_waiting:$dependency_waiting,
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
    --argjson dependency_waiting "${DEPENDENCY_WAITING_JSON}" \
    --argjson deferred_entries "${DEFERRED_ENTRIES_JSON}" \
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
     dependency_waiting:$dependency_waiting,
     deferred_entries:$deferred_entries,
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
    --argjson dependency_waiting "${DEPENDENCY_WAITING_JSON}" \
    --argjson label_in "${LABEL_FILTERED_IN_JSON}" \
    --argjson label_out "${LABEL_FILTERED_OUT_JSON}" \
    --arg ev "${EVIDENCE_PATH}" \
    --arg chat "${SUMMARY}" '
    {status:"ready", dispatch_entries:$dispatch_entries,
     dependency_waiting:$dependency_waiting,
     max_launch_retries:3, backoff_seconds:2,
     evicted_iids:$evicted, scope_evicted_iids:$scope_evicted,
     cleanup_actions:$cleanup_actions,
     label_filtered_in:$label_in, label_filtered_out:$label_out,
     tick_outcome_per_iid:$outcomes, last_reconcile_evidence:$ev,
     chat_summary:$chat}'
fi
