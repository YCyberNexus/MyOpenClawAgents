#!/usr/bin/env bash
# Stop every executor task chain for one GitLab repository while preserving
# private audit evidence. Runtime child termination remains an orchestrator
# operation; this wrapper first fences all durable state against late callbacks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
RESERVE_CMD="${RESERVE_CMD:-${SCRIPT_DIR}/reserve_driven_batch_items.sh}"
RESOLVE_REPO_CMD="${RESOLVE_REPO_CMD:-${SCRIPT_DIR}/resolve_driven_repo_path.sh}"

stop_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    stop_failure "no SHA-256 command is available"
  fi
}

url_decode_path() {
  local value="$1" rest="$1" hex=""
  while [[ "${rest}" == *%* ]]; do
    rest="${rest#*%}"
    [ "${#rest}" -ge 2 ] || return 1
    hex="${rest:0:2}"
    case "${hex}" in
      [0-9A-Fa-f][0-9A-Fa-f]) ;;
      *) return 1 ;;
    esac
    [ "${hex}" != 00 ] || return 1
    rest="${rest:2}"
  done
  printf '%b' "${value//%/\\x}"
}

normalize_project() {
  local target="$1" expected_prefix path decoded segment
  local -a segments=()
  target="${target%%\#*}"
  target="${target%%\?*}"
  while [ "${target}" != "${target%/}" ]; do target="${target%/}"; done
  case "${target}" in
    http://*|https://*)
      expected_prefix="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/"
      [[ "${target}" == "${expected_prefix}"* ]] || return 1
      path="${target#${expected_prefix}}"
      ;;
    *) path="${target}" ;;
  esac
  path="${path%%/-/*}"
  path="${path%.git}"
  decoded="$(url_decode_path "${path}")" || return 1
  case "${decoded}" in
    ""|/*|*/|*//*|*[[:space:]]*) return 1 ;;
  esac
  [[ "${decoded}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || return 1
  IFS='/' read -r -a segments <<<"${decoded}"
  for segment in "${segments[@]}"; do
    case "${segment}" in .|..) return 1 ;; esac
  done
  printf '%s\n' "${decoded}"
}

if [ "$#" -ne 0 ]; then
  stop_failure "usage: /mission-stop <gitlab-repository-url|group/project>"
fi
COMMAND_TEXT="${MESSAGE:-}"
[ -n "${COMMAND_TEXT}" ] || COMMAND_TEXT="$(cat)"
if [[ ! "${COMMAND_TEXT}" =~ ^/mission-stop[[:blank:]]+([^[:blank:]]+)[[:blank:]]*$ ]]; then
  stop_failure "usage: /mission-stop <gitlab-repository-url|group/project>"
fi
TARGET_TEXT="${BASH_REMATCH[1]}"

# Resolve deployment pins without exposing them to the orchestrator.
REPO_PARENT_PROCESS_SET="${REPO_PARENT_PATH+x}"
REPO_PARENT_PROCESS_VALUE="${REPO_PARENT_PATH:-}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/gitlab_env_resolver.sh"
GITLAB_HOST_EFFECTIVE="${GITLAB_HOST}"
GITLAB_PROTOCOL_EFFECTIVE="${GITLAB_API_PROTOCOL}"
GITLAB_TOKEN_EFFECTIVE="${GITLAB_TOKEN}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null
GITLAB_HOST="${GITLAB_HOST_EFFECTIVE}"
GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_EFFECTIVE}"
GITLAB_TOKEN="${GITLAB_TOKEN_EFFECTIVE}"
if [ "${REPO_PARENT_PROCESS_SET}" = x ]; then
  REPO_PARENT_PATH="${REPO_PARENT_PROCESS_VALUE}"
fi
: "${REPO_PARENT_PATH:=/data}"
export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN REPO_PARENT_PATH

PROJECT_FULL="$(normalize_project "${TARGET_TEXT}")" \
  || stop_failure "target must be a repository on the configured GitLab host or <group>/<project>"
