#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "test_shared_dependency_branch.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-shared-branch.XXXXXX")"

# A dependency chain A -> C publishes both issues through one canonical work
# branch. The physical worktree and fixed local issue branch must nevertheless
# remain owned by the currently executing IID C.
REPO_PARENT="${TEST_ROOT}/repos"
mkdir -p "${REPO_PARENT}"
paths_out="$(
  PROJECT=repo GROUP=group REPO_PARENT_PATH="${REPO_PARENT}" \
    ISSUE_IID=43 EXECUTION_ID=7 WORK_BRANCH='issue/41+43' \
    GITLAB_HOST='local-gitlab.invalid:9443' GITLAB_API_PROTOCOL=https \
    GITLAB_TOKEN=test-token REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS='local-gitlab.invalid:9443' \
    bash -c 'source "$1"; printf "%s\n%s\n%s\n" \
      "${WORK_BRANCH}" "${LOCAL_ISSUE_BRANCH}" "${WORKTREE_DIR}"' \
      _ "${SKILL_DIR}/scripts/env_paths.sh"
)"
[ "$(printf '%s\n' "${paths_out}" | sed -n '1p')" = 'issue/41+43' ] \
  || fail "env_paths did not preserve the shared canonical work branch"
[ "$(printf '%s\n' "${paths_out}" | sed -n '2p')" = 'issue/43' ] \
  || fail "the local issue branch was not owned by the current IID"
case "$(printf '%s\n' "${paths_out}" | sed -n '3p')" in
  */.req_executor/.worktrees/issue-43) ;;
  *) fail "the worktree path was not isolated by the current IID" ;;
esac

# The tail issue in a shared chain must keep the one existing open MR. Rotating
# it would close the MR that represents the whole A -> C chain and create a
# second review identity for the same canonical branch.
MR_ROOT="${TEST_ROOT}/mr"
MR_SCRIPTS="${MR_ROOT}/scripts"
MR_BIN="${MR_ROOT}/bin"
MR_WORKTREE="${MR_ROOT}/worktree"
MR_LOG_DIR="${MR_ROOT}/log"
MR_ISSUES_ROOT="${MR_ROOT}/issues"
MR_TAIL_STATE="${MR_ISSUES_ROOT}/issue-43/state.json"
GLAB_LOG="${MR_ROOT}/glab.log"
mkdir -p "${MR_SCRIPTS}" "${MR_BIN}" "${MR_WORKTREE}" \
  "${MR_LOG_DIR}" "${MR_ISSUES_ROOT}/issue-41"
cp "${SKILL_DIR}/scripts/create_mr.sh" "${MR_SCRIPTS}/create_mr.sh"

cat >"${MR_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PROJECT_FULL='group/repo'
export PROJECT_URI='group%2Frepo'
export ISSUES_ROOT="${MR_ISSUES_ROOT:?}"
export WORK_ROOT="${MR_ISSUES_ROOT}/_locks"
mkdir -p "${WORK_ROOT}"
EOF

jq -n '{
  iid:41,status:"done",commit_sha:"1111111111111111111111111111111111111111",
  work_branch:"issue/41+43",branch_members:[41,43],shared_branch_role:"head",
  work_branch_sha:"1111111111111111111111111111111111111111",
  dependency_history_verified:true,
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
  merge_request_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
  mr_finalization:{
    status:"verified_open",source_execution_id:1,
    work_branch:"issue/41+43",branch_members:[41,43],
    shared_branch_role:"head",
    commit_sha:"1111111111111111111111111111111111111111",
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main",iid:17,
    web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
    mr_action:"created",verified_at:"2026-07-19T00:00:00Z"
  }
}' >"${MR_ISSUES_ROOT}/issue-41/state.json"
chmod 600 "${MR_ISSUES_ROOT}/issue-41/state.json"
mkdir -p "${MR_ISSUES_ROOT}/issue-43"
jq -n '{
  iid:43,status:"doing",commit_sha:"2222222222222222222222222222222222222222",
  work_branch:"issue/41+43",branch_members:[41,43],shared_branch_role:"tail",
  work_branch_sha:"2222222222222222222222222222222222222222",
  dependency_history_verified:true,dependency_pinned_execution_id:7,
  dependency_iid:41,dependency_branch:"issue/41+43",
  dependency_base_sha:"1111111111111111111111111111111111111111",
  mr_finalization:{
    status:"pending",source_execution_id:7,
    work_branch:"issue/41+43",branch_members:[41,43],
    shared_branch_role:"tail",
    commit_sha:"2222222222222222222222222222222222222222",
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main"
  }
}' >"${MR_TAIL_STATE}"
chmod 600 "${MR_TAIL_STATE}"

