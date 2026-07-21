#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/recover-shared-mr.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "${FIXTURE_SCRIPTS}" "${FAKE_BIN}"

fail() {
  echo "test_recover_shared_mr_finalization.sh: $*" >&2
  exit 1
}

# Keep the recovery entry point and the real MR finalizer together, as they are
# in deployment. Everything that could touch GitLab or Git is replaced below
# by a strict local fake; any unexpected Git mutation makes the test fail.
cp "${SKILL_DIR}/scripts/recover_shared_mr_finalization.sh" \
  "${FIXTURE_SCRIPTS}/recover_shared_mr_finalization.sh"
cp "${SKILL_DIR}/scripts/create_mr.sh" \
  "${FIXTURE_SCRIPTS}/create_mr.sh"

cat >"${FIXTURE_SCRIPTS}/archive_execution_logs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'archive:%s\n' "${EXECUTION_ID:?}" >>"${ARCHIVE_LOG:?}"
EOF

cat >"${FIXTURE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${RECOVERY_ISSUES_ROOT:?}" "${RECOVERY_WORK_ROOT:?}" \
  "${EXECUTION_ID:?}" "${LOG_DIR:?}"
export PROJECT_FULL='group/repo'
export PROJECT_URI='group%2Frepo'
export ISSUES_ROOT="${RECOVERY_ISSUES_ROOT}"
export WORK_ROOT="${RECOVERY_WORK_ROOT}"
export EXECUTION_ID
EOF

cat >"${FIXTURE_SCRIPTS}/git_network_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git_network_guard_assert_repo() {
  [ "$1" = "${WORKTREE_DIR:?}" ] || return 91
}
git_network_guard_run() {
  local repo="$1"
  shift
  printf '%s' "${repo}" >>"${GUARD_LOG:?}"
  printf ' %q' "$@" >>"${GUARD_LOG}"
  printf '\n' >>"${GUARD_LOG}"
  [ "$#" -eq 4 ] \
    && [ "$1" = ls-remote ] \
    && [ "$2" = --heads ] \
    && [ "$3" = origin ] \
    && [ "$4" = "${WORK_BRANCH:?}" ] || return 92
  printf '%s\trefs/heads/%s\n' "${REMOTE_TIP:?}" \
    "${REMOTE_REF_NAME:-${WORK_BRANCH}}"
}
EOF

cat >"${FIXTURE_SCRIPTS}/merge_mr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${MERGE_MR_MODE:?}" = attempt ]
[ "${AUTO_MERGE:?}" = false ]
[ "${MR_IID:?}" = 17 ]
[ "${WORK_BRANCH:?}" = 'issue/41+43' ]
[ "${MERGE_TARGET_BRANCH:?}" = main ]
[ "${COMMIT_SHA:?}" = '1111111111111111111111111111111111111111' ]
[ -z "${DEPENDENCY_BASE_SHA:-}" ]
jq -cn \
  --argjson iid "${MR_IID}" \
  --arg web_url "${MERGE_REQUEST_URL:?}" \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg dependency_base_sha "${DEPENDENCY_BASE_SHA:-}" \
  --arg sha "${COMMIT_SHA}" '{
    version:1,iid:$iid,web_url:$web_url,source_branch:$source_branch,
    target_branch:$target_branch,dependency_base_sha:$dependency_base_sha,
    sha:$sha,observed_state:"opened",outcome:"opened",verified:true,
    merge_attempted:false,merge_api_succeeded:false,
    reason:"auto_merge_disabled"
  }' | tee -a "${MERGE_LOG:?}"
EOF

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q' "$1" >>"${GIT_COMMAND_LOG:?}"
printf ' %q' "${@:2}" >>"${GIT_COMMAND_LOG}"
printf '\n' >>"${GIT_COMMAND_LOG}"
if [ "$#" -eq 5 ] \
    && [ "$1" = -C ] \
    && [ "$2" = "${WORKTREE_DIR:?}" ] \
    && [ "$3" = rev-parse ] \
    && [ "$4" = --verify ] \
    && [ "$5" = 'HEAD^{commit}' ]; then
  printf '%s\n' "${LOCAL_TIP:?}"
  exit 0
