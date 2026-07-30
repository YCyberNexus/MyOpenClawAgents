#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-multi-heads.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PATH="${TEST_ROOT}/repo"
REMOTE_REPO="${TEST_ROOT}/origin.git"
MR_STATE="${TEST_ROOT}/mrs.json"
GLAB_LOG="${TEST_ROOT}/glab.log"

mkdir -p "${FIXTURE_SCRIPTS}" "${BIN_DIR}" "${REPO_PATH}"
cp "${SKILL_DIR}/scripts/migrate_shared_dependency_head.sh" \
  "${SKILL_DIR}/scripts/migrate_multi_dependency_heads.sh" \
  "${FIXTURE_SCRIPTS}/"

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

if [ "${1:-}" = api ] && [ "${2:-}" = -X ]; then
  [ "${3:-}" = PUT ] || exit 90
  endpoint="${4:-}"
  [ "${endpoint}" = projects/group%2Fproject/merge_requests/17 ] || exit 91
  [ "${5:-}" = -f ] || exit 92
  description="${6#description=}"
  updated="$(jq -ce --arg description "${description}" '
    map(if .iid == 17 then .description=$description else . end)
  ' "${TEST_MR_STATE}")"
  store_mrs "${updated}"
  printf 'update:17\n' >>"${TEST_GLAB_LOG}"
  exit 0
fi

if [ "${1:-}" = api ]; then
  endpoint="${2:-}"
  if [ "${endpoint}" = user ]; then
    jq -nc '{username:"req-executor-bot"}'
    exit 0
  fi
  case "${endpoint}" in
    projects/group%2Fproject/merge_requests/16|projects/group%2Fproject/merge_requests/18|projects/group%2Fproject/merge_requests/19|projects/group%2Fproject/merge_requests/20)
      iid="${endpoint##*/}"
      jq -ce --argjson iid "${iid}" '.[] | select(.iid == $iid)' \
        "${TEST_MR_STATE}"
      exit 0
      ;;
    projects/group%2Fproject/merge_requests/17)
      shared_sha="$(git --git-dir="${TEST_REMOTE_REPO}" rev-parse \
        refs/heads/issue/41+43)"
      jq -ce --arg sha "${shared_sha}" \
        '.[] | select(.iid == 17) | .sha=$sha' "${TEST_MR_STATE}"
      exit 0
      ;;
    projects/group%2Fproject/merge_requests\?*)
      case "${endpoint}" in
        *source_branch=issue%2F41%2B43*) source_branch='issue/41+43' ;;
        *source_branch=issue%2F41*) source_branch='issue/41' ;;
        *source_branch=issue%2F42*) source_branch='issue/42' ;;
        *source_branch=issue%2F44*) source_branch='issue/44' ;;
        *source_branch=issue%2F45*) source_branch='issue/45' ;;
        *) exit 93 ;;
      esac
      if [[ "${endpoint}" == *state=opened* ]]; then
        jq -ce --arg source "${source_branch}" '
          [.[] | select(.source_branch == $source and .state == "opened")]
        ' "${TEST_MR_STATE}"
      else
        jq -ce --arg source "${source_branch}" '
          [.[] | select(.source_branch == $source)]
        ' "${TEST_MR_STATE}"
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
      *) exit 94 ;;
    esac
  done
  [ "${source_branch}" = issue/41+43 ] || exit 95
  [ "${target_branch}" = main ] || exit 96
  sha="$(git --git-dir="${TEST_REMOTE_REPO}" rev-parse \
    "refs/heads/${source_branch}")"
  created="$(jq -nc \
    --arg source "${source_branch}" --arg target "${target_branch}" \
    --arg sha "${sha}" --arg description "${description}" '{
      iid:17,web_url:"https://gitlab.test/group/project/-/merge_requests/17",
      source_branch:$source,target_branch:$target,sha:$sha,state:"opened",
      author:{username:"req-executor-bot"},description:$description
    }')"
  updated="$(jq -ce --argjson created "${created}" '. + [$created]' \
    "${TEST_MR_STATE}")"
  store_mrs "${updated}"
  printf 'create:17\n' >>"${TEST_GLAB_LOG}"
  printf '%s\n' 'https://gitlab.test/group/project/-/merge_requests/17'
  exit 0