cat >"${MR_SCRIPTS}/merge_mr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn \
  --argjson iid 17 \
  --arg web_url 'https://gitlab.example.test/group/repo/-/merge_requests/17' \
  --arg source_branch "${WORK_BRANCH:?}" \
  --arg target_branch "${MERGE_TARGET_BRANCH:?}" \
  --arg dependency_base_sha "${DEPENDENCY_BASE_SHA:-}" \
  --arg sha "${COMMIT_SHA:?}" \
  --argjson verified "${MR_VERIFIED:-true}" '{
    version:1,
    iid:$iid,
    web_url:$web_url,
    source_branch:$source_branch,
    target_branch:$target_branch,
    dependency_base_sha:$dependency_base_sha,
    sha:$sha,
    observed_state:"opened",
    outcome:"opened",
    verified:$verified,
    merge_attempted:false,
    merge_api_succeeded:false,
    reason:"auto_merge_disabled"
  }'
EOF

cat >"${MR_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GLAB_LOG:?}"
case "${1:-} ${2:-}" in
  'api user')
    jq -cn '{username:"req-executor-bot"}'
    ;;
  'api projects/group%2Frepo/merge_requests/17')
    intent_id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    [ "${FAKE_FOREIGN_MR_INTENT:-false}" != true ] \
      || intent_id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    jq -cn --arg intent_id "${intent_id}" '{
      iid:17,
      web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
      source_branch:"issue/41+43",target_branch:"main",
      sha:"2222222222222222222222222222222222222222",state:"opened",
      author:{username:"req-executor-bot"},
      description:("Closes #41\nCloses #43\n"
        + "<!-- req_executor-shared-mr-intent:"
        + $intent_id + " -->")
    }'
    ;;
  'mr list')
    if [ "${FAKE_DUPLICATE_OPEN_MR:-false}" = true ]; then
      jq -cn '[
        {
          iid:17,
          web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
          source_branch:"issue/41+43",target_branch:"main",
          sha:"2222222222222222222222222222222222222222",
          state:"opened"
        },
        {
          iid:18,
          web_url:"https://gitlab.example.test/group/repo/-/merge_requests/18",
          source_branch:"issue/41+43",target_branch:"main",
          sha:"2222222222222222222222222222222222222222",
          state:"opened"
        }
      ]'
    else
      jq -cn '[{
        iid:17,
        web_url:"https://gitlab.example.test/group/repo/-/merge_requests/17",
        source_branch:"issue/41+43",
        target_branch:"main",
        sha:"2222222222222222222222222222222222222222",
        state:"opened"
      }]'
    fi
    ;;
  'mr close'|'mr create') exit 0 ;;
  *) exit 90 ;;
esac
EOF
chmod +x "${MR_SCRIPTS}/env_paths.sh" "${MR_SCRIPTS}/merge_mr.sh" \
  "${MR_BIN}/glab"

mr_out="$(
  PATH="${MR_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
    MR_ISSUES_ROOT="${MR_ISSUES_ROOT}" \
    ISSUE_STATE_FILE="${MR_TAIL_STATE}" \
    PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=7 \
    EXECUTION_ID=007 ISSUE_MODE=fresh ISSUE_TITLE='shared tail' \
    WORKTREE_DIR="${MR_WORKTREE}" LOG_DIR="${MR_LOG_DIR}" \
    BRANCH=main MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/41+43' \
    DEPENDENCY_IID=41 DEPENDENCY_BRANCH='issue/41+43' \
    DEPENDENCY_BASE_SHA=1111111111111111111111111111111111111111 \
    AUTO_MERGE=false COMMIT_SHA=2222222222222222222222222222222222222222 \
    bash "${MR_SCRIPTS}/create_mr.sh"
)" || fail "create_mr failed while reusing the shared branch MR"

