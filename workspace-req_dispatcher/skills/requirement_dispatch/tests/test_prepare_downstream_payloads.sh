#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

prepared="$(
  MESSAGE='[来自114] 用户wuyun请求： 在GitLab ai-infra/veqp_server_v3开发虚拟机台状态机（IDLE/SCANNING/DOOR_CLOSED/RUNNING/DOOR_OPENED），与实体机台一致。请完成后回复。
[origin] channel=wecom user=wuyun conversation=conv-114 reply_agent=zhiban' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${prepared}")" != "success" ]; then
  echo "expected prepare_downstream_payloads.sh to succeed for explicit GitLab project" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${prepared}")" != "ai-infra/veqp_server_v3" ]; then
  echo "expected project ai-infra/veqp_server_v3" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

git_payload="$(jq -r '.git_issuer_payload' <<<"${prepared}")"
requirement_text="$(jq -r '.requirement_text' <<<"${prepared}")"

if ! grep -q '^repo=ai-infra/veqp_server_v3$' <<<"${git_payload}"; then
  echo "expected git_issuer payload to include an explicit repo line" >&2
  printf '%s\n' "${git_payload}" >&2
  exit 1
fi

if grep -q '\[来自114\]' <<<"${git_payload}"; then
  echo "expected git_issuer payload to omit 114 wrapper text" >&2
  printf '%s\n' "${git_payload}" >&2
  exit 1
fi

if grep -q '^\[origin\]' <<<"${git_payload}"; then
  echo "expected git_issuer payload to omit origin metadata lines" >&2
  printf '%s\n' "${git_payload}" >&2
  exit 1
fi

if ! grep -q '开发虚拟机台状态机' <<<"${requirement_text}"; then
  echo "expected normalized requirement to preserve the user requirement" >&2
  printf '%s\n' "${requirement_text}" >&2
  exit 1
fi

if grep -q '请完成后回复' <<<"${requirement_text}"; then
  echo "expected normalized requirement to strip reply instruction" >&2
  printf '%s\n' "${requirement_text}" >&2
  exit 1
fi

if grep -q '在GitLab ai-infra/veqp_server_v3' <<<"${requirement_text}"; then
  echo "expected normalized requirement to strip leading project locator" >&2
  printf '%s\n' "${requirement_text}" >&2
  exit 1
fi

if ! grep -q '最后一行输出 req_dispatcher 契约 JSON' <<<"${git_payload}"; then
  echo "expected git_issuer payload to request the compact JSON contract" >&2
  printf '%s\n' "${git_payload}" >&2
  exit 1
fi

branch_input="$(
  MESSAGE='请在 GitLab ai-infra/veqp_server_v3 中处理，目标分支：release/2026.07，修复导出流程。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${branch_input}")" != "success" ]; then
  echo "expected branch-qualified input to succeed" >&2
  printf '%s\n' "${branch_input}" >&2
  exit 1
fi

if [ "$(jq -r '.target_branch' <<<"${branch_input}")" != "release/2026.07" ]; then
  echo "expected target_branch release/2026.07" >&2
  printf '%s\n' "${branch_input}" >&2
  exit 1
fi

branch_requirement="$(jq -r '.requirement_text' <<<"${branch_input}")"
if [ "${branch_requirement}" != "修复导出流程。" ]; then
  echo "expected branch directive to be stripped from requirement_text" >&2
  printf '%s\n' "${branch_input}" >&2
  exit 1
fi

if jq -r '.git_issuer_payload' <<<"${branch_input}" | grep -q '目标分支'; then
  echo "expected git_issuer payload to omit dispatcher-only branch directive" >&2
  printf '%s\n' "${branch_input}" >&2
  exit 1
fi

branch_before_project="$(
  MESSAGE='目标分支：release/2026.07，请在 GitLab ai-infra/veqp_server_v3 中修复导出流程。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${branch_before_project}")" != "success" ]; then
  echo "expected branch-before-project input to succeed" >&2
  printf '%s\n' "${branch_before_project}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${branch_before_project}")" != "ai-infra/veqp_server_v3" ]; then
  echo "expected branch-before-project input to preserve the real project" >&2
  printf '%s\n' "${branch_before_project}" >&2
  exit 1
fi

if [ "$(jq -r '.target_branch' <<<"${branch_before_project}")" != "release/2026.07" ]; then
  echo "expected branch-before-project target_branch release/2026.07" >&2
  printf '%s\n' "${branch_before_project}" >&2
  exit 1
fi

missing_project="$(
  MESSAGE='[来自114] 用户wuyun请求： 开发虚拟机台状态机。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${missing_project}")" != "failed" ]; then
  echo "expected missing project text to fail before calling git_issuer" >&2
  printf '%s\n' "${missing_project}" >&2
  exit 1
fi

if [ "$(jq -r '.git_issuer_payload' <<<"${missing_project}")" != "null" ]; then
  echo "expected no git_issuer payload when project is missing" >&2
  printf '%s\n' "${missing_project}" >&2
  exit 1
fi

