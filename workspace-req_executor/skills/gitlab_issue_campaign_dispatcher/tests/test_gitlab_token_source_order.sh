#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-token-order.XXXXXX")"
WORKSPACE_ROOT="${TEST_ROOT}/workspace"
CONFIG_DIR="${WORKSPACE_ROOT}/config"
SCRIPTS_DIR="${WORKSPACE_ROOT}/skills/gitlab_issue_campaign_dispatcher/scripts"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PARENT="${TEST_ROOT}/repos"
FAKE_GLAB="${BIN_DIR}/fake-glab"
TOKEN_LOG="${TEST_ROOT}/fake-glab-token.log"

mkdir -p "${CONFIG_DIR}" "${SCRIPTS_DIR}" "${BIN_DIR}" "${REPO_PARENT}"
cp "${SKILL_DIR}/scripts/glab_auth.sh" "${SCRIPTS_DIR}/glab_auth.sh"
cp "${SKILL_DIR}/scripts/env_paths.sh" "${SCRIPTS_DIR}/env_paths.sh"
cp "${SKILL_DIR}/scripts/git_network_guard.sh" "${SCRIPTS_DIR}/git_network_guard.sh"
cp "${SKILL_DIR}/scripts/gitlab_env_resolver.sh" "${SCRIPTS_DIR}/gitlab_env_resolver.sh"
chmod +x "${SCRIPTS_DIR}/glab_auth.sh" "${SCRIPTS_DIR}/env_paths.sh" \
  "${SCRIPTS_DIR}/git_network_guard.sh" "${SCRIPTS_DIR}/gitlab_env_resolver.sh"

cat >"${FAKE_GLAB}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

token=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)
      shift
      token="${1:-}"
      ;;
  esac
  if [ "$#" -gt 0 ]; then
    shift
  fi
done

if [ -n "${token}" ]; then
  printf '%s\n' "${token}" >"${FAKE_GLAB_TOKEN_LOG:?}"
fi
if [ -n "${FAKE_EXPECTED_HOST:-}" ]; then
  [ "${GITLAB_HOST:-}" = "${FAKE_EXPECTED_HOST}" ] || exit 81
  [ "${GITLAB_API_PROTOCOL:-}" = "${FAKE_EXPECTED_PROTOCOL:?}" ] || exit 82
fi
EOF
chmod +x "${FAKE_GLAB}"

write_gitlab_env() {
  local token_line="$1"
  local wiki_line="${2:-}"

  cat >"${CONFIG_DIR}/gitlab.env" <<EOF
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
${token_line}
${wiki_line}
EOF
}

write_gitlab_env "GITLAB_TOKEN=config-token"
FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN="env-token" \
  PROJECT="req_executor_test" \
  GROUP="claw_gitlab" \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  bash -c 'source "$1"; printf "%s\n" "${GITLAB_TOKEN}"' _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/env-paths-token.out" 2>"${TEST_ROOT}/env-paths-token.err"

if ! grep -qx 'env-token' "${TEST_ROOT}/env-paths-token.out"; then
  echo "expected env_paths.sh to preserve process env GITLAB_TOKEN over config/gitlab.env" >&2
  cat "${TEST_ROOT}/env-paths-token.err" >&2
  exit 1
fi
if ! grep -qx 'env-token' "${TOKEN_LOG}"; then
  echo "expected glab auth bootstrap to receive process env GITLAB_TOKEN" >&2
  exit 1
fi

write_gitlab_env "GITLAB_TOKEN=config-token"
FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  bash "${SCRIPTS_DIR}/glab_auth.sh" >"${TEST_ROOT}/config-token.out" 2>"${TEST_ROOT}/config-token.err"

if ! grep -qx 'config-token' "${TOKEN_LOG}"; then
  echo "expected glab_auth.sh to use config/gitlab.env GITLAB_TOKEN when env is absent" >&2
  cat "${TEST_ROOT}/config-token.err" >&2
  exit 1
fi

write_gitlab_env "GITLAB_TOKEN=config-token"
FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN="masked-prefix…masked-suffix" \
  PROJECT="req_executor_test" \
  GROUP="claw_gitlab" \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  bash -c 'source "$1"; printf "%s\n" "${GITLAB_TOKEN}"' _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/masked-token.out" 2>"${TEST_ROOT}/masked-token.err"

