#!/usr/bin/env bash
# Capability-based, secret-safe OpenClaw agent transport.
#
# The 2026.6.11 CLI can accept an exact session key and read the message from
# stdin via --message-file. 2026.4.9 only exposes --session-id + --message;
# using the latter would both collapse new custom keys to main and expose the
# complete message in argv. When the safe CLI surface is unavailable, this
# wrapper calls the loopback Gateway in-process through the installed OpenClaw
# package while still reading the request from stdin.
set -euo pipefail
umask 077

: "${OPENCLAW_TARGET_AGENT:?openclaw_agent_transport: OPENCLAW_TARGET_AGENT required}"

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
OPENCLAW_NODE_BIN="${OPENCLAW_NODE_BIN:-node}"
OPENCLAW_AGENT_TIMEOUT_SECONDS="${OPENCLAW_AGENT_TIMEOUT_SECONDS:-600}"
OPENCLAW_TARGET_SESSION_KEY="${OPENCLAW_TARGET_SESSION_KEY:-}"
OPENCLAW_TARGET_SESSION_ID="${OPENCLAW_TARGET_SESSION_ID:-}"
OPENCLAW_RUN_ID="${OPENCLAW_RUN_ID:-req-agent-$(date -u +%s)-$$}"
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"

case "${OPENCLAW_TARGET_AGENT}" in
  *[!A-Za-z0-9_-]*|"")
    echo "openclaw_agent_transport: invalid target agent" >&2
    exit 64
    ;;
esac
case "${OPENCLAW_AGENT_TIMEOUT_SECONDS}" in
  *[!0-9]*|""|0)
    echo "openclaw_agent_transport: timeout must be a positive integer" >&2
    exit 64
    ;;
esac
if [ -n "${OPENCLAW_TARGET_SESSION_KEY}" ] && [ -n "${OPENCLAW_TARGET_SESSION_ID}" ]; then
  echo "openclaw_agent_transport: session key and session id are mutually exclusive" >&2
  exit 64
fi

MESSAGE="$(cat)"
if [ -z "${MESSAGE}" ]; then
  echo "openclaw_agent_transport: stdin message is required" >&2
  exit 64
fi

validate_session_key() {
  case "$1" in
    "agent:${OPENCLAW_TARGET_AGENT}:"*) ;;
    *)
      echo "openclaw_agent_transport: session key does not belong to target agent" >&2
      exit 65
      ;;
  esac
}

resolve_existing_session_key() {
  local session_id="$1"
  local registry="${OPENCLAW_STATE_DIR}/agents/${OPENCLAW_TARGET_AGENT}/sessions/sessions.json"
  local matches
  local count
  if [ ! -f "${registry}" ]; then
    echo "openclaw_agent_transport: session registry not found for target agent" >&2
    exit 66
  fi
  matches="$(jq -c --arg id "${session_id}" '
    [to_entries[]
      | select(.value.sessionId == $id)
      | .key
      | select(startswith("agent:"))]
  ' "${registry}")" || {
    echo "openclaw_agent_transport: invalid target session registry" >&2
    exit 66
  }
  count="$(jq -r 'length' <<<"${matches}")"
  if [ "${count}" -ne 1 ]; then
    echo "openclaw_agent_transport: target session id is missing or ambiguous" >&2
    exit 66
  fi
  jq -r '.[0]' <<<"${matches}"
}

if [ -z "${OPENCLAW_TARGET_SESSION_KEY}" ] && [ -z "${OPENCLAW_TARGET_SESSION_ID}" ]; then
  OPENCLAW_TARGET_SESSION_KEY="agent:${OPENCLAW_TARGET_AGENT}:main"
fi
if [ -n "${OPENCLAW_TARGET_SESSION_KEY}" ]; then
  validate_session_key "${OPENCLAW_TARGET_SESSION_KEY}"
fi

RESOLVED_SESSION_KEY="${OPENCLAW_TARGET_SESSION_KEY}"
if [ -n "${OPENCLAW_TARGET_SESSION_ID}" ]; then
  RESOLVED_SESSION_KEY="$(resolve_existing_session_key "${OPENCLAW_TARGET_SESSION_ID}")"
  validate_session_key "${RESOLVED_SESSION_KEY}"
fi

# OpenClaw sessions are single-writer lanes. Serialize only calls targeting the
# exact same stored key; different issue/session keys remain fully concurrent.
OPENCLAW_SESSION_LOCK_ROOT="${OPENCLAW_SESSION_LOCK_ROOT:-${TMPDIR:-/tmp}/openclaw-agent-session-locks}"
mkdir -p "${OPENCLAW_SESSION_LOCK_ROOT}"
chmod 700 "${OPENCLAW_SESSION_LOCK_ROOT}" 2>/dev/null || true
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_LOCK_DIGEST="$(printf '%s' "${RESOLVED_SESSION_KEY}" | sha256sum | awk '{print $1}')"
else
  SESSION_LOCK_DIGEST="$(printf '%s' "${RESOLVED_SESSION_KEY}" | shasum -a 256 | awk '{print $1}')"
