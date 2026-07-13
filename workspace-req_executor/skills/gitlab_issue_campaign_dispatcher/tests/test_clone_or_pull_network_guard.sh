#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLONE_SCRIPT="${SKILL_DIR}/scripts/clone_or_pull.sh"
REAL_GIT="$(command -v git)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-clone-guard.XXXXXX")"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GIT="${BIN_DIR}/git"
GIT_CALL_LOG="${TEST_ROOT}/git-calls.log"
mkdir -p "${BIN_DIR}"

cat >"${FAKE_GIT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
index=0
command_name=""
while [ "${index}" -lt "${#args[@]}" ]; do
  case "${args[${index}]}" in
    -C|-c|--git-dir|--work-tree)
      index=$((index + 2))
      ;;
    --*)
      index=$((index + 1))
      ;;
    *)
      command_name="${args[${index}]}"
      break
      ;;
  esac
done
[ -n "${command_name}" ] || exit 97
printf '%s\n' "${command_name}" >>"${GIT_CALL_LOG:?}"

case "${command_name}" in
  fetch|push)
    exit 0
    ;;
  clone)
    count="${#args[@]}"
    [ "${count}" -ge 3 ] || exit 96
    destination="${args[$((count - 1))]}"
    origin="${args[$((count - 2))]}"
    "${REAL_GIT:?}" init -q -b master "${destination}"
    "${REAL_GIT}" -C "${destination}" remote add origin "${origin}"
    exit 0
    ;;
  *)
    exec "${REAL_GIT:?}" "$@"
    ;;
esac
EOF
chmod +x "${FAKE_GIT}"

prepare_repo() {
  local repo="$1" origin="$2"
  mkdir -p "$(dirname "${repo}")"
  "${REAL_GIT}" init -q -b master "${repo}"
  "${REAL_GIT}" -C "${repo}" remote add origin "${origin}"
}

run_clone() {
  local repo="$1"
  shift
  env \
    -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
    -u REPO_PARENT_PATH -u PROJECT_FULL -u PROJECT_URI \
    -u GITLAB_ADDRESS \
    REAL_GIT="${REAL_GIT}" GIT_CALL_LOG="${GIT_CALL_LOG}" \
    PATH="${BIN_DIR}:${PATH}" \
    REPO_PATH="${repo}" GROUP=group PROJECT=repo BRANCH=master \
    GITLAB_HOST=localhost:8081 GITLAB_API_PROTOCOL=http \
    GITLAB_TOKEN=local-test-token \
    REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081 \
    "$@" \
    "${BASH}" "${CLONE_SCRIPT}"
}

assert_no_network_git() {
  if grep -Eq '^(clone|fetch|push)$' "${GIT_CALL_LOG}"; then
    echo "a rejected Git routing case reached a network-capable git command" >&2
    exit 1
  fi
}

