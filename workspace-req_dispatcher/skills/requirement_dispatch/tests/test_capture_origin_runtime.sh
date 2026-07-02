#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAPTURE="${SKILL_DIR}/scripts/capture_origin.sh"

runtime_json_wins="$(
  OPENCLAW_DELIVER_ORIGIN_JSON='{"channel":"wecom","user":"runtime-user","conversation":"runtime-conv","reply_agent":"runtime_reply_agent","source_session":"agent:runtime:main"}' \
  MESSAGE='[origin] channel=wecom user=text-user conversation=text-conv reply_agent=text_reply_agent
需求正文' \
  bash "${CAPTURE}"
)"

if [ "$(jq -r '.reply_agent' <<<"${runtime_json_wins}")" != "runtime_reply_agent" ]; then
  echo "expected structured runtime origin JSON to win over message [origin]" >&2
  printf '%s\n' "${runtime_json_wins}" >&2
  exit 1
fi

if [ "$(jq -r '.user' <<<"${runtime_json_wins}")" != "runtime-user" ]; then
  echo "expected structured runtime origin JSON user to be preserved" >&2
  printf '%s\n' "${runtime_json_wins}" >&2
  exit 1
fi

discrete_runtime="$(
  OPENCLAW_SOURCE_AGENT="114-Coding" \
  OPENCLAW_SOURCE_SESSION="agent:114-Coding:main" \
  OPENCLAW_DELIVER_CHANNEL="wecom" \
  OPENCLAW_DELIVER_USER="wuyun" \
  OPENCLAW_DELIVER_CONVERSATION="conv-114" \
  bash "${CAPTURE}" <<<"没有 origin 行的需求正文"
)"

if [ "$(jq -r '.reply_agent' <<<"${discrete_runtime}")" != "114-Coding" ]; then
  echo "expected discrete runtime source agent to become reply_agent" >&2
  printf '%s\n' "${discrete_runtime}" >&2
  exit 1
fi

if [ "$(jq -r '.source_session' <<<"${discrete_runtime}")" != "agent:114-Coding:main" ]; then
  echo "expected discrete runtime source session to be preserved" >&2
  printf '%s\n' "${discrete_runtime}" >&2
  exit 1
fi

session_only="$(
  OPENCLAW_SOURCE_SESSION="agent:114-OnlySession:main" \
  bash "${CAPTURE}" <<<"没有 origin 行的需求正文"
)"

if [ "$(jq -r '.reply_agent' <<<"${session_only}")" != "114-OnlySession" ]; then
  echo "expected source session key to infer reply_agent when source agent is absent" >&2
  printf '%s\n' "${session_only}" >&2
  exit 1
fi

message_fallback="$(
  bash "${CAPTURE}" <<'EOF'
[origin] channel=wecom user=msg-user conversation=msg-conv reply_agent=msg_reply_agent
需求正文
EOF
)"

if [ "$(jq -r '.reply_agent' <<<"${message_fallback}")" != "msg_reply_agent" ]; then
  echo "expected message [origin] to be used when runtime source metadata is absent" >&2
  printf '%s\n' "${message_fallback}" >&2
  exit 1
fi

empty_origin="$(bash "${CAPTURE}" <<<"没有来源元数据的需求正文")"
if [ -n "${empty_origin}" ]; then
  echo "expected no output when no runtime metadata or [origin] line exists" >&2
  printf '%s\n' "${empty_origin}" >&2
  exit 1
fi

echo "ok capture_origin runtime metadata precedence"
