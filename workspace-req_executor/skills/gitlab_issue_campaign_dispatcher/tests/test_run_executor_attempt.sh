#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/run_executor_attempt.sh"

fail() {
  echo "test_run_executor_attempt.sh: $*" >&2
  exit 1
}

[ -x "${WRAPPER}" ] || fail "run_executor_attempt.sh is missing or not executable"

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
: "${PROJECT:?}" "${GROUP:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER:?}" "${REPO_PATH:?}"
printf -v ATTEMPT_NUMBER_PADDED '%03d' "${ATTEMPT_NUMBER}"
export WORKTREE_DIR="${REPO_PATH}/worktree"
export OUTPUT_DIR="${WORKTREE_DIR}/.req_executor/issue-${ISSUE_IID}/output"
export LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-${ISSUE_IID}/log/attempt-${ATTEMPT_NUMBER_PADDED}"
export ISSUE_ROOT="${REPO_PATH}/.req_executor/issues/issue-${ISSUE_IID}"
export ISSUES_ROOT="${REPO_PATH}/.req_executor/issues"
export ATTEMPT_STATE_FILE="${ISSUE_ROOT}/attempt_state.json"
export ISSUE_STATE_FILE="${ISSUE_ROOT}/state.json"
export WORK_BRANCH="${WORK_BRANCH:-issue/${ISSUE_IID}}"
export LOCAL_ATTEMPT_BRANCH="issue/${ISSUE_IID}-att${ATTEMPT_NUMBER_PADDED}"
mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}" "${ISSUE_ROOT}"
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
  *' rev-parse --verify '*)
    printf '%s\n' 0123456789abcdef0123456789abcdef01234567
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
printf '%s\n' STAGED_OK
EOF
cat >"${FAKE_SCRIPTS}/commit_and_push.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' commit >>"${ORDER_LOG}"
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
if [[ "${WORK_BRANCH}" == issue/*+* ]]; then
  fixed_branch_members="$(jq -c '.branch_members' "${ATTEMPT_STATE_FILE}")"
  fixed_shared_role="$(jq -r '.shared_branch_role' "${ATTEMPT_STATE_FILE}")"
  fixed_intent_id="$(jq -r '.mr_finalization.intent_id' "${ISSUE_STATE_FILE}")"
  jq -e \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg work_branch "${WORK_BRANCH}" \
    --argjson branch_members "${fixed_branch_members}" \
    --arg shared_branch_role "${fixed_shared_role}" \
    --arg commit_sha "${COMMIT_SHA}" \
    --arg intent_id "${fixed_intent_id}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" '
      .mr_finalization == {
        status:"pending",
        source_attempt_number:$attempt_number,
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
  --argjson attempt_number "${ATTEMPT_NUMBER}" \
  --argjson auto_merge "${AUTO_MERGE}" \
  --arg shared_mr_intent_id "${fixed_intent_id}" '{
    version:1,iid:$iid,web_url:$web_url,
    source_branch:$source_branch,target_branch:$target_branch,
    dependency_base_sha:$dependency_base_sha,sha:$sha,
    observed_state:$observed_state,outcome:$outcome,verified:$verified,
    merge_attempted:$auto_merge,merge_api_succeeded:$auto_merge,
    reason:(if $auto_merge then "verified_merged" else "auto_merge_disabled" end),
    mr_action:$mr_action,issue_iid:$issue_iid,
    attempt_number:$attempt_number,auto_merge:$auto_merge
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
printf '%s\n' 'SUMMARY_POSTED=true' >&2
printf '%s\n' "${ISSUE_ROOT}/summary.md"
EOF
chmod +x "${FAKE_BIN}/timeout" "${FAKE_BIN}/git" "${FAKE_SCRIPTS}"/*.sh

write_attempt_state() {
  local attempt_number="$1" auto_merge="$2" target_branch="$3"
  local dependency_iid="${4:-}" dependency_branch="${5:-}"
  local dependency_base_sha="${6:-}"
  local issue_root="${REPO_PATH}/.req_executor/issues/issue-42"
  mkdir -p "${issue_root}"
  jq -n \
    --argjson iid 42 \
    --argjson attempt_number "${attempt_number}" \
    --arg issue_title '测试 issue' \
    --arg mode_actual fresh \
    --argjson auto_merge "${auto_merge}" \
    --arg merge_target_branch "${target_branch}" \
    --arg dependency_iid "${dependency_iid}" \
    --arg dependency_branch "${dependency_branch}" \
    --arg dependency_base_sha "${dependency_base_sha}" '{
      iid:$iid,attempt_number:$attempt_number,issue_title:$issue_title,
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
      } end' >"${issue_root}/attempt_state.json"
  chmod 600 "${issue_root}/attempt_state.json"
}

write_attempt_state 3 false main
wrapper_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=3 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "all-in-one wrapper failed"

expected_order='acpx
stage
commit
verify:main
label:remove:doing
label:add:done
mr:main:false:0123456789abcdef0123456789abcdef01234567
label:add:pr
summarize:true'
[ "$(cat "${ORDER_LOG}")" = "${expected_order}" ] \
  || fail "attempt steps did not stay in one deterministic sequence: $(cat "${ORDER_LOG}")"

result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/attempt-003/worker_result.json"
[ -f "${result_file}" ] || fail "durable worker_result.json was not written"
result_line="$(printf '%s\n' "${wrapper_output}" | tail -n 1)"
if ! diff -u <(jq -S . <<<"${result_line}") <(jq -S . "${result_file}") >/dev/null; then
  fail "printed compact result differs from durable worker_result.json"
fi
jq -e '
  .iid == 42 and .attempt_number == 3 and .status == "done"
  and .commit_sha == "0123456789abcdef0123456789abcdef01234567"
  and .mr_action == "created"
  and .labels_added == ["pr"]
  and .labels_removed == ["doing","done"]
  and .summary_posted == true
  and .block_reason == ""
' "${result_file}" >/dev/null \
  || fail "durable worker result does not match the successful attempt"
jq -e '
  .dependency_iid == null
  and .dependency_branch == null
  and .dependency_base_sha == null
  and .work_branch_sha == "0123456789abcdef0123456789abcdef01234567"
  and .dependency_history_verified == true
  and .dependency_pinned_attempt_number == 3
' "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "successful push did not bind durable dependency history to its remote SHA"
jq -e 'has("mr_finalization") | not' \
  "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "ordinary branch unexpectedly wrote a shared MR pending checkpoint"

if result_mode="$(stat -f '%Lp' "${result_file}" 2>/dev/null)"; then
  :
else
  result_mode="$(stat -c '%a' "${result_file}")"
fi
[ "${result_mode}" = 600 ] || fail "worker_result.json mode is ${result_mode}, expected 600"

# Auto-merge uses MERGE_TARGET_BRANCH for verification/MR creation and writes
# finish only when the exact durable marker says the MR is verified merged.
: >"${ORDER_LOG}"
write_attempt_state 4 true release
merged_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=4 \
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
summarize:true'
[ "$(cat "${ORDER_LOG}")" = "${expected_merged_order}" ] \
  || fail "verified merged order/target is wrong: $(cat "${ORDER_LOG}")"

merged_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/attempt-004/worker_result.json"
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
    "attempt_number","block_reason","commit_sha","iid","labels_added",
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
write_attempt_state 5 true release
unknown_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" MR_TEST_OUTCOME=unknown MR_TEST_EXIT=86 \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=5 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=true ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "unknown merge state incorrectly failed the executor wrapper"
unknown_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/attempt-005/worker_result.json"
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
write_attempt_state 6 true release
label_failure_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" LABEL_TEST_FAIL_ADD=finish \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=6 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=true ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "terminal label failure incorrectly failed the executor wrapper"
label_failure_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/attempt-006/worker_result.json"
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
write_attempt_state 7 false release
ordinary_merged_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" MR_TEST_OUTCOME=merged \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=7 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main MERGE_TARGET_BRANCH=release AUTO_MERGE=false ACPX_TIMEOUT_SECONDS=60 \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "ordinary rapidly-merged wrapper run failed"
ordinary_merged_result_file="${REPO_PATH}/worktree/.req_executor/issue-42/log/attempt-007/worker_result.json"
jq -e '
  .status == "done"
  and .labels_added == ["pr"]
  and .labels_removed == ["doing","done"]
' "${ordinary_merged_result_file}" >/dev/null \
  || fail "ordinary rapidly-merged MR was incorrectly opted into finish"
if grep -Fq 'label:add:finish' "${ORDER_LOG}"; then
  fail "ordinary rapidly-merged MR received finish"
fi
grep -Fxq 'summarize:true' "${ORDER_LOG}" \
  || fail "ordinary successful MR path unexpectedly suppressed its summary"
printf '%s\n' "${ordinary_merged_output}" | tail -n 1 | jq -e '.status == "done"' >/dev/null \
  || fail "ordinary rapidly-merged wrapper result is invalid"

# The outer model may not omit or replace a dependency tuple. The fixed
# attempt-local identity is authoritative, and an exact tuple still runs.
DEPENDENCY_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_attempt_state 8 false main 9 issue/9 "${DEPENDENCY_SHA}"
set +e
PATH="${FAKE_BIN}:${PATH}" \
ORDER_LOG="${ORDER_LOG}" \
PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=8 \
REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
  bash "${FAKE_SCRIPTS}/run_executor_attempt.sh" >/dev/null 2>&1
missing_dependency_rc=$?
set -e
[ "${missing_dependency_rc}" -ne 0 ] \
  || fail "omitted dependency tuple bypassed the fixed attempt identity"

: >"${ORDER_LOG}"
exact_dependency_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=8 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='测试 issue' ISSUE_MODE=fresh \
  BRANCH=main ACPX_TIMEOUT_SECONDS=60 \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9 \
  DEPENDENCY_BASE_SHA="${DEPENDENCY_SHA}" \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "exact fixed dependency tuple was rejected"
printf '%s\n' "${exact_dependency_output}" | tail -n 1 \
  | jq -e '.status == "done"' >/dev/null \
  || fail "exact dependency run did not produce a successful compact result"
jq -e --arg dependency_sha "${DEPENDENCY_SHA}" \
  '.dependency_base_sha == $dependency_sha' \
  "${REPO_PATH}/worktree/.req_executor/issue-42/log/attempt-008/mr_result.json" \
  >/dev/null || fail "dependency SHA did not reach MR finalization"

# Legacy ordinary-state completion is allowed only when the entire dependency
# tuple is absent. A state carrying dependency authority but no work-branch
# identity must fail closed instead of being silently backfilled as issue/<iid>.
write_attempt_state 13 false main 9 issue/9 "${DEPENDENCY_SHA}"
MISSING_WORK_IDENTITY_TMP="$(mktemp "${SHARED_ISSUE_ROOT:-${REPO_PATH}/.req_executor/issues/issue-42}/attempt.missing-work.XXXXXX")"
jq 'del(.work_branch,.branch_members,.shared_branch_role,
  .expected_work_branch_sha,.expected_commit_parent_sha)' \
  "${REPO_PATH}/.req_executor/issues/issue-42/attempt_state.json" \
  >"${MISSING_WORK_IDENTITY_TMP}"
mv "${MISSING_WORK_IDENTITY_TMP}" \
  "${REPO_PATH}/.req_executor/issues/issue-42/attempt_state.json"
chmod 600 "${REPO_PATH}/.req_executor/issues/issue-42/attempt_state.json"
: >"${ORDER_LOG}"
set +e
PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=13 \
  REPO_PATH="${REPO_PATH}" ISSUE_MODE=fresh BRANCH=main \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9 \
  DEPENDENCY_BASE_SHA="${DEPENDENCY_SHA}" ACPX_TIMEOUT_SECONDS=60 \
  bash "${FAKE_SCRIPTS}/run_executor_attempt.sh" >/dev/null 2>&1
missing_work_identity_rc=$?
set -e
[ "${missing_work_identity_rc}" -ne 0 ] \
  || fail "dependency tuple without a fixed work branch used legacy backfill"
[ ! -s "${ORDER_LOG}" ] \
  || fail "dependency tuple without a work branch reached executor side effects"

# A shared tail is never dependency-free. Reject a missing tuple and a fresh
# lease that differs from A's pinned SHA before acpx, Git, or labels can run.
SHARED_A_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHARED_OTHER_SHA=cccccccccccccccccccccccccccccccccccccccc
SHARED_ISSUE_ROOT="${REPO_PATH}/.req_executor/issues/issue-42"
write_shared_tail_state() {
  local attempt_number="$1" expected_sha="$2" include_dependency="$3"
  jq -n \
    --argjson iid 42 \
    --argjson attempt_number "${attempt_number}" \
    --arg issue_title '共享尾节点' \
    --arg expected_sha "${expected_sha}" \
    --argjson include_dependency "${include_dependency}" \
    --arg dependency_sha "${SHARED_A_SHA}" '{
      iid:$iid,attempt_number:$attempt_number,issue_title:$issue_title,
      mode_actual:"fresh",auto_merge:false,merge_target_branch:"main",
      work_branch:"issue/9+42",branch_members:[9,42],shared_branch_role:"tail",
      expected_work_branch_sha:$expected_sha,
      expected_commit_parent_sha:$dependency_sha,
      dependency_iid:(if $include_dependency then 9 else null end),
      dependency_branch:(if $include_dependency then "issue/9+42" else null end),
      dependency_base_sha:(if $include_dependency then $dependency_sha else null end)
    }' >"${SHARED_ISSUE_ROOT}/attempt_state.json"
  chmod 600 "${SHARED_ISSUE_ROOT}/attempt_state.json"
}

assert_shared_identity_rejected() {
  local label="$1" attempt_number="$2" expected_sha="$3"
  shift 3
  : >"${ORDER_LOG}"
  set +e
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
    PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER="${attempt_number}" \
    REPO_PATH="${REPO_PATH}" ISSUE_TITLE='共享尾节点' ISSUE_MODE=fresh \
    BRANCH='issue/9+42' MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/9+42' \
    EXPECTED_WORK_BRANCH_SHA="${expected_sha}" ACPX_TIMEOUT_SECONDS=60 \
    EXPECTED_COMMIT_PARENT_SHA="${SHARED_A_SHA}" \
    "$@" bash "${FAKE_SCRIPTS}/run_executor_attempt.sh" >/dev/null 2>&1
  shared_identity_rc=$?
  set -e
  [ "${shared_identity_rc}" -ne 0 ] \
    || fail "${label} bypassed the fixed shared identity"
  [ ! -s "${ORDER_LOG}" ] \
    || fail "${label} reached executor side effects before rejection"
}

write_shared_tail_state 9 "${SHARED_A_SHA}" false
assert_shared_identity_rejected missing_shared_tail_dependency 9 "${SHARED_A_SHA}"

write_shared_tail_state 10 "${SHARED_OTHER_SHA}" true
assert_shared_identity_rejected mismatched_shared_tail_lease 10 \
  "${SHARED_OTHER_SHA}" \
  env DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9+42 \
    DEPENDENCY_BASE_SHA="${SHARED_A_SHA}"

# A failed inner run must keep partial shared work local. Publishing it would
# lock the canonical two-Issue branch because A cannot take an ordinary retry.
: >"${ORDER_LOG}"
write_shared_tail_state 15 "${SHARED_A_SHA}" true
partial_shared_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" ACPX_TEST_EXIT=1 \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=15 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='共享尾节点部分结果' ISSUE_MODE=fresh \
  BRANCH='issue/9+42' MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/9+42' \
  EXPECTED_WORK_BRANCH_SHA="${SHARED_A_SHA}" ACPX_TIMEOUT_SECONDS=60 \
  EXPECTED_COMMIT_PARENT_SHA="${SHARED_A_SHA}" \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/9+42 \
  DEPENDENCY_BASE_SHA="${SHARED_A_SHA}" \
    bash "${FAKE_SCRIPTS}/run_executor_attempt.sh"
)" || fail "shared partial-work salvage wrapper failed"
printf '%s\n' "${partial_shared_output}" | tail -n 1 \
  | jq -e '.status == "blocked"' >/dev/null \
  || fail "shared partial-work salvage did not remain blocked"
jq -e 'has("mr_finalization") | not' \
  "${REPO_PATH}/.req_executor/issues/issue-42/state.json" >/dev/null \
  || fail "shared partial-work salvage wrote an MR pending checkpoint"
if grep -Eq '^(commit|verify:|mr-pending-checkpoint|mr:)' "${ORDER_LOG}" \
    || grep -Fq 'mr:' "${ORDER_LOG}"; then
  fail "shared partial-work failure published code or reached MR finalization"
fi

: >"${ORDER_LOG}"
write_shared_tail_state 11 "${SHARED_A_SHA}" true
mkdir -p "${REPO_PATH}/.req_executor/issues/issue-9"
jq -n --arg sha "${SHARED_A_SHA}" '{
  iid:9,status:"done",latest_attempt_number:1,
  dependency_pinned_attempt_number:1,
  work_branch:"issue/9+42",branch_members:[9,42],shared_branch_role:"head",
  commit_sha:$sha,work_branch_sha:$sha,dependency_history_verified:true,
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
  merge_request_url:"https://gitlab.example.test/group/repo/-/merge_requests/7",
  mr_finalization:{
    status:"verified_open",source_attempt_number:1,
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
: >"${MR_RETRY_SENTINEL}"
: >"${MR_RECOVERY_LOG}"
valid_shared_tail_output="$(
  PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" MR_TEST_ACTION=reused \
  MR_TEST_FAIL_ONCE_FILE="${MR_RETRY_SENTINEL}" \
  MR_TEST_RECOVERY_LOG="${MR_RECOVERY_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=11 \
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
  and .local_branch == "issue/42-att011" and .mr_action == "reused"
' >/dev/null || fail "shared tail did not persist the reused MR result"
jq -e --arg sha "${SHARED_A_SHA}" '
  .work_branch == "issue/9+42" and .branch_members == [9,42]
  and .shared_branch_role == "tail"
  and .dependency_iid == 9 and .dependency_branch == "issue/9+42"
  and .dependency_base_sha == $sha
  and .dependency_history_verified == true
  and .mr_finalization == {
    status:"pending",source_attempt_number:11,
    work_branch:"issue/9+42",branch_members:[9,42],
    shared_branch_role:"tail",
    commit_sha:"0123456789abcdef0123456789abcdef01234567",
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
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=16 \
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

# The head owns no dependency tuple. Supplying one must fail at the same
# fixed-identity boundary, before any attempt side effect.
jq -n --arg sha "${SHARED_A_SHA}" '{
  iid:42,attempt_number:12,issue_title:"共享头节点",mode_actual:"fresh",
  auto_merge:false,merge_target_branch:"main",
  work_branch:"issue/42+43",branch_members:[42,43],shared_branch_role:"head",
  expected_work_branch_sha:null,
  expected_commit_parent_sha:$sha,
  dependency_iid:9,dependency_branch:"issue/42+43",dependency_base_sha:$sha
}' >"${SHARED_ISSUE_ROOT}/attempt_state.json"
chmod 600 "${SHARED_ISSUE_ROOT}/attempt_state.json"
: >"${ORDER_LOG}"
set +e
PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=12 \
  REPO_PATH="${REPO_PATH}" ISSUE_TITLE='共享头节点' ISSUE_MODE=fresh \
  BRANCH=main WORK_BRANCH='issue/42+43' ACPX_TIMEOUT_SECONDS=60 \
  EXPECTED_COMMIT_PARENT_SHA="${SHARED_A_SHA}" \
  DEPENDENCY_IID=9 DEPENDENCY_BRANCH=issue/42+43 \
  DEPENDENCY_BASE_SHA="${SHARED_A_SHA}" \
  bash "${FAKE_SCRIPTS}/run_executor_attempt.sh" >/dev/null 2>&1
shared_head_dependency_rc=$?
set -e
[ "${shared_head_dependency_rc}" -ne 0 ] \
  || fail "shared head accepted a dependency tuple"
[ ! -s "${ORDER_LOG}" ] \
  || fail "invalid shared head identity reached executor side effects"

# An already-published shared head may not use the ordinary code-changing
# continue path. Future MR-only recovery has a separate identity and must not
# accidentally turn A into A2 on the shared branch.
jq -n --arg lease "${SHARED_A_SHA}" --arg parent "${SHARED_OTHER_SHA}" '{
  iid:42,attempt_number:14,issue_title:"共享头节点续跑",mode_actual:"continue",
  auto_merge:false,merge_target_branch:"main",
  work_branch:"issue/42+43",branch_members:[42,43],shared_branch_role:"head",
  expected_work_branch_sha:$lease,expected_commit_parent_sha:$parent,
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null
}' >"${SHARED_ISSUE_ROOT}/attempt_state.json"
chmod 600 "${SHARED_ISSUE_ROOT}/attempt_state.json"
: >"${ORDER_LOG}"
set +e
PATH="${FAKE_BIN}:${PATH}" ORDER_LOG="${ORDER_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=14 \
  REPO_PATH="${REPO_PATH}" ISSUE_MODE=continue BRANCH=main \
  WORK_BRANCH='issue/42+43' EXPECTED_WORK_BRANCH_SHA="${SHARED_A_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${SHARED_OTHER_SHA}" ACPX_TIMEOUT_SECONDS=60 \
  bash "${FAKE_SCRIPTS}/run_executor_attempt.sh" >/dev/null 2>&1
shared_head_continue_rc=$?
set -e
[ "${shared_head_continue_rc}" -ne 0 ] \
  || fail "shared head ordinary continue bypassed the fixed identity gate"
[ ! -s "${ORDER_LOG}" ] \
  || fail "shared head ordinary continue reached executor side effects"

echo "ok all-in-one executor attempt persists its exact compact result"
