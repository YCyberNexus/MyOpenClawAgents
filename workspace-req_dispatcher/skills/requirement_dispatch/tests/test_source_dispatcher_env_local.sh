#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-source-env.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/dispatcher.env" <<'EOF'
GIT_ISSUER_AGENT=git_issuer
STATE_ROOT=/data/req_dispatcher
STUCK_AFTER_MINUTES=30
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
EOF

out="$(
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" \
  /opt/homebrew/bin/bash -c '
    set -euo pipefail
    source "$1"
    printf "STATE_ROOT=%s\n" "${STATE_ROOT}"
    printf "DISPATCHER_CALLBACK_TARGET=%s\n" "${DISPATCHER_CALLBACK_TARGET}"
  ' _ "${SKILL_DIR}/scripts/source_dispatcher_env.sh"
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

echo "ok source_dispatcher_env loads local env override"
