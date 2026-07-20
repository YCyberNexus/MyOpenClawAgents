#!/usr/bin/env bash
# Migrate an already-completed ordinary dependency head from issue/A to the
# late-bound shared branch issue/A+C. GitLab cannot retarget an MR's source
# branch, so the migration closes A's old MR and creates one replacement MR on
# the new branch before C is allowed to start. A private checkpoint makes every
# mutation replayable without rerunning A or creating duplicate MRs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/git_network_guard.sh"

: "${MIGRATION_HEAD_IID:?}" "${MIGRATION_TAIL_IID:?}" \
  "${MIGRATION_TARGET_BRANCH:?}" "${REPO_PATH:?}" "${ISSUES_ROOT:?}" \
  "${WORK_ROOT:?}" "${PROJECT_FULL:?}" "${PROJECT_URI:?}"

HEAD_IID="${MIGRATION_HEAD_IID}"
TAIL_IID="${MIGRATION_TAIL_IID}"
TARGET_BRANCH="${MIGRATION_TARGET_BRANCH}"
OLD_BRANCH="issue/${HEAD_IID}"
NEW_BRANCH="issue/${HEAD_IID}+${TAIL_IID}"
HEAD_STATE_FILE="${ISSUES_ROOT}/issue-${HEAD_IID}/state.json"
MIGRATION_DIR="${WORK_ROOT}/migrations/${HEAD_IID}+${TAIL_IID}"
LOCK_FILE="${WORK_ROOT}/locks/shared-migration-${HEAD_IID}-${TAIL_IID}.lock"
VERIFY_TIMEOUT="${SHARED_MIGRATION_VERIFY_TIMEOUT_SECONDS:-120}"

for iid in "${HEAD_IID}" "${TAIL_IID}"; do
  [[ "${iid}" =~ ^[1-9][0-9]*$ ]] || {
    echo "migrate_shared_dependency_head: invalid Issue IID" >&2
    exit 2
  }
