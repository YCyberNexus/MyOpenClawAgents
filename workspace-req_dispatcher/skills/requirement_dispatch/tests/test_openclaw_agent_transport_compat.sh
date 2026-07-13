#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TRANSPORT="${SKILL_DIR}/scripts/openclaw_agent_transport.sh"
EXECUTOR_TRANSPORT="${SKILL_DIR}/../../../workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/openclaw_agent_transport.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-agent-compat.XXXXXX")"
MODERN_BIN="${TEST_ROOT}/modern-openclaw"
OLD_BIN="${TEST_ROOT}/old-openclaw"
HELPER_BIN="${TEST_ROOT}/gateway-helper"
MODERN_ARGS="${TEST_ROOT}/modern.args"
MODERN_STDIN="${TEST_ROOT}/modern.stdin"
OLD_ARGS="${TEST_ROOT}/old.args"
HELPER_REQUEST="${TEST_ROOT}/helper.request.json"
HELPER_COUNT="${TEST_ROOT}/helper.count"
CONCURRENCY_HELPER="${TEST_ROOT}/concurrency-helper"
CONCURRENCY_ACTIVE="${TEST_ROOT}/concurrency.active"
CONCURRENCY_MAX="${TEST_ROOT}/concurrency.max"
CONCURRENCY_LOCK="${TEST_ROOT}/concurrency.lock"
STATE_DIR="${TEST_ROOT}/state"
NONCE='nonce-compat-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

cat >"${MODERN_BIN}" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = agent ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Options:'
  printf '%s\n' '  --session-key <key>       exact key'
  printf '%s\n' '  --session-id <id>         exact id'
  printf '%s\n' '  --message-file <path>     message file'
  exit 0
fi
printf '%s\n' "$*" >"${MODERN_ARGS}"
cat >"${MODERN_STDIN}"
printf '%s\n' '{"status":"accepted"}'
EOF

cat >"${OLD_BIN}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OLD_ARGS}"
if [ "${1:-}" = agent ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Options:'
  printf '%s\n' '  --session-id <id>         exact id'
  printf '%s\n' '  --message <text>          argv message'
  exit 0
fi
exit 90
EOF

cat >"${HELPER_BIN}" <<'EOF'
#!/usr/bin/env bash
request="$(cat)"
printf '%s' "${request}" >"${HELPER_REQUEST}"
count=0
if [ -f "${HELPER_COUNT}" ]; then count="$(cat "${HELPER_COUNT}")"; fi
printf '%s\n' "$((count + 1))" >"${HELPER_COUNT}"
printf '%s\n' '{"status":"accepted"}'
EOF
chmod +x "${MODERN_BIN}" "${OLD_BIN}" "${HELPER_BIN}"

cat >"${CONCURRENCY_HELPER}" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exec 8>"${CONCURRENCY_LOCK}"
flock 8
active=0
maximum=0
if [ -s "${CONCURRENCY_ACTIVE}" ]; then active="$(cat "${CONCURRENCY_ACTIVE}")"; fi
if [ -s "${CONCURRENCY_MAX}" ]; then maximum="$(cat "${CONCURRENCY_MAX}")"; fi
active=$((active + 1))
printf '%s\n' "${active}" >"${CONCURRENCY_ACTIVE}"
if [ "${active}" -gt "${maximum}" ]; then printf '%s\n' "${active}" >"${CONCURRENCY_MAX}"; fi
flock -u 8
sleep 1
flock 8
active="$(cat "${CONCURRENCY_ACTIVE}")"
printf '%s\n' "$((active - 1))" >"${CONCURRENCY_ACTIVE}"
flock -u 8
printf '%s\n' '{"status":"accepted"}'
EOF
chmod +x "${CONCURRENCY_HELPER}"

modern_output="$(
  printf 'modern message\n%s' "${NONCE}" | env \
    OPENCLAW_BIN="${MODERN_BIN}" \
    MODERN_ARGS="${MODERN_ARGS}" \
    MODERN_STDIN="${MODERN_STDIN}" \
    OPENCLAW_TARGET_AGENT=req_executor \
    OPENCLAW_TARGET_SESSION_KEY=agent:req_executor:issue-7 \
    OPENCLAW_AGENT_TIMEOUT_SECONDS=45 \
    OPENCLAW_RUN_ID=modern-1 \
    "${TRANSPORT}"
)"
if [ "${modern_output}" != '{"status":"accepted"}' ]; then
  echo "modern transport returned unexpected output" >&2
  exit 1