fi
exec 9>"${OPENCLAW_SESSION_LOCK_ROOT}/${SESSION_LOCK_DIGEST}.lock"
flock 9

if [ -n "${OPENCLAW_AGENT_HELP_OVERRIDE:-}" ]; then
  AGENT_HELP="${OPENCLAW_AGENT_HELP_OVERRIDE}"
else
  set +e
  AGENT_HELP="$("${OPENCLAW_BIN}" agent --help 2>&1)"
  HELP_RC=$?
  set -e
  if [ "${HELP_RC}" -ne 0 ]; then
    echo "openclaw_agent_transport: unable to probe openclaw agent capabilities" >&2
    exit 67
  fi
fi

has_option() {
  printf '%s\n' "${AGENT_HELP}" \
    | grep -Eq "^[[:space:]]+$1([[:space:]]+<[^>]+>)?([[:space:]]|$)"
}

HAS_MESSAGE_FILE=0
HAS_SESSION_KEY=0
HAS_SESSION_ID=0
has_option --message-file && HAS_MESSAGE_FILE=1
has_option --session-key && HAS_SESSION_KEY=1
has_option --session-id && HAS_SESSION_ID=1

# Use only a CLI shape that keeps the message out of argv and preserves the
# selector's actual semantics. An explicit session id is invoked without
# --agent; otherwise old/new resolvers can silently force the agent main key.
USE_SAFE_CLI=0
if [ "${HAS_MESSAGE_FILE}" -eq 1 ]; then
  if [ -n "${OPENCLAW_TARGET_SESSION_KEY}" ] && [ "${HAS_SESSION_KEY}" -eq 1 ]; then
    USE_SAFE_CLI=1
  elif [ -n "${OPENCLAW_TARGET_SESSION_ID}" ] && [ "${HAS_SESSION_ID}" -eq 1 ]; then
    USE_SAFE_CLI=1
  fi
fi
if [ "${USE_SAFE_CLI}" -eq 1 ]; then
  openclaw_args=(agent)
  if [ -n "${OPENCLAW_TARGET_SESSION_ID}" ]; then
    openclaw_args+=(--session-id "${OPENCLAW_TARGET_SESSION_ID}")
  else
    openclaw_args+=(--agent "${OPENCLAW_TARGET_AGENT}" --session-key "${OPENCLAW_TARGET_SESSION_KEY}")
  fi
  openclaw_args+=(--message-file /dev/stdin --timeout "${OPENCLAW_AGENT_TIMEOUT_SECONDS}")
  printf '%s' "${MESSAGE}" | "${OPENCLAW_BIN}" "${openclaw_args[@]}"
  exit $?
fi

# 2026.4.9 has neither --session-key nor --message-file. Never fall back to
# --message: callback nonces and tokens would become visible in process argv.
if [ -n "${OPENCLAW_GATEWAY_HELPER_BIN:-}" ]; then
  helper_cmd=("${OPENCLAW_GATEWAY_HELPER_BIN}")
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  helper_cmd=("${OPENCLAW_NODE_BIN}" "${SCRIPT_DIR}/openclaw_agent_gateway.mjs")
fi

if [[ "${OPENCLAW_BIN}" == */* ]]; then
  OPENCLAW_BIN_PATH="${OPENCLAW_BIN}"
else
  OPENCLAW_BIN_PATH="$(command -v "${OPENCLAW_BIN}" 2>/dev/null || true)"
fi
if [ -z "${OPENCLAW_BIN_PATH}" ]; then
  echo "openclaw_agent_transport: openclaw executable not found" >&2
  exit 67
fi

jq -nc \
  --arg openclaw_bin_path "${OPENCLAW_BIN_PATH}" \
  --arg target_agent "${OPENCLAW_TARGET_AGENT}" \
  --arg session_key "${RESOLVED_SESSION_KEY}" \
  --arg message "${MESSAGE}" \
  --arg run_id "${OPENCLAW_RUN_ID}" \
  --argjson timeout_seconds "${OPENCLAW_AGENT_TIMEOUT_SECONDS}" '{
    openclaw_bin_path:$openclaw_bin_path,
    target_agent:$target_agent,
    session_key:$session_key,
    message:$message,
    run_id:$run_id,
    timeout_seconds:$timeout_seconds
  }' | "${helper_cmd[@]}"