done
[ "${HEAD_IID}" != "${TAIL_IID}" ] || {
  echo "migrate_shared_dependency_head: head and tail must differ" >&2
  exit 2
}
[[ "${VERIFY_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] \
  && [ "${VERIFY_TIMEOUT}" -le 600 ] || {
    echo "migrate_shared_dependency_head: invalid verification timeout" >&2
    exit 2
  }
GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
  check-ref-format --branch "${TARGET_BRANCH}" >/dev/null 2>&1 || {
  echo "migrate_shared_dependency_head: invalid target branch" >&2
  exit 2
}
command -v timeout >/dev/null 2>&1 || exit 2
command -v glab >/dev/null 2>&1 || exit 2
command -v jq >/dev/null 2>&1 || exit 2
command -v od >/dev/null 2>&1 || exit 2

mkdir -p "${WORK_ROOT}/locks" "${MIGRATION_DIR}"
chmod 700 "${MIGRATION_DIR}"
for trusted_path in "${WORK_ROOT}/locks" "${MIGRATION_DIR}"; do
  [ ! -L "${trusted_path}" ] || {
    echo "migrate_shared_dependency_head: trusted runtime path is a symlink" >&2
    exit 2
  }
done
[ ! -L "${LOCK_FILE}" ] || exit 2
exec {MIGRATION_LOCK_FD}>"${LOCK_FILE}"
chmod 600 "${LOCK_FILE}"
flock -x "${MIGRATION_LOCK_FD}"

private_file_mode() {
  if stat -f '%Lp' "$1" 2>/dev/null; then :; else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

private_file_owner() {
  if stat -f '%u' "$1" 2>/dev/null; then :; else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

read_head_state() {
  local bytes
  [ -f "${HEAD_STATE_FILE}" ] && [ ! -L "${HEAD_STATE_FILE}" ] || return 1
  [ "$(private_file_mode "${HEAD_STATE_FILE}")" = 600 ] || return 1
  [ "$(private_file_owner "${HEAD_STATE_FILE}")" = "$(id -u)" ] || return 1
  bytes="$(wc -c <"${HEAD_STATE_FILE}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] && [ "${bytes}" -le 65536 ] \
    || return 1
  jq -ce 'if type == "object" then . else error("invalid state") end' \
    "${HEAD_STATE_FILE}" 2>/dev/null
}

store_head_state() {
  local state_json="$1" state_tmp
  state_tmp="$(mktemp "${HEAD_STATE_FILE}.tmp.XXXXXX")"
  if ! jq -ce 'if type == "object" then . else error("invalid state") end' \
      <<<"${state_json}" >"${state_tmp}"; then
    return 1
  fi
  chmod 600 "${state_tmp}"
  mv "${state_tmp}" "${HEAD_STATE_FILE}"
}

emit_status() {
  local status="$1" reason="$2"
  jq -nc \
    --arg status "${status}" \
    --arg reason "${reason}" \
    --argjson head_iid "${HEAD_IID}" \
    --argjson tail_iid "${TAIL_IID}" \
    --arg old_branch "${OLD_BRANCH}" \
    --arg new_branch "${NEW_BRANCH}" '{
      status:$status,reason:$reason,head_iid:$head_iid,tail_iid:$tail_iid,
      old_branch:$old_branch,new_branch:$new_branch
    }'
}

defer_migration() {
  emit_status deferred "$1"
  exit 75
}

terminal_migration_failure() {
  local reason="$1" now failed_state
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if HEAD_STATE_JSON="$(read_head_state 2>/dev/null)" \
      && jq -e '.branch_migration | type == "object"' \
        <<<"${HEAD_STATE_JSON}" >/dev/null 2>&1; then
    failed_state="$(jq -c \
      --arg reason "${reason}" --arg failed_at "${now}" '
      .branch_migration.status = "failed"
      | .branch_migration.failure_reason = $reason
      | .branch_migration.failed_at = $failed_at
    ' <<<"${HEAD_STATE_JSON}")"
    store_head_state "${failed_state}" || true
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

read_all_source_mrs() {
  local branch="$1" encoded response page_rows page_count page=1
  local previous_page="" all_rows='[]'
  encoded="$(jq -rn --arg value "${branch}" '$value | @uri')" || return 2
  while :; do
    response="$(api_get \
      "projects/${PROJECT_URI}/merge_requests?scope=all&state=all&source_branch=${encoded}&per_page=100&page=${page}")" \
      || return 1
    page_rows="$(jq -ce --arg source_branch "${branch}" '
      if type == "array" and length <= 100
        and all(.[];
          type == "object"
          and (.iid | type == "number" and . == floor and . > 0)
          and (.web_url | type == "string" and length > 0)
          and .source_branch == $source_branch
          and (.target_branch | type == "string" and length > 0)
          and (.sha | type == "string")
          and (.state | type == "string" and length > 0)
          and (.author.username | type == "string" and length > 0)
          and (.description | type == "string"))
      then . else error("invalid MR history page") end
    ' <<<"${response}" 2>/dev/null)" || return 2
    page_count="$(jq -r 'length' <<<"${page_rows}")"
    if [ "${page_count}" -eq 100 ] && [ -n "${previous_page}" ] \
        && [ "${page_rows}" = "${previous_page}" ]; then
      return 3
    fi
    all_rows="$(jq -cn --argjson old "${all_rows}" \
      --argjson page "${page_rows}" '$old + $page')" || return 2
    [ "${page_count}" -lt 100 ] && break
    [ "${page}" -lt 1000 ] || return 3
    previous_page="${page_rows}"
    page=$((page + 1))
  done
  printf '%s\n' "${all_rows}"
}

validate_mr_identity() {
  local mr_json="$1" iid="$2" url="$3" source="$4" state="$5"
  local sha="$6" intent_id="${7:-}" closes_tail="${8:-false}"
  jq -e \
    --argjson iid "${iid}" \
    --arg url "${url}" \
    --arg source "${source}" \
    --arg target "${TARGET_BRANCH}" \
    --arg state "${state}" \
    --arg sha "${sha}" \
    --arg author "${GITLAB_USERNAME}" \
    --arg closes_head "Closes #${HEAD_IID}" \
    --arg closes_tail "Closes #${TAIL_IID}" \
    --arg intent "${intent_id}" \
    --argjson require_tail "${closes_tail}" '
    type == "object"
    and .iid == $iid
    and .web_url == $url
    and .source_branch == $source
    and .target_branch == $target
    and .state == $state
    and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
    and .author.username == $author
    and (.description | type == "string")
    and ((.description | split("\n")) | index($closes_head) != null)
    and (if $require_tail then
      ((.description | split("\n")) | index($closes_tail) != null)
      and (.description | contains(
        "<!-- req_executor-shared-mr-intent:" + $intent + " -->"))
    else true end)
  ' <<<"${mr_json}" >/dev/null 2>&1
}

require_unique_open_mr() {
  local branch="$1" iid="$2" url="$3" rows rc
  set +e
  rows="$(read_open_source_mrs "${branch}")"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
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
  case "${rc}" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  jq -e 'length == 0' <<<"${rows}" >/dev/null 2>&1 || return 2
}

ensure_new_branch() {
  local ref_json rc found remote_sha push_rc
  set +e
  ref_json="$(read_remote_ref "${NEW_BRANCH}")"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) defer_migration new_branch_lookup_unavailable ;;
    *) terminal_migration_failure new_branch_ref_ambiguous ;;
  esac
  found="$(jq -r '.found' <<<"${ref_json}")"
  remote_sha="$(jq -r '.sha' <<<"${ref_json}")"
  if [ "${found}" = true ]; then
    [ "${remote_sha,,}" = "${HEAD_COMMIT_SHA,,}" ] \
      || terminal_migration_failure new_branch_moved
    return 0
  fi
  set +e
  git_network_guard_run "${REPO_PATH}" push --porcelain \
    "--force-with-lease=refs/heads/${NEW_BRANCH}:" origin \
    "${HEAD_COMMIT_SHA}:refs/heads/${NEW_BRANCH}" >/dev/null 2>&1
  push_rc=$?
  set -e
  set +e
  ref_json="$(read_remote_ref "${NEW_BRANCH}")"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration new_branch_confirmation_unavailable
  found="$(jq -r '.found' <<<"${ref_json}")"
  remote_sha="$(jq -r '.sha' <<<"${ref_json}")"
  if [ "${found}" = true ] \
      && [ "${remote_sha,,}" = "${HEAD_COMMIT_SHA,,}" ]; then
    return 0
  fi
  [ "${push_rc}" -eq 0 ] \
    || defer_migration new_branch_create_unconfirmed
  terminal_migration_failure new_branch_create_mismatch
}

