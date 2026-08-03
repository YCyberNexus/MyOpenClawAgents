#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVEN_TOPUP="${SKILL_DIR}/scripts/dispatch_driven_topup.sh"

fail() {
  echo "$1" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_mode() {
  local mode
  if mode="$(stat -f '%Lp' "$1" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -c '%a' "$1"
  fi
}

[ -f "${DRIVEN_TOPUP}" ] || fail "dispatch_driven_topup.sh is missing"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-driven-topup.XXXXXX")"
FIXTURE_SKILL="${TEST_ROOT}/skill"
FIXTURE_SCRIPTS="${FIXTURE_SKILL}/scripts"
FIXTURE_REFS="${FIXTURE_SKILL}/references"
CONFIG_DIR="${TEST_ROOT}/config"
BIN_DIR="${TEST_ROOT}/bin"
MODE_BIN="${TEST_ROOT}/mode-bin"
REPO_PARENT="${TEST_ROOT}/repos"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
PROJECT_REPO="${REPO_PARENT}/group/project"
STATE_DIR="${PROJECT_REPO}/.req_executor/_dispatcher"
STATE_FILE="${STATE_DIR}/campaign_state.json"
ALLOC_LOG="${TEST_ROOT}/allocate.log"
PREP_LOG="${TEST_ROOT}/prepare.log"
LABEL_LOG="${TEST_ROOT}/labels.log"
GLAB_LOG="${TEST_ROOT}/glab.log"
MIGRATION_LOG="${TEST_ROOT}/migration.log"
TRIGGER_CAPTURE="${TEST_ROOT}/internal-trigger.txt"

mkdir -p "${FIXTURE_SCRIPTS}" "${FIXTURE_REFS}" "${CONFIG_DIR}" \
  "${BIN_DIR}" "${MODE_BIN}" "${PROJECT_REPO}" \
  "${SCHEDULER_ROOT}/batches/batch-A" \
  "${SCHEDULER_ROOT}/batches/batch-B" \
  "${SCHEDULER_ROOT}/batches/batch-C"
cat >"${MODE_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_STAT_STYLE:-}" in
  bsd)
    [ "${1:-}" = -f ] && [ "${2:-}" = %Lp ] || exit 2
    printf '600\n'
    ;;
  gnu)
    if [ "${1:-}" = -f ]; then
      printf 'filesystem-noise-that-must-stay-captured\n'
      exit 1
    fi
    [ "${1:-}" = -c ] && [ "${2:-}" = %a ] || exit 2
    printf '600\n'
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "${MODE_BIN}/stat"
git -C "${PROJECT_REPO}" init -q
git -C "${PROJECT_REPO}" config user.email "req-executor-test@example.invalid"
git -C "${PROJECT_REPO}" config user.name "req-executor-test"
git -C "${PROJECT_REPO}" commit --allow-empty -m "fixture root" >/dev/null
git -C "${PROJECT_REPO}" symbolic-ref \
  refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/main HEAD
mkdir -p "${STATE_DIR}"

for name in dispatch_driven_topup.sh dispatch_prepare_tick.sh _dispatch_lib.sh \
  branch_utils.sh env_paths.sh git_network_guard.sh glab_auth.sh \
  gitlab_env_resolver.sh parse_issue_base_branch.sh parse_issue_dependency.sh \
  resolve_dependency_dag_base.sh resolve_driven_repo_path.sh; do
  cp "${SKILL_DIR}/scripts/${name}" "${FIXTURE_SCRIPTS}/${name}"
done
cp "${SKILL_DIR}/references/executor_prompt.md" "${FIXTURE_REFS}/executor_prompt.md"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.test.invalid
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=fake-token-direct
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${REPO_PARENT}
EXECUTOR_MAX_CONCURRENCY=4
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EOF

jq -nc '{version:1,project:"group/project",iids:[2,3,9,10]}' \
  >"${SCHEDULER_ROOT}/batches/batch-A/snapshot.json"
jq -nc '{version:1,project:"group/project",iids:[4,5]}' \
  >"${SCHEDULER_ROOT}/batches/batch-B/snapshot.json"
jq -nc '{version:1,project:"group/project",iids:[6]}' \
  >"${SCHEDULER_ROOT}/batches/batch-C/snapshot.json"

cat >"${FIXTURE_SCRIPTS}/ensure_labels.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/clone_or_pull.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${DISPATCHER_LOG_DIR}/reconcile-20260711T000000Z.json"
mkdir -p "${DISPATCHER_LOG_DIR}"
jq -nc '[
  {iid:1,labels:["doing"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:false,has_done_pr:false,needs_continue:false,
   has_retry:false,has_blocked:false,has_failed:false,has_timeout:false,
   user_reopened:false},
  {iid:2,labels:["blocked-dispatcher"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:false,has_done_pr:false,needs_continue:false,
   has_retry:false,has_blocked:true,has_failed:false,has_timeout:false,
   user_reopened:false},
  {iid:3,labels:["blocked-dispatcher"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:false,has_done_pr:false,needs_continue:false,
   has_retry:false,has_blocked:true,has_failed:false,has_timeout:false,
   user_reopened:false},
  {iid:4,labels:[],missing:false,is_closed_on_gitlab:true,
   is_done_on_gitlab:true,has_done_pr:false,needs_continue:false,
   has_retry:false,has_blocked:false,has_failed:false,has_timeout:false,
   user_reopened:false},
  {iid:5,labels:["pr"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:true,has_done_pr:true,needs_continue:false,
   has_retry:false,has_blocked:false,has_failed:false,has_timeout:false,
   user_reopened:false},
  {iid:6,labels:["pr","continue"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:true,has_done_pr:true,needs_continue:true,
   has_retry:false,has_blocked:false,has_failed:false,has_timeout:false,
   user_reopened:false}
]' >"${path}"
printf '%s\n' "${path}"
EOF
cat >"${FIXTURE_SCRIPTS}/allocate_execution_id.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${IID}" >>"${TEST_ALLOC_LOG}"
printf '%s\n' "${FAKE_ALLOC_EXECUTION_ID:-1}"
EOF
cat >"${FIXTURE_SCRIPTS}/prepare_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
printf '%s|%s|%s\n' "${ISSUE_IID}" "${BRANCH}" "${ISSUE_MODE}" >>"${TEST_PREP_LOG}"
if [ "${FAKE_PREPARE_ATTEMPT_FAIL_IID:-}" = "${ISSUE_IID}" ]; then
  exit 82
fi
if [ "${TEST_EXPECT_CONTINUE_BASE_REQUIRED_IID:-}" = "${ISSUE_IID}" ] \
    && [ "${CONTINUE_BASE_REQUIRED:-false}" != true ]; then
  echo "missing CONTINUE_BASE_REQUIRED for ${ISSUE_IID}" >&2
  exit 88
fi
if [ "${TEST_EXPECT_CONTINUE_BASE_REQUIRED_IID:-}" = "${ISSUE_IID}" ] \
    && ! [[ "${CONTINUE_BASE_SHA:-}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "missing CONTINUE_BASE_SHA for ${ISSUE_IID}" >&2
  exit 89
fi
if [ "${TEST_EXPECT_CONTINUE_BASE_REQUIRED_IID:-}" = "${ISSUE_IID}" ] \
    && [[ "${CONTINUE_BASE_REF:-}" != "refs/remotes/origin/${WORK_BRANCH}" ]] \
    && [ "${CONTINUE_BASE_REF:-}" != "refs/heads/issue/${ISSUE_IID}" ]; then
  echo "missing exact CONTINUE_BASE_REF for ${ISSUE_IID}" >&2
  exit 90
fi
source "${SCRIPT_DIR}/env_paths.sh"
mkdir -p "${WORKTREE_DIR}/.git" "${WORKTREE_DIR}/.claude" "${LOG_DIR}" "${OUTPUT_DIR}"
local_branch="issue/${ISSUE_IID}"
if [ "${DEPENDENCY_CONTRACT_VERSION:-}" = 2 ]; then
  prepared_parent_sha="${EXPECTED_COMMIT_PARENT_SHA:?}"
  git -C "${REPO_PATH}" update-ref \
    "refs/heads/${local_branch}" "${prepared_parent_sha}"
elif [ -n "${SHARED_BRANCH_ROLE:-}" ]; then
  if [ "${SHARED_BRANCH_ROLE}" = tail ]; then
    prepared_parent_sha="${EXPECTED_COMMIT_PARENT_SHA:?}"
  else
    prepared_parent_sha="$(git -C "${REPO_PATH}" rev-parse \
      "refs/remotes/origin/${BRANCH}^{commit}")"
  fi
  git -C "${REPO_PATH}" update-ref \
    "refs/heads/${local_branch}" "${prepared_parent_sha}"
fi
printf '%s\n%s\n' "${ISSUE_MODE}" "${local_branch}"
EOF
cat >"${FIXTURE_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${ISSUE_IID}" "$*" >>"${TEST_LABEL_LOG}"
if [ "$*" = "add doing" ] && [ -n "${FAKE_MUTATION_PRESERVE:-}" ]; then
  printf 'preserve:%s\n' "${FAKE_MUTATION_PRESERVE}"
  exit 0
fi
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/build_prompt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -f "${ISSUE_JSON_FILE}" ] && [ ! -L "${ISSUE_JSON_FILE}" ]
jq -e 'type == "object" and (.description | type == "string")' \
  "${ISSUE_JSON_FILE}" >/dev/null
[ "${FAKE_BUILD_PROMPT_FAIL_IID:-}" != "${ISSUE_IID}" ] || exit 83
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/capture_prepare_tick.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${GITLAB_TOKEN:-}" = "fake-token-direct" ] || exit 91
cat >"${TEST_TRIGGER_CAPTURE}"
jq -nc '{status:"no_eligible_iids",dispatch_entries:[],chat_summary:"capture_only"}'
EOF
cat >"${FIXTURE_SCRIPTS}/migrate_shared_dependency_head.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="${ISSUES_ROOT}/issue-${MIGRATION_HEAD_IID}/state.json"
printf '%s+%s\n' "${MIGRATION_HEAD_IID}" "${MIGRATION_TAIL_IID}" \
  >>"${TEST_MIGRATION_LOG}"
if [ ! -f "${state_file}" ] || [ -L "${state_file}" ]; then
  jq -nc --argjson head "${MIGRATION_HEAD_IID}" \
    --argjson tail "${MIGRATION_TAIL_IID}" '{
      status:"deferred",reason:"dependency_head_state_missing",
      head_iid:$head,tail_iid:$tail
    }'
  exit 75
fi
sha="$(jq -er '.commit_sha | select(type == "string")' "${state_file}")" \
  || exit 75
new_branch="issue/${MIGRATION_HEAD_IID}+${MIGRATION_TAIL_IID}"
state_branch="$(jq -r '.work_branch // ""' "${state_file}")"
if [ "${state_branch}" = "issue/${MIGRATION_HEAD_IID}" ]; then
  migrated_tmp="$(mktemp "${state_file}.migrated.XXXXXX")"
  jq --arg branch "${new_branch}" \
    --arg sha "${sha}" \
    --argjson head "${MIGRATION_HEAD_IID}" \
    --argjson tail "${MIGRATION_TAIL_IID}" \
    --arg target "${MIGRATION_TARGET_BRANCH}" '
    .work_branch=$branch
    | .branch_members=[$head,$tail]
    | .shared_branch_role="head"
    | .work_branch_sha=$sha
    | .dependency_history_verified=true
    | .dependency_pinned_execution_id=.latest_execution_id
    | .merge_request_url="https://gitlab.test/group/project/-/merge_requests/17"
    | .mr_finalization={
        status:"verified_open",source_execution_id:.latest_execution_id,
        work_branch:$branch,branch_members:[$head,$tail],
        shared_branch_role:"head",commit_sha:$sha,
        intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        target_branch:$target,iid:17,
        web_url:"https://gitlab.test/group/project/-/merge_requests/17",
        mr_action:"created",verified_at:"2026-07-20T00:00:00Z"
      }
    | .branch_migration={
        version:1,status:"completed",head_iid:$head,tail_iid:$tail,
        from_branch:("issue/"+($head|tostring)),to_branch:$branch,
        commit_sha:$sha,target_branch:$target,old_mr_iid:16,
        old_mr_url:"https://gitlab.test/group/project/-/merge_requests/16",
        new_mr_iid:17,
        new_mr_url:"https://gitlab.test/group/project/-/merge_requests/17",
        intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        source_execution_id:.latest_execution_id,
        started_at:"2026-07-20T00:00:00Z",
        completed_at:"2026-07-20T00:00:01Z"
      }
  ' "${state_file}" >"${migrated_tmp}"
  chmod 600 "${migrated_tmp}"
  mv "${migrated_tmp}" "${state_file}"
elif [ "${state_branch}" != "${new_branch}" ]; then
  jq -nc --argjson head "${MIGRATION_HEAD_IID}" \
    --argjson tail "${MIGRATION_TAIL_IID}" '{
      status:"failed",reason:"dependency_head_not_migration_safe",
      head_iid:$head,tail_iid:$tail
    }'
  exit 6
fi
git -C "${REPO_PATH}" update-ref \
  "refs/remotes/origin/${new_branch}" "${sha}"
git -C "${REPO_PATH}" update-ref -d \
  "refs/remotes/origin/issue/${MIGRATION_HEAD_IID}" "${sha}" \
  2>/dev/null || true
jq -nc --argjson head "${MIGRATION_HEAD_IID}" \
  --argjson tail "${MIGRATION_TAIL_IID}" \
  --arg branch "${new_branch}" --arg sha "${sha}" '{
    status:"ready",reason:"late_dependency_head_migrated",
    head_iid:$head,tail_iid:$tail,work_branch:$branch,commit_sha:$sha,
    mr_iid:17,mr_url:"https://gitlab.test/group/project/-/merge_requests/17",
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }'
EOF
cat >"${FIXTURE_SCRIPTS}/migrate_multi_dependency_heads.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
anchor_iid="$(jq -r '.[0]' <<<"${MIGRATION_DEPENDENCY_IIDS_JSON}")"
aggregate_sha="${FAKE_MULTI_AGGREGATE_SHA:?}"
state_file="${ISSUES_ROOT}/issue-${anchor_iid}/state.json"
new_branch="issue/${anchor_iid}+${MIGRATION_TAIL_IID}"
printf 'multi:%s->%s\n' "$(jq -c . <<<"${MIGRATION_DEPENDENCY_IIDS_JSON}")" \
  "${MIGRATION_TAIL_IID}" >>"${TEST_MIGRATION_LOG}"
state_tmp="$(mktemp "${state_file}.multi.XXXXXX")"
jq --argjson head "${anchor_iid}" \
  --argjson tail "${MIGRATION_TAIL_IID}" \
  --argjson dependencies "${MIGRATION_DEPENDENCY_IIDS_JSON}" \
  --arg branch "${new_branch}" --arg sha "${aggregate_sha}" \
  --arg target "${MIGRATION_TARGET_BRANCH}" '
  .work_branch=$branch
  | .branch_members=[$head,$tail]
  | .shared_branch_role="head"
  | .commit_sha=$sha
  | .work_branch_sha=$sha
  | .dependency_history_verified=true
  | .dependency_pinned_execution_id=.latest_execution_id
  | .merge_request_url="https://gitlab.test/group/project/-/merge_requests/17"
  | .mr_finalization={
      status:"verified_open",source_execution_id:.latest_execution_id,
      work_branch:$branch,branch_members:[$head,$tail],
      shared_branch_role:"head",commit_sha:$sha,
      intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      target_branch:$target,iid:17,
      web_url:"https://gitlab.test/group/project/-/merge_requests/17",
      mr_action:"created",verified_at:"2026-07-20T00:00:00Z"
    }
  | .dependency_aggregation={
      version:1,status:"completed",anchor_iid:$head,tail_iid:$tail,
      dependency_iids:$dependencies,work_branch:$branch,
      target_branch:$target,aggregate_sha:$sha,
      sources:[],started_at:"2026-07-20T00:00:00Z",
      completed_at:"2026-07-20T00:00:01Z"
    }
' "${state_file}" >"${state_tmp}"
chmod 600 "${state_tmp}"
mv "${state_tmp}" "${state_file}"
git -C "${REPO_PATH}" update-ref \
  "refs/remotes/origin/${new_branch}" "${aggregate_sha}"
jq -nc --argjson head "${anchor_iid}" \
  --argjson tail "${MIGRATION_TAIL_IID}" \
  --argjson dependencies "${MIGRATION_DEPENDENCY_IIDS_JSON}" \
  --arg branch "${new_branch}" --arg sha "${aggregate_sha}" '{
    status:"ready",reason:"multi_dependency_heads_aggregated",
    head_iid:$head,tail_iid:$tail,dependency_iids:$dependencies,
    work_branch:$branch,commit_sha:$sha,mr_iid:17,
    mr_url:"https://gitlab.test/group/project/-/merge_requests/17",
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }'
EOF
cat >"${BIN_DIR}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'api user' ]; then
  jq -cn '{username:"req-executor-bot"}'
  exit 0
fi
if [ -n "${FAKE_DAG_MRS_JSON:-}" ] \
    && [[ "$*" =~ ^api\ projects/group%2Fproject/merge_requests/([1-9][0-9]*)$ ]]; then
  mr_iid="${BASH_REMATCH[1]}"
  jq -ce --argjson iid "${mr_iid}" \
    '.[] | select(.iid == $iid)' <<<"${FAKE_DAG_MRS_JSON}"
  exit 0
fi
if [ -n "${FAKE_DAG_MRS_JSON:-}" ] \
    && [[ "$*" == api\ projects/group%2Fproject/merge_requests\?* ]]; then
  request_args="$*"
  encoded_source="${request_args#*source_branch=}"
  encoded_source="${encoded_source%%&*}"
  source_branch="${encoded_source//%2F//}"
  source_branch="${source_branch//%2B/+}"
  jq -c --arg source_branch "${source_branch}" '
    [.[] | select(
      .state == "opened" and .source_branch == $source_branch)
      | {iid,web_url,source_branch,state}]
  ' <<<"${FAKE_DAG_MRS_JSON}"
  exit 0
fi
if [ "$*" = 'api projects/group%2Fproject/merge_requests/17' ]; then
  jq -cn \
    --arg sha "${FAKE_SHARED_MR_SHA:?}" \
    --arg state "${FAKE_SHARED_MR_STATE:-opened}" \
    --arg target "${FAKE_SHARED_MR_TARGET:-main}" '{
      iid:17,
      web_url:"https://gitlab.test/group/project/-/merge_requests/17",
      source_branch:"issue/9+2",target_branch:$target,sha:$sha,state:$state,
      author:{username:"req-executor-bot"},
      description:("Closes #9\nCloses #2\n"
        + "<!-- req_executor-shared-mr-intent:"
        + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->")
    }'
  exit 0
fi
if [[ "$*" == api\ projects/group%2Fproject/merge_requests\?* ]]; then
  if [ "${FAKE_SHARED_MR_STATE:-opened}" = opened ]; then
    jq -cn '[{
      iid:17,
      web_url:"https://gitlab.test/group/project/-/merge_requests/17",
      source_branch:"issue/9+2",state:"opened"
    }]'
  else
    jq -cn '[]'
  fi
  exit 0
