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
chmod +x "${SCRIPTS_DIR}/glab_auth.sh" "${SCRIPTS_DIR}/env_paths.sh"

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