ensure_old_mr_closed() {
  local old_mr rc state
  set +e
  old_mr="$(api_get \
    "projects/${PROJECT_URI}/merge_requests/${OLD_MR_IID}")"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration old_mr_lookup_unavailable
  state="$(jq -r '.state // ""' <<<"${old_mr}")"
  case "${state}" in
    opened)
      validate_mr_identity "${old_mr}" "${OLD_MR_IID}" "${OLD_MR_URL}" \
        "${OLD_BRANCH}" opened "${HEAD_COMMIT_SHA}" \
        || terminal_migration_failure old_mr_identity_mismatch
      set +e
      require_unique_open_mr "${OLD_BRANCH}" "${OLD_MR_IID}" "${OLD_MR_URL}"
      rc=$?
      set -e
      case "${rc}" in
        0) ;;
        1) defer_migration old_mr_open_list_unavailable ;;
        *) terminal_migration_failure old_mr_not_unique ;;
      esac
      timeout --kill-after=5s "${VERIFY_TIMEOUT}s" glab mr close \
        "${OLD_MR_IID}" --repo "${PROJECT_FULL}" >/dev/null 2>&1 \
        || defer_migration old_mr_close_unavailable
      set +e
      old_mr="$(api_get \
        "projects/${PROJECT_URI}/merge_requests/${OLD_MR_IID}")"
      rc=$?
      set -e
      [ "${rc}" -eq 0 ] || defer_migration old_mr_close_confirmation_unavailable
      validate_mr_identity "${old_mr}" "${OLD_MR_IID}" "${OLD_MR_URL}" \
        "${OLD_BRANCH}" closed "${HEAD_COMMIT_SHA}" \
        || terminal_migration_failure old_mr_close_not_confirmed
      ;;
    closed)
      validate_mr_identity "${old_mr}" "${OLD_MR_IID}" "${OLD_MR_URL}" \
        "${OLD_BRANCH}" closed "${HEAD_COMMIT_SHA}" \
        || terminal_migration_failure closed_old_mr_identity_mismatch
      ;;
    *) terminal_migration_failure old_mr_not_migratable ;;
  esac
  set +e
  require_no_open_mr "${OLD_BRANCH}"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) defer_migration old_branch_open_list_unavailable ;;
    *) terminal_migration_failure old_branch_has_another_open_mr ;;
  esac
}

