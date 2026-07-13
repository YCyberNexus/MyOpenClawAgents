#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-glab-local-guard.XXXXXX")"
WORKSPACE_ROOT="${TEST_ROOT}/workspace"
CONFIG_DIR="${WORKSPACE_ROOT}/config"
SCRIPTS_DIR="${WORKSPACE_ROOT}/skills/gitlab_issue_campaign_dispatcher/scripts"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GLAB="${BIN_DIR}/glab"
GLAB_LOG="${TEST_ROOT}/glab.log"
mkdir -p "${CONFIG_DIR}" "${SCRIPTS_DIR}" "${BIN_DIR}"
cp "${SKILL_DIR}/scripts/glab_auth.sh" "${SCRIPTS_DIR}/glab_auth.sh"
cp "${SKILL_DIR}/scripts/env_paths.sh" "${SCRIPTS_DIR}/env_paths.sh"
cp "${SKILL_DIR}/scripts/git_network_guard.sh" "${SCRIPTS_DIR}/git_network_guard.sh"
chmod +x "${SCRIPTS_DIR}/glab_auth.sh" "${SCRIPTS_DIR}/env_paths.sh" \
  "${SCRIPTS_DIR}/git_network_guard.sh"

git -C "${REPO_ROOT}" check-ignore -q --no-index \
  workspace-req_executor/config/campaign_defaults.local.env || {
  echo "campaign_defaults.local.env must remain ignored" >&2
  exit 1
}

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=tracked-blue.example:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=tracked-token-must-not-be-used-locally
EOF
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<'EOF'
GITLAB_HOST=local-file.example:9443
GITLAB_API_PROTOCOL=https
REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true
REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=local-file.example:9443
EOF

cat >"${FAKE_GLAB}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

verb="${1:-}"
subverb="${2:-}"
hostname=""
protocol=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname)
      shift
      hostname="${1:-}"
      ;;
    --api-protocol)
      shift
      protocol="${1:-}"
      ;;
  esac
  [ "$#" -gt 0 ] && shift
done
[ "${hostname}" = "${GITLAB_HOST:?}" ] || exit 81
if [ -n "${protocol}" ]; then
  [ "${protocol}" = "${GITLAB_API_PROTOCOL:?}" ] || exit 82
fi
printf '%s\t%s\t%s\t%s\n' \
  "${GITLAB_HOST}" "${GITLAB_API_PROTOCOL}" "${verb}" "${subverb}" \
  >>"${FAKE_GLAB_LOG:?}"
EOF
chmod +x "${FAKE_GLAB}"

run_auth() {
  env -u GITLAB_ADDRESS "$@" "${BASH}" "${SCRIPTS_DIR}/glab_auth.sh"
}

: >"${GLAB_LOG}"
local_file_out="$(run_auth \
  -u GITLAB_HOST -u GITLAB_API_PROTOCOL \
  GITLAB_TOKEN=local-test-token GLAB_BIN="${FAKE_GLAB}" \
  FAKE_GLAB_LOG="${GLAB_LOG}")"
[ "${local_file_out}" = local-file.example:9443 ] || {
  echo "ignored local GitLab target did not override the tracked pin" >&2
  exit 1
}
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" -eq 2 ] || {
  echo "expected exactly two fake glab auth calls" >&2
  exit 1
}
if grep -Fq 'tracked-blue.example:30000' "${GLAB_LOG}"; then
  echo "glab_auth touched the tracked host before applying the local file" >&2
  exit 1
fi

: >"${GLAB_LOG}"
process_out="$(run_auth \
  GITLAB_HOST=localhost:8081 GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN=process-token GLAB_BIN="${FAKE_GLAB}" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081 \
  FAKE_GLAB_LOG="${GLAB_LOG}")"
[ "${process_out}" = localhost:8081 ] || {
  echo "process GitLab target did not override the ignored local file" >&2
  exit 1
}
grep -Eq '^localhost:8081[[:space:]]+http[[:space:]]+auth[[:space:]]+(login|status)$' \
  "${GLAB_LOG}" || {
  echo "fake glab did not receive the process-local target" >&2
  exit 1
}

