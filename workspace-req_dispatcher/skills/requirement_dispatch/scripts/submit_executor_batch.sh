#!/usr/bin/env bash
# Fixed intake wrapper: parse/validate selector, route, build I1, persist, then drain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

PREPARED_REQUEST_JSON="${PREPARED_REQUEST_JSON:-}"
MESSAGE="${MESSAGE:-}"
MESSAGE_FILE="${MESSAGE_FILE:-}"

if [ -z "${PREPARED_REQUEST_JSON}" ]; then
  if [ -z "${MESSAGE}" ] && [ -z "${MESSAGE_FILE}" ] && [ ! -t 0 ]; then
    MESSAGE="$(cat)"
  fi
  PREPARED_REQUEST_JSON="$(
    MESSAGE="${MESSAGE}" MESSAGE_FILE="${MESSAGE_FILE}" \
      "${BASH}" "${SCRIPT_DIR}/prepare_executor_issue_payload.sh"
  )"
fi

if ! PREPARED_REQUEST_JSON="$(jq -ce . <<<"${PREPARED_REQUEST_JSON}" 2>/dev/null)"; then
  executor_batch_outbox_die "PREPARED_REQUEST_JSON must be valid JSON"
fi
if [ "$(jq -r '.status // ""' <<<"${PREPARED_REQUEST_JSON}")" != success ]; then
  printf '%s\n' "${PREPARED_REQUEST_JSON}"
  exit 0
fi
if ! PREPARED_REQUEST_JSON="$(jq -ce '
  def nullable_string: . == null or type == "string";
  def valid_selector:
    type == "object" and (
      (.type == "single" and (keys | sort) == ["iid","type"]
        and (.iid | type == "number" and . == floor and . > 0))
      or (.type == "iid_list" and (keys | sort) == ["iids","type"]
        and (.iids | type == "array" and length >= 2)
        and (.iids | all(type == "number" and . == floor and . > 0))
        and (.iids == (.iids | sort | unique)))
      or (.type == "range" and (keys | sort) == ["iid_max","iid_min","type"]
        and (.iid_min | type == "number" and . == floor and . > 0)
        and (.iid_max | type == "number" and . == floor and . > 0)
        and (.iid_max >= .iid_min))
      or (.type == "open_unfinished" and keys == ["type"])
      or (.type == "open_label" and (keys | sort) == ["label","type"]
        and (.label | type == "string" and length > 0))
    );
  if type == "object" then
    (if has("auto_merge") then . else .auto_merge = false end
    | if has("merge_target_branch") then . else .merge_target_branch = null end)
  else . end
  |
  if type == "object"
    and (keys | sort) == [
      "auto_merge","force_rerun_pr","iid","issue_url","merge_target_branch",
      "project","reason","request_text","selector","status","target_branch"
    ]
    and .status == "success"
    and (.project | type == "string"
      and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    and (.selector | valid_selector)
    and (.force_rerun_pr | type == "boolean")
    and (.auto_merge | type == "boolean")
    and (.target_branch | nullable_string)
    and (.merge_target_branch | nullable_string)
    and (.issue_url | nullable_string)
    and (.request_text | nullable_string)
    and .reason == null
    and (if .selector.type == "single"
      then .iid == .selector.iid else .iid == null end)
  then .
  else error("invalid prepared selector")
  end
' <<<"${PREPARED_REQUEST_JSON}" 2>/dev/null)"; then
  executor_batch_outbox_die "PREPARED_REQUEST_JSON is not the exact prepare_executor_issue_payload result"
fi

PROJECT="$(jq -r '.project' <<<"${PREPARED_REQUEST_JSON}")"
SELECTOR_JSON="$(jq -cS '.selector' <<<"${PREPARED_REQUEST_JSON}")"
FORCE_RERUN_PR="$(jq -r '.force_rerun_pr' <<<"${PREPARED_REQUEST_JSON}")"
AUTO_MERGE="$(jq -r '.auto_merge' <<<"${PREPARED_REQUEST_JSON}")"
TARGET_BRANCH="$(jq -r '.target_branch // ""' <<<"${PREPARED_REQUEST_JSON}")"
MERGE_TARGET_BRANCH="$(jq -r '.merge_target_branch // ""' <<<"${PREPARED_REQUEST_JSON}")"

if [ "${ORIGIN_JSON+x}" != x ]; then
  origin_message="${MESSAGE}"
  if [ -z "${origin_message}" ]; then
    origin_message="$(jq -r '.request_text // ""' <<<"${PREPARED_REQUEST_JSON}")"
  fi
  ORIGIN_JSON="$(MESSAGE="${origin_message}" "${BASH}" "${SCRIPT_DIR}/capture_origin.sh")"
fi
ORIGIN_JSON="${ORIGIN_JSON:-null}"

EXECUTOR_AGENT="$(
  PROJECT="${PROJECT}" \
  ROUTING_FILE="${ROUTING_FILE:-}" \
  DEFAULT_EXECUTOR_AGENT="${DEFAULT_EXECUTOR_AGENT:-}" \
    "${BASH}" "${SCRIPT_DIR}/route_project.sh"
)"
if [ "${EXECUTOR_AGENT}" = __NO_ROUTE__ ]; then
  jq -cn --arg project "${PROJECT}" \
    '{status:"failed",reason:"no_route",project:$project}'
  exit 0
