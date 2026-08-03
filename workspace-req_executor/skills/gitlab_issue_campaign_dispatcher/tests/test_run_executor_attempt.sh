#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/run_executor_attempt.sh"

fail() {
  echo "test_run_executor_attempt.sh: $*" >&2
  exit 1
}

sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

file_mode() {
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

[ -x "${WRAPPER}" ] || fail "run_executor_attempt.sh is missing or not executable"

# GNU `stat -f` has filesystem semantics, not BSD format semantics. A failed
# probe can leak stdout, and a format-looking filename can even make it return
# success. Production helpers must capture and validate every probe.
for production_script in "${SKILL_DIR}"/scripts/*.sh; do
  if grep -Eq "^[[:space:]]*if[^#]*stat[[:space:]]+-f([[:space:]]|$)" \
      "${production_script}"; then
    fail "${production_script} probes ambiguous GNU/BSD stat -f before stat -c"
  fi
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-executor-attempt.XXXXXX")"
FAKE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
REPO_PATH="${TEST_ROOT}/repo"
ORDER_LOG="${TEST_ROOT}/order.log"
mkdir -p "${FAKE_SCRIPTS}" "${FAKE_BIN}" "${REPO_PATH}"
cp "${WRAPPER}" "${FAKE_SCRIPTS}/run_executor_attempt.sh"
chmod +x "${FAKE_SCRIPTS}/run_executor_attempt.sh"

cat >"${FAKE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${PROJECT:?}" "${GROUP:?}" "${ISSUE_IID:?}" "${EXECUTION_ID:?}" "${REPO_PATH:?}"
export WORKTREE_DIR="${REPO_PATH}/worktree"
export OUTPUT_DIR="${WORKTREE_DIR}/.req_executor/issue-${ISSUE_IID}/output"
export LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-${ISSUE_IID}/log/execution-${EXECUTION_ID}"
export ISSUE_ROOT="${REPO_PATH}/.req_executor/issues/issue-${ISSUE_IID}"
export ISSUES_ROOT="${REPO_PATH}/.req_executor/issues"
export EXECUTIONS_ROOT="${ISSUE_ROOT}/executions"
export EXECUTION_STATE_FILE="${EXECUTIONS_ROOT}/execution-${EXECUTION_ID}.json"
export ISSUE_STATE_FILE="${ISSUE_ROOT}/state.json"
export WORK_BRANCH="${WORK_BRANCH:-issue/${ISSUE_IID}}"
export LOCAL_ISSUE_BRANCH="issue/${ISSUE_IID}"
mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}" "${EXECUTIONS_ROOT}"
EOF

cat >"${FAKE_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kill-after=*) shift ;;
    --kill-after) shift 2 ;;
    *s) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF
cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *' rev-list --parents -n 1 '*)
    printf '%s %s\n' \
      0123456789abcdef0123456789abcdef01234567 \
      "${EXPECTED_COMMIT_PARENT_SHA:?}"
    ;;
  *' rev-parse --verify refs/remotes/origin/'*)
    if [ -n "${ARCHIVE_ADVANCED_FILE:-}" ] \
        && [ -s "${ARCHIVE_ADVANCED_FILE}" ]; then
      cat "${ARCHIVE_ADVANCED_FILE}"
    else
      printf '%s\n' 0123456789abcdef0123456789abcdef01234567
    fi
    ;;
  *' rev-parse --verify '*)
    if [ -n "${LOG_TEST_SHA:-}" ] && [[ "$*" == *"${LOG_TEST_SHA}"* ]]; then
      printf '%s\n' "${LOG_TEST_SHA}"
    else
      printf '%s\n' 0123456789abcdef0123456789abcdef01234567
    fi
    ;;
  *' merge-base --is-ancestor '*)
    exit 0
    ;;
  *)
    echo "unexpected git invocation: $*" >&2
    exit 91
    ;;
esac
EOF
cat >"${FAKE_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  -f:%Lp|-f:%u)
    printf '%s\n' 'filesystem-noise-that-must-not-reach-the-caller'
    exit 0
    ;;
  -c:%a)
    printf '%s\n' 600
    ;;
  -c:%u)
    id -u
    ;;
  *)
    echo "unexpected stat invocation: $*" >&2
    exit 92
    ;;
esac
EOF

cat >"${FAKE_SCRIPTS}/run_acpx_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' acpx >>"${ORDER_LOG}"
printf 'ACPX_EXIT=%s\n' "${ACPX_TEST_EXIT:-0}"
EOF
cat >"${FAKE_SCRIPTS}/stage_and_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' stage >>"${ORDER_LOG}"
printf '%s\n' "${STAGE_TEST_MARKER:-STAGED_OK}"
EOF
cat >"${FAKE_SCRIPTS}/commit_and_push.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' commit >>"${ORDER_LOG}"
if [ -n "${COMMIT_TITLE_CAPTURE_FILE:-}" ]; then
  printf '%s\n' "${ISSUE_TITLE}" >"${COMMIT_TITLE_CAPTURE_FILE}"
fi
printf '%s\n' 0123456789abcdef0123456789abcdef01234567
[ "${COMMIT_TEST_EXIT:-0}" -eq 0 ] || exit "${COMMIT_TEST_EXIT}"
EOF
cat >"${FAKE_SCRIPTS}/post_push_verify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify:%s\n' "${BRANCH}" >>"${ORDER_LOG}"
EOF
cat >"${FAKE_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'label:%s:%s\n' "$1" "$2" >>"${ORDER_LOG}"
if [ "${LABEL_TEST_FAIL_ADD:-}" = "$2" ] && [ "$1" = add ]; then
  echo "simulated add $2 label failure" >&2
  exit 73
fi
EOF
cat >"${FAKE_SCRIPTS}/create_mr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fixed_intent_id=""
if [[ "${WORK_BRANCH}" =~ ^issue/([1-9][0-9]*)\+([1-9][0-9]*)$ ]]; then
  fixed_shared_head="${BASH_REMATCH[1]}"
  fixed_shared_tail="${BASH_REMATCH[2]}"
  fixed_branch_members="[${fixed_shared_head},${fixed_shared_tail}]"
  if [ "${ISSUE_IID}" = "${fixed_shared_head}" ]; then
    fixed_shared_role=head
  elif [ "${ISSUE_IID}" = "${fixed_shared_tail}" ]; then
    fixed_shared_role=tail
  else
    echo "fake create_mr: current Issue is not a shared branch member" >&2
    exit 97
  fi
  fixed_intent_id="$(jq -r '.mr_finalization.intent_id' "${ISSUE_STATE_FILE}")"
  jq -e \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg work_branch "${WORK_BRANCH}" \
    --argjson branch_members "${fixed_branch_members}" \
    --arg shared_branch_role "${fixed_shared_role}" \
    --arg commit_sha "${COMMIT_SHA}" \
    --arg intent_id "${fixed_intent_id}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" '
      .mr_finalization == {
        status:"pending",
        source_execution_id:$execution_id,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:$shared_branch_role,
        commit_sha:$commit_sha,
        intent_id:$intent_id,
        target_branch:$target_branch
      }
    ' "${ISSUE_STATE_FILE}" >/dev/null \
    || { echo "shared MR pending checkpoint is missing or mismatched" >&2; exit 98; }
  printf '%s\n' mr-pending-checkpoint >>"${ORDER_LOG}"
fi
if [ -n "${MR_TEST_RECOVERY_LOG:-}" ]; then
  printf '%s\n' "${SHARED_MR_RECOVERY:-false}" >>"${MR_TEST_RECOVERY_LOG}"
fi
if [ -n "${MR_TEST_FAIL_ONCE_FILE:-}" ] \
    && [ -f "${MR_TEST_FAIL_ONCE_FILE}" ]; then
  mv "${MR_TEST_FAIL_ONCE_FILE}" "${MR_TEST_FAIL_ONCE_FILE}.used"
  exit 7
fi
outcome=opened
[ "${AUTO_MERGE}" != true ] || outcome=merged
outcome="${MR_TEST_OUTCOME:-${outcome}}"
verified=true
[ "${outcome}" != unknown ] || verified=false
mr_action="${MR_TEST_ACTION:-created}"
printf 'mr:%s:%s:%s\n' "${MERGE_TARGET_BRANCH}" "${AUTO_MERGE}" "${COMMIT_SHA}" >>"${ORDER_LOG}"
jq -cn \
  --argjson iid 7 \
  --arg web_url 'https://gitlab.example.test/group/repo/-/merge_requests/7' \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg dependency_base_sha "${DEPENDENCY_BASE_SHA:-}" \
  --arg sha "${COMMIT_SHA}" \
  --arg observed_state "${outcome}" \
  --arg outcome "${outcome}" \
  --argjson verified "${verified}" \
  --arg mr_action "${mr_action}" \
  --argjson issue_iid "${ISSUE_IID}" \
  --argjson execution_id "${EXECUTION_ID}" \
  --argjson auto_merge "${AUTO_MERGE}" \
  --arg shared_mr_intent_id "${fixed_intent_id}" '{
    version:1,iid:$iid,web_url:$web_url,
    source_branch:$source_branch,target_branch:$target_branch,
    dependency_base_sha:$dependency_base_sha,sha:$sha,
    observed_state:$observed_state,outcome:$outcome,verified:$verified,
    merge_attempted:$auto_merge,merge_api_succeeded:$auto_merge,
    reason:(if $auto_merge then "verified_merged" else "auto_merge_disabled" end),
    mr_action:$mr_action,issue_iid:$issue_iid,
    execution_id:$execution_id,auto_merge:$auto_merge
    }
    | if ($source_branch | test("^issue/[1-9][0-9]*\\+[1-9][0-9]*$"))
      then .shared_mr_intent_id = $shared_mr_intent_id
      else . end
  ' >"${LOG_DIR}/mr_result.json"
chmod 600 "${LOG_DIR}/mr_result.json"
printf '%s\n' 'https://gitlab.example.test/group/repo/-/merge_requests/7' \
  "${mr_action}" 7 "${outcome}"
[ "${MR_TEST_EXIT:-0}" -eq 0 ] || exit "${MR_TEST_EXIT}"
EOF
cat >"${FAKE_SCRIPTS}/summarize_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'summarize:%s\n' "${SUMMARY_POST_TO_ISSUE}" >>"${ORDER_LOG}"
printf '%s\n' 'SUMMARY_POSTED=false' >&2
printf '%s\n' "${ISSUE_ROOT}/summary.md"
EOF
cat >"${FAKE_SCRIPTS}/archive_execution_logs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
parent_commit_sha="${COMMIT_SHA:-0123456789abcdef0123456789abcdef01234567}"
log_commit_sha="${LOG_TEST_SHA:-${parent_commit_sha}}"
if [ "${ARCHIVE_TEST_EXIT:-0}" -ne 0 ]; then
  exit "${ARCHIVE_TEST_EXIT}"
fi
if [ "${log_commit_sha}" != "${parent_commit_sha}" ]; then
  : "${ARCHIVE_ADVANCED_FILE:?}"
  printf '%s\n' "${log_commit_sha}" >"${ARCHIVE_ADVANCED_FILE}"
fi
printf 'LOG_WORK_BRANCH=%s\n' "${WORK_BRANCH}"
printf 'LOG_PARENT_COMMIT=%s\n' "${parent_commit_sha}"
printf 'LOG_COMMIT_SHA=%s\n' "${log_commit_sha}"
EOF
chmod +x "${FAKE_BIN}/timeout" "${FAKE_BIN}/git" "${FAKE_BIN}/stat" \
  "${FAKE_SCRIPTS}"/*.sh

# Invalid ordinary/shared branch identities must fail before env_paths.sh can
# create even the per-Issue runtime tree.  Use a fresh repo path for every
# shape so any bootstrap side effect is directly observable.
while IFS='|' read -r invalid_name invalid_branch; do
  invalid_repo="${TEST_ROOT}/invalid-${invalid_name}/repo"
  set +e
  invalid_output="$({
    PATH="${FAKE_BIN}:${PATH}" \
    ORDER_LOG="${ORDER_LOG}" \
    PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=1 \
    REPO_PATH="${invalid_repo}" ISSUE_MODE=fresh BRANCH=main \
    WORK_BRANCH="${invalid_branch}" ACPX_TIMEOUT_SECONDS=60 \
      bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
  } 2>&1)"
  invalid_rc=$?
  set -e
  [ "${invalid_rc}" -eq 2 ] \
    || fail "invalid ${invalid_name} branch returned ${invalid_rc}: ${invalid_output}"
  [ ! -e "${invalid_repo}" ] \
    || fail "invalid ${invalid_name} branch reached env_paths side effects"
done <<'EOF'
ordinary-other-iid|issue/41
shared-duplicate|issue/42+42
shared-nonmember|issue/9+10
shared-malformed|issue/9+42+77
EOF

expect_dag_rejection() {
  local name="$1" version="$2" plan_sha="$3" work_branch="$4"
  local base_sha="$5" parent_sha="$6" auto_merge="$7"
  local issue_mode="${8:-fresh}"
  local invalid_repo="${TEST_ROOT}/invalid-dag-${name}/repo"
  local invalid_output invalid_rc
  set +e
  invalid_output="$({
    PATH="${FAKE_BIN}:${PATH}" \
    ORDER_LOG="${ORDER_LOG}" \
    PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=1 \
    REPO_PATH="${invalid_repo}" ISSUE_MODE="${issue_mode}" BRANCH=main \
    WORK_BRANCH="${work_branch}" ACPX_TIMEOUT_SECONDS=60 \
    DEPENDENCY_CONTRACT_VERSION="${version}" \
    DEPENDENCY_PLAN_SHA256="${plan_sha}" \
    DEPENDENCY_BASE_SHA="${base_sha}" \
    EXPECTED_COMMIT_PARENT_SHA="${parent_sha}" \
    AUTO_MERGE="${auto_merge}" \
      bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
  } 2>&1)"
  invalid_rc=$?
  set -e
  [ "${invalid_rc}" -eq 2 ] \
    || fail "invalid DAG ${name} returned ${invalid_rc}: ${invalid_output}"
  [ ! -e "${invalid_repo}" ] \
    || fail "invalid DAG ${name} reached env_paths side effects"
}

DAG_BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DAG_INPUT_JSON="$(jq -cn \
  --arg commit_sha "${DAG_BASE_SHA}" '{
    iid:9,
    identity_source:"gitlab_pr_label_branch",
    work_branch:"issue/9",
    commit_sha:$commit_sha,
    work_branch_sha:$commit_sha,
    verified:true
  }')"
DAG_PLAN_CANONICAL="$(jq -cnS \
  --argjson input "${DAG_INPUT_JSON}" \
  --arg aggregate_base_sha "${DAG_BASE_SHA}" '{
    version:2,
    algorithm:"ordered-frontier-merge-v1",
    consumer_iid:42,
    target_branch:"main",
    declared_inputs:[$input],
    effective_inputs:[$input],
    aggregate_base_sha:$aggregate_base_sha
  }')"
DAG_PLAN_SHA="$(sha256_text "${DAG_PLAN_CANONICAL}")"
DAG_WORK_BRANCH="issue/42-dag-${DAG_PLAN_SHA:0:16}"
DAG_PLAN_JSON="$(jq -cnS \
  --argjson input "${DAG_INPUT_JSON}" \
  --arg aggregate_base_sha "${DAG_BASE_SHA}" \
  --arg plan_sha256 "${DAG_PLAN_SHA}" \
  --arg work_branch "${DAG_WORK_BRANCH}" '{
    version:2,
    consumer_iid:42,
    target_branch:"main",
    declared_inputs:[$input],
    effective_inputs:[$input],
    aggregate_base_sha:$aggregate_base_sha,
    plan_sha256:$plan_sha256,
    work_branch:$work_branch
  }')"
expect_dag_rejection plan-without-v2 '' "${DAG_PLAN_SHA}" issue/42 \
  '' '' false
expect_dag_rejection unknown-version 3 "${DAG_PLAN_SHA}" "${DAG_WORK_BRANCH}" \
  "${DAG_BASE_SHA}" "${DAG_BASE_SHA}" false
expect_dag_rejection invalid-plan 2 ABCDEF "${DAG_WORK_BRANCH}" \
  "${DAG_BASE_SHA}" "${DAG_BASE_SHA}" false
expect_dag_rejection branch-plan-mismatch 2 "${DAG_PLAN_SHA}" \
  issue/42-dag-ffffffffffffffff \
  "${DAG_BASE_SHA}" "${DAG_BASE_SHA}" false
expect_dag_rejection missing-base 2 "${DAG_PLAN_SHA}" "${DAG_WORK_BRANCH}" \
  '' "${DAG_BASE_SHA}" false
expect_dag_rejection parent-mismatch 2 "${DAG_PLAN_SHA}" "${DAG_WORK_BRANCH}" \
  "${DAG_BASE_SHA}" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb false
expect_dag_rejection auto-merge 2 "${DAG_PLAN_SHA}" "${DAG_WORK_BRANCH}" \
  "${DAG_BASE_SHA}" "${DAG_BASE_SHA}" true
expect_dag_rejection continue-without-lease 2 "${DAG_PLAN_SHA}" \
  "${DAG_WORK_BRANCH}" "${DAG_BASE_SHA}" "${DAG_BASE_SHA}" false continue

# DAG v2 keeps one branch and MR per consumer while persisting its immutable
# plan identity. It is deliberately not classified as a legacy shared pair.
DAG_REPO_PATH="${TEST_ROOT}/dag/repo"
DAG_ORDER_LOG="${TEST_ROOT}/dag-order.log"
DAG_ISSUE_ROOT="${DAG_REPO_PATH}/.req_executor/issues/issue-42"
mkdir -p "${DAG_ISSUE_ROOT}"
jq -n \
  --argjson execution_id 2 \
  --arg work_branch "${DAG_WORK_BRANCH}" \
  --arg dependency_plan_sha256 "${DAG_PLAN_SHA}" \
  --argjson dependency_plan "${DAG_PLAN_JSON}" \
  --arg dependency_base_sha "${DAG_BASE_SHA}" '{
    latest_execution_id:$execution_id,
    preparing_execution_id:$execution_id,
    proposed_work_branch:$work_branch,
    proposed_branch_members:[42],
    proposed_shared_branch_role:null,
    proposed_expected_work_branch_sha:null,
    proposed_expected_commit_parent_sha:$dependency_base_sha,
    proposed_dependency_iid:9,
    proposed_dependency_branch:"issue/9",
    proposed_dependency_base_sha:$dependency_base_sha,
    proposed_dependency_contract_version:2,
    proposed_dependency_plan_sha256:$dependency_plan_sha256,
    proposed_dependency_plan:$dependency_plan
  }' >"${DAG_ISSUE_ROOT}/state.json"
chmod 600 "${DAG_ISSUE_ROOT}/state.json"
dag_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${DAG_ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=2 \
  REPO_PATH="${DAG_REPO_PATH}" ISSUE_TITLE='DAG consumer' ISSUE_MODE=fresh \
  BRANCH=main WORK_BRANCH="${DAG_WORK_BRANCH}" ACPX_TIMEOUT_SECONDS=60 \
  DEPENDENCY_CONTRACT_VERSION=2 \
  DEPENDENCY_PLAN_SHA256="${DAG_PLAN_SHA}" \
  DEPENDENCY_IID=9 \
  DEPENDENCY_BRANCH=issue/9 \
  DEPENDENCY_BASE_SHA="${DAG_BASE_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${DAG_BASE_SHA}" \
  AUTO_MERGE=false \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "valid DAG v2 wrapper attempt failed"
printf '%s\n' "${dag_output}" | tail -n 1 | jq -e \
  --arg branch "${DAG_WORK_BRANCH}" \
  '.status == "done" and .work_branch == $branch and .mr_action == "created"' \
  >/dev/null || fail "DAG v2 wrapper did not return its independent MR result"
jq -e \
  --arg branch "${DAG_WORK_BRANCH}" \
  --arg plan_sha "${DAG_PLAN_SHA}" \
  --arg base_sha "${DAG_BASE_SHA}" \
  --argjson dependency_plan "${DAG_PLAN_JSON}" '
    .work_branch == $branch
    and .branch_members == [42]
    and .shared_branch_role == null
    and .dependency_contract_version == 2
    and .dependency_plan_sha256 == $plan_sha
    and .dependency_plan == $dependency_plan
    and .latest_execution_id == 2
    and .dependency_iid == 9
    and .dependency_branch == "issue/9"
    and .dependency_base_sha == $base_sha
    and (.commit_sha | type == "string")
    and .commit_sha == .work_branch_sha
    and .dependency_history_verified == true
    and (has("mr_finalization") | not)
  ' "${DAG_REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "DAG v2 push did not persist its frozen non-shared identity"

write_execution_state() {
  local execution_id="$1" auto_merge="$2" target_branch="$3"
  local dependency_iid="${4:-}" dependency_branch="${5:-}"
  local dependency_base_sha="${6:-}"
  local issue_root="${REPO_PATH}/.req_executor/issues/issue-42"
  mkdir -p "${issue_root}/executions"
  jq -n \
    --argjson iid 42 \
    --argjson execution_id "${execution_id}" \
    --arg issue_title '测试 issue' \
    --arg mode_actual fresh \
    --argjson auto_merge "${auto_merge}" \
    --arg merge_target_branch "${target_branch}" \
    --arg dependency_iid "${dependency_iid}" \
    --arg dependency_branch "${dependency_branch}" \
    --arg dependency_base_sha "${dependency_base_sha}" '{
      iid:$iid,execution_id:$execution_id,issue_title:$issue_title,
      mode_actual:$mode_actual,
      auto_merge:$auto_merge,merge_target_branch:$merge_target_branch,
      dependency_iid:(if $dependency_iid == "" then null else ($dependency_iid|tonumber) end),
      dependency_branch:(if $dependency_branch == "" then null else $dependency_branch end),
      dependency_base_sha:(if $dependency_base_sha == "" then null else $dependency_base_sha end)
    }
    | if $dependency_iid == "" then . else . + {
        work_branch:("issue/" + ($iid|tostring)),
        branch_members:[$iid],shared_branch_role:null,
        expected_work_branch_sha:null,expected_commit_parent_sha:null
      } end' >"${issue_root}/executions/execution-${execution_id}.json"
  chmod 600 "${issue_root}/executions/execution-${execution_id}.json"
}

write_execution_state 3 false main
NONSTANDARD_MODE_STATE_FILE="${REPO_PATH}/.req_executor/issues/issue-42/executions/execution-3.json"
chmod 775 "${NONSTANDARD_MODE_STATE_FILE}"
NONAUTHORITATIVE_STATE_TMP="$(mktemp "${NONSTANDARD_MODE_STATE_FILE}.nonauthoritative.XXXXXX")"
jq '.iid = 999
  | .execution_id = 999
  | .auto_merge = true
  | .merge_target_branch = "ignored-by-wrapper"
  | .work_branch = "issue/9+42"
  | .branch_members = [9,42]
  | .shared_branch_role = "tail"' \
  "${NONSTANDARD_MODE_STATE_FILE}" >"${NONAUTHORITATIVE_STATE_TMP}"
mv "${NONAUTHORITATIVE_STATE_TMP}" "${NONSTANDARD_MODE_STATE_FILE}"
chmod 775 "${NONSTANDARD_MODE_STATE_FILE}"
wrapper_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=3 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "all-in-one wrapper failed"

execution_state_mode="$(file_mode "${NONSTANDARD_MODE_STATE_FILE}")"
[ "${execution_state_mode}" = 775 ] \
  || fail "execution-state metadata was unexpectedly normalized"

expected_order='acpx
stage
commit
verify:main
label:remove:doing
label:add:done
mr:main:false:0123456789abcdef0123456789abcdef01234567
label:add:pr
summarize:false'
[ "$(cat "${ORDER_LOG}")" = "${expected_order}" ] \
  || fail "attempt steps did not stay in one deterministic sequence: $(cat "${ORDER_LOG}")"

result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-3/worker_result.json"
[ -f "${result_file}" ] || fail "durable worker_result.json was not written"
result_line="$(printf '%s\n' "${wrapper_output}" | tail -n 1)"
if ! diff -u <(jq -S . <<<"${result_line}") <(jq -S . "${result_file}") >/dev/null; then
  fail "printed compact result differs from durable worker_result.json"
fi
jq -e '
  .iid == 42 and .execution_id == 3 and .status == "done"
  and .commit_sha == "0123456789abcdef0123456789abcdef01234567"
  and .mr_action == "created"
  and .labels_added == ["pr"]
  and .labels_removed == ["doing","done"]
  and .summary_posted == false
  and .block_reason == ""
' "${result_file}" >/dev/null \
  || fail "durable worker result does not match the successful attempt"
jq -e '
  .dependency_iid == null
  and .dependency_branch == null
  and .dependency_base_sha == null
  and .work_branch == "issue/42"
  and .branch_members == [42]
  and .shared_branch_role == null
  and .work_branch_sha == "0123456789abcdef0123456789abcdef01234567"
  and .dependency_history_verified == true
  and .dependency_pinned_execution_id == 3
' "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "successful push did not bind its caller-derived ordinary identity"
jq -e 'has("mr_finalization") | not' \
  "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "ordinary branch unexpectedly wrote a shared MR pending checkpoint"

result_mode="$(file_mode "${result_file}")"
[ "${result_mode}" = 600 ] || fail "worker_result.json mode is ${result_mode}, expected 600"
finalized_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-3/attempt_finalized.json"
[ -f "${finalized_file}" ] && [ ! -L "${finalized_file}" ] \
  || fail "attempt_finalized.json was not written"
finalized_mode="$(file_mode "${finalized_file}")"
[ "${finalized_mode}" = 600 ] \
  || fail "attempt_finalized.json mode is ${finalized_mode}, expected 600"
jq -e \
  --arg result_sha256 "$(sha256_file "${result_file}")" '
  (keys | sort) == ([
    "commit_sha","completed_at_epoch","execution_id","iid",
    "version","work_branch","worker_result_sha256"
  ] | sort)
  and .version == 1
  and .iid == 42
  and .execution_id == 3
  and .work_branch == "issue/42"
  and .commit_sha == "0123456789abcdef0123456789abcdef01234567"
  and .worker_result_sha256 == $result_sha256
  and (.completed_at_epoch | type == "number" and . == floor and . > 0)
' "${finalized_file}" >/dev/null \
  || fail "attempt_finalized.json does not bind the final worker result"

# A real terminal append advances an open MR source branch, but the durable
# result and MR marker retain the reviewed business SHA. State binds both
# identities so downstream dependency aggregation excludes executor logs.
: >"${ORDER_LOG}"
LOG_TEST_SHA=abcdefabcdefabcdefabcdefabcdefabcdefabcd
ARCHIVE_ADVANCED_FILE="${TEST_ROOT}/archive-advanced.sha"
write_execution_state 17 false main
advanced_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
  LOG_TEST_SHA="${LOG_TEST_SHA}" \
  ARCHIVE_ADVANCED_FILE="${ARCHIVE_ADVANCED_FILE}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=17 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='日志子提交' ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "same-branch terminal log promotion failed"
advanced_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-17/worker_result.json"
printf '%s\n' "${advanced_output}" | tail -n 1 | jq -e \
  '.status == "done"
    and .commit_sha == "0123456789abcdef0123456789abcdef01234567"' \
  >/dev/null || fail "printed result did not retain the business commit"
jq -e '.commit_sha == "0123456789abcdef0123456789abcdef01234567"' \
  "${advanced_result_file}" >/dev/null \
  || fail "durable result did not retain the business commit"
jq -e --arg sha "${LOG_TEST_SHA}" \
  '.commit_sha == "0123456789abcdef0123456789abcdef01234567"
    and .work_branch_sha == $sha
    and .dependency_pinned_execution_id == 17' \
  "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "Issue state did not separate business and terminal-log commits"
jq -e '.sha == "0123456789abcdef0123456789abcdef01234567"' \
  "${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-17/mr_result.json" \
  >/dev/null || fail "MR marker did not retain the business commit"

# NO_CHANGES still means no business MR, but its complete terminal evidence
# must create/advance issue/42 instead of disappearing with an empty index.
: >"${ORDER_LOG}"
NO_CHANGE_LOG_SHA=cdefabcdefabcdefabcdefabcdefabcdefabcdef
NO_CHANGE_ARCHIVE_FILE="${TEST_ROOT}/no-change-archive-advanced.sha"
write_execution_state 18 false main
no_change_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
  STAGE_TEST_MARKER=NO_CHANGES LOG_TEST_SHA="${NO_CHANGE_LOG_SHA}" \
  ARCHIVE_ADVANCED_FILE="${NO_CHANGE_ARCHIVE_FILE}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=18 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='无代码改动' ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "NO_CHANGES terminal evidence was not persisted"
printf '%s\n' "${no_change_output}" | tail -n 1 | jq -e \
  --arg sha "${NO_CHANGE_LOG_SHA}" '
  .status == "blocked" and .commit_sha == $sha
  and (.block_reason | contains("no staged changes"))
' >/dev/null || fail "NO_CHANGES result did not report its log-only Issue commit"
jq -e --arg sha "${NO_CHANGE_LOG_SHA}" \
  '.work_branch_sha == $sha and .dependency_pinned_execution_id == 18' \
  "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "NO_CHANGES log-only Issue branch identity was not persisted"
no_change_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-18/worker_result.json"
no_change_finalized_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-18/attempt_finalized.json"
jq -e \
  --arg commit_sha "${NO_CHANGE_LOG_SHA}" \
  --arg result_sha256 "$(sha256_file "${no_change_result_file}")" '
  .iid == 42 and .execution_id == 18 and .work_branch == "issue/42"
  and .commit_sha == $commit_sha
  and .worker_result_sha256 == $result_sha256
' "${no_change_finalized_file}" >/dev/null \
  || fail "blocked NO_CHANGES path did not publish its finalization marker last"

# A persistence failure leaves worker_result.json as non-authoritative evidence:
# the final latch must not appear until terminal archive and state writes finish.
write_execution_state 19 false main
set +e
PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" ARCHIVE_TEST_EXIT=7 \
PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=19 \
REPO_PATH="${REPO_PATH}" ISSUE_TITLE='归档失败' ISSUE_MODE=fresh \
BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
  bash "${FAKE_SCRIPTS}/run_executor_attempt.sh" >/dev/null 2>&1
archive_failure_rc=$?
set -e
[ "${archive_failure_rc}" -eq 4 ] \
  || fail "archive failure returned ${archive_failure_rc}, expected 4"
[ ! -e "${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-19/attempt_finalized.json" ] \
  || fail "archive failure published attempt_finalized.json"

# Auto-merge uses MERGE_TARGET_BRANCH for verification/MR creation and writes
# finish only when the exact durable marker says the MR is verified merged.
: >"${ORDER_LOG}"
write_execution_state 4 true release
merged_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=4 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=true ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "verified merged wrapper run failed"

expected_merged_order='acpx
stage
commit
verify:release
label:remove:doing
label:add:done
mr:release:true:0123456789abcdef0123456789abcdef01234567
label:add:finish
summarize:false'
[ "$(cat "${ORDER_LOG}")" = "${expected_merged_order}" ] \
  || fail "verified merged order/target is wrong: $(cat "${ORDER_LOG}")"

merged_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-4/worker_result.json"
merged_line="$(printf '%s\n' "${merged_output}" | tail -n 1)"
diff -u <(jq -S . <<<"${merged_line}") <(jq -S . "${merged_result_file}") >/dev/null \
  || fail "verified merged compact result was not durable"
jq -e '
  .status == "done"
  and .merge_request_url == "https://gitlab.example.test/group/repo/-/merge_requests/7"
  and .mr_action == "created"
  and .labels_added == ["finish"]
  and .labels_removed == ["doing","done"]
  and .block_reason == ""
  and (keys | sort) == ([
    "execution_id","block_reason","commit_sha","iid","labels_added",
    "labels_removed","local_branch","log_dir","merge_request_url",
    "mode_actual","mr_action","status","summary_posted","wiki_url",
    "work_branch"
  ] | sort)
' "${merged_result_file}" >/dev/null \
  || fail "verified merged result changed the strict schema or terminal label"

# A merge helper crash or unknown server state after MR creation is not a CC
# execution failure.  The durable exact IID keeps the ordinary PR path
# recoverable and must not introduce blocked-cc or finish.
: >"${ORDER_LOG}"
write_execution_state 5 true release
unknown_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" MR_TEST_OUTCOME=unknown MR_TEST_EXIT=86 \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=5 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=true ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "unknown merge state incorrectly failed the executor wrapper"
unknown_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-5/worker_result.json"
jq -e '
  .status == "done"
  and .labels_added == ["pr"]
  and .labels_removed == ["doing","done"]
  and .block_reason == ""
' "${unknown_result_file}" >/dev/null \
  || fail "unknown merge state did not conservatively preserve pr"
if grep -Fq 'label:add:finish' "${ORDER_LOG}" \
    || grep -Fq 'label:add:blocked-cc' "${ORDER_LOG}"; then
  fail "unknown merge state was mislabeled finish or blocked-cc"
fi
printf '%s\n' "${unknown_output}" | tail -n 1 | jq -e '.status == "done"' >/dev/null \
  || fail "unknown merge state did not print its conservative durable result"
grep -Fxq 'summarize:false' "${ORDER_LOG}" \
  || fail "unverified automatic merge published a premature success summary"

# Once an exact MR exists, a transient terminal-label write failure remains a
# recoverable done result.  It must preserve the pre-MR `done` label and must
# not erase the verified MR identity by transitioning to blocked-cc.
: >"${ORDER_LOG}"
write_execution_state 6 true release
label_failure_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" LABEL_TEST_FAIL_ADD=finish \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=6 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=true ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "terminal label failure incorrectly failed the executor wrapper"
label_failure_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-6/worker_result.json"
jq -e '
  .status == "done"
  and .merge_request_url == "https://gitlab.example.test/group/repo/-/merge_requests/7"
  and .labels_added == ["done"]
  and .labels_removed == ["doing"]
  and (.block_reason | contains("add finish label failed after MR finalization"))
' "${label_failure_result_file}" >/dev/null \
  || fail "terminal label failure was not preserved as a recoverable done result"
if grep -Fq 'label:add:blocked-cc' "${ORDER_LOG}"; then
  fail "terminal label failure was incorrectly converted to blocked-cc"
fi
printf '%s\n' "${label_failure_output}" | tail -n 1 | jq -e '.status == "done"' >/dev/null \
  || fail "terminal label failure did not print its recoverable durable result"

# A non-auto request remains the ordinary PR path even if a reviewer merges the
# MR before the wrapper reads the marker. Server state alone must not opt the
# request into the automatic `finish` workflow.
: >"${ORDER_LOG}"
write_execution_state 7 false release
ordinary_merged_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" MR_TEST_OUTCOME=merged \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=7 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=false ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "ordinary rapidly-merged wrapper run failed"
ordinary_merged_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-7/worker_result.json"
jq -e '
  .status == "done"
  and .labels_added == ["pr"]
  and .labels_removed == ["doing","done"]
' "${ordinary_merged_result_file}" >/dev/null \
  || fail "ordinary rapidly-merged MR was incorrectly opted into finish"
if grep -Fq 'label:add:finish' "${ORDER_LOG}"; then
  fail "ordinary rapidly-merged MR received finish"
fi
grep -Fxq 'summarize:false' "${ORDER_LOG}" \
  || fail "ordinary successful MR path attempted to post its summary"
printf '%s\n' "${ordinary_merged_output}" | tail -n 1 | jq -e '.status == "done"' >/dev/null \
  || fail "ordinary rapidly-merged wrapper result is invalid"

# Execution state is context only: caller-provided branch, dependency, and
# merge intent are not rejected when they differ from the persisted record.
DEPENDENCY_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_execution_state 8 false main 9 issue/9 "${DEPENDENCY_SHA}"
: >"${ORDER_LOG}"
STATE_TITLE_CAPTURE="${TEST_ROOT}/state-title.txt"
state_dependency_ignored_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" COMMIT_TITLE_CAPTURE_FILE="${STATE_TITLE_CAPTURE}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=8 \
  REPO_PATH="${REPO_PATH}" ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "persisted dependency unexpectedly rejected caller inputs"
printf '%s\n' "${state_dependency_ignored_output}" | tail -n 1 \
  | jq -e '.status == "done"' >/dev/null \
  || fail "caller inputs differing from persisted dependency did not run"
jq -e '.dependency_base_sha == ""' \
  "${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-8/mr_result.json" \
  >/dev/null || fail "persisted dependency overrode caller inputs"
[ "$(cat "${STATE_TITLE_CAPTURE}")" = '测试 issue' ] \
  || fail "execution state did not supply its optional issue title"

write_execution_state 13 false main
: >"${ORDER_LOG}"
caller_dependency_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=13 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9 \
  DEPENDENCY_BASE_SHA="${DEPENDENCY_SHA}" \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "caller dependency differing from persisted context was rejected"
printf '%s\n' "${caller_dependency_output}" | tail -n 1 \
  | jq -e '.status == "done"' >/dev/null \
  || fail "caller dependency run did not produce a successful compact result"
jq -e --arg dependency_sha "${DEPENDENCY_SHA}" \
  '.dependency_base_sha == $dependency_sha' \
  "${REPO_PATH}/worktree/.req_executor/issue-42/log/execution-13/mr_result.json" \
  >/dev/null || fail "dependency SHA did not reach MR finalization"

# A malformed execution file is ignored as optional context.  The wrapper
# falls back to the deterministic title and still derives ordinary membership
# from WORK_BRANCH even when stale identity variables are also present.
BROKEN_ORDINARY_STATE_FILE="${REPO_PATH}/.req_executor/issues/issue-42/executions/execution-14.json"
printf '%s\n' '{"issue_title":' >"${BROKEN_ORDINARY_STATE_FILE}"
chmod 600 "${BROKEN_ORDINARY_STATE_FILE}"
BROKEN_TITLE_CAPTURE="${TEST_ROOT}/broken-ordinary-title.txt"
: >"${ORDER_LOG}"
broken_ordinary_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" COMMIT_TITLE_CAPTURE_FILE="${BROKEN_TITLE_CAPTURE}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=14 \
  REPO_PATH="${REPO_PATH}" ISSUE_MODE=fresh BRANCH=main \
  BRANCH_MEMBERS_JSON='[9,42]' SHARED_BRANCH_ROLE=tail \
  ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "malformed ordinary execution context rejected the caller identity"
printf '%s\n' "${broken_ordinary_output}" | tail -n 1 \
  | jq -e '.status == "done" and .work_branch == "issue/42"' >/dev/null \
  || fail "malformed ordinary execution context changed the result identity"
[ "$(cat "${BROKEN_TITLE_CAPTURE}")" = 'Issue #42' ] \
  || fail "malformed execution context did not use the fallback title"
jq -e '
  .work_branch == "issue/42"
  and .branch_members == [42]
  and .shared_branch_role == null
' "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "malformed execution context or stale variables changed ordinary membership"

SHARED_A_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHARED_ISSUE_ROOT="${REPO_PATH}/.req_executor/issues/issue-42"
write_shared_tail_state() {
  local execution_id="$1" expected_sha="$2" include_dependency="$3"
  jq -n \
    --argjson iid 42 \
    --argjson execution_id "${execution_id}" \
    --arg issue_title '共享尾节点' \
    --arg expected_sha "${expected_sha}" \
    --argjson include_dependency "${include_dependency}" \
    --arg dependency_sha "${SHARED_A_SHA}" '{
      iid:$iid,execution_id:$execution_id,issue_title:$issue_title,
      mode_actual:"fresh",auto_merge:false,merge_target_branch:"main",
      work_branch:"issue/9+42",branch_members:[9,42],shared_branch_role:"tail",
      expected_work_branch_sha:$expected_sha,
      expected_commit_parent_sha:$dependency_sha,
      dependency_iid:(if $include_dependency then 9 else null end),
      dependency_branch:(if $include_dependency then "issue/9+42" else null end),
      dependency_base_sha:(if $include_dependency then $dependency_sha else null end)
    }' >"${SHARED_ISSUE_ROOT}/executions/execution-${execution_id}.json"
  chmod 600 "${SHARED_ISSUE_ROOT}/executions/execution-${execution_id}.json"
}

# A failed inner run must keep partial shared work local. Publishing it would
# lock the canonical two-Issue branch because A cannot take an ordinary retry.
: >"${ORDER_LOG}"
write_shared_tail_state 15 "${SHARED_A_SHA}" true
printf '%s\n' '{"branch_members":' \
  >"${SHARED_ISSUE_ROOT}/executions/execution-15.json"
chmod 600 "${SHARED_ISSUE_ROOT}/executions/execution-15.json"
partial_shared_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" ACPX_TEST_EXIT=1 \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=15 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='共享尾节点部分结果' ISSUE_MODE=fresh \
  BRANCH='issue/9+42' MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/9+42' \
  EXPECTED_WORK_BRANCH_SHA="${SHARED_A_SHA}" ACPX_TIMEOUT_SECONDS=60 \
  EXPECTED_COMMIT_PARENT_SHA="${SHARED_A_SHA}" \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9+42 \
  DEPENDENCY_BASE_SHA="${SHARED_A_SHA}" \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "shared partial-work salvage wrapper failed"
printf '%s\n' "${partial_shared_output}" | tail -n 1 \
  | jq -e '
      .status == "blocked"
      and .labels_added == ["blocked-cc"]
      and .labels_removed == ["doing"]
    ' >/dev/null \
  || fail "shared partial-work salvage did not remain blocked"
jq -e 'has("mr_finalization") | not' \
  "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "shared partial-work salvage wrote an MR pending checkpoint"
if grep -Eq '^(commit|verify:|mr-pending-checkpoint|mr:)' "${ORDER_LOG}" \
    || grep -Fq 'mr:' "${ORDER_LOG}"; then
  fail "shared partial-work failure published code or reached MR finalization"
fi
grep -Fxq 'label:add:blocked-cc' "${ORDER_LOG}" \
  || fail "blocked failure did not use one atomic terminal-label transition"
if grep -Fq 'label:remove:doing' "${ORDER_LOG}"; then
  fail "blocked failure still used an interruptible two-call label transition"
fi

: >"${ORDER_LOG}"
write_shared_tail_state 11 "${SHARED_A_SHA}" true
FORGED_SHARED_STATE_FILE="${SHARED_ISSUE_ROOT}/executions/execution-11.json"
FORGED_SHARED_STATE_TMP="$(mktemp "${FORGED_SHARED_STATE_FILE}.forged.XXXXXX")"
jq '
  .work_branch = "issue/77+42"
  | .branch_members = [77,42]
  | .shared_branch_role = "head"
' "${FORGED_SHARED_STATE_FILE}" >"${FORGED_SHARED_STATE_TMP}"
mv "${FORGED_SHARED_STATE_TMP}" "${FORGED_SHARED_STATE_FILE}"
chmod 600 "${FORGED_SHARED_STATE_FILE}"
mkdir -p "${REPO_PATH}/.req_executor/issues/issue-9"
jq -n --arg sha "${SHARED_A_SHA}" '{
  iid:9,status:"done",latest_execution_id:1,
  dependency_pinned_execution_id:1,
  work_branch:"issue/9+42",branch_members:[9,42],shared_branch_role:"head",
  commit_sha:$sha,work_branch_sha:$sha,dependency_history_verified:true,
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
  merge_request_url:"https://gitlab.example.test/group/repo/-/merge_requests/7",
  mr_finalization:{
    status:"verified_open",source_execution_id:1,
    work_branch:"issue/9+42",branch_members:[9,42],shared_branch_role:"head",
    commit_sha:$sha,
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main",iid:7,
    web_url:"https://gitlab.example.test/group/repo/-/merge_requests/7",
    mr_action:"created",verified_at:"2026-07-19T00:00:00Z"
  }
}' >"${REPO_PATH}/.req_executor/issues/issue-9/state.json"
chmod 600 "${REPO_PATH}/.req_executor/issues/issue-9/state.json"
MR_RETRY_SENTINEL="${TEST_ROOT}/shared-mr-fail-once"
MR_RECOVERY_LOG="${TEST_ROOT}/shared-mr-recovery.log"
SHARED_LOG_SHA=bcdefabcdefabcdefabcdefabcdefabcdefabcde
SHARED_ARCHIVE_ADVANCED_FILE="${TEST_ROOT}/shared-archive-advanced.sha"
: >"${MR_RETRY_SENTINEL}"
: >"${MR_RECOVERY_LOG}"
valid_shared_tail_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" MR_TEST_ACTION=reused \
  MR_TEST_FAIL_ONCE_FILE="${MR_RETRY_SENTINEL}" \
  MR_TEST_RECOVERY_LOG="${MR_RECOVERY_LOG}" \
  LOG_TEST_SHA="${SHARED_LOG_SHA}" \
  ARCHIVE_ADVANCED_FILE="${SHARED_ARCHIVE_ADVANCED_FILE}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=11 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='共享尾节点' ISSUE_MODE=fresh \
  BRANCH='issue/9+42' MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/9+42' \
  EXPECTED_WORK_BRANCH_SHA="${SHARED_A_SHA}" ACPX_TIMEOUT_SECONDS=60 \
  EXPECTED_COMMIT_PARENT_SHA="${SHARED_A_SHA}" \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9+42 \
  DEPENDENCY_BASE_SHA="${SHARED_A_SHA}" \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "valid shared tail identity was rejected"
[ "$(cat "${MR_RECOVERY_LOG}")" = $'false\ntrue' ] \
  || fail "shared MR retry did not switch to the MR-only recovery mode"
[ "$(grep -c '^commit$' "${ORDER_LOG}")" -eq 1 ] \
  || fail "shared MR retry reran commit/push"
printf '%s\n' "${valid_shared_tail_output}" | tail -n 1 | jq -e '
  .status == "done" and .work_branch == "issue/9+42"
  and .local_branch == "issue/42" and .mr_action == "reused"
  and .commit_sha == "bcdefabcdefabcdefabcdefabcdefabcdefabcde"
' >/dev/null || fail "shared tail did not persist the reused MR/log result"
jq -e --arg sha "${SHARED_A_SHA}" --arg log_sha "${SHARED_LOG_SHA}" '
  .work_branch == "issue/9+42" and .branch_members == [9,42]
  and .shared_branch_role == "tail"
  and .dependency_iid == 9 and .dependency_branch == "issue/9+42"
  and .dependency_base_sha == $sha
  and .work_branch_sha == $log_sha
  and .dependency_history_verified == true
  and .mr_finalization == {
    status:"pending",source_execution_id:11,
    work_branch:"issue/9+42",branch_members:[9,42],
    shared_branch_role:"tail",
    commit_sha:$log_sha,
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main"
  }
' "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "shared tail did not preserve its fixed dependency identity"

# If the bounded commit helper reports failure after the server accepted the
# shared push, the outer wrapper independently proves local HEAD topology and
# the exact fetched remote ref before continuing to MR-only finalization.
: >"${ORDER_LOG}"
write_shared_tail_state 16 "${SHARED_A_SHA}" true
ambiguous_shared_output="$({
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
  COMMIT_TEST_EXIT=73 MR_TEST_ACTION=reused \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=16 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='共享尾节点模糊推送' ISSUE_MODE=fresh \
  BRANCH='issue/9+42' MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/9+42' \
  EXPECTED_WORK_BRANCH_SHA="${SHARED_A_SHA}" ACPX_TIMEOUT_SECONDS=60 \
  EXPECTED_COMMIT_PARENT_SHA="${SHARED_A_SHA}" \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9+42 \
  DEPENDENCY_BASE_SHA="${SHARED_A_SHA}" \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
} 2>"${TEST_ROOT}/ambiguous-shared.stderr")" \
  || fail "outer wrapper did not recover an accepted ambiguous shared push"
printf '%s\n' "${ambiguous_shared_output}" | tail -n 1 | jq -e '
  .status == "done"
  and .commit_sha == "0123456789abcdef0123456789abcdef01234567"
  and .mr_action == "reused"
' >/dev/null || fail "accepted ambiguous shared push did not reach MR finalization"
[ "$(grep -c '^commit$' "${ORDER_LOG}")" -eq 1 ] \
  || fail "ambiguous shared push recovery reran commit"
[ "$(grep -c '^verify:main$' "${ORDER_LOG}")" -eq 2 ] \
  || fail "ambiguous shared push was not independently fetched and reverified"

echo "ok all-in-one executor attempt persists its exact compact result"
