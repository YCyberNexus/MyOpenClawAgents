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
export WORK_BRANCH="issue/${ISSUE_IID}"
export LOCAL_ATTEMPT_BRANCH="${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}"
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

cat >"${FAKE_SCRIPTS}/run_acpx_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' acpx >>"${ORDER_LOG}"
printf '%s\n' 'ACPX_EXIT=0'
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
outcome=opened
[ "${AUTO_MERGE}" != true ] || outcome=merged
outcome="${MR_TEST_OUTCOME:-${outcome}}"
verified=true
[ "${outcome}" != unknown ] || verified=false
printf 'mr:%s:%s:%s\n' "${MERGE_TARGET_BRANCH}" "${AUTO_MERGE}" "${COMMIT_SHA}" >>"${ORDER_LOG}"
jq -cn \
  --argjson iid 7 \
  --arg web_url 'https://gitlab.example.test/group/repo/-/merge_requests/7' \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg sha "${COMMIT_SHA}" \
  --arg observed_state "${outcome}" \
  --arg outcome "${outcome}" \
  --argjson verified "${verified}" \
  --arg mr_action created \
  --argjson issue_iid "${ISSUE_IID}" \
  --argjson attempt_number "${ATTEMPT_NUMBER}" \
  --argjson auto_merge "${AUTO_MERGE}" '{
    version:1,iid:$iid,web_url:$web_url,
    source_branch:$source_branch,target_branch:$target_branch,sha:$sha,
    observed_state:$observed_state,outcome:$outcome,verified:$verified,
    merge_attempted:$auto_merge,merge_api_succeeded:$auto_merge,
    reason:(if $auto_merge then "verified_merged" else "auto_merge_disabled" end),
    mr_action:$mr_action,issue_iid:$issue_iid,
    attempt_number:$attempt_number,auto_merge:$auto_merge
  }' >"${LOG_DIR}/mr_result.json"
chmod 600 "${LOG_DIR}/mr_result.json"
printf '%s\n' 'https://gitlab.example.test/group/repo/-/merge_requests/7' created 7 "${outcome}"
[ "${MR_TEST_EXIT:-0}" -eq 0 ] || exit "${MR_TEST_EXIT}"
EOF
cat >"${FAKE_SCRIPTS}/summarize_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'summarize:%s\n' "${SUMMARY_POST_TO_ISSUE}" >>"${ORDER_LOG}"
printf '%s\n' 'SUMMARY_POSTED=true' >&2
printf '%s\n' "${ISSUE_ROOT}/summary.md"
EOF
chmod +x "${FAKE_BIN}/timeout" "${FAKE_SCRIPTS}"/*.sh

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

if result_mode="$(stat -f '%Lp' "${result_file}" 2>/dev/null)"; then
  :
else
  result_mode="$(stat -c '%a' "${result_file}")"
fi
[ "${result_mode}" = 600 ] || fail "worker_result.json mode is ${result_mode}, expected 600"

# Auto-merge uses MERGE_TARGET_BRANCH for verification/MR creation and writes
# finish only when the exact durable marker says the MR is verified merged.
: >"${ORDER_LOG}"
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

echo "ok all-in-one executor attempt persists its exact compact result"
