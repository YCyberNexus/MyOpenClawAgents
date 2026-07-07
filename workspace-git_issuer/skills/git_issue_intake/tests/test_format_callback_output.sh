#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

callback='{"status":"success","action":"created","issue_iid":312,"issue_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312","project":"claw_gitlab/px_ifp_hulat_test","entry_label":"todo","superseded_by":null,"reason":null,"correlation_id":null}'
requirement_text="$(cat <<'EOF'
CREATE_GITLAB_ISSUE
repo=claw_gitlab/px_ifp_hulat_test
source=req_dispatcher_wiki
wiki_url=http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements
wiki_section=登录流程
wiki_item_ordinal=7
EOF
)"

out="$(
  CALLBACK_JSON="${callback}" \
  REQUIREMENT_TEXT="${requirement_text}" \
  ISSUE_TITLE="登录接口验收" \
  bash "${SKILL_DIR}/scripts/format_callback_output.sh"
)"

if ! grep -Fq 'Issue 已创建成功:' <<<"${out}"; then
  echo "expected human-readable success heading" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

if ! grep -Fq -- '- #312 登录接口验收 ✅ (TODO)' <<<"${out}"; then
  echo "expected issue summary bullet" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

fenced_json="$(
  printf '%s\n' "${out}" | awk '
    in_fence && /^```$/ {in_fence=0; next}
    in_fence {print}
    /^```json$/ {in_fence=1}
  '
)"

assert_json_field() {
  local jq_expr="$1"
  local expected="$2"
  local actual
  actual="$(printf '%s' "${fenced_json}" | jq -r "${jq_expr}")"
  if [ "${actual}" != "${expected}" ]; then
    echo "expected ${jq_expr}=${expected}, got ${actual}" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  fi
}

assert_json_field '.req_dispatcher.action' 'create_issue'
assert_json_field '.req_dispatcher.repo' 'claw_gitlab/px_ifp_hulat_test'
assert_json_field '.req_dispatcher.source' 'req_dispatcher_wiki'
assert_json_field '.req_dispatcher.wiki_section' '登录流程'
assert_json_field '.req_dispatcher.wiki_item_ordinal' '7'
assert_json_field '.req_dispatcher.result.issue_iid' '312'
assert_json_field '.req_dispatcher.result.title' '登录接口验收'
assert_json_field '.req_dispatcher.result.status' 'created'
assert_json_field '.status' 'success'
assert_json_field '.project' 'claw_gitlab/px_ifp_hulat_test'
assert_json_field '.issue_iid' '312'
assert_json_field '.issue_url' 'http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312'

echo "ok format_callback_output emits blue-style markdown"
