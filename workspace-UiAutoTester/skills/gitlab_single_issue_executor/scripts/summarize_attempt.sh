#!/usr/bin/env bash
# summarize_attempt.sh — write a SHORT digest of this attempt to
# ${SUMMARY_FILE} and post the same content as a GitLab issue comment.
#
# Design choice (2026-04-25.5+): the comment is intentionally short.
# Detailed evidence (full claude_result.txt, full git_diff.patch,
# acpx_raw.log, prompt.txt) lives on the runner under ${LOG_DIR} and is
# referenced from the comment by absolute path. Reviewers grab the full
# files from there if they need depth; the comment itself stays scannable.
#
# Required env vars:
#   GITLAB_HOST              from glab_auth.sh
#   PROJECT_URI              URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   ISSUE_MODE               "fresh" or "continue"
#   ATTEMPT_DIR              per-attempt dir
#   LOG_DIR                  per-attempt log dir
#   SUMMARY_FILE             ${ATTEMPT_DIR}/summary.md
#
# Optional env vars:
#   ATTEMPT_STATUS           "done" | "no_changes" | "blocked" | "failed"
#   COMMIT_SHA               last commit on the work branch (if pushed)
#   MERGE_REQUEST_URL        MR URL (if known)
#   BLOCK_REASON             when ATTEMPT_STATUS=blocked|failed
#
# The posted comment is wrapped with a recognizable marker so future
# build_prompt.sh runs distinguish agent-posted summaries from reviewer
# comments:
#
#   <!-- uiautotester:attempt-summary v2 attempt=NNN -->
#   ...short summary...
#   <!-- /uiautotester:attempt-summary -->

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" "${ISSUE_MODE:?}" \
  "${ATTEMPT_DIR:?}" "${LOG_DIR:?}" "${SUMMARY_FILE:?}"

ATTEMPT_STATUS="${ATTEMPT_STATUS:-unknown}"
COMMIT_SHA="${COMMIT_SHA:-}"
MERGE_REQUEST_URL="${MERGE_REQUEST_URL:-}"
BLOCK_REASON="${BLOCK_REASON:-}"

# Count changed files without embedding them; cap displayed list at 10 so
# the comment stays compact. The full list is in ${LOG_DIR}/git_status.txt.
CHANGED_COUNT=0
CHANGED_PREVIEW=""
if [ -s "${LOG_DIR}/git_status.txt" ]; then
  CHANGED_COUNT="$(wc -l < "${LOG_DIR}/git_status.txt" | tr -d ' ')"
  CHANGED_PREVIEW="$(awk '{print $2}' "${LOG_DIR}/git_status.txt" | head -n 10)"
fi

{
  echo "<!-- uiautotester:attempt-summary v2 attempt=${ATTEMPT_NUMBER_PADDED} -->"
  echo "## UiAutoTester attempt ${ATTEMPT_NUMBER_PADDED}"
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
  echo "- **Evidence (on runner)**: \`${LOG_DIR}\`"

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

  echo
  echo "<!-- /uiautotester:attempt-summary -->"
} > "${SUMMARY_FILE}"

glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}" >/dev/null

echo "${SUMMARY_FILE}"