if ! grep -qx 'masked-prefix…masked-suffix' "${TEST_ROOT}/masked-token.out"; then
  echo "expected env_paths.sh to preserve masked-looking process env GITLAB_TOKEN" >&2
  cat "${TEST_ROOT}/masked-token.err" >&2
  exit 1
fi
if ! grep -qx 'masked-prefix…masked-suffix' "${TOKEN_LOG}"; then
  echo "expected glab auth bootstrap to receive masked-looking process env GITLAB_TOKEN" >&2
  exit 1
fi

write_gitlab_env "GITLAB_TOKEN=config-token"
GITLAB_HOST="gitlab-b.pxsemic.tech:30000" \
  GITLAB_API_PROTOCOL="http" \
  GITLAB_TOKEN="masked-prefix…masked-suffix" \
  PROJECT="req_executor_test" \
  GROUP="claw_gitlab" \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  bash -c 'source "$1"; printf "%s\n" "${GITLAB_TOKEN}"' _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/masked-token-with-host.out" 2>"${TEST_ROOT}/masked-token-with-host.err"

if ! grep -qx 'masked-prefix…masked-suffix' "${TEST_ROOT}/masked-token-with-host.out"; then
  echo "expected env_paths.sh to preserve masked-looking GITLAB_TOKEN when host/protocol are already set" >&2
  cat "${TEST_ROOT}/masked-token-with-host.err" >&2
  exit 1
fi

write_gitlab_env "GITLAB_TOKEN=config-token-must-not-reach-local"
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<'EOF'
GITLAB_HOST=localhost:8081
GITLAB_API_PROTOCOL=https
REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true
REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081
EOF
: >"${TOKEN_LOG}"
env -u GITLAB_HOST -u GITLAB_API_PROTOCOL \
  FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" \
  FAKE_EXPECTED_HOST=localhost:8081 \
  FAKE_EXPECTED_PROTOCOL=https \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN=local-process-token \
  PROJECT=req_executor_test GROUP=claw_gitlab \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  bash -c 'source "$1"; printf "%s\n%s\n%s\n" "$GITLAB_HOST" "$GITLAB_API_PROTOCOL" "$GITLAB_TOKEN"' \
    _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/local-tuple.out" 2>"${TEST_ROOT}/local-tuple.err"
if ! cmp -s "${TEST_ROOT}/local-tuple.out" <(printf '%s\n' \
    localhost:8081 https local-process-token); then
  echo "expected env_paths.sh to preserve one coherent local GitLab tuple" >&2
  cat "${TEST_ROOT}/local-tuple.err" >&2
  exit 1
fi
if ! grep -qx local-process-token "${TOKEN_LOG}"; then
  echo "expected local target authentication to use the process token" >&2
  exit 1
fi

: >"${TOKEN_LOG}"
if env -u GITLAB_HOST -u GITLAB_API_PROTOCOL -u GITLAB_TOKEN \
  FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" GLAB_BIN="${FAKE_GLAB}" \
  PROJECT=req_executor_test GROUP=claw_gitlab \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  bash -c 'source "$1"' _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/local-no-token.out" 2>"${TEST_ROOT}/local-no-token.err"
then
  echo "expected local GitLab target to reject tracked-token fallback" >&2
  exit 1
fi
[ ! -s "${TOKEN_LOG}" ] || {
  echo "local target reached glab with the tracked deployment token" >&2
  exit 1
}

cat >>"${CONFIG_DIR}/campaign_defaults.local.env" <<'EOF'
GITLAB_TOKEN=local-file-token
EOF
: >"${TOKEN_LOG}"
env -u GITLAB_HOST -u GITLAB_API_PROTOCOL -u GITLAB_TOKEN \
  FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" \
  FAKE_EXPECTED_HOST=localhost:8081 \
  FAKE_EXPECTED_PROTOCOL=https \
  GLAB_BIN="${FAKE_GLAB}" \
  PROJECT=req_executor_test GROUP=claw_gitlab \
  REPO_PARENT_PATH="${REPO_PARENT}" \
  bash -c 'source "$1"; printf "%s\n%s\n%s\n" "$GITLAB_HOST" "$GITLAB_API_PROTOCOL" "$GITLAB_TOKEN"' \
    _ "${SCRIPTS_DIR}/env_paths.sh" \
  >"${TEST_ROOT}/local-file-token.out" \
  2>"${TEST_ROOT}/local-file-token.err"
