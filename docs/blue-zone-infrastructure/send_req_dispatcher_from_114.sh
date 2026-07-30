#!/usr/bin/env bash
# 114 智伴个人 Agent -> 104 req_dispatcher 需求提交脚本。
#
# 本脚本只负责提交需求并输出 req_dispatcher 当前轮次的受理回复。
# AI Coding 任务异步执行，终态结果由 104 通过反向 Gateway 推送到
# agent:<CURRENT_AGENT_NAME>:main；调用方不得把受理回复当成任务终态。
#
# 114 部署环境必须注入：
#   REQ_DISPATCHER_GATEWAY_TOKEN  104 Gateway Bearer token
#   CURRENT_AGENT_NAME            当前个人 Agent 名，例如 zhujiaye
#   WECHAT_USER_ID                企微发起人 ID
#   WECHAT_CONVERSATION_ID        企微会话或群聊 ID
#
# 可选：
#   REQ_DISPATCHER_GATEWAY_URL    默认 http://10.64.5.104:18789/v1/chat/completions
#   REQ_DISPATCHER_CONNECT_TIMEOUT_SECONDS  默认 10
#   REQ_DISPATCHER_REQUEST_TIMEOUT_SECONDS  默认 120
#   TASK_DESCRIPTION              需求原文；为空时从标准输入读取
#
# 推荐调用方式：
#   printf '%s' '<用户原始需求>' | bash send_req_dispatcher_from_114.sh
#
# 不要把 token 或用户需求放进命令参数、Skill 正文、日志或回复。
set -euo pipefail
umask 077

die() {
  printf 'send_req_dispatcher_from_114: %s\n' "$1" >&2
  exit "${2:-64}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || die "required command not found: $1" 69
}

require_no_line_break() {
  local name="$1"
  local value="$2"
  case "${value}" in
    *$'\n'*|*$'\r'*) die "${name} must not contain line breaks" ;;
  esac
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  case "${value}" in
    ''|*[!0-9]*|0) die "${name} must be a positive integer" ;;
  esac
}

sha256_hex() {
  local value="$1"
  local digest

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "${value}" | sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "${value}" | shasum -a 256)"
  else
    die "sha256sum or shasum is required" 69
  fi

  digest="${digest%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] \
    || die "SHA-256 command returned an invalid digest" 69
  printf '%s' "${digest}"
}

require_chat_completions_url() {
  local value="$1"
  local authority

  case "${value}" in
    http://*|https://*) ;;
    *) die "REQ_DISPATCHER_GATEWAY_URL must use http:// or https://" ;;
  esac

  authority="${value#*://}"
  authority="${authority%%/*}"
  [ -n "${authority}" ] \
    || die "REQ_DISPATCHER_GATEWAY_URL must include a host"

  case "${authority}" in
    *@*) die "REQ_DISPATCHER_GATEWAY_URL must not contain credentials" ;;
  esac

  case "${value}" in
    */v1/chat/completions) ;;
    *)
      die "REQ_DISPATCHER_GATEWAY_URL must end with /v1/chat/completions"
      ;;
  esac
}

require_command curl
require_command jq

: "${REQ_DISPATCHER_GATEWAY_TOKEN:?send_req_dispatcher_from_114: REQ_DISPATCHER_GATEWAY_TOKEN required}"
: "${CURRENT_AGENT_NAME:?send_req_dispatcher_from_114: CURRENT_AGENT_NAME required}"
: "${WECHAT_USER_ID:?send_req_dispatcher_from_114: WECHAT_USER_ID required}"
: "${WECHAT_CONVERSATION_ID:?send_req_dispatcher_from_114: WECHAT_CONVERSATION_ID required}"

REQ_DISPATCHER_GATEWAY_URL="${REQ_DISPATCHER_GATEWAY_URL:-http://10.64.5.104:18789/v1/chat/completions}"
REQ_DISPATCHER_CONNECT_TIMEOUT_SECONDS="${REQ_DISPATCHER_CONNECT_TIMEOUT_SECONDS:-10}"
REQ_DISPATCHER_REQUEST_TIMEOUT_SECONDS="${REQ_DISPATCHER_REQUEST_TIMEOUT_SECONDS:-120}"
REQ_DISPATCHER_AGENT_ID="req_dispatcher"

case "${CURRENT_AGENT_NAME}" in
  ''|*[!A-Za-z0-9_-]*)
    die "CURRENT_AGENT_NAME must match [A-Za-z0-9_-]+"
    ;;
esac

require_no_line_break REQ_DISPATCHER_GATEWAY_TOKEN "${REQ_DISPATCHER_GATEWAY_TOKEN}"
require_no_line_break CURRENT_AGENT_NAME "${CURRENT_AGENT_NAME}"
require_no_line_break WECHAT_USER_ID "${WECHAT_USER_ID}"
require_no_line_break WECHAT_CONVERSATION_ID "${WECHAT_CONVERSATION_ID}"
require_no_line_break REQ_DISPATCHER_GATEWAY_URL "${REQ_DISPATCHER_GATEWAY_URL}"
require_chat_completions_url "${REQ_DISPATCHER_GATEWAY_URL}"
require_positive_integer REQ_DISPATCHER_CONNECT_TIMEOUT_SECONDS \
  "${REQ_DISPATCHER_CONNECT_TIMEOUT_SECONDS}"