fi
echo "fake git rejected a non-read-only command" >&2
exit 97
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q' "$1" >>"${GLAB_LOG:?}"
printf ' %q' "${@:2}" >>"${GLAB_LOG}"
printf '\n' >>"${GLAB_LOG}"
if [ "$*" = 'api user' ]; then
  jq -cn '{username:"req-executor-bot"}'
  exit 0
fi
if [[ "$*" == api\ projects/group%2Frepo/merge_requests\?* ]]; then
  if [ "${FAKE_HISTORY_PAGE_MODE:-}" = hundred ]; then
    if [[ "$*" == *'&page=1' ]]; then
      jq -cn '[
        range(1;101) as $offset
        | {
            iid:(1000 + $offset),
            web_url:("https://gitlab.example.test/group/repo/-/merge_requests/"
              + ((1000 + $offset) | tostring)),
            source_branch:"issue/41+43",target_branch:"main",
            sha:"1111111111111111111111111111111111111111",state:"closed",
            author:{username:"req-executor-bot"},
            description:("Closes #41\nCloses #43\n"
              + "<!-- req_executor-shared-mr-intent:"
              + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->")
          }
      ]'
    else
      jq -cn '[]'
    fi
  else
    jq -cn --arg state "${FAKE_MR_STATE:-opened}" '[{
      iid:17,
      web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
      source_branch:"issue/41+43",target_branch:"main",
      sha:"1111111111111111111111111111111111111111",state:$state,
      author:{username:"req-executor-bot"},
      description:("Closes #41\nCloses #43\n"
        + "<!-- req_executor-shared-mr-intent:"
        + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->")
    }]'
  fi
  exit 0
fi
if [ "$*" = 'api projects/group%2Frepo/merge_requests/17' ]; then
  jq -cn --arg state "${FAKE_MR_STATE:-opened}" '{
    iid:17,
    web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
    source_branch:"issue/41+43",target_branch:"main",
    sha:"1111111111111111111111111111111111111111",state:$state,
    author:{username:"req-executor-bot"},
    description:("Closes #41\nCloses #43\n"
      + "<!-- req_executor-shared-mr-intent:"
      + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->")
  }'
  exit 0
fi
if [ "$#" -ge 2 ] && [ "$1" = mr ] && [ "$2" = list ]; then
  if [ "${FAKE_MR_STATE:-opened}" != opened ]; then
    jq -cn '[]'
    exit 0
  fi
  jq -cn '[{
    iid:17,
    web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
    source_branch:"issue/41+43",target_branch:"main",
    sha:"1111111111111111111111111111111111111111",state:"opened"
  }]'
  exit 0
fi
echo "fake glab rejected an MR mutation" >&2
exit 98
EOF

chmod +x "${FIXTURE_SCRIPTS}/recover_shared_mr_finalization.sh" \
  "${FIXTURE_SCRIPTS}/create_mr.sh" \
  "${FIXTURE_SCRIPTS}/archive_execution_logs.sh" \
  "${FIXTURE_SCRIPTS}/env_paths.sh" \
  "${FIXTURE_SCRIPTS}/git_network_guard.sh" \
  "${FIXTURE_SCRIPTS}/merge_mr.sh" \
  "${FAKE_BIN}/git" "${FAKE_BIN}/glab"

CHECKPOINT_SHA='1111111111111111111111111111111111111111'
MOVED_SHA='2222222222222222222222222222222222222222'

