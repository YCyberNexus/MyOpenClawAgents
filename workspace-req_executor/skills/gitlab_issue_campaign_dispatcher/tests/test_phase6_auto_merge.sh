#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase6-auto-merge.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "${FIXTURE_SCRIPTS}" "${FAKE_BIN}" \
  "${TEST_ROOT}/issues" "${TEST_ROOT}/logs" "${TEST_ROOT}/worktrees"
cp "${SKILL_DIR}/scripts/_dispatch_lib.sh" "${FIXTURE_SCRIPTS}/_dispatch_lib.sh"

fail() {
  echo "test_phase6_auto_merge.sh: $*" >&2
  exit 1
}

cat >"${FIXTURE_SCRIPTS}/merge_mr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${MERGE_MR_MODE:?}" = verify ]
case "${VERIFY_SCENARIO:?}" in
  merged) observed_state=merged; outcome=merged; verified=true; reason=verified_merged ;;
  opened) observed_state=opened; outcome=opened; verified=true; reason=verified_opened ;;
  unknown) observed_state=unknown; outcome=unknown; verified=false; reason=mr_read_failed ;;
  *) exit 90 ;;
esac
jq -cn \
  --argjson iid "${MR_IID}" \
  --arg web_url "${MERGE_REQUEST_URL}" \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg sha "${COMMIT_SHA}" \
  --arg observed_state "${observed_state}" \
  --arg outcome "${outcome}" \
  --argjson verified "${verified}" \
  --arg reason "${reason}" '{
    version:1,iid:$iid,web_url:$web_url,
    source_branch:$source_branch,target_branch:$target_branch,sha:$sha,
    observed_state:$observed_state,outcome:$outcome,verified:$verified,
    merge_attempted:false,merge_api_succeeded:false,reason:$reason
  }'
EOF
chmod +x "${FIXTURE_SCRIPTS}/merge_mr.sh"

cat >"${FAKE_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${TIMEOUT_SCENARIO:-run}" = timeout ]; then
  exit 124
fi
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
chmod +x "${FAKE_BIN}/timeout"

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export PROJECT_URI='group%2Frepo'
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT=repo
export GROUP=group
export GITLAB_TOKEN=test-token
export REPO_PARENT_PATH="${TEST_ROOT}"
export WORKTREES_ROOT="${TEST_ROOT}/worktrees"
export REQ_EXECUTOR_DIR=.req_executor
export PATH="${FAKE_BIN}:${PATH}"

# shellcheck source=/dev/null
source "${FIXTURE_SCRIPTS}/_dispatch_lib.sh"

LABEL_LOG="${TEST_ROOT}/labels.log"
_label_op() {
  printf '%s:%s:%s\n' "$1" "$2" "$3" >>"${LABEL_LOG}"
  if [ "${FAIL_FINISH_LABEL:-false}" = true ] \
      && [ "$2" = add ] && [ "$3" = finish ]; then
    return 73
  fi
}

make_state() {
  local iid="$1"
  jq -cn --argjson iid "${iid}" '{
    pending_subagents:{($iid|tostring):{
      attempt_number:1,child_session_key:"child",
      auto_merge:true,branch:"develop",merge_target_branch:"release"
    }},
    active_issue_iids:[$iid],active_issue_sessions:[],
    completed_iids:[],unfinished_iids:[],blocked_iids:[],failed_iids:[],
    timeout_iids:[],blocked_at_tick_by_iid:{},blocked_retry_limit:1,
    tick_seq:1,quota_completed_this_tick:0,campaign_status:"waiting_for_callbacks"
  }'
}

make_reply() {
  local iid="$1"
  jq -cn --argjson iid "${iid}" '{
    iid:$iid,attempt_number:1,status:"done",mode_actual:"fresh",
    work_branch:("issue/" + ($iid|tostring)),local_branch:"attempt-1",
    commit_sha:"0123456789abcdef0123456789abcdef01234567",
    merge_request_url:("https://gitlab.example.test/group/repo/-/merge_requests/" + ($iid|tostring)),
    mr_action:"created",wiki_url:"",labels_added:["pr"],labels_removed:["done"],
    summary_posted:true,block_reason:"",log_dir:"/tmp/log",block_side:"cc"
  }'
}

