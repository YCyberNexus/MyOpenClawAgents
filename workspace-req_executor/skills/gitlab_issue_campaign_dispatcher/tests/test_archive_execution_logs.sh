#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARCHIVE_SCRIPT="${SKILL_DIR}/scripts/archive_execution_logs.sh"
REAL_GIT="$(command -v git)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-log-archive.XXXXXX")"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GIT="${BIN_DIR}/git"
REMOTE_STATE="${TEST_ROOT}/remote-state"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_NAME="archive_test"
REPO_PATH="${REPO_PARENT}/${PROJECT_NAME}"
WORKTREE_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-7"
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-7/log/execution-123"
ARCHIVE_REF="refs/heads/req-executor-logs/issue-7/execution-123"

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

printf 'prompt\n' >"${LOG_DIR}/prompt.txt"
printf 'result\n' >"${LOG_DIR}/claude_result.txt"
printf 'outer finalization\n' >"${LOG_DIR}/outer-create-mr.stdout.log"
printf '{"status":"done"}\n' >"${LOG_DIR}/worker_result.json"

cat >"${FAKE_GIT}" <<'EOF'
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
    exit 2
    ;;
  push)
    for arg in "${args[@]}"; do
      case "${arg}" in
        *:refs/heads/req-executor-logs/*)
          printf '%s\n%s\n' "${arg%%:*}" "${arg#*:}" >"${REMOTE_STATE:?}"
          exit 0
          ;;
      esac
    done
    echo "fake git did not receive the archive refspec" >&2
    exit 97
    ;;
  *) exec "${REAL_GIT:?}" "$@" ;;
esac
EOF
chmod +x "${FAKE_GIT}"

archive_output="$(
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
      bash "${ARCHIVE_SCRIPT}"
)"

archive_commit="$(awk -F= '$1 == "LOG_ARCHIVE_COMMIT" {print $2}' \
  <<<"${archive_output}")"
[[ "${archive_commit}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
  || { echo "archive script returned an invalid commit" >&2; exit 1; }
[ "$(sed -n '1p' "${REMOTE_STATE}")" = "${archive_commit}" ] \
  || { echo "pushed archive commit mismatch" >&2; exit 1; }
[ "$(sed -n '2p' "${REMOTE_STATE}")" = "${ARCHIVE_REF}" ] \
  || { echo "pushed archive ref mismatch" >&2; exit 1; }
[ "$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse HEAD)" = "${BUSINESS_HEAD}" ] \
  || { echo "archive changed the business branch HEAD" >&2; exit 1; }

retry_output="$(
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
      bash "${ARCHIVE_SCRIPT}"
)"
retry_commit="$(awk -F= '$1 == "LOG_ARCHIVE_COMMIT" {print $2}' \
  <<<"${retry_output}")"
[ "${retry_commit}" = "${archive_commit}" ] \
  || { echo "identical archive retry produced a different commit" >&2; exit 1; }

printf 'callback evidence\n' >"${LOG_DIR}/dispatcher_callbacks.jsonl"
updated_output="$(
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
      bash "${ARCHIVE_SCRIPT}"
)"
updated_commit="$(awk -F= '$1 == "LOG_ARCHIVE_COMMIT" {print $2}' \
  <<<"${updated_output}")"
[ "${updated_commit}" != "${archive_commit}" ] \
  || { echo "changed terminal logs did not append an archive commit" >&2; exit 1; }
[ "$("${REAL_GIT}" -C "${WORKTREE_DIR}" rev-parse "${updated_commit}^")" = \
    "${archive_commit}" ] \
  || { echo "updated archive is not a descendant of the prior snapshot" >&2; exit 1; }
"${REAL_GIT}" -C "${WORKTREE_DIR}" cat-file -e \
  "${updated_commit}:.req_executor/issue-7/log/execution-123/dispatcher_callbacks.jsonl" \
  || { echo "updated archive is missing late callback evidence" >&2; exit 1; }

for expected in prompt.txt claude_result.txt outer-create-mr.stdout.log worker_result.json; do
  archive_path=".req_executor/issue-7/log/execution-123/${expected}"
  "${REAL_GIT}" -C "${WORKTREE_DIR}" cat-file -e \
    "${updated_commit}:${archive_path}" \
    || { echo "archive commit is missing ${archive_path}" >&2; exit 1; }
done

echo "ok terminal LOG_DIR snapshots append without moving the business branch"
