#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
EXECUTOR_SKILL_DIR="$(cd "${SKILL_DIR}/../../../workspace-req_executor/skills/gitlab_issue_campaign_dispatcher" && pwd)"

cmp -s \
  "${SKILL_DIR}/scripts/openclaw_strict_json_receipt.mjs" \
  "${EXECUTOR_SKILL_DIR}/scripts/openclaw_strict_json_receipt.mjs" || {
  echo "strict JSON receipt helpers diverged between dispatcher and executor" >&2
  exit 1
}

node "${TEST_DIR}/test_openclaw_strict_json_receipt.mjs"
