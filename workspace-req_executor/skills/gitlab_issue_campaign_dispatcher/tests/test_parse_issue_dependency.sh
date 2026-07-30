#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PARSER="${SKILL_DIR}/scripts/parse_issue_dependency.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run_parser() {
  local current_iid="$1"
  local description="$2"

  printf '%s' "${description}" | ISSUE_IID="${current_iid}" bash "${PARSER}"
}

assert_json() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local expected_canonical=""
  local actual_canonical=""

  expected_canonical="$(jq -cS . <<<"${expected}")" \
    || fail "${label}: test expectation is not JSON"
  actual_canonical="$(jq -cS . <<<"${actual}")" \
    || fail "${label}: parser output is not strict JSON: ${actual}"
  [[ "${actual_canonical}" == "${expected_canonical}" ]] \
    || fail "${label}: expected ${expected_canonical}, got ${actual_canonical}"
}

assert_resolved() {
  local label="$1"
  local description="$2"
  local dependency_iid="$3"
  local actual=""

  actual="$(run_parser 999 "${description}")"
  assert_json "${label}" \
    "{\"status\":\"resolved\",\"dependency_iid\":${dependency_iid},\"base_branch\":\"issue/${dependency_iid}\"}" \
    "${actual}"
}

assert_resolved 'recommended Chinese syntax' '依赖 Issue #123' 123
assert_resolved 'compact Chinese Issue syntax' '依赖Issue #123' 123
assert_resolved 'Chinese depends-on syntax' '依赖于 #124' 124
assert_resolved 'Chinese depends-on Issue syntax' '依赖于 Issue #124' 124
assert_resolved 'compact Chinese depends-on Issue syntax' '依赖于Issue #124' 124
assert_resolved 'Chinese prerequisite syntax' '前置 Issue: #125' 125
assert_resolved 'English depends-on syntax' 'Depends on #126' 126
assert_resolved 'English depends-on Issue syntax' 'Depends on Issue #126' 126
assert_resolved 'English blocked-by syntax' 'Blocked by #127' 127
assert_resolved 'English dependency syntax' 'dependency: #128' 128
assert_resolved 'machine-readable syntax' 'depends_on: 129' 129
assert_resolved 'English matching is case-insensitive' 'BLOCKED BY #130' 130
assert_resolved 'Chinese line-start prefix with trailing metadata' \
  '依赖 Issue #131 page-name: Service' 131
assert_resolved 'compact lowercase line-start prefix with trailing metadata' \
  '依赖issue #132 page-name: Service' 132
assert_resolved 'English line-start prefix with trailing metadata' \
  'Blocked by #133 page-name: Service' 133
assert_resolved 'maximum GitLab IID' '依赖 Issue #2147483647' 2147483647

assert_resolved 'Markdown list and bold prefixes' '- **依赖 Issue #201**' 201
assert_resolved 'Markdown heading and bold prefixes' '### **Depends on #202**' 202
assert_resolved 'Markdown ordered-list prefix' '1. **前置 Issue: #203**' 203
assert_resolved 'combined Markdown prefixes' $'> - **dependency: #204**' 204

duplicate_output="$(run_parser 999 $'依赖 Issue #301\nDepends on #301\n- **depends_on: 301**')"
assert_json 'duplicate declarations are deduplicated' \
  '{"status":"resolved","dependency_iid":301,"base_branch":"issue/301"}' \
  "${duplicate_output}"

none_output="$(run_parser 999 $'实现普通功能。\n这个任务依赖 Issue #401。\n参考 #401，但这不是声明。')"
assert_json 'prose and inline references are ignored' '{"status":"none"}' "${none_output}"

code_example_output="$(run_parser 999 $'示例：\n```yaml\ndependency: #410\n```\n~~~text\n依赖 Issue #411\n~~~\n    Depends on #412\n\tBlocked by #413\n> ````yaml\n> dependency: #414\n> ```\n> Depends on #415\n> ````')"
assert_json 'fenced and indented Markdown code examples are ignored' \
  '{"status":"none"}' "${code_example_output}"

html_comment_output="$(run_parser 999 $'<!--\ndependency: #409\n-->\n正文。\n<!-- Depends on #410 -->')"
assert_json 'Markdown HTML comments are ignored' \
  '{"status":"none"}' "${html_comment_output}"

html_comment_then_dependency="$(run_parser 999 $'<!-- dependency: #411 -->\nDepends on #412 <!-- visible declaration suffix -->')"
assert_json 'visible declaration after HTML comments is preserved' \
  '{"status":"resolved","dependency_iid":412,"base_branch":"issue/412"}' \
  "${html_comment_then_dependency}"

inline_code_comment_opener="$(run_parser 999 $'说明：使用 `<!--` 写注释\ndependency: #413')"
assert_json 'HTML comment opener inside inline code is literal' \
  '{"status":"resolved","dependency_iid":413,"base_branch":"issue/413"}' \
  "${inline_code_comment_opener}"

