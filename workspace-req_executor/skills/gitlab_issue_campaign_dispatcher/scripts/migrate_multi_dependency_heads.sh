#!/usr/bin/env bash
# Aggregate two or more completed ordinary dependency Issues into the shared
# branch owned by the first dependency and the dependent Issue. The ordinary
# one-head migration remains the compatibility primitive; this wrapper adds a
# replayable fan-in checkpoint, a deterministic merge commit for every extra
# head, and one MR that closes every member of the fan-in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/git_network_guard.sh"

: "${MIGRATION_DEPENDENCY_IIDS_JSON:?}" "${MIGRATION_TAIL_IID:?}" \
  "${MIGRATION_TARGET_BRANCH:?}" "${REPO_PATH:?}" "${ISSUES_ROOT:?}" \
  "${WORK_ROOT:?}" "${PROJECT_FULL:?}" "${PROJECT_URI:?}"

DEPENDENCY_IIDS_JSON="$(jq -ce '
  if type == "array"
    and length >= 2 and length <= 8
    and all(.[]; type == "number" and . == floor and . > 0 and . <= 2147483647)
    and length == (unique | length)
  then . else error("invalid dependency IID list") end
' <<<"${MIGRATION_DEPENDENCY_IIDS_JSON}" 2>/dev/null)" || {
  echo "migrate_multi_dependency_heads: invalid dependency IID list" >&2
  exit 2
}
TAIL_IID="${MIGRATION_TAIL_IID}"
TARGET_BRANCH="${MIGRATION_TARGET_BRANCH}"
[[ "${TAIL_IID}" =~ ^[1-9][0-9]*$ ]] \
  && [ "${TAIL_IID}" -le 2147483647 ] || {
  echo "migrate_multi_dependency_heads: invalid tail IID" >&2
  exit 2
}
if jq -e --argjson tail "${TAIL_IID}" 'index($tail) != null' \
    <<<"${DEPENDENCY_IIDS_JSON}" >/dev/null; then
  echo "migrate_multi_dependency_heads: self dependency is not allowed" >&2
  exit 2
fi

ANCHOR_IID="$(jq -r '.[0]' <<<"${DEPENDENCY_IIDS_JSON}")"
NEW_BRANCH="issue/${ANCHOR_IID}+${TAIL_IID}"
ANCHOR_STATE_FILE="${ISSUES_ROOT}/issue-${ANCHOR_IID}/state.json"
MIGRATION_DIR="${WORK_ROOT}/migrations/${ANCHOR_IID}+${TAIL_IID}/fan-in"
LOCK_FILE="${WORK_ROOT}/locks/shared-fan-in-${ANCHOR_IID}-${TAIL_IID}.lock"
VERIFY_TIMEOUT="${SHARED_MIGRATION_VERIFY_TIMEOUT_SECONDS:-120}"

[[ "${VERIFY_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] \
  && [ "${VERIFY_TIMEOUT}" -le 600 ] || {
  echo "migrate_multi_dependency_heads: invalid verification timeout" >&2
  exit 2
}
GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
  check-ref-format --branch "${TARGET_BRANCH}" >/dev/null 2>&1 || {
  echo "migrate_multi_dependency_heads: invalid target branch" >&2
  exit 2
}
for command_name in timeout glab jq od git flock; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "migrate_multi_dependency_heads: ${command_name} is required" >&2
    exit 2
  }
done

mkdir -p "${WORK_ROOT}/locks" "${MIGRATION_DIR}"
chmod 700 "${MIGRATION_DIR}"
for trusted_path in "${WORK_ROOT}/locks" "${MIGRATION_DIR}"; do
  [ ! -L "${trusted_path}" ] || {
    echo "migrate_multi_dependency_heads: trusted runtime path is a symlink" >&2
    exit 2
  }
done
[ ! -L "${LOCK_FILE}" ] || exit 2
exec {MIGRATION_LOCK_FD}>"${LOCK_FILE}"
chmod 600 "${LOCK_FILE}"
flock -x "${MIGRATION_LOCK_FD}"

private_file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  else
    return 1
  fi
}

private_file_owner() {
  local owner
  if owner="$(stat -c '%u' "$1" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  elif owner="$(stat -f '%u' "$1" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  else
    return 1
  fi
}

read_issue_state() {
  local iid="$1" state_file bytes
  state_file="${ISSUES_ROOT}/issue-${iid}/state.json"
  [ -f "${state_file}" ] && [ ! -L "${state_file}" ] || return 1
  [ "$(private_file_mode "${state_file}")" = 600 ] || return 1
  [ "$(private_file_owner "${state_file}")" = "$(id -u)" ] || return 1
  bytes="$(wc -c <"${state_file}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] && [ "${bytes}" -le 65536 ] \
    || return 1
  jq -ce 'if type == "object" then . else error("invalid state") end' \
    "${state_file}" 2>/dev/null
}