locator_with_polite_prefix="$(
  MESSAGE='请在 GitLab claw_gitlab/px_ifp_hulat_test 中处理：修复导出流程。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

locator_requirement="$(jq -r '.requirement_text' <<<"${locator_with_polite_prefix}")"
if [ "${locator_requirement}" != "修复导出流程。" ]; then
  echo "expected leading polite project locator to be stripped" >&2
  printf '%s\n' "${locator_with_polite_prefix}" >&2
  exit 1
fi

empty_after_locator="$(
  MESSAGE='在 GitLab ai-infra/veqp_server_v3 中' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${empty_after_locator}")" != "failed" ]; then
  echo "expected text with only project locator to fail after normalization" >&2
  printf '%s\n' "${empty_after_locator}" >&2
  exit 1
fi

if [ "$(jq -r '.git_issuer_payload' <<<"${empty_after_locator}")" != "null" ]; then
  echo "expected no git_issuer payload when normalized requirement is empty" >&2
  printf '%s\n' "${empty_after_locator}" >&2
  exit 1
fi

repo_url_input="$(
  MESSAGE='请处理 http://gitlab-b.pxsemic.tech:30000/claw_gitlab/ifp_ui_testing_2/-/wikis/Home 里的测试点生成需求。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${repo_url_input}")" != "success" ]; then
  echo "expected repository/wiki URL input to succeed" >&2
  printf '%s\n' "${repo_url_input}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${repo_url_input}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected project extracted from repository/wiki URL" >&2
  printf '%s\n' "${repo_url_input}" >&2
  exit 1
fi

if ! jq -r '.git_issuer_payload' <<<"${repo_url_input}" | grep -q '^repo=claw_gitlab/ifp_ui_testing_2$'; then
  echo "expected URL-derived payload to include repo line" >&2
  printf '%s\n' "${repo_url_input}" >&2
  exit 1
fi

gitlab_url_after_reference_url="$(
  MESSAGE='参考 http://docs.example.com/foo/bar，再处理 http://gitlab-b.pxsemic.tech:30000/claw_gitlab/ifp_ui_testing_2/-/wikis/Home 的测试点。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${gitlab_url_after_reference_url}")" != "success" ]; then
  echo "expected GitLab URL after non-GitLab URL to succeed" >&2
  printf '%s\n' "${gitlab_url_after_reference_url}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${gitlab_url_after_reference_url}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected GitLab URL after non-GitLab URL to be used" >&2
  printf '%s\n' "${gitlab_url_after_reference_url}" >&2
  exit 1
fi

non_gitlab_url_input="$(
  MESSAGE='参考 http://docs.example.com/foo/bar 生成测试点。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${non_gitlab_url_input}")" != "failed" ]; then
  echo "expected non-GitLab URL without project to fail in dispatcher intake" >&2
  printf '%s\n' "${non_gitlab_url_input}" >&2
  exit 1
fi

if [ "$(jq -r '.git_issuer_payload' <<<"${non_gitlab_url_input}")" != "null" ]; then
  echo "expected no git_issuer payload for non-GitLab URL without project" >&2
  printf '%s\n' "${non_gitlab_url_input}" >&2
  exit 1
fi

non_gitlab_url_before_project="$(
  MESSAGE='参考 http://docs.example.com/foo/bar，在 GitLab claw_gitlab/ifp_ui_testing_2 中生成测试点。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${non_gitlab_url_before_project}")" != "success" ]; then
  echo "expected explicit project after non-GitLab URL to succeed" >&2
  printf '%s\n' "${non_gitlab_url_before_project}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${non_gitlab_url_before_project}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected explicit project after non-GitLab URL to be used" >&2
  printf '%s\n' "${non_gitlab_url_before_project}" >&2
  exit 1
fi

encoded_api_input="$(
  MESSAGE='用 glab api "projects/claw_gitlab%2Fifp_ui_testing_2/wikis" 列出所有 Wiki 页面并生成测试功能/需求点文档。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${encoded_api_input}")" != "success" ]; then
  echo "expected encoded glab api project input to succeed" >&2
  printf '%s\n' "${encoded_api_input}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${encoded_api_input}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected project decoded from glab api projects path" >&2
  printf '%s\n' "${encoded_api_input}" >&2
  exit 1
fi

unresolved_input="$(
  MESSAGE='请把这批 Wiki 需求整理成测试功能点。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${unresolved_input}")" != "failed" ]; then
  echo "expected no-project free text to fail in dispatcher intake" >&2
  printf '%s\n' "${unresolved_input}" >&2
  exit 1
fi

if [ "$(jq -r '.git_issuer_payload' <<<"${unresolved_input}")" != "null" ]; then
  echo "expected no git_issuer payload when project cannot be determined" >&2
  printf '%s\n' "${unresolved_input}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${unresolved_input}" | grep -q 'group/project'; then
  echo "expected no-project reason to ask for group/project or URL" >&2
  printf '%s\n' "${unresolved_input}" >&2
  exit 1
fi

echo "ok prepare_downstream_payloads builds tailored downstream messages"
