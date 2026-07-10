#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-owner-lease.XXXXXX")"
FIXTURE_SKILL="${TEST_ROOT}/skill"
FIXTURE_SCRIPTS="${FIXTURE_SKILL}/scripts"
REPO_PARENT="${TEST_ROOT}/repos/group"
PROJECT_REPO="${REPO_PARENT}/project"
STATE_DIR="${PROJECT_REPO}/.req_executor/_dispatcher"
STATE_FILE="${STATE_DIR}/campaign_state.json"
CALL_LOG="${TEST_ROOT}/external-calls.log"

fail() {
  echo "$1" >&2
  exit 1
}

mkdir -p "${FIXTURE_SCRIPTS}" "${PROJECT_REPO}/.git" "${STATE_DIR}"
for name in dispatch_prepare_tick.sh _dispatch_lib.sh branch_utils.sh env_paths.sh; do
  cp "${SKILL_DIR}/scripts/${name}" "${FIXTURE_SCRIPTS}/${name}"
done

for name in reconcile.sh ensure_labels.sh clone_or_pull.sh; do
  cat >"${FIXTURE_SCRIPTS}/${name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0")" >>"${OWNER_TEST_CALL_LOG}"
if [ "$(basename "$0")" = "reconcile.sh" ]; then
  path="${DISPATCHER_LOG_DIR}/reconcile-20260710T000000Z.json"
  mkdir -p "${DISPATCHER_LOG_DIR}"
  jq -nc '[{iid:1,labels:["doing"],missing:false,is_closed_on_gitlab:false,
    is_done_on_gitlab:false,has_done_pr:false,needs_continue:false,
    has_retry:false,has_blocked:false,has_failed:false,has_timeout:false,
    user_reopened:false}]' >"${path}"
  printf '%s\n' "${path}"
fi
EOF
done
cat >"${FIXTURE_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'set_issue_label.sh\n' >>"${OWNER_TEST_CALL_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_SCRIPTS}"/*.sh
export OWNER_TEST_CALL_LOG="${CALL_LOG}"

scheduled_trigger() {
  cat <<EOF
RUN_SCHEDULED_ISSUE_CAMPAIGN
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
project=project
group=group
gitlab_token=fake-token
issue_iids=1
issue_min_iid=1
issue_max_iid=1
hourly_issue_quota=1
max_concurrent_subagents=1
max_runtime_minutes=300
blocked_retry_limit=3
blocked_cooldown_ticks=1
acpx_timeout_seconds=18000
branch=main
repo_path=${REPO_PARENT}
EOF
}

driven_trigger() {
  cat <<EOF
RUN_SCHEDULED_ISSUE_CAMPAIGN
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
dispatch_mode=driven_topup
driven_request_json={"owner_id":"driven-B","grants":[{"job_id":"job-2","batch_id":"batch-2","snapshot_index":0,"project":"group/project","iid":2,"branch":"main","entry_mode":"auto","force_rerun_pr":false}]}
project=project
group=group
gitlab_token=fake-token
issue_iids=2
issue_min_iid=2
issue_max_iid=2
hourly_issue_quota=1
max_concurrent_subagents=1
max_runtime_minutes=300
blocked_retry_limit=3
blocked_cooldown_ticks=1
acpx_timeout_seconds=18000
branch=main
repo_path=${REPO_PARENT}
EOF
}

write_owned_state() {
  local mode="$1" owner_id="$2" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg mode "${mode}" --arg owner_id "${owner_id}" --arg now "${now}" '{
    project:"project",branch:"main",issue_min_iid:1,issue_max_iid:1,
    hourly_issue_quota:1,max_runtime_minutes:300,blocked_retry_limit:3,
    blocked_cooldown_ticks:1,max_concurrent_subagents:1,stuck_after_minutes:332,
    acpx_timeout_seconds:18000,issue_iids_whitelist:[1],require_labels:[],
    require_labels_match:"or",tick_seq:2,active_issue_iids:[1],
    active_issue_sessions:["issue-project-1"],
    pending_subagents:{"1":{attempt_number:1,run_id:"run-1",
      child_session_key:"agent:child:one",spawned_at:$now,placeholder:false,
      acpx_timeout_seconds:18000}},blocked_at_tick_by_iid:{},unfinished_iids:[],
    completed_iids:[],blocked_iids:[],failed_iids:[],timeout_iids:[],
    campaign_status:"waiting_for_callbacks",quota_launched_this_tick:0,
    last_reconcile_evidence:null,
    dispatch_owner:{mode:$mode,owner_id:$owner_id,leased_at:$now},updated_at:$now
  }' >"${STATE_FILE}"
}

run_prepare() {
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
    bash "${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh"
}

write_owned_state driven driven-A
cp "${STATE_FILE}" "${TEST_ROOT}/driven-before.json"
SCHEDULED_OUT="$(scheduled_trigger | run_prepare)"
printf '%s' "${SCHEDULED_OUT}" | jq -e '
  .status == "busy_owned_by_driven" and .dispatch_entries == []
' >/dev/null || fail "scheduled tick must report busy_owned_by_driven"
cmp -s "${STATE_FILE}" "${TEST_ROOT}/driven-before.json" \
  || fail "scheduled conflict changed driven-owned campaign_state bytes"
[ ! -e "${CALL_LOG}" ] || fail "scheduled conflict called GitLab/clone/reconcile before owner rejection"

write_owned_state scheduled scheduled
cp "${STATE_FILE}" "${TEST_ROOT}/scheduled-before.json"
DRIVEN_OUT="$(driven_trigger | run_prepare)"
printf '%s' "${DRIVEN_OUT}" | jq -e '
  .status == "busy_owned_by_scheduled" and .dispatch_entries == []
' >/dev/null || fail "driven topup must report busy_owned_by_scheduled"
cmp -s "${STATE_FILE}" "${TEST_ROOT}/scheduled-before.json" \
  || fail "driven conflict changed scheduled-owned campaign_state bytes"
[ ! -e "${CALL_LOG}" ] || fail "driven conflict called GitLab/clone/reconcile before owner rejection"

echo "ok campaign owner lease rejects cross-owner mutation before external work"
