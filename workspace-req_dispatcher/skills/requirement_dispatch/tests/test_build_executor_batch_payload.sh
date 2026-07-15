#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILDER="${SKILL_DIR}/scripts/build_executor_batch_payload.sh"
CALLBACK_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

build_payload() {
  BATCH_ID="reqd-batch-20260710-0001" \
  CORRELATION_ID="reqd-7" \
  PROJECT="ai-infra/veqp_server_v3" \
  SELECTOR_JSON="$1" \
  FORCE_RERUN_PR="${2:-false}" \
  EXECUTOR_AGENT="req_executor" \
  CALLBACK_NONCE="${CALLBACK_NONCE}" \
  DISPATCHER_CALLBACK_TARGET="${4:-agent:req_dispatcher:main}" \
  TARGET_BRANCH="${3:-}" \
  AUTO_MERGE="${5:-false}" \
  MERGE_TARGET_BRANCH="${6:-}" \
  bash "${BUILDER}"
}

range_payload="$(build_payload '{"type":"range","iid_min":100,"iid_max":250}' false 'release/2026.07')"
expected_range='RUN_DRIVEN_ISSUE_BATCH
batch_id=reqd-batch-20260710-0001
correlation_id=reqd-7
project=ai-infra/veqp_server_v3
executor_agent=req_executor
selector_type=range
iid_min=100
iid_max=250
force_rerun_pr=false
auto_merge=false
dispatcher_callback_target=agent:req_dispatcher:main
callback_nonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
branch=release/2026.07'

if [ "${range_payload}" != "${expected_range}" ]; then
  echo "unexpected range batch payload" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "${expected_range}" "${range_payload}" >&2
  exit 1
fi

auto_merge_payload="$(build_payload '{"type":"single","iid":312}' false develop '' true release/2026.07)"
if ! grep -qx 'branch=develop' <<<"${auto_merge_payload}" || \
   ! grep -qx 'auto_merge=true' <<<"${auto_merge_payload}" || \
   ! grep -qx 'merge_target_branch=release/2026.07' <<<"${auto_merge_payload}"; then
  echo "expected automatic merge fields in batch payload" >&2
  printf '%s\n' "${auto_merge_payload}" >&2
  exit 1
fi

common_branch_payload="$(build_payload '{"type":"single","iid":312}' false feature/foo-1.2 '' true feature/foo-1.2)"
if ! grep -qx 'branch=feature/foo-1.2' <<<"${common_branch_payload}" || \
   ! grep -qx 'merge_target_branch=feature/foo-1.2' <<<"${common_branch_payload}"; then
  echo "expected common slash, dash, and dot branch characters to remain valid" >&2
  printf '%s\n' "${common_branch_payload}" >&2
  exit 1
fi

for unsafe_branch in \
  'feature/`id`' \
  "feature/'quote" \
  'feature/"quote' \
  'feature/<redirect' \
  'feature/>redirect' \
  'feature/!history'
do
  if build_payload '{"type":"single","iid":312}' false "${unsafe_branch}" \
      >/dev/null 2>&1; then
    echo "expected unsafe base branch to fail: ${unsafe_branch}" >&2
    exit 1
  fi
  if build_payload '{"type":"single","iid":312}' false develop '' true \
      "${unsafe_branch}" >/dev/null 2>&1; then
    echo "expected unsafe merge target branch to fail: ${unsafe_branch}" >&2
    exit 1
  fi
done

if build_payload '{"type":"single","iid":312}' false develop '' true '' >/dev/null 2>&1; then
  echo "expected automatic merge without a merge target to fail" >&2
  exit 1
fi

single_payload="$(build_payload '{"type":"single","iid":312}')"
if ! grep -qx 'selector_type=single' <<<"${single_payload}" || \
   ! grep -qx 'iid=312' <<<"${single_payload}" || \
   grep -Eq '^(iid_min|iid_max|label|branch)=' <<<"${single_payload}"; then
  echo "expected single selector to emit only its defined selector field" >&2
  printf '%s\n' "${single_payload}" >&2
  exit 1
fi

iid_list_payload="$(build_payload '{"type":"iid_list","iids":[1,4,5]}')"
if ! grep -qx 'selector_type=iid_list' <<<"${iid_list_payload}" || \
   ! grep -qx 'iids=1,4,5' <<<"${iid_list_payload}" || \
   grep -Eq '^(iid|iid_min|iid_max|label|branch)=' <<<"${iid_list_payload}"; then
  echo "expected iid_list selector to emit one canonical comma-separated field" >&2
  printf '%s\n' "${iid_list_payload}" >&2
  exit 1
fi

unfinished_payload="$(build_payload '{"type":"open_unfinished"}')"
if ! grep -qx 'selector_type=open_unfinished' <<<"${unfinished_payload}" || \
   grep -Eq '^(iid|iid_min|iid_max|label|branch)=' <<<"${unfinished_payload}"; then
  echo "expected open_unfinished selector to emit no unrelated selector fields" >&2
  printf '%s\n' "${unfinished_payload}" >&2
  exit 1
fi

label_payload="$(build_payload '{"type":"open_label","label":"pr"}' true)"
if ! grep -qx 'selector_type=open_label' <<<"${label_payload}" || \
   ! grep -qx 'label=pr' <<<"${label_payload}" || \
   ! grep -qx 'force_rerun_pr=true' <<<"${label_payload}"; then
  echo "expected open_label selector and rerun flag in batch payload" >&2
  printf '%s\n' "${label_payload}" >&2
  exit 1
fi

if build_payload '{"type":"range","iid_min":250,"iid_max":100}' >/dev/null 2>&1; then
  echo "expected a descending range selector to fail" >&2
  exit 1
fi