fi

[ -n "${DISPATCHER_CALLBACK_TARGET:-}" ] \
  || executor_batch_outbox_die "DISPATCHER_CALLBACK_TARGET must not be empty"

unset CALLBACK_NONCE
CALLBACK_NONCE="$(generate_executor_callback_nonce)"
CORRELATION_ID="$(STATE_ROOT="${STATE_ROOT}" "${BASH}" "${SCRIPT_DIR}/next_correlation_id.sh")"
BATCH_ID="reqd-batch-${CORRELATION_ID#reqd-}"
PAYLOAD="$(
  BATCH_ID="${BATCH_ID}" \
  CORRELATION_ID="${CORRELATION_ID}" \
  PROJECT="${PROJECT}" \
  SELECTOR_JSON="${SELECTOR_JSON}" \
  FORCE_RERUN_PR="${FORCE_RERUN_PR}" \
  AUTO_MERGE="${AUTO_MERGE}" \
  EXECUTOR_AGENT="${EXECUTOR_AGENT}" \
  CALLBACK_NONCE="${CALLBACK_NONCE}" \
  DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}" \
  TARGET_BRANCH="${TARGET_BRANCH}" \
  MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
    "${BASH}" "${SCRIPT_DIR}/build_executor_batch_payload.sh"
)"
REQUEST_DIGEST="$(printf '%s' "${PAYLOAD}" | executor_batch_sha256)"

enqueue_result="$(
  STATE_ROOT="${STATE_ROOT}" \
  BATCH_ID="${BATCH_ID}" \
  CORRELATION_ID="${CORRELATION_ID}" \
  PROJECT="${PROJECT}" \
  SELECTOR_JSON="${SELECTOR_JSON}" \
  FORCE_RERUN_PR="${FORCE_RERUN_PR}" \
  AUTO_MERGE="${AUTO_MERGE}" \
  TARGET_BRANCH="${TARGET_BRANCH}" \
  MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
  EXECUTOR_AGENT="${EXECUTOR_AGENT}" \
  CALLBACK_NONCE="${CALLBACK_NONCE}" \
  ORIGIN_JSON="${ORIGIN_JSON}" \
  PAYLOAD="${PAYLOAD}" \
  REQUEST_DIGEST="${REQUEST_DIGEST}" \
    "${BASH}" "${SCRIPT_DIR}/enqueue_executor_batch_request.sh"
)"
enqueue_status="$(jq -r '.status' <<<"${enqueue_result}")"
if [ "${enqueue_status}" = waiting_for_legacy_drain ]; then
  printf '%s\n' "${enqueue_result}"
  exit 0
fi

BATCH_ID="${BATCH_ID}" \
  "${BASH}" "${SCRIPT_DIR}/drain_executor_batch_outbox.sh"
