#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-project-id.XXXXXX")"
FAKE_GLAB="${TEST_ROOT}/glab"
CALL_LOG="${TEST_ROOT}/glab.calls"

cat >"${FAKE_GLAB}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${CALL_LOG:?CALL_LOG required}"
[ "$#" -eq 2 ] && [ "$1" = api ] || exit 8
[ "$2" = "projects/${EXPECTED_PROJECT_ID:?EXPECTED_PROJECT_ID required}" ] || exit 9
[ "${GITLAB_HOST:-}" = "${EXPECTED_GITLAB_HOST:?EXPECTED_GITLAB_HOST required}" ] || exit 10
[ "${GITLAB_API_PROTOCOL:-}" = "${EXPECTED_GITLAB_PROTOCOL:?EXPECTED_GITLAB_PROTOCOL required}" ] || exit 11
[ "${GITLAB_TOKEN:-}" = "${EXPECTED_GITLAB_TOKEN:?EXPECTED_GITLAB_TOKEN required}" ] || exit 12
[ "${FAKE_GLAB_FAIL:-false}" != true ] || exit 13

jq -nc \
  --argjson id "${FAKE_RESPONSE_ID:-${EXPECTED_PROJECT_ID}}" \
  --arg path "${FAKE_PROJECT_PATH:-ai-infra/one_stop_ui_testing}" \
  '{id:$id,path_with_namespace:$path}'
FAKE
chmod +x "${FAKE_GLAB}"

call_count() {
  if [ ! -f "${CALL_LOG}" ]; then
    printf '0\n'
    return
  fi
  awk 'END { print NR + 0 }' "${CALL_LOG}"
}

run_with_wiki_tuple() {
  MESSAGE="$1" \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
  EXPECTED_PROJECT_ID="${EXPECTED_PROJECT_ID:-55}" \
  EXPECTED_GITLAB_HOST="${EXPECTED_GITLAB_HOST:-gitlab-b.pxsemic.tech:30000}" \
  EXPECTED_GITLAB_PROTOCOL="${EXPECTED_GITLAB_PROTOCOL:-http}" \
  EXPECTED_GITLAB_TOKEN="${EXPECTED_GITLAB_TOKEN:-read-only-test-token}" \
  FAKE_RESPONSE_ID="${FAKE_RESPONSE_ID:-55}" \
  FAKE_PROJECT_PATH="${FAKE_PROJECT_PATH:-ai-infra/one_stop_ui_testing}" \
  FAKE_GLAB_FAIL="${FAKE_GLAB_FAIL:-false}" \
  WIKI_GITLAB_HOST="${WIKI_GITLAB_HOST:-gitlab-b.pxsemic.tech:30000}" \
  WIKI_GITLAB_API_PROTOCOL="${WIKI_GITLAB_API_PROTOCOL:-http}" \
  WIKI_GITLAB_TOKEN="${WIKI_GITLAB_TOKEN:-read-only-test-token}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
}

screenshot_prompt='执行仓库 one_stop_ui_testing（gitlab-b.pxsemic.tech:30000，项目ID 55）中的 Issue #3，标题：一站式业务 ui 自动化测试。执行完成后，结果保存在 one-stop-result 目录下以 job-ID 命名的子目录中，并且将执行分支合并到 master 分支。'
screenshot_result="$(run_with_wiki_tuple "${screenshot_prompt}")"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/one_stop_ui_testing"
  and .selector == {type:"single",iid:3}
  and .target_branch == "master"
  and .merge_target_branch == "master"
  and .auto_merge == true
' <<<"${screenshot_result}" >/dev/null; then
  echo "expected screenshot-style host + project ID prompt to resolve and execute" >&2
  printf '%s\n' "${screenshot_result}" >&2
  exit 1
fi
if ! grep -qx 'api projects/55' "${CALL_LOG}"; then
  echo "expected exactly one numeric project identity lookup" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

matching_path_result="$(
  run_with_wiki_tuple \
    '请处理 ai-infra/one_stop_ui_testing（gitlab-b.pxsemic.tech:30000，GitLab project ID: 55）的 issue #4。'
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/one_stop_ui_testing"
  and .selector == {type:"single",iid:4}
' <<<"${matching_path_result}" >/dev/null; then
  echo "expected a matching path and project ID to succeed" >&2
  printf '%s\n' "${matching_path_result}" >&2
  exit 1
fi

mismatching_path_result="$(
  run_with_wiki_tuple \
    '请处理 other/team_project（gitlab-b.pxsemic.tech:30000，project_id=55）的 issue #5。'
)"
if ! jq -e '
  .status == "failed"
  and .project == null
  and (.reason | contains("与 project ID 解析结果不一致"))
' <<<"${mismatching_path_result}" >/dev/null; then
  echo "expected a path that conflicts with project ID to fail closed" >&2
  printf '%s\n' "${mismatching_path_result}" >&2
  exit 1
fi

same_host_result="$(
  MESSAGE='请处理 gitlab-b.pxsemic.tech:30000 上 project ID 55 的 issue #12。' \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
  EXPECTED_PROJECT_ID=55 \
  EXPECTED_GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
  EXPECTED_GITLAB_PROTOCOL=http \
  EXPECTED_GITLAB_TOKEN='wiki-read-only-token' \
  GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
  GITLAB_API_PROTOCOL=http \
  GITLAB_TOKEN='generic-token-must-not-be-used' \
  WIKI_GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
  WIKI_GITLAB_API_PROTOCOL=http \
  WIKI_GITLAB_TOKEN='wiki-read-only-token' \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/one_stop_ui_testing"
  and .selector == {type:"single",iid:12}
' <<<"${same_host_result}" >/dev/null; then
  echo "expected the dedicated read-only tuple to win when both tuples use the same host" >&2
  printf '%s\n' "${same_host_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
