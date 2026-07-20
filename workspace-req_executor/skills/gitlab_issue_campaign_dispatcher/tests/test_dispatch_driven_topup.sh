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
  gitlab_env_resolver.sh parse_issue_dependency.sh \
  resolve_driven_repo_path.sh; do
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
cat >"${FIXTURE_SCRIPTS}/allocate_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${IID}" >>"${TEST_ALLOC_LOG}"
printf '1\n'
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
    && ! [[ "${CONTINUE_BASE_REF:-}" =~ ^refs/heads/issue/${ISSUE_IID}-att[0-9]+$ ]]; then
  echo "missing exact CONTINUE_BASE_REF for ${ISSUE_IID}" >&2
  exit 90
fi
source "${SCRIPT_DIR}/env_paths.sh"
mkdir -p "${WORKTREE_DIR}/.git" "${WORKTREE_DIR}/.claude" "${LOG_DIR}" "${OUTPUT_DIR}"
local_branch="issue/${ISSUE_IID}-att$(printf '%03d' "${ATTEMPT_NUMBER}")"
if [ -n "${SHARED_BRANCH_ROLE:-}" ]; then
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
    | .dependency_pinned_attempt_number=.latest_attempt_number
    | .merge_request_url="https://gitlab.test/group/project/-/merge_requests/17"
    | .mr_finalization={
        status:"verified_open",source_attempt_number:.latest_attempt_number,
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
        source_attempt_number:.latest_attempt_number,
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
cat >"${BIN_DIR}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'api user' ]; then
  jq -cn '{username:"req-executor-bot"}'
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
  pending_subagents:{"1":{attempt_number:1,run_id:"old-run",
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
    (.attempt_number == 1)
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
' >/dev/null || fail "driven topup did not separate executable grants from stable skipped entries"

for iid in 2 3 6; do
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
  grep -Fq "top-level project, job_id, iid, and attempt_number fields (there is no nested identity object)" \
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
    and .attempt_number == 1
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
  and .pending_subagents["2"].merge_target_branch == null
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

# Persisted shared-group identity is an authorization boundary. The branch key
# must encode the same ordered members, one IID may belong to only one group,
# and a frozen merge target must be a non-empty string.
for invalid_group_case in mismatched_key duplicate_member invalid_target; do
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

# A declared dependency is a deferred ordering condition, not a failed
# attempt. Until the prerequisite has both a successful workflow label and a
# matching durable commit on the shared branch, the dependent consumes no
# attempt and creates no project pending placeholder. Once ready, it appends to
# the frozen shared branch while the independently resolved MR target stays main.
for dependency_cycle_case in root_cycle upstream_cycle; do
  write_terminal_race_state
  case "${dependency_cycle_case}" in
    root_cycle)
      export FAKE_ISSUE_DESCRIPTIONS_JSON='{
        "2":"依赖 Issue #9",
        "9":"依赖 Issue #10",
        "10":"依赖 Issue #2"
      }'
      ;;
    upstream_cycle)
      export FAKE_ISSUE_DESCRIPTIONS_JSON='{
        "2":"依赖 Issue #9",
        "9":"依赖 Issue #10",
        "10":"依赖 Issue #9"
      }'
      ;;
  esac
  DEPENDENCY_CYCLE_OUTPUT="$(run_wrapper "${RACE_REQUEST}")"
  unset FAKE_ISSUE_DESCRIPTIONS_JSON
  printf '%s' "${DEPENDENCY_CYCLE_OUTPUT}" | jq -e '
    .status == "no_eligible_iids"
    and .dispatch_entries == []
    and .pending_iids == []
    and .dependency_waiting == []
    and .deferred_entries == []
    and .skipped_entries == [{
      job_id:"job-2",batch_id:"batch-A",snapshot_index:0,
      project:"group/project",iid:2,status:"skipped",
      reason:"dependency_cycle"
    }]
    and .tick_outcome_per_iid["2"] ==
      "blocked: issue_dependency_invalid: dependency_cycle"
  ' >/dev/null || fail "${dependency_cycle_case} was not rejected explicitly"
  [ "$(cat "${ALLOC_LOG}")" = 2 ] && [ ! -s "${PREP_LOG}" ] \
    || fail "${dependency_cycle_case} reached worktree preparation or allocated repeatedly"
  jq -e '
    (.pending_subagents | has("2") | not)
    and (.blocked_iids | index(2) != null)
  ' "${STATE_FILE}" >/dev/null \
    || fail "${dependency_cycle_case} did not drain its placeholder into blocked state"
