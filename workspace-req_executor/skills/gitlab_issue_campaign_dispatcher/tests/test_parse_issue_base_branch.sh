#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$(cd "${SCRIPT_DIR}/../scripts" && pwd)/parse_issue_base_branch.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_result() {
  local label="$1"
  local input="$2"
  local expected_status="$3"
  local expected_branch="$4"
  local expected_reason="$5"
  local output

  output="$(printf '%s' "${input}" | bash "${PARSER}")" \
    || fail "${label}: parser exited nonzero"
  jq -e \
    --arg status "${expected_status}" \
    --arg branch "${expected_branch}" \
    --arg reason "${expected_reason}" '
      .status == $status
      and .branch == (if $branch == "" then null else $branch end)
      and .reason == (if $reason == "" then null else $reason end)
    ' <<<"${output}" >/dev/null \
    || { printf '%s: unexpected result: %s\n' "${label}" "${output}" >&2; exit 1; }
}

assert_result none 'ordinary requirement body' none '' ''
assert_result marker \
  '<!-- req_executor_base_branch:v1 branch=release/2026.08 -->' \
  resolved release/2026.08 ''
assert_result assignment 'base_branch=feature/issue-origin' \
  resolved feature/issue-origin ''
assert_result source_assignment 'source_branch: hotfix/v1.2' \
  resolved hotfix/v1.2 ''
assert_result chinese '该 Issue 基于 release/cn 分支创建。' \
  resolved release/cn ''
assert_result chinese_benchmark '本需求以 release/base 分支为基准。' \
  resolved release/base ''
assert_result english 'This issue is based on release/en branch.' \
  resolved release/en ''
assert_result english_preserves_case \
  'This issue is based on Release/Prod branch.' \
  resolved Release/Prod ''
assert_result duplicate_same $'base_branch=release/same\n基于 release/same 分支创建' \
  resolved release/same ''
assert_result conflict $'base_branch=release/one\nsource_branch=release/two' \
  conflict '' conflicting_issue_base_branches
assert_result chinese_inline_ambiguity \
  '该 Issue 基于 release/one 分支或 release/two 分支处理。' \
  conflict '' conflicting_issue_base_branches
assert_result english_inline_ambiguity \
  'This issue is based on release/one branch or release/two branch.' \
  conflict '' conflicting_issue_base_branches
assert_result chinese_implicit_first_choice \
  '该 Issue 基于 release/one 或 release/two 分支处理。' \
  conflict '' conflicting_issue_base_branches
assert_result unsafe 'base_branch=../unsafe' \
  invalid '' unsafe_issue_base_branch
assert_result negated '不要基于 release/old 分支处理。' none '' ''
assert_result negated_polite '请勿基于 release/old 分支处理。' none '' ''
assert_result negated_cannot '不能基于 release/old 分支处理。' none '' ''
assert_result negated_should_not '不应基于 release/old 分支处理。' none '' ''
assert_result negated_not_the_case '该 Issue 并非基于 release/old 分支。' none '' ''
assert_result english_negated_contraction \
  "This issue shouldn't be based on release/old branch." none '' ''
assert_result fenced $'```text\nbase_branch=docs/example\n```' none '' ''
assert_result tilde_fenced $'~~~text\nbase_branch=docs/example\n~~~' none '' ''
assert_result mixed_fence_delimiters \
  $'```text\n~~~\nbase_branch=docs/example\n```' none '' ''
assert_result longer_fence_contains_shorter \
  $'````text\n```\nbase_branch=docs/example\n````' none '' ''

echo "ok parse Issue base branch"