find_or_create_new_mr() {
  local history rc count new_mr desc_file desc_tmp
  set +e
  history="$(read_all_source_mrs "${NEW_BRANCH}")"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) defer_migration new_mr_history_unavailable ;;
    2) terminal_migration_failure new_mr_history_invalid ;;
    *) terminal_migration_failure new_mr_history_incomplete ;;
  esac
  count="$(jq -r 'length' <<<"${history}")"
  [ "${count}" -le 1 ] || terminal_migration_failure new_mr_history_conflict
  if [ "${count}" -eq 0 ]; then
    desc_file="${MIGRATION_DIR}/mr_description.md"
    [ ! -L "${desc_file}" ] || terminal_migration_failure migration_description_symlink
    desc_tmp="$(mktemp "${desc_file}.tmp.XXXXXX")"
    {
      printf 'Closes #%s\n' "${HEAD_IID}"
      printf 'Closes #%s\n' "${TAIL_IID}"
      printf '<!-- req_executor-shared-mr-intent:%s -->\n\n' "${INTENT_ID}"
      printf 'Supersedes !%s after late dependency #%s was discovered.\n\n' \
        "${OLD_MR_IID}" "${TAIL_IID}"
      printf 'Auto-generated shared MR for issues #%s and #%s.\n\n' \
        "${HEAD_IID}" "${TAIL_IID}"
      printf 'Do not merge until reviewed.\n'
    } >"${desc_tmp}"
    chmod 600 "${desc_tmp}"
    mv "${desc_tmp}" "${desc_file}"
    set +e
    (
      cd "${REPO_PATH}"
      timeout --kill-after=5s "${VERIFY_TIMEOUT}s" glab mr create \
        --repo "${PROJECT_FULL}" \
        --source-branch "${NEW_BRANCH}" \
        --target-branch "${TARGET_BRANCH}" \
        --title "Issues #${HEAD_IID} + #${TAIL_IID}: shared dependency" \
        --description "$(cat "${desc_file}")" \
        --yes >/dev/null
    )
    rc=$?
    set -e
    [ "${rc}" -eq 0 ] || defer_migration new_mr_create_unavailable
    set +e
    history="$(read_all_source_mrs "${NEW_BRANCH}")"
    rc=$?
    set -e
    [ "${rc}" -eq 0 ] || defer_migration new_mr_create_confirmation_unavailable
    count="$(jq -r 'length' <<<"${history}")"
    [ "${count}" -eq 1 ] || terminal_migration_failure new_mr_create_ambiguous
  fi
  NEW_MR_IID="$(jq -er '.[0].iid | select(type == "number" and . > 0)' \
    <<<"${history}")" || terminal_migration_failure new_mr_iid_invalid
  NEW_MR_URL="$(jq -er '.[0].web_url | select(type == "string" and length > 0)' \
    <<<"${history}")" || terminal_migration_failure new_mr_url_invalid
  set +e
  new_mr="$(api_get \
    "projects/${PROJECT_URI}/merge_requests/${NEW_MR_IID}")"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration new_mr_lookup_unavailable
  validate_mr_identity "${new_mr}" "${NEW_MR_IID}" "${NEW_MR_URL}" \
    "${NEW_BRANCH}" opened "${HEAD_COMMIT_SHA}" "${INTENT_ID}" true \
    || terminal_migration_failure new_mr_identity_mismatch
  set +e
  require_unique_open_mr "${NEW_BRANCH}" "${NEW_MR_IID}" "${NEW_MR_URL}"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) defer_migration new_mr_open_list_unavailable ;;
    *) terminal_migration_failure new_mr_not_unique ;;
  esac
}

