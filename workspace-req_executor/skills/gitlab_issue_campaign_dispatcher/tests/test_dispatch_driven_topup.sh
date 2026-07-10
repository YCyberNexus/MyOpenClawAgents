#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVEN_TOPUP="${SKILL_DIR}/scripts/dispatch_driven_topup.sh"

fail() {
  echo "$1" >&2
  exit 1
}

[ -f "${DRIVEN_TOPUP}" ] || fail "dispatch_driven_topup.sh is missing"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-driven-topup.XXXXXX")"
FIXTURE_SKILL="${TEST_ROOT}/skill"
FIXTURE_SCRIPTS="${FIXTURE_SKILL}/scripts"
FIXTURE_REFS="${FIXTURE_SKILL}/references"
CONFIG_DIR="${TEST_ROOT}/config"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_REPO="${REPO_PARENT}/group/project"
STATE_DIR="${PROJECT_REPO}/.req_executor/_dispatcher"
STATE_FILE="${STATE_DIR}/campaign_state.json"
ALLOC_LOG="${TEST_ROOT}/allocate.log"

mkdir -p "${FIXTURE_SCRIPTS}" "${FIXTURE_REFS}" "${CONFIG_DIR}" \
  "${BIN_DIR}" "${PROJECT_REPO}/.git" "${STATE_DIR}"

for name in dispatch_driven_topup.sh dispatch_prepare_tick.sh _dispatch_lib.sh \
  branch_utils.sh env_paths.sh resolve_driven_repo_path.sh; do
  cp "${SKILL_DIR}/scripts/${name}" "${FIXTURE_SCRIPTS}/${name}"