[ "${mr_out}" = 'https://gitlab.example.test/group/repo/-/merge_requests/17
reused
17
opened' ] || fail "create_mr did not report the reused shared MR identity: ${mr_out}"
if grep -Eq '^mr (close|create)( |$)' "${GLAB_LOG}"; then
  fail "create_mr mutated MR identity instead of reusing the unique open MR"
fi
jq -e '
  .iid == 17 and .issue_iid == 43 and .execution_id == 7
  and .mr_action == "reused" and .source_branch == "issue/41+43"
  and .target_branch == "main" and .outcome == "opened"
' "${MR_LOG_DIR}/mr_result.json" >/dev/null \
  || fail "the reused MR identity was not persisted"

# A duplicate open MR is deterministic conflict evidence. The tail must not
# downgrade it to an identity-only live recheck that could approve MR !17 while
# silently ignoring MR !18.
: >"${GLAB_LOG}"
set +e
PATH="${MR_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  FAKE_DUPLICATE_OPEN_MR=true MR_ISSUES_ROOT="${MR_ISSUES_ROOT}" \
  ISSUE_STATE_FILE="${MR_TAIL_STATE}" \
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=7 \
  EXECUTION_ID=007 ISSUE_MODE=fresh ISSUE_TITLE='shared tail' \
  WORKTREE_DIR="${MR_WORKTREE}" LOG_DIR="${MR_LOG_DIR}" \
  BRANCH=main MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/41+43' \
  DEPENDENCY_IID=41 DEPENDENCY_BRANCH='issue/41+43' \
  DEPENDENCY_BASE_SHA=1111111111111111111111111111111111111111 \
  AUTO_MERGE=false COMMIT_SHA=2222222222222222222222222222222222222222 \
  bash "${MR_SCRIPTS}/create_mr.sh" >/dev/null \
    2>"${MR_ROOT}/duplicate-open.stderr"
duplicate_open_rc=$?
set -e
[ "${duplicate_open_rc}" -eq 6 ] \
  || fail "shared tail duplicate MRs returned rc=${duplicate_open_rc}, expected 6"
jq -e '
  .verified == false
  and .reason == "shared_mr_history_conflict"
  and .iid == 17 and .mr_action == "reused"
' "${MR_LOG_DIR}/mr_result.json" >/dev/null \
  || fail "shared tail duplicate MRs did not persist terminal conflict evidence"
if grep -Eq '^mr (close|create)( |$)' "${GLAB_LOG}"; then
  fail "shared tail duplicate rejection mutated an MR"
fi

: >"${GLAB_LOG}"
set +e
PATH="${MR_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" MR_VERIFIED=false \
  MR_ISSUES_ROOT="${MR_ISSUES_ROOT}" \
  ISSUE_STATE_FILE="${MR_TAIL_STATE}" \
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=7 \
  EXECUTION_ID=007 ISSUE_MODE=fresh ISSUE_TITLE='shared tail' \
  WORKTREE_DIR="${MR_WORKTREE}" LOG_DIR="${MR_LOG_DIR}" \
  BRANCH=main MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/41+43' \
  DEPENDENCY_IID=41 DEPENDENCY_BRANCH='issue/41+43' \
  DEPENDENCY_BASE_SHA=1111111111111111111111111111111111111111 \
  AUTO_MERGE=false COMMIT_SHA=2222222222222222222222222222222222222222 \
  bash "${MR_SCRIPTS}/create_mr.sh" >/dev/null 2>&1
unverified_shared_mr_rc=$?
set -e
[ "${unverified_shared_mr_rc}" -ne 0 ] \
  || fail "shared tail accepted an unverified opened MR"
if grep -Eq '^mr (close|create)( |$)' "${GLAB_LOG}"; then
  fail "unverified shared MR rejection performed an MR mutation"
fi

: >"${GLAB_LOG}"
set +e
PATH="${MR_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  FAKE_FOREIGN_MR_INTENT=true MR_ISSUES_ROOT="${MR_ISSUES_ROOT}" \
  ISSUE_STATE_FILE="${MR_TAIL_STATE}" \
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=7 \
  EXECUTION_ID=007 ISSUE_MODE=fresh ISSUE_TITLE='shared tail' \
  WORKTREE_DIR="${MR_WORKTREE}" LOG_DIR="${MR_LOG_DIR}" \
  BRANCH=main MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/41+43' \
  DEPENDENCY_IID=41 DEPENDENCY_BRANCH='issue/41+43' \
  DEPENDENCY_BASE_SHA=1111111111111111111111111111111111111111 \
  AUTO_MERGE=false COMMIT_SHA=2222222222222222222222222222222222222222 \
  bash "${MR_SCRIPTS}/create_mr.sh" >/dev/null 2>&1
foreign_intent_rc=$?
set -e
[ "${foreign_intent_rc}" -eq 6 ] \
  || fail "shared tail adopted an MR without the group's exact ownership intent"
if grep -Eq '^mr (close|create)( |$)' "${GLAB_LOG}"; then
  fail "foreign-intent shared MR rejection performed an MR mutation"
fi

MR_HEAD_STATE_TMP="$(mktemp "${MR_ISSUES_ROOT}/issue-41/state.invalid.XXXXXX")"
jq '.merge_request_url =
  "https://gitlab.example.test/group/repo/-/merge_requests/18"' \
  "${MR_ISSUES_ROOT}/issue-41/state.json" >"${MR_HEAD_STATE_TMP}"
mv "${MR_HEAD_STATE_TMP}" "${MR_ISSUES_ROOT}/issue-41/state.json"
set +e
PATH="${MR_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  MR_ISSUES_ROOT="${MR_ISSUES_ROOT}" \
  ISSUE_STATE_FILE="${MR_TAIL_STATE}" \
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=7 \
  EXECUTION_ID=007 ISSUE_MODE=fresh ISSUE_TITLE='shared tail' \
  WORKTREE_DIR="${MR_WORKTREE}" LOG_DIR="${MR_LOG_DIR}" \
  BRANCH=main MERGE_TARGET_BRANCH=main WORK_BRANCH='issue/41+43' \
  DEPENDENCY_IID=41 DEPENDENCY_BRANCH='issue/41+43' \
  DEPENDENCY_BASE_SHA=1111111111111111111111111111111111111111 \
  AUTO_MERGE=false COMMIT_SHA=2222222222222222222222222222222222222222 \
  bash "${MR_SCRIPTS}/create_mr.sh" >/dev/null 2>&1
foreign_mr_rc=$?
set -e
[ "${foreign_mr_rc}" -eq 2 ] \
  || fail "shared tail did not reject A's mismatched durable MR binding"
if grep -Eq '^mr (close|create)( |$)' "${GLAB_LOG}"; then
  fail "foreign shared MR rejection performed an MR mutation"
fi

# A shared remote branch can move because another IID owns the same canonical
# ref. The push must therefore lease against the SHA captured by planning, not
# against an implicit value observed again at push time.
PUSH_ROOT="${TEST_ROOT}/push"
PUSH_SCRIPTS="${PUSH_ROOT}/scripts"
PUSH_BIN="${PUSH_ROOT}/bin"
PUSH_WORKTREE="${PUSH_ROOT}/worktree"
GIT_LOG="${PUSH_ROOT}/git.log"
EXPECTED_LEASE_SHA=1111111111111111111111111111111111111111
EXPECTED_PARENT_SHA=2222222222222222222222222222222222222222
mkdir -p "${PUSH_SCRIPTS}" "${PUSH_BIN}" "${PUSH_WORKTREE}"
cp "${SKILL_DIR}/scripts/commit_and_push.sh" "${PUSH_SCRIPTS}/commit_and_push.sh"

cat >"${PUSH_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
:
EOF

cat >"${PUSH_SCRIPTS}/git_network_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git_network_guard_assert_repo() { :; }
git_network_guard_run() {
  shift
  printf 'guarded' >>"${GIT_LOG:?}"
  printf ' %q' "$@" >>"${GIT_LOG}"
  printf '\n' >>"${GIT_LOG}"
  case "${1:-}" in
    ls-remote)
      remote_sha="${EXPECTED_WORK_BRANCH_SHA:?}"
      if [ "${PUSH_ACCEPTED:-false}" = true ]; then
        remote_sha="${REMOTE_AFTER_PUSH_SHA:-4444444444444444444444444444444444444444}"
      fi
      printf '%s\trefs/heads/%s\n' \
        "${remote_sha}" "${WORK_BRANCH:?}"
      ;;
    push)
      PUSH_ACCEPTED=true
      export PUSH_ACCEPTED
      if [ "${SIMULATE_ACCEPTED_PUSH_ERROR:-false}" = true ] \
          && [ "${PUSH_ERROR_RETURNED:-false}" != true ]; then
        PUSH_ERROR_RETURNED=true
        export PUSH_ERROR_RETURNED
        return 73
      fi
      ;;
    *) return 91 ;;
  esac
}
EOF

