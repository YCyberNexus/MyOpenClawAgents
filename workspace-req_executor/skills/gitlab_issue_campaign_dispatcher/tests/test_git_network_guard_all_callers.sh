#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${SKILL_DIR}/scripts"
GUARD="${SCRIPTS_DIR}/git_network_guard.sh"
REAL_GIT="$(command -v git)"

required_contracts=(
  'clone_or_pull.sh:git_network_guard_clone'
  'clone_or_pull.sh:git_network_guard_run "${REPO_PATH}" fetch'
  'prepare_attempt.sh:git_network_guard_run "${REPO_PATH}" fetch'
  'prepare_attempt.sh:ls-remote --exit-code --heads origin'
  'branch_utils.sh:git_network_guard_run "${repo_path}"'
  'commit_and_push.sh:ls-remote --exit-code --heads origin'
  'commit_and_push.sh:git_network_guard_run "${WORKTREE_DIR}" push'
  'archive_execution_logs.sh:git_network_guard_run "${WORKTREE_DIR}" push'
  'archive_execution_logs.sh:git_network_guard_run "${WORKTREE_DIR}" fetch'
  'archive_execution_logs.sh:git_network_guard_run "${WORKTREE_DIR}"'
  'post_push_verify.sh:git_network_guard_run "${WORKTREE_DIR}" fetch'
)
for contract in "${required_contracts[@]}"; do
  file="${contract%%:*}"
  text="${contract#*:}"
  grep -Fq "${text}" "${SCRIPTS_DIR}/${file}" || {
    echo "missing Git network guard contract in ${file}: ${text}" >&2
    exit 1
  }
done

for file in \
  clone_or_pull.sh prepare_attempt.sh branch_utils.sh \
  commit_and_push.sh archive_execution_logs.sh post_push_verify.sh
do
  if grep -Eq '^[[:space:]]*git[[:space:]].*(clone|fetch|ls-remote|push)([[:space:]]|$)' \
      "${SCRIPTS_DIR}/${file}"; then
    echo "raw network-capable git command bypasses the guard in ${file}" >&2
    exit 1
  fi
done

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-git-guard-callers.XXXXXX")"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GIT="${BIN_DIR}/git"
GIT_LOG="${TEST_ROOT}/git.log"
REPO="${TEST_ROOT}/repo"
mkdir -p "${BIN_DIR}"
"${REAL_GIT}" init -q -b master "${REPO}"
"${REAL_GIT}" -C "${REPO}" remote add origin \
  'http://oauth2:test-token@localhost:8081/group/repo.git'

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
[ -n "${command_name}" ] || exit 97
printf '%s\n' "${command_name}" >>"${GIT_LOG:?}"
case "${command_name}" in
  clone|fetch|ls-remote|push) exit 0 ;;
  *) exec "${REAL_GIT:?}" "$@" ;;
esac
EOF
chmod +x "${FAKE_GIT}"

run_guard() {
  local host="${1}" allowed="${2}"
  shift 2
  env \
    -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
    REAL_GIT="${REAL_GIT}" GIT_LOG="${GIT_LOG}" \
    PATH="${BIN_DIR}:${PATH}" \
    GITLAB_HOST="${host}" GITLAB_API_PROTOCOL=http \
    GITLAB_TOKEN=test-token \
    PROJECT_FULL=group/repo \
    REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="${allowed}" \
    "$@"
}

: >"${GIT_LOG}"
for operation in fetch ls-remote push; do
  case "${operation}" in
    fetch) operation_args=(fetch --prune origin) ;;
    ls-remote) operation_args=(ls-remote --exit-code --heads origin issue/1) ;;
    push) operation_args=(push origin issue/1:issue/1) ;;
  esac
  run_guard localhost:8081 localhost:8081 \
    "${BASH}" -c '
      source "$1"
      repo="$2"
      shift 2
      GIT_NETWORK_GUARD_CONTEXT=test_git_network_guard
      git_network_guard_run "$repo" "$@"
    ' _ "${GUARD}" "${REPO}" "${operation_args[@]}"
done
for operation in fetch ls-remote push; do
  [ "$(grep -c "^${operation}$" "${GIT_LOG}")" -eq 1 ] || {
    echo "guarded ${operation} did not reach the fake git exactly once" >&2
    exit 1
  }
done

"${REAL_GIT}" -C "${REPO}" config remote.origin.pushurl \
  'http://evil.example/group/repo.git'
: >"${GIT_LOG}"
if run_guard localhost:8081 localhost:8081 \
  "${BASH}" -c '
    source "$1"
    GIT_NETWORK_GUARD_CONTEXT=test_git_network_guard
    git_network_guard_run "$2" fetch origin
  ' _ "${GUARD}" "${REPO}" \
  >"${TEST_ROOT}/pushurl.out" 2>"${TEST_ROOT}/pushurl.err"
then
  echo "shared guard accepted remote.origin.pushurl" >&2
  exit 1
fi
if grep -q '^fetch$' "${GIT_LOG}"; then
  echo "pushurl rejection occurred after fetch" >&2
  exit 1
fi
"${REAL_GIT}" -C "${REPO}" config --unset-all remote.origin.pushurl

: >"${GIT_LOG}"
if run_guard gitlab-b.pxsemic.tech:30000 gitlab-b.pxsemic.tech:30000 \
  "${BASH}" -c '
    source "$1"
    GIT_NETWORK_GUARD_CONTEXT=test_git_network_guard
    git_network_guard_run "$2" fetch origin
  ' _ "${GUARD}" "${REPO}" \
  >"${TEST_ROOT}/blue.out" 2>"${TEST_ROOT}/blue.err"
then
  echo "shared guard accepted the tracked deployment host in local-test mode" >&2
  exit 1
fi
[ ! -s "${GIT_LOG}" ] || {
  echo "shared guard called git before rejecting the tracked deployment host" >&2
  exit 1
}

echo "ok every clone/fetch/ls-remote/push caller uses the shared Git guard"