make_case() {
  local name="$1" work_branch_sha="${2:-${CHECKPOINT_SHA}}"
  CASE_ROOT="${TEST_ROOT}/${name}"
  CASE_ISSUES_ROOT="${CASE_ROOT}/issues"
  CASE_WORK_ROOT="${CASE_ROOT}/work-root"
  CASE_WORKTREE="${CASE_ROOT}/worktree"
  CASE_LOG_DIR="${CASE_ROOT}/attempt-log"
  CASE_ISSUE_STATE="${CASE_ROOT}/issue-state.json"
  CASE_EXECUTION_STATE="${CASE_ROOT}/attempt-state.json"
  CASE_GIT_LOG="${CASE_ROOT}/git.log"
  CASE_GUARD_LOG="${CASE_ROOT}/guard.log"
  CASE_GLAB_LOG="${CASE_ROOT}/glab.log"
  CASE_MERGE_LOG="${CASE_ROOT}/merge.log"
  CASE_ARCHIVE_LOG="${CASE_ROOT}/archive.log"
  CASE_STDERR="${CASE_ROOT}/stderr.log"
  mkdir -p "${CASE_ISSUES_ROOT}" "${CASE_WORK_ROOT}" \
    "${CASE_WORKTREE}" "${CASE_LOG_DIR}"
  : >"${CASE_GIT_LOG}"
  : >"${CASE_GUARD_LOG}"
  : >"${CASE_GLAB_LOG}"
  : >"${CASE_MERGE_LOG}"
  : >"${CASE_ARCHIVE_LOG}"

  jq -cn \
    --arg commit_sha "${CHECKPOINT_SHA}" \
    --arg work_branch_sha "${work_branch_sha}" '{
      iid:41,status:"doing",dependency_history_verified:true,
      dependency_pinned_execution_id:1,
      work_branch:"issue/41+43",branch_members:[41,43],
      shared_branch_role:"head",work_branch_sha:$work_branch_sha,
      dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
      mr_finalization:{
        status:"pending",source_execution_id:1,
        work_branch:"issue/41+43",branch_members:[41,43],
        shared_branch_role:"head",commit_sha:$commit_sha,
        intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        target_branch:"main"
      }
    }' >"${CASE_ISSUE_STATE}"
  jq -cn '{
    iid:41,execution_id:1,issue_title:"shared head recovery",
    mode_actual:"fresh",auto_merge:false,
    work_branch:"issue/41+43",branch_members:[41,43],
    shared_branch_role:"head",merge_target_branch:"main",
    expected_work_branch_sha:null,
    expected_commit_parent_sha:"3333333333333333333333333333333333333333",
    dependency_iid:null,dependency_branch:null,dependency_base_sha:null
  }' >"${CASE_EXECUTION_STATE}"
  chmod 600 "${CASE_ISSUE_STATE}" "${CASE_EXECUTION_STATE}"
}

run_case() {
  local remote_tip="$1" local_tip="$2"
  set +e
  CASE_STDOUT="$(
    PATH="${FAKE_BIN}:${PATH}" \
    RECOVERY_ISSUES_ROOT="${CASE_ISSUES_ROOT}" \
    RECOVERY_WORK_ROOT="${CASE_WORK_ROOT}" \
    ISSUE_IID=41 EXECUTION_ID=1 \
    ISSUE_STATE_FILE="${CASE_ISSUE_STATE}" \
    EXECUTION_STATE_FILE="${CASE_EXECUTION_STATE}" \
    WORK_BRANCH='issue/41+43' WORKTREE_DIR="${CASE_WORKTREE}" \
    LOG_DIR="${CASE_LOG_DIR}" \
    REMOTE_TIP="${remote_tip}" LOCAL_TIP="${local_tip}" \
    REMOTE_REF_NAME="${REMOTE_REF_NAME:-issue/41+43}" \
    GIT_COMMAND_LOG="${CASE_GIT_LOG}" GUARD_LOG="${CASE_GUARD_LOG}" \
    GLAB_LOG="${CASE_GLAB_LOG}" MERGE_LOG="${CASE_MERGE_LOG}" \
    ARCHIVE_LOG="${CASE_ARCHIVE_LOG}" \
    FAKE_MR_STATE="${FAKE_MR_STATE:-opened}" \
    FAKE_HISTORY_PAGE_MODE="${FAKE_HISTORY_PAGE_MODE:-}" \
      bash "${FIXTURE_SCRIPTS}/recover_shared_mr_finalization.sh" \
      2>"${CASE_STDERR}"
  )"
  CASE_RC=$?
  set -e
}

