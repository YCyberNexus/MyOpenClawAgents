#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase6-shared-mr.XXXXXX")"
mkdir -p "${TEST_ROOT}/issues" "${TEST_ROOT}/logs" \
  "${TEST_ROOT}/worktrees"

fail() {
  echo "test_phase6_shared_branch_mr.sh: $*" >&2
  exit 1
}

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export PROJECT_URI='group%2Frepo'
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT=repo
export GROUP=group
export GITLAB_TOKEN=test-token
export REPO_PARENT_PATH="${TEST_ROOT}"
export WORKTREES_ROOT="${TEST_ROOT}/worktrees"
export REQ_EXECUTOR_DIR=.req_executor

# shellcheck source=/dev/null
source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

# Keep a callable copy of the production live verifier before replacing the
# name below with the deterministic Phase 6 state-machine stub.
eval "$(declare -f shared_mr_query_live_identity \
  | sed '1s/shared_mr_query_live_identity/shared_mr_query_live_identity_real/')"

LIVE_SHARED_MR_STATE=opened
LIVE_SHARED_MR_IDENTITY_MATCHES=true
LIVE_SHARED_MR_UNAVAILABLE=false
shared_mr_query_live_identity() {
  [ "${LIVE_SHARED_MR_UNAVAILABLE}" != true ] || return 1
  jq -cn \
    --arg state "${LIVE_SHARED_MR_STATE}" \
    --argjson identity_matches "${LIVE_SHARED_MR_IDENTITY_MATCHES}" \
    '{state:$state,identity_matches:$identity_matches}'
}

LABEL_LOG="${TEST_ROOT}/labels.log"
_label_op() {
  if [ -n "${FAIL_PR_LABEL_SENTINEL:-}" ] \
      && [ -f "${FAIL_PR_LABEL_SENTINEL}" ] \
      && [ "$2" = add ] && [ "$3" = pr ]; then
    mv "${FAIL_PR_LABEL_SENTINEL}" "${FAIL_PR_LABEL_SENTINEL}.used"
    return 1
  fi
  printf '%s:%s:%s\n' "$1" "$2" "$3" >>"${LABEL_LOG}"
}

HEAD_SHA='1111111111111111111111111111111111111111'
TAIL_SHA='2222222222222222222222222222222222222222'
INTENT_ID='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

# The production verifier must reject a second open MR for the same source
# branch even when the marker-selected MR itself still has an exact identity.
LIVE_VERIFY_BIN="${TEST_ROOT}/live-verify-bin"
mkdir -p "${LIVE_VERIFY_BIN}"
cat >"${LIVE_VERIFY_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --kill-after=* ]] || exit 91
shift
[[ "${1:-}" == *s ]] || exit 92
shift
exec "$@"
EOF
cat >"${LIVE_VERIFY_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'api user' ]; then
  jq -cn '{username:"req-executor-bot"}'
elif [ "$*" = 'api projects/group%2Frepo/merge_requests/17' ]; then
  jq -cn '{
    iid:17,
    web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
    source_branch:"issue/41+43",target_branch:"main",
    sha:"1111111111111111111111111111111111111111",state:"opened",
    author:{username:"req-executor-bot"},
    description:("Closes #41\nCloses #43\n"
      + "<!-- req_executor-shared-mr-intent:"
      + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->")
  }'
elif [[ "$*" == api\ projects/group%2Frepo/merge_requests\?* ]]; then
  jq -cn --argjson count "${LIVE_OPEN_COUNT:-1}" '[
    range(0;$count) as $offset
    | {
        iid:(17 + $offset),
        web_url:("https://gitlab.example.test/group/repo/-/merge_requests/"
          + ((17 + $offset) | tostring)),
        source_branch:"issue/41+43",state:"opened"
      }
  ]'
else
  exit 93
fi
EOF
chmod +x "${LIVE_VERIFY_BIN}/timeout" "${LIVE_VERIFY_BIN}/glab"

real_unique_result="$(
  export PATH="${LIVE_VERIFY_BIN}:${PATH}"
  export GLAB_BIN="${LIVE_VERIFY_BIN}/glab"
  export LIVE_OPEN_COUNT=1
  export PHASE6_MR_VERIFY_TIMEOUT_SECONDS=5
  shared_mr_query_live_identity_real 17 \
    'https://gitlab.example.test/group/repo/-/merge_requests/17' \
    'issue/41+43' main "${HEAD_SHA}" "${INTENT_ID}" 41 43
)" || fail "production shared MR live verifier rejected one exact open MR"
jq -e '.state == "opened" and .identity_matches == true' \
  <<<"${real_unique_result}" >/dev/null \
  || fail "production shared MR live verifier did not accept the unique MR"

