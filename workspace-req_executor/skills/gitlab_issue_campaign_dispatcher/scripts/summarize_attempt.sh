#!/usr/bin/env bash
# summarize_attempt.sh — write a SHORT local digest of this attempt to
# ${SUMMARY_FILE}. It never posts the digest to the GitLab issue.
#
# Design choice: the local summary is intentionally short.
# Detailed evidence (full claude_result.txt, full git_diff.patch,
# acpx_raw.log, prompt.txt) lives on the runner under ${LOG_DIR}. The summary
# itself stays scannable.
#
# Required env vars:
#   GITLAB_HOST              from glab_auth.sh
#   PROJECT_URI              URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID                from env_paths.sh
#   EXECUTION_ID            opaque execution identity
#   ISSUE_MODE               "fresh" or "continue"
#   ISSUE_ROOT               persistent issue directory
#   LOG_DIR                  fixed issue-local log dir
#   SUMMARY_FILE             ${ISSUE_ROOT}/summary.md
#
# Optional env vars:
#   ATTEMPT_STATUS           "done" | "blocked" | "failed" | "timeout" ("no_changes" is legacy)
#   COMMIT_SHA               last commit on the work branch (if pushed)
#   MERGE_REQUEST_URL        MR URL (if known)
#   BLOCK_REASON             when ATTEMPT_STATUS=blocked|failed|timeout
#   SUMMARY_POST_TO_ISSUE    deprecated compatibility input; ignored.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${EXECUTION_ID:?}" "${ISSUE_MODE:?}" \
  "${ISSUE_ROOT:?}" "${LOG_DIR:?}" "${SUMMARY_FILE:?}"

ATTEMPT_STATUS="${ATTEMPT_STATUS:-unknown}"
COMMIT_SHA="${COMMIT_SHA:-}"
MERGE_REQUEST_URL="${MERGE_REQUEST_URL:-}"
BLOCK_REASON="${BLOCK_REASON:-}"

# Count changed files without embedding them; cap displayed list at 10 so
# the summary stays compact. The full list is in ${LOG_DIR}/git_status.txt.
CHANGED_COUNT=0
CHANGED_PREVIEW=""
if [ -s "${LOG_DIR}/git_status.txt" ]; then
  CHANGED_COUNT="$(wc -l < "${LOG_DIR}/git_status.txt" | tr -d ' ')"
  CHANGED_PREVIEW="$(awk '{print $2}' "${LOG_DIR}/git_status.txt" | head -n 10)"
fi

{
  echo "## req_executor execution result"
  echo
  echo "- **Mode**: ${ISSUE_MODE}"
  echo "- **Status**: ${ATTEMPT_STATUS}"
  if [ -n "${COMMIT_SHA}" ]; then
    echo "- **Commit**: \`${COMMIT_SHA:0:12}\`"
  fi
  if [ -n "${MERGE_REQUEST_URL}" ]; then
    echo "- **Merge request**: ${MERGE_REQUEST_URL}"
  fi
  if [ -n "${BLOCK_REASON}" ]; then
    echo "- **Block reason**: ${BLOCK_REASON}"
  fi
  echo "- **Changed files**: ${CHANGED_COUNT}"
  echo "- **Evidence**: \`${LOG_DIR}\` (staging-time files enter the MR; the terminal directory is archived on \`req-executor-logs/issue-${ISSUE_IID}/execution-${EXECUTION_ID}\`)"

  if [ -n "${CHANGED_PREVIEW}" ] && [ "${CHANGED_COUNT}" -gt 0 ]; then
    echo
    if [ "${CHANGED_COUNT}" -le 10 ]; then
      echo "<details><summary>Changed files</summary>"
    else
      echo "<details><summary>Changed files (first 10 of ${CHANGED_COUNT})</summary>"
    fi
    echo
    echo '```'
    printf '%s\n' "${CHANGED_PREVIEW}"
    echo '```'
    echo
    echo "</details>"
  fi

} > "${SUMMARY_FILE}"

echo "SUMMARY_POSTED=false" >&2

echo "${SUMMARY_FILE}"