fi
case "$*" in
  *'/issues/2') iid=2; labels='["blocked-dispatcher"]' ;;
  *'/issues/3') iid=3; labels='["blocked-dispatcher"]' ;;
  *'/issues/6') iid=6; labels='["pr","continue"]' ;;
  *'/issues/9')
    iid=9
    if [ -n "${FAKE_DEPENDENCY_LABELS_JSON:-}" ]; then
      labels="${FAKE_DEPENDENCY_LABELS_JSON}"
    elif [ -n "${FAKE_DEPENDENCY_LABEL:-}" ]; then
      labels="[\"${FAKE_DEPENDENCY_LABEL}\"]"
    else
      labels='[]'
    fi
    ;;
  *'/issues/10') iid=10; labels='[]' ;;
  *)
    echo "unexpected glab invocation: $*" >&2
    exit 97
    ;;
esac
if [ -n "${FAKE_LIVE_LABEL:-}" ]; then
  labels="[\"${FAKE_LIVE_LABEL}\"]"
fi
description="body"
if [ "${iid}" = "${FAKE_DEPENDENT_IID:-}" ]; then
  description="${FAKE_DEPENDENCY_DESCRIPTION:-body}"
  if [ -n "${FAKE_DEPENDENT_LABELS_JSON:-}" ]; then
    labels="${FAKE_DEPENDENT_LABELS_JSON}"
  fi
fi
if [ -n "${FAKE_ISSUE_DESCRIPTIONS_JSON:-}" ]; then
  custom_description="$(jq -r --arg iid "${iid}" '
    if has($iid) then .[$iid] else null end
  ' <<<"${FAKE_ISSUE_DESCRIPTIONS_JSON}")"
  if [ "${custom_description}" != null ]; then
    description="${custom_description}"
  fi
fi
if [ -n "${FAKE_ISSUE_LABELS_JSON:-}" ]; then
  custom_labels="$(jq -c --arg iid "${iid}" '
    if has($iid) then .[$iid] else null end
  ' <<<"${FAKE_ISSUE_LABELS_JSON}")"
  if [ "${custom_labels}" != null ]; then
    labels="${custom_labels}"
  fi
fi
printf '%s\n' "${iid}" >>"${TEST_GLAB_LOG}"
jq -nc --argjson iid "${iid}" --argjson labels "${labels}" \
  --arg description "${description}" \
  --arg state "${FAKE_LIVE_STATE:-opened}" \
  '{iid:$iid,title:("Issue " + ($iid|tostring)),description:$description,
    web_url:("https://gitlab.test/group/project/-/issues/" + ($iid|tostring)),
    labels:$labels,state:$state}'