real_duplicate_result="$(
  export PATH="${LIVE_VERIFY_BIN}:${PATH}"
  export GLAB_BIN="${LIVE_VERIFY_BIN}/glab"
  export LIVE_OPEN_COUNT=2
  export PHASE6_MR_VERIFY_TIMEOUT_SECONDS=5
  shared_mr_query_live_identity_real 17 \
    'https://gitlab.example.test/group/repo/-/merge_requests/17' \
    'issue/41+43' main "${HEAD_SHA}" "${INTENT_ID}" 41 43
)" || fail "production shared MR live verifier could not classify duplicate MRs"
jq -e '.state == "opened" and .identity_matches == false' \
  <<<"${real_duplicate_result}" >/dev/null \
  || fail "production shared MR live verifier accepted duplicate open MRs"

make_shared_state() {
  local head="$1" tail="$2" iid="$3" role="$4"
  jq -cn \
    --argjson head "${head}" \
    --argjson tail "${tail}" \
    --argjson iid "${iid}" \
    --arg role "${role}" \
    --arg dependency_sha "${HEAD_SHA}" '{
      pending_subagents:{($iid|tostring):{
        execution_id:1,child_session_key:"child",auto_merge:false,
        branch:"main",merge_target_branch:"main",
        work_branch:("issue/" + ($head|tostring) + "+" + ($tail|tostring)),
        branch_members:[$head,$tail],shared_branch_role:$role,
        dependency_iid:(if $role == "tail" then $head else null end),
        dependency_branch:(if $role == "tail" then
          ("issue/" + ($head|tostring) + "+" + ($tail|tostring)) else null end),
        dependency_base_sha:(if $role == "tail" then $dependency_sha else null end)
      }},
      active_issue_iids:[$iid],active_issue_sessions:[],
      completed_iids:[],unfinished_iids:[],blocked_iids:[],failed_iids:[],
      timeout_iids:[],blocked_at_tick_by_iid:{},blocked_retry_limit:2,
      tick_seq:1,quota_completed_this_tick:0,campaign_status:"waiting_for_callbacks"
    }'
}

make_shared_reply() {
  local head="$1" tail="$2" iid="$3" role="$4" mr_iid="$5"
  local commit_sha="${HEAD_SHA}" action=created
  if [ "${role}" = tail ]; then
    commit_sha="${TAIL_SHA}"
    action=reused
  fi
  jq -cn \
    --argjson head "${head}" \
    --argjson tail "${tail}" \
    --argjson iid "${iid}" \
    --argjson mr_iid "${mr_iid}" \
    --arg commit_sha "${commit_sha}" \
    --arg action "${action}" '{
      iid:$iid,execution_id:1,status:"done",mode_actual:"fresh",
      work_branch:("issue/" + ($head|tostring) + "+" + ($tail|tostring)),
      local_branch:("issue/" + ($iid|tostring)),
      commit_sha:$commit_sha,
      merge_request_url:("https://gitlab.example.test/group/repo/-/merge_requests/"
        + ($mr_iid|tostring)),
      mr_action:$action,wiki_url:"",labels_added:[],labels_removed:[],
      summary_posted:false,block_reason:"",log_dir:"/tmp/log",block_side:"cc"
    }'
}