VALID_ORIGIN='http://oauth2:old-token@localhost:8081/group/repo.git'
REPO_PATH_SUCCESS="${TEST_ROOT}/repos/success"
prepare_repo "${REPO_PATH_SUCCESS}" "${VALID_ORIGIN}"
: >"${GIT_CALL_LOG}"
run_clone "${REPO_PATH_SUCCESS}" >"${TEST_ROOT}/success.out" 2>"${TEST_ROOT}/success.err"
[ "$(grep -c '^fetch$' "${GIT_CALL_LOG}")" -eq 1 ] || {
  echo "safe local origin did not perform exactly one guarded fetch" >&2
  exit 1
}
[ "$("${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" config --get http.followRedirects)" = false ]
[ "$("${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" config --get protocol.allow)" = never ]
[ "$("${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" config --get protocol.http.allow)" = always ]
[ "$("${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" remote get-url origin)" = \
  'http://oauth2:local-test-token@localhost:8081/group/repo.git' ] || {
  echo "clone_or_pull did not replace the prior credential before fetch" >&2
  exit 1
}

for unsafe_credential_origin in \
  'http://oauth2:old-token@localhost:8081/group/repo.git' \
  'http://localhost:8081/group/repo.git'
do
  "${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" remote set-url origin \
    "${unsafe_credential_origin}"
  if env \
      -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      CONFIG_DIR="${SKILL_DIR}/../../config" \
      PROJECT_FULL=group/repo \
      GITLAB_HOST=localhost:8081 GITLAB_API_PROTOCOL=http \
      GITLAB_TOKEN=local-test-token \
      REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
      REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081 \
      bash -c '
        source "$1"
        git_network_guard_assert_repo "$2"
      ' _ "${SKILL_DIR}/scripts/git_network_guard.sh" "${REPO_PATH_SUCCESS}"; then
    echo "strict network guard accepted a missing or stale origin credential" >&2
    exit 1
  fi
done
"${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" remote set-url origin \
  'http://oauth2:local-test-token@localhost:8081/group/repo.git'

mismatching_origins=(
  'https://oauth2:old-token@localhost:8081/group/repo.git'
  'http://oauth2:old-token@other.example:8081/group/repo.git'
  'http://oauth2:old-token@localhost/group/repo.git'
  'http://oauth2:old-token@localhost:8082/group/repo.git'
  'http://oauth2:old-token@localhost:8081/other/repo.git'
  'http://oauth2:old-token@localhost:8081/group/repo'
  'http://oauth2:old-token@localhost:8081/group/repo.git/'
  'http://oauth2:old-token@localhost:8081/group/repo.git.git'
)
for origin in "${mismatching_origins[@]}"; do
  "${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" remote set-url origin "${origin}"
  : >"${GIT_CALL_LOG}"
  if run_clone "${REPO_PATH_SUCCESS}" >/dev/null 2>"${TEST_ROOT}/origin-mismatch.err"; then
    echo "clone_or_pull accepted a mismatching origin" >&2
    exit 1
  fi
  assert_no_network_git
done
"${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" remote set-url origin "${VALID_ORIGIN}"

"${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" config remote.origin.pushurl \
  'http://evil.example/group/repo.git'
: >"${GIT_CALL_LOG}"
if run_clone "${REPO_PATH_SUCCESS}" >/dev/null 2>"${TEST_ROOT}/pushurl.err"; then
  echo "clone_or_pull accepted remote.origin.pushurl" >&2
  exit 1
fi
assert_no_network_git
"${REAL_GIT}" -C "${REPO_PATH_SUCCESS}" config --unset-all remote.origin.pushurl

for rewrite_key in \
  'url.http://evil.example/.insteadOf' \
  'url.http://evil.example/.pushInsteadOf'
do
  : >"${GIT_CALL_LOG}"
  if run_clone "${REPO_PATH_SUCCESS}" \
      GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0="${rewrite_key}" \
      GIT_CONFIG_VALUE_0='http://localhost:8081/' \
      >/dev/null 2>"${TEST_ROOT}/rewrite.err"; then
    echo "clone_or_pull accepted Git URL rewrite configuration" >&2
    exit 1
  fi
  assert_no_network_git
done

: >"${GIT_CALL_LOG}"
if run_clone "${REPO_PATH_SUCCESS}" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy \
    GIT_CONFIG_VALUE_0=http://evil-proxy.example:8888 \
    >/dev/null 2>"${TEST_ROOT}/git-proxy.err"; then
  echo "clone_or_pull accepted Git proxy configuration" >&2
  exit 1
fi
assert_no_network_git

for proxy_name in \
  http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
do
  : >"${GIT_CALL_LOG}"
  if run_clone "${REPO_PATH_SUCCESS}" \
      "${proxy_name}=http://evil-proxy.example:8888" \
      >/dev/null 2>"${TEST_ROOT}/env-proxy.err"; then
    echo "clone_or_pull accepted ${proxy_name}" >&2
    exit 1
  fi
  [ ! -s "${GIT_CALL_LOG}" ] || {
    echo "clone_or_pull called git before rejecting ${proxy_name}" >&2
    exit 1
  }
done

: >"${GIT_CALL_LOG}"
if run_clone "${REPO_PATH_SUCCESS}" \
    GITLAB_HOST=gitlab-b.pxsemic.tech:30000 \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=gitlab-b.pxsemic.tech:30000 \
    >/dev/null 2>"${TEST_ROOT}/blue-host.err"; then
  echo "clone_or_pull accepted the tracked deployment host in local-test mode" >&2
  exit 1
fi
[ ! -s "${GIT_CALL_LOG}" ] || {
  echo "clone_or_pull called git before rejecting the tracked deployment host" >&2
  exit 1
}

FIRST_CLONE="${TEST_ROOT}/repos/first-clone"
: >"${GIT_CALL_LOG}"
run_clone "${FIRST_CLONE}" >"${TEST_ROOT}/first-clone.out" \
  2>"${TEST_ROOT}/first-clone.err"
[ -d "${FIRST_CLONE}/.git" ] || {
  echo "fake first clone did not create a repository" >&2
  exit 1
}
[ "$(grep -c '^clone$' "${GIT_CALL_LOG}")" -eq 1 ]
[ "$(grep -c '^fetch$' "${GIT_CALL_LOG}")" -eq 1 ]

REJECTED_FIRST_CLONE="${TEST_ROOT}/repos/rejected-first-clone"
: >"${GIT_CALL_LOG}"
if run_clone "${REJECTED_FIRST_CLONE}" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0='url.http://evil.example/.insteadOf' \
    GIT_CONFIG_VALUE_0='http://localhost:8081/' \
    >/dev/null 2>"${TEST_ROOT}/first-clone-rewrite.err"; then
  echo "first clone accepted URL rewrite configuration" >&2
  exit 1
fi
assert_no_network_git
[ ! -e "${REJECTED_FIRST_CLONE}/.git" ] || {
  echo "rejected first clone created repository state" >&2
  exit 1
}

echo "ok clone/fetch routing is exact and rejects rewrite, pushurl, and proxies"