assert_no_mr_or_git_activity() {
  [ ! -s "${CASE_GIT_LOG}" ] || fail "$1 unexpectedly invoked git"
  [ ! -s "${CASE_GUARD_LOG}" ] || fail "$1 unexpectedly queried the remote"
  [ ! -s "${CASE_GLAB_LOG}" ] || fail "$1 unexpectedly entered the MR flow"
  [ ! -s "${CASE_MERGE_LOG}" ] || fail "$1 unexpectedly verified an MR"
  [ ! -s "${CASE_ARCHIVE_LOG}" ] || fail "$1 unexpectedly archived logs"
}

# A valid pending checkpoint may only read the fixed local/remote tips and then
# resume the exact MR flow. The fake command boundary rejects commit and push.
make_case valid
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
[ "${CASE_RC}" -eq 0 ] || fail "valid recovery failed: $(cat "${CASE_STDERR}")"
jq -e \
  --arg sha "${CHECKPOINT_SHA}" '
    .status == "verified_open"
    and .iid == 41 and .execution_id == 1
    and .commit_sha == $sha
    and .intent_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .merge_request_url ==
      "https://gitlab.example.test/group/repo/-/merge_requests/17"
    and .mr_action == "created"
  ' <<<"${CASE_STDOUT}" >/dev/null \
  || fail "valid recovery did not return the exact verified_open binding"
[ "$(wc -l <"${CASE_GIT_LOG}" | tr -d '[:space:]')" -eq 1 ] \
  || fail "valid recovery performed an unexpected number of local Git calls"
grep -Fx -- "-C ${CASE_WORKTREE} rev-parse --verify HEAD\^\{commit\}" \
  "${CASE_GIT_LOG}" >/dev/null \
  || fail "valid recovery performed a Git operation other than reading HEAD"
[ "$(wc -l <"${CASE_GUARD_LOG}" | tr -d '[:space:]')" -eq 1 ] \
  || fail "valid recovery performed an unexpected number of remote Git calls"
grep -F ' ls-remote --heads origin issue/41+43' "${CASE_GUARD_LOG}" >/dev/null \
  || fail "valid recovery did not fence the exact remote branch tip"
[ "$(wc -l <"${CASE_GLAB_LOG}" | tr -d '[:space:]')" -eq 6 ] \
  || fail "valid recovery did not perform the expected exact read-only MR checks"
if grep -E '^mr (create|close)( |$)' "${CASE_GLAB_LOG}" >/dev/null; then
  fail "valid recovery attempted to create, close, or mutate an MR"
fi
[ "$(wc -l <"${CASE_MERGE_LOG}" | tr -d '[:space:]')" -eq 1 ] \
  || fail "valid recovery did not perform one exact MR verification"
jq -e '
  .verified == true and .outcome == "opened"
  and .sha == "1111111111111111111111111111111111111111"
' "${CASE_LOG_DIR}/mr_result.json" >/dev/null \
  || fail "the MR flow did not persist a verified private marker"
[ "$(cat "${CASE_ARCHIVE_LOG}")" = 'archive:1' ] \
  || fail "valid recovery did not append the refreshed terminal log snapshot"

# Exactly 100 history rows means the first page is full, not that history is
# malformed. Recovery must request page 2, then persist terminal conflict
# evidence instead of leaking the current claim in pending forever.
make_case hundred-history
FAKE_HISTORY_PAGE_MODE=hundred
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
unset FAKE_HISTORY_PAGE_MODE
[ "${CASE_RC}" -eq 6 ] \
  || fail "100-row shared MR history returned rc=${CASE_RC}, expected 6"
grep -F 'page=1' "${CASE_GLAB_LOG}" >/dev/null \
  || fail "100-row shared MR history did not request page 1"
grep -F 'page=2' "${CASE_GLAB_LOG}" >/dev/null \
  || fail "100-row shared MR history did not request page 2"
