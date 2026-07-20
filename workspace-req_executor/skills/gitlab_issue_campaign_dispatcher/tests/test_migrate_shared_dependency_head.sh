#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-head-migration.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PATH="${TEST_ROOT}/repo"
REMOTE_REPO="${TEST_ROOT}/origin.git"
MR_STATE="${TEST_ROOT}/mrs.json"
GLAB_LOG="${TEST_ROOT}/glab.log"
FAIL_ONCE_MARKER="${TEST_ROOT}/create-failed-once"

mkdir -p "${FIXTURE_SCRIPTS}" "${BIN_DIR}" "${REPO_PATH}"
cp "${SKILL_DIR}/scripts/migrate_shared_dependency_head.sh" \
  "${FIXTURE_SCRIPTS}/migrate_shared_dependency_head.sh"

cat >"${FIXTURE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${TEST_REPO_PATH:?}" "${TEST_PROJECT_FULL:?}" "${TEST_PROJECT_URI:?}"
export REPO_PATH="${TEST_REPO_PATH}"
export RESULT_ROOT="${REPO_PATH}/.req_executor"
export WORK_ROOT="${RESULT_ROOT}/_dispatcher"
export ISSUES_ROOT="${RESULT_ROOT}/issues"
export PROJECT_FULL="${TEST_PROJECT_FULL}"
export PROJECT_URI="${TEST_PROJECT_URI}"
EOF

cat >"${FIXTURE_SCRIPTS}/git_network_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git_network_guard_assert_repo() {
  [ "$1" = "${TEST_REPO_PATH}" ]
}
git_network_guard_run() {
  local repo="$1"
  shift
  [ "${repo}" = "${TEST_REPO_PATH}" ]
  git -C "${repo}" "$@"
}
EOF

cat >"${BIN_DIR}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

store_mrs() {
  local content="$1" tmp
  tmp="$(mktemp "${TEST_MR_STATE}.tmp.XXXXXX")"
  printf '%s\n' "${content}" >"${tmp}"
  mv "${tmp}" "${TEST_MR_STATE}"
}

if [ "${1:-}" = api ]; then
  endpoint="${2:-}"
  if [ "${endpoint}" = user ]; then
    jq -nc '{username:"req-executor-bot"}'
    exit 0
  fi
  case "${endpoint}" in
    projects/group%2Fproject/merge_requests/16)
      jq -ce '.[] | select(.iid == 16)' "${TEST_MR_STATE}"
      exit 0
      ;;
    projects/group%2Fproject/merge_requests/17)
      jq -ce '.[] | select(.iid == 17)' "${TEST_MR_STATE}"
      exit 0
      ;;
    projects/group%2Fproject/merge_requests\?*)
      case "${endpoint}" in
        *source_branch=issue%2F41%2B43*) source_branch='issue/41+43' ;;
        *source_branch=issue%2F41*) source_branch='issue/41' ;;
        *) exit 91 ;;
      esac
      if [[ "${endpoint}" == *state=opened* ]]; then
        jq -ce --arg source "${source_branch}" \
          '[.[] | select(.source_branch == $source and .state == "opened")]' \
          "${TEST_MR_STATE}"
      else
        jq -ce --arg source "${source_branch}" \
          '[.[] | select(.source_branch == $source)]' "${TEST_MR_STATE}"
      fi
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = mr ] && [ "${2:-}" = close ]; then
  iid="${3:?}"
  updated="$(jq -ce --argjson iid "${iid}" '
    map(if .iid == $iid then .state="closed" else . end)
  ' "${TEST_MR_STATE}")"
  store_mrs "${updated}"
  printf 'close:%s\n' "${iid}" >>"${TEST_GLAB_LOG}"
  exit 0
fi

