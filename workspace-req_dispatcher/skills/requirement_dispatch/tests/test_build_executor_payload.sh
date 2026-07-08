#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-build-executor.XXXXXX")"

payload="$(
  PROJECT="ai-infra/veqp_server_v3" \
  IID="312" \
  CORRELATION_ID="reqd-7" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/build_executor_payload.sh"
)"

expected='RUN_SINGLE_ISSUE
project=ai-infra/veqp_server_v3
iid=312
correlation_id=reqd-7
dispatcher_callback_target=agent:req_dispatcher:main'

if [ "${payload}" != "${expected}" ]; then
  echo "unexpected executor payload" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "${expected}" "${payload}" >&2
  exit 1
fi

payload_with_branch="$(
  PROJECT="ai-infra/veqp_server_v3" \
  IID="312" \
  CORRELATION_ID="reqd-7" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  TARGET_BRANCH="release/2026.07" \
  bash "${SKILL_DIR}/scripts/build_executor_payload.sh"
)"

expected_with_branch='RUN_SINGLE_ISSUE
project=ai-infra/veqp_server_v3
iid=312
correlation_id=reqd-7
dispatcher_callback_target=agent:req_dispatcher:main
branch=release/2026.07'

if [ "${payload_with_branch}" != "${expected_with_branch}" ]; then
  echo "unexpected executor payload with target branch" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "${expected_with_branch}" "${payload_with_branch}" >&2
  exit 1
fi

if PROJECT="veqp_server_v3" \
   IID="312" \
   CORRELATION_ID="reqd-7" \
   DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
   bash "${SKILL_DIR}/scripts/build_executor_payload.sh" >/dev/null 2>"${TEST_ROOT}/build-executor-invalid.err"; then
  echo "expected malformed project to fail" >&2
  exit 1
fi

if ! grep -q "PROJECT must be <group>/<project>" "${TEST_ROOT}/build-executor-invalid.err"; then
  echo "expected clear malformed project error" >&2
  cat "${TEST_ROOT}/build-executor-invalid.err" >&2
  exit 1
fi

if PROJECT="ai-infra/veqp_server_v3" \
   IID="abc" \
   CORRELATION_ID="reqd-7" \
   DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
   bash "${SKILL_DIR}/scripts/build_executor_payload.sh" >/dev/null 2>"${TEST_ROOT}/build-executor-iid.err"; then
  echo "expected non-integer iid to fail" >&2
  exit 1
fi

if ! grep -q "IID must be a positive integer" "${TEST_ROOT}/build-executor-iid.err"; then
  echo "expected clear iid error" >&2
  cat "${TEST_ROOT}/build-executor-iid.err" >&2
  exit 1
fi

if PROJECT="ai-infra/veqp_server_v3" \
   IID="312" \
   CORRELATION_ID="reqd-7" \
   TARGET_BRANCH="../bad" \
   bash "${SKILL_DIR}/scripts/build_executor_payload.sh" >/dev/null 2>"${TEST_ROOT}/build-executor-branch.err"; then
  echo "expected invalid target branch to fail" >&2
  exit 1
fi

if ! grep -q "branch must be a safe Git ref name" "${TEST_ROOT}/build-executor-branch.err"; then
  echo "expected clear branch error" >&2
  cat "${TEST_ROOT}/build-executor-branch.err" >&2
  exit 1
fi

echo "ok build_executor_payload emits RUN_SINGLE_ISSUE"
