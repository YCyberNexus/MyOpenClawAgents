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
PROJECT_REPO="${REPO_PARENT}/group/project"
STATE_DIR="${PROJECT_REPO}/.req_executor/_dispatcher"
STATE_FILE="${STATE_DIR}/campaign_state.json"
ALLOC_LOG="${TEST_ROOT}/allocate.log"
PREP_LOG="${TEST_ROOT}/prepare.log"
LABEL_LOG="${TEST_ROOT}/labels.log"
GLAB_LOG="${TEST_ROOT}/glab.log"
TRIGGER_CAPTURE="${TEST_ROOT}/internal-trigger.txt"

mkdir -p "${FIXTURE_SCRIPTS}" "${FIXTURE_REFS}" "${CONFIG_DIR}" \
  "${BIN_DIR}" "${MODE_BIN}" "${PROJECT_REPO}"
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
git -C "${PROJECT_REPO}" symbolic-ref \
  refs/remotes/origin/HEAD refs/remotes/origin/main
mkdir -p "${STATE_DIR}"

for name in dispatch_driven_topup.sh dispatch_prepare_tick.sh _dispatch_lib.sh \
  branch_utils.sh env_paths.sh git_network_guard.sh glab_auth.sh \
  gitlab_env_resolver.sh \
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
source "${SCRIPT_DIR}/env_paths.sh"
mkdir -p "${WORKTREE_DIR}/.git" "${WORKTREE_DIR}/.claude" "${LOG_DIR}" "${OUTPUT_DIR}"
printf '%s\n%s\n' "${ISSUE_MODE}" "issue/${ISSUE_IID}-att$(printf '%03d' "${ATTEMPT_NUMBER}")"
EOF
cat >"${FIXTURE_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${ISSUE_IID}" "$*" >>"${TEST_LABEL_LOG}"
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/build_prompt.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FIXTURE_SCRIPTS}/capture_prepare_tick.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${GITLAB_TOKEN:-}" = "fake-token-direct" ] || exit 91
cat >"${TEST_TRIGGER_CAPTURE}"
jq -nc '{status:"no_eligible_iids",dispatch_entries:[],chat_summary:"capture_only"}'
EOF
cat >"${BIN_DIR}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'/issues/2') iid=2; labels='["blocked-dispatcher"]' ;;
  *'/issues/3') iid=3; labels='["blocked-dispatcher"]' ;;
  *'/issues/6') iid=6; labels='["pr","continue"]' ;;
  *)
    echo "unexpected glab invocation: $*" >&2
    exit 97
    ;;
esac
printf '%s\n' "${iid}" >>"${TEST_GLAB_LOG}"
jq -nc --argjson iid "${iid}" --argjson labels "${labels}" \
  '{iid:$iid,title:("Issue " + ($iid|tostring)),description:"body",
    web_url:("https://gitlab.test/group/project/-/issues/" + ($iid|tostring)),labels:$labels}'
EOF
chmod +x "${FIXTURE_SCRIPTS}"/*.sh "${BIN_DIR}/glab"

export TEST_ALLOC_LOG="${ALLOC_LOG}"
export TEST_PREP_LOG="${PREP_LOG}"
export TEST_LABEL_LOG="${LABEL_LOG}"
export TEST_GLAB_LOG="${GLAB_LOG}"

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
  {"job_id":"job-3","batch_id":"batch-A","snapshot_index":1,"project":"group/project","iid":3,"branch":"release/explicit","entry_mode":"continue","force_rerun_pr":false},
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
done

jq -e '
  (.pending_subagents | keys | map(tonumber) | sort) == [1,2,3,6]
  and .pending_subagents["1"].run_id == "old-run"
  and (all(.pending_subagents | to_entries[] | select(.key != "1");
    .value.memberships_source == "scheduler_active_job"))
  and .issue_iids_whitelist == [1,2,3,4,5,6]
  and .dispatch_owner == (.dispatch_owner | select(.mode == "driven" and .owner_id == "owner-A"))
' "${STATE_FILE}" >/dev/null || fail "driven topup pending state froze skips or omitted scheduler membership source"

[ "$(cat "${ALLOC_LOG}")" = $'2\n3\n6' ] \
  || fail "topup must allocate only executable grant IIDs 2, 3, and 6"
[ "$(cat "${PREP_LOG}")" = $'2|main|fresh\n3|release/explicit|continue\n6|main|fresh' ] \
  || fail "null/default branch, explicit branch, entry_mode, or force fresh semantics were not applied"
[ "$(cat "${GLAB_LOG}")" = $'2\n3\n6' ] \
  || fail "skipped grants reached live issue prep"
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

echo "ok driven topup filters live skips and preserves scheduler job identity"