write_shared_marker() {
  local head="$1" tail="$2" iid="$3" role="$4" mr_iid="$5"
  local action="${6:-}" verified="${7:-true}"
  local outcome="${8:-opened}" observed_state="${9:-opened}"
  local commit_sha="${HEAD_SHA}" dependency_sha=""
  local marker_dir marker_path issue_dir
  if [ "${role}" = tail ]; then
    commit_sha="${TAIL_SHA}"
    dependency_sha="${HEAD_SHA}"
    [ -n "${action}" ] || action=reused
  else
    [ -n "${action}" ] || action=created
  fi
  marker_dir="${WORKTREES_ROOT}/issue-${iid}/.req_executor/issue-${iid}/log/execution-1"
  marker_path="${marker_dir}/mr_result.json"
  issue_dir="${ISSUES_ROOT}/issue-${iid}"
  mkdir -p "${marker_dir}" "${issue_dir}"
  jq -cn \
    --argjson iid "${iid}" \
    --argjson mr_iid "${mr_iid}" \
    --argjson head "${head}" \
    --argjson tail "${tail}" \
    --arg action "${action}" \
    --arg commit_sha "${commit_sha}" \
    --arg dependency_sha "${dependency_sha}" \
    --arg intent_id "${INTENT_ID}" \
    --argjson verified "${verified}" \
    --arg outcome "${outcome}" \
    --arg observed_state "${observed_state}" '{
      version:1,iid:$mr_iid,
      web_url:("https://gitlab.example.test/group/repo/-/merge_requests/"
        + ($mr_iid|tostring)),
      source_branch:("issue/" + ($head|tostring) + "+" + ($tail|tostring)),
      target_branch:"main",dependency_base_sha:$dependency_sha,sha:$commit_sha,
      observed_state:$observed_state,outcome:$outcome,verified:$verified,
      merge_attempted:false,merge_api_succeeded:false,reason:"auto_merge_disabled",
      mr_action:$action,issue_iid:$iid,execution_id:1,auto_merge:false,
      shared_mr_intent_id:$intent_id
    }' >"${marker_path}"
  chmod 600 "${marker_path}"
  jq -cn \
    --argjson iid "${iid}" \
    --argjson head "${head}" \
    --argjson tail "${tail}" \
    --arg role "${role}" \
    --arg commit_sha "${commit_sha}" \
    --arg dependency_sha "${dependency_sha}" \
    --arg intent_id "${INTENT_ID}" '{
      iid:$iid,status:"doing",
      work_branch:("issue/" + ($head|tostring) + "+" + ($tail|tostring)),
      branch_members:[$head,$tail],shared_branch_role:$role,
      dependency_iid:(if $role == "tail" then $head else null end),
      dependency_branch:(if $role == "tail" then
        ("issue/" + ($head|tostring) + "+" + ($tail|tostring)) else null end),
      dependency_base_sha:(if $role == "tail" then $dependency_sha else null end),
      work_branch_sha:$commit_sha,dependency_pinned_execution_id:1,
      dependency_history_verified:true,
      mr_finalization:{
        status:"pending",source_execution_id:1,
        work_branch:("issue/" + ($head|tostring) + "+" + ($tail|tostring)),
        branch_members:[$head,$tail],shared_branch_role:$role,
        commit_sha:$commit_sha,intent_id:$intent_id,target_branch:"main"
      }
    }' >"${issue_dir}/state.json"
  chmod 600 "${issue_dir}/state.json"
}

# A owns creation of the one shared MR; a strict marker and matching compact
# result are enough for the callback-side transition to pr/done.
write_shared_marker 41 43 41 head 17
: >"${LABEL_LOG}"
head_out="$(phase6_process \
  "$(make_shared_state 41 43 41 head)" \
  "$(make_shared_reply 41 43 41 head 17)" false)" \
  || fail "valid shared head Phase 6 call failed"
jq -e '
  .final_status == "done"
  and .final_reply.mr_action == "created"
  and (.updated_state.completed_iids | index(41) != null)
' <<<"${head_out}" >/dev/null \
  || fail "valid shared head marker did not complete"
jq -e '
  .mr_finalization.status == "verified_open"
  and .mr_finalization.source_execution_id == 1
  and .mr_finalization.work_branch == "issue/41+43"
  and .mr_finalization.branch_members == [41,43]
  and .mr_finalization.shared_branch_role == "head"
  and .mr_finalization.commit_sha == "1111111111111111111111111111111111111111"
  and .mr_finalization.intent_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .mr_finalization.target_branch == "main"
  and .mr_finalization.iid == 17
  and .mr_finalization.web_url == "https://gitlab.example.test/group/repo/-/merge_requests/17"
  and .mr_finalization.mr_action == "created"
' "${ISSUES_ROOT}/issue-41/state.json" >/dev/null \
  || fail "shared head exact MR binding was not persisted"
[ "$(cat "${LABEL_LOG}")" = '41:add:pr' ] \
  || fail "shared head completion was not one atomic pr transition"