cat >"${PUSH_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git' >>"${GIT_LOG:?}"
printf ' %q' "$@" >>"${GIT_LOG}"
printf '\n' >>"${GIT_LOG}"
while [ "${1:-}" = -c ]; do
  shift 2
done
case "${1:-}" in
  commit) ;;
  rev-list)
    printf '%s %s\n' \
      '4444444444444444444444444444444444444444' \
      "${EXPECTED_COMMIT_PARENT_SHA:?}"
    ;;
  rev-parse)
    printf '%s\n' '4444444444444444444444444444444444444444'
    ;;
  *) exit 92 ;;
esac
EOF
chmod +x "${PUSH_SCRIPTS}/env_paths.sh" \
  "${PUSH_SCRIPTS}/git_network_guard.sh" "${PUSH_BIN}/git"

push_out="$(
  PATH="${PUSH_BIN}:${PATH}" GIT_LOG="${GIT_LOG}" \
    PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=7 \
    EXECUTION_ID=007 ISSUE_TITLE='shared tail' \
    WORKTREE_DIR="${PUSH_WORKTREE}" LOCAL_ISSUE_BRANCH='issue/43' \
    WORK_BRANCH='issue/41+43' EXPECTED_WORK_BRANCH_SHA="${EXPECTED_LEASE_SHA}" \
    EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_PARENT_SHA}" \
    bash "${PUSH_SCRIPTS}/commit_and_push.sh"
)" || fail "commit_and_push rejected the explicit shared-branch lease"
[ "${push_out}" = 4444444444444444444444444444444444444444 ] \
  || fail "commit_and_push did not return the new commit SHA"
