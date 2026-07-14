#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-timeout-migration.XXXXXX")"

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export DISPATCHER_LOG_DIR="${TEST_ROOT}/logs"
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT_URI="group%2Fproject"
export PROJECT="project"
export REPO_PARENT_PATH="${TEST_ROOT}/repos"

source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

fail() {
  echo "$1" >&2
  exit 1
}

printf '%s\n' '{"project":"project","run_timeout_seconds":18120}' >"${CAMPAIGN_STATE_FILE}"
load_state | jq -e 'has("run_timeout_seconds") | not' >/dev/null \
  || fail "load_state must delete legacy run_timeout_seconds"
fresh_init_state | jq -e 'has("run_timeout_seconds") | not' >/dev/null \
  || fail "fresh_init_state must not expose run_timeout_seconds"

[ "$(derive_stuck_after_minutes 3600)" = "130" ] \
  || fail "default acpx timeout must derive stuck_after_minutes=130"
[ "$(derive_stuck_after_minutes 21600)" = "430" ] \
  || fail "six-hour acpx timeout must derive stuck_after_minutes=430"

grep -Fq 'unsupported trigger field: run_timeout_seconds' \
  "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
if rg -n 'run_timeout_seconds:[[:space:]]*\$|--argjson run_timeout|RUN_TIMEOUT' \
  "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh" \
  "${SKILL_DIR}/scripts/_dispatch_lib.sh"; then
  echo "removed run timeout is still persisted or emitted" >&2
  exit 1
fi
if rg -n 'RUN_TIMEOUT|run_timeout_seconds=' \
  "${SKILL_DIR}/scripts/dispatch_single_issue.sh"; then
  echo "RUN_SINGLE_ISSUE still synthesizes removed run timeout" >&2
  exit 1
fi

echo "ok req_executor removes legacy run timeout state"