store_issue_state() {
  local iid="$1" state_json="$2" state_file state_tmp
  state_file="${ISSUES_ROOT}/issue-${iid}/state.json"
  [ -d "$(dirname "${state_file}")" ] && [ ! -L "$(dirname "${state_file}")" ] \
    || return 1
  state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
  if ! jq -ce 'if type == "object" then . else error("invalid state") end' \
      <<<"${state_json}" >"${state_tmp}"; then
    return 1
  fi
  chmod 600 "${state_tmp}"
  mv "${state_tmp}" "${state_file}"
}

emit_status() {
  local status="$1" reason="$2"
  jq -nc \
    --arg status "${status}" \
    --arg reason "${reason}" \
    --argjson head_iid "${ANCHOR_IID}" \
    --argjson tail_iid "${TAIL_IID}" \
    --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
    --arg work_branch "${NEW_BRANCH}" '{
      status:$status,reason:$reason,head_iid:$head_iid,tail_iid:$tail_iid,
      dependency_iids:$dependency_iids,work_branch:$work_branch
    }'
}

defer_migration() {
  emit_status deferred "$1"
  exit 75
}

terminal_migration_failure() {
  local reason="$1" now anchor_state failed_state
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if anchor_state="$(read_issue_state "${ANCHOR_IID}" 2>/dev/null)" \
      && jq -e '.dependency_aggregation | type == "object"' \
        <<<"${anchor_state}" >/dev/null 2>&1; then
    failed_state="$(jq -c \
      --arg reason "${reason}" --arg failed_at "${now}" '
      .dependency_aggregation.status = "failed"
      | .dependency_aggregation.failure_reason = $reason
      | .dependency_aggregation.failed_at = $failed_at
    ' <<<"${anchor_state}")"
    store_issue_state "${ANCHOR_IID}" "${failed_state}" || true
  fi
  emit_status failed "${reason}"
  exit 6
}

api_get() {
  timeout --kill-after=5s "${VERIFY_TIMEOUT}s" glab api "$1" 2>/dev/null
}