fi
if ! grep -q -- '--agent req_executor --session-key agent:req_executor:issue-7' "${MODERN_ARGS}" \
    || ! grep -q -- '--message-file /dev/stdin' "${MODERN_ARGS}" \
    || grep -q -- "${NONCE}" "${MODERN_ARGS}"; then
  echo "modern transport did not select the safe key/message-file CLI shape" >&2
  exit 1
fi
if [ "$(cat "${MODERN_STDIN}")" != "$(printf 'modern message\n%s' "${NONCE}")" ]; then
  echo "modern transport changed the stdin message" >&2
  exit 1
fi

old_output="$(
  printf 'old message\n%s' "${NONCE}" | env \
    OPENCLAW_BIN="${OLD_BIN}" \
    OLD_ARGS="${OLD_ARGS}" \
    OPENCLAW_GATEWAY_HELPER_BIN="${HELPER_BIN}" \
    HELPER_REQUEST="${HELPER_REQUEST}" \
    HELPER_COUNT="${HELPER_COUNT}" \
    OPENCLAW_TARGET_AGENT=req_executor \
    OPENCLAW_TARGET_SESSION_KEY=agent:req_executor:issue-8 \
    OPENCLAW_AGENT_TIMEOUT_SECONDS=46 \
    OPENCLAW_RUN_ID=old-1 \
    "${TRANSPORT}"
)"
if [ "${old_output}" != '{"status":"accepted"}' ] \
    || [ "$(jq -r '.session_key' "${HELPER_REQUEST}")" != agent:req_executor:issue-8 ] \
    || [ "$(jq -r '.message' "${HELPER_REQUEST}")" != "$(printf 'old message\n%s' "${NONCE}")" ]; then
  echo "old transport did not preserve the full key/message through the local Gateway helper" >&2
  exit 1
fi
if grep -q -- "${NONCE}" "${OLD_ARGS}" || grep -q -- '--message ' "${OLD_ARGS}"; then
  echo "old transport leaked the message into argv" >&2
  exit 1
fi

mkdir -p "${STATE_DIR}/agents/req_dispatcher/sessions"
cat >"${STATE_DIR}/agents/req_dispatcher/sessions/sessions.json" <<'EOF'
{"agent:req_dispatcher:callback-local":{"sessionId":"session-real-1"}}
EOF
printf 'id message' | env \
  OPENCLAW_BIN="${OLD_BIN}" \
  OLD_ARGS="${OLD_ARGS}" \
  OPENCLAW_GATEWAY_HELPER_BIN="${HELPER_BIN}" \
  HELPER_REQUEST="${HELPER_REQUEST}" \
  HELPER_COUNT="${HELPER_COUNT}" \
  OPENCLAW_STATE_DIR="${STATE_DIR}" \
  OPENCLAW_TARGET_AGENT=req_dispatcher \
  OPENCLAW_TARGET_SESSION_ID=session-real-1 \
  OPENCLAW_AGENT_TIMEOUT_SECONDS=47 \
  "${TRANSPORT}" >/dev/null
if [ "$(jq -r '.session_key' "${HELPER_REQUEST}")" != agent:req_dispatcher:callback-local ]; then
  echo "old transport did not resolve the actual session id to its exact stored key" >&2
  exit 1
fi

count_before="$(cat "${HELPER_COUNT}")"
set +e
missing_output="$(
  printf 'missing id' | env \
    OPENCLAW_BIN="${OLD_BIN}" \
    OLD_ARGS="${OLD_ARGS}" \
    OPENCLAW_GATEWAY_HELPER_BIN="${HELPER_BIN}" \
    HELPER_REQUEST="${HELPER_REQUEST}" \
    HELPER_COUNT="${HELPER_COUNT}" \
    OPENCLAW_STATE_DIR="${STATE_DIR}" \
    OPENCLAW_TARGET_AGENT=req_dispatcher \
    OPENCLAW_TARGET_SESSION_ID=missing-session \
    "${TRANSPORT}" 2>&1
)"
missing_rc=$?
set -e
if [ "${missing_rc}" -ne 66 ] || [ "$(cat "${HELPER_COUNT}")" != "${count_before}" ] \
    || ! grep -q 'missing or ambiguous' <<<"${missing_output}"; then
  echo "missing old session id did not fail closed before delivery" >&2
  exit 1
