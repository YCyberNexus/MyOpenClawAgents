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

echo "ok prepare_downstream_payloads builds tailored downstream messages"