read_remote_ref() {
  local branch="$1" rows rc tips count sha
  set +e
  rows="$(git_network_guard_run "${REPO_PATH}" \
    ls-remote --exit-code --heads origin "${branch}" 2>/dev/null)"
  rc=$?
  set -e
  case "${rc}" in 0|2) ;; *) return 1 ;; esac
  tips="$(awk -v expected="refs/heads/${branch}" \
    '$2 == expected {print $1}' <<<"${rows}")"
  count="$(awk 'NF {n++} END {print n+0}' <<<"${tips}")"
  [ "${count}" -le 1 ] || return 2
  sha="$(awk 'NF {print; exit}' <<<"${tips}")"
  if [ "${count}" -eq 0 ]; then
    jq -nc '{found:false,sha:""}'
  elif [[ "${sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
    jq -nc --arg sha "${sha}" '{found:true,sha:$sha}'
  else
    return 2
  fi
}

read_open_source_mrs() {
  local branch="$1" encoded response
  encoded="$(jq -rn --arg value "${branch}" '$value | @uri')" || return 2
  response="$(api_get \
    "projects/${PROJECT_URI}/merge_requests?scope=all&state=opened&source_branch=${encoded}&per_page=100")" \
    || return 1
  jq -ce --arg source_branch "${branch}" '
    if type == "array" and length <= 100
      and all(.[];
        type == "object"
        and (.iid | type == "number" and . == floor and . > 0)
        and (.web_url | type == "string" and length > 0)
        and .source_branch == $source_branch
        and .state == "opened")
    then . else error("invalid open MR list") end
  ' <<<"${response}" 2>/dev/null || return 2
}

require_unique_open_mr() {
  local branch="$1" iid="$2" url="$3" rows rc
  set +e
  rows="$(read_open_source_mrs "${branch}")"
  rc=$?
  set -e
  case "${rc}" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  jq -e --argjson iid "${iid}" --arg url "${url}" '
    length == 1 and .[0].iid == $iid and .[0].web_url == $url
  ' <<<"${rows}" >/dev/null 2>&1 || return 2
}

require_no_open_mr() {
  local branch="$1" rows rc
  set +e
  rows="$(read_open_source_mrs "${branch}")"
  rc=$?
  set -e
  case "${rc}" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  jq -e 'length == 0' <<<"${rows}" >/dev/null 2>&1 || return 2
}

validate_source_mr() {
  local mr_json="$1" source_json="$2" expected_state="$3"
  local source_iid source_branch source_sha source_mr_iid source_mr_url
  source_iid="$(jq -r '.iid' <<<"${source_json}")"
  source_branch="$(jq -r '.branch' <<<"${source_json}")"
  source_sha="$(jq -r '.commit_sha' <<<"${source_json}")"
  source_mr_iid="$(jq -r '.mr_iid' <<<"${source_json}")"
  source_mr_url="$(jq -r '.mr_url' <<<"${source_json}")"
  jq -e \
    --argjson iid "${source_mr_iid}" \
    --arg url "${source_mr_url}" \
    --arg source "${source_branch}" \
    --arg target "${TARGET_BRANCH}" \
    --arg state "${expected_state}" \
    --arg sha "${source_sha}" \
    --arg author "${GITLAB_USERNAME}" \
    --arg closes "Closes #${source_iid}" '
    type == "object"
    and .iid == $iid and .web_url == $url
    and .source_branch == $source and .target_branch == $target
    and .state == $state
    and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
    and .author.username == $author
    and (.description | type == "string")
    and ((.description | split("\n")) | index($closes) != null)
  ' <<<"${mr_json}" >/dev/null 2>&1
}

ensure_commit_object() {
  local branch="$1" sha="$2"
  if GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" cat-file -e \
      "${sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  git_network_guard_run "${REPO_PATH}" fetch --no-tags origin \
    "refs/heads/${branch}:refs/remotes/origin/${branch}" >/dev/null 2>&1 \
    || return 1
  GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" cat-file -e \
    "${sha}^{commit}" 2>/dev/null
}

build_aggregate_commit() {
  local sources_json="$1" started_at="$2" aggregate_sha next_iid next_sha
  local merge_output merge_rc tree_sha commit_message
  aggregate_sha="$(jq -r '.[0].commit_sha' <<<"${sources_json}")"
  while IFS= read -r next_source; do
    next_iid="$(jq -r '.iid' <<<"${next_source}")"
    next_sha="$(jq -r '.commit_sha' <<<"${next_source}")"
    set +e
    merge_output="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
      merge-tree --write-tree "${aggregate_sha}" "${next_sha}" 2>/dev/null)"
    merge_rc=$?
    set -e
    [ "${merge_rc}" -eq 0 ] || return 1
    tree_sha="$(awk 'NR == 1 {print $1}' <<<"${merge_output}")"
    [[ "${tree_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
      || return 2
    commit_message="Merge dependency Issue #${next_iid} for Issue #${TAIL_IID}"
    aggregate_sha="$(
      GIT_AUTHOR_NAME=req-executor \
      GIT_AUTHOR_EMAIL=req-executor@localhost \
      GIT_AUTHOR_DATE="${started_at}" \
      GIT_COMMITTER_NAME=req-executor \
      GIT_COMMITTER_EMAIL=req-executor@localhost \
      GIT_COMMITTER_DATE="${started_at}" \
      GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" commit-tree \
        "${tree_sha}" -p "${aggregate_sha}" -p "${next_sha}" \
        <<<"${commit_message}"
    )" || return 2
    [[ "${aggregate_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
      || return 2
  done < <(jq -c '.[1:][]' <<<"${sources_json}")
  while IFS= read -r source_sha; do
    GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" merge-base --is-ancestor \
      "${source_sha}" "${aggregate_sha}" >/dev/null 2>&1 || return 2
  done < <(jq -r '.[].commit_sha' <<<"${sources_json}")
  printf '%s\n' "${aggregate_sha}"
}

git_network_guard_assert_repo "${REPO_PATH}"

set +e
GITLAB_USERNAME="$(api_get user | jq -er \
  '.username | select(type == "string" and length > 0 and length <= 255)' \
  2>/dev/null)"
principal_rc=$?
set -e
[ "${principal_rc}" -eq 0 ] || defer_migration gitlab_principal_unavailable

ANCHOR_STATE_JSON="$(read_issue_state "${ANCHOR_IID}")" \
  || terminal_migration_failure dependency_anchor_state_missing_or_unsafe
AGGREGATION_STATUS="$(jq -r '.dependency_aggregation.status // ""' \
  <<<"${ANCHOR_STATE_JSON}")"
if [ "${AGGREGATION_STATUS}" = failed ]; then
  emit_status failed "$(jq -r \
    '.dependency_aggregation.failure_reason // "dependency_aggregation_failed"' \
    <<<"${ANCHOR_STATE_JSON}")"
  exit 6
fi

if [ -z "${AGGREGATION_STATUS}" ]; then
  SOURCES_JSON='[]'
  while IFS= read -r source_iid; do
    source_branch="issue/${source_iid}"
    source_state="$(read_issue_state "${source_iid}")" \
      || terminal_migration_failure dependency_source_state_missing_or_unsafe
    source_identity="$(jq -ce \
      --argjson iid "${source_iid}" --arg branch "${source_branch}" '
      if .iid == $iid and .status == "done"
        and .work_branch == $branch and .branch_members == [$iid]
        and (.shared_branch_role // null) == null
        and (.dependency_iid // null) == null
        and (.dependency_branch // null) == null
        and (.dependency_base_sha // null) == null
        and (.commit_sha | type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
        and .work_branch_sha == .commit_sha
        and .dependency_history_verified == true
        and (.latest_execution_id | type == "number" and . == floor and . > 0)
        and .dependency_pinned_execution_id == .latest_execution_id
        and (.merge_request_url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
      then {
        iid:$iid,branch:$branch,commit_sha:.commit_sha,
        source_execution_id:.latest_execution_id,mr_url:.merge_request_url
      } else error("ordinary dependency source is not aggregation-safe") end
    ' <<<"${source_state}" 2>/dev/null)" \
      || terminal_migration_failure dependency_source_not_aggregation_safe
    source_mr_url="$(jq -r '.mr_url' <<<"${source_identity}")"
    if [[ "${source_mr_url}" =~ /-/merge_requests/([1-9][0-9]*)/?$ ]]; then
      source_mr_iid="${BASH_REMATCH[1]}"
    else
      terminal_migration_failure dependency_source_mr_url_invalid
    fi
    source_identity="$(jq -c --argjson mr_iid "${source_mr_iid}" \
      '. + {mr_iid:$mr_iid}' <<<"${source_identity}")"
    source_ref="$(read_remote_ref "${source_branch}")" \
      || defer_migration dependency_source_branch_lookup_unavailable
    [ "$(jq -r '.found' <<<"${source_ref}")" = true ] \
      && [ "$(jq -r '.sha' <<<"${source_ref}")" = \
        "$(jq -r '.commit_sha' <<<"${source_identity}")" ] \
      || terminal_migration_failure dependency_source_branch_commit_mismatch
    ensure_commit_object "${source_branch}" \
      "$(jq -r '.commit_sha' <<<"${source_identity}")" \
      || defer_migration dependency_source_fetch_unavailable
    source_mr="$(api_get \
      "projects/${PROJECT_URI}/merge_requests/${source_mr_iid}")" \
      || defer_migration dependency_source_mr_lookup_unavailable
    validate_source_mr "${source_mr}" "${source_identity}" opened \
      || terminal_migration_failure dependency_source_mr_identity_mismatch
    set +e
    require_unique_open_mr "${source_branch}" "${source_mr_iid}" "${source_mr_url}"
    unique_rc=$?
    set -e
    case "${unique_rc}" in
      0) ;;
      1) defer_migration dependency_source_mr_list_unavailable ;;
      *) terminal_migration_failure dependency_source_mr_not_unique ;;
    esac
    SOURCES_JSON="$(jq -cn --argjson sources "${SOURCES_JSON}" \
      --argjson source "${source_identity}" '$sources + [$source]')"
  done < <(jq -r '.[]' <<<"${DEPENDENCY_IIDS_JSON}")

  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  AGGREGATE_SHA="$(build_aggregate_commit "${SOURCES_JSON}" "${STARTED_AT}")"
  aggregate_rc=$?
  set -e
  case "${aggregate_rc}" in
    0) ;;
    1) terminal_migration_failure dependency_merge_conflict ;;
    *) terminal_migration_failure dependency_merge_commit_failed ;;
  esac
  CHECKPOINT_STATE="$(jq -ce \
    --argjson anchor "${ANCHOR_IID}" \
    --argjson tail "${TAIL_IID}" \
    --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
    --argjson sources "${SOURCES_JSON}" \
    --arg work_branch "${NEW_BRANCH}" \
    --arg target_branch "${TARGET_BRANCH}" \
    --arg aggregate_sha "${AGGREGATE_SHA}" \
    --arg started_at "${STARTED_AT}" '
    .dependency_aggregation = {
      version:1,status:"pending",anchor_iid:$anchor,tail_iid:$tail,
      dependency_iids:$dependency_iids,sources:$sources,
      work_branch:$work_branch,target_branch:$target_branch,
      aggregate_sha:$aggregate_sha,started_at:$started_at
    }
  ' <<<"${ANCHOR_STATE_JSON}")"
  store_issue_state "${ANCHOR_IID}" "${CHECKPOINT_STATE}" \
    || defer_migration dependency_aggregation_checkpoint_write_failed
  ANCHOR_STATE_JSON="${CHECKPOINT_STATE}"
  AGGREGATION_STATUS=pending
fi

CHECKPOINT_JSON="$(jq -ce \
  --argjson anchor "${ANCHOR_IID}" \
  --argjson tail "${TAIL_IID}" \
  --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
  --arg work_branch "${NEW_BRANCH}" \
  --arg target_branch "${TARGET_BRANCH}" '
  .dependency_aggregation
  | if type == "object" and .version == 1
    and (.status == "pending" or .status == "completed")
    and .anchor_iid == $anchor and .tail_iid == $tail
    and .dependency_iids == $dependency_iids
    and .work_branch == $work_branch and .target_branch == $target_branch
    and (.aggregate_sha | type == "string"
      and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
    and (.started_at | type == "string" and length > 0)
    and (.sources | type == "array" and length == ($dependency_iids | length))
    and ([.sources[].iid] == $dependency_iids)
    and all(.sources[];
      (.iid | type == "number" and . == floor and . > 0)
      and .branch == ("issue/" + (.iid | tostring))
      and (.commit_sha | type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      and (.source_execution_id | type == "number" and . == floor and . > 0)
      and (.mr_iid | type == "number" and . == floor and . > 0)
      and (.mr_url | type == "string" and length > 0))
  then . else error("invalid dependency aggregation checkpoint") end
' <<<"${ANCHOR_STATE_JSON}" 2>/dev/null)" \
  || terminal_migration_failure dependency_aggregation_checkpoint_invalid
SOURCES_JSON="$(jq -c '.sources' <<<"${CHECKPOINT_JSON}")"
AGGREGATE_SHA="$(jq -r '.aggregate_sha' <<<"${CHECKPOINT_JSON}")"
ANCHOR_SOURCE_SHA="$(jq -r '.sources[0].commit_sha' <<<"${CHECKPOINT_JSON}")"

# The ordinary migration closes the anchor-only MR and creates the stable
# shared MR. A pending aggregation checkpoint is deliberately tolerated by the
# ordinary migration's state validator.
if ! jq -e \
    --arg branch "${NEW_BRANCH}" --argjson anchor "${ANCHOR_IID}" '
    .work_branch == $branch and .shared_branch_role == "head"
      and .iid == $anchor and .branch_migration.status == "completed"
  ' <<<"${ANCHOR_STATE_JSON}" >/dev/null 2>&1; then
  set +e
  head_migration_output="$(
    MIGRATION_HEAD_IID="${ANCHOR_IID}" \
    MIGRATION_TAIL_IID="${TAIL_IID}" \
    MIGRATION_TARGET_BRANCH="${TARGET_BRANCH}" \
    timeout --kill-after=30s 600s \
      bash "${SCRIPT_DIR}/migrate_shared_dependency_head.sh"
  )"
  head_migration_rc=$?
  set -e
  if [ "${head_migration_rc}" -eq 75 ] \
      || [ "${head_migration_rc}" -eq 124 ] \
      || [ "${head_migration_rc}" -eq 137 ]; then
    defer_migration dependency_anchor_migration_pending
  fi
  if [ "${head_migration_rc}" -ne 0 ] \
      || ! jq -e --argjson head "${ANCHOR_IID}" \
        --argjson tail "${TAIL_IID}" --arg branch "${NEW_BRANCH}" \
        --arg sha "${ANCHOR_SOURCE_SHA}" '
        .status == "ready" and .head_iid == $head and .tail_iid == $tail
        and .work_branch == $branch
        and ((.commit_sha | ascii_downcase) == ($sha | ascii_downcase))
      ' <<<"${head_migration_output}" >/dev/null 2>&1; then
    terminal_migration_failure dependency_anchor_migration_failed
  fi
  ANCHOR_STATE_JSON="$(read_issue_state "${ANCHOR_IID}")" \
    || defer_migration dependency_anchor_state_reload_failed
fi

SHARED_IDENTITY="$(jq -ce \
  --argjson anchor "${ANCHOR_IID}" --argjson tail "${TAIL_IID}" \
  --arg branch "${NEW_BRANCH}" --arg target "${TARGET_BRANCH}" \
  --arg source_sha "${ANCHOR_SOURCE_SHA}" --arg aggregate_sha "${AGGREGATE_SHA}" '
  if .iid == $anchor and .status == "done"
    and .work_branch == $branch and .branch_members == [$anchor,$tail]
    and .shared_branch_role == "head"
    and (((.commit_sha | ascii_downcase) == ($source_sha | ascii_downcase))
      or ((.commit_sha | ascii_downcase) == ($aggregate_sha | ascii_downcase)))
    and .branch_migration.status == "completed"
    and (.mr_finalization | type == "object")
    and .mr_finalization.status == "verified_open"
    and .mr_finalization.work_branch == $branch
    and .mr_finalization.target_branch == $target
    and ((.mr_finalization.commit_sha | ascii_downcase)
      == (.commit_sha | ascii_downcase))
    and (.mr_finalization.intent_id | type == "string"
      and test("^[0-9a-f]{64}$"))
    and (.mr_finalization.iid | type == "number" and . > 0)
    and (.mr_finalization.web_url | type == "string" and length > 0)
  then {
    mr_iid:.mr_finalization.iid,mr_url:.mr_finalization.web_url,
    intent_id:.mr_finalization.intent_id,
    source_execution_id:.mr_finalization.source_execution_id
  } else error("shared anchor identity mismatch") end
' <<<"${ANCHOR_STATE_JSON}" 2>/dev/null)" \
  || terminal_migration_failure dependency_anchor_shared_identity_mismatch
SHARED_MR_IID="$(jq -r '.mr_iid' <<<"${SHARED_IDENTITY}")"
SHARED_MR_URL="$(jq -r '.mr_url' <<<"${SHARED_IDENTITY}")"
SHARED_INTENT_ID="$(jq -r '.intent_id' <<<"${SHARED_IDENTITY}")"

shared_ref="$(read_remote_ref "${NEW_BRANCH}")" \
  || defer_migration aggregate_branch_lookup_unavailable
[ "$(jq -r '.found' <<<"${shared_ref}")" = true ] \
  || terminal_migration_failure aggregate_branch_missing
shared_sha="$(jq -r '.sha' <<<"${shared_ref}")"
if [ "${shared_sha,,}" = "${ANCHOR_SOURCE_SHA,,}" ]; then
  set +e
  git_network_guard_run "${REPO_PATH}" push --porcelain \
    "--force-with-lease=refs/heads/${NEW_BRANCH}:${ANCHOR_SOURCE_SHA}" \
    origin "${AGGREGATE_SHA}:refs/heads/${NEW_BRANCH}" >/dev/null 2>&1
  aggregate_push_rc=$?
  set -e
  shared_ref="$(read_remote_ref "${NEW_BRANCH}")" \
    || defer_migration aggregate_branch_confirmation_unavailable
  shared_sha="$(jq -r '.sha' <<<"${shared_ref}")"
  if [ "${shared_sha,,}" != "${AGGREGATE_SHA,,}" ]; then
    [ "${aggregate_push_rc}" -eq 0 ] \
      || defer_migration aggregate_branch_push_unconfirmed
    terminal_migration_failure aggregate_branch_push_mismatch
  fi
elif [ "${shared_sha,,}" != "${AGGREGATE_SHA,,}" ]; then
  terminal_migration_failure aggregate_branch_moved
fi
GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" update-ref \
  "refs/remotes/origin/${NEW_BRANCH}" "${AGGREGATE_SHA}"

DESCRIPTION_FILE="${MIGRATION_DIR}/mr_description.md"
[ ! -L "${DESCRIPTION_FILE}" ] \
  || terminal_migration_failure aggregation_description_symlink
DESCRIPTION_TMP="$(mktemp "${DESCRIPTION_FILE}.tmp.XXXXXX")"
{
  while IFS= read -r dependency_iid; do
    printf 'Closes #%s\n' "${dependency_iid}"
  done < <(jq -r '.[]' <<<"${DEPENDENCY_IIDS_JSON}")
  printf 'Closes #%s\n' "${TAIL_IID}"
  printf '<!-- req_executor-shared-mr-intent:%s -->\n\n' "${SHARED_INTENT_ID}"
  printf 'Auto-generated shared MR for dependency Issues '
  jq -r 'map("#" + tostring) | join(", ")' <<<"${DEPENDENCY_IIDS_JSON}"
  printf ' and dependent Issue #%s.\n\n' "${TAIL_IID}"
  printf 'Do not merge until reviewed.\n'
} >"${DESCRIPTION_TMP}"
chmod 600 "${DESCRIPTION_TMP}"
mv "${DESCRIPTION_TMP}" "${DESCRIPTION_FILE}"
DESIRED_DESCRIPTION="$(cat "${DESCRIPTION_FILE}")"

shared_mr="$(api_get \
  "projects/${PROJECT_URI}/merge_requests/${SHARED_MR_IID}")" \
  || defer_migration aggregate_mr_lookup_unavailable
if ! jq -e \
    --argjson iid "${SHARED_MR_IID}" --arg url "${SHARED_MR_URL}" \
    --arg source "${NEW_BRANCH}" --arg target "${TARGET_BRANCH}" \
    --arg sha "${AGGREGATE_SHA}" --arg author "${GITLAB_USERNAME}" \
    --arg intent "${SHARED_INTENT_ID}" '
    .iid == $iid and .web_url == $url and .source_branch == $source
    and .target_branch == $target and .state == "opened"
    and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
    and .author.username == $author
    and (.description | type == "string"
      and contains("<!-- req_executor-shared-mr-intent:" + $intent + " -->"))
  ' <<<"${shared_mr}" >/dev/null 2>&1; then
  defer_migration aggregate_mr_sha_not_observable
fi
if ! jq -e --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
    --argjson tail "${TAIL_IID}" --arg intent "${SHARED_INTENT_ID}" '
    (.description | split("\n")) as $lines
    | all($dependency_iids[]; . as $iid
        | $lines | index("Closes #" + ($iid | tostring)) != null)
      and ($lines | index("Closes #" + ($tail | tostring)) != null)
      and (.description | contains(
        "<!-- req_executor-shared-mr-intent:" + $intent + " -->"))
  ' <<<"${shared_mr}" >/dev/null 2>&1; then
  timeout --kill-after=5s "${VERIFY_TIMEOUT}s" glab api -X PUT \
    "projects/${PROJECT_URI}/merge_requests/${SHARED_MR_IID}" \
    -f "description=${DESIRED_DESCRIPTION}" >/dev/null 2>&1 \
    || defer_migration aggregate_mr_update_unavailable
fi
shared_mr="$(api_get \
  "projects/${PROJECT_URI}/merge_requests/${SHARED_MR_IID}")" \
  || defer_migration aggregate_mr_confirmation_unavailable
jq -e \
  --argjson iid "${SHARED_MR_IID}" --arg url "${SHARED_MR_URL}" \
  --arg source "${NEW_BRANCH}" --arg target "${TARGET_BRANCH}" \
  --arg sha "${AGGREGATE_SHA}" --arg author "${GITLAB_USERNAME}" \
  --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
  --argjson tail "${TAIL_IID}" --arg intent "${SHARED_INTENT_ID}" '
  .iid == $iid and .web_url == $url and .source_branch == $source
  and .target_branch == $target and .state == "opened"
  and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
  and .author.username == $author
  and ((.description | split("\n")) as $lines
    | all($dependency_iids[]; . as $dependency_iid
        | $lines | index("Closes #" + ($dependency_iid | tostring)) != null)
      and ($lines | index("Closes #" + ($tail | tostring)) != null)
      and (.description | contains(
        "<!-- req_executor-shared-mr-intent:" + $intent + " -->")))
' <<<"${shared_mr}" >/dev/null 2>&1 \
  || terminal_migration_failure aggregate_mr_identity_mismatch
set +e
require_unique_open_mr "${NEW_BRANCH}" "${SHARED_MR_IID}" "${SHARED_MR_URL}"
shared_unique_rc=$?
set -e
case "${shared_unique_rc}" in
  0) ;;
  1) defer_migration aggregate_mr_list_unavailable ;;
  *) terminal_migration_failure aggregate_mr_not_unique ;;
esac

# The anchor MR was already superseded by the ordinary shared migration. Close
# and retire every additional ordinary source only after the aggregate branch
# and all closing lines are independently observable.
while IFS= read -r source_json; do
  source_iid="$(jq -r '.iid' <<<"${source_json}")"
  [ "${source_iid}" != "${ANCHOR_IID}" ] || continue
  source_branch="$(jq -r '.branch' <<<"${source_json}")"
  source_sha="$(jq -r '.commit_sha' <<<"${source_json}")"
  source_mr_iid="$(jq -r '.mr_iid' <<<"${source_json}")"
  source_mr_url="$(jq -r '.mr_url' <<<"${source_json}")"
  source_mr="$(api_get \
    "projects/${PROJECT_URI}/merge_requests/${source_mr_iid}")" \
    || defer_migration dependency_source_mr_lookup_unavailable
  source_mr_state="$(jq -r '.state // ""' <<<"${source_mr}")"
  case "${source_mr_state}" in
    opened)
      validate_source_mr "${source_mr}" "${source_json}" opened \
        || terminal_migration_failure dependency_source_mr_identity_mismatch
      set +e
      require_unique_open_mr "${source_branch}" "${source_mr_iid}" "${source_mr_url}"
      source_unique_rc=$?
      set -e
      case "${source_unique_rc}" in
        0) ;;
        1) defer_migration dependency_source_mr_list_unavailable ;;
        *) terminal_migration_failure dependency_source_mr_not_unique ;;
      esac
      timeout --kill-after=5s "${VERIFY_TIMEOUT}s" glab mr close \
        "${source_mr_iid}" --repo "${PROJECT_FULL}" >/dev/null 2>&1 \
        || defer_migration dependency_source_mr_close_unavailable
      source_mr="$(api_get \
        "projects/${PROJECT_URI}/merge_requests/${source_mr_iid}")" \
        || defer_migration dependency_source_mr_close_confirmation_unavailable
      validate_source_mr "${source_mr}" "${source_json}" closed \
        || terminal_migration_failure dependency_source_mr_close_not_confirmed
      ;;
    closed)
      validate_source_mr "${source_mr}" "${source_json}" closed \
        || terminal_migration_failure dependency_source_closed_mr_identity_mismatch
      ;;
    *) terminal_migration_failure dependency_source_mr_not_migratable ;;
  esac
  set +e
  require_no_open_mr "${source_branch}"
  source_open_rc=$?
  set -e
  case "${source_open_rc}" in
    0) ;;
    1) defer_migration dependency_source_open_list_unavailable ;;
    *) terminal_migration_failure dependency_source_branch_has_open_mr ;;
  esac

  source_ref="$(read_remote_ref "${source_branch}")" \
    || defer_migration dependency_source_branch_lookup_unavailable
  if [ "$(jq -r '.found' <<<"${source_ref}")" = true ]; then
    [ "$(jq -r '.sha' <<<"${source_ref}")" = "${source_sha}" ] \
      || terminal_migration_failure dependency_source_branch_moved
    set +e
    git_network_guard_run "${REPO_PATH}" push --porcelain \
      "--force-with-lease=refs/heads/${source_branch}:${source_sha}" \
      origin ":refs/heads/${source_branch}" >/dev/null 2>&1
    source_delete_rc=$?
    set -e
    source_ref="$(read_remote_ref "${source_branch}")" \
      || defer_migration dependency_source_branch_delete_confirmation_unavailable
    if [ "$(jq -r '.found' <<<"${source_ref}")" = true ]; then
      [ "${source_delete_rc}" -ne 0 ] \
        && defer_migration dependency_source_branch_delete_unconfirmed
      terminal_migration_failure dependency_source_branch_delete_mismatch
    fi
  fi
  GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" update-ref -d \
    "refs/remotes/origin/${source_branch}" "${source_sha}" 2>/dev/null || true

  source_state="$(read_issue_state "${source_iid}")" \
    || defer_migration dependency_source_state_reload_failed
  source_updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  source_state="$(jq -ce \
    --argjson source_iid "${source_iid}" --arg source_sha "${source_sha}" \
    --arg source_mr_url "${source_mr_url}" \
    --argjson anchor "${ANCHOR_IID}" --argjson tail "${TAIL_IID}" \
    --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
    --arg work_branch "${NEW_BRANCH}" --arg aggregate_sha "${AGGREGATE_SHA}" \
    --argjson replacement_mr_iid "${SHARED_MR_IID}" \
    --arg replacement_mr_url "${SHARED_MR_URL}" \
    --arg updated_at "${source_updated_at}" '
    if .iid == $source_iid and .status == "done"
      and ((.commit_sha | ascii_downcase) == ($source_sha | ascii_downcase))
    then
      .superseded_merge_request_url = $source_mr_url
      | .merge_request_url = $replacement_mr_url
      | .mr_finalization = {
          status:"superseded",commit_sha:$source_sha,
          replacement_work_branch:$work_branch,
          replacement_mr_iid:$replacement_mr_iid,
          replacement_mr_url:$replacement_mr_url,superseded_at:$updated_at
        }
      | .joined_dependency_group = {
          version:1,anchor_iid:$anchor,tail_iid:$tail,
          dependency_iids:$dependency_iids,work_branch:$work_branch,
          aggregate_sha:$aggregate_sha,joined_at:$updated_at
        }
      | .updated_at = $updated_at
    else error("dependency source state changed") end
  ' <<<"${source_state}" 2>/dev/null)" \
    || terminal_migration_failure dependency_source_state_changed
  store_issue_state "${source_iid}" "${source_state}" \
    || defer_migration dependency_source_state_update_failed