fi

echo "unexpected glab invocation: $*" >&2
exit 97
EOF
chmod +x "${BIN_DIR}/glab" "${FIXTURE_SCRIPTS}"/*.sh

git init --bare -q "${REMOTE_REPO}"
git -C "${REPO_PATH}" init -q
git -C "${REPO_PATH}" config user.email req-executor-test@example.invalid
git -C "${REPO_PATH}" config user.name req-executor-test
git -C "${REPO_PATH}" commit --allow-empty -m root >/dev/null
ROOT_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"

git -C "${REPO_PATH}" checkout -qb source-41 "${ROOT_SHA}"
printf 'head 41\n' >"${REPO_PATH}/head-41.txt"
git -C "${REPO_PATH}" add head-41.txt
git -C "${REPO_PATH}" commit -qm 'head 41'
HEAD_41_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"

git -C "${REPO_PATH}" checkout -qb source-42 "${ROOT_SHA}"
printf 'head 42\n' >"${REPO_PATH}/head-42.txt"
git -C "${REPO_PATH}" add head-42.txt
git -C "${REPO_PATH}" commit -qm 'head 42'
HEAD_42_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"

git -C "${REPO_PATH}" checkout -qb source-44 "${ROOT_SHA}"
printf 'source 44\n' >"${REPO_PATH}/conflict.txt"
git -C "${REPO_PATH}" add conflict.txt
git -C "${REPO_PATH}" commit -qm 'conflicting head 44'
HEAD_44_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"

git -C "${REPO_PATH}" checkout -qb source-45 "${ROOT_SHA}"
printf 'source 45\n' >"${REPO_PATH}/conflict.txt"
git -C "${REPO_PATH}" add conflict.txt
git -C "${REPO_PATH}" commit -qm 'conflicting head 45'
HEAD_45_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"

git -C "${REPO_PATH}" remote add origin "${REMOTE_REPO}"
git -C "${REPO_PATH}" push origin \
  "${ROOT_SHA}:refs/heads/main" \
  "${HEAD_41_SHA}:refs/heads/issue/41" \
  "${HEAD_42_SHA}:refs/heads/issue/42" \
  "${HEAD_44_SHA}:refs/heads/issue/44" \
  "${HEAD_45_SHA}:refs/heads/issue/45" >/dev/null
git -C "${REPO_PATH}" update-ref refs/remotes/origin/main "${ROOT_SHA}"
git -C "${REPO_PATH}" update-ref refs/remotes/origin/issue/41 "${HEAD_41_SHA}"
git -C "${REPO_PATH}" update-ref refs/remotes/origin/issue/42 "${HEAD_42_SHA}"
git -C "${REPO_PATH}" update-ref refs/remotes/origin/issue/44 "${HEAD_44_SHA}"
git -C "${REPO_PATH}" update-ref refs/remotes/origin/issue/45 "${HEAD_45_SHA}"

for source_iid in 41 42 44 45; do
  state_dir="${REPO_PATH}/.req_executor/issues/issue-${source_iid}"
  mkdir -p "${state_dir}"
  case "${source_iid}" in
    41) source_sha="${HEAD_41_SHA}"; source_mr_iid=16 ;;
    42) source_sha="${HEAD_42_SHA}"; source_mr_iid=18 ;;
    44) source_sha="${HEAD_44_SHA}"; source_mr_iid=19 ;;
    45) source_sha="${HEAD_45_SHA}"; source_mr_iid=20 ;;
  esac
  jq -n --argjson iid "${source_iid}" --arg sha "${source_sha}" \
    --argjson mr_iid "${source_mr_iid}" '{
      iid:$iid,status:"done",latest_execution_id:1,
      dependency_pinned_execution_id:1,
      work_branch:("issue/" + ($iid|tostring)),branch_members:[$iid],
      shared_branch_role:null,dependency_iid:null,dependency_branch:null,
      dependency_base_sha:null,commit_sha:$sha,work_branch_sha:$sha,
      dependency_history_verified:true,
      merge_request_url:("https://gitlab.test/group/project/-/merge_requests/" + ($mr_iid|tostring))
    }' >"${state_dir}/state.json"
  chmod 600 "${state_dir}/state.json"
done

jq -n --arg sha41 "${HEAD_41_SHA}" --arg sha42 "${HEAD_42_SHA}" \
  --arg sha44 "${HEAD_44_SHA}" --arg sha45 "${HEAD_45_SHA}" '[
  {iid:16,web_url:"https://gitlab.test/group/project/-/merge_requests/16",
   source_branch:"issue/41",target_branch:"main",sha:$sha41,state:"opened",
   author:{username:"req-executor-bot"},description:"Closes #41"},
  {iid:18,web_url:"https://gitlab.test/group/project/-/merge_requests/18",
   source_branch:"issue/42",target_branch:"main",sha:$sha42,state:"opened",
   author:{username:"req-executor-bot"},description:"Closes #42"},
  {iid:19,web_url:"https://gitlab.test/group/project/-/merge_requests/19",
   source_branch:"issue/44",target_branch:"main",sha:$sha44,state:"opened",
   author:{username:"req-executor-bot"},description:"Closes #44"},
  {iid:20,web_url:"https://gitlab.test/group/project/-/merge_requests/20",
   source_branch:"issue/45",target_branch:"main",sha:$sha45,state:"opened",
   author:{username:"req-executor-bot"},description:"Closes #45"}
]' >"${MR_STATE}"

export TEST_REPO_PATH="${REPO_PATH}"
export TEST_REMOTE_REPO="${REMOTE_REPO}"
export TEST_PROJECT_FULL=group/project
export TEST_PROJECT_URI=group%2Fproject
export TEST_MR_STATE="${MR_STATE}"
export TEST_GLAB_LOG="${GLAB_LOG}"

run_migration() {
  MIGRATION_DEPENDENCY_IIDS_JSON='[41,42]' \
    MIGRATION_TAIL_IID=43 MIGRATION_TARGET_BRANCH=main \
    PATH="${BIN_DIR}:${PATH}" \
    bash "${FIXTURE_SCRIPTS}/migrate_multi_dependency_heads.sh"
}

# A content conflict is terminal for this fan-in candidate, but must not
# mutate either source MR/ref or create the shared branch. OpenClaw surfaces
# the deterministic reason and waits for a human-authored resolution.
set +e
CONFLICT_OUTPUT="$(
  MIGRATION_DEPENDENCY_IIDS_JSON='[44,45]' \
    MIGRATION_TAIL_IID=46 MIGRATION_TARGET_BRANCH=main \
    PATH="${BIN_DIR}:${PATH}" \
    bash "${FIXTURE_SCRIPTS}/migrate_multi_dependency_heads.sh"
)"
CONFLICT_RC=$?
set -e
[ "${CONFLICT_RC}" -eq 6 ] \
  || fail 'conflicting aggregation did not fail terminally'
printf '%s' "${CONFLICT_OUTPUT}" | jq -e '
  .status == "failed" and .reason == "dependency_merge_conflict"
  and .head_iid == 44 and .tail_iid == 46
  and .dependency_iids == [44,45]
' >/dev/null || fail 'conflicting aggregation did not expose a stable reason'
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/44 \
  | awk '{print $1}')" = "${HEAD_44_SHA}" ] \
  || fail 'conflicting aggregation moved the first source branch'
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/45 \
  | awk '{print $1}')" = "${HEAD_45_SHA}" ] \
  || fail 'conflicting aggregation moved the second source branch'
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/44+46 \
  | wc -l | tr -d '[:space:]')" = 0 ] \
  || fail 'conflicting aggregation created a shared branch'
jq -e '
  (map(select((.iid == 19 or .iid == 20) and .state == "opened")) | length) == 2
' "${MR_STATE}" >/dev/null || fail 'conflicting aggregation closed a source MR'
[ ! -s "${GLAB_LOG}" ] \
  || fail 'conflicting aggregation issued a mutating GitLab command'

FIRST_OUTPUT="$(run_migration)"
printf '%s' "${FIRST_OUTPUT}" | jq -e '
  .status == "ready" and .head_iid == 41 and .tail_iid == 43
  and .dependency_iids == [41,42]
  and .work_branch == "issue/41+43"
  and (.commit_sha | type == "string" and length == 40)
  and .mr_iid == 17
' >/dev/null || fail 'multi-head migration did not become ready'
AGGREGATE_SHA="$(jq -r '.commit_sha' <<<"${FIRST_OUTPUT}")"

[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/41+43 \
  | awk '{print $1}')" = "${AGGREGATE_SHA}" ] \
  || fail 'shared branch does not point at the aggregate commit'
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/41 \
  | wc -l | tr -d '[:space:]')" = 0 ] \
  || fail 'anchor ordinary branch was not retired'
[ "$(git ls-remote --heads "${REMOTE_REPO}" refs/heads/issue/42 \
  | wc -l | tr -d '[:space:]')" = 0 ] \
  || fail 'additional dependency branch was not retired'
git -C "${REPO_PATH}" merge-base --is-ancestor \
  "${HEAD_41_SHA}" "${AGGREGATE_SHA}" \
  || fail 'aggregate commit omitted the anchor commit'
git -C "${REPO_PATH}" merge-base --is-ancestor \
  "${HEAD_42_SHA}" "${AGGREGATE_SHA}" \
  || fail 'aggregate commit omitted the additional dependency commit'

jq -e '
  (map(select(.iid == 16 and .state == "closed")) | length) == 1
  and (map(select(.iid == 18 and .state == "closed")) | length) == 1
  and (map(select(.iid == 17 and .state == "opened"
    and ((.description | split("\n")) | index("Closes #41") != null)
    and ((.description | split("\n")) | index("Closes #42") != null)
    and ((.description | split("\n")) | index("Closes #43") != null))) | length) == 1
' "${MR_STATE}" >/dev/null || fail 'combined MR identity is incomplete'

jq -e --arg sha "${AGGREGATE_SHA}" '
  .work_branch == "issue/41+43" and .branch_members == [41,43]
  and .shared_branch_role == "head"
  and .commit_sha == $sha and .work_branch_sha == $sha
  and .mr_finalization.commit_sha == $sha
  and .dependency_aggregation.status == "completed"
  and .dependency_aggregation.dependency_iids == [41,42]
' "${REPO_PATH}/.req_executor/issues/issue-41/state.json" >/dev/null \
  || fail 'anchor state did not freeze the aggregate identity'
jq -e --arg sha "${AGGREGATE_SHA}" '
  .mr_finalization.status == "superseded"
  and .joined_dependency_group.dependency_iids == [41,42]
  and .joined_dependency_group.aggregate_sha == $sha
  and .merge_request_url ==
    "https://gitlab.test/group/project/-/merge_requests/17"
' "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail 'additional dependency state did not join the combined MR'

SECOND_OUTPUT="$(run_migration)"
printf '%s' "${SECOND_OUTPUT}" | jq -e --arg sha "${AGGREGATE_SHA}" '
  .status == "ready" and .commit_sha == $sha and .mr_iid == 17
' >/dev/null || fail 'completed aggregation was not replayable'
[ "$(jq '[.[] | select(.iid == 17)] | length' "${MR_STATE}")" = 1 ] \
  || fail 'replay created a duplicate shared MR'
[ "$(grep -c '^create:17$' "${GLAB_LOG}")" = 1 ] \
  || fail 'replay invoked shared MR creation again'

printf 'ok multi dependency head migration\n'
