#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WIKI_URL="http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements"
WIKI_CONTENT="$(cat <<'EOF'
# Product Requirements

Intro text that should not become its own issue.

## Background

Context that should not become its own issue.

## Login flow

Implement password reset from the login screen.

## Export flow

Add CSV export for filtered records.
EOF
)"

prepared="$(
  MESSAGE="请处理 ${WIKI_URL}" \
  WIKI_CONTENT="${WIKI_CONTENT}" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${prepared}")" != "success" ]; then
  echo "expected wiki payload preparation to succeed" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${prepared}")" != "claw_gitlab/px_ifp_hulat_test" ]; then
  echo "expected project parsed from wiki URL" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

if [ "$(jq -r '.wiki_slug' <<<"${prepared}")" != "product/requirements" ]; then
  echo "expected wiki slug parsed from wiki URL" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

branch_prepared="$(
  MESSAGE="目标分支：release/2026.07，请处理 ${WIKI_URL}" \
  WIKI_CONTENT="${WIKI_CONTENT}" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${branch_prepared}")" != "success" ]; then
  echo "expected branch-qualified wiki payload preparation to succeed" >&2
  printf '%s\n' "${branch_prepared}" >&2
  exit 1
fi

if [ "$(jq -r '.target_branch' <<<"${branch_prepared}")" != "release/2026.07" ]; then
  echo "expected wiki target_branch release/2026.07" >&2
  printf '%s\n' "${branch_prepared}" >&2
  exit 1
fi

if jq -r '.git_issuer_payloads[0]' <<<"${branch_prepared}" | grep -q '目标分支'; then
  echo "expected wiki git_issuer payload to omit dispatcher-only branch directive" >&2
  printf '%s\n' "${branch_prepared}" >&2
  exit 1
fi

dotted="$(
  MESSAGE="请处理 http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/wikis/product/spec.v1" \
  WIKI_CONTENT='只有一段需求正文。' \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.wiki_slug' <<<"${dotted}")" != "product/spec.v1" ]; then
  echo "expected wiki slug to keep dots inside the page path" >&2
  printf '%s\n' "${dotted}" >&2
  exit 1
fi

if [ "$(jq '.requirements | length' <<<"${prepared}")" -ne 2 ]; then
  echo "expected two requirement items from two level-2 headings" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

first_payload="$(jq -r '.git_issuer_payloads[0]' <<<"${prepared}")"
second_payload="$(jq -r '.git_issuer_payloads[1]' <<<"${prepared}")"

if ! grep -q '^repo=claw_gitlab/px_ifp_hulat_test$' <<<"${first_payload}"; then
  echo "expected payload to include repo from wiki URL" >&2
  printf '%s\n' "${first_payload}" >&2
  exit 1
fi

if ! grep -q '^source=req_dispatcher_wiki$' <<<"${first_payload}"; then
  echo "expected payload to mark wiki source" >&2
  printf '%s\n' "${first_payload}" >&2
  exit 1
fi

if ! grep -q "^wiki_url=${WIKI_URL}$" <<<"${first_payload}"; then
  echo "expected payload to include original wiki URL" >&2
  printf '%s\n' "${first_payload}" >&2
  exit 1
fi

if ! grep -q '^wiki_section=Login flow$' <<<"${first_payload}"; then
  echo "expected first payload section title" >&2
  printf '%s\n' "${first_payload}" >&2
  exit 1
fi

if ! grep -q 'Implement password reset' <<<"${first_payload}"; then
  echo "expected first payload body" >&2
  printf '%s\n' "${first_payload}" >&2
  exit 1
fi

if ! grep -q '不要添加执行器入口标签' <<<"${first_payload}"; then
  echo "expected wiki git_issuer payload to forbid executor entry labels by default" >&2
  printf '%s\n' "${first_payload}" >&2
  exit 1
fi

if ! grep -q '^wiki_item_ordinal=2$' <<<"${second_payload}"; then
  echo "expected second payload ordinal" >&2
  printf '%s\n' "${second_payload}" >&2
  exit 1
fi

numbered_content="$(cat <<'EOF'
需求列表

1. 支持批量导入用户。

2. 支持导入失败报告下载。
EOF
)"

numbered="$(
  MESSAGE="wiki: ${WIKI_URL}" \
  WIKI_CONTENT="${numbered_content}" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq '.requirements | length' <<<"${numbered}")" -ne 2 ]; then
  echo "expected numbered blocks to split into two requirements" >&2
  printf '%s\n' "${numbered}" >&2
  exit 1
fi

single="$(
  MESSAGE="wiki: ${WIKI_URL}" \
  WIKI_CONTENT='只有一段需求正文，没有标题。' \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq '.requirements | length' <<<"${single}")" -ne 1 ]; then
  echo "expected single-body wiki to fallback to one requirement" >&2
  printf '%s\n' "${single}" >&2
  exit 1
fi

missing_content="$(
  MESSAGE="wiki: ${WIKI_URL}" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${missing_content}")" != "failed" ]; then
  echo "expected missing wiki content to fail before fetch mode is enabled" >&2
  printf '%s\n' "${missing_content}" >&2
  exit 1
fi

if ! grep -q 'wiki content is required' <<<"$(jq -r '.reason' <<<"${missing_content}")"; then
  echo "expected clear missing content reason" >&2
  printf '%s\n' "${missing_content}" >&2
  exit 1
fi

unsupported="$(
  MESSAGE='请处理 http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/issues/1' \
  WIKI_CONTENT="${WIKI_CONTENT}" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${unsupported}")" != "failed" ]; then
  echo "expected non-wiki URL to fail" >&2
  printf '%s\n' "${unsupported}" >&2
  exit 1
fi

echo "ok prepare_wiki_downstream_payloads builds wiki item payloads"
