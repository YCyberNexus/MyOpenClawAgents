#!/usr/bin/env bash
# Capture req_dispatcher origin metadata for the intake path.
#
# Precedence:
#   1. Structured runtime / gateway origin JSON, when OpenClaw provides it.
#   2. Discrete runtime / gateway source env vars.
#   3. Message text line: [origin] channel=... user=... conversation=... reply_agent=...
#
# stdout:
#   - compact JSON object when origin is available
#   - empty output when origin is unavailable
#
# This script never parses project or requirement semantics. The message fallback
# reads only the explicit [origin] metadata line.
set -euo pipefail

first_env() {
  for _name in "$@"; do
    _value="$(printenv "${_name}" 2>/dev/null || true)"
    if [ -n "${_value}" ]; then
      printf '%s' "${_value}"
      return 0
    fi
  done
  return 0
}

infer_agent_from_session() {
  _session="$1"
  case "${_session}" in
    agent:*:*)
      _rest="${_session#agent:}"
      printf '%s' "${_rest%%:*}"
      ;;
  esac
}

normalize_origin_json() {
  _json="$1"
  printf '%s' "${_json}" | jq -c '
    if type != "object" then empty else
      def clean:
        with_entries(select(.value != null and .value != ""));
      {
        channel: (.channel // .source_channel // .deliver_channel // null),
        user: (.user // .source_user // .deliver_user // .user_id // null),
        conversation: (.conversation // .conversation_id // .conv // .source_conversation // .deliver_conversation // null),
        reply_agent: (.reply_agent // .source_agent // .agent // .sender_agent // .from_agent // null),
        source_agent: (.source_agent // .agent // .sender_agent // .from_agent // null),
        source_session: (.source_session // .source_session_key // .session // .session_key // null)
      } | clean | if length == 0 then empty else . end
    end' 2>/dev/null || true
}

origin_from_structured_json() {
  _candidate="$(first_env \
    OPENCLAW_DELIVER_ORIGIN_JSON \
    OPENCLAW_DELIVER_ORIGIN \
    OPENCLAW_SOURCE_ORIGIN_JSON \
    OPENCLAW_SOURCE_ORIGIN \
    DELIVER_ORIGIN_JSON \
    DELIVER_ORIGIN \
    SOURCE_ORIGIN_JSON \
    SOURCE_ORIGIN)"
  [ -n "${_candidate}" ] || return 0
  normalize_origin_json "${_candidate}"
}

origin_from_runtime_env() {
  _source_session="$(first_env \
    OPENCLAW_SOURCE_SESSION \
    OPENCLAW_SOURCE_SESSION_KEY \
    OPENCLAW_DELIVER_SOURCE_SESSION \
    SOURCE_SESSION \
    SOURCE_SESSION_KEY)"
  _source_agent="$(first_env \
    OPENCLAW_SOURCE_AGENT \
    OPENCLAW_SOURCE_AGENT_NAME \
    OPENCLAW_DELIVER_SOURCE_AGENT \
    OPENCLAW_DELIVER_AGENT \
    SOURCE_AGENT \
    SOURCE_AGENT_NAME)"
  if [ -z "${_source_agent}" ] && [ -n "${_source_session}" ]; then
    _source_agent="$(infer_agent_from_session "${_source_session}")"
  fi
  _reply_agent="$(first_env \
    OPENCLAW_REPLY_AGENT \
    OPENCLAW_DELIVER_REPLY_AGENT \
    REPLY_AGENT \
    DELIVER_REPLY_AGENT)"
  _reply_agent="${_reply_agent:-${_source_agent}}"
  _channel="$(first_env \
    OPENCLAW_ORIGIN_CHANNEL \
    OPENCLAW_SOURCE_CHANNEL \
    OPENCLAW_DELIVER_CHANNEL \
    DELIVER_CHANNEL \
    SOURCE_CHANNEL)"
  _user="$(first_env \
    OPENCLAW_ORIGIN_USER \
    OPENCLAW_SOURCE_USER \
    OPENCLAW_DELIVER_USER \
    DELIVER_USER \
    SOURCE_USER)"
  _conversation="$(first_env \
    OPENCLAW_ORIGIN_CONVERSATION \
    OPENCLAW_SOURCE_CONVERSATION \
    OPENCLAW_DELIVER_CONVERSATION \
    OPENCLAW_CONVERSATION_ID \
    DELIVER_CONVERSATION \
    SOURCE_CONVERSATION)"

  jq -nc \
    --arg channel "${_channel}" \
    --arg user "${_user}" \
    --arg conversation "${_conversation}" \
    --arg reply_agent "${_reply_agent}" \
    --arg source_agent "${_source_agent}" \
    --arg source_session "${_source_session}" \
    '{channel:$channel,
      user:$user,
      conversation:$conversation,
      reply_agent:$reply_agent,
      source_agent:$source_agent,
      source_session:$source_session}
     | with_entries(select(.value != ""))
     | if length == 0 then empty else . end'
}

read_message() {
  if [ -n "${MESSAGE:-}" ]; then
    printf '%s' "${MESSAGE}"
  elif [ -n "${MESSAGE_FILE:-}" ]; then
    [ -f "${MESSAGE_FILE}" ] || { echo "capture_origin: MESSAGE_FILE not found: ${MESSAGE_FILE}" >&2; exit 2; }
    cat "${MESSAGE_FILE}"
  elif [ -t 0 ]; then
    :
  else
    cat
  fi
}

origin_from_message() {
  _message="$1"
  _origin_line=""
  while IFS= read -r _line || [ -n "${_line}" ]; do
    _line="${_line%$'\r'}"
    case "${_line}" in
      "[origin]"*|" "*"[origin]"*)
        _trimmed="${_line#"${_line%%[![:space:]]*}"}"
        case "${_trimmed}" in
          "[origin]"*) _origin_line="${_trimmed#"[origin]"}"; break ;;
        esac
        ;;
    esac
  done <<EOF
${_message}
EOF

  [ -n "${_origin_line}" ] || return 0
  _origin_line="${_origin_line#"${_origin_line%%[![:space:]]*}"}"
  case "${_origin_line}" in
    \{*) normalize_origin_json "${_origin_line}"; return 0 ;;
  esac

  _channel=""
  _user=""
  _conversation=""
  _reply_agent=""
  _source_agent=""
  _source_session=""

  for _token in ${_origin_line}; do
    case "${_token}" in
      *=*) ;;
      *) continue ;;
    esac
    _key="${_token%%=*}"
    _value="${_token#*=}"
    case "${_key}" in
      channel) _channel="${_value}" ;;
      user) _user="${_value}" ;;
      conversation|conversation_id|conv) _conversation="${_value}" ;;
      reply_agent) _reply_agent="${_value}" ;;
      source_agent|agent) _source_agent="${_value}" ;;
      source_session|source_session_key|session|session_key) _source_session="${_value}" ;;
    esac
  done

  if [ -z "${_reply_agent}" ] && [ -n "${_source_agent}" ]; then
    _reply_agent="${_source_agent}"
  fi
  if [ -z "${_reply_agent}" ] && [ -n "${_source_session}" ]; then
    _reply_agent="$(infer_agent_from_session "${_source_session}")"
  fi

  jq -nc \
    --arg channel "${_channel}" \
    --arg user "${_user}" \
    --arg conversation "${_conversation}" \
    --arg reply_agent "${_reply_agent}" \
    --arg source_agent "${_source_agent}" \
    --arg source_session "${_source_session}" \
    '{channel:$channel,
      user:$user,
      conversation:$conversation,
      reply_agent:$reply_agent,
      source_agent:$source_agent,
      source_session:$source_session}
     | with_entries(select(.value != ""))
     | if length == 0 then empty else . end'
}

origin="$(origin_from_structured_json)"
if [ -n "${origin}" ]; then
  printf '%s\n' "${origin}"
  exit 0
fi

origin="$(origin_from_runtime_env)"
if [ -n "${origin}" ]; then
  printf '%s\n' "${origin}"
  exit 0
fi

message="$(read_message)"
origin="$(origin_from_message "${message}")"
[ -z "${origin}" ] || printf '%s\n' "${origin}"