multi_backtick_comment_opener="$(run_parser 999 $'说明：使用 ``<!-- `示例` -->`` 写注释\nDepends on #414')"
assert_json 'HTML markers inside multi-backtick code spans are literal' \
  '{"status":"resolved","dependency_iid":414,"base_branch":"issue/414"}' \
  "${multi_backtick_comment_opener}"

multiline_code_comment_opener="$(run_parser 999 $'说明：`<!--\n示例`\ndependency: #415')"
assert_json 'HTML opener inside multiline code span is literal' \
  '{"status":"resolved","dependency_iid":415,"base_branch":"issue/415"}' \
  "${multiline_code_comment_opener}"

escaped_comment_opener="$(run_parser 999 $'说明：\\<!--\ndependency: #416')"
assert_json 'backslash-escaped HTML opener is literal' \
  '{"status":"resolved","dependency_iid":416,"base_branch":"issue/416"}' \
  "${escaped_comment_opener}"

indented_code_comment_opener="$(run_parser 999 $'    <!--\ndependency: #417')"
assert_json 'HTML opener inside indented code is literal' \
  '{"status":"resolved","dependency_iid":417,"base_branch":"issue/417"}' \
  "${indented_code_comment_opener}"

trailing_code_declaration="$(run_parser 999 'Depends on #418 `note`')"
assert_json 'dependency declaration permits trailing inline code' \
  '{"status":"resolved","dependency_iid":418,"base_branch":"issue/418"}' \
  "${trailing_code_declaration}"

wrapped_code_target="$(run_parser 999 'dependency: `#419`')"
assert_json 'inline-code dependency target is invalid' \
  '{"status":"invalid","reason":"invalid_dependency_target"}' \
  "${wrapped_code_target}"

leading_code_reference="$(run_parser 999 '`note` Depends on #420')"
assert_json 'leading inline code does not create a declaration' \
  '{"status":"none"}' "${leading_code_reference}"

literal_container_markers_output="$(run_parser 999 $'```yaml\n- ```\ndependency: #419\n```\n> ```yaml\n> > ```\n> dependency: #420\n> ```')"
assert_json 'container-like code inside active fences stays literal' \
  '{"status":"none"}' "${literal_container_markers_output}"

nested_container_order_output="$(run_parser 999 $'- > ```yaml\n  > dependency: #421\n  > ```')"
assert_json 'list then blockquote fenced code is ignored' \
  '{"status":"none"}' "${nested_container_order_output}"

quote_container_end_output="$(run_parser 999 $'> ```yaml\n> sample: true\ndependency: #416')"
assert_json 'dependency after an unterminated blockquote fence is visible' \
  '{"status":"resolved","dependency_iid":416,"base_branch":"issue/416"}' \
  "${quote_container_end_output}"

list_container_end_output="$(run_parser 999 $'- ```yaml\n  sample: true\ndependency: #417')"
assert_json 'dependency after an unterminated list fence is visible' \
  '{"status":"resolved","dependency_iid":417,"base_branch":"issue/417"}' \
  "${list_container_end_output}"

invalid_backtick_info_output="$(run_parser 999 $'```yaml`example\ndependency: #418')"
assert_json 'invalid backtick fence info does not hide following metadata' \
  '{"status":"resolved","dependency_iid":418,"base_branch":"issue/418"}' \
  "${invalid_backtick_info_output}"

negative_output="$(run_parser 999 $'不依赖 #402\n- **不依赖 #403**')"
assert_json 'negative Chinese statements are ignored' '{"status":"none"}' "${negative_output}"

multiple_output="$(run_parser 999 $'依赖 Issue #501\nBlocked by #502')"
assert_json 'multiple different dependencies are invalid' \
  '{"status":"invalid","reason":"multiple_dependencies"}' \
  "${multiple_output}"

self_output="$(run_parser 601 '依赖于 #601')"
assert_json 'self dependency is invalid' \
  '{"status":"invalid","reason":"self_dependency"}' \
  "${self_output}"

for invalid_description in \
  '依赖 Issue #abc' \
  '依赖于' \
  '前置 Issue: #0' \
  '依赖 Issue #2147483648' \
  'Depends on #-2' \
  'Blocked by #123trailing' \
  'dependency:' \
  'depends_on: zero'; do
  invalid_output="$(run_parser 999 "${invalid_description}")"
  assert_json "invalid target: ${invalid_description}" \
    '{"status":"invalid","reason":"invalid_dependency_target"}' \
    "${invalid_output}"
done

mixed_invalid_output="$(run_parser 999 $'依赖 Issue #701\ndependency: invalid')"
assert_json 'an invalid declaration invalidates otherwise valid declarations' \
  '{"status":"invalid","reason":"invalid_dependency_target"}' \
  "${mixed_invalid_output}"

set +e
configuration_output="$(printf '依赖 Issue #1' | ISSUE_IID=invalid bash "${PARSER}" 2>/dev/null)"
configuration_status=$?
set -e
[[ ${configuration_status} -ne 0 ]] \
  || fail 'invalid ISSUE_IID should be a non-semantic execution failure'
[[ -z "${configuration_output}" ]] \
  || fail 'invalid ISSUE_IID should not emit semantic JSON'

printf 'ok issue dependency parser\n'
