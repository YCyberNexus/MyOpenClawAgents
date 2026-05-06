#!/usr/bin/env bash
# run_prepared_worker.sh — execute a dispatcher-prepared issue handoff.
# This script intentionally does not clone, fetch, prepare worktrees, copy
# .claude, create directories, or build prompts. Those are dispatcher duties.

set -euo pipefail

HANDOFF_FILE="${HANDOFF_FILE:-${1:-}}"
if [ -z "${HANDOFF_FILE}" ]; then
  echo "run_prepared_worker: HANDOFF_FILE env or first argument is required" >&2
  exit 2
fi
if [ ! -f "${HANDOFF_FILE}" ]; then
  echo "run_prepared_worker: handoff file not found: ${HANDOFF_FILE}" >&2
  exit 2
fi

PROJECT="${PROJECT:-$(jq -r '.project' "${HANDOFF_FILE}")}"
GROUP="${GROUP:-$(jq -r '.group' "${HANDOFF_FILE}")}"
ISSUE_IID="${ISSUE_IID:-$(jq -r '.iid' "${HANDOFF_FILE}")}"
ATTEMPT_NUMBER="${ATTEMPT_NUMBER:-$(jq -r '.attempt_number' "${HANDOFF_FILE}")}"
BRANCH="${BRANCH:-$(jq -r '.branch' "${HANDOFF_FILE}")}"
DEV_BRANCH="${DEV_BRANCH:-$(jq -r '.dev_branch' "${HANDOFF_FILE}")}"
HULAT_DIR="${HULAT_DIR:-$(jq -r '.hulat_dir' "${HANDOFF_FILE}")}"
ISSUE_TITLE="$(jq -r '.issue_title // ""' "${HANDOFF_FILE}")"
ISSUE_MODE="$(jq -r '.issue_mode_actual // .issue_mode_requested // "fresh"' "${HANDOFF_FILE}")"
PROMPT_FILE="$(jq -r '.prompt_file' "${HANDOFF_FILE}")"
HANDOFF_WORKTREE_DIR="$(jq -r '.worktree_dir' "${HANDOFF_FILE}")"
HANDOFF_LOG_DIR="$(jq -r '.log_dir' "${HANDOFF_FILE}")"
HANDOFF_LOCAL_BRANCH="$(jq -r '.local_branch' "${HANDOFF_FILE}")"
PREPARED_WORKER=1

export PROJECT GROUP ISSUE_IID ATTEMPT_NUMBER BRANCH DEV_BRANCH HULAT_DIR ISSUE_TITLE ISSUE_MODE PREPARED_WORKER

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${SKILL_DIR}"
source scripts/env_paths.sh

: "${GITLAB_TOKEN:?run_prepared_worker: GITLAB_TOKEN must be supplied by the worker payload}"
: "${PROJECT_URI:?}" "${GITLAB_HOST:?}" "${WORKTREE_DIR:?}" "${LOG_DIR:?}" \
  "${ATTEMPT_STATE_FILE:?}" "${ISSUE_STATE_FILE:?}" "${SUMMARY_FILE:?}"

if [ "${WORKTREE_DIR}" != "${HANDOFF_WORKTREE_DIR}" ]; then
  echo "run_prepared_worker: handoff worktree mismatch: ${HANDOFF_WORKTREE_DIR} != ${WORKTREE_DIR}" >&2
  exit 2
fi
if [ "${LOG_DIR}" != "${HANDOFF_LOG_DIR}" ]; then
  echo "run_prepared_worker: handoff log dir mismatch: ${HANDOFF_LOG_DIR} != ${LOG_DIR}" >&2
  exit 2
fi
if [ "${LOCAL_ATTEMPT_BRANCH}" != "${HANDOFF_LOCAL_BRANCH}" ]; then
  echo "run_prepared_worker: handoff local branch mismatch: ${HANDOFF_LOCAL_BRANCH} != ${LOCAL_ATTEMPT_BRANCH}" >&2
  exit 2
fi
if [ ! -d "${WORKTREE_DIR}" ] || [ ! -f "${PROMPT_FILE}" ]; then
  echo "run_prepared_worker: dispatcher-prepared worktree or prompt is missing" >&2
  exit 2
fi

BLOCKED_RETRY_LIMIT="${BLOCKED_RETRY_LIMIT:-${blocked_retry_limit:-}}"
WORKER_VERSION="2026-05-06.2"
export WORKER_VERSION