ensure_old_branch_deleted() {
  local ref_json rc found remote_sha push_rc
  set +e
  ref_json="$(read_remote_ref "${OLD_BRANCH}")"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) defer_migration old_branch_lookup_unavailable ;;
    *) terminal_migration_failure old_branch_ref_ambiguous ;;
  esac
  found="$(jq -r '.found' <<<"${ref_json}")"
  remote_sha="$(jq -r '.sha' <<<"${ref_json}")"
  [ "${found}" = true ] || return 0
  [ "${remote_sha,,}" = "${HEAD_COMMIT_SHA,,}" ] \
    || terminal_migration_failure old_branch_moved
  set +e
  git_network_guard_run "${REPO_PATH}" push --porcelain \
    "--force-with-lease=refs/heads/${OLD_BRANCH}:${HEAD_COMMIT_SHA}" \
    origin ":refs/heads/${OLD_BRANCH}" >/dev/null 2>&1
  push_rc=$?
  set -e
  set +e
  ref_json="$(read_remote_ref "${OLD_BRANCH}")"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration old_branch_delete_confirmation_unavailable
  if [ "$(jq -r '.found' <<<"${ref_json}")" = false ]; then
    return 0
  fi
  [ "${push_rc}" -eq 0 ] || defer_migration old_branch_delete_unconfirmed
  terminal_migration_failure old_branch_delete_mismatch
}

git_network_guard_assert_repo "${REPO_PATH}"

HEAD_STATE_JSON="$(read_head_state)" \
  || terminal_migration_failure dependency_head_state_missing_or_unsafe
MIGRATION_STATUS="$(jq -r '.branch_migration.status // ""' \
  <<<"${HEAD_STATE_JSON}")"

if [ "${MIGRATION_STATUS}" = failed ]; then
  emit_status failed "$(jq -r '.branch_migration.failure_reason // "migration_failed"' \
    <<<"${HEAD_STATE_JSON}")"
  exit 6
fi