grep -Fq -- \
  "--force-with-lease=refs/heads/issue/41+43:${EXPECTED_LEASE_SHA}" \
  "${GIT_LOG}" \
  || fail "push did not use the exact planning-time expected SHA lease"
grep -Fq \
  '4444444444444444444444444444444444444444:refs/heads/issue/41+43' \
  "${GIT_LOG}" \
  || fail "push did not publish the immutable captured commit to the canonical ref"
if grep -Fq 'issue/43:issue/41+43' "${GIT_LOG}"; then
  fail "push still trusted the mutable IID-local attempt ref"
fi
grep -Fq -- '-c core.hooksPath=/dev/null -c commit.gpgSign=false commit' \
  "${GIT_LOG}" \
  || fail "commit did not disable repository hooks and commit signing"
if grep -Eq '(^| )--force-with-lease( |$)' "${GIT_LOG}"; then
  fail "push used an implicit force-with-lease value"
fi

# A transport error can arrive after the server accepted the exact update.
# The wrapper must resolve that ambiguity from the canonical ref itself.
: >"${GIT_LOG}"
ambiguous_push_out="$({
  PATH="${PUSH_BIN}:${PATH}" GIT_LOG="${GIT_LOG}" \
    SIMULATE_ACCEPTED_PUSH_ERROR=true \
    REMOTE_AFTER_FAILED_PUSH_SHA=4444444444444444444444444444444444444444 \
    PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=8 \
    EXECUTION_ID=008 ISSUE_TITLE='ambiguous accepted push' \
    WORKTREE_DIR="${PUSH_WORKTREE}" LOCAL_ISSUE_BRANCH='issue/43' \
    WORK_BRANCH='issue/41+43' EXPECTED_WORK_BRANCH_SHA="${EXPECTED_LEASE_SHA}" \
    EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_PARENT_SHA}" \
    bash "${PUSH_SCRIPTS}/commit_and_push.sh"
} 2>"${PUSH_ROOT}/ambiguous.stderr")" \
  || fail "accepted-but-error push was not recovered from the exact remote tip"