json_update() {
  local file="$1"
  shift
  local tmp
  tmp="$(mktemp "$(dirname "${file}")/.json.XXXXXX")"
  jq "$@" "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

set_attempt_fields() {
  json_update "${ATTEMPT_STATE_FILE}" "$@"
}

set_issue_fields() {
  json_update "${ISSUE_STATE_FILE}" "$@"
}

post_summary() {
  local status="$1"
  local block_reason="${2:-}"
  local summary_out="${LOG_DIR}/summarize_attempt.out"
  local summary_err="${LOG_DIR}/summarize_attempt.err"
  if ATTEMPT_STATUS="${status}" COMMIT_SHA="${COMMIT_SHA:-}" MERGE_REQUEST_URL="${MERGE_REQUEST_URL:-}" \
      BLOCK_REASON="${block_reason}" bash scripts/summarize_attempt.sh >"${summary_out}" 2>"${summary_err}"; then
    set_attempt_fields '.summary_file = env.SUMMARY_FILE | .summary_posted_to_issue = true'
  else
    set_attempt_fields '.summary_posted_to_issue = false'
  fi
}

finish() {
  local status="$1"
  local block_reason="${2:-}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  set_attempt_fields --arg status "${status}" --arg now "${now}" --arg block_reason "${block_reason}" \
    '.status = $status
     | .attempt_finished_at = $now
     | .block_reason = (if $block_reason == "" then null else $block_reason end)
     | .skill_version = env.WORKER_VERSION'

  set_issue_fields --arg status "${status}" --arg now "${now}" --arg block_reason "${block_reason}" \
    '.status = $status
     | .block_reason = (if $block_reason == "" then null else $block_reason end)
     | .skill_version = env.WORKER_VERSION
     | .updated_at = $now'

  jq -nc \
    --arg skill_version "${WORKER_VERSION}" \
    --argjson iid "${ISSUE_IID}" \
    --arg status "${status}" \
    --arg work_branch "${WORK_BRANCH}" \
    --arg commit_sha "${COMMIT_SHA:-}" \
    --arg merge_request_url "${MERGE_REQUEST_URL:-}" \
    --arg block_reason "${block_reason}" \
    '{
      skill_version: $skill_version,
      iid: $iid,
      status: $status,
      work_branch: $work_branch,
      commit_sha: (if $commit_sha == "" then null else $commit_sha end),
      merge_request_url: (if $merge_request_url == "" then null else $merge_request_url end),
      block_reason: (if $block_reason == "" then null else $block_reason end)
    }'
  exit 0
}

block_with_summary() {
  local reason="$1"
  local status="blocked"
  local next_retry
  next_retry="$(jq -r '(.retry_count // 0) + 1' "${ISSUE_STATE_FILE}")"
  if [ -n "${BLOCKED_RETRY_LIMIT}" ] && [ "${next_retry}" -gt "${BLOCKED_RETRY_LIMIT}" ]; then
    status="failed"
  fi
  set_issue_fields --argjson retry_count "${next_retry}" '.retry_count = $retry_count'
  post_summary "${status}" "${reason}"
  finish "${status}" "${reason}"
}

run_or_block() {
  local reason="$1"
  local out="$2"
  local err="$3"
  shift 3
  if ! "$@" >"${out}" 2>"${err}"; then
    block_with_summary "${reason}: $(tail -n 1 "${err}" 2>/dev/null || true)"
  fi
}

run_or_block "ensure labels failed" "${LOG_DIR}/ensure_labels.out" "${LOG_DIR}/ensure_labels.err" \
  bash scripts/ensure_labels.sh

if [ "${ISSUE_MODE}" = "continue" ]; then
  for label in continue blocked done pr; do
    run_or_block "remove label ${label} failed" "${LOG_DIR}/label-remove-${label}.out" "${LOG_DIR}/label-remove-${label}.err" \
      bash scripts/set_issue_label.sh remove "${label}"
  done
else
  for label in todo blocked done pr; do
    run_or_block "remove label ${label} failed" "${LOG_DIR}/label-remove-${label}.out" "${LOG_DIR}/label-remove-${label}.err" \
      bash scripts/set_issue_label.sh remove "${label}"
  done
