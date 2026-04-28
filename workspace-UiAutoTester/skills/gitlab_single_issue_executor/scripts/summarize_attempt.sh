#!/usr/bin/env bash
# summarize_attempt.sh — write ${SUMMARY_FILE} with a structured digest of
# this attempt, then post the same content as a GitLab issue comment so
# the next continue-mode run (and any reviewer) can see what previous
# attempts did.
#
# Required env vars:
#   GITLAB_HOST              from glab_auth.sh
#   PROJECT_URI              URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   ISSUE_MODE               "fresh" or "continue" (the mode actually used)
#   ATTEMPT_DIR              per-attempt dir
#   LOG_DIR                  per-attempt log dir
#   SUMMARY_FILE             ${ATTEMPT_DIR}/summary.md
#
# Optional env vars (any may be unset / empty if not yet known):
#   ATTEMPT_STATUS           terminal status of this attempt
#                            ("done" | "no_changes" | "blocked" | "failed")
#   COMMIT_SHA               last commit on the work branch (if pushed)
#   MERGE_REQUEST_URL        MR URL (if known)
#   BLOCK_REASON             when ATTEMPT_STATUS=blocked|failed
#
# The posted comment is wrapped with a recognizable marker so future
# build_prompt.sh runs can distinguish agent-posted summaries from
# reviewer-written guidance:
#
#   <!-- uiautotester:attempt-summary v1 attempt=NNN -->
#   ...summary body...
#   <!-- /uiautotester:attempt-summary -->

set -euo pipefail

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" "${ISSUE_MODE:?}" \
  "${ATTEMPT_DIR:?}" "${LOG_DIR:?}" "${SUMMARY_FILE:?}"

ATTEMPT_STATUS="${ATTEMPT_STATUS:-unknown}"
COMMIT_SHA="${COMMIT_SHA:-}"
MERGE_REQUEST_URL="${MERGE_REQUEST_URL:-}"
BLOCK_REASON="${BLOCK_REASON:-}"

# Pull a tail of claude_result.txt and a head of git_diff.patch as
# evidence. Cap aggressively — issue comments shouldn't be massive.
RESULT_TAIL=""
if [ -s "${LOG_DIR}/claude_result.txt" ]; then
  RESULT_TAIL="$(tail -c 2000 "${LOG_DIR}/claude_result.txt")"
fi

DIFF_HEAD=""
if [ -s "${LOG_DIR}/git_diff.patch" ]; then
  DIFF_HEAD="$(head -c 2000 "${LOG_DIR}/git_diff.patch")"
fi

CHANGED_FILES=""
if [ -s "${LOG_DIR}/git_status.txt" ]; then
  CHANGED_FILES="$(awk '{print $2}' "${LOG_DIR}/git_status.txt" | head -n 50)"
fi

# Build summary.md.
{
  echo "<!-- uiautotester:attempt-summary v1 attempt=${ATTEMPT_NUMBER_PADDED} -->"
  echo "## UiAutoTester attempt ${ATTEMPT_NUMBER_PADDED} summary"
  echo
  echo "- Mode: ${ISSUE_MODE}"
  echo "- Status: ${ATTEMPT_STATUS}"
  if [ -n "${COMMIT_SHA}" ]; then
    echo "- Commit: \`${COMMIT_SHA}\`"
  fi
  if [ -n "${MERGE_REQUEST_URL}" ]; then
    echo "- Merge request: ${MERGE_REQUEST_URL}"
  fi
  if [ -n "${BLOCK_REASON}" ]; then
    echo "- Block reason: ${BLOCK_REASON}"
  fi
  echo "- Attempt artifacts (on runner): \`${ATTEMPT_DIR}\`"
  echo

  if [ -n "${CHANGED_FILES}" ]; then
    echo "### Changed files (up to 50)"
    echo
    echo '```'
    printf '%s\n' "${CHANGED_FILES}"
    echo '```'
    echo
  fi

  if [ -n "${RESULT_TAIL}" ]; then
    echo "### Last 2000 bytes of claude_result.txt"
    echo
    echo '```'
    printf '%s\n' "${RESULT_TAIL}"
    echo '```'
    echo
  fi

  if [ -n "${DIFF_HEAD}" ]; then
    echo "### First 2000 bytes of git_diff.patch"
    echo
    echo '```diff'
    printf '%s\n' "${DIFF_HEAD}"
    echo '```'
    echo
  fi

  echo "<!-- /uiautotester:attempt-summary -->"
} > "${SUMMARY_FILE}"

# Post as a comment on the issue.
glab api --hostname "${GITLAB_HOST}" --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}" >/dev/null

echo "${SUMMARY_FILE}"