done

# A stable completed prerequisite no longer waits on its old declaration, so
# that historical edge must cut off cycle traversal.
write_terminal_race_state
export FAKE_ISSUE_DESCRIPTIONS_JSON='{
  "2":"依赖 Issue #9",
  "9":"依赖 Issue #2"
}'
export FAKE_ISSUE_LABELS_JSON='{"9":["pr"]}'
COMPLETED_EDGE_OUTPUT="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_ISSUE_DESCRIPTIONS_JSON FAKE_ISSUE_LABELS_JSON
printf '%s' "${COMPLETED_EDGE_OUTPUT}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .skipped_entries == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9+2",
    reason:"dependency_branch_migration_pending"
  }]
' >/dev/null || fail "completed dependency did not enter late branch migration"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "completed-edge branch wait consumed an attempt"

# A bounded parser timeout is a non-terminal ordering retry. It must release
# the scheduler slot without allocating an attempt or misreporting completion.
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
unset FAKE_ISSUE_DESCRIPTIONS_JSON
mv "${BIN_DIR}/timeout" "${BIN_DIR}/timeout.injected-test"
unset TEST_REAL_TIMEOUT
printf '%s' "${DEPENDENCY_CHECK_DEFERRED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .skipped_entries == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9+2",
    reason:"dependency_cycle_check_deferred"
  }]
  and .deferred_entries[0].reason == "dependency_cycle_check_deferred"
' >/dev/null || fail "dependency cycle-check timeout was not deferred"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "dependency cycle-check timeout consumed an attempt"

# Root parser and Issue lookup timeouts happen before a dependency IID is
# known. They must use the nullable preflight deferral envelope, keep the
# scheduler membership retryable, and consume no attempt.
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
  export FAKE_ROOT_TIMEOUT_MODE="${root_preflight_timeout}"
  write_terminal_race_state
  ROOT_PREFLIGHT_DEFERRED="$(run_wrapper "${RACE_REQUEST}")"
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
      iid:2,dependency_iid:null,branch:null,
      reason:$reason
    }]
    and .deferred_entries == [{
      job_id:"job-2",batch_id:"batch-A",snapshot_index:0,
      project:"group/project",iid:2,status:"deferred",
      reason:$reason,dependency_iid:null,
      dependency_branch:null
    }]
  ' >/dev/null \
    || fail "root ${root_preflight_timeout} timeout was not retryably deferred"
  [ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
    || fail "root ${root_preflight_timeout} timeout consumed an attempt"
done
unset FAKE_ROOT_TIMEOUT_MODE TEST_REAL_TIMEOUT
mv "${BIN_DIR}/timeout" "${BIN_DIR}/timeout.root-preflight-test"

# The first declared prerequisite lookup shares the same phase deadline and
# per-call timeout as chain traversal, while retaining the known dependency in
# its deferral envelope.
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
export FAKE_DEPENDENCY_DESCRIPTION='依赖于 Issue #9'
DIRECT_LOOKUP_DEFERRED="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION TEST_REAL_TIMEOUT
mv "${BIN_DIR}/timeout" "${BIN_DIR}/timeout.direct-lookup-test"
printf '%s' "${DIRECT_LOOKUP_DEFERRED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .skipped_entries == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9+2",
    reason:"dependency_cycle_check_deferred"
  }]
  and .deferred_entries[0].reason == "dependency_cycle_check_deferred"