write_marker() {
  local iid="$1" mode="${2:-600}" marker_path marker_dir
  marker_dir="${WORKTREES_ROOT}/issue-${iid}/.req_executor/issue-${iid}/log/attempt-001"
  marker_path="${marker_dir}/mr_result.json"
  mkdir -p "${marker_dir}"
  jq -cn --argjson iid "${iid}" '{
    version:1,iid:$iid,
    web_url:("https://gitlab.example.test/group/repo/-/merge_requests/" + ($iid|tostring)),
    source_branch:("issue/" + ($iid|tostring)),target_branch:"release",
    sha:"0123456789abcdef0123456789abcdef01234567",
    observed_state:"merged",outcome:"merged",verified:true,
    merge_attempted:true,merge_api_succeeded:true,reason:"verified_merged",
    mr_action:"created",issue_iid:$iid,attempt_number:1,auto_merge:true
  }' >"${marker_path}"
  chmod "${mode}" "${marker_path}"
}

: >"${LABEL_LOG}"
export VERIFY_SCENARIO=merged
write_marker 7
merged_out="$(phase6_process "$(make_state 7)" "$(make_reply 7)" false)" \
  || fail "verified merged Phase 6 call failed"
jq -e '
  .final_status == "done"
  and .final_reply.status == "done"
  and .final_reply.block_reason == ""
  and (.updated_state.completed_iids | index(7) != null)
' <<<"${merged_out}" >/dev/null || fail "verified merged MR was not classified done"
grep -Fq '7:add:finish' "${LABEL_LOG}" || fail "verified merged MR did not add finish"
if grep -Eq '7:add:(pr|failed-cc|failed-dispatcher)' "${LABEL_LOG}"; then
  fail "verified merged MR received a regressing label"
fi

: >"${LABEL_LOG}"
export VERIFY_SCENARIO=opened
write_marker 8
opened_out="$(phase6_process "$(make_state 8)" "$(make_reply 8)" false)" \
  || fail "verified opened Phase 6 call failed"
jq -e '
  .final_status == "failed"
  and .final_reply.status == "failed"
  and (.final_reply.block_reason | contains("remains opened"))
  and (.updated_state.failed_iids | index(8) != null)
' <<<"${opened_out}" >/dev/null || fail "opened automatic MR was not reported failed"
grep -Fq '8:add:pr' "${LABEL_LOG}" || fail "opened automatic MR did not retain pr"
if grep -Eq '8:add:(finish|failed-cc|failed-dispatcher)' "${LABEL_LOG}"; then
  fail "opened automatic MR received finish or a failure label"
fi

: >"${LABEL_LOG}"
export VERIFY_SCENARIO=unknown
write_marker 9
unknown_out="$(phase6_process "$(make_state 9)" "$(make_reply 9)" false)" \
  || fail "unknown-state Phase 6 call failed"
jq -e '
  .final_status == "failed"
  and .final_reply.status == "failed"
  and (.final_reply.block_reason | contains("state is uncertain"))
' <<<"${unknown_out}" >/dev/null || fail "unknown automatic merge state was not reported conservatively"
[ ! -s "${LABEL_LOG}" ] || fail "unknown automatic merge state changed live labels"

# Missing and non-private markers fail closed without touching a stable label.
: >"${LABEL_LOG}"
export VERIFY_SCENARIO=merged
missing_out="$(phase6_process "$(make_state 10)" "$(make_reply 10)" false)" \
  || fail "missing-marker Phase 6 call failed"
jq -e '
  .final_status == "failed"
  and (.final_reply.block_reason | contains("trusted current-attempt MR marker"))
' <<<"${missing_out}" >/dev/null || fail "missing marker did not fail closed"
[ ! -s "${LABEL_LOG}" ] || fail "missing marker changed live labels"

: >"${LABEL_LOG}"
write_marker 11 644
bad_mode_out="$(phase6_process "$(make_state 11)" "$(make_reply 11)" false)" \
  || fail "bad-mode marker Phase 6 call failed"
jq -e '.final_status == "failed"' <<<"${bad_mode_out}" >/dev/null \
  || fail "non-private marker was trusted"
[ ! -s "${LABEL_LOG}" ] || fail "non-private marker changed live labels"

# A callback cannot point Phase 6 at an unrelated, otherwise self-consistent MR.
: >"${LABEL_LOG}"
write_marker 12
forged_reply="$(make_reply 12 | jq -c '
  .merge_request_url = "https://gitlab.example.test/group/repo/-/merge_requests/999"
')"
forged_out="$(phase6_process "$(make_state 12)" "${forged_reply}" false)" \
  || fail "forged-identity Phase 6 call failed"
jq -e '
  .final_status == "failed"
  and (.final_reply.block_reason | contains("does not match the trusted"))
