#!/usr/bin/env bash
# Validate a RUN_DRIVEN_ISSUE_BATCH trigger, freeze its OPEN Issue membership,
# and atomically publish an idempotent executor batch.
set -euo pipefail

CREATE_BATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_BATCH_SKILL_DIR="$(cd "${CREATE_BATCH_SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${CREATE_BATCH_SKILL_DIR}/../.." && pwd)/config}"
GITLAB_HOST_PROCESS_SET="${GITLAB_HOST+x}"
GITLAB_HOST_PROCESS_OVERRIDE="${GITLAB_HOST:-}"
GITLAB_PROTOCOL_PROCESS_SET="${GITLAB_API_PROTOCOL+x}"
GITLAB_PROTOCOL_PROCESS_OVERRIDE="${GITLAB_API_PROTOCOL:-}"
GITLAB_LOCAL_TEST_MODE_PROCESS_SET="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE+x}"
GITLAB_LOCAL_TEST_MODE_PROCESS_OVERRIDE="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE:-}"
GITLAB_ALLOWED_HOSTS_PROCESS_SET="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS+x}"
GITLAB_ALLOWED_HOSTS_PROCESS_OVERRIDE="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS:-}"

batch_die() {
  echo "create_driven_batch.sh: $1" >&2
  exit "${2:-2}"
}

has_control_characters() {
  local value="$1"
  case "${value}" in
    *$'\r'*|*$'\t'*) return 0 ;;
  esac
  LC_ALL=C printf '%s' "${value}" | grep -q '[[:cntrl:]]'
}

require_field() {
  local name="$1"
  if [ "${TRIGGER_FIELDS[${name}]+x}" != x ]; then
    batch_die "missing trigger field: ${name}"
  fi
}

reject_field() {
  local name="$1"
  if [ "${TRIGGER_FIELDS[${name}]+x}" = x ]; then
    batch_die "selector_type=${SELECTOR_TYPE} does not accept ${name}"
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    batch_die "no SHA-256 command is available"
  fi
}

emit_success() {
  local batch_id="$1"
  local matched_count="$2"
  local snapshot_digest="$3"
  local scheduler_status="$4"

  jq -cn \
    --arg batch_id "${batch_id}" \
    --arg matched_count "${matched_count}" \
    --arg snapshot_digest "${snapshot_digest}" \
    --arg scheduler_status "${scheduler_status}" \
    '{
      status: "success",
      batch_id: $batch_id,
      matched_count: ($matched_count | tonumber),
      snapshot_digest: $snapshot_digest,
      scheduler_status: $scheduler_status
    }'
}

if ! IFS= read -r TRIGGER_NAME; then
  batch_die "missing trigger"
fi
[ "${TRIGGER_NAME}" = RUN_DRIVEN_ISSUE_BATCH ] || \
  batch_die "expected RUN_DRIVEN_ISSUE_BATCH trigger"

declare -A TRIGGER_FIELDS=()
while IFS= read -r trigger_line || [ -n "${trigger_line}" ]; do
  [ -n "${trigger_line}" ] || continue
  case "${trigger_line}" in
    *=*) ;;
    *) batch_die "invalid trigger line" ;;
  esac

  trigger_key="${trigger_line%%=*}"
  trigger_value="${trigger_line#*=}"
  case "${trigger_key}" in
    batch_id|correlation_id|project|selector_type|iid|iids|iid_min|iid_max|label|force_rerun_pr|auto_merge|dispatcher_callback_target|executor_agent|callback_nonce|branch|merge_target_branch)
      ;;
    *)
      batch_die "unsupported trigger field: ${trigger_key}"
      ;;
  esac
  if [ "${TRIGGER_FIELDS[${trigger_key}]+x}" = x ]; then
    batch_die "duplicate trigger field: ${trigger_key}"
  fi
  if has_control_characters "${trigger_value}"; then
    batch_die "trigger field contains control characters: ${trigger_key}"
  fi
  TRIGGER_FIELDS["${trigger_key}"]="${trigger_value}"
done

for required_name in \
  batch_id correlation_id project selector_type force_rerun_pr dispatcher_callback_target executor_agent callback_nonce
do
  require_field "${required_name}"
done

BATCH_ID="${TRIGGER_FIELDS[batch_id]}"
CORRELATION_ID="${TRIGGER_FIELDS[correlation_id]}"
PROJECT_FULL="${TRIGGER_FIELDS[project]}"
SELECTOR_TYPE="${TRIGGER_FIELDS[selector_type]}"
FORCE_RERUN_PR="${TRIGGER_FIELDS[force_rerun_pr]}"
AUTO_MERGE="${TRIGGER_FIELDS[auto_merge]:-false}"
CALLBACK_TARGET_INPUT="${TRIGGER_FIELDS[dispatcher_callback_target]}"
EXECUTOR_AGENT_INPUT="${TRIGGER_FIELDS[executor_agent]}"
CALLBACK_NONCE="${TRIGGER_FIELDS[callback_nonce]}"
BRANCH="${TRIGGER_FIELDS[branch]:-}"
MERGE_TARGET_BRANCH="${TRIGGER_FIELDS[merge_target_branch]:-}"

