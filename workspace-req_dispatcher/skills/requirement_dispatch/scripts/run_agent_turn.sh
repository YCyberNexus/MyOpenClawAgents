#!/usr/bin/env bash
# run_agent_turn.sh — 明确的 req_dispatcher → 下游 OpenClaw agent 调用包装。
#
# 本脚本把跨 agent 调用固定为 OpenClaw CLI 的可验证形态：
#   openclaw agent --agent <TARGET_AGENT> --session-id <TARGET_SESSION_ID> \
#     --message <MESSAGE> --timeout <AGENT_TIMEOUT_SECONDS>
#
# TARGET_SESSION_KEY 作为历史兼容输入保留；底层 CLI 统一使用 --session-id。
#
# 目标 agent 的最后一行若是紧凑 JSON，本脚本会把它解析到 worker_result_json。
# 若输出把 pretty JSON 放在 markdown 代码块里，也会兜底提取最后一个合法 JSON object。
# openclaw 调用失败不会让本脚本非零退出；它返回 status=failed 的结构化信封，
# 由 orchestrator 按“同 payload 最多 3 次、2s 退避”处理。入参形态错误才 exit 2。
set -euo pipefail

: "${TARGET_AGENT:?run_agent_turn: TARGET_AGENT required}"

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
if [ -n "${TARGET_SESSION_ID:-}" ]; then
  TARGET_SESSION_SELECTOR="${TARGET_SESSION_ID}"
  TARGET_SESSION_SELECTOR_SOURCE="TARGET_SESSION_ID"
elif [ -n "${TARGET_SESSION_KEY:-}" ]; then
  TARGET_SESSION_SELECTOR="${TARGET_SESSION_KEY}"
  TARGET_SESSION_SELECTOR_SOURCE="TARGET_SESSION_KEY"
else
  TARGET_SESSION_SELECTOR="agent:${TARGET_AGENT}:main"
  TARGET_SESSION_SELECTOR_SOURCE="TARGET_SESSION_ID"
fi
case "${TARGET_SESSION_SELECTOR}" in
  *"…"*)
    echo "run_agent_turn: ${TARGET_SESSION_SELECTOR_SOURCE} must not contain placeholder ellipsis: ${TARGET_SESSION_SELECTOR}" >&2
    exit 2
    ;;
  *"<"*|*">"*)
    echo "run_agent_turn: ${TARGET_SESSION_SELECTOR_SOURCE} must not contain placeholder brackets: ${TARGET_SESSION_SELECTOR}" >&2
    exit 2
    ;;
esac
AGENT_TIMEOUT_SECONDS="${AGENT_TIMEOUT_SECONDS:-${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}}"
MESSAGE="${MESSAGE:-}"
MESSAGE_FILE="${MESSAGE_FILE:-}"

case "${AGENT_TIMEOUT_SECONDS}" in
  *[!0-9]*|"") echo "run_agent_turn: AGENT_TIMEOUT_SECONDS must be a positive integer, got: ${AGENT_TIMEOUT_SECONDS}" >&2; exit 2 ;;
  0) echo "run_agent_turn: AGENT_TIMEOUT_SECONDS must be positive" >&2; exit 2 ;;
esac
if [ -n "${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-}" ]; then
  case "${DOWNSTREAM_AGENT_TIMEOUT_SECONDS}" in
    *[!0-9]*|"") echo "run_agent_turn: DOWNSTREAM_AGENT_TIMEOUT_SECONDS must be a positive integer, got: ${DOWNSTREAM_AGENT_TIMEOUT_SECONDS}" >&2; exit 2 ;;
    0) echo "run_agent_turn: DOWNSTREAM_AGENT_TIMEOUT_SECONDS must be positive" >&2; exit 2 ;;
  esac
  if [ "${AGENT_TIMEOUT_SECONDS}" -lt "${DOWNSTREAM_AGENT_TIMEOUT_SECONDS}" ]; then
    AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS}"
  fi
fi

if [ -n "${MESSAGE_FILE}" ]; then
  if [ ! -f "${MESSAGE_FILE}" ]; then
    echo "run_agent_turn: MESSAGE_FILE not found: ${MESSAGE_FILE}" >&2
    exit 2
  fi
elif [ -z "${MESSAGE}" ]; then
  MESSAGE="$(cat)"
fi

if [ -z "${MESSAGE_FILE}" ] && [ -z "${MESSAGE}" ]; then
  echo "run_agent_turn: MESSAGE, MESSAGE_FILE, or stdin message is required" >&2
  exit 2
fi

SAFE_TARGET="$(printf '%s' "${TARGET_AGENT}" | tr -c 'A-Za-z0-9_-' '_')"
NOW_UTC="$(date -u +%s)"
RUN_ID="${RUN_ID:-openclaw-${SAFE_TARGET}-${NOW_UTC}-$$}"

openclaw_args=(agent --agent "${TARGET_AGENT}")
if [ -n "${TARGET_SESSION_SELECTOR}" ]; then
  openclaw_args+=(--session-id "${TARGET_SESSION_SELECTOR}")
