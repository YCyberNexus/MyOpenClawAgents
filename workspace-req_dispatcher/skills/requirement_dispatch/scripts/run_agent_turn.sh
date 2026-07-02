#!/usr/bin/env bash
# run_agent_turn.sh — 明确的 req_dispatcher → 下游 OpenClaw agent 调用包装。
#
# 本脚本把跨 agent 调用固定为 OpenClaw CLI 的可验证形态：
#   openclaw agent --agent <TARGET_AGENT> --session-key <TARGET_SESSION_KEY> \
#     --message <MESSAGE> --timeout <AGENT_TIMEOUT_SECONDS>
#
# 目标 agent 的最后一行若是紧凑 JSON，本脚本会把它解析到 worker_result_json。
# openclaw 调用失败不会让本脚本非零退出；它返回 status=failed 的结构化信封，
# 由 orchestrator 按“同 payload 最多 3 次、2s 退避”处理。入参形态错误才 exit 2。
set -euo pipefail

: "${TARGET_AGENT:?run_agent_turn: TARGET_AGENT required}"

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
TARGET_SESSION_KEY="${TARGET_SESSION_KEY:-agent:${TARGET_AGENT}:main}"
AGENT_TIMEOUT_SECONDS="${AGENT_TIMEOUT_SECONDS:-600}"
MESSAGE="${MESSAGE:-}"
MESSAGE_FILE="${MESSAGE_FILE:-}"

case "${AGENT_TIMEOUT_SECONDS}" in
  *[!0-9]*|"") echo "run_agent_turn: AGENT_TIMEOUT_SECONDS must be a positive integer, got: ${AGENT_TIMEOUT_SECONDS}" >&2; exit 2 ;;
  0) echo "run_agent_turn: AGENT_TIMEOUT_SECONDS must be positive" >&2; exit 2 ;;
esac

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
if [ -n "${TARGET_SESSION_KEY}" ]; then
  openclaw_args+=(--session-key "${TARGET_SESSION_KEY}")
fi
if [ -n "${MESSAGE_FILE}" ]; then
  openclaw_args+=(--message-file "${MESSAGE_FILE}")
else
  openclaw_args+=(--message "${MESSAGE}")
fi
openclaw_args+=(--timeout "${AGENT_TIMEOUT_SECONDS}")

set +e
RAW_OUTPUT="$("${OPENCLAW_BIN}" "${openclaw_args[@]}" 2>&1)"
EXIT_CODE=$?
set -e

LAST_JSON_LINE="$(
  printf '%s\n' "${RAW_OUTPUT}" | awk '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^\{.*\}$/) last=line
    }
    END {
      if (last != "") print last
    }'
)"

WORKER_RESULT_JSON="null"
if [ -n "${LAST_JSON_LINE}" ] && printf '%s' "${LAST_JSON_LINE}" | jq -e . >/dev/null 2>&1; then
  WORKER_RESULT_JSON="${LAST_JSON_LINE}"
fi

if [ "${EXIT_CODE}" -eq 0 ]; then
  STATUS="success"
else
  STATUS="failed"
fi

jq -nc \
  --arg status "${STATUS}" \
  --arg target_agent "${TARGET_AGENT}" \
  --arg child_session_key "${TARGET_SESSION_KEY}" \
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
