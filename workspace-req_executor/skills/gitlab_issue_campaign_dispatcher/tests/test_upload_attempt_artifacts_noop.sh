#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPLOAD_SCRIPT="${SKILL_DIR}/scripts/upload_attempt_artifacts.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-no-wiki.XXXXXX")"
REPO_PATH="${TEST_ROOT}/repo"
FAKE_BIN="${TEST_ROOT}/bin"
GLAB_CALLS="${TEST_ROOT}/glab-calls.txt"

mkdir -p "${FAKE_BIN}" "${REPO_PATH}/.git"

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GLAB_CALLS:?}"
case "${1:-}" in
  auth)
    exit 0
    ;;
  api)
    printf '{}\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${FAKE_BIN}/glab"

LOG_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-7/.req_executor/issue-7/log/attempt-001"
mkdir -p "${LOG_DIR}"
printf 'prompt body\n' >"${LOG_DIR}/prompt.txt"
printf 'claude result\n' >"${LOG_DIR}/claude_result.txt"

PROJECT=demo \
GROUP=group \
GITLAB_TOKEN=fake-token \
GLAB_BIN="${FAKE_BIN}/glab" \
GLAB_CALLS="${GLAB_CALLS}" \
PATH="${FAKE_BIN}:${PATH}" \
REPO_PATH="${REPO_PATH}" \
ISSUE_IID=7 \
ATTEMPT_NUMBER=1 \
bash "${UPLOAD_SCRIPT}" >/dev/null

api_calls=0
if [ -f "${GLAB_CALLS}" ]; then
  api_calls="$(grep -c '^api ' "${GLAB_CALLS}" || true)"
fi

if [ "${api_calls}" != "0" ]; then
  echo "upload_attempt_artifacts.sh should be a no-op and must not call glab api; saw ${api_calls} api call(s)" >&2
  exit 1
fi

echo "ok upload_attempt_artifacts is a no-op"