if [ "${1:-}" = mr ] && [ "${2:-}" = create ]; then
  shift 2
  source_branch=""
  target_branch=""
  description=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-branch) source_branch="$2"; shift 2 ;;
      --target-branch) target_branch="$2"; shift 2 ;;
      --description) description="$2"; shift 2 ;;
      --repo|--title) shift 2 ;;
      --yes) shift ;;
      *) exit 92 ;;
    esac
  done
  [ "${source_branch}" = 'issue/41+43' ] || exit 93
  [ "${target_branch}" = main ] || exit 94
  if [ "${TEST_FAIL_CREATE_ONCE:-false}" = true ] \
      && [ ! -f "${TEST_FAIL_ONCE_MARKER}" ]; then
    : >"${TEST_FAIL_ONCE_MARKER}"
    printf 'create-failed:%s\n' "${source_branch}" >>"${TEST_GLAB_LOG}"
    exit 95
  fi
  sha="$(git --git-dir="${TEST_REMOTE_REPO}" rev-parse \
    "refs/heads/${source_branch}")"
  created="$(jq -nc \
    --arg source "${source_branch}" \
    --arg target "${target_branch}" \
    --arg sha "${sha}" \
    --arg description "${description}" '{
      iid:17,
      web_url:"https://gitlab.test/group/project/-/merge_requests/17",
      source_branch:$source,target_branch:$target,sha:$sha,state:"opened",
      author:{username:"req-executor-bot"},description:$description
    }')"
  updated="$(jq -ce --argjson created "${created}" '. + [$created]' \
    "${TEST_MR_STATE}")"
  store_mrs "${updated}"
  printf 'create:%s\n' "${source_branch}" >>"${TEST_GLAB_LOG}"
  printf '%s\n' 'https://gitlab.test/group/project/-/merge_requests/17'
  exit 0
fi