# Simulate a crash after per-Issue verified_open persistence but before the
# campaign pending entry is drained. Replay must accept that exact promoted
# authority, keep the claim while the fresh MR read is unavailable, and drain
# it without rerunning issue code once the same MR becomes observable again.
LIVE_SHARED_MR_UNAVAILABLE=true
: >"${LABEL_LOG}"
verified_crash_wait="$(phase6_process \
  "$(make_shared_state 41 43 41 head)" \
  "$(make_shared_reply 41 43 41 head 17)" false)" \
  || fail "verified-open crash replay wait failed"
jq -e '
  .final_status == "blocked"
  and .mr_recovery_pending == true
  and .updated_state.pending_subagents["41"].mr_finalization_retry == true
' <<<"${verified_crash_wait}" >/dev/null \
  || fail "verified-open crash replay drained the pending claim"
jq -e '.mr_finalization.status == "verified_open"' \
  "${ISSUES_ROOT}/issue-41/state.json" >/dev/null \
  || fail "verified-open crash replay regressed the durable MR authority"
[ ! -s "${LABEL_LOG}" ] \
  || fail "unavailable verified-open crash replay mutated labels"
LIVE_SHARED_MR_UNAVAILABLE=false
verified_crash_done="$(phase6_process \
  "$(jq -c '.updated_state' <<<"${verified_crash_wait}")" \
  "$(make_shared_reply 41 43 41 head 17)" false)" \
  || fail "verified-open crash replay did not recover"
jq -e '
  .final_status == "done"
  and (.updated_state.pending_subagents["41"] // null) == null
  and (.updated_state.completed_iids | index(41) != null)
' <<<"${verified_crash_done}" >/dev/null \
  || fail "verified-open crash replay did not drain exactly once"

# C must reuse A's MR, with its own source SHA bound by its private marker.
write_shared_marker 41 43 43 tail 17
tail_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 41 43 43 tail)" \
  "$(make_shared_reply 41 43 43 tail 17)")" \
  || fail "valid shared tail resolution failed"
jq -e '
  .applies == true and .reply.status == "done"
  and .reply.mr_action == "reused" and .completion_label == "pr"
' <<<"${tail_resolution}" >/dev/null \
  || fail "valid shared tail marker was not accepted"

# A transient `pr` label failure must keep the exact claim pending. The next
# marker-only Phase 6 pass retries labels without rerunning issue code.
write_shared_marker 45 47 45 head 19
FAIL_PR_LABEL_SENTINEL="${TEST_ROOT}/fail-pr-label-once"
: >"${FAIL_PR_LABEL_SENTINEL}"
label_retry_out="$(phase6_process \
  "$(make_shared_state 45 47 45 head)" \
  "$(make_shared_reply 45 47 45 head 19)" false)" \
  || fail "shared pr-label retry setup failed"
jq -e '
  .final_status == "blocked"
  and .label_retry_pending == true
  and .updated_state.pending_subagents["45"].mr_label_retry == true
  and .updated_state.pending_subagents["45"].mr_label_retry_execution_id == 1
' <<<"${label_retry_out}" >/dev/null \
  || fail "shared pr-label failure drained the exact pending claim"
label_retry_done="$(phase6_process \
  "$(jq -c '.updated_state' <<<"${label_retry_out}")" \
  "$(make_shared_reply 45 47 45 head 19)" false)" \
  || fail "shared pr-label retry did not finish"
jq -e '
  .final_status == "done"
  and (.updated_state.pending_subagents["45"] // null) == null
' <<<"${label_retry_done}" >/dev/null \
  || fail "shared pr-label retry did not complete from the same marker"
unset FAIL_PR_LABEL_SENTINEL

# A valid post-push checkpoint converts a missing marker into an MR-only
# recovery wait. It must retain the same claim and avoid label writes.
pending_recovery_dir="${ISSUES_ROOT}/issue-55"
mkdir -p "${pending_recovery_dir}"
jq -cn --arg sha "${HEAD_SHA}" '{
  iid:55,status:"done",work_branch:"issue/55+57",branch_members:[55,57],
  shared_branch_role:"head",work_branch_sha:$sha,
  dependency_pinned_execution_id:1,dependency_history_verified:true,
  mr_finalization:{
    status:"pending",source_execution_id:1,work_branch:"issue/55+57",
    branch_members:[55,57],shared_branch_role:"head",commit_sha:$sha,
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main"
  }
}' >"${pending_recovery_dir}/state.json"
chmod 600 "${pending_recovery_dir}/state.json"
write_shared_marker 55 57 55 head 29 created false unknown unknown
pending_recovery_marker="${WORKTREES_ROOT}/issue-55/.req_executor/issue-55/log/execution-1/mr_result.json"
mv "${pending_recovery_marker}" "${pending_recovery_marker}.missing"
: >"${LABEL_LOG}"
mr_recovery_wait="$(phase6_process \
  "$(make_shared_state 55 57 55 head)" \
  "$(make_shared_reply 55 57 55 head 29)" false)" \
  || fail "shared MR recovery wait failed"
