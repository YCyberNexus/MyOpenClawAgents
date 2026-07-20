#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-dependency-cursor.XXXXXX")"
FIXTURE_SKILL="${TEST_ROOT}/skill"
FIXTURE_SCRIPTS="${FIXTURE_SKILL}/scripts"
FIXTURE_REFS="${FIXTURE_SKILL}/references"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PARENT="${TEST_ROOT}/repos/group"
PROJECT_REPO="${REPO_PARENT}/project"
STATE_FILE="${PROJECT_REPO}/.req_executor/_dispatcher/campaign_state.json"
GLAB_LOG="${TEST_ROOT}/glab.log"
ALLOC_LOG="${TEST_ROOT}/allocate.log"

mkdir -p "${FIXTURE_SCRIPTS}" "${FIXTURE_REFS}" "${BIN_DIR}" \
  "${PROJECT_REPO}"
for name in \
  dispatch_prepare_tick.sh \
  _dispatch_lib.sh \
  branch_utils.sh \
  env_paths.sh \
  git_network_guard.sh \
  parse_issue_dependency.sh; do
  cp "${SKILL_DIR}/scripts/${name}" "${FIXTURE_SCRIPTS}/${name}"
done
cp "${SKILL_DIR}/references/executor_prompt.md" \
  "${FIXTURE_REFS}/executor_prompt.md"

git -C "${PROJECT_REPO}" init -q
git -C "${PROJECT_REPO}" config user.email \
  "req-executor-test@example.invalid"
git -C "${PROJECT_REPO}" config user.name "req-executor-test"
git -C "${PROJECT_REPO}" commit --allow-empty -m "fixture root" >/dev/null
git -C "${PROJECT_REPO}" symbolic-ref \
  refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "${PROJECT_REPO}" update-ref refs/remotes/origin/main HEAD

cat >"${FIXTURE_SCRIPTS}/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${DISPATCHER_LOG_DIR}/reconcile-20260719T000000Z.json"
mkdir -p "${DISPATCHER_LOG_DIR}"
jq -n '[range(1; 52) | {
  iid:., labels:[], missing:false, is_closed_on_gitlab:false,
  is_done_on_gitlab:false, has_done_pr:false, has_finish:false,
  needs_continue:false, has_retry:false, has_blocked:false,
  has_failed:false, has_timeout:false, user_reopened:false
}]' >"${path}"
printf '%s\n' "${path}"
EOF

for name in ensure_labels.sh clone_or_pull.sh set_issue_label.sh build_prompt.sh; do
  cat >"${FIXTURE_SCRIPTS}/${name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
done

cat >"${FIXTURE_SCRIPTS}/allocate_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${IID}" >>"${DEPENDENCY_CURSOR_ALLOC_LOG}"
printf '1\n'
EOF

cat >"${FIXTURE_SCRIPTS}/prepare_attempt.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
mkdir -p "${WORKTREE_DIR}/.claude" "${LOG_DIR}" "${OUTPUT_DIR}"
printf 'fresh\nissue/%s\n' "${ISSUE_IID}"
EOF

cat >"${BIN_DIR}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$*"
iid="${request##*/issues/}"
case "${iid}" in
  ''|*[!0-9]*)
    echo "unexpected glab invocation: ${request}" >&2
    exit 97
    ;;
esac
printf '%s\n' "${iid}" >>"${DEPENDENCY_CURSOR_GLAB_LOG}"
if [ "${iid}" -ge 1 ] && [ "${iid}" -le 50 ]; then
  description="Depends on #$((iid + 100))"
else
  description='independent issue'
fi
jq -nc \
  --argjson iid "${iid}" \
  --arg description "${description}" \
  '{iid:$iid,title:("Issue " + ($iid | tostring)),description:$description,
    web_url:("https://gitlab.test.invalid/group/project/-/issues/" +
      ($iid | tostring)),labels:[],state:"opened"}'
EOF

chmod +x "${FIXTURE_SCRIPTS}"/*.sh "${BIN_DIR}/glab"
export DEPENDENCY_CURSOR_GLAB_LOG="${GLAB_LOG}"
export DEPENDENCY_CURSOR_ALLOC_LOG="${ALLOC_LOG}"

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
issue_min_iid=1
issue_max_iid=151
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

run_prepare() {
  GITLAB_TOKEN=fake-token \
    GITLAB_HOST=gitlab.test.invalid \
    GITLAB_API_PROTOCOL=https \
    PATH="${BIN_DIR}:${PATH}" \
    bash "${FIXTURE_SCRIPTS}/dispatch_prepare_tick.sh"
}

: >"${GLAB_LOG}"
: >"${ALLOC_LOG}"
FIRST_TICK="$(scheduled_trigger | run_prepare)"
printf '%s' "${FIRST_TICK}" | jq -e '
  .status == "no_eligible_iids"
  and .dispatch_entries == []
  and (.dependency_waiting | length) == 50
  and [.dependency_waiting[].iid] == [range(1; 51)]
  and (all(.dependency_waiting[];
    .dependency_iid == (.iid + 100)
    and .branch == ("issue/" + ((.iid + 100) | tostring) + "+" + (.iid | tostring))
    and .reason == "dependency_not_completed"))
' >/dev/null || fail "first tick did not defer exactly the first 50 dependency waiters"
[ ! -s "${ALLOC_LOG}" ] \
  || fail "first tick allocated an attempt despite finding no runnable Issue"
jq -e '
  .dependency_scan_cursor_iid == 51
  and .unfinished_iids == [range(1; 51)]
  and .pending_subagents == {}
' "${STATE_FILE}" >/dev/null \
  || fail "first tick did not persist cursor 51 and all waiting IIDs"

: >"${GLAB_LOG}"
SECOND_TICK="$(scheduled_trigger | run_prepare)"
printf '%s' "${SECOND_TICK}" | jq -e '
  .status == "ready"
  and [.dispatch_entries[].iid] == [51]
  and .dependency_waiting == []
' >/dev/null \
  || fail "second tick did not rotate to and select runnable IID 51"
[ "$(cat "${ALLOC_LOG}")" = 51 ] \
  || fail "only runnable IID 51 should consume an attempt"
jq -e '
  .dependency_scan_cursor_iid == null
  and (.pending_subagents | has("51"))
  and .next_new_issue_iid == 52
' "${STATE_FILE}" >/dev/null \
  || fail "successful rotated selection did not reset the cursor and persist IID 51"

echo "ok scheduled dependency preflight cursor prevents starvation past 50 waiters"