fi

# Flags mentioned only in examples must not be treated as declared options.
printf 'deceptive help' | env \
  OPENCLAW_BIN="${OLD_BIN}" \
  OLD_ARGS="${OLD_ARGS}" \
  OPENCLAW_AGENT_HELP_OVERRIDE=$'Examples:\n  openclaw agent --session-key key --message-file path' \
  OPENCLAW_GATEWAY_HELPER_BIN="${HELPER_BIN}" \
  HELPER_REQUEST="${HELPER_REQUEST}" \
  HELPER_COUNT="${HELPER_COUNT}" \
  OPENCLAW_TARGET_AGENT=req_dispatcher \
  OPENCLAW_TARGET_SESSION_KEY=agent:req_dispatcher:main \
  "${EXECUTOR_TRANSPORT}" >/dev/null
if [ "$(jq -r '.message' "${HELPER_REQUEST}")" != 'deceptive help' ]; then
  echo "capability probe accepted flags from an example line" >&2
  exit 1
fi

# Same-session calls must be single-writer, while distinct keys retain
# concurrency. This prevents the lost-response failure seen in live testing.
printf '0\n' >"${CONCURRENCY_ACTIVE}"
printf '0\n' >"${CONCURRENCY_MAX}"
SESSION_LOCK_ROOT="${TEST_ROOT}/session-locks-same"
for suffix in one two; do
  printf '%s' "same-${suffix}" | env \
    OPENCLAW_BIN="${OLD_BIN}" \
    OLD_ARGS="${OLD_ARGS}" \
    OPENCLAW_GATEWAY_HELPER_BIN="${CONCURRENCY_HELPER}" \
    CONCURRENCY_ACTIVE="${CONCURRENCY_ACTIVE}" \
    CONCURRENCY_MAX="${CONCURRENCY_MAX}" \
    CONCURRENCY_LOCK="${CONCURRENCY_LOCK}" \
    OPENCLAW_SESSION_LOCK_ROOT="${SESSION_LOCK_ROOT}" \
    OPENCLAW_TARGET_AGENT=req_executor \
    OPENCLAW_TARGET_SESSION_KEY=agent:req_executor:same-session \
    "${TRANSPORT}" >"${TEST_ROOT}/same-${suffix}.out" &
done
wait
if [ "$(cat "${CONCURRENCY_MAX}")" -ne 1 ]; then
  echo "same-session transport calls were not serialized" >&2
  exit 1
fi

printf '0\n' >"${CONCURRENCY_ACTIVE}"
printf '0\n' >"${CONCURRENCY_MAX}"
SESSION_LOCK_ROOT="${TEST_ROOT}/session-locks-distinct"
for suffix in one two; do
  printf '%s' "distinct-${suffix}" | env \
    OPENCLAW_BIN="${OLD_BIN}" \
    OLD_ARGS="${OLD_ARGS}" \
    OPENCLAW_GATEWAY_HELPER_BIN="${CONCURRENCY_HELPER}" \
    CONCURRENCY_ACTIVE="${CONCURRENCY_ACTIVE}" \
    CONCURRENCY_MAX="${CONCURRENCY_MAX}" \
    CONCURRENCY_LOCK="${CONCURRENCY_LOCK}" \
    OPENCLAW_SESSION_LOCK_ROOT="${SESSION_LOCK_ROOT}" \
    OPENCLAW_TARGET_AGENT=req_executor \
    OPENCLAW_TARGET_SESSION_KEY="agent:req_executor:distinct-${suffix}" \
    "${TRANSPORT}" >"${TEST_ROOT}/distinct-${suffix}.out" &
done
wait
if [ "$(cat "${CONCURRENCY_MAX}")" -ne 2 ]; then
  echo "different session keys were unnecessarily serialized" >&2
  exit 1
fi

echo "ok openclaw agent transport supports modern and 2026.4.9 semantics"