if ! [[ "${BATCH_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  batch_die "batch_id must be a safe path component"
fi
[ -n "${CORRELATION_ID}" ] || batch_die "correlation_id must not be empty"
[ -n "${CALLBACK_TARGET_INPUT}" ] \
  || batch_die "dispatcher_callback_target must not be empty"
[[ "${CALLBACK_NONCE}" =~ ^[0-9a-f]{64}$ ]] \
  || batch_die "callback_nonce must be exactly 64 lowercase hex characters"
if ! [[ "${PROJECT_FULL}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  batch_die "project must be <group>/<project>"
fi
case "${FORCE_RERUN_PR}" in
  true|false) ;;
  *) batch_die "force_rerun_pr must be true or false" ;;
esac
case "${AUTO_MERGE}" in
  true|false) ;;
  *) batch_die "auto_merge must be true or false" ;;
esac
validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*'`'*|*"'"*|*'"'*|*'<'*|*'>'*|*'!'*|*" "*|*$'\t'*|*$'\r'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != @ ]
}
if [ -n "${BRANCH}" ] && ! validate_branch_name "${BRANCH}"; then
  batch_die "branch must be a safe Git ref name"
fi
if [ -n "${MERGE_TARGET_BRANCH}" ] && ! validate_branch_name "${MERGE_TARGET_BRANCH}"; then
  batch_die "merge_target_branch must be a safe Git ref name"
fi
if [ "${AUTO_MERGE}" = true ] && [ -z "${MERGE_TARGET_BRANCH}" ]; then
  batch_die "merge_target_branch is required when auto_merge=true"
fi

case "${SELECTOR_TYPE}" in
  single)
    require_field iid
    reject_field iids
    reject_field iid_min
    reject_field iid_max
    reject_field label
    IID="${TRIGGER_FIELDS[iid]}"
    [[ "${IID}" =~ ^[1-9][0-9]*$ ]] || batch_die "iid must be a positive integer"
    SELECTOR_JSON="$(jq -cnS --arg iid "${IID}" '{type:"single",iid:($iid | tonumber)}')"
    ;;
  iid_list)
    require_field iids
    reject_field iid
    reject_field iid_min
    reject_field iid_max
    reject_field label
    IIDS="${TRIGGER_FIELDS[iids]}"
    [[ "${IIDS}" =~ ^[1-9][0-9]*(,[1-9][0-9]*)+$ ]] \
      || batch_die "iids must be a comma-separated list of positive integers"
    if ! SELECTOR_JSON="$(jq -Rce '
      split(",") | map(tonumber)
      | if length >= 2 and . == (sort | unique)
        then {type:"iid_list",iids:.}
        else error("iids must be sorted and unique")
        end
    ' <<<"${IIDS}")"; then
      batch_die "iids must contain at least two sorted unique positive integers"
    fi
    ;;
  range)
    require_field iid_min
    require_field iid_max
    reject_field iid
    reject_field iids
    reject_field label
    IID_MIN="${TRIGGER_FIELDS[iid_min]}"
    IID_MAX="${TRIGGER_FIELDS[iid_max]}"
    [[ "${IID_MIN}" =~ ^[1-9][0-9]*$ ]] || batch_die "iid_min must be a positive integer"
    [[ "${IID_MAX}" =~ ^[1-9][0-9]*$ ]] || batch_die "iid_max must be a positive integer"
    [ "${IID_MIN}" -le "${IID_MAX}" ] || batch_die "iid_min must be <= iid_max"
    SELECTOR_JSON="$(jq -cnS \
      --arg iid_min "${IID_MIN}" \
      --arg iid_max "${IID_MAX}" \
      '{type:"range",iid_min:($iid_min | tonumber),iid_max:($iid_max | tonumber)}')"
    ;;
  open_unfinished)
    reject_field iid
    reject_field iids
    reject_field iid_min
    reject_field iid_max
    reject_field label
    SELECTOR_JSON='{"type":"open_unfinished"}'
    ;;
  open_label)
    require_field label
    reject_field iid
    reject_field iids
    reject_field iid_min
    reject_field iid_max
    LABEL="${TRIGGER_FIELDS[label]}"
    if [ -z "${LABEL//[[:space:]]/}" ]; then
      batch_die "label must not be empty"
    fi
    SELECTOR_JSON="$(jq -cnS --arg label "${LABEL}" '{type:"open_label",label:$label}')"
    ;;
  *)
    batch_die "unsupported selector_type: ${SELECTOR_TYPE}"
    ;;