GROUP="${PROJECT_FULL%/*}"
PROJECT="${PROJECT_FULL##*/}"
STOPPED_AT_EPOCH="${NOW_EPOCH:-$(date +%s)}"
case "${STOPPED_AT_EPOCH}" in
  ''|*[!0-9]*) stop_failure "NOW_EPOCH must be a non-negative integer" ;;
esac
STOP_ENTROPY="${PROJECT_FULL}:${STOPPED_AT_EPOCH}:$$:${RANDOM}"
STOP_ID="mission-stop-${STOPPED_AT_EPOCH}-$(printf '%s' "${STOP_ENTROPY}" | sha256_text | cut -c1-16)"
STOP_ARCHIVE_ROOT="${EXECUTOR_SCHEDULER_ROOT}/mission_stop_archive"
STOP_ARCHIVE_DIR="${STOP_ARCHIVE_ROOT}/${STOP_ID}"
mkdir -p "${STOP_ARCHIVE_DIR}/launch_actions"
chmod 700 "${STOP_ARCHIVE_ROOT}" "${STOP_ARCHIVE_DIR}" \
  "${STOP_ARCHIVE_DIR}/launch_actions"

# Serialize with reservation/top-up. The migration-only pass completes any
# interrupted scheduler transaction before this command constructs its own.
EXECUTOR_TICK_LOCK_FILE="${EXECUTOR_SCHEDULER_ROOT}/executor_batch_tick.lock"
exec {STOP_TICK_LOCK_FD}>"${EXECUTOR_TICK_LOCK_FILE}"
flock -x "${STOP_TICK_LOCK_FD}"
if ! CONFIG_DIR="${CONFIG_DIR}" DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
    bash "${RESERVE_CMD}" >/dev/null; then
  flock -u "${STOP_TICK_LOCK_FD}"
  exec {STOP_TICK_LOCK_FD}>&-
  stop_failure "scheduler recovery failed before mission stop"
fi

