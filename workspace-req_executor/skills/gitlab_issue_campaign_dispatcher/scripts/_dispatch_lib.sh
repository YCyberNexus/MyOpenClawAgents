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
#   phase6_build_driven_handoff_intent <pending_json> <iid> <attempt> <status>
#                                          <mr_url> <reason>
#                                → emits a canonical claim-bound durable intent
#   phase6_canonicalize_driven_handoff_intent <intent_json>
#                                → validates and canonicalizes an existing intent
#   phase6_put_driven_handoff_intent <state_json> <intent_json>
#                                → idempotently adds the intent to campaign state
#   phase6_find_driven_handoff_intent <state_json> <iid> <attempt>
#                                → emits the one matching intent or null
#   phase6_write_driven_handoff_intent <intent_json>
#                                → atomically materializes its project-local
#                                  scheduler handoff and prints the path
#   phase6_write_driven_handoff <pending_json> <iid> <status> <mr_url> <reason>
#                                → compatibility wrapper that builds and writes
#                                  a handoff without storing an intent
#   iso_to_epoch <iso8601>       → epoch seconds (0 when unparseable)
#   completion_extract_unique_worker_reply <final_assistant_text>
#                                → extract the sole strict compact worker JSON
#   completion_authenticate_pending <pending_json> <attempt> <run_id>
#                                      <child_session_key> <label>
#                                → print native_v1|legacy after exact identity check
#   phase6_synthesize_reply <iid> <execution_id> <status> <block_reason>
#                                → emit a synthetic compact reply JSON (status=blocked|timeout)
#   phase6_synthesize_blocked <iid> <execution_id> <block_reason>
#                                → phase6_synthesize_reply with status=blocked
#   phase6_synthesize_timeout <iid> <execution_id> <block_reason>
#                                → phase6_synthesize_reply with status=timeout
#   phase6_normalize_reply <reply_json> <ctx_iid> <ctx_attempt> [synth_status]
#                                → validated + normalized reply JSON; synth_status
#                                  (default blocked) is used when the raw reply is
#                                  unparseable or carries no status field
#   phase6_sync_labels <iid> <final_status> [block_side] [completion_label]
#                                → run set_issue_label.sh ops; echo any append-on-failure text
#   phase6_write_state_files <iid> <execution_id> <reply_json> <final_status>
#                                                  <prior_state_json> <prior_retry_count>
#                                                  <is_launch_synth>
#                                → writes EXECUTION_STATE_FILE + ISSUE_STATE_FILE atomically;
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

# Return the first line without creating a producer/consumer pipe. Long prompt
# payloads can make `printf ... | head -n 1` terminate the producer with
# SIGPIPE; under `set -o pipefail` that aborts the dispatcher with exit 141.
first_line() {
  local text="${1-}"
  printf '%s\n' "${text%%$'\n'*}"
}

# Parse an ISO-8601 UTC timestamp into epoch seconds. Echoes 0 when the
# input is empty / null / unparseable so callers can branch on `-gt 0`.
iso_to_epoch() {
  local ts="$1" epoch
  if [ -z "${ts}" ] || [ "${ts}" = "null" ]; then
    printf '%s\n' 0
    return 0
  fi
  if epoch="$(date -u -d "${ts}" +%s 2>/dev/null)" \
      && [[ "${epoch}" =~ ^-?[0-9]+$ ]]; then
    printf '%s\n' "${epoch}"
  elif epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${ts}" +%s 2>/dev/null)" \
      && [[ "${epoch}" =~ ^-?[0-9]+$ ]]; then
    printf '%s\n' "${epoch}"
  elif command -v gdate >/dev/null 2>&1 \
      && epoch="$(gdate -u -d "${ts}" +%s 2>/dev/null)" \
      && [[ "${epoch}" =~ ^-?[0-9]+$ ]]; then
    printf '%s\n' "${epoch}"
  else
    printf '%s\n' 0
  fi
}

atomic_write_json() {
  local target="$1"
  local tmp
  (
    umask 077
    tmp="$(mktemp "${target}.tmp.XXXXXX")"
    cat >"${tmp}"
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${target}"
    # Re-apply the private mode to the published path. The temporary file is
    # already mode 600, but this makes the destination contract explicit for
    # deployment filesystems or copy layers that do not preserve rename modes.
    chmod 600 "${target}"
  )
}

wrapper_log() {
  local phase="$1"; shift
  local ts="$(utc_now)"
  mkdir -p "${DISPATCHER_LOG_DIR}"
  printf '[%s] [%s] %s\n' "${ts}" "${phase}" "$*" >>"${DISPATCHER_LOG_DIR}/wrapper.log"
}

# Extract exactly one current compact worker reply from the final assistant
# text.  The worker contract requires a one-line object, so parsing candidate
# lines avoids treating arbitrary prose, nested examples, or tool payloads as
# a completion.  Two valid lines are ambiguous even when byte-identical.
# Returns 4 when no strict worker object exists and 5 when more than one exists,
# allowing the authenticated native-completion path to recover only the former
# without weakening the fail-closed ambiguous-result rule.
completion_extract_unique_worker_reply() {
  local final_text="$1" candidates count

  if ! candidates="$(printf '%s' "${final_text}" | jq -Rsc '
    def is_worker_reply:
      type == "object"
      and (keys | sort) == ([
        "execution_id", "block_reason", "commit_sha", "iid",
        "labels_added", "labels_removed", "local_branch", "log_dir",
        "merge_request_url", "mode_actual", "mr_action", "status",
        "summary_posted", "wiki_url", "work_branch"
      ] | sort)
      and (.iid | type == "number" and . == floor and . > 0)
      and (.execution_id | type == "number" and . == floor and . > 0)
      and (.status as $status
        | ($status | type) == "string"
          and (["done","no_changes","blocked","failed","timeout"]
            | index($status) != null))
      and (.mode_actual | type == "string")
      and (.work_branch | type == "string")
      and (.local_branch | type == "string")
      and (.commit_sha | type == "string")
      and (.merge_request_url | type == "string")
      and (.mr_action as $mr_action
        | ($mr_action | type) == "string"
          and (["created","rotated","reused","none"] | index($mr_action) != null))
      and (.wiki_url | type == "string")
      and (.labels_added | type == "array" and all(.[]; type == "string"))
      and (.labels_removed | type == "array" and all(.[]; type == "string"))
      and (.summary_posted | type == "boolean")
      and (.block_reason | type == "string")
      and (.log_dir | type == "string")
      and (if .status == "blocked" or .status == "failed" or .status == "timeout"
        then (.block_reason | length) > 0
        else true
        end);

    [
      split("\n")[]
      | sub("\r$"; "")
      | gsub("^\\s+|\\s+$"; "")
      | select(length > 0)
      | (try fromjson catch null)
      | select(is_worker_reply)
    ]
  ')"; then
    echo "completion: unable to scan final assistant text" >&2
    return 3
  fi

  count="$(jq -r 'length' <<<"${candidates}")"
  if [ "${count}" -eq 0 ]; then
    # Zero strict objects is recoverable only for prose/no-result terminals.
    # A malformed, pretty-printed, or wrong-identity JSON object must remain a
    # hard rejection; otherwise it could be mistaken for an absent result and
    # borrow the durable route's IID/execution identity.
    if printf '%s' "${final_text}" | jq -Rse '
        def trim: gsub("^\\s+|\\s+$"; "");
        . as $raw
        | ($raw | trim) as $whole
        | ([$raw | split("\n")[] | sub("\r$"; "") | trim]) as $lines
        | (((try ($whole | fromjson) catch null) | type) == "object")
          or ($lines | any(.[];
            (((try fromjson catch null) | type) == "object")
            or startswith("{") or endswith("}")))
      ' >/dev/null 2>&1; then
      echo "completion: final assistant text has invalid or non-canonical JSON-shaped worker output" >&2
      return 3
    fi
    echo "completion: final assistant text has no strict compact worker JSON" >&2
    return 4
  fi
  if [ "${count}" -ne 1 ]; then
    echo "completion: final assistant text has ambiguous compact worker JSON" >&2
    return 5
  fi
  jq -c '.[0]' <<<"${candidates}"
}