if build_payload '{"type":"open_label","label":""}' >/dev/null 2>&1; then
  echo "expected an empty open_label selector to fail" >&2
  exit 1
fi

if build_payload '{"type":"open_unfinished","iid":1}' >/dev/null 2>&1; then
  echo "expected selector fields not defined for its type to fail" >&2
  exit 1
fi

for invalid_iid_list in \
  '{"type":"iid_list","iids":[1]}' \
  '{"type":"iid_list","iids":[4,1,5]}' \
  '{"type":"iid_list","iids":[1,4,4]}' \
  '{"type":"iid_list","iids":[1,0,5]}'
do
  if build_payload "${invalid_iid_list}" >/dev/null 2>&1; then
    echo "expected a non-canonical iid_list selector to fail: ${invalid_iid_list}" >&2
    exit 1
  fi
done

if build_payload '{"type":"unknown"}' >/dev/null 2>&1; then
  echo "expected an unknown selector type to fail" >&2
  exit 1
fi

if BATCH_ID=$'reqd-batch\ninjected=true' \
   CORRELATION_ID="reqd-7" \
   PROJECT="ai-infra/veqp_server_v3" \
   SELECTOR_JSON='{"type":"single","iid":312}' \
   FORCE_RERUN_PR=false \
   EXECUTOR_AGENT=req_executor \
   CALLBACK_NONCE="${CALLBACK_NONCE}" \
   DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
   bash "${BUILDER}" >/dev/null 2>&1; then
  echo "expected newline-containing scalar values to fail" >&2
  exit 1
fi

for unsafe_executor_agent in \
  'req_executor:child' \
  "$(printf 'a%.0s' {1..65})"
do
  if BATCH_ID="reqd-batch-20260710-0001" \
     CORRELATION_ID="reqd-7" \
     PROJECT="ai-infra/veqp_server_v3" \
     SELECTOR_JSON='{"type":"single","iid":312}' \
     FORCE_RERUN_PR=false \
     EXECUTOR_AGENT="${unsafe_executor_agent}" \
     CALLBACK_NONCE="${CALLBACK_NONCE}" \
     DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
     bash "${BUILDER}" >/dev/null 2>&1; then
    echo "expected executor identity outside the executor pin grammar to fail" >&2
    exit 1
  fi
done

executor_agent_64="$(printf 'a%.0s' {1..64})"
executor_agent_64_payload="$(
  BATCH_ID="reqd-batch-20260710-0001" \
  CORRELATION_ID="reqd-7" \
  PROJECT="ai-infra/veqp_server_v3" \
  SELECTOR_JSON='{"type":"single","iid":312}' \
  FORCE_RERUN_PR=false \
  EXECUTOR_AGENT="${executor_agent_64}" \
  CALLBACK_NONCE="${CALLBACK_NONCE}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
  bash "${BUILDER}"
)"
grep -qx "executor_agent=${executor_agent_64}" <<<"${executor_agent_64_payload}" || {
  echo "expected a 64-character executor identity to remain valid" >&2
  exit 1
}

for unsafe_project in 'group/../secret' 'group/./secret'; do
  if BATCH_ID="reqd-batch-20260710-0001" \
     CORRELATION_ID="reqd-7" \
     PROJECT="${unsafe_project}" \
     SELECTOR_JSON='{"type":"single","iid":312}' \
     FORCE_RERUN_PR=false \
     EXECUTOR_AGENT=req_executor \
     CALLBACK_NONCE="${CALLBACK_NONCE}" \
     DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
     bash "${BUILDER}" >/dev/null 2>&1; then
    echo "expected a project dot segment to fail: ${unsafe_project}" >&2
    exit 1
  fi
done

if build_payload $'{"type":"open_label","label":"pr\\tunsafe"}' >/dev/null 2>&1; then
  echo "expected control characters in selector values to fail" >&2
  exit 1
fi

if BATCH_ID="reqd-batch-20260710-0001" \
   CORRELATION_ID="reqd-7" \
   PROJECT="ai-infra/veqp_server_v3" \
   SELECTOR_JSON='{"type":"single","iid":312}' \
   FORCE_RERUN_PR=false \
   EXECUTOR_AGENT='req_executor extra' \
   CALLBACK_NONCE="${CALLBACK_NONCE}" \
   DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
   bash "${BUILDER}" >/dev/null 2>&1; then
  echo "expected an unsafe executor agent identity to fail" >&2
  exit 1
fi

valid_callback_payload="$(build_payload '{"type":"single","iid":312}' false '' 'agent:req_dispatcher:9main._:-')"
if ! grep -qx 'dispatcher_callback_target=agent:req_dispatcher:9main._:-' <<<"${valid_callback_payload}"; then
  echo "expected a valid req_dispatcher callback target to pass" >&2
  printf '%s\n' "${valid_callback_payload}" >&2
  exit 1
fi

for invalid_callback_target in \
  'agent:req_executor:main' \
  'req_dispatcher:main' \
  'agent:req_dispatcher:main/child' \
  'agent:req_dispatcher:_main' \
  'agent:req_dispatcher:'
do
  if build_payload '{"type":"single","iid":312}' false '' "${invalid_callback_target}" >/dev/null 2>&1; then
    echo "expected invalid dispatcher callback target to fail: ${invalid_callback_target}" >&2
    exit 1
  fi
done

callback_suffix_129="$(printf 'a%.0s' {1..129})"
if build_payload '{"type":"single","iid":312}' false '' "agent:req_dispatcher:${callback_suffix_129}" >/dev/null 2>&1; then
  echo "expected an overlong dispatcher callback target to fail" >&2
  exit 1
fi

echo "ok build_executor_batch_payload emits validated RUN_DRIVEN_ISSUE_BATCH"