require_positive_integer REQ_DISPATCHER_REQUEST_TIMEOUT_SECONDS \
  "${REQ_DISPATCHER_REQUEST_TIMEOUT_SECONDS}"

if [ -n "${TASK_DESCRIPTION:-}" ]; then
  task_description="${TASK_DESCRIPTION}"
elif [ -t 0 ]; then
  die "TASK_DESCRIPTION is empty and stdin has no task description"
else
  task_description="$(cat)"
fi

[ -n "${task_description}" ] \
  || die "task description must not be empty"

origin_json="$({
  jq -nc \
    --arg user "${WECHAT_USER_ID}" \
    --arg conversation "${WECHAT_CONVERSATION_ID}" \
    --arg agent "${CURRENT_AGENT_NAME}" '
      {
        channel: "wecom",
        user: $user,
        conversation: $conversation,
        reply_agent: $agent,
        source_agent: $agent,
        source_session: ("agent:" + $agent + ":main")
      }
    '
})"

# 同一 114 个人 Agent、企微会话和用户稳定复用一个 intake session；任一
# origin 维度不同都会得到独立 session，避免多用户请求共享 req_dispatcher
# main transcript。使用规范 JSON 后再散列，避免分隔符碰撞，也不在 session key
# 中暴露企微标识。main session 继续留给 callback/tick 等控制面消息。
session_identity_json="$({
  jq -nc \
    --arg reply_agent "${CURRENT_AGENT_NAME}" \
    --arg conversation "${WECHAT_CONVERSATION_ID}" \
    --arg user "${WECHAT_USER_ID}" '
      {
        reply_agent: $reply_agent,
        conversation: $conversation,
        user: $user
      }
    '
})"
session_identity_sha256="$(sha256_hex "${session_identity_json}")"
REQ_DISPATCHER_SESSION_KEY="agent:req_dispatcher:intake-${session_identity_sha256}"

message="$(printf '[origin] %s\n%s' "${origin_json}" "${task_description}")"

request_json="$({
  jq -nc \
    --arg model "openclaw/${REQ_DISPATCHER_AGENT_ID}" \
    --arg message "${message}" '
    {
      model: $model,
      messages: [
        {
          role: "user",
          content: $message
        }
      ],
      stream: false
    }
  '
})"

# 使用 Chat Completions 直接执行 req_dispatcher，不调用 sessions_send。
# 104 OpenClaw 2026.4.9 会以 deliver=false 运行此入口：Agent 回复只写入本次
# HTTP 响应，不会启动 A2A announce，也不会沿 main 的企微 last route 外发。
# model 与 agent header 固定；session header 按 origin 三元组稳定隔离，避免落入
# 默认 main，也避免不同企微会话共享 transcript。

# 通过 curl 配置文件描述符传入 Authorization header，避免 token 出现在
# curl 命令参数中。这里不创建磁盘临时文件。
render_curl_auth_config() {
  case "${REQ_DISPATCHER_GATEWAY_TOKEN}" in
    *'"'*|*'\'*)
      die "REQ_DISPATCHER_GATEWAY_TOKEN contains unsupported quote or backslash"
      ;;
  esac
  printf 'header = "Authorization: Bearer %s"\n' \
    "${REQ_DISPATCHER_GATEWAY_TOKEN}"
}

set +e
response="$({
  printf '%s' "${request_json}" \
    | curl \
        --silent \
        --show-error \
        --fail \
        --request POST \
        --connect-timeout "${REQ_DISPATCHER_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${REQ_DISPATCHER_REQUEST_TIMEOUT_SECONDS}" \
        --config <(render_curl_auth_config) \
        --header 'Content-Type: application/json' \
        --header "x-openclaw-agent-id: ${REQ_DISPATCHER_AGENT_ID}" \
        --header "x-openclaw-session-key: ${REQ_DISPATCHER_SESSION_KEY}" \
        --data-binary @- \
        "${REQ_DISPATCHER_GATEWAY_URL}"
})"
curl_rc=$?
set -e

if [ "${curl_rc}" -ne 0 ]; then
  die "104 /v1/chat/completions request failed with curl exit code ${curl_rc}" 69
fi

[ -n "${response}" ] \
  || die "104 /v1/chat/completions returned an empty response" 69

if ! printf '%s' "${response}" | jq empty >/dev/null 2>&1; then
  die "104 /v1/chat/completions returned non-JSON content" 69
fi

# stdout 只输出104原始JSON应答，供114个人 Agent 判断是否成功受理。
printf '%s\n' "${response}"