esac

# scheduler_env.sh loads the deployment-pinned agent and callback route before
# the request is frozen. Process/local overrides remain deployment controls;
# untrusted trigger fields must match them exactly.
# Resolve the complete GitLab tuple first; scheduler config may contain the
# ignored local tuple and must not be allowed to mix it with tracked values.
# shellcheck disable=SC1091
source "${CREATE_BATCH_SCRIPT_DIR}/gitlab_env_resolver.sh"
GITLAB_HOST_EFFECTIVE="${GITLAB_HOST}"
GITLAB_PROTOCOL_EFFECTIVE="${GITLAB_API_PROTOCOL}"
GITLAB_TOKEN_EFFECTIVE="${GITLAB_TOKEN}"
# shellcheck disable=SC1091
source "${CREATE_BATCH_SCRIPT_DIR}/scheduler_env.sh" >/dev/null
GITLAB_HOST="${GITLAB_HOST_EFFECTIVE}"
GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_EFFECTIVE}"
GITLAB_TOKEN="${GITLAB_TOKEN_EFFECTIVE}"
export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
if [ "${GITLAB_LOCAL_TEST_MODE_PROCESS_SET}" = x ]; then
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE="${GITLAB_LOCAL_TEST_MODE_PROCESS_OVERRIDE}"
fi
if [ "${GITLAB_ALLOWED_HOSTS_PROCESS_SET}" = x ]; then
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="${GITLAB_ALLOWED_HOSTS_PROCESS_OVERRIDE}"
fi
GITLAB_HOST_EFFECTIVE_SET=x
GITLAB_PROTOCOL_EFFECTIVE_SET=x
[ "${EXECUTOR_AGENT_INPUT}" = "${EXECUTOR_AGENT}" ] \
  || batch_die "executor_agent does not match the pinned executor"
PINNED_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET}"
[ "${CALLBACK_TARGET_INPUT}" = "${PINNED_CALLBACK_TARGET}" ] \
  || batch_die "dispatcher_callback_target does not match the deployment pin"

REQUEST_JSON="$(jq -cnS \
  --arg batch_id "${BATCH_ID}" \
  --arg correlation_id "${CORRELATION_ID}" \
  --arg project "${PROJECT_FULL}" \
  --argjson selector "${SELECTOR_JSON}" \
  --argjson force_rerun_pr "${FORCE_RERUN_PR}" \
  --argjson auto_merge "${AUTO_MERGE}" \
  --arg dispatcher_callback_target "${CALLBACK_TARGET_INPUT}" \
  --arg executor_agent "${EXECUTOR_AGENT_INPUT}" \
  --arg callback_nonce "${CALLBACK_NONCE}" \
  --arg branch "${BRANCH}" \
  --arg merge_target_branch "${MERGE_TARGET_BRANCH}" \
  '{
    version: 1,
    batch_id: $batch_id,
    correlation_id: $correlation_id,
    project: $project,
    selector: $selector,
    force_rerun_pr: $force_rerun_pr,
    auto_merge: $auto_merge,
    dispatcher_callback_target: $dispatcher_callback_target,
    executor_agent: $executor_agent,
    callback_nonce: $callback_nonce,
    branch: (if $branch == "" then null else $branch end),
    merge_target_branch: (if $merge_target_branch == "" then null else $merge_target_branch end)
  }')"
REQUEST_DIGEST="$(printf '%s' "${REQUEST_JSON}" | sha256_text)"

FAILED_INTAKE_ROOT="${EXECUTOR_SCHEDULER_ROOT}/failed-intake"
BATCH_LOCK_ROOT="${EXECUTOR_SCHEDULER_ROOT}/batch-locks"
mkdir -p "${FAILED_INTAKE_ROOT}" "${BATCH_LOCK_ROOT}"

exec {BATCH_LOCK_FD}>"${BATCH_LOCK_ROOT}/${BATCH_ID}.lock"
flock -x "${BATCH_LOCK_FD}"