echo "unexpected glab invocation: $*" >&2
exit 96
EOF
chmod +x "${BIN_DIR}/glab" "${FIXTURE_SCRIPTS}"/*.sh

git init --bare -q "${REMOTE_REPO}"
git -C "${REPO_PATH}" init -q
git -C "${REPO_PATH}" config user.email req-executor-test@example.invalid
git -C "${REPO_PATH}" config user.name req-executor-test
git -C "${REPO_PATH}" commit --allow-empty -m root >/dev/null
HEAD_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"
git -C "${REPO_PATH}" remote add origin "${REMOTE_REPO}"
git -C "${REPO_PATH}" push origin \
  "${HEAD_SHA}:refs/heads/main" \
  "${HEAD_SHA}:refs/heads/issue/41" >/dev/null
git -C "${REPO_PATH}" update-ref refs/remotes/origin/main "${HEAD_SHA}"
git -C "${REPO_PATH}" update-ref refs/remotes/origin/issue/41 "${HEAD_SHA}"

ISSUE_STATE_DIR="${REPO_PATH}/.req_executor/issues/issue-41"
mkdir -p "${ISSUE_STATE_DIR}"
jq -n --arg sha "${HEAD_SHA}" '{
  iid:41,status:"done",latest_execution_id:1,
  dependency_pinned_execution_id:1,
  work_branch:"issue/41",branch_members:[41],shared_branch_role:null,
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
  commit_sha:$sha,work_branch_sha:$sha,dependency_history_verified:true,
  merge_request_url:"https://gitlab.test/group/project/-/merge_requests/16"
}' >"${ISSUE_STATE_DIR}/state.json"
chmod 600 "${ISSUE_STATE_DIR}/state.json"

jq -n --arg sha "${HEAD_SHA}" '[{
  iid:16,
  web_url:"https://gitlab.test/group/project/-/merge_requests/16",
  source_branch:"issue/41",target_branch:"main",sha:$sha,state:"opened",
  author:{username:"req-executor-bot"},description:"Closes #41"
}]' >"${MR_STATE}"

export TEST_REPO_PATH="${REPO_PATH}"
export TEST_REMOTE_REPO="${REMOTE_REPO}"
export TEST_PROJECT_FULL='group/project'
export TEST_PROJECT_URI='group%2Fproject'
export TEST_MR_STATE="${MR_STATE}"
export TEST_GLAB_LOG="${GLAB_LOG}"
export TEST_FAIL_ONCE_MARKER="${FAIL_ONCE_MARKER}"
export TEST_FAIL_CREATE_ONCE=true

run_migration() {
  MIGRATION_HEAD_IID=41 MIGRATION_TAIL_IID=43 \
    MIGRATION_TARGET_BRANCH=main \
    PATH="${BIN_DIR}:${PATH}" \
    bash "${FIXTURE_SCRIPTS}/migrate_shared_dependency_head.sh"
}

set +e
FIRST_OUTPUT="$(run_migration)"
FIRST_RC=$?
set -e
[ "${FIRST_RC}" -eq 75 ] \
  || fail "replacement MR failure did not leave a retryable migration"
printf '%s' "${FIRST_OUTPUT}" | jq -e '
  .status == "deferred" and .reason == "new_mr_create_unavailable"
' >/dev/null || fail "retryable migration emitted the wrong checkpoint status"
jq -e '
  .branch_migration.status == "pending"
  and .work_branch == "issue/41"
' "${ISSUE_STATE_DIR}/state.json" >/dev/null \
  || fail "migration checkpoint did not preserve ordinary A state"
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/41 \
  | wc -l | tr -d '[:space:]')" = 1 ] \
  || fail "retryable failure deleted A's old branch too early"
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/41+43 \
  | wc -l | tr -d '[:space:]')" = 1 ] \
  || fail "retryable failure did not preserve the exact replacement branch"
jq -e '
  (map(select(.iid == 16 and .state == "closed")) | length) == 1
  and (map(select(.iid == 17)) | length) == 0
' "${MR_STATE}" >/dev/null \
  || fail "retryable failure did not stop between old-MR close and replacement"

SECOND_OUTPUT="$(run_migration)"
printf '%s' "${SECOND_OUTPUT}" | jq -e --arg sha "${HEAD_SHA}" '
  .status == "ready" and .head_iid == 41 and .tail_iid == 43
  and .work_branch == "issue/41+43" and .commit_sha == $sha
  and .mr_iid == 17
' >/dev/null || fail "migration recovery did not produce the shared branch"
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/41 \
  | wc -l | tr -d '[:space:]')" = 0 ] \
  || fail "completed migration retained A's obsolete branch"
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/41+43 \
  | awk '{print $1}')" = "${HEAD_SHA}" ] \
  || fail "completed migration changed A's exact commit"
jq -e --arg sha "${HEAD_SHA}" '
  .work_branch == "issue/41+43"
  and .branch_members == [41,43]
  and .shared_branch_role == "head"
  and .commit_sha == $sha and .work_branch_sha == $sha
  and .mr_finalization.status == "verified_open"
  and .mr_finalization.iid == 17
  and .branch_migration.status == "completed"
  and .branch_migration.old_mr_iid == 16
  and .branch_migration.new_mr_iid == 17
' "${ISSUE_STATE_DIR}/state.json" >/dev/null \
  || fail "completed migration did not rewrite A's durable binding"
jq -e '
  (map(select(.iid == 16 and .state == "closed")) | length) == 1
  and (map(select(.iid == 17 and .state == "opened"
    and .source_branch == "issue/41+43")) | length) == 1
  and (.[1].description | contains("Closes #41"))
  and (.[1].description | contains("Closes #43"))
  and (.[1].description | contains("req_executor-shared-mr-intent:"))
' "${MR_STATE}" >/dev/null \
  || fail "replacement MR identity or closure coverage is invalid"

THIRD_OUTPUT="$(run_migration)"
printf '%s' "${THIRD_OUTPUT}" | jq -e '.status == "ready" and .mr_iid == 17' \
  >/dev/null || fail "completed migration was not replay-safe"
[ "$(grep -c '^close:16$' "${GLAB_LOG}")" -eq 1 ] \
  || fail "migration replay closed the old MR more than once"
[ "$(grep -c '^create:issue/41+43$' "${GLAB_LOG}")" -eq 1 ] \
  || fail "migration replay created a duplicate replacement MR"

echo "ok late dependency migration recovers and preserves one A commit plus one C commit branch"