done
cp "${SKILL_DIR}/references/executor_prompt.md" "${FIXTURE_REFS}/executor_prompt.md"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.test.invalid
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=fake-token-must-not-enter-state
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${REPO_PARENT}
EXECUTOR_MAX_CONCURRENCY=2
EOF

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
path="${DISPATCHER_LOG_DIR}/reconcile-20260710T000000Z.json"
mkdir -p "${DISPATCHER_LOG_DIR}"
jq -nc '[
  {iid:1,labels:["doing"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:false,has_done_pr:false,needs_continue:false,
   has_retry:false,has_blocked:false,has_failed:false,has_timeout:false,
   user_reopened:false},
  {iid:2,labels:["todo"],missing:false,is_closed_on_gitlab:false,
   is_done_on_gitlab:false,has_done_pr:false,needs_continue:false,
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
source "${SCRIPT_DIR}/env_paths.sh"
mkdir -p "${WORKTREE_DIR}/.git" "${WORKTREE_DIR}/.claude" "${LOG_DIR}" "${OUTPUT_DIR}"
printf '%s\n%s\n' "${ISSUE_MODE}" "issue/${ISSUE_IID}-att$(printf '%03d' "${ATTEMPT_NUMBER}")"
EOF
cat >"${FIXTURE_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/build_prompt.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${BIN_DIR}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'/issues/2')
    jq -nc '{iid:2,title:"Issue two",description:"body",web_url:"https://gitlab.test/group/project/-/issues/2",labels:["todo"]}'
    ;;
  *)
    echo "unexpected glab invocation: $*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "${FIXTURE_SCRIPTS}"/*.sh "${BIN_DIR}/glab"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg now "${NOW}" '{
  project:"project",repo_path:"unused",branch:"main",
  issue_min_iid:1,issue_max_iid:1,hourly_issue_quota:2,
  max_runtime_minutes:300,blocked_retry_limit:3,blocked_cooldown_ticks:1,
  max_concurrent_subagents:2,stuck_after_minutes:332,acpx_timeout_seconds:18000,
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

GRANT='{"job_id":"job-2","batch_id":"batch-1","snapshot_index":0,"project":"group/project","iid":2,"branch":"main","entry_mode":"fresh","force_rerun_pr":false}'
VALID_REQUEST="$(jq -nc --argjson grant "${GRANT}" '{owner_id:"owner-A",grants:[$grant]}')"

assert_rejected() {
  local label="$1" request="$2"
  if printf '%s\n' "${request}" | CONFIG_DIR="${CONFIG_DIR}" \
    PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh" \
    PATH="${BIN_DIR}:${PATH}" TEST_ALLOC_LOG="${ALLOC_LOG}" \
    bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh" \
    >"${TEST_ROOT}/${label}.out" 2>"${TEST_ROOT}/${label}.err"; then
    fail "${label} request must be rejected"
  fi
  cmp -s "${STATE_FILE}" "${TEST_ROOT}/state-before-invalid.json" \
    || fail "${label} validation changed campaign state"
}

assert_rejected unknown_top "$(printf '%s' "${VALID_REQUEST}" | jq -c '.unexpected=true')"
assert_rejected unknown_grant "$(printf '%s' "${VALID_REQUEST}" | jq -c '.grants[0].unexpected=true')"
assert_rejected missing_owner "$(printf '%s' "${VALID_REQUEST}" | jq -c 'del(.owner_id)')"
assert_rejected missing_grant_field "$(printf '%s' "${VALID_REQUEST}" | jq -c 'del(.grants[0].job_id)')"
assert_rejected duplicate_iid "$(jq -nc --argjson grant "${GRANT}" \
  '{owner_id:"owner-A",grants:[$grant,($grant|.job_id="job-duplicate")]}')"
assert_rejected mixed_project "$(jq -nc --argjson grant "${GRANT}" \
  '{owner_id:"owner-A",grants:[$grant,($grant|.job_id="job-3"|.iid=3|.project="other/project")]}')"
assert_rejected control_character "$(jq -nc --argjson grant "${GRANT}" \
  '{owner_id:"owner\nA",grants:[$grant]}')"

export TEST_ALLOC_LOG="${ALLOC_LOG}"
OUTPUT="$(printf '%s\n' "${VALID_REQUEST}" | CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh" \
  PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh")"

printf '%s' "${OUTPUT}" | jq -e '
  .status == "ready"
  and (.dispatch_entries | length) == 1
  and .dispatch_entries[0].iid == 2
  and .dispatch_entries[0].attempt_number == 1
  and (.dispatch_entries[0].child_label | type == "string")
  and (.dispatch_entries[0].payload_path | type == "string")
  and .dispatch_entries[0].job_id == "job-2"
  and .dispatch_entries[0].batch_id == "batch-1"
  and .dispatch_entries[0].snapshot_index == 0
  and .scope_evicted_iids == []
' >/dev/null || fail "driven topup did not return exactly the granted IID with scheduler metadata"

PAYLOAD_PATH="$(printf '%s' "${OUTPUT}" | jq -r '.dispatch_entries[0].payload_path')"
[ -f "${PAYLOAD_PATH}" ] || fail "driven topup payload_path does not exist"
jq -e '
  (.pending_subagents | has("1"))
  and (.pending_subagents | has("2"))
  and .pending_subagents["1"].run_id == "old-run"
  and .issue_iids_whitelist == [1,2]
  and .dispatch_owner.mode == "driven"
  and .dispatch_owner.owner_id == "owner-A"
' "${STATE_FILE}" >/dev/null || fail "driven topup did not preserve pending IID 1 and add grant IID 2"
if grep -Fq 'fake-token-must-not-enter-state' "${STATE_FILE}"; then
  fail "GitLab token leaked into campaign state metadata"
fi
[ "$(cat "${ALLOC_LOG}")" = "2" ] || fail "topup must allocate only grant IID 2"

REPLAY="$(printf '%s\n' "${VALID_REQUEST}" | CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh" \
  PATH="${BIN_DIR}:${PATH}" bash "${FIXTURE_SCRIPTS}/dispatch_driven_topup.sh")"
printf '%s' "${REPLAY}" | jq -e '
  (.status == "waiting_for_callbacks" or .status == "no_eligible_iids")
  and .dispatch_entries == []
' >/dev/null || fail "same job/batch replay must not prepare an existing pending IID"
[ "$(cat "${ALLOC_LOG}")" = "2" ] || fail "same job/batch replay allocated IID 2 twice"
jq -e '.pending_subagents | has("2")' "${STATE_FILE}" >/dev/null \
  || fail "same job/batch replay must preserve the existing pending IID"

echo "ok driven topup preserves pending work and prepares grants only"