[ "${ambiguous_push_out}" = 4444444444444444444444444444444444444444 ] \
  || fail "ambiguous accepted push did not return the local commit SHA"
grep -F 'exact remote tip confirms success' \
  "${PUSH_ROOT}/ambiguous.stderr" >/dev/null \
  || fail "ambiguous accepted push did not record its exact-ref recovery"

# A merge commit can have A as its first parent while also importing a second
# parent. The shared pair contract is linear, so the wrapper must reject that
# topology before it performs any remote lookup or push.
MERGE_ROOT="${TEST_ROOT}/merge-parent"
MERGE_SCRIPTS="${MERGE_ROOT}/scripts"
MERGE_REPO="${MERGE_ROOT}/repo"
MERGE_NETWORK_LOG="${MERGE_ROOT}/network.log"
mkdir -p "${MERGE_SCRIPTS}" "${MERGE_REPO}"
cp "${SKILL_DIR}/scripts/commit_and_push.sh" \
  "${MERGE_SCRIPTS}/commit_and_push.sh"
cat >"${MERGE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
:
EOF
cat >"${MERGE_SCRIPTS}/git_network_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git_network_guard_assert_repo() { :; }
git_network_guard_run() {
  printf '%s\n' called >>"${MERGE_NETWORK_LOG:?}"
  return 97
}
EOF
chmod +x "${MERGE_SCRIPTS}/env_paths.sh" \
  "${MERGE_SCRIPTS}/git_network_guard.sh"
git -C "${MERGE_REPO}" init -q
git -C "${MERGE_REPO}" config user.email shared-test@example.invalid
git -C "${MERGE_REPO}" config user.name shared-test
printf 'base\n' >"${MERGE_REPO}/base.txt"
git -C "${MERGE_REPO}" add base.txt
git -C "${MERGE_REPO}" commit -q -m base
git -C "${MERGE_REPO}" switch -q -c side
printf 'side\n' >"${MERGE_REPO}/side.txt"
git -C "${MERGE_REPO}" add side.txt
git -C "${MERGE_REPO}" commit -q -m side
git -C "${MERGE_REPO}" switch -q -
printf 'head\n' >"${MERGE_REPO}/head.txt"
git -C "${MERGE_REPO}" add head.txt
git -C "${MERGE_REPO}" commit -q -m head
MERGE_EXPECTED_SHA="$(git -C "${MERGE_REPO}" rev-parse HEAD)"
git -C "${MERGE_REPO}" merge -q --no-ff --no-commit side
set +e
MERGE_NETWORK_LOG="${MERGE_NETWORK_LOG}" \
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=1 \
  EXECUTION_ID=001 ISSUE_TITLE='reject merge parent' \
  WORKTREE_DIR="${MERGE_REPO}" LOCAL_ISSUE_BRANCH='issue/43' \
  WORK_BRANCH='issue/41+43' EXPECTED_WORK_BRANCH_SHA="${MERGE_EXPECTED_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${MERGE_EXPECTED_SHA}" \
  bash "${MERGE_SCRIPTS}/commit_and_push.sh" >/dev/null 2>&1
merge_parent_rc=$?
set -e
[ "${merge_parent_rc}" -eq 5 ] \
  || fail "commit_and_push accepted a shared-branch merge commit"
[ ! -s "${MERGE_NETWORK_LOG}" ] \
  || fail "merge-commit rejection happened after remote access"

# Exercise the full Git topology against a real bare origin: A first publishes
# its ordinary issue/A branch.  C's late declaration then migrates that exact
# A commit to issue/A+C and removes issue/A before C appends one leased commit.
# Independent B stays on a separate branch rooted at the original target.
TOPOLOGY_ROOT="${TEST_ROOT}/topology"
TOPOLOGY_SCRIPTS="${TOPOLOGY_ROOT}/scripts"
TOPOLOGY_REPO="${TOPOLOGY_ROOT}/repo"
TOPOLOGY_ORIGIN="${TOPOLOGY_ROOT}/origin.git"
mkdir -p "${TOPOLOGY_SCRIPTS}" "${TOPOLOGY_REPO}" "${TOPOLOGY_ORIGIN}"
cp "${SKILL_DIR}/scripts/commit_and_push.sh" \
  "${TOPOLOGY_SCRIPTS}/commit_and_push.sh"