' >/dev/null || fail "direct dependency lookup timeout was not deferred"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "direct dependency lookup timeout consumed an attempt"

write_terminal_race_state
export FAKE_DEPENDENT_IID=2
export FAKE_DEPENDENCY_DESCRIPTION='依赖于 Issue #9'
export FAKE_DEPENDENCY_LABEL=pr
DEPENDENCY_WAIT="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENCY_LABEL
printf '%s' "${DEPENDENCY_WAIT}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9+2",
    reason:"dependency_branch_migration_pending"
  }]
  and .deferred_entries == [{
    job_id:"job-2",batch_id:"batch-A",snapshot_index:0,
    project:"group/project",iid:2,status:"deferred",
    reason:"dependency_branch_migration_pending",dependency_iid:9,
    dependency_branch:"issue/9+2"
  }]
' >/dev/null || fail "unready dependency migration was not deferred without launch"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] && [ ! -s "${LABEL_LOG}" ] \
  || fail "unready dependency consumed attempt, prepared a worktree, or changed labels"
jq -e '
  (.pending_subagents | has("2") | not)
  and (.unfinished_iids | index(2) != null)
' "${STATE_FILE}" >/dev/null \
  || fail "unready dependency did not remain retryable without a placeholder"

git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/issue/9+2 HEAD
: >"${ALLOC_LOG}"
: >"${PREP_LOG}"
: >"${LABEL_LOG}"
: >"${GLAB_LOG}"
DEPENDENCY_INCOMPLETE="$(run_wrapper "${RACE_REQUEST}")"
printf '%s' "${DEPENDENCY_INCOMPLETE}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .dependency_waiting == [{
    iid:2,dependency_iid:9,branch:"issue/9+2",reason:"dependency_not_completed"
  }]
' >/dev/null || fail "existing partial dependency branch was released before successful completion"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] && [ ! -s "${LABEL_LOG}" ] \
  || fail "incomplete dependency branch consumed execution budget"

export FAKE_DEPENDENCY_LABELS_JSON='["pr","continue"]'
DEPENDENCY_RESUMING="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENCY_LABELS_JSON
printf '%s' "${DEPENDENCY_RESUMING}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .dependency_waiting[0].reason == "dependency_not_completed"
' >/dev/null || fail "dependency with a pending continue request was treated as stable"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] && [ ! -s "${LABEL_LOG}" ] \
  || fail "resuming dependency released its dependent"

export FAKE_DEPENDENCY_LABEL=pr
: >"${ALLOC_LOG}"
: >"${PREP_LOG}"
: >"${LABEL_LOG}"
: >"${GLAB_LOG}"
DEPENDENCY_UNVERIFIED="$(run_wrapper "${RACE_REQUEST}")"
printf '%s' "${DEPENDENCY_UNVERIFIED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .dependency_waiting[0].reason == "dependency_branch_migration_pending"
' >/dev/null || fail "dependency branch was released without migration-safe durable state"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] && [ ! -s "${LABEL_LOG}" ] \
  || fail "unverified dependency commit consumed execution budget"

# A stacked dependency commit is allowed as a manual-review development
# baseline, but C must not auto-merge that unreviewed commit into main. The
# pinned prerequisite SHA has to be an ancestor of the exact merge target.
STACKED_DEPENDENCY_SHA="$(printf 'stacked dependency\n' \
  | git -C "${PROJECT_REPO}" commit-tree HEAD^{tree} -p HEAD)"
git -C "${PROJECT_REPO}" update-ref \
  refs/remotes/origin/issue/9+2 "${STACKED_DEPENDENCY_SHA}"
mkdir -p "${PROJECT_REPO}/.req_executor/issues/issue-9"
jq -n --arg sha "${STACKED_DEPENDENCY_SHA}" \
  '{iid:9,status:"done",commit_sha:$sha,work_branch:"issue/9+2",
    branch_members:[9,2],shared_branch_role:"head",
    dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
    merge_request_url:"https://gitlab.test/group/project/-/merge_requests/17"}' \
  >"${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