BATCH_DIR="${BATCHES_ROOT}/${BATCH_ID}"
if [ -e "${BATCH_DIR}" ]; then
  [ -d "${BATCH_DIR}" ] || batch_die "existing batch path is not a directory" 3
  for persisted_name in request.json snapshot.json state.json; do
    [ -f "${BATCH_DIR}/${persisted_name}" ] || \
      batch_die "existing batch is incomplete: missing ${persisted_name}" 3
  done

  EXISTING_REQUEST_JSON="$(jq -ceS '
    if type == "object" then . else error("request must be an object") end
  ' "${BATCH_DIR}/request.json")" || \
    batch_die "existing request.json is invalid" 3
  EXISTING_REQUEST_DIGEST="$(printf '%s' "${EXISTING_REQUEST_JSON}" | sha256_text)"
  EXISTING_REQUEST_SEMANTIC="$(jq -cS '
    . + {
      auto_merge:(.auto_merge // false),
      merge_target_branch:(.merge_target_branch // null)
    }
  ' <<<"${EXISTING_REQUEST_JSON}")"
  [ "${EXISTING_REQUEST_SEMANTIC}" = "$(jq -cS . <<<"${REQUEST_JSON}")" ] || \
    batch_die "batch_id request conflict" 3
  # Keep the original digest for an old on-disk request that predates these
  # optional fields. State and public acceptance continue hashing raw bytes.
  REQUEST_DIGEST="${EXISTING_REQUEST_DIGEST}"

  EXISTING_SNAPSHOT_JSON="$(jq -ceS '
    if type == "object"
      and (.version == 1)
      and (.project | type == "string")
      and (.iids | type == "array")
      and (.iids | all(type == "number" and . == floor and . > 0))
    then .
    else error("snapshot shape is invalid")
    end
  ' "${BATCH_DIR}/snapshot.json")" || batch_die "existing snapshot.json is invalid" 3
  EXISTING_SNAPSHOT_DIGEST="$(printf '%s' "${EXISTING_SNAPSHOT_JSON}" | sha256_text)"

  EXISTING_STATE="$(jq -ce \
    --arg batch_id "${BATCH_ID}" \
    --arg request_digest "${REQUEST_DIGEST}" \
    --arg snapshot_digest "${EXISTING_SNAPSHOT_DIGEST}" \
    'if type == "object"
        and .batch_id == $batch_id
        and .request_digest == $request_digest
        and .snapshot_digest == $snapshot_digest
        and (.matched_count | type == "number")
        and (.status == "queued" or .status == "running" or .status == "completed")
     then .
     else error("batch state is invalid")
     end' \
    "${BATCH_DIR}/state.json")" || batch_die "existing batch state is invalid" 3

  exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
  flock -x "${SCHEDULER_LOCK_FD}"
  BATCH_ORDER_COUNT="$(jq -r --arg batch_id "${BATCH_ID}" \
    '[.batch_order[] | select(. == $batch_id)] | length' "${SCHEDULER_STATE_FILE}")"
  EXISTING_SCHEDULER_STATUS="$(jq -r '.status' <<<"${EXISTING_STATE}")"
  if [ "${EXISTING_SCHEDULER_STATUS}" = completed ]; then
    case "${BATCH_ORDER_COUNT}" in
      0) ;;
      1)
        COMPACTED_SCHEDULER_STATE="$(jq -c --arg batch_id "${BATCH_ID}" '
          .batch_order = [.batch_order[] | select(. != $batch_id)]
          | if .round_robin_cursor == $batch_id
            then .round_robin_cursor = null else . end
        ' "${SCHEDULER_STATE_FILE}")"
        COMPACTED_STATE_TMP="$(mktemp "${EXECUTOR_SCHEDULER_ROOT}/.scheduler_state.json.XXXXXX")"
        printf '%s' "${COMPACTED_SCHEDULER_STATE}" >"${COMPACTED_STATE_TMP}"
        mv "${COMPACTED_STATE_TMP}" "${SCHEDULER_STATE_FILE}"
        ;;
      *)
        flock -u "${SCHEDULER_LOCK_FD}"
        exec {SCHEDULER_LOCK_FD}>&-
        batch_die "completed batch scheduler registration is duplicated" 3
        ;;
    esac
  else
    case "${BATCH_ORDER_COUNT}" in
      0)
      RECOVERED_SCHEDULER_STATE="$(jq -c --arg batch_id "${BATCH_ID}" \
        '.batch_order += [$batch_id]' "${SCHEDULER_STATE_FILE}")" || {
        flock -u "${SCHEDULER_LOCK_FD}"
        exec {SCHEDULER_LOCK_FD}>&-
        batch_die "failed to recover existing batch scheduler registration" 3
      }
      RECOVERED_STATE_TMP="$(mktemp "${EXECUTOR_SCHEDULER_ROOT}/.scheduler_state.json.XXXXXX")"
      printf '%s' "${RECOVERED_SCHEDULER_STATE}" >"${RECOVERED_STATE_TMP}"
      if ! mv "${RECOVERED_STATE_TMP}" "${SCHEDULER_STATE_FILE}"; then
        mv \
          "${RECOVERED_STATE_TMP}" \
          "${FAILED_INTAKE_ROOT}/$(basename "${RECOVERED_STATE_TMP}")" 2>/dev/null || true
        flock -u "${SCHEDULER_LOCK_FD}"
        exec {SCHEDULER_LOCK_FD}>&-
        batch_die "failed to publish recovered scheduler registration" 3
      fi
        ;;
      1) ;;
      *)
        flock -u "${SCHEDULER_LOCK_FD}"
        exec {SCHEDULER_LOCK_FD}>&-
        batch_die "existing batch scheduler registration is duplicated" 3
        ;;
    esac
  fi
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-

  emit_success \
    "${BATCH_ID}" \
    "$(jq -r '.matched_count' <<<"${EXISTING_STATE}")" \
    "${EXISTING_SNAPSHOT_DIGEST}" \
    "$(jq -r '.status' <<<"${EXISTING_STATE}")"
  exit 0
