#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-batch-state.XXXXXX")"
STATE_ROOT_PATH="${TEST_ROOT}/state"
BATCH_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batches.json"
ORIGIN='{"channel":"wecom","user":"batch-user","conversation":"batch-conversation","reply_agent":"reply-agent"}'

record_batch() {
  STATE_ROOT="${STATE_ROOT_PATH}" \
  BATCH_ID="batch-250" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${ORIGIN}" \
  MATCHED_COUNT="250" \
  REQUEST_DIGEST="$1" \
  GITLAB_TOKEN="must-not-be-read-or-persisted" \
    "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh"
}

first_output="$(record_batch "digest-a")"
if ! jq -e '
  type == "object"
  and (keys | sort) == ["batch_id","status"]
  and .status == "accepted"
  and .batch_id == "batch-250"
' <<<"${first_output}" >/dev/null; then
  echo "expected first batch record to return an accepted result" >&2
  printf '%s\n' "${first_output}" >&2
  exit 1
fi

if ! jq -e '
  type == "object"
  and (.batches | type == "object")
  and (.batches | keys) == ["batch-250"]
  and (.batches["batch-250"] | keys | sort) == [
    "batch_id","created_at","executor_agent","matched_count","origin",
    "request_digest","status","terminal_count","updated_at"
  ]
  and .batches["batch-250"].batch_id == "batch-250"
  and .batches["batch-250"].executor_agent == "req_executor"
  and .batches["batch-250"].origin == {
    channel:"wecom",
    user:"batch-user",
    conversation:"batch-conversation",
    reply_agent:"reply-agent"
  }
  and .batches["batch-250"].matched_count == 250
  and .batches["batch-250"].terminal_count == 0
  and .batches["batch-250"].status == "queued"
  and .batches["batch-250"].request_digest == "digest-a"
  and (.batches["batch-250"].created_at | type == "string" and length > 0)
  and (.batches["batch-250"].updated_at | type == "string" and length > 0)
' "${BATCH_FILE}" >/dev/null; then
  echo "expected a compact batch mirror with matched_count=250" >&2
  sed -n '1,80p' "${BATCH_FILE}" >&2
  exit 1
fi

if jq -e '.. | objects | select(has("snapshot") or has("iids") or has("iid"))' \
  "${BATCH_FILE}" >/dev/null; then
  echo "batch mirror must not persist an IID list or snapshot" >&2
  sed -n '1,80p' "${BATCH_FILE}" >&2
  exit 1
fi

if grep -q -- 'must-not-be-read-or-persisted\|GITLAB_TOKEN\|gitlab_token' "${BATCH_FILE}"; then
  echo "batch mirror must not persist a GitLab token" >&2
  sed -n '1,80p' "${BATCH_FILE}" >&2
  exit 1
fi

before_duplicate="$(jq -cS . "${BATCH_FILE}")"
duplicate_output="$(record_batch "digest-a")"
after_duplicate="$(jq -cS . "${BATCH_FILE}")"

if ! jq -e '
  type == "object"
  and (keys | sort) == ["batch_id","status"]
  and .status == "duplicate"
  and .batch_id == "batch-250"
' <<<"${duplicate_output}" >/dev/null; then
  echo "expected same batch ID and request digest to be idempotent" >&2
  printf '%s\n' "${duplicate_output}" >&2
  exit 1
fi

if [ "${before_duplicate}" != "${after_duplicate}" ]; then
  echo "idempotent batch replay unexpectedly changed the mirror" >&2
  exit 1
fi

set +e
record_batch "digest-conflict" >"${TEST_ROOT}/conflict.out" 2>"${TEST_ROOT}/conflict.err"
conflict_rc=$?
set -e

if [ "${conflict_rc}" -eq 0 ]; then
  echo "expected a reused batch ID with a different digest to fail closed" >&2
  exit 1
fi

if [ "$(jq -cS . "${BATCH_FILE}")" != "${before_duplicate}" ]; then
  echo "digest conflict unexpectedly overwrote the existing batch mirror" >&2
  exit 1
fi

set +e
STATE_ROOT="${STATE_ROOT_PATH}" \
BATCH_ID="batch-token-origin" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON='{"channel":"wecom","gitlab_token":"must-not-persist-from-origin"}' \
MATCHED_COUNT="1" \
REQUEST_DIGEST="digest-token-origin" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" \
  >"${TEST_ROOT}/token-origin.out" 2>"${TEST_ROOT}/token-origin.err"
token_origin_rc=$?
set -e

if [ "${token_origin_rc}" -eq 0 ]; then
  echo "expected origin metadata outside the capture_origin contract to be rejected" >&2
  exit 1
fi
if grep -q -- 'must-not-persist-from-origin\|gitlab_token' "${BATCH_FILE}"; then
  echo "batch mirror persisted token-shaped origin data" >&2
  sed -n '1,100p' "${BATCH_FILE}" >&2
  exit 1
fi

jq -c 'del(.batches["batch-250"].matched_count)' "${BATCH_FILE}" \
  >"${TEST_ROOT}/corrupt-mirror.json"
mv "${TEST_ROOT}/corrupt-mirror.json" "${BATCH_FILE}"
corrupt_before="$(jq -cS . "${BATCH_FILE}")"
set +e
record_batch "digest-a" >"${TEST_ROOT}/corrupt-replay.out" \
  2>"${TEST_ROOT}/corrupt-replay.err"
corrupt_replay_rc=$?
set -e
if [ "${corrupt_replay_rc}" -eq 0 ]; then
  echo "expected malformed existing mirror entry to fail before duplicate ack" >&2
  exit 1
fi
if [ "$(jq -cS . "${BATCH_FILE}")" != "${corrupt_before}" ]; then
  echo "malformed mirror replay unexpectedly changed state" >&2
  exit 1
fi

echo "ok executor batch mirror is compact and digest-idempotent"