EOF
chmod +x "${FIXTURE_SCRIPTS}"/*.sh "${BIN_DIR}/glab"

export TEST_ALLOC_LOG="${ALLOC_LOG}"
export TEST_PREP_LOG="${PREP_LOG}"
export TEST_LABEL_LOG="${LABEL_LOG}"
export TEST_GLAB_LOG="${GLAB_LOG}"
export TEST_MIGRATION_LOG="${MIGRATION_LOG}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg now "${NOW}" '{
  project:"project",repo_path:"unused",branch:"main",
  issue_min_iid:1,issue_max_iid:1,hourly_issue_quota:4,
  max_runtime_minutes:300,blocked_retry_limit:3,blocked_cooldown_ticks:1,
  max_concurrent_subagents:4,stuck_after_minutes:332,acpx_timeout_seconds:18000,
  issue_iids_whitelist:[1],require_labels:[],require_labels_match:"or",
  tick_seq:7,active_issue_iids:[1],active_issue_sessions:["issue-project-1"],
  pending_subagents:{"1":{execution_id:1,run_id:"old-run",
    child_session_key:"agent:child:one",spawned_at:$now,placeholder:false,
    acpx_timeout_seconds:18000}},
  blocked_at_tick_by_iid:{},unfinished_iids:[],completed_iids:[],blocked_iids:[],
  failed_iids:[],timeout_iids:[],campaign_status:"waiting_for_callbacks",
  quota_launched_this_tick:0,last_reconcile_evidence:null,
  dispatch_owner:{mode:"driven",owner_id:"owner-A",leased_at:$now},updated_at:$now
}' >"${STATE_FILE}"
cp "${STATE_FILE}" "${TEST_ROOT}/state-before-invalid.json"

GRANTS='[
  {"job_id":"job-2","batch_id":"batch-A","snapshot_index":0,"project":"group/project","iid":2,"branch":null,"entry_mode":"auto","force_rerun_pr":false},
  {"job_id":"job-3","batch_id":"batch-A","snapshot_index":1,"project":"group/project","iid":3,"branch":"release/explicit","entry_mode":"continue","force_rerun_pr":false,"auto_merge":true,"merge_target_branch":"release/merge"},
  {"job_id":"job-4","batch_id":"batch-B","snapshot_index":0,"project":"group/project","iid":4,"branch":null,"entry_mode":"auto","force_rerun_pr":true},
  {"job_id":"job-5","batch_id":"batch-B","snapshot_index":1,"project":"group/project","iid":5,"branch":null,"entry_mode":"auto","force_rerun_pr":false},
  {"job_id":"job-6","batch_id":"batch-C","snapshot_index":0,"project":"group/project","iid":6,"branch":null,"entry_mode":"auto","force_rerun_pr":true}
]'
VALID_REQUEST="$(jq -nc --argjson grants "${GRANTS}" '{owner_id:"owner-A",grants:$grants}')"
VALIDATION_REQUEST="$(printf '%s' "${VALID_REQUEST}" | jq -c '.grants |= map(.branch="main")')"

run_wrapper() {
  local request="$1"
  printf '%s\n' "${request}" | CONFIG_DIR="${CONFIG_DIR}" \
    PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh" \
    PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh"
}

assert_rejected() {
  local label="$1" request="$2"
  if run_wrapper "${request}" >"${TEST_ROOT}/${label}.out" 2>"${TEST_ROOT}/${label}.err"; then
    fail "${label} request must be rejected"
  fi
  cmp -s "${STATE_FILE}" "${TEST_ROOT}/state-before-invalid.json" \
    || fail "${label} validation changed campaign state"
}

FIRST_GRANT="$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.grants[0]')"
SECOND_GRANT="$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.grants[1]')"
assert_rejected unknown_top "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.unexpected=true')"
assert_rejected unknown_grant "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.grants[0].unexpected=true')"
assert_rejected missing_owner "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c 'del(.owner_id)')"
assert_rejected missing_grant_field "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c 'del(.grants[0].job_id)')"
assert_rejected duplicate_iid "$(jq -nc --argjson grant "${FIRST_GRANT}" \
  '{owner_id:"owner-A",grants:[$grant,($grant|.job_id="job-duplicate"|.batch_id="batch-Z"|.snapshot_index=9)]}')"
assert_rejected duplicate_job_id "$(jq -nc --argjson first "${FIRST_GRANT}" --argjson second "${SECOND_GRANT}" \
  '{owner_id:"owner-A",grants:[$first,($second|.job_id=$first.job_id)]}')"
assert_rejected duplicate_membership_identity "$(jq -nc --argjson first "${FIRST_GRANT}" --argjson second "${SECOND_GRANT}" \
  '{owner_id:"owner-A",grants:[$first,($second|.batch_id=$first.batch_id|.snapshot_index=$first.snapshot_index)]}')"
assert_rejected mixed_project "$(jq -nc --argjson grant "${FIRST_GRANT}" \
  '{owner_id:"owner-A",grants:[$grant,($grant|.job_id="job-other"|.iid=9|.batch_id="batch-Z"|.project="other/project")]}')"
assert_rejected owner_control_character "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.owner_id="owner\nA"')"
assert_rejected job_control_character "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.grants[0].job_id="job\tinject"')"
assert_rejected branch_control_character "$(printf '%s' "${VALIDATION_REQUEST}" | jq -c '.grants[0].branch="main\rbranch=evil"')"

assert_token_rejected() {
  local label="$1" malicious_token="$2"
  if printf '%s\n' "${VALIDATION_REQUEST}" | \
    GITLAB_TOKEN="${malicious_token}" CONFIG_DIR="${CONFIG_DIR}" \
    PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh" \
    PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh" \
    >"${TEST_ROOT}/${label}.out" 2>"${TEST_ROOT}/${label}.err"; then
    fail "${label} GitLab token must be rejected before line trigger construction"
  fi
  cmp -s "${STATE_FILE}" "${TEST_ROOT}/state-before-invalid.json" \
    || fail "${label} GitLab token validation changed campaign state"
}
assert_token_rejected token_newline $'token\ninjected'
assert_token_rejected token_carriage_return $'token\rinjected'
assert_token_rejected token_tab $'token\tinjected'
assert_token_rejected token_delete $'token\x7finjected'

printf '%s\n' "${VALIDATION_REQUEST}" | \
  TEST_TRIGGER_CAPTURE="${TRIGGER_CAPTURE}" CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/capture_prepare_tick.sh" \
  PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh" \
  >"${TEST_ROOT}/capture-trigger.out"
[ -s "${TRIGGER_CAPTURE}" ] || fail "internal topup trigger was not captured"
if grep -Fq 'gitlab_token=' "${TRIGGER_CAPTURE}" || \
   grep -Fq 'fake-token-direct' "${TRIGGER_CAPTURE}"; then
  fail "internal driven topup trigger serialized the GitLab token"
fi
grep -Fq 'dispatch_mode=driven_topup' "${TRIGGER_CAPTURE}" \
  || fail "captured internal trigger omitted driven_topup identity"
grep -Fq 'acpx_timeout_seconds=3600' "${TRIGGER_CAPTURE}" \
  || fail "driven topup did not use the one-hour default acpx timeout"

printf '%s\n' "${VALIDATION_REQUEST}" | \
  TEST_TRIGGER_CAPTURE="${TRIGGER_CAPTURE}" CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_ACPX_TIMEOUT_SECONDS=7200 \
  PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/capture_prepare_tick.sh" \
  PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh" \
  >"${TEST_ROOT}/capture-runtime-timeout-trigger.out"
grep -Fq 'acpx_timeout_seconds=7200' "${TRIGGER_CAPTURE}" \
  || fail "driven topup did not apply the persisted runtime acpx timeout"

prepare_trigger() {
  local request="$1"
  cat <<EOF
RUN_SCHEDULED_ISSUE_CAMPAIGN
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
dispatch_mode=driven_topup
driven_request_json=${request}
project=project
group=group
gitlab_token=fake-token-must-enter-trigger
issue_iids=2,3
issue_min_iid=2
issue_max_iid=3
hourly_issue_quota=4
max_concurrent_subagents=4
max_runtime_minutes=300
blocked_retry_limit=3
blocked_cooldown_ticks=1
acpx_timeout_seconds=18000
branch=main
repo_path=${REPO_PARENT}/group
EOF
}

assert_prepare_rejected() {
  local label="$1" request="$2" output
  : >"${ALLOC_LOG}"
  : >"${PREP_LOG}"
  : >"${LABEL_LOG}"
  : >"${GLAB_LOG}"
  output="$(prepare_trigger "${request}" | \
    GITLAB_TOKEN=fake-token-direct \
    GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
    PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh")"
  printf '%s' "${output}" | jq -e \
    '.status == "tick_failed" and .chat_summary == "invalid_driven_request_json"' >/dev/null \
    || fail "${label} must be rejected by prepare secondary validation"
  cmp -s "${STATE_FILE}" "${TEST_ROOT}/state-before-invalid.json" \
    || fail "${label} prepare validation changed campaign state"
  [ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
    && [ ! -s "${LABEL_LOG}" ] && [ ! -s "${GLAB_LOG}" ] \
    || fail "${label} prepare validation reached issue work"
}

DUP_JOB_REQUEST="$(jq -nc --argjson first "${FIRST_GRANT}" --argjson second "${SECOND_GRANT}" \
  '{owner_id:"owner-A",grants:[$first,($second|.job_id=$first.job_id)]}')"
DUP_MEMBERSHIP_REQUEST="$(jq -nc --argjson first "${FIRST_GRANT}" --argjson second "${SECOND_GRANT}" \
  '{owner_id:"owner-A",grants:[$first,($second|.batch_id=$first.batch_id|.snapshot_index=$first.snapshot_index)]}')"
assert_prepare_rejected duplicate_job_id_internal "${DUP_JOB_REQUEST}"
assert_prepare_rejected duplicate_membership_internal "${DUP_MEMBERSHIP_REQUEST}"

OUTPUT="$(run_wrapper "${VALID_REQUEST}")"
printf '%s' "${OUTPUT}" | jq -e '
  .status == "ready"
  and .pending_iids == [1,2,3,6]
  and [.dispatch_entries[].iid] == [2,3,6]
  and (all(.dispatch_entries[];
    (.execution_id == 1)
    and (.child_label | type == "string")
    and (.payload_path | type == "string")
    and (.expected_task_sha256 | test("^[0-9a-f]{64}$"))
    and (.expected_task_bytes | type == "number" and . > 0)
    and .memberships_source == "scheduler_active_job"))
  and [.skipped_entries[] | {iid,status,reason}] == [
    {iid:4,status:"skipped",reason:"closed"},
    {iid:5,status:"skipped",reason:"pr_without_force_rerun"}
  ]
  and (all(.skipped_entries[];
    (.job_id | type == "string")
    and (.batch_id | type == "string")
    and (.snapshot_index | type == "number")
    and .project == "group/project"))
  and .scope_evicted_iids == []
' >/dev/null || {
  printf '%s\n' "${OUTPUT}" >&2
  fail "driven topup did not separate executable grants from stable skipped entries"
}

for iid in 2 3 6; do
  EXECUTION_STATE_PATH="${PROJECT_REPO}/.req_executor/issues/issue-${iid}/executions/execution-1.json"
  [ -f "${EXECUTION_STATE_PATH}" ] \
    || fail "fixed execution identity for IID ${iid} does not exist"
  [ "$(file_mode "${EXECUTION_STATE_PATH}")" = "600" ] \
    || fail "fixed execution identity for IID ${iid} is not mode 600 at creation"
  PAYLOAD_PATH="$(printf '%s' "${OUTPUT}" | jq -r --argjson iid "${iid}" \
    '.dispatch_entries[] | select(.iid == $iid) | .payload_path')"
  [ -f "${PAYLOAD_PATH}" ] || fail "driven topup payload_path for IID ${iid} does not exist"
  EXPECTED_TASK_SHA256="$(printf '%s' "${OUTPUT}" | jq -r --argjson iid "${iid}" \
    '.dispatch_entries[] | select(.iid == $iid) | .expected_task_sha256')"
  EXPECTED_TASK_BYTES="$(printf '%s' "${OUTPUT}" | jq -r --argjson iid "${iid}" \
    '.dispatch_entries[] | select(.iid == $iid) | .expected_task_bytes')"
  ACTUAL_TASK_SHA256="$(sha256_file "${PAYLOAD_PATH}")"
  ACTUAL_TASK_BYTES="$(wc -c <"${PAYLOAD_PATH}" | tr -d '[:space:]')"
  [ "${ACTUAL_TASK_SHA256}" = "${EXPECTED_TASK_SHA256}" ] \
    || fail "spawn bootstrap SHA-256 mismatched dispatch identity for IID ${iid}"
  [ "${ACTUAL_TASK_BYTES}" = "${EXPECTED_TASK_BYTES}" ] \
    || fail "spawn bootstrap byte count mismatched dispatch identity for IID ${iid}"
  [ "${ACTUAL_TASK_BYTES}" -lt 4096 ] \
    || fail "sessions_spawn task for IID ${iid} is no longer a small bootstrap"
  [ "$(file_mode "${PAYLOAD_PATH}")" = "600" ] \
    || fail "spawn bootstrap for IID ${iid} is not mode 600"
  grep -Fq '# REQ_EXECUTOR_SPAWN_BOOTSTRAP_V1' "${PAYLOAD_PATH}" \
    || fail "sessions_spawn task for IID ${iid} is not the small bootstrap"
  grep -Fq "top-level project, job_id, iid, and execution_id fields (there is no nested identity object)" \
    "${PAYLOAD_PATH}" \
    || fail "spawn bootstrap for IID ${iid} leaves manifest identity nesting ambiguous"
  MODE_HELPER="$(sed -n \
    's/^.*portable helper inside that Bash call: \(mode_of() {.*; }\); require its output.*$/\1/p' \
    "${PAYLOAD_PATH}")"
  [ -n "${MODE_HELPER}" ] \
    || fail "spawn bootstrap for IID ${iid} lacks an extractable mode helper"
  unset -f mode_of 2>/dev/null || true
  eval "${MODE_HELPER}"
  [ "$(mode_of "${PAYLOAD_PATH}")" = "600" ] \
    || fail "spawn bootstrap mode helper failed on the host stat implementation"
  [ "$(FAKE_STAT_STYLE=bsd PATH="${MODE_BIN}:${PATH}" mode_of "${PAYLOAD_PATH}")" = "600" ] \
    || fail "spawn bootstrap mode helper failed its BSD stat branch"
  [ "$(FAKE_STAT_STYLE=gnu PATH="${MODE_BIN}:${PATH}" mode_of "${PAYLOAD_PATH}")" = "600" ] \
    || fail "spawn bootstrap mode helper leaked GNU stat probe output"
  grep -Fq 'require its output to equal the literal string 600' "${PAYLOAD_PATH}" \
    || fail "spawn bootstrap for IID ${iid} leaves mode normalization ambiguous"
  if grep -Fq '%#Lp' "${PAYLOAD_PATH}"; then
    fail "spawn bootstrap for IID ${iid} permits prefixed BSD mode output"
  fi
  if grep -Fq 'fake-token-direct' "${PAYLOAD_PATH}" || \
     grep -Fq 'GITLAB_TOKEN=' "${PAYLOAD_PATH}"; then
    fail "sessions_spawn task for IID ${iid} contains a GitLab credential"
  fi
  MANIFEST_PATH="$(sed -n 's/^manifest_path=//p' "${PAYLOAD_PATH}")"
  [ -f "${MANIFEST_PATH}" ] || fail "spawn manifest for IID ${iid} does not exist"
  MANIFEST_SHA256="$(sed -n 's/^manifest_sha256=//p' "${PAYLOAD_PATH}")"
  MANIFEST_BYTES="$(sed -n 's/^manifest_bytes=//p' "${PAYLOAD_PATH}")"
  [ "$(sha256_file "${MANIFEST_PATH}")" = "${MANIFEST_SHA256}" ] \
    || fail "spawn manifest SHA-256 mismatched bootstrap for IID ${iid}"
  [ "$(wc -c <"${MANIFEST_PATH}" | tr -d '[:space:]')" = "${MANIFEST_BYTES}" ] \
    || fail "spawn manifest byte count mismatched bootstrap for IID ${iid}"
  [ "$(file_mode "${MANIFEST_PATH}")" = "600" ] \
    || fail "spawn manifest for IID ${iid} is not mode 600"
  EXECUTOR_PAYLOAD_PATH="$(jq -r '.executor_payload_path' "${MANIFEST_PATH}")"
  [ -f "${EXECUTOR_PAYLOAD_PATH}" ] || fail "private executor payload for IID ${iid} does not exist"
  EXPECTED_JOB_ID="$(printf '%s' "${GRANTS}" | jq -r --argjson iid "${iid}" \
    '.[] | select(.iid == $iid) | .job_id')"
  jq -e --argjson iid "${iid}" --arg expected_job_id "${EXPECTED_JOB_ID}" '
    .version == 1
    and .project == "group/project"
    and .job_id == $expected_job_id
    and .iid == $iid
    and .execution_id == 1
    and (has("identity") | not)
    and (.executor_payload_sha256 | test("^[0-9a-f]{64}$"))
    and (.executor_payload_bytes | type == "number" and . > 0)
  ' "${MANIFEST_PATH}" >/dev/null || fail "spawn manifest identity is invalid for IID ${iid}"
  [ "$(sha256_file "${EXECUTOR_PAYLOAD_PATH}")" = \
    "$(jq -r '.executor_payload_sha256' "${MANIFEST_PATH}")" ] \
    || fail "private executor payload SHA-256 mismatched manifest for IID ${iid}"
  [ "$(wc -c <"${EXECUTOR_PAYLOAD_PATH}" | tr -d '[:space:]')" = \
    "$(jq -r '.executor_payload_bytes' "${MANIFEST_PATH}")" ] \
    || fail "private executor payload byte count mismatched manifest for IID ${iid}"
  [ "$(file_mode "${EXECUTOR_PAYLOAD_PATH}")" = "600" ] \
    || fail "private executor payload for IID ${iid} is not mode 600"
  if grep -Fq 'fake-token-direct' "${EXECUTOR_PAYLOAD_PATH}" || \
     grep -Fq 'GITLAB_TOKEN=' "${EXECUTOR_PAYLOAD_PATH}"; then
    fail "private executor payload for IID ${iid} contains a GitLab credential"
  fi
  grep -Fq "REPO_PARENT_PATH= REPO_PATH=${PROJECT_REPO} \\" \
    "${EXECUTOR_PAYLOAD_PATH}" \
    || fail "private executor payload for IID ${iid} did not bind the namespaced repo path"
  if [ "${iid}" -eq 3 ]; then
    grep -Fq 'AUTO_MERGE=true' "${EXECUTOR_PAYLOAD_PATH}" \
      || fail "automatic merge intent was not rendered for IID 3"
    grep -Fq "ISSUE_MODE=continue BRANCH='release/explicit' \\" \
      "${EXECUTOR_PAYLOAD_PATH}" \
      || fail "processing branch was not shell quoted in the wrapper command for IID 3"
    grep -Fq "AUTO_MERGE=true MERGE_TARGET_BRANCH='release/merge' \\" \
      "${EXECUTOR_PAYLOAD_PATH}" \
      || fail "automatic merge target was not shell quoted in the wrapper command for IID 3"
  fi
done

jq -e '
  (.pending_subagents | keys | map(tonumber) | sort) == [1,2,3,6]
  and .pending_subagents["1"].run_id == "old-run"
  and (all(.pending_subagents | to_entries[] | select(.key != "1");
    .value.memberships_source == "scheduler_active_job"))
  and .pending_subagents["3"].auto_merge == true
  and .pending_subagents["3"].merge_target_branch == "release/merge"
  and .pending_subagents["2"].auto_merge == false
  and .pending_subagents["2"].branch == "main"
  and .pending_subagents["2"].merge_target_branch == "main"
  and .issue_iids_whitelist == [1,2,3,4,5,6]
  and .dispatch_owner == (.dispatch_owner | select(.mode == "driven" and .owner_id == "owner-A"))
' "${STATE_FILE}" >/dev/null || fail "driven topup pending state froze skips or omitted scheduler membership source"

[ "$(cat "${ALLOC_LOG}")" = $'2\n3\n6' ] \
  || fail "topup must allocate only executable grant IIDs 2, 3, and 6"
[ "$(cat "${PREP_LOG}")" = $'2|main|fresh\n3|release/explicit|continue\n6|main|fresh' ] \
  || fail "null/default branch, explicit branch, entry_mode, or force fresh semantics were not applied"
[ "$(cat "${GLAB_LOG}")" = $'2\n3\n9\n10\n6' ] \
  || fail "dependency planning did not stay within the frozen batch scope"
if grep -Eq '^(4|5)\|' "${LABEL_LOG}"; then
  fail "closed or PR-without-force grant mutated issue execution labels"
fi

PREPARE_SCRIPT="${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
grep -Fq 'after this project campaign lock is released' "${PREPARE_SCRIPT}" \
  || fail "Task 7 dynamic membership timing contract is not documented"
grep -Fq 'resolve the latest memberships by job_id under the agent scheduler lock' "${PREPARE_SCRIPT}" \
  || fail "Task 7 must resolve memberships dynamically by job_id"
grep -Fq 'before recording that scheduler job terminal' "${PREPARE_SCRIPT}" \
  || fail "Task 7 membership lookup must precede scheduler terminal recording"
awk '
  { source[NR] = $0 }
  /[[:space:]]update-index[[:space:]]*\\?$/ {
    count++
    hooks = fsmonitor = attributes = attr_nosystem = 0
    for (i = NR - 10; i <= NR; i++) {
      if (source[i] ~ /core\.hooksPath=\/dev\/null/) hooks = 1
      if (source[i] ~ /core\.fsmonitor=false/) fsmonitor = 1
      if (source[i] ~ /core\.attributesFile=\/dev\/null/) attributes = 1
      if (source[i] ~ /GIT_ATTR_NOSYSTEM=1/) attr_nosystem = 1
    }
    if (!(hooks && fsmonitor && attributes && attr_nosystem)) unsafe = 1
  }
  END { exit !(count > 0 && !unsafe) }
' "${PREPARE_SCRIPT}" \
  || fail "dispatch_prepare_tick update-index is not isolated from repository Git hooks/attributes"

cp "${ALLOC_LOG}" "${TEST_ROOT}/allocate-before-skip-only.log"
cp "${PREP_LOG}" "${TEST_ROOT}/prepare-before-skip-only.log"
cp "${LABEL_LOG}" "${TEST_ROOT}/labels-before-skip-only.log"
cp "${GLAB_LOG}" "${TEST_ROOT}/glab-before-skip-only.log"
SKIP_ONLY_REQUEST="$(printf '%s' "${VALID_REQUEST}" | jq -c '.grants |= map(select(.iid == 4 or .iid == 5))')"
SKIP_ONLY="$(run_wrapper "${SKIP_ONLY_REQUEST}")"
printf '%s' "${SKIP_ONLY}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == [1,2,3,6]
  and [.skipped_entries[] | {iid,reason}] == [
    {iid:4,reason:"closed"},
    {iid:5,reason:"pr_without_force_rerun"}
  ]
' >/dev/null || fail "skip-only driven topup must return skipped_entries to Task 9"
for log in allocate prepare labels glab; do
  cmp -s "${TEST_ROOT}/${log}-before-skip-only.log" "${TEST_ROOT}/${log}.log" \
    || fail "skip-only driven topup performed ${log} issue work"
done
jq -e '(.pending_subagents | has("4") or has("5")) | not' "${STATE_FILE}" >/dev/null \
  || fail "skip-only driven topup created pending entries"

REPLAY="$(run_wrapper "${VALID_REQUEST}")"
printf '%s' "${REPLAY}" | jq -e '
  (.status == "waiting_for_callbacks" or .status == "no_eligible_iids")
  and .dispatch_entries == []
  and .pending_iids == [1,2,3,6]
  and [.skipped_entries[].iid] == [4,5]
' >/dev/null || fail "same grants replay must retain skips without re-preparing pending jobs"
[ "$(cat "${ALLOC_LOG}")" = $'2\n3\n6' ] \
  || fail "same grants replay allocated existing pending jobs twice"

write_terminal_race_state() {
  jq -n --arg now "${NOW}" '{
    project:"project",repo_path:"unused",branch:"main",
    issue_min_iid:2,issue_max_iid:2,hourly_issue_quota:4,
    max_runtime_minutes:300,blocked_retry_limit:3,blocked_cooldown_ticks:1,
    max_concurrent_subagents:4,stuck_after_minutes:332,acpx_timeout_seconds:18000,
    issue_iids_whitelist:[2],require_labels:[],require_labels_match:"or",
    tick_seq:8,active_issue_iids:[],active_issue_sessions:[],pending_subagents:{},
    blocked_at_tick_by_iid:{},unfinished_iids:[2],completed_iids:[9],blocked_iids:[],
    failed_iids:[],timeout_iids:[],campaign_status:"running",
    quota_launched_this_tick:0,last_reconcile_evidence:null,
    dispatch_owner:{mode:"driven",owner_id:"owner-A",leased_at:$now},updated_at:$now
  }' >"${STATE_FILE}"
  : >"${ALLOC_LOG}"
  : >"${PREP_LOG}"
  : >"${LABEL_LOG}"
  : >"${GLAB_LOG}"
}

RACE_REQUEST="$(printf '%s' "${VALID_REQUEST}" | jq -c \
  '.grants |= map(select(.iid == 2))')"

# With no branch in the driven request, a branch recorded when the Issue was
# created becomes both the worktree baseline and the MR/automatic-merge target.
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"<!-- req_executor_base_branch:v1 branch=release/from-issue -->\nbody"
}'
INHERITED_BRANCH_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0].branch=null
  | .grants[0].auto_merge=true
  | .grants[0].merge_target_branch=null
')"
INHERITED_BRANCH_OUTPUT="$(run_wrapper "${INHERITED_BRANCH_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON
printf '%s' "${INHERITED_BRANCH_OUTPUT}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
' >/dev/null || fail "Issue-declared branch did not produce a runnable grant"
[ "$(cat "${PREP_LOG}")" = '2|release/from-issue|fresh' ] \
  || fail "Issue-declared branch did not select the worktree baseline"
INHERITED_BOOTSTRAP="$(printf '%s' "${INHERITED_BRANCH_OUTPUT}" \
  | jq -r '.dispatch_entries[0].payload_path')"
INHERITED_MANIFEST="$(sed -n 's/^manifest_path=//p' "${INHERITED_BOOTSTRAP}")"
INHERITED_EXECUTOR_PAYLOAD="$(jq -r '.executor_payload_path' \
  "${INHERITED_MANIFEST}")"
grep -Fq "ISSUE_MODE=fresh BRANCH='release/from-issue' \\" \
  "${INHERITED_EXECUTOR_PAYLOAD}" \
  || fail "Issue branch was not rendered into the executor command"
grep -Fq "AUTO_MERGE=true MERGE_TARGET_BRANCH='release/from-issue' \\" \
  "${INHERITED_EXECUTOR_PAYLOAD}" \
  || fail "Issue branch was not inherited as the automatic-merge target"
jq -e '
  .pending_subagents["2"].branch == "release/from-issue"
  and .pending_subagents["2"].merge_target_branch == "release/from-issue"
  and .pending_subagents["2"].auto_merge == true
' "${STATE_FILE}" >/dev/null \
  || fail "resolved Issue branch was not frozen in pending state"

# An explicit execution branch is authoritative and bypasses even malformed
# Issue metadata; its MR target still follows that explicit branch by default.
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{"2":"base_branch=../stale-unsafe"}'
EXPLICIT_OVERRIDE_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0].branch="release/explicit-override"
  | .grants[0].auto_merge=false
  | .grants[0].merge_target_branch=null
')"
EXPLICIT_OVERRIDE_OUTPUT="$(run_wrapper "${EXPLICIT_OVERRIDE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON
printf '%s' "${EXPLICIT_OVERRIDE_OUTPUT}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
' >/dev/null || fail "explicit branch did not override Issue metadata"
[ "$(cat "${PREP_LOG}")" = '2|release/explicit-override|fresh' ] \
  || fail "explicit branch did not select the worktree baseline"
jq -e '
  .pending_subagents["2"].branch == "release/explicit-override"
  and .pending_subagents["2"].merge_target_branch == "release/explicit-override"
' "${STATE_FILE}" >/dev/null \
  || fail "explicit branch override was not frozen as the MR target"

# Persisted shared-group identity is an authorization boundary. The branch key
# must encode the same ordered members, one IID may belong to only one group,
# and a frozen merge target must be a non-empty string.
for invalid_group_case in mismatched_key duplicate_member duplicate_auxiliary \
  invalid_fan_in missing_fan_in_mode unexpected_pair_mode invalid_target; do
  write_terminal_race_state
  INVALID_GROUP_TMP="$(mktemp "${STATE_FILE}.invalid-group.XXXXXX")"
  case "${invalid_group_case}" in
    mismatched_key)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:10,tail_iid:2,
          members:[10,2],scope_id:"batch-A",merge_target_branch:"main"}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
    duplicate_member)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:9,tail_iid:2,
          members:[9,2],scope_id:"batch-A",merge_target_branch:"main"},
        "issue/9+3":{work_branch:"issue/9+3",head_iid:9,tail_iid:3,
          members:[9,3],scope_id:"batch-A",merge_target_branch:"main"}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
    duplicate_auxiliary)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:9,tail_iid:2,
          members:[9,2],dependency_iids:[9,10],dependency_mode:"fan_in",
          scope_id:"batch-A",merge_target_branch:"main"},
        "issue/10+3":{work_branch:"issue/10+3",head_iid:10,tail_iid:3,
          members:[10,3],scope_id:"batch-A",merge_target_branch:"main"}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
    invalid_fan_in)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:9,tail_iid:2,
          members:[9,2],dependency_iids:[9,2],dependency_mode:"fan_in",
          scope_id:"batch-A",merge_target_branch:"main"}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
    missing_fan_in_mode)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:9,tail_iid:2,
          members:[9,2],dependency_iids:[9,10],
          scope_id:"batch-A",merge_target_branch:"main"}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
    unexpected_pair_mode)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:9,tail_iid:2,
          members:[9,2],dependency_mode:"fan_in",
          scope_id:"batch-A",merge_target_branch:"main"}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
    invalid_target)
      jq '.shared_branch_groups = {
        "issue/9+2":{work_branch:"issue/9+2",head_iid:9,tail_iid:2,
          members:[9,2],scope_id:"batch-A",merge_target_branch:7}
      }' "${STATE_FILE}" >"${INVALID_GROUP_TMP}"
      ;;
  esac
  mv "${INVALID_GROUP_TMP}" "${STATE_FILE}"
  INVALID_GROUP_OUTPUT="$(run_wrapper "${RACE_REQUEST}")"
  printf '%s' "${INVALID_GROUP_OUTPUT}" | jq -e '
    .status == "tick_failed"
    and .chat_summary == "invalid_persisted_shared_branch_groups"
    and .dispatch_entries == []
  ' >/dev/null || fail "${invalid_group_case} shared group did not fail closed"
  [ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
    || fail "${invalid_group_case} shared group reached attempt preparation"
done

# An incomplete reverse-edge planning scope must not block an ordinary A.  A
# has no knowledge of a future C and starts on issue/A; C can migrate it later
# after A has completed.
write_terminal_race_state
jq -nc '{version:1,project:"group/project",iids:[range(1;202)]}' \
  >"${SCHEDULER_ROOT}/batches/batch-A/snapshot.json"
INCOMPLETE_SCOPE_OUTPUT="$(run_wrapper "${RACE_REQUEST}")"
printf '%s' "${INCOMPLETE_SCOPE_OUTPUT}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || fail "incomplete reverse scope blocked an ordinary branch launch"
[ "$(cat "${ALLOC_LOG}")" = 2 ] \
  && [ "$(cat "${PREP_LOG}")" = '2|main|fresh' ] \
  || fail "ordinary A did not launch on issue/A with an incomplete reverse scope"
jq -e '
  .pending_subagents["2"].work_branch == "issue/2"
  and .pending_subagents["2"].branch_members == [2]
  and (.pending_subagents["2"].shared_branch_role // null) == null
' "${STATE_FILE}" >/dev/null \
  || fail "ordinary A identity was not frozen as issue/A"
jq -nc '{version:1,project:"group/project",iids:[2,3,9,10]}' \
  >"${SCHEDULER_ROOT}/batches/batch-A/snapshot.json"

# Even when reverse-edge planning can already see C -> A, A's own launch must
# remain ordinary.  Only C's later processing may migrate issue/9 to issue/9+2.
# Independent B remains on issue/10.
write_terminal_race_state
PAIR_STATE_TMP="$(mktemp "${STATE_FILE}.pair-head.XXXXXX")"
jq '.issue_min_iid=9 | .issue_max_iid=10 | .issue_iids_whitelist=[9,10]
  | .unfinished_iids=[9,10]' "${STATE_FILE}" >"${PAIR_STATE_TMP}"
mv "${PAIR_STATE_TMP}" "${STATE_FILE}"
PAIR_HEAD_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] as $base
  | .grants = [
      ($base | .job_id="job-9" | .iid=9 | .snapshot_index=2 | .branch="main"),
      ($base | .job_id="job-10" | .iid=10 | .snapshot_index=3 | .branch="main")
    ]')"
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
PAIR_HEAD_OUTPUT="$(run_wrapper "${PAIR_HEAD_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION
printf '%s' "${PAIR_HEAD_OUTPUT}" | jq -e '
  .status == "ready"
  and ([.dispatch_entries[].iid] | sort) == [9,10]
  and (.dispatch_entries | map(select(.iid == 2)) | length) == 0
' >/dev/null || fail "late dependency planning did not launch A and independent B"
PAIR_A_PAYLOAD="$(printf '%s' "${PAIR_HEAD_OUTPUT}" | jq -r \
  '.dispatch_entries[] | select(.iid == 9) | .payload_path')"
PAIR_A_MANIFEST="$(sed -n 's/^manifest_path=//p' "${PAIR_A_PAYLOAD}")"
PAIR_A_EXECUTOR_PAYLOAD="$(jq -r '.executor_payload_path' "${PAIR_A_MANIFEST}")"
PAIR_B_PAYLOAD="$(printf '%s' "${PAIR_HEAD_OUTPUT}" | jq -r \
  '.dispatch_entries[] | select(.iid == 10) | .payload_path')"
PAIR_B_MANIFEST="$(sed -n 's/^manifest_path=//p' "${PAIR_B_PAYLOAD}")"
PAIR_B_EXECUTOR_PAYLOAD="$(jq -r '.executor_payload_path' "${PAIR_B_MANIFEST}")"
grep -Fq 'WORK_BRANCH=issue/9' "${PAIR_A_EXECUTOR_PAYLOAD}" \
  || fail "A did not keep its ordinary branch before C was processed"
grep -Fq 'EXPECTED_WORK_BRANCH_SHA=' "${PAIR_A_EXECUTOR_PAYLOAD}" \
  || fail "A ordinary payload omitted its empty creation lease"
grep -Fq 'EXPECTED_COMMIT_PARENT_SHA=' "${PAIR_A_EXECUTOR_PAYLOAD}" \
  || fail "A ordinary payload omitted its parent field"
grep -Fq 'WORK_BRANCH=issue/10' "${PAIR_B_EXECUTOR_PAYLOAD}" \
  || fail "independent B was moved onto the A+C shared branch"
jq -e '
  (.shared_branch_groups // {}) == {}
  and .pending_subagents["9"].work_branch == "issue/9"
  and .pending_subagents["9"].branch_members == [9]
  and (.pending_subagents["9"].shared_branch_role // null) == null
  and .pending_subagents["10"].work_branch == "issue/10"
  and .pending_subagents["10"].branch_members == [10]
' "${STATE_FILE}" >/dev/null || fail "A/B ordinary branch identities were not frozen durably"

# A finish that becomes visible on the fresh pre-mutation GET drains the grant
# as a successful skip and never removes a terminal label.
write_terminal_race_state
export FAKE_LIVE_LABEL=finish
LIVE_FINISH_SKIP="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_LIVE_LABEL
printf '%s' "${LIVE_FINISH_SKIP}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and [.skipped_entries[] | {iid,status,reason}] == [
    {iid:2,status:"skipped",reason:"pr_without_force_rerun"}
  ]
  and .pending_iids == []
' >/dev/null || fail "live finish race was not drained as a stable skipped grant"
[ ! -s "${LABEL_LOG}" ] \
  || fail "live finish race reached workflow-label mutations"
jq -e '
  (.pending_subagents | has("2") | not)
  and (.completed_iids | index(2) != null)
' "${STATE_FILE}" >/dev/null \
  || fail "live finish race left a pending placeholder or omitted completion"

# The final add-doing operation performs its own live read.  If finish or pr
# lands in the smaller window after the GET above, preserve:* must also drain
# the grant rather than treating exit 0 as a successful transition to doing.
for preserved_terminal in finish pr; do
  write_terminal_race_state
  export FAKE_MUTATION_PRESERVE="${preserved_terminal}"
  MUTATION_SKIP="$(run_wrapper "${RACE_REQUEST}")"
  unset FAKE_MUTATION_PRESERVE
  printf '%s' "${MUTATION_SKIP}" | jq -e '
    .status == "no_eligible_iids"
    and .dispatch_entries == []
    and [.skipped_entries[] | {iid,status,reason}] == [
      {iid:2,status:"skipped",reason:"pr_without_force_rerun"}
    ]
    and .pending_iids == []
  ' >/dev/null \
    || fail "mutation-boundary ${preserved_terminal} race was not drained"
  grep -Fxq '2|add doing' "${LABEL_LOG}" \
    || fail "mutation-boundary ${preserved_terminal} fixture did not reach add doing"
  jq -e '
    (.pending_subagents | has("2") | not)
    and (.completed_iids | index(2) != null)
  ' "${STATE_FILE}" >/dev/null \
    || fail "mutation-boundary ${preserved_terminal} race left pending state"
done

# Dependency parsing and graph reads are bounded preflight work. Timeouts keep
# the scheduler grant retryable and must happen before execution allocation,
# placeholder persistence, worktree preparation, or workflow-label mutation.
export TEST_REAL_TIMEOUT="$(command -v timeout)"
cat >"${BIN_DIR}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_ROOT_TIMEOUT_MODE:-}" = parser ] \
    && [[ " $* " == *" ISSUE_IID=2 "* ]]; then
  exit 124
fi
if [ "${FAKE_ROOT_TIMEOUT_MODE:-}" = lookup ] \
    && [[ " $* " == *"/issues/2 "* ]]; then
  exit 124
fi
exec "${TEST_REAL_TIMEOUT}" "$@"
EOF
chmod +x "${BIN_DIR}/timeout"
for root_preflight_timeout in parser lookup; do
  write_terminal_race_state
  export FAKE_ROOT_TIMEOUT_MODE="${root_preflight_timeout}"
  ROOT_PREFLIGHT_DEFERRED="$(run_wrapper "${RACE_REQUEST}")"
  unset FAKE_ROOT_TIMEOUT_MODE
  if [ "${root_preflight_timeout}" = parser ]; then
    expected_root_deferred_reason=dependency_preflight_deferred
  else
    expected_root_deferred_reason=dependency_graph_preflight_deferred
  fi
  printf '%s' "${ROOT_PREFLIGHT_DEFERRED}" | jq -e \
    --arg reason "${expected_root_deferred_reason}" '
    .status == "no_eligible_iids"
    and .dispatch_entries == []
    and .pending_iids == []
    and .skipped_entries == []
    and .dependency_waiting == [{
      iid:2,dependency_iid:null,branch:null,reason:$reason
    }]
    and .deferred_entries == [{
      job_id:"job-2",batch_id:"batch-A",snapshot_index:0,
      project:"group/project",iid:2,status:"deferred",
      reason:$reason,dependency_iid:null,dependency_branch:null
    }]
  ' >/dev/null || {
    printf '%s\n' "${ROOT_PREFLIGHT_DEFERRED}" >&2
    fail "root ${root_preflight_timeout} timeout was not retryably deferred"
  }
  [ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
    && [ ! -s "${LABEL_LOG}" ] \
    || fail "root ${root_preflight_timeout} timeout crossed the preflight boundary"
  jq -e '
    (.pending_subagents | has("2") | not)
    and (.unfinished_iids | index(2) != null)
  ' "${STATE_FILE}" >/dev/null \
    || fail "root ${root_preflight_timeout} timeout persisted a placeholder"
done
unset TEST_REAL_TIMEOUT
mv "${BIN_DIR}/timeout" "${BIN_DIR}/timeout.root-preflight-test"

# A timeout while traversing an unfinished predecessor retains the known edge
# in the retry envelope but does not classify the graph as invalid.
export TEST_REAL_TIMEOUT="$(command -v timeout)"
cat >"${BIN_DIR}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" ISSUE_IID=9 "* ]]; then
  exit 124
fi
exec "${TEST_REAL_TIMEOUT}" "$@"
EOF
chmod +x "${BIN_DIR}/timeout"
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"依赖 Issue #9",
  "9":"依赖 Issue #10"
}'
DEPENDENCY_CHECK_DEFERRED="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON TEST_REAL_TIMEOUT
mv "${BIN_DIR}/timeout" "${BIN_DIR}/timeout.chain-parser-test"
printf '%s' "${DEPENDENCY_CHECK_DEFERRED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .skipped_entries == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9",
    reason:"dependency_cycle_check_deferred"
  }]
  and .deferred_entries[0].reason == "dependency_cycle_check_deferred"
' >/dev/null || {
  printf '%s\n' "${DEPENDENCY_CHECK_DEFERRED}" >&2
  fail "dependency parser timeout was not deferred"
}
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  && [ ! -s "${LABEL_LOG}" ] \
  || fail "dependency parser timeout consumed an attempt"

# The direct predecessor GET is under the same graph deadline. Its IID and
# immutable ordinary branch are already known when the lookup times out.
export TEST_REAL_TIMEOUT="$(command -v timeout)"
cat >"${BIN_DIR}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *"/issues/9 "* ]]; then
  exit 124
fi
exec "${TEST_REAL_TIMEOUT}" "$@"
EOF
chmod +x "${BIN_DIR}/timeout"
write_terminal_race_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
DIRECT_LOOKUP_DEFERRED="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION TEST_REAL_TIMEOUT
mv "${BIN_DIR}/timeout" "${BIN_DIR}/timeout.direct-lookup-test"
printf '%s' "${DIRECT_LOOKUP_DEFERRED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .skipped_entries == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9",
    reason:"dependency_dag_preflight_deferred"
  }]
  and .deferred_entries[0].reason == "dependency_dag_preflight_deferred"
' >/dev/null || {
  printf '%s\n' "${DIRECT_LOOKUP_DEFERRED}" >&2
  fail "direct dependency lookup timeout was not deferred"
}
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  && [ ! -s "${LABEL_LOG}" ] \
  || fail "direct dependency lookup timeout consumed an attempt"

# New DAG-v2 planning keeps every predecessor immutable and gives each
# consumer its own plan-addressed branch.
write_ordinary_dag_source_state() {
  local iid="$1" execution_id="$2" branch="$3" sha="$4" mr_iid="$5"
  local work_branch_sha="${6:-${sha}}"
  local state_dir="${PROJECT_REPO}/.req_executor/issues/issue-${iid}"
  mkdir -p "${state_dir}"
  jq -n \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg branch "${branch}" \
    --arg sha "${sha}" \
    --arg work_branch_sha "${work_branch_sha}" \
    --arg mr_url \
      "https://gitlab.test/group/project/-/merge_requests/${mr_iid}" '{
      iid:$iid,status:"done",
      latest_execution_id:$execution_id,
      dependency_pinned_execution_id:$execution_id,
      work_branch:$branch,branch_members:[$iid],shared_branch_role:null,
      dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
      commit_sha:$sha,work_branch_sha:$work_branch_sha,
      dependency_history_verified:true,merge_request_url:$mr_url
    }' >"${state_dir}/state.json"
  chmod 600 "${state_dir}/state.json"
}

DAG_SOURCE_9_SHA="$(git -C "${PROJECT_REPO}" rev-parse HEAD)"
DAG_LOG_INDEX="$(mktemp "${TEST_ROOT}/dag-log-index.XXXXXX")"
cp "${PROJECT_REPO}/.git/index" "${DAG_LOG_INDEX}"
mkdir -p \
  "${PROJECT_REPO}/.req_executor/issue-9/log/execution-901"
printf '{"status":"archived"}\n' \
  >"${PROJECT_REPO}/.req_executor/issue-9/log/execution-901/summary.json"
GIT_INDEX_FILE="${DAG_LOG_INDEX}" git -C "${PROJECT_REPO}" add \
  ".req_executor/issue-9/log/execution-901/summary.json"
DAG_SOURCE_9_LOG_TREE="$(GIT_INDEX_FILE="${DAG_LOG_INDEX}" \
  git -C "${PROJECT_REPO}" write-tree)"
DAG_SOURCE_9_LOG_SHA="$(printf 'terminal log child\n' \
  | git -C "${PROJECT_REPO}" commit-tree "${DAG_SOURCE_9_LOG_TREE}" \
    -p "${DAG_SOURCE_9_SHA}")"

DAG_BUSINESS_INDEX="$(mktemp "${TEST_ROOT}/dag-business-index.XXXXXX")"
cp "${PROJECT_REPO}/.git/index" "${DAG_BUSINESS_INDEX}"
printf 'unreviewed business change\n' \
  >"${PROJECT_REPO}/unexpected-business-change.txt"
GIT_INDEX_FILE="${DAG_BUSINESS_INDEX}" git -C "${PROJECT_REPO}" add \
  "unexpected-business-change.txt"
DAG_SOURCE_9_BUSINESS_TREE="$(GIT_INDEX_FILE="${DAG_BUSINESS_INDEX}" \
  git -C "${PROJECT_REPO}" write-tree)"
DAG_SOURCE_9_BUSINESS_SHA="$(printf 'unexpected business child\n' \
  | git -C "${PROJECT_REPO}" commit-tree "${DAG_SOURCE_9_BUSINESS_TREE}" \
    -p "${DAG_SOURCE_9_SHA}")"

# A historical predecessor does not need any req_executor batch/private state.
# Stable live `pr` plus the exact fetched issue/<iid> branch is sufficient.
SOURCE_9_STATE_PATH="${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
if [ -f "${SOURCE_9_STATE_PATH}" ] && [ ! -L "${SOURCE_9_STATE_PATH}" ]; then
  mv "${SOURCE_9_STATE_PATH}" \
    "${PROJECT_REPO}/.req_executor/issues/issue-9/state.before-gitlab-only.json"
fi
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9 "${DAG_SOURCE_9_SHA}"
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{"2":"依赖 Issue #9"}'
export FAKE_ISSUE_LABELS_JSON='{"2":["blocked-dispatcher"],"9":["pr"]}'
DAG_GITLAB_ONLY_READY="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_GITLAB_ONLY_READY}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || {
  printf '%s\n' "${DAG_GITLAB_ONLY_READY}" >&2
  fail "GitLab-completed predecessor without batch state was not released"
}
jq -e --arg sha "${DAG_SOURCE_9_SHA}" '
  .dependency_plan.declared_inputs == [{
    iid:9,
    identity_source:"gitlab_pr_label_branch",
    work_branch:"issue/9",
    commit_sha:$sha,
    work_branch_sha:$sha,
    verified:true
  }]
  and .dependency_plan.aggregate_base_sha == $sha
' "${PROJECT_REPO}/.req_executor/issues/issue-2/state.json" >/dev/null \
  || fail "GitLab label/branch source was not frozen into the DAG plan"
[ ! -e "${SOURCE_9_STATE_PATH}" ] \
  || fail "GitLab-only dependency fabricated a batch/private Issue state"

# Live GitLab label + branch also wins over a stale private state snapshot.
# The dispatcher freezes the current branch SHA without rewriting that cache.
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9 "${DAG_SOURCE_9_BUSINESS_SHA}"
write_ordinary_dag_source_state 9 901 issue/9 "${DAG_SOURCE_9_SHA}" 16
export FAKE_DAG_MRS_JSON="$(jq -nc \
  --arg sha "${DAG_SOURCE_9_BUSINESS_SHA}" '[{
    iid:16,
    web_url:"https://gitlab.test/group/project/-/merge_requests/16",
    source_branch:"issue/9",target_branch:"main",sha:$sha,state:"opened",
    author:{username:"req-executor-bot"},description:"Closes #9"
  }]')"
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{"2":"依赖 Issue #9"}'
export FAKE_ISSUE_LABELS_JSON='{"2":["blocked-dispatcher"],"9":["pr"]}'
DAG_BUSINESS_CHILD_READY="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_BUSINESS_CHILD_READY}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || {
  printf '%s\n' "${DAG_BUSINESS_CHILD_READY}" >&2
  fail "live GitLab branch did not override stale private source state"
}
[ "$(cat "${ALLOC_LOG}")" = 2 ] \
  && [ "$(cat "${PREP_LOG}")" = '2|main|fresh' ] \
  || fail "live GitLab branch source did not reach worktree preparation"
jq -e --arg sha "${DAG_SOURCE_9_BUSINESS_SHA}" '
  .dependency_plan.declared_inputs[0].identity_source ==
    "gitlab_pr_label_branch"
  and .dependency_plan.declared_inputs[0].commit_sha == $sha
  and .dependency_plan.aggregate_base_sha == $sha
' "${PROJECT_REPO}/.req_executor/issues/issue-2/state.json" >/dev/null \
  || fail "current GitLab branch SHA did not win over stale private state"
jq -e --arg sha "${DAG_SOURCE_9_SHA}" '
  .commit_sha == $sha and .work_branch_sha == $sha
' "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" >/dev/null \
  || fail "live branch proof mutated the stale private source cache"

# Use B/L for the same-tick gate below; the next normal consumer resets state
# to B/B. The live ordinary branch remains the authoritative dependency tip.
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9 "${DAG_SOURCE_9_LOG_SHA}"
export FAKE_DAG_MRS_JSON="$(printf '%s' "${FAKE_DAG_MRS_JSON}" | jq -c \
  --arg sha "${DAG_SOURCE_9_LOG_SHA}" '.[0].sha = $sha')"
write_ordinary_dag_source_state 9 901 issue/9 \
  "${DAG_SOURCE_9_SHA}" 16 "${DAG_SOURCE_9_LOG_SHA}"

# A completed predecessor selected for force-rerun in this same tick is no
# longer an immutable input. The consumer is removed from the batch before its
# execution ID or pending placeholder is allocated, while the source proceeds.
write_terminal_race_state
SAME_TICK_DIRECT_STATE_TMP="$(mktemp \
  "${STATE_FILE}.same-tick-direct.XXXXXX")"
jq '.issue_min_iid=2 | .issue_max_iid=9
  | .issue_iids_whitelist=[9,2]
  | .unfinished_iids=[9,2] | .completed_iids=[9]' \
  "${STATE_FILE}" >"${SAME_TICK_DIRECT_STATE_TMP}"
mv "${SAME_TICK_DIRECT_STATE_TMP}" "${STATE_FILE}"
SAME_TICK_DIRECT_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] as $consumer
  | .grants = [
      ($consumer
        | .job_id="job-9" | .iid=9 | .snapshot_index=2
        | .branch="main" | .entry_mode="fresh"
        | .force_rerun_pr=true | .auto_merge=false
        | .merge_target_branch=null),
      ($consumer
        | .job_id="job-2" | .iid=2 | .snapshot_index=0
        | .branch="main" | .entry_mode="fresh"
        | .force_rerun_pr=false | .auto_merge=false
        | .merge_target_branch=null)
    ]')"
SOURCE_9_STATE_SAME_TICK_BACKUP="$(mktemp \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.same-tick.XXXXXX")"
cp "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" \
  "${SOURCE_9_STATE_SAME_TICK_BACKUP}"
export FAKE_ISSUE_DESCRIPTIONS_JSON='{"2":"依赖 Issue #9","9":"body"}'
export FAKE_ISSUE_LABELS_JSON='{"2":["blocked-dispatcher"],"9":["pr"]}'
export FAKE_ALLOC_EXECUTION_ID=902
SAME_TICK_DIRECT_OUTPUT="$(run_wrapper "${SAME_TICK_DIRECT_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON \
  FAKE_ALLOC_EXECUTION_ID
cp "${SOURCE_9_STATE_SAME_TICK_BACKUP}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
printf '%s' "${SAME_TICK_DIRECT_OUTPUT}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [9]
  and .pending_iids == [9]
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9",
    reason:"dependency_source_selected_same_tick"
  }]
  and .deferred_entries[0].reason ==
    "dependency_source_selected_same_tick"
' >/dev/null || {
  printf '%s\n' "${SAME_TICK_DIRECT_OUTPUT}" >&2
  fail "direct same-tick predecessor mutation did not defer its consumer"
}
[ "$(cat "${ALLOC_LOG}")" = 9 ] \
  && [ "$(cat "${PREP_LOG}")" = '9|main|fresh' ] \
  || fail "direct same-tick gate allocated or prepared its consumer"
jq -e '
  (.pending_subagents | has("9"))
  and (.pending_subagents | has("2") | not)
' "${STATE_FILE}" >/dev/null \
  || fail "direct same-tick gate persisted a consumer placeholder"
if grep -Fq '2|' "${LABEL_LOG}"; then
  fail "direct same-tick gate mutated consumer workflow labels"
fi

# Even if private state still says B/B after the branch advanced to L, the
# current GitLab issue/<iid> branch is authoritative and becomes the baseline.
write_ordinary_dag_source_state 9 901 issue/9 "${DAG_SOURCE_9_SHA}" 16
: >"${MIGRATION_LOG}"
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{"2":"依赖 Issue #9"}'
export FAKE_ISSUE_LABELS_JSON='{"2":["blocked-dispatcher"],"9":["pr"]}'
DAG_TWO_READY="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_TWO_READY}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || fail "single-input DAG consumer was not released"
DAG_TWO_STATE="${PROJECT_REPO}/.req_executor/issues/issue-2/state.json"
DAG_TWO_WORK_BRANCH="$(jq -r '.dependency_plan.work_branch' "${DAG_TWO_STATE}")"
DAG_TWO_PLAN_SHA256="$(jq -r \
  '.dependency_plan_sha256' "${DAG_TWO_STATE}")"
jq -e --arg log_sha "${DAG_SOURCE_9_LOG_SHA}" '
  .dependency_contract_version == 2
  and (.dependency_plan | keys | sort) == ([
    "aggregate_base_sha","consumer_iid","declared_inputs",
    "effective_inputs","plan_sha256","target_branch","version","work_branch"
  ] | sort)
  and .dependency_plan.consumer_iid == 2
  and (.dependency_plan.declared_inputs | map(.iid)) == [9]
  and (.dependency_plan.effective_inputs | map(.iid)) == [9]
  and .dependency_plan.declared_inputs[0].identity_source ==
    "gitlab_pr_label_branch"
  and .dependency_plan.declared_inputs[0].commit_sha == $log_sha
  and .dependency_plan.declared_inputs[0].work_branch_sha == $log_sha
  and .dependency_plan.effective_inputs[0].commit_sha == $log_sha
  and .dependency_plan.effective_inputs[0].work_branch_sha == $log_sha
  and .dependency_plan.aggregate_base_sha == $log_sha
  and .proposed_dependency_plan == .dependency_plan
  and .proposed_expected_commit_parent_sha == $log_sha
' "${DAG_TWO_STATE}" >/dev/null \
  || fail "single-input DAG plan was not frozen in Issue state"
[[ "${DAG_TWO_WORK_BRANCH}" =~ ^issue/2-dag-[0-9a-f]{16}$ ]] \
  || fail "DAG consumer did not receive a plan-addressed branch"
[ "${DAG_TWO_WORK_BRANCH}" = \
    "issue/2-dag-${DAG_TWO_PLAN_SHA256:0:16}" ] \
  || fail "DAG branch prefix does not match its full plan identity"
[ "$(cat "${PREP_LOG}")" = '2|main|fresh' ] \
  || fail "DAG consumer did not prepare from its independent target baseline"
[ ! -s "${MIGRATION_LOG}" ] \
  || fail "DAG planning invoked a destructive legacy migration"
jq -e --arg sha "${DAG_SOURCE_9_SHA}" '
  .commit_sha == $sha
  and .work_branch_sha == $sha
  and (.terminal_log_recovered_at // null) == null
' "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" >/dev/null \
  || fail "GitLab branch proof rewrote the private predecessor cache"
SOURCE_9_STATE_HASH="$(sha256_file \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json")"
[ "$(git -C "${PROJECT_REPO}" rev-parse refs/remotes/origin/issue/9)" = \
    "${DAG_SOURCE_9_LOG_SHA}" ] \
  || fail "DAG planning moved the predecessor branch"
DAG_TWO_PAYLOAD="$(printf '%s' "${DAG_TWO_READY}" \
  | jq -r '.dispatch_entries[0].payload_path')"
DAG_TWO_MANIFEST="$(sed -n 's/^manifest_path=//p' "${DAG_TWO_PAYLOAD}")"
DAG_TWO_EXECUTOR_PAYLOAD="$(jq -r '.executor_payload_path' \
  "${DAG_TWO_MANIFEST}")"
grep -Fq 'DEPENDENCY_CONTRACT_VERSION=2' "${DAG_TWO_EXECUTOR_PAYLOAD}" \
  || fail "DAG contract version was not rendered"
grep -Fq "DEPENDENCY_PLAN_SHA256=${DAG_TWO_PLAN_SHA256}" \
  "${DAG_TWO_EXECUTOR_PAYLOAD}" \
  || fail "DAG full plan identity was not rendered"
grep -Fq "EXPECTED_COMMIT_PARENT_SHA=${DAG_SOURCE_9_LOG_SHA}" \
  "${DAG_TWO_EXECUTOR_PAYLOAD}" \
  || fail "DAG consumer did not freeze its exact commit parent"
grep -Fq "WORK_BRANCH=${DAG_TWO_WORK_BRANCH}" \
  "${DAG_TWO_EXECUTOR_PAYLOAD}" \
  || fail "DAG consumer work branch was not rendered"

# A second consumer may reuse the same immutable predecessor without sharing
# a branch or mutating the first consumer.
write_terminal_race_state
DAG_THREE_STATE_TMP="$(mktemp "${STATE_FILE}.dag-three.XXXXXX")"
jq '.issue_min_iid=3 | .issue_max_iid=3 | .issue_iids_whitelist=[3]
  | .unfinished_iids=[3] | .completed_iids=[9]' \
  "${STATE_FILE}" >"${DAG_THREE_STATE_TMP}"
mv "${DAG_THREE_STATE_TMP}" "${STATE_FILE}"
DAG_THREE_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] |= (
    .job_id="job-3" | .iid=3 | .snapshot_index=1 | .branch="main"
    | .entry_mode="fresh" | .force_rerun_pr=false
    | .auto_merge=false | .merge_target_branch=null
  )')"
export FAKE_ISSUE_DESCRIPTIONS_JSON='{"3":"依赖 Issue #9"}'
export FAKE_ISSUE_LABELS_JSON='{"3":["blocked-dispatcher"],"9":["pr"]}'
DAG_THREE_READY="$(run_wrapper "${DAG_THREE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_THREE_READY}" | jq -e '
  .status == "ready" and [.dispatch_entries[].iid] == [3]
' >/dev/null || fail "fan-out consumer did not reuse its predecessor"
DAG_THREE_WORK_BRANCH="$(jq -r '.dependency_plan.work_branch' \
  "${PROJECT_REPO}/.req_executor/issues/issue-3/state.json")"
[ "${DAG_THREE_WORK_BRANCH}" != "${DAG_TWO_WORK_BRANCH}" ] \
  || fail "fan-out consumers were assigned the same work branch"
jq -e --arg sha "${DAG_SOURCE_9_LOG_SHA}" '
  .dependency_plan.aggregate_base_sha == $sha
  and (.dependency_plan.declared_inputs | map(.iid)) == [9]
' "${PROJECT_REPO}/.req_executor/issues/issue-3/state.json" >/dev/null \
  || fail "fan-out consumer did not freeze the reused predecessor SHA"
[ "$(sha256_file \
    "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json")" = \
    "${SOURCE_9_STATE_HASH}" ] \
  || fail "fan-out planning modified the shared predecessor state"

# Promote the first consumer to a completed immutable artifact, then declare
# both its ancestor and itself. Transitive reduction must keep only Issue 2.
DAG_TWO_COMMIT_SHA="$(printf 'DAG consumer 2 result\n' \
  | git -C "${PROJECT_REPO}" commit-tree HEAD^{tree} \
    -p "${DAG_SOURCE_9_LOG_SHA}")"
git -C "${PROJECT_REPO}" update-ref \
  "refs/remotes/origin/${DAG_TWO_WORK_BRANCH}" "${DAG_TWO_COMMIT_SHA}"
DAG_TWO_DONE_TMP="$(mktemp "${DAG_TWO_STATE}.done.XXXXXX")"
jq --arg commit_sha "${DAG_TWO_COMMIT_SHA}" \
  --arg work_branch "${DAG_TWO_WORK_BRANCH}" '
  .status="done"
  | .latest_execution_id=1
  | .dependency_pinned_execution_id=1
  | .work_branch=$work_branch
  | .branch_members=[2]
  | .shared_branch_role=null
  | .dependency_iid=9
  | .dependency_branch="issue/9"
  | .dependency_base_sha=.dependency_plan.aggregate_base_sha
  | .commit_sha=$commit_sha
  | .work_branch_sha=$commit_sha
  | .dependency_history_verified=true
  | .merge_request_url=
    "https://gitlab.test/group/project/-/merge_requests/19"
' "${DAG_TWO_STATE}" >"${DAG_TWO_DONE_TMP}"
chmod 600 "${DAG_TWO_DONE_TMP}"
mv "${DAG_TWO_DONE_TMP}" "${DAG_TWO_STATE}"
export FAKE_DAG_MRS_JSON="$(printf '%s' "${FAKE_DAG_MRS_JSON}" | jq -c \
  --arg sha "${DAG_TWO_COMMIT_SHA}" \
  --arg branch "${DAG_TWO_WORK_BRANCH}" '. + [{
    iid:19,
    web_url:"https://gitlab.test/group/project/-/merge_requests/19",
    source_branch:$branch,target_branch:"main",sha:$sha,state:"opened",
    author:{username:"req-executor-bot"},description:"Closes #2"
  }]')"

# The antichain gate uses the resolver's transitive closure, not only direct
# declarations. Here Issue 6 directly consumes completed Issue 2, while Issue
# 9 is Issue 2's frozen ancestor and is selected for force-rerun in this tick.
write_terminal_race_state
SAME_TICK_TRANSITIVE_STATE_TMP="$(mktemp \
  "${STATE_FILE}.same-tick-transitive.XXXXXX")"
jq '.issue_min_iid=6 | .issue_max_iid=9
  | .issue_iids_whitelist=[9,6]
  | .unfinished_iids=[9,6] | .completed_iids=[9,2]' \
  "${STATE_FILE}" >"${SAME_TICK_TRANSITIVE_STATE_TMP}"
mv "${SAME_TICK_TRANSITIVE_STATE_TMP}" "${STATE_FILE}"
SAME_TICK_TRANSITIVE_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] as $consumer
  | .grants = [
      ($consumer
        | .job_id="job-9" | .iid=9 | .snapshot_index=2
        | .branch="main" | .entry_mode="fresh"
        | .force_rerun_pr=true | .auto_merge=false
        | .merge_target_branch=null),
      ($consumer
        | .job_id="job-6" | .batch_id="batch-C" | .snapshot_index=0
        | .iid=6 | .branch="main" | .entry_mode="fresh"
        | .force_rerun_pr=true | .auto_merge=false
        | .merge_target_branch=null)
    ]')"
SOURCE_9_TRANSITIVE_BACKUP="$(mktemp \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.transitive.XXXXXX")"
cp "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" \
  "${SOURCE_9_TRANSITIVE_BACKUP}"
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"依赖 Issue #9",
  "6":"依赖 Issue #2",
  "9":"body"
}'
export FAKE_ISSUE_LABELS_JSON='{
  "2":["pr"],"6":["blocked-dispatcher"],"9":["pr"]
}'
export FAKE_ALLOC_EXECUTION_ID=903
SAME_TICK_TRANSITIVE_OUTPUT="$(
  run_wrapper "${SAME_TICK_TRANSITIVE_REQUEST}"
)"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON \
  FAKE_ALLOC_EXECUTION_ID
cp "${SOURCE_9_TRANSITIVE_BACKUP}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
printf '%s' "${SAME_TICK_TRANSITIVE_OUTPUT}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [9]
  and .pending_iids == [9]
  and .dependency_waiting == [{
    iid:6,dependency_iid:9,branch:"issue/9",
    reason:"dependency_source_selected_same_tick"
  }]
  and .deferred_entries[0].reason ==
    "dependency_source_selected_same_tick"
' >/dev/null || {
  printf '%s\n' "${SAME_TICK_TRANSITIVE_OUTPUT}" >&2
  fail "transitive same-tick predecessor mutation did not defer its consumer"
}
[ "$(cat "${ALLOC_LOG}")" = 9 ] \
  && [ "$(cat "${PREP_LOG}")" = '9|main|fresh' ] \
  || fail "transitive same-tick gate allocated or prepared its consumer"
jq -e '
  (.pending_subagents | has("9"))
  and (.pending_subagents | has("6") | not)
' "${STATE_FILE}" >/dev/null \
  || fail "transitive same-tick gate persisted a consumer placeholder"
if grep -Fq '6|' "${LABEL_LOG}"; then
  fail "transitive same-tick gate mutated consumer workflow labels"
fi

write_terminal_race_state
DAG_SIX_STATE_TMP="$(mktemp "${STATE_FILE}.dag-six.XXXXXX")"
jq '.issue_min_iid=6 | .issue_max_iid=6 | .issue_iids_whitelist=[6]
  | .unfinished_iids=[6] | .completed_iids=[9,2]' \
  "${STATE_FILE}" >"${DAG_SIX_STATE_TMP}"
mv "${DAG_SIX_STATE_TMP}" "${STATE_FILE}"
DAG_SIX_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] |= (
    .job_id="job-6" | .batch_id="batch-C" | .snapshot_index=0
    | .iid=6 | .branch="main" | .entry_mode="fresh"
    | .force_rerun_pr=true | .auto_merge=false
    | .merge_target_branch=null
  )')"
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"依赖 Issue #9",
  "6":"依赖 Issue #9,#2"
}'
export FAKE_ISSUE_LABELS_JSON='{
  "2":["pr"],"6":["blocked-dispatcher"],"9":["pr"]
}'
DAG_SIX_READY="$(run_wrapper "${DAG_SIX_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_SIX_READY}" | jq -e '
  .status == "ready" and [.dispatch_entries[].iid] == [6]
' >/dev/null || {
  printf '%s\n' "${DAG_SIX_READY}" >&2
  fail "multi-level DAG consumer was not released"
}
jq -e --arg sha "${DAG_TWO_COMMIT_SHA}" '
  (.dependency_plan.declared_inputs | map(.iid)) == [9,2]
  and (.dependency_plan.effective_inputs | map(.iid)) == [2]
  and .dependency_plan.aggregate_base_sha == $sha
' "${PROJECT_REPO}/.req_executor/issues/issue-6/state.json" >/dev/null \
  || fail "multi-level DAG transitive reduction chose the wrong frontier"

# Cycle detection traverses every edge, including a back-edge that appears
# only in the second element of a multi-input declaration.
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"依赖 Issue #9,#10",
  "9":"body",
  "10":"依赖 Issue #2"
}'
export FAKE_ISSUE_LABELS_JSON='{
  "2":["blocked-dispatcher"],"9":[],"10":[]
}'
DAG_SECOND_EDGE_CYCLE="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_SECOND_EDGE_CYCLE}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .dependency_waiting == []
  and .skipped_entries[0].reason == "dependency_cycle"
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: dependency_cycle"
' >/dev/null || {
  printf '%s\n' "${DAG_SECOND_EDGE_CYCLE}" >&2
  fail "cycle on a non-first dependency edge was not rejected"
}
[ ! -s "${PREP_LOG}" ] \
  || fail "non-first-edge cycle reached worktree preparation"

# A repeated ancestor in a diamond is black/visited, not an active-stack
# recurrence, and therefore remains a normal dependency wait.
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"依赖 Issue #9",
  "9":"依赖 Issue #10,#3",
  "10":"依赖 Issue #3",
  "3":"body"
}'
export FAKE_ISSUE_LABELS_JSON='{
  "2":["blocked-dispatcher"],"3":[],"9":[],"10":[]
}'
DAG_DIAMOND_WAIT="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${DAG_DIAMOND_WAIT}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .skipped_entries == []
  and .dependency_waiting[0].reason == "dependency_not_completed"
' >/dev/null || fail "diamond dependency graph was mistaken for a cycle"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "diamond wait consumed an attempt"
unset FAKE_DAG_MRS_JSON

# Restore the single-head fixture used by the remaining continue tests.
DEPENDENCY_SHA="$(git -C "${PROJECT_REPO}" rev-parse HEAD)"
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9+2 "${DEPENDENCY_SHA}"
mkdir -p "${PROJECT_REPO}/.req_executor/issues/issue-9"
jq -n --arg sha "${DEPENDENCY_SHA}" '{
  iid:9,status:"done",commit_sha:$sha,work_branch:"issue/9+2",
  branch_members:[9,2],shared_branch_role:"head",
  work_branch_sha:$sha,dependency_history_verified:true,
  latest_execution_id:1,dependency_pinned_execution_id:1,
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
  merge_request_url:"https://gitlab.test/group/project/-/merge_requests/17",
  mr_finalization:{
    status:"verified_open",source_execution_id:1,
    work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"head",
    commit_sha:$sha,
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main",iid:17,
    web_url:"https://gitlab.test/group/project/-/merge_requests/17",
    mr_action:"created",verified_at:"2026-07-19T00:00:00Z"
  }}' >"${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
chmod 600 "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
VALID_DEPENDENCY_STATE="$(mktemp \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.valid.XXXXXX")"
cp "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" \
  "${VALID_DEPENDENCY_STATE}"
export FAKE_SHARED_MR_SHA="${DEPENDENCY_SHA}"
cp "${VALID_DEPENDENCY_STATE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9+2 "${DEPENDENCY_SHA}"
export FAKE_SHARED_MR_SHA="${DEPENDENCY_SHA}"

write_legacy_pair_campaign_state() {
  local state_tmp
  write_terminal_race_state
  state_tmp="$(mktemp "${STATE_FILE}.legacy-pair.XXXXXX")"
  jq '.shared_branch_groups = {
    "issue/9+2":{
      work_branch:"issue/9+2",head_iid:9,tail_iid:2,
      members:[9,2],scope_id:"batch-A",merge_target_branch:"main"
    }
  }' "${STATE_FILE}" >"${state_tmp}"
  mv "${state_tmp}" "${STATE_FILE}"
}

# A persisted v1 shared pair remains supported while it drains. During the
# source's Phase-6 crash window its campaign claim is authoritative even if
# live labels and private state already look terminal; the tail must not spend
# an execution ID or create a placeholder.
write_legacy_pair_campaign_state
LEGACY_PENDING_TMP="$(mktemp "${STATE_FILE}.legacy-source-pending.XXXXXX")"
jq --arg now "${NOW}" '.pending_subagents["9"] = {
    execution_id:901,run_id:"run-legacy-head",
    child_session_key:"child-legacy-head",
    spawned_at:$now,placeholder:false,acpx_timeout_seconds:18000,
    auto_merge:false,branch:"main",merge_target_branch:"main",
    work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"head",
    dependency_iid:null,dependency_branch:null,dependency_base_sha:null
  }
  | .active_issue_iids=[9]
  | .active_issue_sessions=["issue-project-9"]' \
  "${STATE_FILE}" >"${LEGACY_PENDING_TMP}"
mv "${LEGACY_PENDING_TMP}" "${STATE_FILE}"
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
export FAKE_DEPENDENCY_LABEL=pr
LEGACY_PHASE6_WAIT="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENCY_LABEL
printf '%s' "${LEGACY_PHASE6_WAIT}" | jq -e '
  .status == "waiting_for_callbacks"
  and .dispatch_entries == []
  and .pending_iids == [9]
' >/dev/null || fail "legacy shared tail crossed the source Phase-6 crash window"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  && [ ! -s "${LABEL_LOG}" ] \
  || fail "legacy Phase-6 crash window consumed an attempt"

# Once the source claim disappears, the already-persisted pair may resume
# without invoking either retired branch-migration helper.
write_legacy_pair_campaign_state
jq -n --arg sha "${DEPENDENCY_SHA}" '{
  iid:2,status:"blocked",retry_count:0,
  work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"tail",
  dependency_iid:9,dependency_branch:"issue/9+2",
  dependency_base_sha:$sha,work_branch_sha:$sha,
  dependency_history_verified:true
}' >"${PROJECT_REPO}/.req_executor/issues/issue-2/state.json"
: >"${MIGRATION_LOG}"
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
export FAKE_DEPENDENCY_LABEL=pr
export FAKE_ALLOC_EXECUTION_ID=902
LEGACY_PAIR_READY="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENCY_LABEL \
  FAKE_ALLOC_EXECUTION_ID
printf '%s' "${LEGACY_PAIR_READY}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || {
  printf '%s\n' "${LEGACY_PAIR_READY}" >&2
  fail "persisted legacy shared pair did not resume"
}
[ "$(cat "${ALLOC_LOG}")" = 2 ] \
  && [ "$(cat "${PREP_LOG}")" = '2|issue/9+2|fresh' ] \
  || fail "persisted legacy shared pair did not preserve its tail branch"
[ ! -s "${MIGRATION_LOG}" ] \
  || fail "persisted legacy pair invoked a retired migration helper"
jq -e --arg sha "${DEPENDENCY_SHA}" '
  .shared_branch_groups["issue/9+2"].members == [9,2]
  and .pending_subagents["2"].work_branch == "issue/9+2"
  and .pending_subagents["2"].shared_branch_role == "tail"
  and .pending_subagents["2"].dependency_iid == 9
  and .pending_subagents["2"].dependency_base_sha == $sha
' "${STATE_FILE}" >/dev/null \
  || fail "persisted legacy pair identity was not carried into the attempt"

# The durable v1 proof is still live-bound to its one MR. A closed MR cannot
# release the tail merely because the old state says verified_open.
write_legacy_pair_campaign_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
export FAKE_DEPENDENCY_LABEL=pr
export FAKE_SHARED_MR_STATE=closed
LEGACY_CLOSED_MR_WAIT="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENCY_LABEL \
  FAKE_SHARED_MR_STATE
printf '%s' "${LEGACY_CLOSED_MR_WAIT}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting[0].reason == "dependency_commit_unverified"
' >/dev/null || fail "closed legacy source MR released its shared tail"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "closed legacy source MR consumed a tail attempt"

# The shared head is immutable while the v1 pair drains. A continue request is
# deferred before allocation and cannot overwrite the verified source state.
write_legacy_pair_campaign_state
LEGACY_HEAD_CAMPAIGN_TMP="$(mktemp "${STATE_FILE}.legacy-head.XXXXXX")"
jq '.issue_min_iid=9 | .issue_max_iid=9 | .issue_iids_whitelist=[9]
  | .unfinished_iids=[9] | .completed_iids=[]' \
  "${STATE_FILE}" >"${LEGACY_HEAD_CAMPAIGN_TMP}"
mv "${LEGACY_HEAD_CAMPAIGN_TMP}" "${STATE_FILE}"
LEGACY_HEAD_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] |= (
    .job_id="job-9" | .iid=9 | .snapshot_index=2 | .branch="main"
    | .entry_mode="auto" | .force_rerun_pr=false
    | .auto_merge=false | .merge_target_branch=null
  )')"
LEGACY_HEAD_STATE_HASH="$(sha256_file \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json")"
export FAKE_ISSUE_LABELS_JSON='{"9":["pr","continue"]}'
LEGACY_HEAD_CONTINUE="$(run_wrapper "${LEGACY_HEAD_REQUEST}")"
unset FAKE_ISSUE_LABELS_JSON
printf '%s' "${LEGACY_HEAD_CONTINUE}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == [{
    iid:9,dependency_iid:null,branch:null,
    reason:"shared_branch_head_continue_unsupported"
  }]
  and .deferred_entries[0].reason ==
    "shared_branch_head_continue_unsupported"
' >/dev/null || fail "legacy shared head continue was not deferred"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  && [ ! -s "${LABEL_LOG}" ] \
  || fail "legacy shared head continue crossed the preflight boundary"
[ "$(sha256_file \
    "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json")" = \
    "${LEGACY_HEAD_STATE_HASH}" ] \
  || fail "legacy shared head continue overwrote its verified state"

# Once C has pushed the shared branch, continue resumes that exact C tip even
# if A is no longer in a stable completed state.
write_terminal_race_state
RESUME_GROUP_TMP="$(mktemp "${STATE_FILE}.resume-group.XXXXXX")"
jq '.shared_branch_groups = {
  "issue/9+2":{
    work_branch:"issue/9+2",head_iid:9,tail_iid:2,
    members:[9,2],scope_id:"batch-A",merge_target_branch:"main"
  }
}' "${STATE_FILE}" >"${RESUME_GROUP_TMP}"
mv "${RESUME_GROUP_TMP}" "${STATE_FILE}"
RESUME_HEAD_SHA="$(printf 'resume C1\n' \
  | git -C "${PROJECT_REPO}" commit-tree HEAD^{tree} -p "${DEPENDENCY_SHA}")"
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9+2 "${RESUME_HEAD_SHA}"
mkdir -p "${PROJECT_REPO}/.req_executor/issues/issue-2"
jq -n --arg dependency_sha "${DEPENDENCY_SHA}" \
  --arg work_branch_sha "${RESUME_HEAD_SHA}" '{
    iid:2,status:"blocked",retry_count:0,
    work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"tail",
    dependency_iid:9,dependency_branch:"issue/9+2",
    dependency_base_sha:$dependency_sha,
    work_branch_sha:$work_branch_sha,
    dependency_history_verified:true
  }' >"${PROJECT_REPO}/.req_executor/issues/issue-2/state.json"
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
export TEST_EXPECT_CONTINUE_BASE_REQUIRED_IID=2
CONTINUE_READY="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON \
  TEST_EXPECT_CONTINUE_BASE_REQUIRED_IID
printf '%s' "${CONTINUE_READY}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
  and .deferred_entries == []
' >/dev/null || fail "continue did not bypass a dependency gate it no longer needs"
[ "$(cat "${PREP_LOG}")" = '2|main|continue' ] \
  || fail "continue did not preserve C own-branch resume semantics"
CONTINUE_PAYLOAD="$(printf '%s' "${CONTINUE_READY}" \
  | jq -r '.dispatch_entries[0].payload_path')"
CONTINUE_MANIFEST="$(sed -n 's/^manifest_path=//p' "${CONTINUE_PAYLOAD}")"
CONTINUE_EXECUTOR_PAYLOAD="$(jq -r '.executor_payload_path' \
  "${CONTINUE_MANIFEST}")"
grep -Fq "EXPECTED_WORK_BRANCH_SHA=${RESUME_HEAD_SHA}" \
  "${CONTINUE_EXECUTOR_PAYLOAD}" \
  || fail "continue did not retain C1 as the exact remote push lease"
grep -Fq "EXPECTED_COMMIT_PARENT_SHA=${DEPENDENCY_SHA}" \
  "${CONTINUE_EXECUTOR_PAYLOAD}" \
  || fail "continue did not retain frozen A as C replacement's only parent"

# A branch whose verified history was dependency-free cannot acquire a new
# baseline merely because the mutable Issue body changed before continue.
write_terminal_race_state
jq -n --arg work_branch_sha "${RESUME_HEAD_SHA}" '{
  iid:2,status:"blocked",retry_count:0,
  work_branch_sha:$work_branch_sha,
  dependency_history_verified:true
}' >"${PROJECT_REPO}/.req_executor/issues/issue-2/state.json"
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
NEW_CONTINUE_DEP_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0].auto_merge=true | .grants[0].merge_target_branch="main"')"
NEW_CONTINUE_DEP_OUTPUT="$(run_wrapper "${NEW_CONTINUE_DEP_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON
printf '%s' "${NEW_CONTINUE_DEP_OUTPUT}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == []
  and .skipped_entries[0].reason == "continue_branch_history_mismatch"
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: continue_branch_history_mismatch"
' >/dev/null \
  || fail "dependency-changing continue bypassed verified branch history"
[ ! -s "${PREP_LOG}" ] \
  || fail "dependency-changing continue reached worktree preparation"

# Once a shared pair is frozen, removing C's declaration cannot turn C back
# into an ordinary issue branch or reinterpret its existing history.
A1_SHA="$(git -C "${PROJECT_REPO}" rev-parse HEAD)"
C_RESUME_SHA="$(printf 'dependent resume\n' \
  | git -C "${PROJECT_REPO}" commit-tree HEAD^{tree} -p "${A1_SHA}")"
git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/main "${A1_SHA}"
git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/issue/9+2 "${C_RESUME_SHA}"
jq -n --arg dependency_sha "${A1_SHA}" \
  --arg work_branch_sha "${C_RESUME_SHA}" '{
    iid:2,status:"blocked",retry_count:0,
    work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"tail",
    dependency_iid:9,dependency_branch:"issue/9+2",
    dependency_base_sha:$dependency_sha,
    work_branch_sha:$work_branch_sha,
    dependency_history_verified:true
  }' >"${PROJECT_REPO}/.req_executor/issues/issue-2/state.json"
write_terminal_race_state
SHARED_STATE_TMP="$(mktemp "${STATE_FILE}.shared.XXXXXX")"
jq '.shared_branch_groups = {
  "issue/9+2":{
    work_branch:"issue/9+2",head_iid:9,tail_iid:2,
    members:[9,2],scope_id:"batch-A",merge_target_branch:"main"
  }
}' "${STATE_FILE}" >"${SHARED_STATE_TMP}"
mv "${SHARED_STATE_TMP}" "${STATE_FILE}"
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION=body
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
SHARED_DECLARATION_CHANGED="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON
printf '%s' "${SHARED_DECLARATION_CHANGED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: shared_branch_dependency_changed"
' >/dev/null \
  || fail "frozen shared dependency accepted a changed Issue declaration"
jq -e --arg sha "${A1_SHA}" '
  .dependency_iid == 9
  and .dependency_branch == "issue/9+2"
  and .dependency_base_sha == $sha
  and .status == "blocked"
' "${PROJECT_REPO}/.req_executor/issues/issue-2/state.json" >/dev/null \
  || fail "shared declaration guard overwrote C's verified dependency tuple"
[ ! -s "${PREP_LOG}" ] \
  || fail "shared declaration guard reached worktree preparation"

# Keep an ordinary resume ref for the legacy/missing-state fail-closed checks
# below; those checks remain independent of the shared-pair binding above.
git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/issue/2 "${C_RESUME_SHA}"
STICKY_AUTO_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c \
  '.grants[0].entry_mode="continue"
   | .grants[0].auto_merge=true
   | .grants[0].merge_target_branch="main"')"

# A remote resume branch can survive loss of the workstation-local state. Its
# original ancestry cannot be reconstructed from today's body or branch heads,
# so every continue must fail closed. In particular, a manual continue must not
# create a dependency-free state record that a later auto-merge would trust.
ISSUE_2_STATE="${PROJECT_REPO}/.req_executor/issues/issue-2/state.json"
ISSUE_2_STATE_BACKUP="${PROJECT_REPO}/.req_executor/issues/issue-2/state.before-missing"
mv "${ISSUE_2_STATE}" "${ISSUE_2_STATE_BACKUP}"
write_terminal_race_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION=body
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
MISSING_STATE_AUTO_BLOCK="$(run_wrapper "${STICKY_AUTO_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON
printf '%s' "${MISSING_STATE_AUTO_BLOCK}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == []
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: unverified_continue_dependency_history"
' >/dev/null \
  || fail "missing continue state allowed an unverifiable auto-merge"
[ ! -s "${PREP_LOG}" ] \
  || fail "missing-state auto-merge guard reached worktree preparation"
mv "${ISSUE_2_STATE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-2/state.after-missing-none"

# Even a currently valid declaration cannot prove which historical dependency
# SHA the existing C branch inherited before A was rewritten.
write_terminal_race_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖 Issue #9'
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
MISSING_STATE_RESOLVED_BLOCK="$(run_wrapper "${STICKY_AUTO_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON
printf '%s' "${MISSING_STATE_RESOLVED_BLOCK}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == []
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: unverified_continue_dependency_history"
' >/dev/null \
  || fail "live declaration rebuilt unverifiable dependency history"
[ ! -s "${PREP_LOG}" ] \
  || fail "missing-state declared auto-merge guard reached worktree preparation"
mv "${ISSUE_2_STATE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-2/state.after-missing-resolved"

# Non-auto continue is also blocked, preventing it from laundering unknown
# ancestry into an apparently dependency-free durable state.
write_terminal_race_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION=body
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
MISSING_STATE_MANUAL_BLOCK="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON
printf '%s' "${MISSING_STATE_MANUAL_BLOCK}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == []
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: unverified_continue_dependency_history"
' >/dev/null \
  || fail "manual continue laundered unverifiable dependency history"
[ ! -s "${PREP_LOG}" ] \
  || fail "missing-state manual guard reached worktree preparation"
mv "${ISSUE_2_STATE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-2/state.after-missing-manual"
mv "${ISSUE_2_STATE_BACKUP}" "${ISSUE_2_STATE}"

# Pre-feature state has no cryptographic binding between its recorded result
# and the current remote C head. It must not be auto-migrated from that mutable
# head, even when a legacy commit_sha happens to look plausible.
LEGACY_STATE_BACKUP="${PROJECT_REPO}/.req_executor/issues/issue-2/state.before-legacy"
mv "${ISSUE_2_STATE}" "${LEGACY_STATE_BACKUP}"
jq -n --arg sha "${C_RESUME_SHA}" \
  '{iid:2,status:"blocked",commit_sha:$sha,retry_count:0}' \
  >"${ISSUE_2_STATE}"
write_terminal_race_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION=body
export FAKE_DEPENDENT_LABELS_JSON='["continue"]'
LEGACY_STATE_BLOCK="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION FAKE_DEPENDENT_LABELS_JSON
printf '%s' "${LEGACY_STATE_BLOCK}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .tick_outcome_per_iid["2"] ==
    "blocked: issue_dependency_invalid: invalid_persisted_dependency_metadata"
' >/dev/null \
  || fail "legacy state trusted a mutable remote continue head"
[ ! -s "${PREP_LOG}" ] \
  || fail "legacy-state guard reached worktree preparation"
mv "${ISSUE_2_STATE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-2/state.after-legacy"
mv "${LEGACY_STATE_BACKUP}" "${ISSUE_2_STATE}"

echo "ok driven topup filters live skips and preserves scheduler job identity"