' <<<"${forged_out}" >/dev/null || fail "forged MR identity was not rejected"
[ ! -s "${LABEL_LOG}" ] || fail "forged MR identity changed live labels"

# The marker can synthesize a recovery reply after a wrapper crash, but only
# the subsequent live verification can turn that evidence into `finish`.
write_marker 13
recovered_reply="$(phase6_reply_from_auto_merge_marker "$(make_state 13)" 13 1)" \
  || fail "trusted marker recovery did not produce a compact reply"
jq -e '
  .iid == 13 and .attempt_number == 1 and .status == "done"
  and .work_branch == "issue/13"
  and .merge_request_url == "https://gitlab.example.test/group/repo/-/merge_requests/13"
  and .commit_sha == "0123456789abcdef0123456789abcdef01234567"
' <<<"${recovered_reply}" >/dev/null || fail "marker recovery reply identity is wrong"
: >"${LABEL_LOG}"
recovered_out="$(phase6_process "$(make_state 13)" "${recovered_reply}" false)" \
  || fail "marker recovery Phase 6 call failed"
jq -e '.final_status == "done"' <<<"${recovered_out}" >/dev/null \
  || fail "verified recovered marker did not complete"
grep -Fxq '13:add:finish' "${LABEL_LOG}" \
  || fail "verified recovered marker did not add finish atomically"

# A transient finish-label failure keeps pending intact and produces no done
# handoff. Re-entering Phase 6 with the durable marker retries only the atomic
# label transition and then completes.
: >"${LABEL_LOG}"
write_marker 14
export FAIL_FINISH_LABEL=true
retry_out="$(phase6_process "$(make_state 14)" "$(make_reply 14)" false)" \
  || fail "finish-label retry Phase 6 call failed"
unset FAIL_FINISH_LABEL
jq -e '
  .final_status == "blocked"
  and .label_retry_pending == true
  and .final_reply.status == "blocked"
  and (.updated_state.pending_subagents["14"] != null)
  and .updated_state.pending_subagents["14"].finish_label_retry == true
  and .updated_state.pending_subagents["14"].finish_label_retry_attempt == 1
  and ((.updated_state.completed_iids // []) | index(14) == null)
' <<<"${retry_out}" >/dev/null \
  || fail "finish-label failure drained or completed the pending claim"
[ "$(cat "${LABEL_LOG}")" = '14:add:finish' ] \
  || fail "finish-label failure removed a stable label before retry: $(cat "${LABEL_LOG}")"
: >"${LABEL_LOG}"
retry_success_out="$(phase6_process \
  "$(jq -c '.updated_state' <<<"${retry_out}")" "$(make_reply 14)" false)" \
  || fail "finish-label retry did not re-enter Phase 6"
jq -e '
  .final_status == "done"
  and (.updated_state.pending_subagents["14"] == null)
  and (.updated_state.completed_iids | index(14) != null)
' <<<"${retry_success_out}" >/dev/null \
  || fail "successful finish-label retry did not complete and drain"
[ "$(cat "${LABEL_LOG}")" = '14:add:finish' ] \
  || fail "finish-label retry performed non-atomic label operations"

# Network verification is bounded; timeout preserves labels and never grants
# finish based only on local evidence.
: >"${LABEL_LOG}"
write_marker 15
export TIMEOUT_SCENARIO=timeout
timeout_out="$(phase6_process "$(make_state 15)" "$(make_reply 15)" false)" \
  || fail "verification-timeout Phase 6 call failed"
unset TIMEOUT_SCENARIO
jq -e '
  .final_status == "failed"
  and (.final_reply.block_reason | contains("verification_timeout"))
' <<<"${timeout_out}" >/dev/null || fail "verification timeout did not fail closed"
[ ! -s "${LABEL_LOG}" ] || fail "verification timeout changed live labels"

# Rolling-upgrade evidence may expose only the raw label array. It must still
# protect finish from both regressing failures and a late ordinary done->pr.
legacy_finish_evidence='[{"iid":16,"labels":["finish"],"is_done_on_gitlab":false,"has_done_pr":false}]'
phase6_evidence_shows_completed 16 "${legacy_finish_evidence}" \
  || fail "legacy raw finish label was not recognized as completed"
phase6_evidence_has_finish 16 "${legacy_finish_evidence}" \
  || fail "legacy raw finish label did not activate downgrade protection"

echo "ok Phase 6 independently verifies automatic merges before finish"
