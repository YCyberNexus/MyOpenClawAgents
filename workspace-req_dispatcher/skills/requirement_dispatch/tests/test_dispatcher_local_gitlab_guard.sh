#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_ENV="${SKILL_DIR}/scripts/source_dispatcher_env.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-local-guard.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/dispatcher.env" <<'EOF'
WIKI_GITLAB_HOST=tracked-blue.example:30000
WIKI_GITLAB_API_PROTOCOL=http
WIKI_GITLAB_TOKEN=tracked-token-must-not-reach-local
STATE_ROOT=/data/req_dispatcher
EXECUTOR_SCHEDULER_STATE_FILE=/data/req_executor/_scheduler/scheduler_state.json
EXECUTOR_ACPX_TIMEOUT_SECONDS=3600
OPENCLAW_SUBAGENT_TIMEOUT_SECONDS=20400
EOF

run_source() {
  env \
    DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" \
    REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE=true \
    REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS=localhost:8081 \
    bash -c 'source "$1"' _ "${SOURCE_ENV}"
}

set +e
run_source >"${TEST_ROOT}/missing-local.out" 2>"${TEST_ROOT}/missing-local.err"
missing_local_rc=$?
set -e
[ "${missing_local_rc}" -eq 14 ] || {
  echo "dispatcher local-test mode did not reject a missing local override" >&2
  exit 1
}

cat >"${CONFIG_DIR}/dispatcher.local.env" <<'EOF'
GITLAB_HOST=localhost:8081
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=local-dispatcher-token
WIKI_GITLAB_HOST=localhost:8081
WIKI_GITLAB_API_PROTOCOL=http
WIKI_GITLAB_TOKEN=local-dispatcher-token
REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE=false
REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS=tracked-blue.example:30000
EOF

env \
  DISPATCHER_CONFIG_DIR="${CONFIG_DIR}" \
  REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE=true \
  REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS=localhost:8081 \
  bash -c '
    set -euo pipefail
    source "$1"
    [ "$WIKI_GITLAB_HOST" = localhost:8081 ]
    [ "$GITLAB_HOST" = localhost:8081 ]
    [ "$REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE" = true ]
    [ "$REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS" = localhost:8081 ]
  ' _ "${SOURCE_ENV}"

for missing_field in host protocol token; do
  {
    printf '%s\n' \
      'GITLAB_HOST=localhost:8081' \
      'GITLAB_API_PROTOCOL=http' \
      'GITLAB_TOKEN=local-dispatcher-token'
    [ "${missing_field}" = host ] \
      || printf '%s\n' 'WIKI_GITLAB_HOST=localhost:8081'
    [ "${missing_field}" = protocol ] \
      || printf '%s\n' 'WIKI_GITLAB_API_PROTOCOL=http'
    [ "${missing_field}" = token ] \
      || printf '%s\n' 'WIKI_GITLAB_TOKEN=local-dispatcher-token'
  } >"${CONFIG_DIR}/dispatcher.local.env"
  set +e
  run_source >"${TEST_ROOT}/partial-${missing_field}.out" \
    2>"${TEST_ROOT}/partial-${missing_field}.err"
  partial_rc=$?
  set -e
  [ "${partial_rc}" -eq 14 ] || {
    echo "dispatcher accepted a partial local WIKI_GITLAB tuple" >&2
    exit 1
  }
done

cat >"${CONFIG_DIR}/dispatcher.local.env" <<'EOF'
GITLAB_HOST=localhost:8081
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=tracked-token-must-not-reach-local
WIKI_GITLAB_HOST=localhost:8081
WIKI_GITLAB_API_PROTOCOL=http
WIKI_GITLAB_TOKEN=tracked-token-must-not-reach-local
EOF

set +e
run_source >"${TEST_ROOT}/tracked-token.out" 2>"${TEST_ROOT}/tracked-token.err"
tracked_token_rc=$?
set -e
[ "${tracked_token_rc}" -eq 14 ] || {
  echo "dispatcher local-test mode accepted a token equal to the tracked token" >&2
  exit 1
}

echo "ok dispatcher local GitLab guard fails closed"