cat >"${TOPOLOGY_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
:
EOF
cat >"${TOPOLOGY_SCRIPTS}/git_network_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git_network_guard_assert_repo() { git -C "$1" rev-parse --git-dir >/dev/null; }
git_network_guard_run() {
  local repo="$1"
  shift
  git -C "${repo}" "$@"
}
EOF
chmod +x "${TOPOLOGY_SCRIPTS}/env_paths.sh" \
  "${TOPOLOGY_SCRIPTS}/git_network_guard.sh"
git -C "${TOPOLOGY_ORIGIN}" init --bare -q
git -C "${TOPOLOGY_REPO}" init -q
git -C "${TOPOLOGY_REPO}" config user.email shared-test@example.invalid
git -C "${TOPOLOGY_REPO}" config user.name shared-test
git -C "${TOPOLOGY_REPO}" remote add origin "${TOPOLOGY_ORIGIN}"
printf 'target\n' >"${TOPOLOGY_REPO}/target.txt"
git -C "${TOPOLOGY_REPO}" add target.txt
git -C "${TOPOLOGY_REPO}" commit -q -m target
TOPOLOGY_BASE_SHA="$(git -C "${TOPOLOGY_REPO}" rev-parse HEAD)"

git -C "${TOPOLOGY_REPO}" switch -q -c issue/41
printf 'A\n' >"${TOPOLOGY_REPO}/a.txt"
git -C "${TOPOLOGY_REPO}" add a.txt
TOPOLOGY_A_SHA="$(
  PROJECT=repo GROUP=group ISSUE_IID=41 EXECUTION_ID=1 \
  EXECUTION_ID=001 ISSUE_TITLE='A' \
  WORKTREE_DIR="${TOPOLOGY_REPO}" LOCAL_ISSUE_BRANCH='issue/41' \
  WORK_BRANCH='issue/41' \
    bash "${TOPOLOGY_SCRIPTS}/commit_and_push.sh" | tail -n 1
)"
[ "$(git --git-dir="${TOPOLOGY_ORIGIN}" rev-parse refs/heads/issue/41)" = \
    "${TOPOLOGY_A_SHA}" ] \
  || fail "A did not first publish its ordinary issue/A branch"
if git --git-dir="${TOPOLOGY_ORIGIN}" show-ref --verify --quiet \
    refs/heads/issue/41+43; then
  fail "A prematurely knew about C's dependency branch"
fi

git -C "${TOPOLOGY_REPO}" push --porcelain \
  '--force-with-lease=refs/heads/issue/41+43:' origin \
  "${TOPOLOGY_A_SHA}:refs/heads/issue/41+43" >/dev/null
git -C "${TOPOLOGY_REPO}" push --porcelain \
  "--force-with-lease=refs/heads/issue/41:${TOPOLOGY_A_SHA}" origin \
  ':refs/heads/issue/41' >/dev/null
[ "$(git --git-dir="${TOPOLOGY_ORIGIN}" rev-parse refs/heads/issue/41+43)" = \
    "${TOPOLOGY_A_SHA}" ] \
  || fail "late migration did not preserve A's exact commit"
if git --git-dir="${TOPOLOGY_ORIGIN}" show-ref --verify --quiet \
    refs/heads/issue/41; then
  fail "late migration retained the obsolete issue/A branch"
fi

git -C "${TOPOLOGY_REPO}" switch -q -c issue/43 "${TOPOLOGY_A_SHA}"
printf 'C\n' >"${TOPOLOGY_REPO}/c.txt"
git -C "${TOPOLOGY_REPO}" add c.txt
TOPOLOGY_C_SHA="$(
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=1 \
  EXECUTION_ID=001 ISSUE_TITLE='C' \
  WORKTREE_DIR="${TOPOLOGY_REPO}" LOCAL_ISSUE_BRANCH='issue/43' \
  WORK_BRANCH='issue/41+43' EXPECTED_WORK_BRANCH_SHA="${TOPOLOGY_A_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${TOPOLOGY_A_SHA}" \
    bash "${TOPOLOGY_SCRIPTS}/commit_and_push.sh" | tail -n 1
)"

