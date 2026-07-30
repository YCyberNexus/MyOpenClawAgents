#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARCHIVE_SCRIPT="${SKILL_DIR}/scripts/archive_execution_logs.sh"
REAL_GIT="$(command -v git)"

fail() {
  echo "test_archive_execution_logs.sh: $*" >&2
  exit 1
}

[ -x "${ARCHIVE_SCRIPT}" ] \
  || fail "same-branch terminal log helper is missing or not executable"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-log-branch.XXXXXX")"
BIN_DIR="${TEST_ROOT}/bin"
REMOTE_STATE="${TEST_ROOT}/remote-state"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_NAME=archive_test
REPO_PATH="${REPO_PARENT}/${PROJECT_NAME}"
WORKTREE_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-7"
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-7/log/execution-123"
WORK_BRANCH_REF=refs/heads/issue/7
mkdir -p "${BIN_DIR}" "${LOG_DIR}"

"${REAL_GIT}" -C "${WORKTREE_DIR}" init -q
"${REAL_GIT}" -C "${WORKTREE_DIR}" config user.email test@example.invalid
"${REAL_GIT}" -C "${WORKTREE_DIR}" config user.name test
"${REAL_GIT}" -C "${WORKTREE_DIR}" remote add origin \
  'https://oauth2:test-token@local-gitlab.invalid:9443/claw_gitlab/archive_test.git'
printf 'base\n' >"${WORKTREE_DIR}/app.txt"
"${REAL_GIT}" -C "${WORKTREE_DIR}" add app.txt
"${REAL_GIT}" -C "${WORKTREE_DIR}" commit -m base >/dev/null
BUSINESS_HEAD="$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse HEAD)"
: >"${REMOTE_STATE}"

printf 'prompt\n' >"${LOG_DIR}/prompt.txt"
printf 'result\n' >"${LOG_DIR}/claude_result.txt"
printf '{"status":"done","commit_sha":"%s"}\n' "${BUSINESS_HEAD}" \
  >"${LOG_DIR}/worker_result.json"
printf 'must stay uncommitted\n' >"${WORKTREE_DIR}/partial-business.txt"

cat >"${BIN_DIR}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
index=0
command_name=""
while [ "${index}" -lt "${#args[@]}" ]; do
  case "${args[${index}]}" in
    -C|-c|--git-dir|--work-tree) index=$((index + 2)) ;;
    --*) index=$((index + 1)) ;;
    *) command_name="${args[${index}]}"; break ;;
  esac
