#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/acpx-first-line.XXXXXX")"

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export DISPATCHER_LOG_DIR="${TEST_ROOT}/logs"
export PROJECT_URI="group%2Fproject"
export ISSUES_ROOT="${TEST_ROOT}/issues"

source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

fail() {
  echo "$1" >&2
  exit 1
}

long_prompt="# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1"
for _ in $(seq 1 4096); do
  long_prompt+=$'\nlong executor prompt line with enough content to exceed a pipe buffer'
done

actual="$(first_line "${long_prompt}")"
[ "${actual}" = "# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1" ] \
  || fail "first_line must return the sentinel without sending the producer SIGPIPE"

PREPARE_SCRIPT="${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
grep -Fq 'first_template_line="$(first_line "${template}")"' "${PREPARE_SCRIPT}" \
  || fail "template sentinel check must use first_line"
grep -Fq 'sentinel_first_line="$(first_line "${rendered}")"' "${PREPARE_SCRIPT}" \
  || fail "rendered sentinel check must use first_line"

if rg -n '\|[[:space:]]*head[[:space:]]+-n[[:space:]]+1' "${PREPARE_SCRIPT}"; then
  fail "dispatch_prepare_tick.sh must not inspect long prompt text through head"
fi

echo "ok long prompt sentinel checks avoid SIGPIPE"
