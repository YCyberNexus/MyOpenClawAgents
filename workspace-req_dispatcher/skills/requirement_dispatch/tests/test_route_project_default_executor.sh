#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-route-default.XXXXXX")"
ROUTING_FILE="${TEST_ROOT}/routing.env"

cat >"${ROUTING_FILE}" <<'EOF'
# Specific overrides still win when a project needs a dedicated executor.
special/group = special_executor
EOF

default_route="$(
  PROJECT="ai-infra/veqp_server_v3" \
  ROUTING_FILE="${ROUTING_FILE}" \
  DEFAULT_EXECUTOR_AGENT="req_executor" \
  bash "${SKILL_DIR}/scripts/route_project.sh"
)"

if [ "${default_route}" != "req_executor" ]; then
  echo "expected unknown but valid project to route to DEFAULT_EXECUTOR_AGENT, got: ${default_route}" >&2
  exit 1
fi

override_route="$(
  PROJECT="special/group" \
  ROUTING_FILE="${ROUTING_FILE}" \
  DEFAULT_EXECUTOR_AGENT="req_executor" \
  bash "${SKILL_DIR}/scripts/route_project.sh"
)"

if [ "${override_route}" != "special_executor" ]; then
  echo "expected explicit routing override to win, got: ${override_route}" >&2
  exit 1
fi

if PROJECT="veqp_server_v3" \
   ROUTING_FILE="${ROUTING_FILE}" \
   DEFAULT_EXECUTOR_AGENT="req_executor" \
   bash "${SKILL_DIR}/scripts/route_project.sh" >/dev/null 2>"${TEST_ROOT}/invalid.err"; then
  echo "expected malformed project without group/project form to fail" >&2
  exit 1
fi

if ! grep -q "PROJECT must be <group>/<project>" "${TEST_ROOT}/invalid.err"; then
  echo "expected clear malformed project error" >&2
  cat "${TEST_ROOT}/invalid.err" >&2
  exit 1
fi

echo "ok route_project defaults valid projects to executor"