jq -e '
  .final_status == "blocked"
  and .mr_recovery_pending == true
  and .updated_state.pending_subagents["55"].mr_finalization_retry == true
  and .updated_state.pending_subagents["55"].mr_finalization_retry_execution_id == 1
' <<<"${mr_recovery_wait}" >/dev/null \
  || fail "shared MR recovery wait drained or rewrote the exact claim"
[ ! -s "${LABEL_LOG}" ] \
  || fail "shared MR recovery wait mutated labels before MR verification"

# A pending/unknown historical observation is only identity evidence. It may
# complete after Phase 6 independently observes the same exact MR still open.
write_shared_marker 51 53 51 head 27 created false unknown unknown
unverified_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 51 53 51 head)" \
  "$(make_shared_reply 51 53 51 head 27)")" \
  || fail "unverified marker rejection failed"
jq -e '
  .applies == true and .reply.status == "done"
  and .completion_label == "pr"
' <<<"${unverified_resolution}" >/dev/null \
  || fail "identity-only shared marker was not decided by the fresh live read"

# A deterministic all-state history conflict is terminal evidence, not a
# reason to retry MR creation forever. Phase 6 must drain it without publishing
# pr even if the selected historical MR currently looks open.
write_shared_marker 52 54 52 head 28 created false unknown unknown
history_conflict_marker="${WORKTREES_ROOT}/issue-52/.req_executor/issue-52/log/execution-1/mr_result.json"
history_conflict_tmp="$(mktemp "${history_conflict_marker}.conflict.XXXXXX")"
jq '.reason = "shared_mr_history_conflict"' \
  "${history_conflict_marker}" >"${history_conflict_tmp}"
chmod 600 "${history_conflict_tmp}"
mv "${history_conflict_tmp}" "${history_conflict_marker}"
history_conflict_out="$(phase6_process \
  "$(make_shared_state 52 54 52 head)" \
  "$(make_shared_reply 52 54 52 head 28)" false)" \
  || fail "shared history-conflict Phase 6 call failed"
jq -e '
  .final_status == "failed"
  and .mr_recovery_pending != true
  and (.updated_state.pending_subagents["52"] // null) == null
  and (.updated_state.failed_iids | index(52) != null)
  and (.updated_state.unfinished_iids | index(52)) == null
' <<<"${history_conflict_out}" >/dev/null \
  || fail "deterministic shared history conflict was not terminal failed"

# Role/action and compact-result identity are both fail-closed.
write_shared_marker 61 63 61 head 37 reused
wrong_action_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 61 63 61 head)" \
  "$(make_shared_reply 61 63 61 head 37)")" \
  || fail "wrong-action marker rejection failed"
jq -e '.reply.status == "blocked"' <<<"${wrong_action_resolution}" >/dev/null \
  || fail "shared head accepted mr_action=reused"

write_shared_marker 71 73 73 tail 47
forged_reply="$(make_shared_reply 71 73 73 tail 47 | jq -c \
  '.commit_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"')"
forged_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 71 73 73 tail)" "${forged_reply}")" \
  || fail "forged compact result rejection failed"
jq -e '
  .reply.status == "blocked"
  and (.reply.block_reason | contains("compact result"))
' <<<"${forged_resolution}" >/dev/null \
  || fail "shared callback selected a source SHA different from its marker"

# A fresh live read is mandatory. Unavailable reads retain the exact MR-only
# claim, while closed or identity-mismatched MRs are terminally rejected and
# can never publish `pr`.
write_shared_marker 75 77 75 head 49
LIVE_SHARED_MR_UNAVAILABLE=true
: >"${LABEL_LOG}"
live_unavailable_out="$(phase6_process \
  "$(make_shared_state 75 77 75 head)" \
  "$(make_shared_reply 75 77 75 head 49)" false)" \
  || fail "live shared MR unavailable path failed"
jq -e '
  .final_status == "blocked" and .mr_recovery_pending == true
  and .updated_state.pending_subagents["75"].mr_finalization_retry == true