if [ -z "${MIGRATION_STATUS}" ]; then
  ORDINARY_IDENTITY="$(jq -ce \
    --argjson head "${HEAD_IID}" \
    --arg old_branch "${OLD_BRANCH}" '
    if .iid == $head
      and .status == "done"
      and .work_branch == $old_branch
      and .branch_members == [$head]
      and (.shared_branch_role // null) == null
      and (.dependency_iid // null) == null
      and (.dependency_branch // null) == null
      and (.dependency_base_sha // null) == null
      and (.commit_sha | type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      and .work_branch_sha == .commit_sha
      and .dependency_history_verified == true
      and (.latest_attempt_number | type == "number" and . == floor and . > 0)
      and .dependency_pinned_attempt_number == .latest_attempt_number
      and (.merge_request_url | type == "string"
        and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
    then {
      commit_sha:.commit_sha,
      source_attempt_number:.latest_attempt_number,
      old_mr_url:.merge_request_url
    } else error("ordinary dependency head is not migration-safe") end
  ' <<<"${HEAD_STATE_JSON}" 2>/dev/null)" \
    || terminal_migration_failure dependency_head_not_migration_safe
  HEAD_COMMIT_SHA="$(jq -r '.commit_sha' <<<"${ORDINARY_IDENTITY}")"
  SOURCE_ATTEMPT_NUMBER="$(jq -r '.source_attempt_number' \
    <<<"${ORDINARY_IDENTITY}")"
  OLD_MR_URL="$(jq -r '.old_mr_url' <<<"${ORDINARY_IDENTITY}")"
  if [[ "${OLD_MR_URL}" =~ /-/merge_requests/([1-9][0-9]*)/?$ ]]; then
    OLD_MR_IID="${BASH_REMATCH[1]}"
  else
    terminal_migration_failure dependency_head_mr_url_invalid
  fi

  set +e
  GITLAB_USERNAME="$(api_get user | jq -er \
    '.username | select(type == "string" and length > 0 and length <= 255)' \
    2>/dev/null)"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration gitlab_principal_unavailable

  set +e
  OLD_REF_JSON="$(read_remote_ref "${OLD_BRANCH}")"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration old_branch_lookup_unavailable
  [ "$(jq -r '.found' <<<"${OLD_REF_JSON}")" = true ] \
    && [ "$(jq -r '.sha' <<<"${OLD_REF_JSON}")" = "${HEAD_COMMIT_SHA}" ] \
    || terminal_migration_failure old_branch_commit_mismatch
  set +e
  OLD_MR_JSON="$(api_get \
    "projects/${PROJECT_URI}/merge_requests/${OLD_MR_IID}")"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || defer_migration old_mr_lookup_unavailable
  validate_mr_identity "${OLD_MR_JSON}" "${OLD_MR_IID}" "${OLD_MR_URL}" \
    "${OLD_BRANCH}" opened "${HEAD_COMMIT_SHA}" \
    || terminal_migration_failure old_mr_identity_mismatch
  set +e
  require_unique_open_mr "${OLD_BRANCH}" "${OLD_MR_IID}" "${OLD_MR_URL}"
  rc=$?
  set -e
  case "${rc}" in
    0) ;;
    1) defer_migration old_mr_open_list_unavailable ;;
    *) terminal_migration_failure old_mr_not_unique ;;
  esac

  INTENT_ID="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null \
    | tr -d '[:space:]')" || defer_migration migration_intent_unavailable
  [[ "${INTENT_ID}" =~ ^[0-9a-f]{64}$ ]] \
    || defer_migration migration_intent_invalid
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  HEAD_STATE_JSON="$(jq -c \
    --argjson head "${HEAD_IID}" \
    --argjson tail "${TAIL_IID}" \
    --arg from_branch "${OLD_BRANCH}" \
    --arg to_branch "${NEW_BRANCH}" \
    --arg commit_sha "${HEAD_COMMIT_SHA}" \
    --arg target_branch "${TARGET_BRANCH}" \
    --argjson old_mr_iid "${OLD_MR_IID}" \
    --arg old_mr_url "${OLD_MR_URL}" \
    --arg intent_id "${INTENT_ID}" \
    --argjson source_attempt_number "${SOURCE_ATTEMPT_NUMBER}" \
    --arg started_at "${STARTED_AT}" '
    .branch_migration = {
      version:1,status:"pending",head_iid:$head,tail_iid:$tail,
      from_branch:$from_branch,to_branch:$to_branch,commit_sha:$commit_sha,
      target_branch:$target_branch,old_mr_iid:$old_mr_iid,
      old_mr_url:$old_mr_url,intent_id:$intent_id,
      source_attempt_number:$source_attempt_number,started_at:$started_at
    }
  ' <<<"${HEAD_STATE_JSON}")"
  store_head_state "${HEAD_STATE_JSON}" \
    || defer_migration migration_checkpoint_write_failed
  MIGRATION_STATUS=pending
fi

MIGRATION_JSON="$(jq -ce \
  --argjson head "${HEAD_IID}" \
  --argjson tail "${TAIL_IID}" \
  --arg from_branch "${OLD_BRANCH}" \
  --arg to_branch "${NEW_BRANCH}" \
  --arg target_branch "${TARGET_BRANCH}" '
  .branch_migration
  | if type == "object"
    and .version == 1
    and (.status == "pending" or .status == "completed")
    and .head_iid == $head and .tail_iid == $tail
    and .from_branch == $from_branch and .to_branch == $to_branch
    and .target_branch == $target_branch
    and (.commit_sha | type == "string"
      and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
    and (.old_mr_iid | type == "number" and . == floor and . > 0)
    and (.old_mr_iid as $old_mr_iid
      | .old_mr_url | type == "string"
        and test("/-/merge_requests/" + ($old_mr_iid | tostring) + "/?$"))
    and (.intent_id | type == "string" and test("^[0-9a-f]{64}$"))
    and (.source_attempt_number | type == "number" and . == floor and . > 0)
    and (.started_at | type == "string" and length > 0)
    and (if .status == "completed" then
      (.new_mr_iid | type == "number" and . == floor and . > 0)
      and (.new_mr_iid as $new_mr_iid
        | .new_mr_url | type == "string"
          and test("/-/merge_requests/" + ($new_mr_iid | tostring) + "/?$"))
      and (.completed_at | type == "string" and length > 0)
    else true end)
  then . else error("invalid migration checkpoint") end
' <<<"${HEAD_STATE_JSON}" 2>/dev/null)" \
  || terminal_migration_failure migration_checkpoint_invalid

HEAD_COMMIT_SHA="$(jq -r '.commit_sha' <<<"${MIGRATION_JSON}")"
SOURCE_ATTEMPT_NUMBER="$(jq -r '.source_attempt_number' <<<"${MIGRATION_JSON}")"
OLD_MR_IID="$(jq -r '.old_mr_iid' <<<"${MIGRATION_JSON}")"
OLD_MR_URL="$(jq -r '.old_mr_url' <<<"${MIGRATION_JSON}")"
INTENT_ID="$(jq -r '.intent_id' <<<"${MIGRATION_JSON}")"

set +e
GITLAB_USERNAME="$(api_get user | jq -er \
  '.username | select(type == "string" and length > 0 and length <= 255)' \
  2>/dev/null)"
rc=$?
set -e
[ "${rc}" -eq 0 ] || defer_migration gitlab_principal_unavailable

ensure_new_branch

NEW_MR_IID=""
NEW_MR_URL=""
if [ "${MIGRATION_STATUS}" = completed ]; then
  NEW_MR_IID="$(jq -r '.new_mr_iid' <<<"${MIGRATION_JSON}")"
  NEW_MR_URL="$(jq -r '.new_mr_url' <<<"${MIGRATION_JSON}")"
else
  set +e
  existing_history="$(read_all_source_mrs "${NEW_BRANCH}")"
  history_rc=$?
  set -e
  case "${history_rc}" in
    0) ;;
    1) defer_migration new_mr_history_unavailable ;;
    2) terminal_migration_failure new_mr_history_invalid ;;
    *) terminal_migration_failure new_mr_history_incomplete ;;
  esac
  existing_count="$(jq -r 'length' <<<"${existing_history}")"
  [ "${existing_count}" -le 1 ] \
    || terminal_migration_failure new_mr_history_conflict
  if [ "${existing_count}" -eq 1 ]; then
    NEW_MR_IID="$(jq -r '.[0].iid' <<<"${existing_history}")"
    NEW_MR_URL="$(jq -r '.[0].web_url' <<<"${existing_history}")"
  fi