# Continue replaces C instead of appending C2. The remote lease is the old C1
# tip, while the new commit parent remains frozen A; a mixed reset preserves the
# published C tree as a worktree diff and folds the next edit into one C commit.
TOPOLOGY_C1_SHA="${TOPOLOGY_C_SHA}"
[ "$(git -C "${TOPOLOGY_REPO}" branch --show-current)" = issue/43 ] \
  || fail "shared-tail worktree left its fixed issue-local branch"
printf 'C-v2\n' >"${TOPOLOGY_REPO}/c.txt"
git -C "${TOPOLOGY_REPO}" reset -q --mixed "${TOPOLOGY_A_SHA}"
git -C "${TOPOLOGY_REPO}" add c.txt
TOPOLOGY_C_SHA="$(
  PROJECT=repo GROUP=group ISSUE_IID=43 EXECUTION_ID=2 \
  EXECUTION_ID=002 ISSUE_TITLE='C continue' \
  WORKTREE_DIR="${TOPOLOGY_REPO}" LOCAL_ISSUE_BRANCH='issue/43' \
  WORK_BRANCH='issue/41+43' EXPECTED_WORK_BRANCH_SHA="${TOPOLOGY_C1_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${TOPOLOGY_A_SHA}" \
    bash "${TOPOLOGY_SCRIPTS}/commit_and_push.sh" | tail -n 1
)"

git -C "${TOPOLOGY_REPO}" switch -q -c issue/42 "${TOPOLOGY_BASE_SHA}"
printf 'B\n' >"${TOPOLOGY_REPO}/b.txt"
git -C "${TOPOLOGY_REPO}" add b.txt
TOPOLOGY_B_SHA="$(
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=1 \
  EXECUTION_ID=001 ISSUE_TITLE='B' \
  WORKTREE_DIR="${TOPOLOGY_REPO}" LOCAL_ISSUE_BRANCH='issue/42' \
  WORK_BRANCH='issue/42' \
    bash "${TOPOLOGY_SCRIPTS}/commit_and_push.sh" | tail -n 1
)"

[ "$(git -C "${TOPOLOGY_REPO}" rev-parse "${TOPOLOGY_A_SHA}^")" = \
    "${TOPOLOGY_BASE_SHA}" ] \
  || fail "A did not contribute exactly one commit on the target baseline"
[ "$(git -C "${TOPOLOGY_REPO}" rev-parse "${TOPOLOGY_C_SHA}^")" = \
    "${TOPOLOGY_A_SHA}" ] \
  || fail "C was not the direct single-parent child of A"
[ "$(git -C "${TOPOLOGY_REPO}" rev-list --count \
    "${TOPOLOGY_BASE_SHA}..${TOPOLOGY_C_SHA}")" -eq 2 ] \
  || fail "the shared A+C branch does not contain exactly two new commits"
if git -C "${TOPOLOGY_REPO}" merge-base --is-ancestor \
    "${TOPOLOGY_C1_SHA}" "${TOPOLOGY_C_SHA}"; then
  fail "shared tail continue appended C2 instead of replacing the single C commit"
fi
[ "$(git -C "${TOPOLOGY_REPO}" show "${TOPOLOGY_C_SHA}:c.txt")" = C-v2 ] \
  || fail "replacement C commit did not retain the continued worktree result"
[ "$(git -C "${TOPOLOGY_REPO}" rev-parse "${TOPOLOGY_B_SHA}^")" = \
    "${TOPOLOGY_BASE_SHA}" ] \
  || fail "B did not remain independent from A+C"
if git -C "${TOPOLOGY_REPO}" merge-base --is-ancestor \
    "${TOPOLOGY_B_SHA}" "${TOPOLOGY_C_SHA}"; then
  fail "B leaked into the shared A+C history"
fi
[ "$(git --git-dir="${TOPOLOGY_ORIGIN}" rev-parse refs/heads/issue/41+43)" = \
    "${TOPOLOGY_C_SHA}" ] \
  || fail "origin shared branch did not end at C"
[ "$(git --git-dir="${TOPOLOGY_ORIGIN}" rev-parse refs/heads/issue/42)" = \
    "${TOPOLOGY_B_SHA}" ] \
  || fail "origin independent B branch was not preserved"

echo "ok shared dependency branches reuse fixed IID-local branches, one MR, and an explicit SHA lease"
