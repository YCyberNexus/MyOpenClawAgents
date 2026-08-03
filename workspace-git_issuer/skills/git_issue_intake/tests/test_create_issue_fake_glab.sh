#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-issuer-create.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
LOG_FILE="${TEST_ROOT}/glab.log"
DESC_FILE="${TEST_ROOT}/description.txt"

mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/glab" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_GLAB_LOG}"

for arg in "$@"; do
  case "${arg}" in
    description=@*)
      description_path="${arg#description=@}"
      while IFS= read -r line || [ -n "${line}" ]; do
        printf '%s\n' "${line}"
      done <"${description_path}" >"${FAKE_DESCRIPTION_CAPTURE}"
      ;;
  esac
done

case "$*" in
  "auth login --hostname gitlab-b.pxsemic.tech:30000 --token fake-token --api-protocol http")
    exit 0
    ;;
  "auth status --hostname gitlab-b.pxsemic.tech:30000")
    exit 0
    ;;
  "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues"*)
    printf '{"iid":312,"web_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312"}\n'
    exit 0
    ;;
  "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312 -f add_labels=todo")
    printf '{}\n'
    exit 0
    ;;
  "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312/notes"*)
    printf '{}\n'
    exit 0
    ;;
esac

echo "unexpected glab call: $*" >&2
exit 44
FAKE
chmod +x "${FAKE_BIN}/glab"

printf '实现登录接口验收用例\n\norigin line should stay in description\n' >"${DESC_FILE}"

out="$(
  PATH="${FAKE_BIN}:${PATH}" \
  FAKE_GLAB_LOG="${LOG_FILE}" \
  GITLAB_HOST="gitlab-b.pxsemic.tech:30000" \
  GITLAB_API_PROTOCOL="http" \
  GITLAB_TOKEN="fake-token" \
  DEFAULT_ENTRY_LABEL="todo" \
  PROJECT_FULL="claw_gitlab/px_ifp_hulat_test" \
  ISSUE_TITLE="登录接口验收" \
  ISSUE_DESCRIPTION_FILE="${DESC_FILE}" \
  ISSUE_BASE_BRANCH="release/2026.08" \
  ORIGIN_JSON='{"channel":"wecom","user":"u1"}' \
  FAKE_DESCRIPTION_CAPTURE="${TEST_ROOT}/submitted-description.txt" \
  bash "${SKILL_DIR}/scripts/create_issue.sh"
)"

assert_json_field() {
  local json="$1"
  local jq_expr="$2"
  local expected="$3"
  local actual
  actual="$(printf '%s' "${json}" | jq -r "${jq_expr}")"
  if [ "${actual}" != "${expected}" ]; then
    echo "expected ${jq_expr}=${expected}, got ${actual}" >&2
    echo "json: ${json}" >&2
    exit 1
  fi
}

assert_log_contains() {
  local expected="$1"
  if ! grep -Fq -- "${expected}" "${LOG_FILE}"; then
    echo "expected glab log to contain: ${expected}" >&2
    echo "actual log:" >&2
    cat "${LOG_FILE}" >&2
    exit 1
  fi
}

assert_log_contains "auth login --hostname gitlab-b.pxsemic.tech:30000 --token fake-token --api-protocol http"
assert_log_contains "auth status --hostname gitlab-b.pxsemic.tech:30000"
assert_log_contains "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues"
assert_log_contains "-f title=登录接口验收"
assert_log_contains "-F description=@"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312 -f add_labels=todo"
assert_log_contains "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312/notes -F body=@"

assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.action' 'created'
assert_json_field "${out}" '.issue_iid' '312'
assert_json_field "${out}" '.issue_url' 'http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312'
assert_json_field "${out}" '.project' 'claw_gitlab/px_ifp_hulat_test'
assert_json_field "${out}" '.entry_label' 'todo'
assert_json_field "${out}" '.reason' 'null'

if [ "$(sed -n '1p' "${TEST_ROOT}/submitted-description.txt")" != \
    '<!-- req_executor_base_branch:v1 branch=release/2026.08 -->' ]; then
  echo "expected the submitted Issue description to start with branch metadata" >&2
  sed -n '1,20p' "${TEST_ROOT}/submitted-description.txt" >&2
  exit 1
fi
grep -Fq '实现登录接口验收用例' "${TEST_ROOT}/submitted-description.txt" \
  || { echo "branch metadata rewrite lost the original description" >&2; exit 1; }

before_invalid_calls="$(wc -l <"${LOG_FILE}" | tr -d '[:space:]')"
set +e
invalid_out="$(
  PATH="${FAKE_BIN}:${PATH}" \
  FAKE_GLAB_LOG="${LOG_FILE}" \
  FAKE_DESCRIPTION_CAPTURE="${TEST_ROOT}/invalid-description.txt" \
  GITLAB_HOST="gitlab-b.pxsemic.tech:30000" \
  GITLAB_API_PROTOCOL="http" \
  GITLAB_TOKEN="fake-token" \
  DEFAULT_ENTRY_LABEL="todo" \
  PROJECT_FULL="claw_gitlab/px_ifp_hulat_test" \
  ISSUE_TITLE="非法分支" \
  ISSUE_DESCRIPTION="body" \
  ISSUE_BASE_BRANCH='../unsafe' \
  bash "${SKILL_DIR}/scripts/create_issue.sh"
)"
invalid_rc=$?
set -e
[ "${invalid_rc}" -eq 2 ] \
  || { echo "invalid Issue branch returned unexpected exit ${invalid_rc}" >&2; exit 1; }
assert_json_field "${invalid_out}" '.status' 'failed'
assert_json_field "${invalid_out}" '.reason' 'ISSUE_BASE_BRANCH must be a safe Git ref name'
after_invalid_calls="$(wc -l <"${LOG_FILE}" | tr -d '[:space:]')"
[ "${before_invalid_calls}" = "${after_invalid_calls}" ] \
  || { echo "invalid Issue branch reached GitLab" >&2; exit 1; }

echo "ok create_issue fake glab"