write_terminal_race_state
AUTO_MERGE_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c \
  '.grants[0].auto_merge = true | .grants[0].merge_target_branch = "main"')"
AUTO_MERGE_WAIT="$(run_wrapper "${AUTO_MERGE_REQUEST}")"
printf '%s' "${AUTO_MERGE_WAIT}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .dependency_waiting == []
  and .skipped_entries[0].reason == "shared_branch_auto_merge_unsupported"
' >/dev/null || fail "auto-merge bypassed the prerequisite merge target gate"
[ "$(cat "${ALLOC_LOG}")" = 2 ] && [ ! -s "${PREP_LOG}" ] \
  && grep -Fq '2|add blocked-dispatcher' "${LABEL_LOG}" \
  || fail "shared-branch auto-merge rejection reached worktree preparation"

DEPENDENCY_SHA="$(git -C "${PROJECT_REPO}" rev-parse HEAD)"
git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/issue/9+2 "${DEPENDENCY_SHA}"
mkdir -p "${PROJECT_REPO}/.req_executor/issues/issue-9"
  jq -n --arg sha "${DEPENDENCY_SHA}" \
  '{iid:9,status:"done",commit_sha:$sha,work_branch:"issue/9+2",
    branch_members:[9,2],shared_branch_role:"head",
    work_branch_sha:$sha,dependency_history_verified:true,
    latest_attempt_number:1,dependency_pinned_attempt_number:1,
    dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
    merge_request_url:"https://gitlab.test/group/project/-/merge_requests/17",
    mr_finalization:{
      status:"verified_open",source_attempt_number:1,
      work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"head",
      commit_sha:$sha,
      intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      target_branch:"main",iid:17,
      web_url:"https://gitlab.test/group/project/-/merge_requests/17",
      mr_action:"created",verified_at:"2026-07-19T00:00:00Z"
    }}' \
  >"${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
chmod 600 "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
export FAKE_SHARED_MR_SHA="${DEPENDENCY_SHA}"
VALID_DEPENDENCY_STATE="$(mktemp \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.valid.XXXXXX")"
cp "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" \
  "${VALID_DEPENDENCY_STATE}"
for invalid_dependency_binding in missing_finalization mismatched_target unverified_history; do
  case "${invalid_dependency_binding}" in
    missing_finalization)
      jq 'del(.mr_finalization)' "${VALID_DEPENDENCY_STATE}" \
        >"${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
      ;;
    mismatched_target)
      jq '.mr_finalization.target_branch = "release"' \
        "${VALID_DEPENDENCY_STATE}" \
        >"${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
      ;;
    unverified_history)
      jq '.dependency_history_verified = false' "${VALID_DEPENDENCY_STATE}" \
        >"${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"
      ;;
  esac
  write_terminal_race_state
  INVALID_DEPENDENCY_BINDING="$(run_wrapper "${RACE_REQUEST}")"
  printf '%s' "${INVALID_DEPENDENCY_BINDING}" | jq -e '
    .status == "no_eligible_iids"
    and .dispatch_entries == []
    and .dependency_waiting[0].reason == "dependency_commit_unverified"
  ' >/dev/null \
    || fail "${invalid_dependency_binding} dependency MR binding released C"
  [ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
    || fail "${invalid_dependency_binding} dependency MR binding reached preparation"
done
cp "${VALID_DEPENDENCY_STATE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json"

# A pending claim still blocks C during the Phase-6 crash window. Once that
# claim is absent, A may come from an earlier campaign and need not appear in
# this campaign's completed_iids; its private migration-safe state supplies
# the durable proof for the late-binding transaction.
write_terminal_race_state
UNSETTLED_STATE_TMP="$(mktemp "${STATE_FILE}.dependency-unsettled.XXXXXX")"
jq --arg now "${NOW}" '.pending_subagents["9"] = {
    attempt_number:1,run_id:"run-A",child_session_key:"child-A",
    spawned_at:$now,placeholder:false,acpx_timeout_seconds:18000,
    auto_merge:false,branch:"main",merge_target_branch:"main",
    work_branch:"issue/9+2",branch_members:[9,2],shared_branch_role:"head",
    dependency_iid:null,dependency_branch:null,dependency_base_sha:null
  }
  | .active_issue_iids=[9]
  | .active_issue_sessions=["issue-project-9"]' \
  "${STATE_FILE}" >"${UNSETTLED_STATE_TMP}"