if ! cmp -s "${TEST_ROOT}/local-file-token.out" <(printf '%s\n' \
    localhost:8081 https local-file-token); then
  echo "expected local target to use its same-file token" >&2
  cat "${TEST_ROOT}/local-file-token.err" >&2
  exit 1
fi
grep -qx local-file-token "${TOKEN_LOG}" || {
  echo "local-file token did not reach local authentication" >&2
  exit 1
}

env -u GITLAB_HOST -u GITLAB_API_PROTOCOL -u GITLAB_TOKEN \
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_SCHEDULER_ROOT=caller-scheduler-root \
  bash -c 'source "$1"; printf "%s\n%s\n%s\n%s\n" "$GITLAB_HOST" "$GITLAB_API_PROTOCOL" "$GITLAB_TOKEN" "$EXECUTOR_SCHEDULER_ROOT"' \
    _ "${SCRIPTS_DIR}/gitlab_env_resolver.sh" \
  >"${TEST_ROOT}/shared-resolver.out" \
  2>"${TEST_ROOT}/shared-resolver.err"
if ! cmp -s "${TEST_ROOT}/shared-resolver.out" <(printf '%s\n' \
    localhost:8081 https local-file-token caller-scheduler-root); then
  echo "shared resolver mixed the local tuple or clobbered scheduler settings" >&2
  cat "${TEST_ROOT}/shared-resolver.err" >&2
  exit 1
fi

BAD_SCRIPTS_DIR="${TEST_ROOT}/bad-resolver/scripts"
mkdir -p "${BAD_SCRIPTS_DIR}"
cp "${SKILL_DIR}/scripts/gitlab_env_resolver.sh" \
  "${BAD_SCRIPTS_DIR}/gitlab_env_resolver.sh"
cat >"${BAD_SCRIPTS_DIR}/glab_auth.sh" <<'EOF'
GITLAB_HOST=localhost:8081
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=must-not-survive-resolver-failure
GITLAB_TARGET_SOURCE=invalid-source
GITLAB_TOKEN_SOURCE=local
GLAB_CONFIG_DIR=
return 0
EOF
if ! bash -c '
  if source "$1" 2>/dev/null; then
    exit 90
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || exit 91
  [ -z "${__GITLAB_RESOLVER_JSON+x}" ] || exit 92
  [ -z "${__GITLAB_RESOLVER_RC+x}" ] || exit 93
  ! declare -F __gitlab_env_resolver_main >/dev/null || exit 94
' _ "${BAD_SCRIPTS_DIR}/gitlab_env_resolver.sh"; then
  echo "shared resolver retained private failure state in the caller" >&2
  exit 1
fi
mv "${CONFIG_DIR}/campaign_defaults.local.env" \
  "${CONFIG_DIR}/campaign_defaults.local.env.tested"

write_gitlab_env "GITLAB_TOKEN=" "WIKI_GITLAB_TOKEN=wiki-token"
if FAKE_GLAB_TOKEN_LOG="${TOKEN_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  bash "${SCRIPTS_DIR}/glab_auth.sh" >"${TEST_ROOT}/wiki-token.out" 2>"${TEST_ROOT}/wiki-token.err"
then
  echo "expected glab_auth.sh to reject WIKI_GITLAB_TOKEN fallback" >&2
  exit 1
fi

if ! grep -q 'GITLAB_TOKEN must be set' "${TEST_ROOT}/wiki-token.err"; then
  echo "expected missing GITLAB_TOKEN error when only WIKI_GITLAB_TOKEN is configured" >&2
  cat "${TEST_ROOT}/wiki-token.err" >&2
  exit 1
fi

echo "ok GitLab token source order"
