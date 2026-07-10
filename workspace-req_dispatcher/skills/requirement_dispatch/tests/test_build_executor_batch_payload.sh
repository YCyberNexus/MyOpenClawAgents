#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILDER="${SKILL_DIR}/scripts/build_executor_batch_payload.sh"

build_payload() {
  BATCH_ID="reqd-batch-20260710-0001" \
  CORRELATION_ID="reqd-7" \
  PROJECT="ai-infra/veqp_server_v3" \
  SELECTOR_JSON="$1" \
  FORCE_RERUN_PR="${2:-false}" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  TARGET_BRANCH="${3:-}" \
  GITLAB_TOKEN="must-not-leak" \
  bash "${BUILDER}"
}

range_payload="$(build_payload '{"type":"range","iid_min":100,"iid_max":250}' false 'release/2026.07')"
expected_range='RUN_DRIVEN_ISSUE_BATCH
batch_id=reqd-batch-20260710-0001
correlation_id=reqd-7
project=ai-infra/veqp_server_v3
selector_type=range
iid_min=100
iid_max=250
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
branch=release/2026.07'

if [ "${range_payload}" != "${expected_range}" ]; then
  echo "unexpected range batch payload" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "${expected_range}" "${range_payload}" >&2
  exit 1
fi

if grep -Eqi 'token|must-not-leak' <<<"${range_payload}"; then
  echo "expected dispatcher batch payload to contain no token material" >&2
  printf '%s\n' "${range_payload}" >&2
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

if build_payload '{"type":"unknown"}' >/dev/null 2>&1; then
  echo "expected an unknown selector type to fail" >&2
  exit 1
fi

if BATCH_ID=$'reqd-batch\ninjected=true' \
   CORRELATION_ID="reqd-7" \
   PROJECT="ai-infra/veqp_server_v3" \
   SELECTOR_JSON='{"type":"single","iid":312}' \
   FORCE_RERUN_PR=false \
   bash "${BUILDER}" >/dev/null 2>&1; then
  echo "expected newline-containing scalar values to fail" >&2
  exit 1
fi

if build_payload $'{"type":"open_label","label":"pr\\tunsafe"}' >/dev/null 2>&1; then
  echo "expected control characters in selector values to fail" >&2
  exit 1
fi

echo "ok build_executor_batch_payload emits validated token-free RUN_DRIVEN_ISSUE_BATCH"