fi
if [ -n "${MESSAGE_FILE}" ]; then
  openclaw_args+=(--message-file "${MESSAGE_FILE}")
else
  openclaw_args+=(--message "${MESSAGE}")
fi
openclaw_args+=(--timeout "${AGENT_TIMEOUT_SECONDS}")

RUN_AGENT_TURN_HEARTBEAT_SECONDS="${RUN_AGENT_TURN_HEARTBEAT_SECONDS:-30}"
case "${RUN_AGENT_TURN_HEARTBEAT_SECONDS}" in
  *[!0-9]*|"") echo "run_agent_turn: RUN_AGENT_TURN_HEARTBEAT_SECONDS must be a positive integer, got: ${RUN_AGENT_TURN_HEARTBEAT_SECONDS}" >&2; exit 2 ;;
  0) echo "run_agent_turn: RUN_AGENT_TURN_HEARTBEAT_SECONDS must be positive" >&2; exit 2 ;;
esac

set +e
AUTO_RAW_OUTPUT_FILE=0
AUTO_STATUS_FILE=0
if [ -n "${RUN_AGENT_TURN_RAW_OUTPUT_FILE:-}" ]; then
  RAW_OUTPUT_FILE="${RUN_AGENT_TURN_RAW_OUTPUT_FILE}"
else
  RAW_OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/req-dispatcher-run-agent-output.XXXXXX")"
  AUTO_RAW_OUTPUT_FILE=1
fi
if [ -n "${RUN_AGENT_TURN_STATUS_FILE:-}" ]; then
  STATUS_FILE="${RUN_AGENT_TURN_STATUS_FILE}"
else
  STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/req-dispatcher-run-agent-status.XXXXXX")"
  AUTO_STATUS_FILE=1
fi
cleanup_auto_temp_files() {
  if [ "${AUTO_RAW_OUTPUT_FILE:-0}" = "1" ] && [ -n "${RAW_OUTPUT_FILE:-}" ] && [ -f "${RAW_OUTPUT_FILE}" ]; then
    : >"${RAW_OUTPUT_FILE}"
  fi
  if [ "${AUTO_STATUS_FILE:-0}" = "1" ] && [ -n "${STATUS_FILE:-}" ] && [ -f "${STATUS_FILE}" ]; then
    : >"${STATUS_FILE}"
  fi
}
trap cleanup_auto_temp_files EXIT
(
  set +e
  "${OPENCLAW_BIN}" "${openclaw_args[@]}" >"${RAW_OUTPUT_FILE}" 2>&1
  printf '%s\n' "$?" >"${STATUS_FILE}"
) &
OPENCLAW_PID=$!
HEARTBEAT_ELAPSED=0
while [ ! -s "${STATUS_FILE}" ]; do
  sleep 1
  HEARTBEAT_ELAPSED=$((HEARTBEAT_ELAPSED + 1))
  if [ ! -s "${STATUS_FILE}" ] && [ $((HEARTBEAT_ELAPSED % RUN_AGENT_TURN_HEARTBEAT_SECONDS)) -eq 0 ]; then
    echo "run_agent_turn: waiting for ${TARGET_AGENT} pid=${OPENCLAW_PID} elapsed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) timeout=${AGENT_TIMEOUT_SECONDS}s" >&2
  fi
done
wait "${OPENCLAW_PID}" >/dev/null 2>&1
EXIT_CODE="$(cat "${STATUS_FILE}" 2>/dev/null)"
case "${EXIT_CODE}" in
  *[!0-9]*|"") EXIT_CODE=127 ;;
esac
RAW_OUTPUT="$(cat "${RAW_OUTPUT_FILE}" 2>/dev/null)"
set -e

WORKER_RESULT_JSON="$(
  printf '%s' "${RAW_OUTPUT}" | jq -R -s -c '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def object_from_json: try (fromjson | select(type == "object")) catch empty;
    def compact_line_objects:
      [split("\n")[] | trim | select(test("^\\{.*\\}$")) | object_from_json];
    def fenced_objects:
      [
        match("(?ms)(^|\\n)[[:space:]]*```[^\\n]*\\n(?<body>.*?)\\n[[:space:]]*```"; "g")
        | .captures[] | select(.name == "body") | .string | object_from_json
      ];
    compact_line_objects[-1] // fenced_objects[-1] // null
  '
)"

if [ "${EXIT_CODE}" -eq 0 ]; then
  STATUS="success"
else
  STATUS="failed"
fi

jq -nc \
  --arg status "${STATUS}" \
  --arg target_agent "${TARGET_AGENT}" \
  --arg child_session_key "${TARGET_SESSION_SELECTOR}" \
  --arg run_id "${RUN_ID}" \
  --argjson exit_code "${EXIT_CODE}" \
  --arg raw_output "${RAW_OUTPUT}" \
  --argjson worker_result_json "${WORKER_RESULT_JSON}" \
  '{
    status: $status,
    target_agent: $target_agent,
    child_session_key: ($child_session_key | select(. != "") // null),
    run_id: $run_id,
    exit_code: $exit_code,
    worker_result_json: $worker_result_json,
    raw_output: $raw_output
  }'