done < <(jq -c '.[1:][]' <<<"${SOURCES_JSON}")

COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ANCHOR_STATE_JSON="$(read_issue_state "${ANCHOR_IID}")" \
  || defer_migration dependency_anchor_state_reload_failed
COMPLETED_STATE="$(jq -ce \
  --argjson anchor "${ANCHOR_IID}" --argjson tail "${TAIL_IID}" \
  --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
  --arg work_branch "${NEW_BRANCH}" --arg aggregate_sha "${AGGREGATE_SHA}" \
  --argjson mr_iid "${SHARED_MR_IID}" --arg mr_url "${SHARED_MR_URL}" \
  --arg completed_at "${COMPLETED_AT}" '
  if .iid == $anchor and .work_branch == $work_branch
    and .shared_branch_role == "head"
    and .dependency_aggregation.anchor_iid == $anchor
    and .dependency_aggregation.tail_iid == $tail
    and .dependency_aggregation.dependency_iids == $dependency_iids
    and .dependency_aggregation.aggregate_sha == $aggregate_sha
    and .mr_finalization.iid == $mr_iid
    and .mr_finalization.web_url == $mr_url
  then
    .commit_sha = $aggregate_sha
    | .work_branch_sha = $aggregate_sha
    | .mr_finalization.commit_sha = $aggregate_sha
    | .dependency_aggregation.status = "completed"
    | .dependency_aggregation.mr_iid = $mr_iid
    | .dependency_aggregation.mr_url = $mr_url
    | .dependency_aggregation.completed_at = $completed_at
    | .dependency_history_updated_at = $completed_at
    | .updated_at = $completed_at
    | del(.dependency_aggregation.failure_reason,
          .dependency_aggregation.failed_at)
  else error("dependency anchor state changed") end
' <<<"${ANCHOR_STATE_JSON}" 2>/dev/null)" \
  || terminal_migration_failure dependency_anchor_state_changed
store_issue_state "${ANCHOR_IID}" "${COMPLETED_STATE}" \
  || defer_migration dependency_aggregation_completion_write_failed

jq -nc \
  --argjson head_iid "${ANCHOR_IID}" --argjson tail_iid "${TAIL_IID}" \
  --argjson dependency_iids "${DEPENDENCY_IIDS_JSON}" \
  --arg work_branch "${NEW_BRANCH}" --arg commit_sha "${AGGREGATE_SHA}" \
  --argjson mr_iid "${SHARED_MR_IID}" --arg mr_url "${SHARED_MR_URL}" \
  --arg intent_id "${SHARED_INTENT_ID}" '{
    status:"ready",reason:"multi_dependency_heads_aggregated",
    head_iid:$head_iid,tail_iid:$tail_iid,
    dependency_iids:$dependency_iids,work_branch:$work_branch,
    commit_sha:$commit_sha,mr_iid:$mr_iid,mr_url:$mr_url,
    intent_id:$intent_id
  }'
