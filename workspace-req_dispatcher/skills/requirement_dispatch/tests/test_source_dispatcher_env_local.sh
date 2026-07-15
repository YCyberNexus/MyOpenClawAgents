#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-dispatcher-source-env.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/dispatcher.env" <<'EOF'
GIT_ISSUER_AGENT=git_issuer
STATE_ROOT=/data/req_dispatcher
STUCK_AFTER_MINUTES=30
EXECUTOR_ACPX_TIMEOUT_SECONDS=3600
OPENCLAW_SUBAGENT_TIMEOUT_SECONDS=20400
ROUTING_FILE=../../config/routing.env
REPLY_GATEWAY_URL=
REPLY_GATEWAY_TOKEN=
DEFAULT_REPLY_AGENT=
REPLY_NOTIFY_TIMEOUT_SECONDS=30
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
EOF

cat >"${CONFIG_DIR}/dispatcher.local.env" <<EOF
STATE_ROOT=${TEST_ROOT}/state
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:local-test
EXECUTOR_SCHEDULER_STATE_FILE=${TEST_ROOT}/scheduler_state.json
EOF

cat >"${TEST_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[],"acpx_timeout_seconds":5400}
EOF

out="$(
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" \
  /opt/homebrew/bin/bash -c '
    set -euo pipefail
    source "$1"
    printf "STATE_ROOT=%s\n" "${STATE_ROOT}"
    printf "DISPATCHER_CALLBACK_TARGET=%s\n" "${DISPATCHER_CALLBACK_TARGET}"
    bash "$2"
  ' _ "${SKILL_DIR}/scripts/source_dispatcher_env.sh" \
    "${SKILL_DIR}/scripts/get_executor_timeout_budget.sh"
)"

if ! grep -q "^STATE_ROOT=${TEST_ROOT}/state$" <<<"${out}"; then
  echo "expected dispatcher.local.env to override STATE_ROOT" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

if ! grep -q '^DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:local-test$' <<<"${out}"; then
  echo "expected dispatcher.local.env to override DISPATCHER_CALLBACK_TARGET" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

budget_json="$(tail -n 1 <<<"${out}")"
jq -e '
  .status == "success"
  and .acpx_timeout_seconds == 5400
  and .global_subagent_timeout_seconds == 20400
  and .executor_agent_timeout_seconds == 9000
  and .exec_tool_timeout_seconds == 9300
  and .queue_launch_reclaim_seconds == 9600
  and .stuck_after_minutes == 180
' <<<"${budget_json}" >/dev/null

cat >"${TEST_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[],"acpx_timeout_seconds":18000}
EOF
max_budget="$(
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" \
  /opt/homebrew/bin/bash -c '
    set -euo pipefail
    source "$1"
    bash "$2"
  ' _ "${SKILL_DIR}/scripts/source_dispatcher_env.sh" \
    "${SKILL_DIR}/scripts/get_executor_timeout_budget.sh"
)"
jq -e '
  .acpx_timeout_seconds == 18000
  and .global_subagent_timeout_seconds == 20400
  and .executor_agent_timeout_seconds == 21600
  and .exec_tool_timeout_seconds == 21900
  and .queue_launch_reclaim_seconds == 22200
  and .stuck_after_minutes == 390
' <<<"${max_budget}" >/dev/null

printf '%s\n' '{"version":1,"acpx_timeout_seconds":18001}' \
  >"${TEST_ROOT}/scheduler_state.json"
if ! DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" /opt/homebrew/bin/bash -c \
    'source "$1"' _ "${SKILL_DIR}/scripts/source_dispatcher_env.sh" \
    >/dev/null 2>&1; then
  echo "expected base config loading to remain independent of invalid executor state" >&2
  exit 1
fi
if DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" /opt/homebrew/bin/bash -c '
    set -euo pipefail
    source "$1"
    bash "$2"
  ' _ "${SKILL_DIR}/scripts/source_dispatcher_env.sh" \
    "${SKILL_DIR}/scripts/get_executor_timeout_budget.sh" \
    >/dev/null 2>&1; then
  echo "expected explicit timeout budget loading to reject invalid executor state" >&2
  exit 1
fi

mv "${TEST_ROOT}/scheduler_state.json" "${TEST_ROOT}/scheduler_state.invalid.json"
if DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" /opt/homebrew/bin/bash -c '
    set -euo pipefail
    source "$1"
    bash "$2"
  ' _ "${SKILL_DIR}/scripts/source_dispatcher_env.sh" \
    "${SKILL_DIR}/scripts/get_executor_timeout_budget.sh" \
    >/dev/null 2>&1; then
  echo "expected explicit timeout budget loading to reject missing executor state" >&2
  exit 1
fi

echo "ok source_dispatcher_env loads local env override"