fi

# If the old branch is already absent, only a checkpoint-owned replacement MR
# can prove that this is recovery after our final delete rather than an
# unrelated destructive change.
set +e
OLD_REF_JSON="$(read_remote_ref "${OLD_BRANCH}")"
old_ref_rc=$?
set -e
case "${old_ref_rc}" in
  0) ;;
  1) defer_migration old_branch_lookup_unavailable ;;
  *) terminal_migration_failure old_branch_ref_ambiguous ;;
esac
if [ "$(jq -r '.found' <<<"${OLD_REF_JSON}")" = false ] \
    && [ -z "${NEW_MR_IID}" ]; then
  terminal_migration_failure old_branch_missing_before_replacement
fi

ensure_old_mr_closed
find_or_create_new_mr
ensure_old_branch_deleted

GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" update-ref \
  "refs/remotes/origin/${NEW_BRANCH}" "${HEAD_COMMIT_SHA}"
GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" update-ref -d \
  "refs/remotes/origin/${OLD_BRANCH}" "${HEAD_COMMIT_SHA}" 2>/dev/null || true

COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEAD_STATE_JSON="$(read_head_state)" \
  || defer_migration dependency_head_state_reload_failed
COMPLETED_STATE="$(jq -ce \
  --argjson head "${HEAD_IID}" \
  --argjson tail "${TAIL_IID}" \
  --arg new_branch "${NEW_BRANCH}" \
  --arg commit_sha "${HEAD_COMMIT_SHA}" \
  --arg intent_id "${INTENT_ID}" \
  --arg target_branch "${TARGET_BRANCH}" \
  --argjson source_attempt_number "${SOURCE_ATTEMPT_NUMBER}" \
  --argjson new_mr_iid "${NEW_MR_IID}" \
  --arg new_mr_url "${NEW_MR_URL}" \
  --arg completed_at "${COMPLETED_AT}" '
  if .branch_migration.intent_id == $intent_id
    and .branch_migration.commit_sha == $commit_sha
  then
    .work_branch = $new_branch
    | .branch_members = [$head,$tail]
    | .shared_branch_role = "head"
    | .work_branch_sha = $commit_sha
    | .dependency_history_verified = true
    | .dependency_pinned_attempt_number = $source_attempt_number
    | .dependency_history_updated_at = $completed_at
    | .merge_request_url = $new_mr_url
    | .mr_finalization = {
        status:"verified_open",source_attempt_number:$source_attempt_number,
        work_branch:$new_branch,branch_members:[$head,$tail],
        shared_branch_role:"head",commit_sha:$commit_sha,intent_id:$intent_id,
        target_branch:$target_branch,iid:$new_mr_iid,web_url:$new_mr_url,
        mr_action:"created",verified_at:$completed_at
      }
    | .branch_migration.status = "completed"
    | .branch_migration.new_mr_iid = $new_mr_iid
    | .branch_migration.new_mr_url = $new_mr_url
    | .branch_migration.completed_at = $completed_at
    | del(.branch_migration.failure_reason,.branch_migration.failed_at)
  else error("migration checkpoint changed") end
' <<<"${HEAD_STATE_JSON}" 2>/dev/null)" \
  || terminal_migration_failure migration_checkpoint_changed
store_head_state "${COMPLETED_STATE}" \
  || defer_migration migration_completion_write_failed

jq -nc \
  --argjson head_iid "${HEAD_IID}" \
  --argjson tail_iid "${TAIL_IID}" \
  --arg work_branch "${NEW_BRANCH}" \
  --arg commit_sha "${HEAD_COMMIT_SHA}" \
  --argjson mr_iid "${NEW_MR_IID}" \
  --arg mr_url "${NEW_MR_URL}" \
  --arg intent_id "${INTENT_ID}" '{
    status:"ready",reason:"late_dependency_head_migrated",
    head_iid:$head_iid,tail_iid:$tail_iid,work_branch:$work_branch,
    commit_sha:$commit_sha,mr_iid:$mr_iid,mr_url:$mr_url,
    intent_id:$intent_id
  }'