jq -e '
  .verified == false and .outcome == "unknown"
  and .reason == "shared_mr_history_conflict"
  and .iid == 1001
' "${CASE_LOG_DIR}/mr_result.json" >/dev/null \
  || fail "100-row shared MR history did not persist terminal conflict evidence"
if grep -E '^mr (create|close)( |$)' "${CASE_GLAB_LOG}" >/dev/null; then
  fail "100-row shared MR history recovery mutated an MR"
fi

# Once the owned MR is closed, MR-only recovery must fail closed and must not
# create a replacement MR for the same shared source branch.
make_case closed-owned-mr
FAKE_MR_STATE=closed
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
unset FAKE_MR_STATE
[ "${CASE_RC}" -eq 6 ] \
  || fail "closed owned MR returned rc=${CASE_RC}, expected 6"
grep -F 'one owned shared MR is no longer exactly open' \
  "${CASE_STDERR}" >/dev/null \
  || fail "closed owned MR did not report the no-replacement fence"
if grep -E '^mr (create|close)( |$)' "${CASE_GLAB_LOG}" >/dev/null; then
  fail "closed owned MR recovery created or mutated a replacement MR"
fi
[ ! -s "${CASE_MERGE_LOG}" ] \
  || fail "closed owned MR reached exact-open verification"
jq -e '
  .verified == false and .outcome == "unknown"
  and .observed_state == "unknown"
  and .reason == "shared_mr_live_recheck_required"
  and .iid == 17
  and .web_url ==
    "https://gitlab.example.test/group/repo/-/merge_requests/17"
' "${CASE_LOG_DIR}/mr_result.json" >/dev/null \
  || fail "closed owned MR did not preserve exact identity evidence for Phase 6"

# A later fresh A attempt is not allowed to treat a deleted canonical branch
# as a new group. Any historical MR on the frozen source branch blocks a second
# create even outside the explicit MR-only recovery mode.
: >"${CASE_GLAB_LOG}"
set +e
PATH="${FAKE_BIN}:${PATH}" \
RECOVERY_ISSUES_ROOT="${CASE_ISSUES_ROOT}" \
RECOVERY_WORK_ROOT="${CASE_WORK_ROOT}" \
MR_ISSUES_ROOT="${CASE_ISSUES_ROOT}" \
ISSUE_IID=41 EXECUTION_ID=1 ISSUE_STATE_FILE="${CASE_ISSUE_STATE}" \
WORK_BRANCH='issue/41+43' WORKTREE_DIR="${CASE_WORKTREE}" \
LOG_DIR="${CASE_LOG_DIR}" ISSUE_MODE=fresh ISSUE_TITLE='fresh head retry' \
BRANCH=main MERGE_TARGET_BRANCH=main AUTO_MERGE=false \
COMMIT_SHA="${CHECKPOINT_SHA}" SHARED_MR_RECOVERY=false \
GLAB_LOG="${CASE_GLAB_LOG}" MERGE_LOG="${CASE_MERGE_LOG}" \
FAKE_MR_STATE=closed \
  bash "${FIXTURE_SCRIPTS}/create_mr.sh" \
  >/dev/null 2>"${CASE_ROOT}/fresh-after-closed.stderr"
fresh_after_closed_rc=$?
set -e
[ "${fresh_after_closed_rc}" -eq 6 ] \
  || fail "fresh head retry after closed MR returned rc=${fresh_after_closed_rc}"
grep -F 'shared branch history already exists' \
  "${CASE_ROOT}/fresh-after-closed.stderr" >/dev/null \
  || fail "fresh head retry did not report its historical-MR fence"
if grep -E '^mr (create|close)( |$)' "${CASE_GLAB_LOG}" >/dev/null; then
  fail "fresh head retry created a second MR after the first was closed"
fi

# A checkpoint inconsistent with the durable Issue state must fail before any
# Git or MR command runs.
make_case checkpoint-mismatch "${MOVED_SHA}"
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
[ "${CASE_RC}" -eq 2 ] \
  || fail "mismatched checkpoint returned rc=${CASE_RC}, expected 2"