fi

INTAKE_DIR="$(mktemp -d "${EXECUTOR_SCHEDULER_ROOT}/.batch-intake-${BATCH_ID}.XXXXXX")"
INTAKE_ACTIVE=true
INTAKE_FAILURE_REASON=intake_failed

retire_failed_intake() {
  local exit_status=$?
  local failed_destination=""
  trap - EXIT
  if [ "${INTAKE_ACTIVE}" = true ] && [ -d "${INTAKE_DIR}" ]; then
    jq -cn \
      --arg batch_id "${BATCH_ID}" \
      --arg reason "${INTAKE_FAILURE_REASON}" \
      '{status:"failed",batch_id:$batch_id,reason:$reason}' \
      >"${INTAKE_DIR}/failure.json" 2>/dev/null || \
      printf '%s\n' '{"status":"failed","reason":"intake_failed"}' >"${INTAKE_DIR}/failure.json"
    failed_destination="${FAILED_INTAKE_ROOT}/$(basename "${INTAKE_DIR}")"
    mv "${INTAKE_DIR}" "${failed_destination}" || true
  fi
  exit "${exit_status}"
}
trap retire_failed_intake EXIT

intake_fail() {
  INTAKE_FAILURE_REASON="$1"
  echo "create_driven_batch.sh: $2" >&2
  exit "${3:-2}"
}

printf '%s\n' "${REQUEST_JSON}" >"${INTAKE_DIR}/request.json"

# Run auth in a subprocess so sourcing the ignored local config cannot overwrite
# scheduler variables in this intake transaction.
INTAKE_FAILURE_REASON=gitlab_auth_failed
if ! AUTHENTICATED_HOST="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  GITLAB_HOST="${GITLAB_HOST_EFFECTIVE}" \
  GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_EFFECTIVE}" \
  GITLAB_TOKEN="${GITLAB_TOKEN_EFFECTIVE}" \
  GLAB_BIN="${GLAB_BIN:-glab}" \
  GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR:-}" \
    bash "${CREATE_BATCH_SCRIPT_DIR}/glab_auth.sh"
)"; then
  intake_fail gitlab_auth_failed "GitLab authentication failed"
fi
[ "${AUTHENTICATED_HOST}" = "${GITLAB_HOST_EFFECTIVE}" ] \
  || intake_fail gitlab_auth_target_changed \
    "GitLab auth changed the effective host"

ALL_ISSUES='[]'
PREVIOUS_FULL_SCAN=''
SNAPSHOT_STABLE=false
MAX_SNAPSHOT_SCANS=4
HARD_MAX_CURSOR_PAGES=1000
HARD_MAX_SNAPSHOT_NODES=100000
MAX_CURSOR_PAGES="${CREATE_BATCH_MAX_CURSOR_PAGES:-${HARD_MAX_CURSOR_PAGES}}"
MAX_SNAPSHOT_NODES="${CREATE_BATCH_MAX_SNAPSHOT_NODES:-${HARD_MAX_SNAPSHOT_NODES}}"
if ! [[ "${MAX_CURSOR_PAGES}" =~ ^[1-9][0-9]*$ ]] \
    || [ "${#MAX_CURSOR_PAGES}" -gt "${#HARD_MAX_CURSOR_PAGES}" ]; then
  intake_fail gitlab_cursor_limit_invalid \
    "GitLab cursor page limit must be a bounded positive integer"
fi
if ! [[ "${MAX_SNAPSHOT_NODES}" =~ ^[1-9][0-9]*$ ]] \
    || [ "${#MAX_SNAPSHOT_NODES}" -gt "${#HARD_MAX_SNAPSHOT_NODES}" ]; then
  intake_fail gitlab_snapshot_limit_invalid \
    "GitLab snapshot node limit must be a bounded positive integer"
fi
if [ "${MAX_CURSOR_PAGES}" -gt "${HARD_MAX_CURSOR_PAGES}" ]; then
  intake_fail gitlab_cursor_limit_invalid \
    "GitLab cursor page limit must be between 1 and ${HARD_MAX_CURSOR_PAGES}"