fi
run_or_block "add label doing failed" "${LOG_DIR}/label-add-doing.out" "${LOG_DIR}/label-add-doing.err" \
  bash scripts/set_issue_label.sh add doing

set_attempt_fields '.worker_started_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))'

cd "${WORKTREE_DIR}"
if ! acpx --auth-policy skip claude exec -f "${PROMPT_FILE}" \
    1>"${LOG_DIR}/claude_result.txt" \
    2>"${LOG_DIR}/acpx_raw.log"; then
  cd "${SKILL_DIR}"
  block_with_summary "Claude Code execution failed: $(tail -n 1 "${LOG_DIR}/acpx_raw.log" 2>/dev/null || true)"
fi
cd "${SKILL_DIR}"

STAGE_OUT="${LOG_DIR}/stage_and_guard.out"
STAGE_ERR="${LOG_DIR}/stage_and_guard.err"
if ! bash scripts/stage_and_guard.sh >"${STAGE_OUT}" 2>"${STAGE_ERR}"; then
  block_with_summary "agent artifacts leaked into worktree"
fi
STAGE_MARKER="$(tail -n 1 "${STAGE_OUT}")"
case "${STAGE_MARKER}" in
  NO_CHANGES)
    post_summary "no_changes" ""
    finish "no_changes" ""
    ;;
  STAGED_OK) ;;
  *)
    block_with_summary "unexpected stage_and_guard output: ${STAGE_MARKER}"
    ;;
esac

COMMIT_OUT="${LOG_DIR}/commit_and_push.out"
COMMIT_ERR="${LOG_DIR}/commit_and_push.err"
if ! ISSUE_TITLE="${ISSUE_TITLE}" bash scripts/commit_and_push.sh >"${COMMIT_OUT}" 2>"${COMMIT_ERR}"; then
  block_with_summary "git commit/push failed: $(tail -n 1 "${COMMIT_ERR}" 2>/dev/null || true)"
fi
COMMIT_SHA="$(tail -n 1 "${COMMIT_OUT}")"
export COMMIT_SHA
set_attempt_fields --arg commit_sha "${COMMIT_SHA}" '.commit_sha = $commit_sha'
set_issue_fields --arg commit_sha "${COMMIT_SHA}" '.commit_sha = $commit_sha'

run_or_block "post-push verification failed" "${LOG_DIR}/post_push_verify.out" "${LOG_DIR}/post_push_verify.err" \
  bash scripts/post_push_verify.sh

if ! bash scripts/upload_attempt_artifacts.sh >"${LOG_DIR}/upload_attempt_artifacts.out" 2>"${LOG_DIR}/upload_attempt_artifacts.err"; then
  block_with_summary "attempt wiki artifact publication failed: $(tail -n 1 "${LOG_DIR}/upload_attempt_artifacts.err" 2>/dev/null || true)"
fi
set_attempt_fields '.attempt_artifacts_posted_to_wiki = true | .wiki_artifacts_file = (env.LOG_DIR + "/wiki_artifacts.md")'

run_or_block "remove label doing failed" "${LOG_DIR}/label-remove-doing.out" "${LOG_DIR}/label-remove-doing.err" \
  bash scripts/set_issue_label.sh remove doing
run_or_block "add label done failed" "${LOG_DIR}/label-add-done.out" "${LOG_DIR}/label-add-done.err" \
  bash scripts/set_issue_label.sh add done

MR_OUT="${LOG_DIR}/create_mr.out"
MR_ERR="${LOG_DIR}/create_mr.err"
if ! ISSUE_TITLE="${ISSUE_TITLE}" bash scripts/create_mr.sh >"${MR_OUT}" 2>"${MR_ERR}"; then
  block_with_summary "merge request creation failed: $(tail -n 1 "${MR_ERR}" 2>/dev/null || true)"
fi
MERGE_REQUEST_URL="$(tail -n 1 "${MR_OUT}")"
export MERGE_REQUEST_URL
set_attempt_fields --arg merge_request_url "${MERGE_REQUEST_URL}" '.merge_request_url = $merge_request_url'
set_issue_fields --arg merge_request_url "${MERGE_REQUEST_URL}" '.merge_request_url = $merge_request_url'

run_or_block "add label pr failed" "${LOG_DIR}/label-add-pr.out" "${LOG_DIR}/label-add-pr.err" \
  bash scripts/set_issue_label.sh add pr

post_summary "done" ""
finish "done" ""