grep -F 'checkpoint does not match the fixed execution' "${CASE_STDERR}" >/dev/null \
  || fail "mismatched checkpoint did not report the identity rejection"
assert_no_mr_or_git_activity 'mismatched checkpoint'

# Once either side of the fixed commit fence moves, recovery must stop before
# entering create_mr, even though the other side still matches.
make_case remote-moved
run_case "${MOVED_SHA}" "${CHECKPOINT_SHA}"
[ "${CASE_RC}" -eq 5 ] \
  || fail "moved remote tip returned rc=${CASE_RC}, expected 5"
grep -F 'shared branch moved after its recovery checkpoint' \
  "${CASE_STDERR}" >/dev/null \
  || fail "moved remote tip did not report the branch fence"
[ -s "${CASE_GIT_LOG}" ] && [ -s "${CASE_GUARD_LOG}" ] \
  || fail "moved remote tip was not compared with both fixed tips"
[ ! -s "${CASE_GLAB_LOG}" ] && [ ! -s "${CASE_MERGE_LOG}" ] \
  || fail "moved remote tip entered the MR flow"

make_case local-moved
run_case "${CHECKPOINT_SHA}" "${MOVED_SHA}"
[ "${CASE_RC}" -eq 5 ] \
  || fail "moved local HEAD returned rc=${CASE_RC}, expected 5"
grep -F 'shared branch moved after its recovery checkpoint' \
  "${CASE_STDERR}" >/dev/null \
  || fail "moved local HEAD did not report the branch fence"
[ ! -s "${CASE_GLAB_LOG}" ] && [ ! -s "${CASE_MERGE_LOG}" ] \
  || fail "moved local HEAD entered the MR flow"

# `git ls-remote` patterns also match ref suffixes. A colliding
# refs/heads/prefix/issue/41+43 row must not satisfy the canonical ref fence.
make_case suffix-collision
REMOTE_REF_NAME='prefix/issue/41+43'
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
unset REMOTE_REF_NAME
[ "${CASE_RC}" -eq 5 ] \
  || fail "suffix-collision ref returned rc=${CASE_RC}, expected 5"
grep -F 'exact shared remote ref is missing or ambiguous' \
  "${CASE_STDERR}" >/dev/null \
  || fail "suffix-collision ref did not report exact-ref rejection"
[ ! -s "${CASE_GIT_LOG}" ] \
  || fail "suffix-collision ref reached local HEAD verification"
[ ! -s "${CASE_GLAB_LOG}" ] && [ ! -s "${CASE_MERGE_LOG}" ] \
  || fail "suffix-collision ref entered the MR flow"

# State authority is limited to regular, current-UID, mode-600 files.
make_case public-state
chmod 644 "${CASE_ISSUE_STATE}"
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
[ "${CASE_RC}" -eq 2 ] \
  || fail "non-private state returned rc=${CASE_RC}, expected 2"
grep -F 'unsafe or invalid Issue state' "${CASE_STDERR}" >/dev/null \
  || fail "non-private state did not report the trust-boundary rejection"
assert_no_mr_or_git_activity 'non-private state'

make_case symlink-state
REAL_EXECUTION_STATE="${CASE_ROOT}/attempt-state-real.json"
mv "${CASE_EXECUTION_STATE}" "${REAL_EXECUTION_STATE}"
ln -s "${REAL_EXECUTION_STATE}" "${CASE_EXECUTION_STATE}"
run_case "${CHECKPOINT_SHA}" "${CHECKPOINT_SHA}"
[ "${CASE_RC}" -eq 2 ] \
  || fail "symlink state returned rc=${CASE_RC}, expected 2"
grep -F 'unsafe or invalid execution state' "${CASE_STDERR}" >/dev/null \
  || fail "symlink state did not report the trust-boundary rejection"
assert_no_mr_or_git_activity 'symlink state'

echo 'test_recover_shared_mr_finalization.sh: PASS'