done
case "${command_name}" in
  ls-remote)
    if [ -s "${REMOTE_STATE:?}" ]; then
      printf '%s\t%s\n' "$(sed -n '1p' "${REMOTE_STATE}")" \
        "$(sed -n '2p' "${REMOTE_STATE}")"
      exit 0
    fi
    for arg in "${args[@]}"; do
      [ "${arg}" != --exit-code ] || exit 2
    done
    exit 0
    ;;
  push)
    for arg in "${args[@]}"; do
      case "${arg}" in
        *:refs/heads/issue/7)
          printf '%s\n%s\n' "${arg%%:*}" refs/heads/issue/7 \
            >"${REMOTE_STATE:?}"
          exit 0
          ;;
        *:refs/heads/*)
          echo "unexpected non-Issue refspec: ${arg}" >&2
          exit 97
          ;;
      esac
    done
    echo "fake git did not receive the Issue branch refspec" >&2
    exit 98
    ;;
  *) exec "${REAL_GIT:?}" "$@" ;;
esac
EOF
chmod +x "${BIN_DIR}/git"

run_archive() {
  env \
    -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    REAL_GIT="${REAL_GIT}" REMOTE_STATE="${REMOTE_STATE}" \
    PATH="${BIN_DIR}:${PATH}" \
    PROJECT="${PROJECT_NAME}" GROUP=claw_gitlab \
    GITLAB_HOST=local-gitlab.invalid:9443 GITLAB_API_PROTOCOL=https \
    GITLAB_TOKEN=test-token \
    REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=local-gitlab.invalid:9443 \
    REPO_PARENT_PATH="${REPO_PARENT}" ISSUE_IID=7 EXECUTION_ID=123 \
    WORK_BRANCH=issue/7 COMMIT_SHA="$1" \
      bash "${ARCHIVE_SCRIPT}"
}

archive_output="$(run_archive "")" \
  || fail "log-only execution did not create its Issue branch"
LOG_COMMIT="$(awk -F= '$1 == "LOG_COMMIT_SHA" {print $2}' \
  <<<"${archive_output}")"
[[ "${LOG_COMMIT}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
  || fail "helper returned an invalid log commit"
[ "${LOG_COMMIT}" != "${BUSINESS_HEAD}" ] \
  || fail "terminal logs did not create a child commit"
[ "$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse "${LOG_COMMIT}^")" = \
    "${BUSINESS_HEAD}" ] \
  || fail "terminal log commit is not a direct child of the business commit"
[ "$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse HEAD)" = "${LOG_COMMIT}" ] \
  || fail "local Issue branch did not advance to the log commit"
[ "$(sed -n '1p' "${REMOTE_STATE}")" = "${LOG_COMMIT}" ] \
  && [ "$(sed -n '2p' "${REMOTE_STATE}")" = "${WORK_BRANCH_REF}" ] \
  || fail "remote Issue branch did not advance to the log commit"
"${REAL_GIT}" -C "${WORKTREE_DIR}" cat-file -e \
  "${LOG_COMMIT}:.req_executor/issue-7/log/execution-123/worker_result.json" \
  || fail "terminal log commit is missing worker_result.json"
if "${REAL_GIT}" -C "${WORKTREE_DIR}" cat-file -e \
    "${LOG_COMMIT}:partial-business.txt" 2>/dev/null; then
  fail "log-only commit captured unrelated partial business work"
fi

# Simulate a process dying after the server accepted the deterministic log
# commit but before local refs advanced. The replay must recognize that exact
# remote child, recover local refs, and avoid a second commit.
"${REAL_GIT}" -C "${WORKTREE_DIR}" update-ref HEAD \
  "${BUSINESS_HEAD}" "${LOG_COMMIT}"
"${REAL_GIT}" -C "${WORKTREE_DIR}" update-ref refs/remotes/origin/issue/7 \
  "${BUSINESS_HEAD}" "${LOG_COMMIT}"
crash_recovery_output="$(run_archive "${BUSINESS_HEAD}")" \
  || fail "accepted remote log commit was not crash-recoverable"
[ "$(awk -F= '$1 == "LOG_COMMIT_SHA" {print $2}' \
    <<<"${crash_recovery_output}")" = "${LOG_COMMIT}" ] \
  && [ "$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse HEAD)" = \
    "${LOG_COMMIT}" ] \
  || fail "crash recovery did not restore the exact accepted log commit"

replay_output="$(run_archive "${LOG_COMMIT}")" \
  || fail "exact same-branch replay failed"
[ "$(awk -F= '$1 == "LOG_COMMIT_SHA" {print $2}' \
    <<<"${replay_output}")" = "${LOG_COMMIT}" ] \
  || fail "unchanged replay appended another commit"

: >"${REMOTE_STATE}"
recreated_output="$(run_archive "${LOG_COMMIT}")" \
  || fail "unchanged replay did not recreate a missing Issue ref"
[ "$(awk -F= '$1 == "LOG_COMMIT_SHA" {print $2}' \
    <<<"${recreated_output}")" = "${LOG_COMMIT}" ] \
  && [ "$(sed -n '1p' "${REMOTE_STATE}")" = "${LOG_COMMIT}" ] \
  && [ "$(sed -n '2p' "${REMOTE_STATE}")" = "${WORK_BRANCH_REF}" ] \
  || fail "missing Issue ref was not recreated at the exact existing log commit"

printf 'late callback evidence\n' >"${LOG_DIR}/dispatcher_callbacks.jsonl"
updated_output="$(run_archive "${LOG_COMMIT}")" \
  || fail "late evidence append failed"
UPDATED_COMMIT="$(awk -F= '$1 == "LOG_COMMIT_SHA" {print $2}' \
  <<<"${updated_output}")"
[ "${UPDATED_COMMIT}" != "${LOG_COMMIT}" ] \
  && [ "$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse "${UPDATED_COMMIT}^")" = \
    "${LOG_COMMIT}" ] \
  || fail "late evidence did not append one same-branch child"
"${REAL_GIT}" -C "${WORKTREE_DIR}" cat-file -e \
  "${UPDATED_COMMIT}:.req_executor/issue-7/log/execution-123/dispatcher_callbacks.jsonl" \
  || fail "late evidence is missing from the appended commit"

if grep -Fq 'req-executor-logs' "${ARCHIVE_SCRIPT}"; then
  fail "helper still names the removed remote log branch"
fi

echo "ok terminal LOG_DIR appends only to the Issue work branch"