: >"${GLAB_LOG}"
set +e
run_auth \
  GITLAB_HOST=localhost:8081 GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN=tracked-token-must-not-be-used-locally \
  GLAB_BIN="${FAKE_GLAB}" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081 \
  FAKE_GLAB_LOG="${GLAB_LOG}" \
  >"${TEST_ROOT}/tracked-token-value.out" \
  2>"${TEST_ROOT}/tracked-token-value.err"
tracked_token_rc=$?
set -e
[ "${tracked_token_rc}" -eq 14 ] || {
  echo "local-test mode accepted a process token equal to the tracked token" >&2
  exit 1
}
[ ! -s "${GLAB_LOG}" ] || {
  echo "glab was called with a process token equal to the tracked token" >&2
  exit 1
}

set +e
env PROJECT=repo GROUP=group REPO_PARENT_PATH="${TEST_ROOT}/repos" \
  CONFIG_DIR="${CONFIG_DIR}" \
  GITLAB_HOST=localhost:8081 GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN=tracked-token-must-not-be-used-locally \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081 \
  bash -c 'source "$1"' _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/env-paths-tracked-token.out" \
  2>"${TEST_ROOT}/env-paths-tracked-token.err"
env_paths_tracked_token_rc=$?
set -e
[ "${env_paths_tracked_token_rc}" -eq 86 ] || {
  echo "env_paths accepted a process token equal to the tracked token" >&2
  exit 1
}

: >"${GLAB_LOG}"
set +e
run_auth \
  GITLAB_HOST=tracked-blue.example:30000 GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN=process-token GLAB_BIN="${FAKE_GLAB}" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=tracked-blue.example:30000 \
  FAKE_GLAB_LOG="${GLAB_LOG}" \
  >"${TEST_ROOT}/tracked-host.out" 2>"${TEST_ROOT}/tracked-host.err"
tracked_rc=$?
set -e
[ "${tracked_rc}" -eq 14 ] || {
  echo "local-test mode did not reject the tracked deployment host" >&2
  exit 1
}
[ ! -s "${GLAB_LOG}" ] || {
  echo "glab was called for the tracked deployment host in local-test mode" >&2
  exit 1
}

# env_paths.sh may skip persistent glab auth for a complete process tuple, but
# that optimization must not skip the local-test blue-host fence.
: >"${GLAB_LOG}"
set +e
env PROJECT=repo GROUP=group REPO_PARENT_PATH="${TEST_ROOT}/repos" \
  GITLAB_HOST=tracked-blue.example:30000 GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN=process-token GLAB_BIN="${FAKE_GLAB}" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=tracked-blue.example:30000 \
  FAKE_GLAB_LOG="${GLAB_LOG}" \
  bash -c 'source "$1"' _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/env-paths-tracked.out" \
  2>"${TEST_ROOT}/env-paths-tracked.err"
env_paths_tracked_rc=$?
set -e
[ "${env_paths_tracked_rc}" -eq 86 ] || {
  echo "env_paths process tuple skipped the local-test tracked-host fence" >&2
  exit 1
}
[ ! -s "${GLAB_LOG}" ] || {
  echo "env_paths called glab for the tracked host in local-test mode" >&2
  exit 1
}

: >"${GLAB_LOG}"
set +e
run_auth \
  GITLAB_HOST=other-local.example:8081 GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN=process-token GLAB_BIN="${FAKE_GLAB}" \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081 \
  FAKE_GLAB_LOG="${GLAB_LOG}" \
  >"${TEST_ROOT}/not-allowed.out" 2>"${TEST_ROOT}/not-allowed.err"
allowlist_rc=$?
set -e
[ "${allowlist_rc}" -eq 14 ] || {
  echo "local-test mode accepted a host outside the allowlist" >&2
  exit 1
}
[ ! -s "${GLAB_LOG}" ] || {
  echo "glab was called for a host outside the local allowlist" >&2
  exit 1
}

echo "ok glab auth resolves local overrides before network and fails closed"
