#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-issuer-parse.XXXXXX")"
ROUTING_FILE="${TEST_ROOT}/project_routing.env"

cat >"${ROUTING_FILE}" <<'DATA'
# comment
claw_gitlab/px_ifp_hulat_test|px_ifp_hulat_test,ifp,hulat
other_group/other_project|other-alias
DATA

run_parse() {
  local text="$1"
  ROUTING_FILE="${ROUTING_FILE}" \
  REQUIREMENT_TEXT="${text}" \
  bash "${SKILL_DIR}/scripts/parse_project.sh"
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

out="$(run_parse "请在 ifp 项目创建登录测试需求")"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.project' 'claw_gitlab/px_ifp_hulat_test'
assert_json_field "${out}" '.group' 'claw_gitlab'
assert_json_field "${out}" '.project_slug' 'px_ifp_hulat_test'
assert_json_field "${out}" '.matched' 'ifp'

out="$(run_parse "请在 px_ifp_hulat_test 创建需求")"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.project' 'claw_gitlab/px_ifp_hulat_test'
assert_json_field "${out}" '.matched' 'px_ifp_hulat_test'

out="$(run_parse "项目 claw_gitlab/px_ifp_hulat_test 需要新增用例")"
assert_json_field "${out}" '.status' 'success'
assert_json_field "${out}" '.project' 'claw_gitlab/px_ifp_hulat_test'
assert_json_field "${out}" '.matched' 'claw_gitlab/px_ifp_hulat_test'

out="$(run_parse "完全未知项目")"
assert_json_field "${out}" '.status' 'failed'
assert_json_field "${out}" '.project' 'null'
assert_json_field "${out}" '.reason' '无法从需求文本解析出目标 project'

echo "ok parse_project"