# Snapshot target launch actions and acquire their locks in stable job-id
# order. Every normal post-spawn path takes action lock before scheduler lock,
# so the stop transition follows the same ordering.
LAUNCH_ACTION_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_actions"
LAUNCH_ACTION_LOCK_ROOT="${EXECUTOR_SCHEDULER_ROOT}/launch_action_locks"
mkdir -p "${LAUNCH_ACTION_ROOT}" "${LAUNCH_ACTION_LOCK_ROOT}"
declare -a TARGET_ACTION_FILES=() TARGET_ACTION_JOB_IDS=() ACTION_LOCK_FDS=()
declare -a TARGET_CALLBACK_FILES=() CALLBACK_LOCK_FDS=()
shopt -s nullglob
all_action_files=("${LAUNCH_ACTION_ROOT}"/*.json)
shopt -u nullglob
for action_file in "${all_action_files[@]}"; do
  action_project="$(jq -er '.project | select(type == "string")' "${action_file}")" \
    || stop_failure "durable launch action is invalid"
  [ "${action_project}" = "${PROJECT_FULL}" ] || continue
  action_job_id="$(jq -er '.job_id | select(type == "string" and length > 0)' \
    "${action_file}")" || stop_failure "durable launch action is invalid"
  TARGET_ACTION_FILES+=("${action_file}")
  TARGET_ACTION_JOB_IDS+=("${action_job_id}")
done
if [ "${#TARGET_ACTION_JOB_IDS[@]}" -gt 0 ]; then
  IFS=$'\n' TARGET_ACTION_JOB_IDS=($(printf '%s\n' \
    "${TARGET_ACTION_JOB_IDS[@]}" | LC_ALL=C sort -u))
  unset IFS
fi
for action_job_id in "${TARGET_ACTION_JOB_IDS[@]}"; do
  action_digest="$(printf '%s' "${action_job_id}" | sha256_text)"
  if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ]; then
    exec {action_lock_fd}>"${LAUNCH_ACTION_ROOT}/.${action_digest}.lock"
    flock -x "${action_lock_fd}"
    ACTION_LOCK_FDS+=("${action_lock_fd}")
  fi
  exec {action_lock_fd}>"${LAUNCH_ACTION_LOCK_ROOT}/${action_digest}.lock"
  flock -x "${action_lock_fd}"
  ACTION_LOCK_FDS+=("${action_lock_fd}")
done

# Fence target I3 delivery before changing scheduler state. Callback delivery
# has its own per-event lock domain and may run before a normal tick acquires
# the global tick lock, so target locks must be held across the stop commit.
shopt -s nullglob
callback_files=("${CALLBACK_OUTBOX}"/*.json)
shopt -u nullglob
for callback_file in "${callback_files[@]}"; do
  callback_name="$(basename "${callback_file}" .json)"
  callback_digest="$(printf '%s' "${callback_name}" | scheduler_sha256_text)"
  callback_legacy_fd=""
  if [ "${LEGACY_LOCK_COMPAT_ACTIVE:-false}" = true ]; then
    exec {callback_legacy_fd}>"${CALLBACK_OUTBOX}/.${callback_name}.lock"
    flock -x "${callback_legacy_fd}"
  fi
  exec {callback_fd}>"${CALLBACK_LOCKS}/${callback_digest}.lock"
  flock -x "${callback_fd}"
  if [ ! -f "${callback_file}" ]; then
    flock -u "${callback_fd}"
    exec {callback_fd}>&-
    if [ -n "${callback_legacy_fd}" ]; then
      flock -u "${callback_legacy_fd}"
      exec {callback_legacy_fd}>&-
    fi
    continue
  fi
  callback_project="$(jq -er '.body.project | select(type == "string")' \
    "${callback_file}")" || stop_failure "durable callback outbox entry is invalid"
  if [ "${callback_project}" = "${PROJECT_FULL}" ]; then
    TARGET_CALLBACK_FILES+=("${callback_file}")
    [ -z "${callback_legacy_fd}" ] \
      || CALLBACK_LOCK_FDS+=("${callback_legacy_fd}")
    CALLBACK_LOCK_FDS+=("${callback_fd}")
  else
    flock -u "${callback_fd}"
    exec {callback_fd}>&-
    if [ -n "${callback_legacy_fd}" ]; then
      flock -u "${callback_legacy_fd}"
      exec {callback_legacy_fd}>&-
    fi
  fi
done

# Resolve, lock, and validate project-local state before the scheduler commit.
# Keeping this lock through the commit prevents a completion from publishing a
# fresh pending/handoff row between the scheduler fence and project cleanup.
REPO_PATH="$(PROJECT_FULL="${PROJECT_FULL}" \
  REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
  GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" GITLAB_HOST="${GITLAB_HOST}" \
  GITLAB_TOKEN="${GITLAB_TOKEN}" bash "${RESOLVE_REPO_CMD}")" \
  || stop_failure "unable to resolve repository state path"
CAMPAIGN_DIR="${REPO_PATH}/.req_executor/_dispatcher"
CAMPAIGN_STATE_FILE="${CAMPAIGN_DIR}/campaign_state.json"
CAMPAIGN_LOCK_FILE="${CAMPAIGN_DIR}/campaign.lock"
CAMPAIGN_STATE_PRESENT=false
PROJECT_CLEANUP_TARGETS='[]'
PROJECT_PENDING_IIDS='[]'
UPDATED_CAMPAIGN_STATE='null'
if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
  exec {STOP_CAMPAIGN_LOCK_FD}>"${CAMPAIGN_LOCK_FILE}"
  flock -x "${STOP_CAMPAIGN_LOCK_FD}"
  CAMPAIGN_STATE="$(jq -ce '
    if type == "object" and ((.pending_subagents // {}) | type == "object")
    then . else error("invalid campaign state") end
  ' "${CAMPAIGN_STATE_FILE}")" || stop_failure "campaign state is invalid"
  scheduler_atomic_write_json "${STOP_ARCHIVE_DIR}/campaign_state.before.json" \
    "${CAMPAIGN_STATE}"
  PROJECT_CLEANUP_TARGETS="$(jq -c '
    [(.pending_subagents // {})[]
      | .child_session_key // empty
      | select(type == "string" and length > 0)] | unique | sort
  ' <<<"${CAMPAIGN_STATE}")"
  PROJECT_PENDING_IIDS="$(jq -c '
    [(.pending_subagents // {}) | keys[] | tonumber] | unique | sort
  ' <<<"${CAMPAIGN_STATE}")"
  UPDATED_CAMPAIGN_STATE="$(jq -c \
    --arg stop_id "${STOP_ID}" --arg project "${PROJECT_FULL}" \
    --argjson stopped_at "${STOPPED_AT_EPOCH}" '
    .pending_subagents = {}
    | .active_issue_iids = []
    | .active_issue_sessions = []
    | .campaign_status = "running"
    | .quota_launched_this_tick = 0
    | del(.dispatch_owner,.driven_handoff_intents)
    | .mission_stop_history = ((.mission_stop_history // []) + [{
        version:1,stop_id:$stop_id,project:$project,stopped_at:$stopped_at
      }])
    | if (.mission_stop_history | length) > 20
      then .mission_stop_history = .mission_stop_history[-20:]
      else . end
  ' <<<"${CAMPAIGN_STATE}")"
  CAMPAIGN_STATE_PRESENT=true
fi

exec {STOP_SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${STOP_SCHEDULER_LOCK_FD}"
SCHEDULER_STATE="$(jq -ce '
  if type == "object" and .version == 1
    and (.active_jobs | type == "object")
    and (.batch_order | type == "array")
    and (has("pending_transaction") | not)
  then . else error("invalid scheduler state") end
' "${SCHEDULER_STATE_FILE}")" || stop_failure "scheduler state is invalid"
STOPPED_JOBS="$(jq -c --arg project "${PROJECT_FULL}" '
  [.active_jobs[] | select(.project == $project)]
  | sort_by(.reservation_seq // 0, .job_id)
' <<<"${SCHEDULER_STATE}")"
STOPPED_JOB_IDS="$(jq -c '[.[].job_id] | unique | sort' <<<"${STOPPED_JOBS}")"
STOPPED_ISSUE_IIDS="$(jq -c '[.[].iid] | unique | sort' <<<"${STOPPED_JOBS}")"

TARGET_BATCH_ORDER_IDS='[]'
STOPPED_BATCH_IDS='[]'
TRANSACTION_BATCH_STATES='{}'
while IFS= read -r batch_id; do
  [ -n "${batch_id}" ] || continue
  batch_dir="${BATCHES_ROOT}/${batch_id}"
  [ -f "${batch_dir}/request.json" ] && [ -f "${batch_dir}/state.json" ] \
    || stop_failure "registered batch is incomplete: ${batch_id}"
  batch_project="$(jq -er '.project | select(type == "string")' \
    "${batch_dir}/request.json")" || stop_failure "batch request is invalid: ${batch_id}"
  [ "${batch_project}" = "${PROJECT_FULL}" ] || continue
  TARGET_BATCH_ORDER_IDS="$(jq -c --arg batch_id "${batch_id}" \
    '. + [$batch_id] | unique | sort' <<<"${TARGET_BATCH_ORDER_IDS}")"
  batch_status="$(jq -er '
    .status | select(. == "queued" or . == "running" or . == "completed" or . == "failed")
  ' "${batch_dir}/state.json")" || stop_failure "batch state is invalid: ${batch_id}"
  case "${batch_status}" in
    completed|failed) continue ;;
  esac
  batch_state="$(jq -ce --arg batch_id "${batch_id}" \
    --arg project "${PROJECT_FULL}" --arg stop_id "${STOP_ID}" \
    --argjson stopped_at "${STOPPED_AT_EPOCH}" '
    if type == "object" and .version == 1 and .batch_id == $batch_id
      and (.memberships | type == "object")
    then
      .status = "failed"
      | .memberships |= with_entries(
          if (.value.status == "terminal" or .value.status == "skipped")
          then .
          else .value = (.value
            | .status = "skipped"
            | del(.job_id,.blocked_by_job_id,.terminal_status))
          end)
      | .terminal_counts_version = 1
      | .terminal_count = ([.memberships[]
          | select(.status == "terminal" or .status == "skipped")] | length)
      | .done_count = ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "done")] | length)
      | .failed_count = ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "failed")] | length)
      | .timeout_count = ([.memberships[]
          | select(.status == "terminal" and .terminal_status == "timeout")] | length)
      | .skipped_count = ([.memberships[]
          | select(.status == "skipped"
            or (.status == "terminal" and .terminal_status == "skipped"))] | length)
      | .mission_stop = {
          version:1,stop_id:$stop_id,project:$project,stopped_at:$stopped_at
        }
    else error("invalid batch state") end
  ' "${batch_dir}/state.json")" || stop_failure "batch state is invalid: ${batch_id}"
  TRANSACTION_BATCH_STATES="$(jq -c --arg batch_id "${batch_id}" \
    --argjson state "${batch_state}" '.[$batch_id] = $state' \
    <<<"${TRANSACTION_BATCH_STATES}")"
  STOPPED_BATCH_IDS="$(jq -c --arg batch_id "${batch_id}" \
    '. + [$batch_id] | unique | sort' <<<"${STOPPED_BATCH_IDS}")"
done < <(jq -r '.batch_order[]' <<<"${SCHEDULER_STATE}")

if ! jq -e --arg project "${PROJECT_FULL}" --argjson batches "${STOPPED_BATCH_IDS}" '
  [.active_jobs[] | select(.project == $project) | .memberships[].batch_id]
  | all(.[]; . as $batch_id | ($batches | index($batch_id)) != null)
' <<<"${SCHEDULER_STATE}" >/dev/null; then
  stop_failure "target job references a batch outside the repository runnable chain"
fi

FINAL_SCHEDULER_STATE="$(jq -c \
  --arg project "${PROJECT_FULL}" --argjson batches "${TARGET_BATCH_ORDER_IDS}" '
  .active_jobs |= with_entries(select(.value.project != $project))
  | .batch_order = [.batch_order[]
      | . as $batch_id | select(($batches | index($batch_id)) == null)]
  | .round_robin_cursor as $cursor
  | if $cursor != null
      and ($batches | index($cursor)) != null
    then .round_robin_cursor = null else . end
' <<<"${SCHEDULER_STATE}")"

if [ "$(jq -r 'length' <<<"${TRANSACTION_BATCH_STATES}")" -gt 0 ]; then
  TRANSACTION_STATE="$(jq -c \
    --arg stop_id "${STOP_ID}" --argjson scheduler_state "${FINAL_SCHEDULER_STATE}" \
    --argjson batch_states "${TRANSACTION_BATCH_STATES}" '
    .pending_transaction = {
      version:1,transaction_id:$stop_id,
      scheduler_state:$scheduler_state,batch_states:$batch_states
    }
  ' <<<"${SCHEDULER_STATE}")"
  scheduler_atomic_write_json "${SCHEDULER_STATE_FILE}" "${TRANSACTION_STATE}"
  while IFS= read -r changed_batch_id; do
    scheduler_atomic_write_json "${BATCHES_ROOT}/${changed_batch_id}/state.json" \
      "$(jq -c --arg batch_id "${changed_batch_id}" '.[$batch_id]' \
        <<<"${TRANSACTION_BATCH_STATES}")"
  done < <(jq -r 'keys[]' <<<"${TRANSACTION_BATCH_STATES}")
fi
scheduler_atomic_write_json "${SCHEDULER_STATE_FILE}" "${FINAL_SCHEDULER_STATE}"
flock -u "${STOP_SCHEDULER_LOCK_FD}"
exec {STOP_SCHEDULER_LOCK_FD}>&-

RUNTIME_LABELS='[]'
ACTION_CLEANUP_TARGETS='[]'
for action_file in "${TARGET_ACTION_FILES[@]}"; do
  [ -f "${action_file}" ] || continue
  action_json="$(jq -ce --arg project "${PROJECT_FULL}" '
    if type == "object" and .project == $project
    then . else error("launch action project changed") end
  ' "${action_file}")" || stop_failure "durable launch action changed during mission stop"
  RUNTIME_LABELS="$(jq -c --arg child_label "$(jq -r '.child_label // empty' <<<"${action_json}")" '
    if $child_label == "" then . else (. + [$child_label] | unique | sort) end
  ' <<<"${RUNTIME_LABELS}")"
  ACTION_CLEANUP_TARGETS="$(jq -c \
    --arg target "$(jq -r '.ack.child_session_key // empty' <<<"${action_json}")" '
    if $target == "" then . else (. + [$target] | unique | sort) end
  ' <<<"${ACTION_CLEANUP_TARGETS}")"
  mv "${action_file}" "${STOP_ARCHIVE_DIR}/launch_actions/$(basename "${action_file}")"
done

# A terminal result may already be waiting for dispatcher acknowledgement.
# Its event lock has remained held since before the scheduler transition.
mkdir -p "${STOP_ARCHIVE_DIR}/callback_outbox"
chmod 700 "${STOP_ARCHIVE_DIR}/callback_outbox"
for callback_file in "${TARGET_CALLBACK_FILES[@]}"; do
  if [ -f "${callback_file}" ]; then
    mv "${callback_file}" \
      "${STOP_ARCHIVE_DIR}/callback_outbox/$(basename "${callback_file}")"
  fi
done

for callback_lock_fd in "${CALLBACK_LOCK_FDS[@]}"; do
  flock -u "${callback_lock_fd}" 2>/dev/null || true
  exec {callback_lock_fd}>&-
done

for action_lock_fd in "${ACTION_LOCK_FDS[@]}"; do
  flock -u "${action_lock_fd}" 2>/dev/null || true
  exec {action_lock_fd}>&-
done

if [ "${CAMPAIGN_STATE_PRESENT}" = true ]; then
  scheduler_atomic_write_json "${CAMPAIGN_STATE_FILE}" "${UPDATED_CAMPAIGN_STATE}"
  flock -u "${STOP_CAMPAIGN_LOCK_FD}"
  exec {STOP_CAMPAIGN_LOCK_FD}>&-
fi
flock -u "${STOP_TICK_LOCK_FD}"
exec {STOP_TICK_LOCK_FD}>&-

CLEANUP_TARGETS="$(jq -cn \
  --argjson project_targets "${PROJECT_CLEANUP_TARGETS}" \
  --argjson action_targets "${ACTION_CLEANUP_TARGETS}" \
  '$project_targets + $action_targets | unique | sort')"
CLEANUP_ACTIONS="$(jq -c '[.[] | {action:"kill",target:.}]' \
  <<<"${CLEANUP_TARGETS}")"
STOPPED_ISSUE_IIDS="$(jq -cn --argjson scheduler "${STOPPED_ISSUE_IIDS}" \
  --argjson project "${PROJECT_PENDING_IIDS}" '$scheduler + $project | unique | sort')"

PUBLIC_RESULT="$(jq -cnS \
  --arg project "${PROJECT_FULL}" --arg stop_id "${STOP_ID}" \
  --argjson stopped_batch_ids "${STOPPED_BATCH_IDS}" \
  --argjson stopped_job_count "$(jq -r 'length' <<<"${STOPPED_JOB_IDS}")" \
  --argjson stopped_issue_iids "${STOPPED_ISSUE_IIDS}" \
  --argjson cleanup_requested_count "$(( \
    $(jq -r 'length' <<<"${CLEANUP_ACTIONS}") + \
    $(jq -r 'length' <<<"${RUNTIME_LABELS}") ))" '
  {
    status:"success",project:$project,stop_id:$stop_id,
    stopped_batch_ids:$stopped_batch_ids,
    stopped_job_count:$stopped_job_count,
    stopped_issue_iids:$stopped_issue_iids,
    cleanup_requested_count:$cleanup_requested_count
  }')"
scheduler_atomic_write_json "${STOP_ARCHIVE_DIR}/result.json" "${PUBLIC_RESULT}"

jq -cn \
  --argjson public_result "${PUBLIC_RESULT}" \
  --argjson cleanup_actions "${CLEANUP_ACTIONS}" \
  --argjson runtime_labels "${RUNTIME_LABELS}" '{
  status:"success",
  public_result:$public_result,
  cleanup_actions:$cleanup_actions,
  runtime_labels:$runtime_labels
}'