mv "${UNSETTLED_STATE_TMP}" "${STATE_FILE}"
DEPENDENCY_HEAD_PENDING="$(run_wrapper "${RACE_REQUEST}")"
printf '%s' "${DEPENDENCY_HEAD_PENDING}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .dependency_waiting[0].reason == "dependency_not_completed"
' >/dev/null || fail "campaign-pending A released C during Phase-6 crash window"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "campaign-pending A allowed C to allocate or prepare"

write_terminal_race_state
MISSING_COMPLETED_TMP="$(mktemp "${STATE_FILE}.dependency-completed.XXXXXX")"
jq '.completed_iids=[]' "${STATE_FILE}" >"${MISSING_COMPLETED_TMP}"
mv "${MISSING_COMPLETED_TMP}" "${STATE_FILE}"
DEPENDENCY_NOT_CLASSIFIED="$(run_wrapper "${RACE_REQUEST}")"
printf '%s' "${DEPENDENCY_NOT_CLASSIFIED}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || fail "earlier-campaign A did not release C after durable migration proof"
[ "$(cat "${ALLOC_LOG}")" = 2 ] \
  || fail "earlier-campaign A did not allocate exactly one C attempt"

# Historical `verified_open` state is not enough to release C. If A's one MR
# is closed after Phase 6, the fresh dependency gate must keep C unstarted.
write_terminal_race_state
: >"${ALLOC_LOG}"
: >"${PREP_LOG}"
: >"${LABEL_LOG}"
export FAKE_SHARED_MR_STATE=closed
DEPENDENCY_MR_CLOSED="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_SHARED_MR_STATE
printf '%s' "${DEPENDENCY_MR_CLOSED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .dependency_waiting[0].reason == "dependency_commit_unverified"
' >/dev/null || fail "closed A MR released C from the live dependency gate"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  || fail "closed A MR allowed C to allocate or prepare"

# A is the immutable head commit of issue/9+2. A continue request must remain
# a retryable scheduler deferral and must not enter attempt preparation or the
# prep-blocked Phase-6 path, because either path could overwrite the verified
# A state that releases C. Removing continue then lets the existing C gate use
# these exact same state bytes.
HEAD_CONTINUE_STATE_TMP="$(mktemp "${STATE_FILE}.head-continue.XXXXXX")"
jq '.issue_min_iid=9 | .issue_max_iid=9 | .issue_iids_whitelist=[9]
  | .unfinished_iids=[9] | .completed_iids=[]' \
  "${STATE_FILE}" >"${HEAD_CONTINUE_STATE_TMP}"
mv "${HEAD_CONTINUE_STATE_TMP}" "${STATE_FILE}"
HEAD_CONTINUE_REQUEST="$(printf '%s' "${RACE_REQUEST}" | jq -c '
  .grants[0] |= (
    .job_id="job-9" | .iid=9 | .snapshot_index=2 | .branch="main"
    | .entry_mode="auto" | .force_rerun_pr=false
    | .auto_merge=false | .merge_target_branch=null
  )')"
HEAD_STATE_BEFORE="$(mktemp "${TEST_ROOT}/head-state-before.XXXXXX")"
cp "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" \
  "${HEAD_STATE_BEFORE}"