# Authenticate a callback against the pending entry while dispatch_followup
# holds the campaign lock.  Existing/current entries are strict by default and
# require the exact runtime ack identity.  A rolling-upgrade entry may opt into
# the old callback surface only through the explicit marker
# `completion_auth:"legacy"`; absence of identity is never inferred as legacy.
completion_authenticate_pending() {
  local pending_json="$1" callback_attempt="$2" callback_run_id="$3"
  local callback_child_session_key="$4" callback_label="$5" auth_mode

  if ! auth_mode="$(jq -er '
    if type != "object" then error("pending is not an object")
    elif (.completion_auth // "native_v1") == "native_v1" then "native_v1"
    elif .completion_auth == "legacy" then "legacy"
    else error("unknown completion_auth")
    end
  ' <<<"${pending_json}" 2>/dev/null)"; then
    echo "completion: pending completion authentication mode is invalid" >&2
    return 3
  fi

  case "${callback_run_id}${callback_child_session_key}${callback_label}" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "completion: callback identity contains control characters" >&2
      return 3
      ;;
  esac

  if [ "${auth_mode}" = "native_v1" ]; then
    if ! [[ "${callback_attempt}" =~ ^[1-9][0-9]*$ ]] \
        || [ -z "${callback_run_id}" ] \
        || [ -z "${callback_child_session_key}" ]; then
      echo "completion: strict callback identity is incomplete" >&2
      return 3
    fi
    if ! jq -e \
        --argjson callback_attempt "${callback_attempt}" \
        --arg callback_run_id "${callback_run_id}" \
        --arg callback_child_session_key "${callback_child_session_key}" \
        --arg callback_label "${callback_label}" '
      (.execution_id | type == "number" and . == floor and . > 0)
      and (.run_id | type == "string" and length > 0)
      and (.child_session_key | type == "string" and length > 0)
      and .execution_id == $callback_attempt
      and .run_id == $callback_run_id
      and .child_session_key == $callback_child_session_key
      and ((.child_label // .label // "") as $expected_label
        | $expected_label == ""
          or ($callback_label != "" and $callback_label == $expected_label))
    ' <<<"${pending_json}" >/dev/null; then
      echo "completion: callback identity does not match pending state" >&2
      return 3
    fi
    printf '%s\n' native_v1
    return 0
  fi

  # Explicit legacy mode accepts omitted runtime identity, but rejects any
  # supplied field that conflicts with durable pending evidence.
  if [ -n "${callback_attempt}" ] && ! [[ "${callback_attempt}" =~ ^[1-9][0-9]*$ ]]; then
    echo "completion: legacy callback attempt is invalid" >&2
    return 3
  fi
  if ! jq -e \
      --arg callback_attempt "${callback_attempt}" \
      --arg callback_run_id "${callback_run_id}" \
      --arg callback_child_session_key "${callback_child_session_key}" \
      --arg callback_label "${callback_label}" '
    .completion_auth == "legacy"
    and (.execution_id | type == "number" and . == floor and . > 0)
    and ($callback_attempt == ""
      or (.execution_id | tostring) == $callback_attempt)
    and ($callback_run_id == ""
      or ((.run_id // "") == "" or .run_id == $callback_run_id))
    and ($callback_child_session_key == ""
      or ((.child_session_key // "") == ""
        or .child_session_key == $callback_child_session_key))
    and ($callback_label == ""
      or ((.child_label // .label // "") == ""
        or (.child_label // .label) == $callback_label))
  ' <<<"${pending_json}" >/dev/null; then
    echo "completion: legacy callback conflicts with pending state" >&2
    return 3
  fi
  printf '%s\n' legacy
}

# Build the project-local half of a scheduler-driven terminal callback without
# writing it. The pending entry intentionally contributes only job/claim
# identity and the dynamic-membership marker: membership fanout is resolved
# later by import_driven_handoff.sh under the scheduler lock.
phase6_build_driven_handoff_json() {
  local pending_json="$1" iid="$2" final_status="$3" mr_url="$4" reason="$5"
  local job_id claim_generation claim_token_json event_id
  local handoff_json

  case "${final_status}" in
    done|failed|timeout|skipped) ;;
    *)
      echo "phase6_write_driven_handoff: non-terminal status: ${final_status}" >&2
      return 2
      ;;
  esac
  case "${iid}" in
    ''|*[!0-9]*)
      echo "phase6_write_driven_handoff: invalid iid: ${iid}" >&2
      return 2
      ;;
  esac

  if ! job_id="$(printf '%s' "${pending_json}" | jq -er '
    if type == "object"
      and .memberships_source == "scheduler_active_job"
      and (.job_id | type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"))
      and (.batch_id | type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and (.snapshot_index | type == "number" and . == floor and . >= 0)
      and ((if has("claim_generation") then .claim_generation else 0 end) as $generation
        | (if has("claim_token") then .claim_token else null end) as $token
        | ($generation | type == "number" and . == floor and . >= 0)
          and (($token == null)
            or ($token | type == "string" and length > 0))
          and (if $generation == 0
            then $token == null
            else ($token | type == "string" and length > 0)
            end))
    then .job_id
    else error("invalid scheduler-driven pending metadata")
    end
  ')"; then
    echo "phase6_write_driven_handoff: invalid scheduler-driven pending metadata" >&2
    return 3
  fi

  claim_generation="$(jq -r '
    if has("claim_generation") then .claim_generation else 0 end
  ' <<<"${pending_json}")"
  claim_token_json="$(jq -c '
    if has("claim_token") then .claim_token else null end
  ' <<<"${pending_json}")"
  event_id="${job_id}:claim-${claim_generation}:terminal-1"
  handoff_json="$(jq -cnS \
    --arg event_id "${event_id}" \
    --arg job_id "${job_id}" \
    --argjson claim_generation "${claim_generation}" \
    --argjson claim_token "${claim_token_json}" \
    --arg project "${PROJECT_FULL}" \
    --argjson iid "${iid}" \
    --arg status "${final_status}" \
    --arg mr_url "${mr_url}" \
    --arg reason "${reason}" '{
      version:1,
      event_id:$event_id,
      job_id:$job_id,
      memberships:[],
      memberships_source:"scheduler_active_job",
      claim_generation:$claim_generation,
      claim_token:$claim_token,
      project:$project,
      iid:$iid,
      status:$status,
      mr_url:(if $mr_url == "" then null else $mr_url end),
      reason:(if $reason == "" then null else $reason end)
    }')"

  printf '%s\n' "${handoff_json}"
}

# Strictly canonicalize a handoff before it is persisted or recovered from a
# durable intent. Requiring memberships=[] keeps scheduler membership snapshots
# out of the project lock/domain; the importer alone freezes that snapshot.
phase6_canonicalize_driven_handoff_json() {
  local handoff_json="$1"
  printf '%s' "${handoff_json}" | jq -ceS --arg project "${PROJECT_FULL}" '
    if type == "object"
      and (keys | sort) == [
        "claim_generation",
        "claim_token",
        "event_id",
        "iid",
        "job_id",
        "memberships",
        "memberships_source",
        "mr_url",
        "project",
        "reason",
        "status",
        "version"
      ]
      and .version == 1
      and (.job_id | type == "string"
        and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"))
      and (.claim_generation | type == "number"
        and . == floor and . >= 0)
      and (if .claim_generation == 0
        then .claim_token == null
        else (.claim_token | type == "string" and length > 0)
        end)
      and .event_id == (.job_id + ":claim-"
        + (.claim_generation | tostring) + ":terminal-1")
      and .memberships == []
      and .memberships_source == "scheduler_active_job"
      and .project == $project
      and (.iid | type == "number" and . == floor and . > 0)
      and ((.status == "done") or (.status == "failed")
        or (.status == "timeout") or (.status == "skipped"))
      and (.mr_url == null
        or (.mr_url | type == "string" and length > 0))
      and (.reason == null
        or (.reason | type == "string" and length > 0))
    then .
    else error("invalid canonical scheduler-driven handoff")
    end
  '
}

# Materialization is idempotent and safe outside the campaign lock because the
# canonical intent has already been committed with project state. Concurrent
# drainers can only publish byte-equivalent JSON for the same stable event.
phase6_write_driven_handoff_json() {
  local handoff_json="$1"
  local canonical_handoff iid event_id
  local handoff_dir handoff_file existing_json

  canonical_handoff="$(phase6_canonicalize_driven_handoff_json "${handoff_json}")" || {
    echo "phase6_write_driven_handoff_json: invalid handoff" >&2
    return 3
  }
  iid="$(jq -r '.iid' <<<"${canonical_handoff}")"
  event_id="$(jq -r '.event_id' <<<"${canonical_handoff}")"
  handoff_dir="${ISSUES_ROOT}/issue-${iid}/driven_handoffs"
  handoff_file="${handoff_dir}/${event_id}.json"
  mkdir -p "${handoff_dir}"

  if [ -f "${handoff_file}" ]; then
    existing_json="$(phase6_canonicalize_driven_handoff_json \
      "$(cat "${handoff_file}")" 2>/dev/null)" || {
      echo "phase6_write_driven_handoff_json: existing handoff is invalid: ${handoff_file}" >&2
      return 3
    }
    if [ "${existing_json}" != "${canonical_handoff}" ]; then
      echo "phase6_write_driven_handoff_json: stable event conflicts with existing handoff: ${event_id}" >&2
      return 3
    fi
  else
    printf '%s' "${canonical_handoff}" | atomic_write_json "${handoff_file}"
  fi
  printf '%s\n' "${handoff_file}"
}

phase6_build_driven_handoff_intent() {
  local pending_json="$1" iid="$2" execution_id="$3"
  local final_status="$4" mr_url="$5" reason="$6"
  local handoff_json

  case "${execution_id}" in
    ''|*[!0-9]*|0)
      echo "phase6_build_driven_handoff_intent: invalid execution_id: ${execution_id}" >&2
      return 2
      ;;
  esac
  handoff_json="$(phase6_build_driven_handoff_json \
    "${pending_json}" "${iid}" "${final_status}" "${mr_url}" "${reason}")" \
    || return $?
  handoff_json="$(phase6_canonicalize_driven_handoff_json "${handoff_json}")" \
    || return $?
  jq -cnS \
    --argjson execution_id "${execution_id}" \
    --argjson handoff "${handoff_json}" '{
      version:1,
      execution_id:$execution_id,
      handoff:$handoff
    }'
}

phase6_canonicalize_driven_handoff_intent() {
  local intent_json="$1"
  local normalized_intent canonical_handoff execution_id

  normalized_intent="$(printf '%s' "${intent_json}" | jq -ceS '
    if type == "object"
      and (keys | sort) == ["execution_id","handoff","version"]
      and .version == 1
      and (.execution_id | type == "number"
        and . == floor and . > 0)
      and (.handoff | type == "object")
    then .
    else error("invalid scheduler-driven handoff intent")
    end
  ')" || return 3
  execution_id="$(jq -r '.execution_id' <<<"${normalized_intent}")"
  canonical_handoff="$(phase6_canonicalize_driven_handoff_json \
    "$(jq -c '.handoff' <<<"${normalized_intent}")")" || return 3
  jq -cnS \
    --argjson execution_id "${execution_id}" \
    --argjson handoff "${canonical_handoff}" '{
      version:1,
      execution_id:$execution_id,
      handoff:$handoff
    }'
}

phase6_put_driven_handoff_intent() {
  local state_json="$1" intent_json="$2"
  local canonical_intent event_id

  canonical_intent="$(phase6_canonicalize_driven_handoff_intent \
    "${intent_json}")" || return 3
  event_id="$(jq -r '.handoff.event_id' <<<"${canonical_intent}")"
  printf '%s' "${state_json}" | jq -ce \
    --arg event_id "${event_id}" \
    --argjson intent "${canonical_intent}" '
    if has("driven_handoff_intents")
        and (.driven_handoff_intents | type != "object")
    then error("driven_handoff_intents must be an object")
    elif ((.driven_handoff_intents // {})[$event_id] // null) as $existing
      | $existing != null and $existing != $intent
    then error("stable event conflicts with existing durable intent")
    else .driven_handoff_intents =
      ((.driven_handoff_intents // {}) + {($event_id):$intent})
    end
  '
}

phase6_find_driven_handoff_intent() {
  local state_json="$1" iid="$2" execution_id="$3"
  local matches match_count entry_key canonical_intent

  matches="$(printf '%s' "${state_json}" | jq -ce \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" '
    if has("driven_handoff_intents")
        and (.driven_handoff_intents | type != "object")
    then error("driven_handoff_intents must be an object")
    else [(.driven_handoff_intents // {}) | to_entries[]
      | select(
          (.value | type == "object")
          and .value.execution_id == $execution_id
          and (.value.handoff | type == "object")
          and .value.handoff.iid == $iid
        )]
    end
  ')" || return 3
  match_count="$(jq -r 'length' <<<"${matches}")"
  if [ "${match_count}" -eq 0 ]; then
    printf '%s\n' null
    return 0
  fi
  if [ "${match_count}" -ne 1 ]; then
    echo "phase6_find_driven_handoff_intent: multiple intents match iid=${iid} execution_id=${execution_id}" >&2
    return 3
  fi
  entry_key="$(jq -r '.[0].key' <<<"${matches}")"
  canonical_intent="$(phase6_canonicalize_driven_handoff_intent \
    "$(jq -c '.[0].value' <<<"${matches}")")" || return 3
  if [ "$(jq -r '.handoff.event_id' <<<"${canonical_intent}")" != "${entry_key}" ]; then
    echo "phase6_find_driven_handoff_intent: intent key does not match stable event" >&2
    return 3
  fi
  printf '%s\n' "${canonical_intent}"
}

phase6_write_driven_handoff_intent() {
  local canonical_intent
  canonical_intent="$(phase6_canonicalize_driven_handoff_intent "$1")" \
    || return 3
  phase6_write_driven_handoff_json \
    "$(jq -c '.handoff' <<<"${canonical_intent}")"
}

phase6_write_driven_handoff() {
  local handoff_json
  handoff_json="$(phase6_build_driven_handoff_json "$@")" || return $?
  phase6_write_driven_handoff_json "${handoff_json}"
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

migrate_legacy_execution_state_locked() {
  # Caller contract: campaign.lock is already held exclusively. The ordinary
  # state reader is also used by the unlocked completion-ingest lookup, so all
  # durable migration belongs here rather than in load_state.
  local marker="${CAMPAIGN_STATE_FILE}.execution-identity-v2-migrated"
  local state_json migrated_state legacy_counter_file legacy_issue_state_file
  local marker_complete=false

  if [ -L "${marker}" ]; then
    wrapper_log state_migration "execution identity migration marker is a symlink"
    return 1
  fi
  if [ -e "${marker}" ]; then
    if [ ! -f "${marker}" ]; then
      wrapper_log state_migration "execution identity migration marker is invalid"
      return 1
    fi
    if jq -e '
        (keys | sort) == ["completed","requires_quiescent_lock","version"]
        and .version == 2 and .completed == true
        and .requires_quiescent_lock == true
      ' "${marker}" >/dev/null 2>&1; then
      marker_complete=true
    elif ! jq -e '
        (keys | sort) == ["completed","version"]
        and .version == 1 and .completed == true
      ' "${marker}" >/dev/null 2>&1; then
      wrapper_log state_migration "execution identity migration marker is invalid"
      return 1
    fi
  fi

  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    state_json="$(jq -c '.' "${CAMPAIGN_STATE_FILE}")" || return 1
  else
    state_json="$(fresh_init_state)" || return 1
  fi

  # Never turn a small legacy sequence number into a supposedly opaque ID.
  # The old release must drain these active records before the new release is
  # admitted. This also preserves the exact callback identity fence.
  if jq -e '
      def legacy_key:
        . == "attempt_number"
        or . == "finish_label_retry_attempt"
        or . == "mr_label_retry_attempt"
        or . == "mr_finalization_retry_attempt";
      [(.pending_subagents // {}), (.driven_handoff_intents // {})]
      | any(.. | objects; any(keys[]; legacy_key))
    ' <<<"${state_json}" >/dev/null; then
    wrapper_log state_migration \
      "legacy active execution records must drain before upgrade"
    return 2
  fi

  # Version 1 was emitted by the former unlocked reader and is therefore not
  # proof of a quiescent, locked sweep. Only the version-2 marker may bypass it.
  [ "${marker_complete}" = false ] || return 0

  # A current execution can still be writing its per-Issue state without the
  # campaign lock. Defer the one-time sweep until the project is fully quiet.
  if jq -e '
      ((.pending_subagents // {}) | length) > 0
      or ((.driven_handoff_intents // {}) | length) > 0
    ' <<<"${state_json}" >/dev/null; then
    return 0
  fi

  # Preflight every path before the first write so an unsafe filesystem entry
  # cannot leave a falsely completed marker behind.
  for legacy_counter_file in "${ISSUES_ROOT}"/issue-*/attempt_state.json; do
    [ -e "${legacy_counter_file}" ] || continue
    if [ -L "${legacy_counter_file}" ] || [ ! -f "${legacy_counter_file}" ]; then
      wrapper_log state_migration \
        "legacy execution counter path is not a regular file: ${legacy_counter_file}"
      return 1
    fi
  done
  for legacy_issue_state_file in "${ISSUES_ROOT}"/issue-*/state.json; do
    [ -e "${legacy_issue_state_file}" ] || continue
    if [ -L "${legacy_issue_state_file}" ] || [ ! -f "${legacy_issue_state_file}" ]; then
      wrapper_log state_migration \
        "legacy Issue state path is not a regular file: ${legacy_issue_state_file}"
      return 1
    fi
    jq -e 'type == "object"' "${legacy_issue_state_file}" >/dev/null 2>&1 \
      || return 1
  done

  # Remove only the retired Issue-execution metadata. Transport retry evidence
  # such as launch_attempts is a separate bounded runtime acknowledgement.
  migrated_state="$(jq -c '
    def legacy_key:
      . == "attempt_number"
      or . == "attempt_started_at"
      or . == "attempt_finished_at"
      or . == "attempts_total"
      or . == "latest_attempt_number"
      or . == "preparing_attempt_number"
      or . == "latest_attempt_dir"
      or . == "prior_attempt_count"
      or . == "dependency_pinned_attempt_number"
      or . == "source_attempt_number"
      or . == "finish_label_retry_attempt"
      or . == "mr_label_retry_attempt"
      or . == "mr_finalization_retry_attempt";
    def scrub_legacy:
      if type == "object" then
        with_entries(select((.key | legacy_key) | not) | .value |= scrub_legacy)
      elif type == "array" then map(scrub_legacy)
      else . end;
    del(.run_timeout_seconds) | scrub_legacy
  ' <<<"${state_json}")" || return 1

  for legacy_counter_file in "${ISSUES_ROOT}"/issue-*/attempt_state.json; do
    [ -e "${legacy_counter_file}" ] || continue
    jq -nc '{version:1,deprecated:true,replacement:"execution-scoped-state"}' \
      | atomic_write_json "${legacy_counter_file}" || return 1
  done
  for legacy_issue_state_file in "${ISSUES_ROOT}"/issue-*/state.json; do
    [ -e "${legacy_issue_state_file}" ] || continue
    jq '
      del(.attempt_number,.attempt_started_at,.attempt_finished_at,
          .attempts_total,.latest_attempt_number,.preparing_attempt_number,
          .latest_attempt_dir,.prior_attempt_count,
          .dependency_pinned_attempt_number,.source_attempt_number,
          .finish_label_retry_attempt,.mr_label_retry_attempt,
          .mr_finalization_retry_attempt)
    ' "${legacy_issue_state_file}" \
      | atomic_write_json "${legacy_issue_state_file}" || return 1
  done
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    printf '%s\n' "${migrated_state}" \
      | atomic_write_json "${CAMPAIGN_STATE_FILE}" || return 1
  fi
  jq -nc '{version:2,completed:true,requires_quiescent_lock:true}' \
    | atomic_write_json "${marker}"
}

load_state() {
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    # Pure read/normalization only: this path is intentionally safe for the
    # unlocked completion-ingest identity lookup.
    jq 'del(.run_timeout_seconds)' "${CAMPAIGN_STATE_FILE}"
  else
    fresh_init_state
  fi
}

derive_stuck_after_minutes() {
  local acpx_timeout_seconds="$1"
  printf '%s\n' "$(( (acpx_timeout_seconds + 2400 + 59) / 60 + 30 ))"
}

# Decide whether a project campaign owner may enter while the caller holds the
# campaign flock. This helper is deliberately pure. Normal rejected transitions
# leave state byte-stable, but legacy state with pending work and no owner sets
# `migration_required=true` and returns a durable scheduled owner even when the
# requested owner is busy/rejected. The caller persists `updated_state` after an
# allowed transition or that explicit migration; the helper never writes it.
dispatch_owner_transition() {
  local state_json="$1" mode="$2" owner_id="$3" leased_at="$4"
  printf '%s' "${state_json}" | jq -c \
    --arg mode "${mode}" \
    --arg owner_id "${owner_id}" \
    --arg leased_at "${leased_at}" '
    . as $state
    | (($state.pending_subagents // {}) | length) as $pending_count
    | ($state.dispatch_owner // null) as $persisted_current
    | (($persisted_current | type) == "object"
       and (($persisted_current.mode == "driven") or ($persisted_current.mode == "scheduled"))
       and (($persisted_current.owner_id | type) == "string")
       and (($persisted_current.owner_id | length) > 0)) as $has_current
    | ($pending_count > 0 and ($has_current | not)) as $migration_required
    | (if $migration_required then
         {mode:"scheduled",owner_id:"scheduled",leased_at:$leased_at}
       else $persisted_current end) as $current
    | ($pending_count > 0
       and ($has_current or $migration_required)
       and (($current.mode != $mode) or ($current.owner_id != $owner_id))) as $busy
    | {
        allowed: ($busy | not),
        migration_required: $migration_required,
        status: (if $busy then ("busy_owned_by_" + $current.mode) else "acquired" end),
        updated_state: (if $busy then
          (if $migration_required then
             ($state | .dispatch_owner = $current)
           else $state end)
        else
          ($state | .dispatch_owner = {
            mode: $mode,
            owner_id: $owner_id,
            leased_at: $leased_at
          })
        end)
      }
  '
}

fresh_init_state() {
  jq -n \
    --arg project "${PROJECT}" \
    --arg repo_path "${REPO_PARENT_PATH}" \
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
      stuck_after_minutes: 130,
      acpx_timeout_seconds: 3600,
      kill_subagent_on_terminal: false,
      kill_subagent_on_done: false,
      result_note_enabled: false,
      issue_iids_whitelist: [],
      require_labels: [],
      require_labels_match: "or",
      model_tiers: null,
      continue_upgrade_threshold: 2,
      next_new_issue_iid: null,
      dependency_scan_cursor_iid: null,
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
  local iid="$1" execution_id="$2" status="$3" block_reason="$4"
  case "${status}" in
    blocked|timeout) ;;
    *) status="blocked" ;;
  esac
  jq -n \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg status "${status}" \
    --arg block_reason "${block_reason}" \
    '{
      iid: $iid,
      execution_id: $execution_id,
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
# state. Tolerant of both label vocabularies — `pr` via has_done_pr,
# `finish` via either its dedicated field or raw labels, and benchmark-test
# `done` via is_done_on_gitlab — and of missing fields (null → false). This is
# the Source-of-Truth guard: a completed/closed
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
        or (.has_done_pr == true)
        or (.has_finish == true)
        or (((.labels // []) | index("finish")) != null)))' >/dev/null 2>&1
}

# Narrow compatibility check used to prevent an old ordinary `done` callback
# from replacing a newer automatic-merge `finish` with `pr`. Raw labels are
# accepted for rolling upgrades whose reconcile evidence predates has_finish.
phase6_evidence_has_finish() {
  local iid="$1" evidence_json="$2"
  [ -n "${evidence_json}" ] || return 1
  printf '%s' "${evidence_json}" | jq -e --argjson iid "${iid}" '
    (type == "array") and any(.[];
      (.iid == $iid) and (
        (.has_finish == true)
        or (((.labels // []) | index("finish")) != null)))' >/dev/null 2>&1
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
#   $3 = expected execution_id (from pending entry)
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
      execution_id: (.execution_id // $exp_attempt),
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

# Read the exact MR identity produced by the fixed outer wrapper. The compact
# callback is not trusted to choose which MR is verified: it must agree with
# the mode-600 marker in the issue-local log directory. The marker payload is
# still fenced by execution_id.
phase6_file_mode() {
  local path="$1" mode
  if mode="$(stat -c '%a' "${path}" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  elif mode="$(stat -f '%Lp' "${path}" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  else
    return 1
  fi
}

phase6_file_owner() {
  local path="$1" owner
  if owner="$(stat -c '%u' "${path}" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  elif owner="$(stat -f '%u' "${path}" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  else
    return 1
  fi
}

phase6_mr_marker_path() {
  local iid="$1" execution_id="$2"
  [[ "${iid}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${execution_id}" =~ ^[1-9][0-9]*$ ]] || return 1
  [ -n "${WORKTREES_ROOT:-}" ] || return 1
  printf '%s\n' \
    "${WORKTREES_ROOT}/issue-${iid}/${REQ_EXECUTOR_DIR:-.req_executor}/issue-${iid}/log/execution-${execution_id}/mr_result.json"
}

# Output the validated marker or return non-zero. State supplies the trusted
# auto-merge intent and target branch; neither value is accepted from callback
# JSON or from the marker itself without an exact comparison.
phase6_read_auto_merge_marker() {
  local state_json="$1" iid="$2" execution_id="$3"
  local pending target_branch dependency_base_sha work_branch marker_path marker_bytes marker_mode
  pending="$(jq -ce --argjson iid "${iid}" \
    '.pending_subagents[($iid|tostring)] // error("missing pending entry")' \
    <<<"${state_json}" 2>/dev/null)" || return 1
  [ "$(jq -r '.auto_merge // false' <<<"${pending}")" = true ] || return 1
  target_branch="$(jq -r '.merge_target_branch // .branch // ""' <<<"${pending}")"
  [ -n "${target_branch}" ] || return 1
  work_branch="$(jq -r --argjson iid "${iid}" \
    '.work_branch // ("issue/" + ($iid | tostring))' <<<"${pending}")"
  git check-ref-format --branch "${work_branch}" >/dev/null 2>&1 || return 1
  dependency_base_sha="$(jq -r '.dependency_base_sha // ""' <<<"${pending}")"
  if [ -n "${dependency_base_sha}" ] \
      && ! [[ "${dependency_base_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
    return 1
  fi
  marker_path="$(phase6_mr_marker_path "${iid}" "${execution_id}")" || return 1
  [ -f "${marker_path}" ] && [ ! -L "${marker_path}" ] || return 1
  marker_mode="$(phase6_file_mode "${marker_path}")" || return 1
  [ "${marker_mode}" = 600 ] || return 1
  marker_bytes="$(wc -c <"${marker_path}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${marker_bytes}" =~ ^[0-9]+$ ]] \
    && [ "${marker_bytes}" -gt 0 ] \
    && [ "${marker_bytes}" -le 65536 ] || return 1

  jq -ce \
    --argjson issue_iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg source_branch "${work_branch}" \
    --arg target_branch "${target_branch}" \
    --arg dependency_base_sha "${dependency_base_sha}" '
      # Rolling-upgrade compatibility: old version-1 markers predate the
      # dependency field. They are safe to normalize only for a pending entry
      # that itself has no dependency; a dependent attempt must always carry
      # and match the explicit SHA.
      (if type == "object" and has("dependency_base_sha") then .
       elif type == "object" and $dependency_base_sha == "" then
         . + {dependency_base_sha:""}
       else error("missing dependency identity") end) as $marker
      | if ($marker | type) == "object"
        and ($marker | keys | sort) == ([
          "execution_id","auto_merge","dependency_base_sha","iid","issue_iid",
          "merge_api_succeeded","merge_attempted","mr_action","observed_state",
          "outcome","reason","sha","source_branch","target_branch",
          "verified","version","web_url"
        ] | sort)
        and $marker.version == 1
        and $marker.issue_iid == $issue_iid
        and $marker.execution_id == $execution_id
        and $marker.auto_merge == true
        and $marker.source_branch == $source_branch
        and $marker.target_branch == $target_branch
        and (($marker.dependency_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
        and ($marker.iid | type == "number" and . == floor and . > 0)
        and ($marker.web_url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*$"))
        and ($marker.sha | type == "string" and test("^[0-9a-fA-F]{7,64}$"))
        and ($marker.mr_action == "created" or $marker.mr_action == "rotated"
          or $marker.mr_action == "reused")
        and ($marker.outcome == "merged" or $marker.outcome == "opened" or $marker.outcome == "unknown")
        and ($marker.verified | type == "boolean")
        and ($marker.observed_state | type == "string")
        and ($marker.merge_attempted | type == "boolean")
        and ($marker.merge_api_succeeded | type == "boolean")
        and ($marker.reason | type == "string")
      then $marker else error("invalid automatic-merge marker") end
    ' "${marker_path}" 2>/dev/null
}

# Recovery path for a wrapper that was killed after persisting mr_result.json
# but before worker_result.json. The returned compact reply is only evidence to
# enter Phase 6; it still cannot authorize `finish` until the independent live
# MR verification below succeeds.
phase6_reply_from_auto_merge_marker() {
  local state_json="$1" iid="$2" execution_id="$3" marker marker_path log_dir
  marker="$(phase6_read_auto_merge_marker \
    "${state_json}" "${iid}" "${execution_id}")" || return 1
  marker_path="$(phase6_mr_marker_path "${iid}" "${execution_id}")" || return 1
  log_dir="$(dirname "${marker_path}")"
  jq -nc \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg work_branch "$(jq -r '.source_branch' <<<"${marker}")" \
    --arg local_branch "issue/${iid}" \
    --arg commit_sha "$(jq -r '.sha' <<<"${marker}")" \
    --arg merge_request_url "$(jq -r '.web_url' <<<"${marker}")" \
    --arg mr_action "$(jq -r '.mr_action' <<<"${marker}")" \
    --arg log_dir "${log_dir}" '{
      iid:$iid,execution_id:$execution_id,status:"done",mode_actual:"",
      work_branch:$work_branch,local_branch:$local_branch,
      commit_sha:$commit_sha,merge_request_url:$merge_request_url,
      mr_action:$mr_action,wiki_url:"",labels_added:[],labels_removed:[],
      summary_posted:false,block_reason:"",log_dir:$log_dir,block_side:"dispatcher"
    }'
}

# Shared branches never auto-merge, but their one MR is a cross-Issue durable
# identity and therefore needs the same callback-side trust boundary as an
# automatic merge.  The pending entry supplies the frozen topology/target;
# only the fixed, private marker may supply the source SHA and MR identity.
phase6_read_shared_branch_marker() {
  local state_json="$1" iid="$2" execution_id="$3"
  local pending work_branch target_branch dependency_base_sha shared_role
  local checkpoint intent_id marker_path marker_bytes marker_mode marker_owner

  pending="$(jq -ce --argjson iid "${iid}" '
    .pending_subagents[($iid|tostring)] // error("missing pending entry")
  ' <<<"${state_json}" 2>/dev/null)" || return 1
  if ! pending="$(jq -ce --argjson iid "${iid}" '
      if type == "object"
        and .auto_merge == false
        and (.work_branch | type == "string"
          and test("^issue/[1-9][0-9]*\\+[1-9][0-9]*$"))
        and (.branch_members | type == "array" and length == 2)
        and all(.branch_members[];
          type == "number" and . == floor and . > 0)
        and .branch_members[0] != .branch_members[1]
        and (.branch_members | index($iid) != null)
        and .work_branch == ("issue/" + (.branch_members[0] | tostring)
          + "+" + (.branch_members[1] | tostring))
        and .shared_branch_role ==
          (if $iid == .branch_members[0] then "head" else "tail" end)
        and (if .shared_branch_role == "head" then
          (.dependency_iid // null) == null
          and (.dependency_branch // null) == null
          and (.dependency_base_sha // null) == null
        else
          .dependency_iid == .branch_members[0]
          and .dependency_branch == .work_branch
          and (.dependency_base_sha | type == "string"
            and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        end)
      then . else error("invalid shared pending identity") end
    ' <<<"${pending}" 2>/dev/null)"; then
    return 1
  fi

  work_branch="$(jq -r '.work_branch' <<<"${pending}")"
  target_branch="$(jq -r '.merge_target_branch // .branch // ""' \
    <<<"${pending}")"
  [ -n "${target_branch}" ] || return 1
  dependency_base_sha="$(jq -r '.dependency_base_sha // ""' <<<"${pending}")"
  shared_role="$(jq -r '.shared_branch_role' <<<"${pending}")"
  checkpoint="$(phase6_read_shared_mr_checkpoint \
    "${state_json}" "${iid}" "${execution_id}")" || return 1
  intent_id="$(jq -r '.intent_id' <<<"${checkpoint}")"
  marker_path="$(phase6_mr_marker_path "${iid}" "${execution_id}")" || return 1
  [ -f "${marker_path}" ] && [ ! -L "${marker_path}" ] || return 1
  marker_mode="$(phase6_file_mode "${marker_path}")" || return 1
  marker_owner="$(phase6_file_owner "${marker_path}")" || return 1
  [ "${marker_mode}" = 600 ] && [ "${marker_owner}" = "$(id -u)" ] \
    || return 1
  marker_bytes="$(wc -c <"${marker_path}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${marker_bytes}" =~ ^[0-9]+$ ]] \
    && [ "${marker_bytes}" -gt 0 ] \
    && [ "${marker_bytes}" -le 65536 ] || return 1

  jq -ce \
    --argjson issue_iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg source_branch "${work_branch}" \
    --arg target_branch "${target_branch}" \
    --arg dependency_base_sha "${dependency_base_sha}" \
    --arg intent_id "${intent_id}" \
    --argjson checkpoint "${checkpoint}" \
    --arg shared_role "${shared_role}" '
      . as $marker
      | if ($marker | type) == "object"
        and ($marker | keys | sort) == ([
          "execution_id","auto_merge","dependency_base_sha","iid","issue_iid",
          "merge_api_succeeded","merge_attempted","mr_action","observed_state",
          "outcome","reason","sha","source_branch","target_branch",
          "shared_mr_intent_id","verified","version","web_url"
        ] | sort)
        and $marker.version == 1
        and $marker.issue_iid == $issue_iid
        and $marker.execution_id == $execution_id
        and $marker.auto_merge == false
        and $marker.source_branch == $source_branch
        and $marker.target_branch == $target_branch
        and (($marker.dependency_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
        and $marker.shared_mr_intent_id == $intent_id
        and ($marker.iid | type == "number" and . == floor and . > 0)
        and ($marker.web_url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/"
            + ($marker.iid | tostring) + "/?$"))
        and ($marker.sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and (($marker.sha | ascii_downcase)
          == ($checkpoint.commit_sha | ascii_downcase))
        and (if $shared_role == "head"
          then $marker.mr_action == "created"
          else $marker.mr_action == "reused" end)
        and ($marker.verified | type == "boolean")
        and ($marker.outcome | type == "string")
        and ($marker.observed_state | type == "string")
        and $marker.merge_attempted == false
        and $marker.merge_api_succeeded == false
        and ($marker.reason | type == "string" and length > 0)
        and (if $checkpoint.status == "verified_open" then
          $marker.iid == $checkpoint.iid
          and $marker.web_url == $checkpoint.web_url
          and $marker.mr_action == $checkpoint.mr_action
        else
          $checkpoint.status == "pending"
        end)
      then $marker else error("invalid shared-branch MR marker") end
    ' "${marker_path}" 2>/dev/null
}

phase6_reply_from_shared_branch_marker() {
  local state_json="$1" iid="$2" execution_id="$3"
  local marker marker_path log_dir
  marker="$(phase6_read_shared_branch_marker \
    "${state_json}" "${iid}" "${execution_id}")" || return 1
  marker_path="$(phase6_mr_marker_path "${iid}" "${execution_id}")" || return 1
  log_dir="$(dirname "${marker_path}")"
  jq -nc \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg work_branch "$(jq -r '.source_branch' <<<"${marker}")" \
    --arg local_branch "issue/${iid}" \
    --arg commit_sha "$(jq -r '.sha' <<<"${marker}")" \
    --arg merge_request_url "$(jq -r '.web_url' <<<"${marker}")" \
    --arg mr_action "$(jq -r '.mr_action' <<<"${marker}")" \
    --arg log_dir "${log_dir}" '{
      iid:$iid,execution_id:$execution_id,status:"done",mode_actual:"",
      work_branch:$work_branch,local_branch:$local_branch,
      commit_sha:$commit_sha,merge_request_url:$merge_request_url,
      mr_action:$mr_action,wiki_url:"",labels_added:[],labels_removed:[],
      summary_posted:false,block_reason:"",log_dir:$log_dir,block_side:"dispatcher"
    }'
}

# A shared attempt checkpoints its exact pushed commit before it starts MR
# creation. Phase 6 may later have atomically promoted that authority to the
# exact verified-open MR binding before the campaign-state drain is persisted.
# Both forms authorize replay of the same attempt, but the promoted form must
# bind every MR identity field as well as the immutable branch/commit intent.
phase6_read_shared_mr_checkpoint() {
  local state_json="$1" iid="$2" execution_id="$3"
  local pending issue_state_file state_bytes state_mode state_owner

  pending="$(jq -ce --argjson iid "${iid}" '
    .pending_subagents[($iid|tostring)]
    | select(type == "object"
      and .auto_merge == false
      and (.work_branch | type == "string"
        and test("^issue/[1-9][0-9]*\\+[1-9][0-9]*$"))
      and (.branch_members | type == "array" and length == 2)
      and (.shared_branch_role == "head" or .shared_branch_role == "tail"))
  ' <<<"${state_json}" 2>/dev/null)" || return 1
  issue_state_file="${ISSUES_ROOT}/issue-${iid}/state.json"
  [ -f "${issue_state_file}" ] && [ ! -L "${issue_state_file}" ] || return 1
  state_mode="$(phase6_file_mode "${issue_state_file}")" || return 1
  state_owner="$(phase6_file_owner "${issue_state_file}")" || return 1
  [ "${state_mode}" = 600 ] && [ "${state_owner}" = "$(id -u)" ] \
    || return 1
  state_bytes="$(wc -c <"${issue_state_file}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${state_bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${state_bytes}" -le 65536 ] || return 1

  jq -ce \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --argjson pending "${pending}" '
    . as $issue
    | (.mr_finalization // null) as $checkpoint
    | ($pending.merge_target_branch // $pending.branch // "") as $target
    | if type == "object"
      and .iid == $iid
      and .work_branch == $pending.work_branch
      and .branch_members == $pending.branch_members
      and .shared_branch_role == $pending.shared_branch_role
      and .dependency_pinned_execution_id == $execution_id
      and .dependency_history_verified == true
      and (.work_branch_sha | type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      and ($checkpoint | type == "object")
      and $checkpoint.source_execution_id == $execution_id
      and $checkpoint.work_branch == $pending.work_branch
      and $checkpoint.branch_members == $pending.branch_members
      and $checkpoint.shared_branch_role == $pending.shared_branch_role
      and ($checkpoint.commit_sha | type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      and ($checkpoint.intent_id | type == "string"
        and test("^[0-9a-f]{64}$"))
      and ((.work_branch_sha | ascii_downcase)
        == ($checkpoint.commit_sha | ascii_downcase))
      and $target != ""
      and $checkpoint.target_branch == $target
      and (if $checkpoint.status == "pending" then
        ($checkpoint | keys | sort) == ([
          "branch_members","commit_sha","intent_id","shared_branch_role",
          "source_execution_id","status","target_branch","work_branch"
        ] | sort)
      elif $checkpoint.status == "verified_open" then
        ($checkpoint | keys | sort) == ([
          "branch_members","commit_sha","iid","intent_id","mr_action",
          "shared_branch_role","source_execution_id","status",
          "target_branch","verified_at","web_url","work_branch"
        ] | sort)
        and $issue.status == "done"
        and $issue.latest_execution_id == $execution_id
        and ($issue.commit_sha | type == "string")
        and (($issue.commit_sha | ascii_downcase)
          == ($checkpoint.commit_sha | ascii_downcase))
        and $issue.merge_request_url == $checkpoint.web_url
        and ($checkpoint.iid | type == "number"
          and . == floor and . > 0)
        and ($checkpoint.web_url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/"
            + ($checkpoint.iid | tostring) + "/?$"))
        and (if $pending.shared_branch_role == "head" then
          $checkpoint.mr_action == "created"
        else
          $checkpoint.mr_action == "reused"
        end)
        and ($checkpoint.verified_at | type == "string" and length > 0)
      else false end)
    then $checkpoint else error("invalid shared MR checkpoint") end
  ' "${issue_state_file}" 2>/dev/null
}

phase6_shared_mr_checkpoint_is_pending() {
  phase6_read_shared_mr_checkpoint "$@" \
    | jq -e '.status == "pending"' >/dev/null
}

phase6_shared_mr_recovery_is_authorized() {
  phase6_read_shared_mr_checkpoint "$@" >/dev/null
}

# Query one exact shared MR and classify its current identity. The historical
# private marker selects the IID and immutable intent, but only this fresh API
# read may prove that the MR is still open on the expected branch/SHA. Requiring
# the current token principal plus both exact closing lines prevents an
# unrelated user or same-branch MR from being adopted during recovery.
shared_mr_query_live_identity() {
  local mr_iid="$1" mr_url="$2" source_branch="$3" target_branch="$4"
  local commit_sha="$5" intent_id="$6" head_iid="$7" tail_iid="$8"
  local verify_timeout glab_cmd user_response live_response open_response
  local encoded_source command_rc username

  [[ "${mr_iid}" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "${head_iid}" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "${tail_iid}" =~ ^[1-9][0-9]*$ ]] || return 2
  [ "${head_iid}" != "${tail_iid}" ] || return 2
  [[ "${commit_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || return 2
  [[ "${intent_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  [ -n "${mr_url}" ] && [ -n "${source_branch}" ] \
    && [ -n "${target_branch}" ] || return 2

  verify_timeout="${PHASE6_MR_VERIFY_TIMEOUT_SECONDS:-120}"
  [[ "${verify_timeout}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${verify_timeout}" -le 600 ] || return 2
  command -v timeout >/dev/null 2>&1 || return 2
  glab_cmd="${GLAB_BIN:-glab}"
  command -v "${glab_cmd}" >/dev/null 2>&1 || return 2

  set +e
  user_response="$(timeout --kill-after=5s "${verify_timeout}s" \
    "${glab_cmd}" api user 2>/dev/null)"
  command_rc=$?
  set -e
  [ "${command_rc}" -eq 0 ] || return 1
  username="$(jq -er '
    .username | select(type == "string" and length > 0 and length <= 255)
  ' <<<"${user_response}" 2>/dev/null)" || return 1

  set +e
  live_response="$(timeout --kill-after=5s "${verify_timeout}s" \
    "${glab_cmd}" api \
      "projects/${PROJECT_URI}/merge_requests/${mr_iid}" 2>/dev/null)"
  command_rc=$?
  set -e
  [ "${command_rc}" -eq 0 ] || return 1

  encoded_source="$(jq -rn --arg value "${source_branch}" '$value | @uri')" \
    || return 1
  set +e
  open_response="$(timeout --kill-after=5s "${verify_timeout}s" \
    "${glab_cmd}" api \
      "projects/${PROJECT_URI}/merge_requests?scope=all&state=opened&source_branch=${encoded_source}&per_page=100" \
      2>/dev/null)"
  command_rc=$?
  set -e
  [ "${command_rc}" -eq 0 ] || return 1
  open_response="$(jq -ce '
    if type == "array" and length <= 100
      and all(.[];
        type == "object"
        and (.iid | type == "number" and . == floor and . > 0)
        and (.web_url | type == "string" and length > 0)
        and (.source_branch | type == "string" and length > 0)
        and (.state | type == "string" and length > 0))
    then . else error("invalid open shared MR list") end
  ' <<<"${open_response}" 2>/dev/null)" || return 1

  jq -nce \
    --argjson live "${live_response}" \
    --argjson open_rows "${open_response}" \
    --argjson iid "${mr_iid}" \
    --arg web_url "${mr_url}" \
    --arg source_branch "${source_branch}" \
    --arg target_branch "${target_branch}" \
    --arg sha "${commit_sha}" \
    --arg intent_marker "<!-- req_executor-shared-mr-intent:${intent_id} -->" \
    --arg author_username "${username}" \
    --arg closes_head "Closes #${head_iid}" \
    --arg closes_tail "Closes #${tail_iid}" '
      if ($live | type) == "object"
        and ($live.iid | type == "number" and . == floor and . > 0)
        and ($live.web_url | type == "string" and length > 0)
        and ($live.source_branch | type == "string" and length > 0)
        and ($live.target_branch | type == "string" and length > 0)
        and ($live.sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and ($live.state | type == "string" and length > 0)
        and ($live.description | type == "string")
        and ($live.author.username | type == "string" and length > 0)
      then {
        state:$live.state,
        identity_matches:(
          $live.iid == $iid
          and $live.web_url == $web_url
          and $live.source_branch == $source_branch
          and $live.target_branch == $target_branch
          and (($live.sha | ascii_downcase) == ($sha | ascii_downcase))
          and $live.author.username == $author_username
          and ($live.description | contains($intent_marker))
          and (($live.description | split("\n")) | index($closes_head) != null)
          and (($live.description | split("\n")) | index($closes_tail) != null)
          and ($open_rows | length) == 1
          and $open_rows[0].iid == $iid
          and $open_rows[0].web_url == $web_url
          and $open_rows[0].source_branch == $source_branch
          and $open_rows[0].state == "opened"
        )
      } else error("invalid live shared MR response") end
    ' 2>/dev/null
}

# Return applies=false for ordinary branches.  For a shared branch, success is
# authorized only by the exact private marker and an exact compact-result match.
phase6_resolve_shared_branch_mr() {
  local state_json="$1" reply_json="$2"
  local iid execution_id pending work_branch marker live_mr live_state
  local head_iid tail_iid shared_mr_recovery_pending=false
  iid="$(jq -r '.iid' <<<"${reply_json}")"
  execution_id="$(jq -r '.execution_id' <<<"${reply_json}")"
  pending="$(jq -c --argjson iid "${iid}" \
    '.pending_subagents[($iid|tostring)] // {}' <<<"${state_json}")"
  work_branch="$(jq -r '.work_branch // ""' <<<"${pending}")"
  if ! [[ "${work_branch}" =~ ^issue/[1-9][0-9]*\+[1-9][0-9]*$ ]]; then
    jq -nc --argjson reply "${reply_json}" \
      '{applies:false,reply:$reply,completion_label:"",recovery_pending:false}'
    return 0
  fi

  if ! marker="$(phase6_read_shared_branch_marker \
      "${state_json}" "${iid}" "${execution_id}")"; then
    reply_json="$(jq -c '
      .status = "blocked"
      | .block_side = "dispatcher"
      | .block_reason = "shared MR could not be verified: the trusted current-execution marker is missing, unsafe, pending, or mismatched"
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" \
      '{applies:true,reply:$reply,completion_label:"",recovery_pending:true}'
    return 0
  fi

  if ! jq -e \
      --arg mr_url "$(jq -r '.web_url' <<<"${marker}")" \
      --arg source_branch "$(jq -r '.source_branch' <<<"${marker}")" \
      --arg sha "$(jq -r '.sha' <<<"${marker}")" \
      --arg mr_action "$(jq -r '.mr_action' <<<"${marker}")" '
      .merge_request_url == $mr_url
      and .work_branch == $source_branch
      and ((.commit_sha | ascii_downcase) == ($sha | ascii_downcase))
      and .mr_action == $mr_action
    ' <<<"${reply_json}" >/dev/null 2>&1; then
    reply_json="$(jq -c '
      .status = "blocked"
      | .block_side = "dispatcher"
      | .block_reason = "shared MR could not be verified: compact result does not match the trusted current-execution marker"
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" \
      '{applies:true,reply:$reply,completion_label:"preserve",recovery_pending:false}'
    return 0
  fi

  if [ "$(jq -r '.reason' <<<"${marker}")" = \
      shared_mr_history_conflict ]; then
    reply_json="$(jq -c '
      .status = "failed"
      | .block_side = "dispatcher"
      | .block_reason = "shared MR source history is ambiguous; replacement is forbidden"
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" \
      '{applies:true,reply:$reply,completion_label:"",recovery_pending:false}'
    return 0
  fi

  head_iid="$(jq -r '.branch_members[0]' <<<"${pending}")"
  tail_iid="$(jq -r '.branch_members[1]' <<<"${pending}")"
  if ! live_mr="$(shared_mr_query_live_identity \
      "$(jq -r '.iid' <<<"${marker}")" \
      "$(jq -r '.web_url' <<<"${marker}")" \
      "$(jq -r '.source_branch' <<<"${marker}")" \
      "$(jq -r '.target_branch' <<<"${marker}")" \
      "$(jq -r '.sha' <<<"${marker}")" \
      "$(jq -r '.shared_mr_intent_id' <<<"${marker}")" \
      "${head_iid}" "${tail_iid}")"; then
    reply_json="$(jq -c '
      .status = "blocked"
      | .block_side = "dispatcher"
      | .block_reason = "shared MR live verification is temporarily unavailable"
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" \
      '{applies:true,reply:$reply,completion_label:"",recovery_pending:true}'
    return 0
  fi
  live_state="$(jq -r '.state' <<<"${live_mr}")"
  if [ "$(jq -r '.identity_matches' <<<"${live_mr}")" != true ]; then
    reply_json="$(jq -c '
      .status = "blocked"
      | .block_side = "dispatcher"
      | .block_reason = "shared MR live identity, ownership intent, target, or source SHA no longer matches"
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" \
      '{applies:true,reply:$reply,completion_label:"preserve",recovery_pending:false}'
    return 0
  fi
  if [ "${live_state}" != opened ]; then
    reply_json="$(jq -c --arg state "${live_state}" '
      .status = "blocked"
      | .block_side = "dispatcher"
      | .block_reason = ("shared MR is no longer open (state=" + $state + ")")
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" \
      '{applies:true,reply:$reply,completion_label:"preserve",recovery_pending:false}'
    return 0
  fi

  reply_json="$(jq -c '
    .status = "done"
    | .block_side = "cc"
    | .block_reason = ""
  ' <<<"${reply_json}")"
  jq -nc --argjson reply "${reply_json}" \
    '{applies:true,reply:$reply,completion_label:"pr",recovery_pending:false}'
}

# Reconcile an automatic-merge result against the exact live GitLab MR.
# Inputs: $1=current campaign state, $2=normalized compact reply.
# Output: {reply:<normalized reply>,completion_label:""|"pr"|"finish"|"preserve"}
phase6_resolve_auto_merge() {
  local state_json="$1" reply_json="$2"
  local iid execution_id pending auto_merge reply_status marker
  local mr_url work_branch commit_sha target_branch dependency_base_sha mr_iid mr_action
  iid="$(jq -r '.iid' <<<"${reply_json}")"
  execution_id="$(jq -r '.execution_id' <<<"${reply_json}")"
  pending="$(jq -c --argjson iid "${iid}" '.pending_subagents[($iid|tostring)] // {}' <<<"${state_json}")"
  auto_merge="$(jq -r '.auto_merge // false' <<<"${pending}")"
  reply_status="$(jq -r '.status' <<<"${reply_json}")"

  if [ "${auto_merge}" != true ]; then
    jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:""}'
    return 0
  fi

  if ! marker="$(phase6_read_auto_merge_marker \
      "${state_json}" "${iid}" "${execution_id}")"; then
    if [ "${reply_status}" = done ] \
        || [ -n "$(jq -r '.merge_request_url // ""' <<<"${reply_json}")" ]; then
      reply_json="$(jq -c '
        .status = "failed"
        | .block_side = "dispatcher"
        | .block_reason = "automatic merge could not be verified: the trusted current-execution MR marker is missing or invalid"
      ' <<<"${reply_json}")"
      jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:"preserve"}'
    else
      jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:""}'
    fi
    return 0
  fi

  mr_url="$(jq -r '.web_url' <<<"${marker}")"
  work_branch="$(jq -r '.source_branch' <<<"${marker}")"
  commit_sha="$(jq -r '.sha' <<<"${marker}")"
  target_branch="$(jq -r '.target_branch' <<<"${marker}")"
  dependency_base_sha="$(jq -r '.dependency_base_sha' <<<"${marker}")"
  mr_iid="$(jq -r '.iid' <<<"${marker}")"
  mr_action="$(jq -r '.mr_action' <<<"${marker}")"

  # A callback may report outcome, but it may not select or alter the identity
  # being verified. Every identity field must exactly match the fixed marker.
  if ! jq -e \
      --arg mr_url "${mr_url}" \
      --arg work_branch "${work_branch}" \
      --arg commit_sha "${commit_sha}" \
      --arg mr_action "${mr_action}" '
        .merge_request_url == $mr_url
        and .work_branch == $work_branch
        and ((.commit_sha | ascii_downcase) == ($commit_sha | ascii_downcase))
        and .mr_action == $mr_action
      ' <<<"${reply_json}" >/dev/null 2>&1; then
    reply_json="$(jq -c '
      .status = "failed"
      | .block_side = "dispatcher"
      | .block_reason = "automatic merge could not be verified: compact result does not match the trusted current-execution MR identity"
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:"preserve"}'
    return 0
  fi

  local verify_result="" verify_rc=1 verify_valid=false verify_timeout
  verify_timeout="${PHASE6_MR_VERIFY_TIMEOUT_SECONDS:-120}"
  if [[ "${verify_timeout}" =~ ^[1-9][0-9]*$ ]] \
      && [ "${verify_timeout}" -le 600 ] \
      && command -v timeout >/dev/null 2>&1; then
    set +e
    verify_result="$(
      timeout --kill-after=5s "${verify_timeout}s" env \
        PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
        REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
        MERGE_MR_MODE=verify AUTO_MERGE=false \
        MR_IID="${mr_iid}" MERGE_REQUEST_URL="${mr_url}" \
        WORK_BRANCH="${work_branch}" MERGE_TARGET_BRANCH="${target_branch}" \
        DEPENDENCY_BASE_SHA="${dependency_base_sha}" \
        COMMIT_SHA="${commit_sha}" \
        bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge_mr.sh" 2>/dev/null
    )"
    verify_rc=$?
    set -e
  fi

  if [ "${verify_rc}" -eq 0 ] && jq -e \
      --argjson iid "${mr_iid}" \
      --arg web_url "${mr_url}" \
      --arg source_branch "${work_branch}" \
      --arg target_branch "${target_branch}" \
      --arg dependency_base_sha "${dependency_base_sha}" \
      --arg sha "${commit_sha}" '
        type == "object"
        and .version == 1
        and .iid == $iid
        and .web_url == $web_url
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.dependency_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
        and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
        and (.verified | type == "boolean")
        and (.outcome == "merged" or .outcome == "opened" or .outcome == "unknown")
        and (.observed_state | type == "string")
        and (.reason | type == "string")
      ' <<<"${verify_result}" >/dev/null 2>&1; then
    verify_valid=true
  fi

  if [ "${verify_valid}" = true ] \
      && jq -e '.verified == true and .outcome == "merged" and .observed_state == "merged"' \
        <<<"${verify_result}" >/dev/null; then
    reply_json="$(jq -c '
      .status = "done"
      | .block_side = "cc"
      | .block_reason = ""
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:"finish"}'
    return 0
  fi

  if [ "${verify_valid}" = true ] \
      && jq -e '.verified == true and .outcome == "opened" and .observed_state == "opened"' \
        <<<"${verify_result}" >/dev/null; then
    local opened_reason
    opened_reason="$(jq -r '.reason' <<<"${verify_result}")"
    reply_json="$(jq -c --arg reason "automatic merge did not complete; exact MR remains opened (${opened_reason})" '
      .status = "failed"
      | .block_side = "cc"
      | .block_reason = $reason
    ' <<<"${reply_json}")"
    jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:"pr"}'
    return 0
  fi

  local unknown_reason="verification_unavailable_or_identity_mismatch"
  if [ "${verify_valid}" = true ]; then
    unknown_reason="$(jq -r '.reason' <<<"${verify_result}")"
  elif [ "${verify_rc}" -eq 124 ] || [ "${verify_rc}" -eq 137 ]; then
    unknown_reason="verification_timeout"
  fi
  reply_json="$(jq -c --arg reason "automatic merge state is uncertain; existing issue labels were preserved (${unknown_reason})" '
    .status = "failed"
    | .block_side = "dispatcher"
    | .block_reason = $reason
  ' <<<"${reply_json}")"
  jq -nc --argjson reply "${reply_json}" '{reply:$reply,completion_label:"preserve"}'
}

# Synchronize live workflow labels via set_issue_label.sh.
# Inputs: $1=iid, $2=final_status (done|blocked|failed|timeout)
#         $3=block_side (cc|dispatcher, 默认 dispatcher) — selects
#            blocked-cc/blocked-dispatcher and failed-cc/failed-dispatcher.
#         $4=completion_label (optional): finish for a server-verified merge,
#            pr for an automatic merge that is verified still-open, preserve
#            for uncertain live state, or empty for ordinary status behavior.
# Returns: 0 on success, non-zero with stderr if any required op fails.
phase6_sync_labels() {
  local iid="$1" final_status="$2" block_side="${3:-dispatcher}" completion_label="${4:-}"
  case "${block_side}" in cc|dispatcher) ;; *) block_side="dispatcher" ;; esac
  local rc=0

  if [ "${completion_label}" = preserve ]; then
    return 0
  fi
  if [ "${completion_label}" = finish ]; then
    # set_issue_label.sh performs one GitLab label update that adds `finish`
    # while removing every conflicting workflow label. Never remove `pr` or
    # `done` first: if the single add/update fails, the last stable completion
    # label must remain visible until the durable Phase 6 retry succeeds.
    _label_op "${iid}" add finish
    return $?
  fi
  if [ "${completion_label}" = pr ]; then
    # Same atomic-transition rule as `finish` above.
    _label_op "${iid}" add pr
    return $?
  fi
  case "${final_status}" in
    done)
      # set_issue_label.sh atomically adds the terminal label and removes all
      # conflicting workflow labels, including doing and legacy residues.
      _label_op "${iid}" add pr || rc=$?
      ;;
    blocked)
      if [ "${block_side}" = "cc" ]; then
        _label_op "${iid}" add blocked-cc || rc=$?
      else
        _label_op "${iid}" add blocked-dispatcher || rc=$?
      fi
      ;;
    failed)
      if [ "${block_side}" = "cc" ]; then
        _label_op "${iid}" add failed-cc || rc=$?
      else
        _label_op "${iid}" add failed-dispatcher || rc=$?
      fi
      ;;
    timeout)
      _label_op "${iid}" add timeout || rc=$?
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
  # EXECUTION_ID=1 is a placeholder — env_paths.sh requires the var
  # when ISSUE_IID is set, but set_issue_label.sh itself only touches the
  # GitLab issue label set.
  PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
    REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
    ISSUE_IID="${iid}" EXECUTION_ID=1 \
    bash "${script_dir}/set_issue_label.sh" "${op}" "${lbl}"
}

# Read prior issue state.json (if it exists) and echo it as JSON, or "{}".
phase6_read_prior_issue_state() {
  local iid="$1"
  local f="${ISSUES_ROOT}/issue-${iid}/state.json"
  if [ -f "${f}" ]; then cat "${f}"; else echo '{}'; fi
}

# Write the terminal EXECUTION_STATE_FILE + ISSUE_STATE_FILE for a given
# (iid, execution_id) pair. Caller passes the validated reply JSON and
# the final status (after label sync + retry promotion).
#
# Inputs (positional):
#   $1 = iid
#   $2 = execution_id
#   $3 = reply JSON (normalized)
#   $4 = final_status
#   $5 = prior issue state JSON (or "{}")
#   $6 = is_launch_synth ("true" | "false") — when "true", retry_count is
#         preserved (launch-side failures don't consume retry budget).
#
# Side effects: rewrites EXECUTION_STATE_FILE + ISSUE_STATE_FILE atomically.
# Stdout: a single line with the new retry_count (so the caller can persist
# campaign-level classification with the same value).
phase6_write_state_files() {
  local iid="$1" execution_id="$2" reply="$3" final_status="$4" \
        prior_issue_state="$5" is_launch_synth="$6" block_side="${7:-}" \
        shared_mr_binding="${8:-null}"

  local issue_root="${ISSUES_ROOT}/issue-${iid}"
  local executions_root="${issue_root}/executions"
  local execution_state_file="${executions_root}/execution-${execution_id}.json"
  local issue_state_file="${issue_root}/state.json"
  local summary_file="${issue_root}/summary.md"

  mkdir -p "${issue_root}" "${executions_root}"

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

  # ─── EXECUTION_STATE_FILE ───
  local prior_execution_state='{}'
  if [ -f "${execution_state_file}" ]; then
    prior_execution_state="$(cat "${execution_state_file}")"
  fi
  local summary_exists=false
  [ -f "${summary_file}" ] && summary_exists=true

  local new_execution_state
  new_execution_state="$(printf '%s' "${prior_execution_state}" | jq \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg now "${now}" \
    --arg final_status "${final_status}" \
    --arg block_side "${block_side}" \
    --arg summary_file "${summary_file}" \
    --argjson summary_exists "${summary_exists}" \
    --argjson shared_mr_binding "${shared_mr_binding}" \
    --argjson reply "${reply}" \
    '
    . as $prior
    | $prior
    + {
        iid: $iid,
        execution_id: $execution_id,
        status: $final_status,
        execution_finished_at: $now,
        commit_sha: (if $reply.commit_sha == "" then null else $reply.commit_sha end),
        wiki_artifacts_file: null,
        execution_artifacts_posted_to_wiki: false,
        summary_file: (if $summary_exists then $summary_file else null end),
        summary_posted_to_issue: ($reply.summary_posted // false),
        block_reason: (if ($reply.block_reason // "") == "" then null else $reply.block_reason end),
        block_side: (if ($final_status == "blocked" or $final_status == "failed") and ($block_side != "") then $block_side else null end)
      }
    | if $shared_mr_binding == null then .
      else .mr_finalization = $shared_mr_binding end
    ')"
  printf '%s' "${new_execution_state}" | atomic_write_json "${execution_state_file}"

  # ─── ISSUE_STATE_FILE ───
  local new_issue_state
  new_issue_state="$(printf '%s' "${prior_issue_state}" | jq \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg now "${now}" \
    --arg final_status "${final_status}" \
    --arg block_side "${block_side}" \
    --arg issue_root "${issue_root}" \
    --argjson new_retry_count "${new_retry_count}" \
    --argjson shared_mr_binding "${shared_mr_binding}" \
    --argjson reply "${reply}" \
    '
    . as $prior
    | $prior
    | del(.attempts_total,.latest_attempt_number,.preparing_attempt_number,
          .latest_attempt_dir,.prior_attempt_count)
    + {
        iid: $iid,
        session: ($prior.session // ("issue-" + ($iid|tostring))),
        status: $final_status,
        mode: $reply.mode_actual,
        latest_execution_id: $execution_id,
        retry_count: $new_retry_count,
        block_reason: (if ($reply.block_reason // "") == "" then null else $reply.block_reason end),
        commit_sha: (if $reply.commit_sha == "" then null else $reply.commit_sha end),
        merge_request_url: (if $reply.merge_request_url == "" then null else $reply.merge_request_url end),
        updated_at: $now,
        block_side: (if ($final_status == "blocked" or $final_status == "failed") and ($block_side != "") then $block_side else ($prior.block_side // null) end)
      }
    | if $shared_mr_binding == null then .
      else .mr_finalization = $shared_mr_binding end
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

  if [ -z "${child_session_key}" ] || [ "${child_session_key}" = "null" ]; then
    jq -n '{action:"skip", target:"", reason:"no_child_session_key"}'
    return 0
  fi

  # Preserve every terminal child session. Operators need both the local files
  # and the OpenClaw child-session transcript for post-run diagnosis.
  jq -n --arg target "${child_session_key}" \
    --arg status "${final_status}" \
    '{action:"skip", target:$target, reason:"preserve_terminal_evidence", status:$status}'
}

# All-in-one Phase 6 processor. Reads the validated reply, syncs labels,
# writes terminal state files, applies state classification, decides
# cleanup, persists campaign state. Does NOT touch the flock.
#
# Inputs (positional):
#   $1 = current state JSON (typically the pure load_state output)
#   $2 = reply JSON (normalized)
#   $3 = is_launch_synth ("true"|"false")
#   $4 = trusted completion-label override (optional: "preserve")
# Output (stdout): one-line JSON envelope:
#   {"final_status":"...","cleanup":{...},"remaining_pending_count":N,"updated_state":<json>}
phase6_process() {
  local state_json="$1" reply_json="$2" is_launch_synth="$3"
  local trusted_completion_override="${4:-}"
  local iid execution_id reply_status completion_label=""
  case "${trusted_completion_override}" in
    ""|preserve) ;;
    *) trusted_completion_override="" ;;
  esac
  iid="$(printf '%s' "${reply_json}" | jq -r '.iid')"
  execution_id="$(printf '%s' "${reply_json}" | jq -r '.execution_id')"
  reply_status="$(printf '%s' "${reply_json}" | jq -r '.status')"

  local shared_mr_resolution auto_merge_resolution
  local shared_mr_applies=false shared_mr_binding=null
  local shared_mr_recovery_pending=false
  shared_mr_resolution="$(phase6_resolve_shared_branch_mr \
    "${state_json}" "${reply_json}")"
  if [ "$(jq -r '.applies' <<<"${shared_mr_resolution}")" = true ]; then
    shared_mr_applies=true
    reply_json="$(jq -c '.reply' <<<"${shared_mr_resolution}")"
    completion_label="$(jq -r '.completion_label' <<<"${shared_mr_resolution}")"
    shared_mr_recovery_pending="$(jq -r '.recovery_pending // false' \
      <<<"${shared_mr_resolution}")"
  else
    auto_merge_resolution="$(phase6_resolve_auto_merge \
      "${state_json}" "${reply_json}")"
    reply_json="$(jq -c '.reply' <<<"${auto_merge_resolution}")"
    completion_label="$(jq -r '.completion_label' <<<"${auto_merge_resolution}")"
  fi
  if [ -z "${completion_label}" ] \
      && [ "${trusted_completion_override}" = preserve ]; then
    completion_label=preserve
  fi
  reply_status="$(jq -r '.status' <<<"${reply_json}")"
  local block_side
  block_side="$(printf '%s' "${reply_json}" | jq -r '.block_side // "dispatcher"')"

  # Capture child_session_key BEFORE drain.
  local child_session_key
  child_session_key="$(printf '%s' "${state_json}" \
    | jq -r --argjson iid "${iid}" '.pending_subagents[($iid|tostring)].child_session_key // ""')"

  # The exact shared commit is already durable, but its MR marker is not ready.
  # Preserve the claim without touching labels or retry counters; the batch
  # heartbeat can now finalize only the MR and feed its verified marker back
  # through this same Phase 6 path.
  if [ "${shared_mr_applies}" = true ] \
      && [ "${shared_mr_recovery_pending}" = true ] \
      && { [ -z "${completion_label}" ] \
        || [ "${completion_label}" = preserve ]; } \
      && [ "${reply_status}" = blocked ] \
      && phase6_shared_mr_recovery_is_authorized \
        "${state_json}" "${iid}" "${execution_id}"; then
    local recovery_state recovery_cleanup recovery_remaining
    recovery_state="$(jq -c \
      --argjson iid "${iid}" \
      --argjson execution_id "${execution_id}" '
      .pending_subagents[($iid|tostring)].mr_finalization_retry = true
      | .pending_subagents[($iid|tostring)].mr_finalization_retry_execution_id = $execution_id
    ' <<<"${state_json}")"
    recovery_cleanup="$(phase6_decide_cleanup \
      "${recovery_state}" "${iid}" blocked "${child_session_key}")"
    recovery_remaining="$(jq -r '.pending_subagents | keys | length' \
      <<<"${recovery_state}")"
    jq -nc \
      --argjson final_reply "${reply_json}" \
      --argjson cleanup "${recovery_cleanup}" \
      --argjson remaining_pending_count "${recovery_remaining}" \
      --argjson updated_state "${recovery_state}" '{
        final_status:"blocked",
        final_reply:$final_reply,
        cleanup:$cleanup,
        remaining_pending_count:$remaining_pending_count,
        updated_state:$updated_state,
        mr_recovery_pending:true
      }'
    return 0
  fi

  # Sync labels for the preliminary status. On sync failure:
  #   - `failed`  → keep `failed` (retry-budget exhaustion is sticky).
  #   - `timeout` → keep `timeout` (terminal, no retry; only append diagnostic
  #                 to block_reason and retry the sync best-effort once).
  #   - else      → demote to `blocked` (the historical safety net for
  #                 transient GitLab API failures on done/blocked outcomes).
  local label_err="" label_retry_pending=false label_retry_kind=""
  local final_status="${reply_status}"
  local _err=""
  if ! _err="$(phase6_sync_labels "${iid}" "${final_status}" "${block_side}" "${completion_label}" 2>&1 >/dev/null)"; then
    label_err="${_err}"
    if [ "${completion_label}" = finish ] \
        || { [ "${shared_mr_applies}" = true ] \
          && [ "${completion_label}" = pr ]; }; then
      final_status="blocked"
      block_side="dispatcher"
      label_retry_kind="${completion_label}"
      completion_label=preserve
      label_retry_pending=true
      reply_json="$(printf '%s' "${reply_json}" | jq -c \
        --arg le "phase6 completion label sync failed after verified MR state: ${label_err}" '
        .status = "blocked"
        | .block_side = "dispatcher"
        | (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
      ')"
    elif [ "${final_status}" = "timeout" ]; then
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

  # A verified MR whose atomic `pr`/`finish` transition failed is not terminal.
  # Keep the exact pending claim and durable worker/MR markers intact so the
  # heartbeat's result/completion reconciliation re-enters Phase 6 and retries
  # only the live verification + label transition; it must never rerun issue
  # code, emit a success handoff, or drain the scheduler slot prematurely.
  if [ "${label_retry_pending}" = true ]; then
    local retry_cleanup retry_remaining retry_state
    retry_state="$(jq -c \
      --argjson iid "${iid}" \
      --argjson execution_id "${execution_id}" \
      --arg retry_kind "${label_retry_kind}" '
      if .pending_subagents[($iid|tostring)] != null then
        if $retry_kind == "finish" then
          .pending_subagents[($iid|tostring)].finish_label_retry = true
          | .pending_subagents[($iid|tostring)].finish_label_retry_execution_id = $execution_id
        else
          .pending_subagents[($iid|tostring)].mr_label_retry = true
          | .pending_subagents[($iid|tostring)].mr_label_retry_execution_id = $execution_id
        end
      else . end
    ' <<<"${state_json}")"
    retry_cleanup="$(phase6_decide_cleanup \
      "${retry_state}" "${iid}" "${final_status}" "${child_session_key}")"
    retry_remaining="$(printf '%s' "${retry_state}" | jq -r \
      '.pending_subagents | keys | length')"
    jq -nc \
      --arg final_status "${final_status}" \
      --argjson final_reply "${reply_json}" \
      --argjson cleanup "${retry_cleanup}" \
      --argjson remaining_pending_count "${retry_remaining}" \
      --argjson updated_state "${retry_state}" '{
        final_status:$final_status,
        final_reply:$final_reply,
        cleanup:$cleanup,
        remaining_pending_count:$remaining_pending_count,
        updated_state:$updated_state,
        label_retry_pending:true
      }'
    return 0
  fi

  # Write per-issue state files (computes new retry_count).
  local prior_issue_state
  prior_issue_state="$(phase6_read_prior_issue_state "${iid}")"
  if [ "${shared_mr_applies}" = true ] \
      && [ "${final_status}" = done ]; then
    local shared_marker shared_pending shared_verified_at
    shared_marker="$(phase6_read_shared_branch_marker \
      "${state_json}" "${iid}" "${execution_id}")" || return 1
    shared_pending="$(jq -c --argjson iid "${iid}" \
      '.pending_subagents[($iid|tostring)]' <<<"${state_json}")"
    shared_verified_at="$(utc_now)"
    shared_mr_binding="$(jq -nc \
      --argjson execution_id "${execution_id}" \
      --arg work_branch "$(jq -r '.work_branch' <<<"${shared_pending}")" \
      --argjson branch_members "$(jq -c '.branch_members' <<<"${shared_pending}")" \
      --arg shared_branch_role "$(jq -r '.shared_branch_role' <<<"${shared_pending}")" \
      --arg commit_sha "$(jq -r '.sha' <<<"${shared_marker}")" \
      --arg intent_id "$(jq -r '.shared_mr_intent_id' <<<"${shared_marker}")" \
      --arg target_branch "$(jq -r '.target_branch' <<<"${shared_marker}")" \
      --argjson iid "$(jq -r '.iid' <<<"${shared_marker}")" \
      --arg web_url "$(jq -r '.web_url' <<<"${shared_marker}")" \
      --arg mr_action "$(jq -r '.mr_action' <<<"${shared_marker}")" \
      --arg verified_at "${shared_verified_at}" '{
        status:"verified_open",
        source_execution_id:$execution_id,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:$shared_branch_role,
        commit_sha:$commit_sha,
        intent_id:$intent_id,
        target_branch:$target_branch,
        iid:$iid,
        web_url:$web_url,
        mr_action:$mr_action,
        verified_at:$verified_at
      }')"
  fi
  local new_retry_count blocked_retry_limit
  new_retry_count="$(phase6_write_state_files "${iid}" "${execution_id}" "${reply_json}" \
    "${final_status}" "${prior_issue_state}" "${is_launch_synth}" \
    "${block_side}" "${shared_mr_binding}")"

  # Promote blocked → failed if retry_count > blocked_retry_limit.
  blocked_retry_limit="$(printf '%s' "${state_json}" | jq -r '.blocked_retry_limit // 0')"
  if [ "${final_status}" = "blocked" ] && [ "${is_launch_synth}" != "true" ] \
     && [ "${new_retry_count}" -gt "${blocked_retry_limit}" ]; then
    final_status="failed"
    phase6_sync_labels "${iid}" failed "${block_side}" >/dev/null 2>&1 || true
    # rewrite issue state with final_status=failed (retry_count already incremented)
    phase6_write_state_files "${iid}" "${execution_id}" "${reply_json}" \
      "${final_status}" "${prior_issue_state}" "${is_launch_synth}" \
      "${block_side}" "${shared_mr_binding}" >/dev/null
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
    --argjson final_reply "${reply_json}" \
    --argjson cleanup "${cleanup}" \
    --argjson remaining_pending_count "${remaining_pending_count}" \
    --argjson updated_state "${updated_state}" '
    {
      final_status: $final_status,
      final_reply: $final_reply,
      cleanup: $cleanup,
      remaining_pending_count: $remaining_pending_count,
      updated_state: $updated_state
    }'
}
