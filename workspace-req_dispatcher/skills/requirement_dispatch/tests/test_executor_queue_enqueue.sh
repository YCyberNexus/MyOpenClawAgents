#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-enqueue.XXXXXX")"
STATE_ROOT="${TEST_ROOT}/state"

origin='{"channel":"wecom","user":"u1","conversation":"c1","reply_agent":"reply_agent"}'

first="$(
  STATE_ROOT="${STATE_ROOT}" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="12" \
  ISSUE_URL="http://gitlab/issues/12" \
  EXECUTOR_AGENT="req_executor" \
  TARGET_BRANCH="release/2026.07" \
  ORIGIN_JSON="${origin}" \
  REQ_DIGEST="first issue" \
  bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh"
)"

second="$(
  STATE_ROOT="${STATE_ROOT}" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="13" \
  ISSUE_URL="http://gitlab/issues/13" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${origin}" \
  REQ_DIGEST="second issue" \
  bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh"
)"

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"

if [ "$(jq -r '.status' <<<"${first}")" != "queued" ]; then
  echo "expected first enqueue status queued" >&2
  printf '%s\n' "${first}" >&2
  exit 1
fi

if [ "$(jq -r '.queue_id' <<<"${first}")" != "execq-1" ]; then
  echo "expected first queue_id execq-1" >&2
  printf '%s\n' "${first}" >&2
  exit 1
fi

if [ "$(jq -r '.queue_id' <<<"${second}")" != "execq-2" ]; then
  echo "expected second queue_id execq-2" >&2
  printf '%s\n' "${second}" >&2
  exit 1
fi

if [ "$(jq -r '.active == null' "${queue_file}")" != "true" ]; then
  echo "expected no active item after enqueue only" >&2
  cat "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue | length' "${queue_file}")" != "2" ]; then
  echo "expected two queued entries" >&2
  cat "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue[0].iid' "${queue_file}")" != "12" ] ||
   [ "$(jq -r '.queue[1].iid' "${queue_file}")" != "13" ]; then
  echo "expected FIFO order #12 then #13" >&2
  cat "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue[0].origin.reply_agent' "${queue_file}")" != "reply_agent" ]; then
  echo "expected origin to be preserved" >&2
  cat "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue[0].target_branch' "${queue_file}")" != "release/2026.07" ]; then
  echo "expected target_branch to be preserved on the queued item" >&2
  cat "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue[1].target_branch' "${queue_file}")" != "null" ]; then
  echo "expected missing target_branch to stay null" >&2
  cat "${queue_file}" >&2
  exit 1
fi

echo "ok executor queue enqueue"