' <<<"${live_unavailable_out}" >/dev/null \
  || fail "unavailable live MR read did not retain the exact recovery claim"
[ ! -s "${LABEL_LOG}" ] || fail "unavailable live MR read wrote labels"
LIVE_SHARED_MR_UNAVAILABLE=false

write_shared_marker 76 78 76 head 50 created false unknown unknown
LIVE_SHARED_MR_STATE=closed
closed_resolution="$(phase6_process \
  "$(make_shared_state 76 78 76 head)" \
  "$(make_shared_reply 76 78 76 head 50)" false)" \
  || fail "closed shared MR resolution failed"
jq -e '
  .final_status == "blocked"
  and .mr_recovery_pending != true
  and (.updated_state.pending_subagents["76"] // null) == null
  and (.updated_state.blocked_iids | index(76) != null)
' <<<"${closed_resolution}" >/dev/null \
  || fail "closed identity-only shared MR did not drain terminally"
LIVE_SHARED_MR_STATE=opened

write_shared_marker 79 80 79 head 51
LIVE_SHARED_MR_IDENTITY_MATCHES=false
retargeted_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 79 80 79 head)" \
  "$(make_shared_reply 79 80 79 head 51)")" \
  || fail "retargeted shared MR resolution failed"
jq -e '
  .reply.status == "blocked" and .completion_label == "preserve"
  and .recovery_pending == false
' <<<"${retargeted_resolution}" >/dev/null \
  || fail "retargeted shared MR was accepted"
LIVE_SHARED_MR_IDENTITY_MATCHES=true

# A non-private marker and a marker symlink are not authority.
write_shared_marker 81 83 81 head 57
chmod 644 \
  "${WORKTREES_ROOT}/issue-81/.req_executor/issue-81/log/execution-1/mr_result.json"
bad_mode_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 81 83 81 head)" \
  "$(make_shared_reply 81 83 81 head 57)")" \
  || fail "bad marker mode rejection failed"
jq -e '.reply.status == "blocked"' <<<"${bad_mode_resolution}" >/dev/null \
  || fail "mode-644 shared marker was trusted"

symlink_dir="${WORKTREES_ROOT}/issue-91/.req_executor/issue-91/log/execution-1"
mkdir -p "${symlink_dir}"
ln -s \
  "${WORKTREES_ROOT}/issue-41/.req_executor/issue-41/log/execution-1/mr_result.json" \
  "${symlink_dir}/mr_result.json"
symlink_resolution="$(phase6_resolve_shared_branch_mr \
  "$(make_shared_state 91 93 91 head)" \
  "$(make_shared_reply 91 93 91 head 67)")" \
  || fail "marker symlink rejection failed"
jq -e '.reply.status == "blocked"' <<<"${symlink_resolution}" >/dev/null \
  || fail "shared marker symlink was trusted"

# Ordinary non-auto-merge branches retain their existing marker-free behavior.
ordinary_state="$(jq -cn '{
  pending_subagents:{"101":{
    execution_id:1,child_session_key:"child",auto_merge:false,
    branch:"main",merge_target_branch:"main",work_branch:"issue/101"
  }},active_issue_iids:[101],active_issue_sessions:[],completed_iids:[],
  unfinished_iids:[],blocked_iids:[],failed_iids:[],timeout_iids:[],
  blocked_at_tick_by_iid:{},blocked_retry_limit:2,tick_seq:1,
  quota_completed_this_tick:0,campaign_status:"waiting_for_callbacks"
}')"
ordinary_reply="$(jq -cn '{
  iid:101,execution_id:1,status:"done",mode_actual:"fresh",
  work_branch:"issue/101",local_branch:"issue/101",
  commit_sha:"3333333333333333333333333333333333333333",
  merge_request_url:"https://gitlab.example.test/group/repo/-/merge_requests/77",
  mr_action:"created",wiki_url:"",labels_added:[],labels_removed:[],
  summary_posted:false,block_reason:"",log_dir:"/tmp/log",block_side:"cc"
}')"
: >"${LABEL_LOG}"
ordinary_out="$(phase6_process "${ordinary_state}" "${ordinary_reply}" false)" \
  || fail "ordinary marker-free Phase 6 call failed"
jq -e '.final_status == "done"' <<<"${ordinary_out}" >/dev/null \
  || fail "ordinary non-shared branch was forced through the shared marker gate"

echo "ok Phase 6 requires one exact verified MR identity for shared branches"