conflicting_ids_result="$(
  run_with_wiki_tuple \
    '请处理 gitlab-b.pxsemic.tech:30000 上项目ID 55、project id 56 的 issue #6。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("多个不同 GitLab project ID"))
' <<<"${conflicting_ids_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected conflicting project IDs to fail before any API request" >&2
  printf '%s\n' "${conflicting_ids_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
untrusted_host_result="$(
  run_with_wiki_tuple \
    '请处理 gitlab-evil.example:30000 上项目 ID 55 的 issue #7。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("host 与已配置实例不一致"))
' <<<"${untrusted_host_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected an unconfigured prompt host to fail before any API request" >&2
  printf '%s\n' "${untrusted_host_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
generic_untrusted_host_result="$(
  run_with_wiki_tuple \
    '请处理仓库（code-evil.internal:30000，项目 ID 55）中的 issue #13。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("host 与已配置实例不一致"))
' <<<"${generic_untrusted_host_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected any host explicitly paired with project ID to be checked before the API request" >&2
  printf '%s\n' "${generic_untrusted_host_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
host_after_id_result="$(
  run_with_wiki_tuple \
    '请处理项目 ID 55，code-evil.internal:30000 上的 issue #18。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("host 与已配置实例不一致"))
' <<<"${host_after_id_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected a host written after project ID to be checked before the API request" >&2
  printf '%s\n' "${host_after_id_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
labeled_host_after_id_result="$(
  run_with_wiki_tuple \
    '请处理 project ID 55，GitLab host: code-evil.internal:30000 上的 issue #19。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("host 与已配置实例不一致"))
' <<<"${labeled_host_after_id_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected an explicitly labeled GitLab host to be checked before the API request" >&2
  printf '%s\n' "${labeled_host_after_id_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
wrong_response_result="$(
  FAKE_RESPONSE_ID=56 \
    run_with_wiki_tuple \
      '请处理 gitlab-b.pxsemic.tech:30000 上项目 ID 55 的 issue #8。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("不匹配或不完整"))
' <<<"${wrong_response_result}" >/dev/null \
    || [ "${calls_after}" -ne "$((calls_before + 1))" ]; then
  echo "expected a response with the wrong project ID to fail closed" >&2
  printf '%s\n' "${wrong_response_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
unsafe_path_result="$(
  FAKE_PROJECT_PATH='../unsafe' \
    run_with_wiki_tuple \
      '请处理 gitlab-b.pxsemic.tech:30000 上项目 ID 55 的 issue #15。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("不安全的 path_with_namespace"))
' <<<"${unsafe_path_result}" >/dev/null \
    || [ "${calls_after}" -ne "$((calls_before + 1))" ]; then
  echo "expected an unsafe API path_with_namespace to fail closed" >&2
  printf '%s\n' "${unsafe_path_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
api_failure_result="$(
  FAKE_GLAB_FAIL=true \
    run_with_wiki_tuple \
      '请处理 gitlab-b.pxsemic.tech:30000 上项目 ID 55 的 issue #16。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("查询失败或当前只读凭据无权访问"))
' <<<"${api_failure_result}" >/dev/null \
    || [ "${calls_after}" -ne "$((calls_before + 1))" ]; then
  echo "expected a failed read-only project lookup to stop before executor routing" >&2
  printf '%s\n' "${api_failure_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
zero_id_result="$(
  run_with_wiki_tuple \
    '请处理 gitlab-b.pxsemic.tech:30000 上项目 ID 0 的 issue #17。'
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("project ID 必须是正整数"))
' <<<"${zero_id_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected a zero project ID to fail before any API request" >&2
  printf '%s\n' "${zero_id_result}" >&2
  exit 1
fi

id_only_result="$(
  run_with_wiki_tuple '请处理项目编号 55 的 issue #9。'
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/one_stop_ui_testing"
  and .selector == {type:"single",iid:9}
' <<<"${id_only_result}" >/dev/null; then
  echo "expected project ID alone to use the only configured GitLab instance" >&2
  printf '%s\n' "${id_only_result}" >&2
  exit 1
fi

english_id_only_result="$(
  run_with_wiki_tuple '请处理 GitLab project ID 55 的 issue #14。'
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/one_stop_ui_testing"
  and .selector == {type:"single",iid:14}
' <<<"${english_id_only_result}" >/dev/null; then
  echo "expected the words GitLab project ID not to be mistaken for a bare host" >&2
  printf '%s\n' "${english_id_only_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
multiple_instances_result="$(
  MESSAGE='请处理 project ID 55 的 issue #10。' \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
  GITLAB_HOST='gitlab-a.example' \
  GITLAB_API_PROTOCOL='https' \
  GITLAB_TOKEN='generic-read-only-token' \
  WIKI_GITLAB_HOST='gitlab-b.example' \
  WIKI_GITLAB_API_PROTOCOL='https' \
  WIKI_GITLAB_TOKEN='wiki-read-only-token' \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("配置了多个 GitLab 实例"))
' <<<"${multiple_instances_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected project ID without a host to fail when multiple instances are configured" >&2
  printf '%s\n' "${multiple_instances_result}" >&2
  exit 1
fi

calls_before="$(call_count)"
missing_credentials_result="$(
  MESSAGE='请处理 project ID 55 的 issue #11。' \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
calls_after="$(call_count)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("未配置可用于解析"))
' <<<"${missing_credentials_result}" >/dev/null \
    || [ "${calls_before}" != "${calls_after}" ]; then
  echo "expected missing read-only credentials to fail before any API request" >&2
  printf '%s\n' "${missing_credentials_result}" >&2
  exit 1
fi

echo "ok executor project locators resolve GitLab host + project ID deterministically"