fi
if [ "${MAX_SNAPSHOT_NODES}" -gt "${HARD_MAX_SNAPSHOT_NODES}" ]; then
  intake_fail gitlab_snapshot_limit_invalid \
    "GitLab snapshot node limit must be between 1 and ${HARD_MAX_SNAPSHOT_NODES}"
fi
GRAPHQL_QUERY='query($fullPath: ID!, $after: String) {
  project(fullPath: $fullPath) {
    issues(first: 100, after: $after, state: opened, sort: created_asc) {
      nodes {
        iid
        state
        labels(first: 100) {
          nodes { title }
          pageInfo { hasNextPage }
        }
      }
      pageInfo { endCursor hasNextPage }
    }
  }
}'
SCAN_PAGES_FILE="${INTAKE_DIR}/normalized-issue-pages.jsonl"
snapshot_scan=1
while [ "${snapshot_scan}" -le "${MAX_SNAPSHOT_SCANS}" ]; do
  INTAKE_FAILURE_REASON="gitlab_scan_${snapshot_scan}_initialize_failed"
  if ! : >"${SCAN_PAGES_FILE}"; then
    intake_fail "${INTAKE_FAILURE_REASON}" \
      "failed to initialize GitLab Issue scan ${snapshot_scan} accumulator"
  fi
  cursor=''
  cursor_page=1
  snapshot_node_count=0
  declare -A SCAN_CURSORS=()
  while :; do
    # GitLab GraphQL connections have cursor/keyset semantics on old releases
    # that predate REST Issue keyset pagination. Every cursor is passed as a
    # separate CLI field, must advance exactly once, and the complete normalized
    # result must still agree with the immediately following full scan.
    if [ "${cursor_page}" -gt "${MAX_CURSOR_PAGES}" ]; then
      intake_fail gitlab_cursor_page_limit \
        "GitLab GraphQL Issue scan exceeded ${MAX_CURSOR_PAGES} cursor pages"
    fi
    GRAPHQL_ARGS=(
      api graphql
      -f "query=${GRAPHQL_QUERY}"
      -F "fullPath=${PROJECT_FULL}"
    )
    if [ -n "${cursor}" ]; then
      GRAPHQL_ARGS+=( -f "after=${cursor}" )
    fi
    INTAKE_FAILURE_REASON="gitlab_cursor_page_${cursor_page}_failed"
    if ! PAGE_JSON="$("${GLAB_BIN:-glab}" "${GRAPHQL_ARGS[@]}")"; then
      intake_fail "${INTAKE_FAILURE_REASON}" \
        "GitLab GraphQL Issue cursor page ${cursor_page} request failed"
    fi
    if ! ISSUE_CONNECTION="$(jq -ce '
      if type == "object"
        and ((.errors // []) | type == "array" and length == 0)
        and (.data | type == "object")
        and (.data.project | type == "object")
        and (.data.project.issues | type == "object")
        and (.data.project.issues.nodes | type == "array")
        and (.data.project.issues.pageInfo | type == "object")
        and (.data.project.issues.pageInfo.hasNextPage | type == "boolean")
        and ((.data.project.issues.pageInfo.endCursor == null)
          or (.data.project.issues.pageInfo.endCursor | type == "string"))
      then .data.project.issues else error("invalid Issue connection") end
    ' <<<"${PAGE_JSON}")"; then
      intake_fail "gitlab_cursor_page_${cursor_page}_invalid_connection" \
        "GitLab GraphQL Issue cursor page ${cursor_page} is invalid"
    fi
    if ! jq -e '
      all(.nodes[];
        (.labels.pageInfo | type == "object")
        and (.labels.pageInfo.hasNextPage | type == "boolean")
        and (.labels.pageInfo.hasNextPage == false))
    ' <<<"${ISSUE_CONNECTION}" >/dev/null; then
      intake_fail "gitlab_cursor_page_${cursor_page}_incomplete_labels" \
        "GitLab GraphQL Issue cursor page ${cursor_page} has an incomplete labels connection"
    fi
    if ! NORMALIZED_PAGE="$(jq -ce '
      def valid_iid:
        (type == "number" and . == floor and . > 0)
        or (type == "string" and test("^[1-9][0-9]*$"));
      if all(.nodes[];
          type == "object"
          and (.iid | valid_iid)
          and (.state | type == "string")
          and (.labels | type == "object")
          and (.labels.nodes | type == "array")
          and (all(.labels.nodes[];
            type == "object" and (.title | type == "string"))))
        then [.nodes[] | {
          iid:(.iid | tonumber),
          state:(.state | ascii_downcase),
          labels:(.labels.nodes | map(.title) | sort)
        }]
        else error("invalid Issue node") end
    ' <<<"${ISSUE_CONNECTION}")"; then
      intake_fail "gitlab_cursor_page_${cursor_page}_invalid_issue" \
        "GitLab GraphQL Issue cursor page ${cursor_page} contains an invalid Issue"
    fi
    if ! jq -e '
        ([.[].iid] | length) == ([.[].iid] | unique | length)
      ' <<<"${NORMALIZED_PAGE}" >/dev/null; then
      intake_fail gitlab_cursor_duplicate_iid \
        "GitLab GraphQL Issue cursor page ${cursor_page} repeats an IID"
    fi
    INTAKE_FAILURE_REASON="gitlab_cursor_page_${cursor_page}_accumulate_failed"
    if ! printf '%s\n' "${NORMALIZED_PAGE}" >>"${SCAN_PAGES_FILE}"; then
      intake_fail "${INTAKE_FAILURE_REASON}" \
        "failed to accumulate GitLab GraphQL Issue cursor page ${cursor_page}"
    fi
    page_node_count="$(jq -r 'length' <<<"${NORMALIZED_PAGE}")"
    snapshot_node_count=$((snapshot_node_count + page_node_count))
    if [ "${snapshot_node_count}" -gt "${MAX_SNAPSHOT_NODES}" ]; then
      intake_fail gitlab_snapshot_node_limit \
        "GitLab GraphQL Issue scan exceeded ${MAX_SNAPSHOT_NODES} nodes"
    fi
    HAS_NEXT_PAGE="$(jq -r '.pageInfo.hasNextPage' <<<"${ISSUE_CONNECTION}")"
    [ "${HAS_NEXT_PAGE}" = true ] || break
    NEXT_CURSOR="$(jq -r '.pageInfo.endCursor // empty' <<<"${ISSUE_CONNECTION}")"
    if [ -z "${NEXT_CURSOR}" ] \
        || has_control_characters "${NEXT_CURSOR}" \
        || [ "${#NEXT_CURSOR}" -gt 4096 ] \
        || ! [[ "${NEXT_CURSOR}" =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
      intake_fail gitlab_cursor_invalid \
        "GitLab GraphQL Issue cursor page ${cursor_page} has no safe next cursor"
    fi
    if [ "${NEXT_CURSOR}" = "${cursor}" ] \
        || [ "${SCAN_CURSORS[${NEXT_CURSOR}]+x}" = x ]; then
      intake_fail gitlab_cursor_not_advanced \
        "GitLab GraphQL Issue cursor did not advance at page ${cursor_page}"
    fi
    SCAN_CURSORS["${NEXT_CURSOR}"]=1
    cursor="${NEXT_CURSOR}"
    cursor_page=$((cursor_page + 1))
  done

  if ! CURRENT_FULL_SCAN="$(jq -cSse '
      [ .[][] ] as $merged
      | if ([ $merged[].iid ] | length)
          == ([ $merged[].iid ] | unique | length)
        then $merged | sort_by(.iid, .state, .labels)
        else error("duplicate IID across cursor pages") end
    ' "${SCAN_PAGES_FILE}")"; then
    intake_fail gitlab_cursor_duplicate_iid \
      "GitLab GraphQL Issue cursor pages repeat an IID"
  fi
  if [ "${snapshot_scan}" -gt 1 ] \
      && [ "${CURRENT_FULL_SCAN}" = "${PREVIOUS_FULL_SCAN}" ]; then
    ALL_ISSUES="${CURRENT_FULL_SCAN}"
    SNAPSHOT_STABLE=true
    break
  fi
  PREVIOUS_FULL_SCAN="${CURRENT_FULL_SCAN}"
  snapshot_scan=$((snapshot_scan + 1))
done

if [ "${SNAPSHOT_STABLE}" != true ]; then
  intake_fail gitlab_snapshot_unstable \
    "GitLab Issue list changed across ${MAX_SNAPSHOT_SCANS} consecutive full scans"
fi

INTAKE_FAILURE_REASON=selector_failed
MATCHED_IIDS="$(jq -cS \
  --arg selector_type "${SELECTOR_TYPE}" \
  --argjson selector "${SELECTOR_JSON}" \
  '
    def unfinished_terminal_label:
      . == "pr"
      or . == "finish"
      or . == "timeout"
      or . == "blocked"
      or startswith("blocked-")
      or . == "failed"
      or startswith("failed-");

    map(select(.state == "opened"))
    | sort_by(.iid)
    | unique_by(.iid)
    | map(select(
        if $selector_type == "single" then
          .iid == $selector.iid
        elif $selector_type == "iid_list" then
          .iid as $iid | ($selector.iids | index($iid)) != null
        elif $selector_type == "range" then
          .iid >= $selector.iid_min and .iid <= $selector.iid_max
        elif $selector_type == "open_unfinished" then
          ([.labels[] | select(unfinished_terminal_label)] | length) == 0
        elif $selector_type == "open_label" then
          (.labels | index($selector.label)) != null
        else
          false
        end))
    | map(.iid)
  ' <<<"${ALL_ISSUES}")" || intake_fail selector_failed "failed to select GitLab Issues"

SNAPSHOT_JSON="$(jq -cS \
  --arg project "${PROJECT_FULL}" \
  '{version:1,project:$project,iids:.}' <<<"${MATCHED_IIDS}")"
SNAPSHOT_DIGEST="$(printf '%s' "${SNAPSHOT_JSON}" | sha256_text)"
MATCHED_COUNT="$(jq -r 'length' <<<"${MATCHED_IIDS}")"
if [ "${MATCHED_COUNT}" -eq 0 ]; then
  SCHEDULER_STATUS=completed
else
  SCHEDULER_STATUS=queued
fi

STATE_JSON="$(jq -cnS \
  --arg batch_id "${BATCH_ID}" \
  --arg status "${SCHEDULER_STATUS}" \
  --arg matched_count "${MATCHED_COUNT}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  '{
    version: 1,
    terminal_counts_version: 1,
    batch_id: $batch_id,
    status: $status,
    matched_count: ($matched_count | tonumber),
    terminal_count: 0,
    done_count: 0,
    failed_count: 0,
    timeout_count: 0,
    skipped_count: 0,
    next_snapshot_index: 0,
    request_digest: $request_digest,
    snapshot_digest: $snapshot_digest,
    memberships: {}
  }')"

INTAKE_FAILURE_REASON=snapshot_persist_failed
if ! printf '%s\n' "${SNAPSHOT_JSON}" >"${SCAN_PAGES_FILE}"; then
  intake_fail snapshot_persist_failed "failed to write snapshot candidate"
fi
if ! mv "${SCAN_PAGES_FILE}" "${INTAKE_DIR}/snapshot.json"; then
  intake_fail snapshot_persist_failed "failed to publish snapshot candidate"
fi
printf '%s\n' "${STATE_JSON}" >"${INTAKE_DIR}/state.json"

for intake_name in request.json snapshot.json state.json; do
  jq -e . "${INTAKE_DIR}/${intake_name}" >/dev/null || \
    intake_fail invalid_persisted_json "failed to validate ${intake_name}"
done

# Publish the complete directory and register it while holding only the
# scheduler state lock. No GitLab or project operation happens under it.
exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"
if jq -e --arg batch_id "${BATCH_ID}" '.batch_order | index($batch_id) != null' \
  "${SCHEDULER_STATE_FILE}" >/dev/null; then
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  intake_fail stale_scheduler_registration "scheduler already contains batch_id without a batch directory" 3
fi

UPDATED_SCHEDULER_STATE="$(jq -c --arg batch_id "${BATCH_ID}" \
  --argjson matched_count "${MATCHED_COUNT}" '
    if $matched_count == 0 then . else .batch_order += [$batch_id] end
  ' "${SCHEDULER_STATE_FILE}")" || {
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  intake_fail scheduler_state_update_failed "failed to update scheduler state"
}
SCHEDULER_STATE_TMP="$(mktemp "${EXECUTOR_SCHEDULER_ROOT}/.scheduler_state.json.XXXXXX")"
printf '%s' "${UPDATED_SCHEDULER_STATE}" >"${SCHEDULER_STATE_TMP}"

INTAKE_FAILURE_REASON=atomic_publish_failed
if ! mv "${INTAKE_DIR}" "${BATCH_DIR}"; then
  mv "${SCHEDULER_STATE_TMP}" "${FAILED_INTAKE_ROOT}/$(basename "${SCHEDULER_STATE_TMP}")" || true
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  intake_fail atomic_publish_failed "failed to publish batch directory"
fi
INTAKE_ACTIVE=false

if ! mv "${SCHEDULER_STATE_TMP}" "${SCHEDULER_STATE_FILE}"; then
  PUBLISHED_FAILURE_DIR="${FAILED_INTAKE_ROOT}/published-${BATCH_ID}-$$-${RANDOM}"
  mv "${BATCH_DIR}" "${PUBLISHED_FAILURE_DIR}" || true
  if [ -e "${SCHEDULER_STATE_TMP}" ]; then
    mv "${SCHEDULER_STATE_TMP}" "${PUBLISHED_FAILURE_DIR}/scheduler_state.candidate.json" || true
  fi
  flock -u "${SCHEDULER_LOCK_FD}"
  exec {SCHEDULER_LOCK_FD}>&-
  batch_die "failed to publish scheduler state" 2
fi

flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-
trap - EXIT

emit_success "${BATCH_ID}" "${MATCHED_COUNT}" "${SNAPSHOT_DIGEST}" "${SCHEDULER_STATUS}"
