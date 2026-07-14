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
printf '%s\n' verify >>"${ORDER_LOG}"
EOF
cat >"${FAKE_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'label:%s:%s\n' "$1" "$2" >>"${ORDER_LOG}"
EOF
cat >"${FAKE_SCRIPTS}/create_mr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' mr >>"${ORDER_LOG}"
printf '%s\n' 'https://gitlab.example.test/group/repo/-/merge_requests/7' created
EOF
cat >"${FAKE_SCRIPTS}/summarize_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' summarize >>"${ORDER_LOG}"
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
verify
label:remove:doing
label:add:done
mr
label:add:pr
summarize'
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

echo "ok all-in-one executor attempt persists its exact compact result"