: >"${ALLOC_LOG}"
: >"${PREP_LOG}"
: >"${LABEL_LOG}"
: >"${GLAB_LOG}"
export FAKE_ISSUE_LABELS_JSON='{"9":["pr","continue"]}'
HEAD_CONTINUE_DEFERRED="$(run_wrapper "${HEAD_CONTINUE_REQUEST}")"
unset FAKE_ISSUE_LABELS_JSON
printf '%s' "${HEAD_CONTINUE_DEFERRED}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and .pending_iids == []
  and .skipped_entries == []
  and .dependency_waiting == [{
    iid:9,dependency_iid:null,branch:null,
    reason:"shared_branch_head_continue_unsupported"
  }]
  and .deferred_entries == [{
    job_id:"job-9",batch_id:"batch-A",snapshot_index:2,
    project:"group/project",iid:9,status:"deferred",
    reason:"shared_branch_head_continue_unsupported",
    dependency_iid:null,dependency_branch:null
  }]
' >/dev/null || fail "shared head continue was not deferred before attempt allocation"
[ ! -s "${ALLOC_LOG}" ] && [ ! -s "${PREP_LOG}" ] \
  && [ ! -s "${LABEL_LOG}" ] \
  || fail "shared head continue allocated, prepared, or mutated workflow labels"
cmp -s "${HEAD_STATE_BEFORE}" \
  "${PROJECT_REPO}/.req_executor/issues/issue-9/state.json" \
  || fail "shared head continue overwrote A verified Issue state"

# The continue label is now absent from the fake live A response. Reuse the
# byte-identical A state above and prove C can still cross its dependency gate.
write_terminal_race_state
: >"${ALLOC_LOG}"
: >"${PREP_LOG}"
: >"${LABEL_LOG}"
: >"${GLAB_LOG}"
DEPENDENCY_READY="$(run_wrapper "${RACE_REQUEST}")"
unset FAKE_DEPENDENCY_LABEL FAKE_DEPENDENT_IID FAKE_DEPENDENCY_DESCRIPTION
printf '%s' "${DEPENDENCY_READY}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [2]
  and .dependency_waiting == []
' >/dev/null || fail "completed dependency did not release its dependent"
[ "$(cat "${ALLOC_LOG}")" = '2' ] \
  || fail "released dependency did not allocate exactly one dependent attempt"
[ "$(cat "${PREP_LOG}")" = '2|issue/9+2|fresh' ] \
  || fail "dependent fresh attempt did not use the prerequisite issue branch"

DEPENDENCY_PAYLOAD="$(printf '%s' "${DEPENDENCY_READY}" | jq -r '.dispatch_entries[0].payload_path')"
DEPENDENCY_MANIFEST="$(sed -n 's/^manifest_path=//p' "${DEPENDENCY_PAYLOAD}")"
DEPENDENCY_EXECUTOR_PAYLOAD="$(jq -r '.executor_payload_path' "${DEPENDENCY_MANIFEST}")"
grep -Fq 'BRANCH=issue/9+2' "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependency base branch was not rendered into the executor payload"
grep -Fq "CONFIG_BRANCH=main" "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependency changed the trusted Claude config branch"
grep -Fq "DEPENDENCY_BASE_SHA=${DEPENDENCY_SHA}" "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependency base commit was not pinned in the executor payload"
grep -Fq "EXPECTED_WORK_BRANCH_SHA=${DEPENDENCY_SHA}" \
  "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependent push lease was not pinned to A's exact commit"
grep -Fq "EXPECTED_COMMIT_PARENT_SHA=${DEPENDENCY_SHA}" \
  "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependent commit parent was not pinned to A's exact commit"
grep -Fq 'MERGE_TARGET_BRANCH=main' "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependency unexpectedly changed the independently resolved MR target"
grep -Fq 'WORK_BRANCH=issue/9+2' "${DEPENDENCY_EXECUTOR_PAYLOAD}" \
  || fail "dependent Issue did not retain the shared canonical work branch"

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
