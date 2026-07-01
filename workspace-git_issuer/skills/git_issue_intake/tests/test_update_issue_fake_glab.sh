#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-issuer-update.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
LOG_FILE="${TEST_ROOT}/glab.log"
DESC_FILE="${TEST_ROOT}/description.txt"

mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/glab" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_GLAB_LOG}"

case "$*" in
  "auth login --hostname gitlab-b.pxsemic.tech:30000 --token fake-token --api-protocol http")
    exit 0
    ;;
  "auth status --hostname gitlab-b.pxsemic.tech:30000")
    exit 0
    ;;
  "api projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312")
    printf '{"iid":312,"state":"opened","labels":["todo"],"web_url":"http://example/312"}\n'
    exit 0
    ;;
  "api projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/313")
    printf '{"iid":313,"state":"opened","labels":["doing"],"web_url":"http://example/313"}\n'
    exit 0
    ;;
  "api projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/314")
    printf '{"iid":314,"state":"opened","labels":["pr"],"web_url":"http://example/314"}\n'
    exit 0
    ;;
  "api projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/315")
    printf '{"iid":315,"state":"opened","labels":["todo"],"web_url":"http://example/315"}\n'
    exit 0
    ;;
  "api projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/316")
    printf '{"iid":316,"state":"opened","labels":["doing"],"web_url":"http://example/316"}\n'
    exit 0
    ;;
  "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/"*"-F description=@"*)
    printf '{}\n'
    exit 0
    ;;
  "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/"*"/notes -F body=@"*)
    printf '{}\n'
    exit 0
    ;;
  "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/313 -f add_labels=retry")
    printf '{}\n'
    exit 0
    ;;
  "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/314 -f add_labels=continue")
    printf '{}\n'
    exit 0
    ;;
  "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/"*"-f state_event=close")
    printf '{}\n'
    exit 0
    ;;
  "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues -f title=Supersede flow -F description=@"*)
    printf '{"iid":401,"web_url":"http://example/401"}\n'
    exit 0
    ;;
  "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/401 -f add_labels=todo")
    printf '{}\n'
    exit 0
    ;;
esac

echo "unexpected glab call: $*" >&2
exit 44
FAKE
chmod +x "${FAKE_BIN}/glab"

printf '更新后的需求描述\n' >"${DESC_FILE}"

run_update() {
  local issue_iid="$1"
  local change_action="$2"
  local rerun_label="${3:-}"
  local title="${4:-}"

  PATH="${FAKE_BIN}:${PATH}" \
    FAKE_GLAB_LOG="${LOG_FILE}" \
    GITLAB_HOST="gitlab-b.pxsemic.tech:30000" \
    GITLAB_API_PROTOCOL="http" \
    GITLAB_TOKEN="fake-token" \
    DEFAULT_ENTRY_LABEL="todo" \
    PROJECT_FULL="claw_gitlab/px_ifp_hulat_test" \
    ISSUE_IID="${issue_iid}" \
    CHANGE_ACTION="${change_action}" \
    RERUN_LABEL="${rerun_label}" \
    ISSUE_TITLE="${title}" \
    ISSUE_DESCRIPTION_FILE="${DESC_FILE}" \
    CHANGE_NOTE="测试变更说明" \
    bash "${SKILL_DIR}/scripts/update_issue.sh"
}

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

out="$(run_update 312 update)"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.action' 'updated'
assert_json_field "${out}" '.issue_iid' '312'
assert_json_field "${out}" '.issue_url' 'http://example/312'
assert_json_field "${out}" '.entry_label' 'null'

out="$(run_update 313 update retry)"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.action' 'updated+relabeled'
assert_json_field "${out}" '.entry_label' 'retry'

out="$(run_update 314 update continue)"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.action' 'updated+relabeled'
assert_json_field "${out}" '.entry_label' 'continue'

out="$(run_update 315 cancel)"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.action' 'closed'
assert_json_field "${out}" '.issue_iid' '315'

out="$(run_update 316 supersede "" "Supersede flow")"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.action' 'superseded'
assert_json_field "${out}" '.issue_iid' '316'
assert_json_field "${out}" '.superseded_by' '401'
assert_json_field "${out}" '.entry_label' 'todo'

set +e
invalid_out="$(run_update 312 update doing)"
invalid_code=$?
set -e
if [ "${invalid_code}" -eq 0 ]; then
  echo "expected invalid rerun label to fail" >&2
  exit 1
fi
assert_json_field "${invalid_out}" '.status' 'failed'
assert_json_field "${invalid_out}" '.reason' 'RERUN_LABEL must be retry or continue'

assert_log_contains "api projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312 -F description=@"
assert_log_contains "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/312/notes -F body=@"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/313 -f add_labels=retry"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/314 -f add_labels=continue"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/315 -f state_event=close"
assert_log_contains "api --method POST projects/claw_gitlab%2Fpx_ifp_hulat_test/issues -f title=Supersede flow -F description=@"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/401 -f add_labels=todo"
assert_log_contains "api --method PUT projects/claw_gitlab%2Fpx_ifp_hulat_test/issues/316 -f state_event=close"

echo "ok update_issue fake glab"
