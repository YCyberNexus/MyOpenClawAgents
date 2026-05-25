#!/usr/bin/env bash
# summarize_attempt.sh — write a SHORT digest of this attempt to
# ${SUMMARY_FILE} and optionally post the same content as a GitLab issue
# comment.
#
# Design choice: the comment is intentionally short.
# Detailed evidence (full claude_result.txt, full git_diff.patch,
# acpx_raw.log, prompt.txt) lives on the runner under ${LOG_DIR}. On
# push-ready attempts, prompt/result/report evidence is also published to
# the project Wiki before MR creation. The summary itself stays scannable.
#
# Required env vars:
#   GITLAB_HOST              from glab_auth.sh
#   PROJECT_URI              URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   ISSUE_MODE               "fresh" or "continue"
#   ATTEMPT_DIR              issue dir for the current attempt
#   LOG_DIR                  current-attempt log dir
#   SUMMARY_FILE             ${ISSUE_ROOT}/summary.md
#
# Optional env vars:
#   ATTEMPT_STATUS           "done" | "blocked" | "failed" | "timeout" ("no_changes" is legacy)
#   COMMIT_SHA               last commit on the work branch (if pushed)
#   MERGE_REQUEST_URL        MR URL (if known)
#   BLOCK_REASON             when ATTEMPT_STATUS=blocked|failed
#   SUMMARY_POST_TO_ISSUE    true/false; defaults true. Failure paths set false
#                            so evidence stays local under ${LOG_DIR} / ${ISSUE_ROOT}.
#
# When posting is enabled, the comment is wrapped with a recognizable marker
# so future build_prompt.sh runs distinguish agent-posted summaries from
# reviewer comments:
#
#   <!-- acpx_auto_tester_temporal:attempt-summary v2 attempt=NNN -->
#   ...short summary...
#   <!-- /acpx_auto_tester_temporal:attempt-summary -->

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
SUMMARY_POST_TO_ISSUE="${SUMMARY_POST_TO_ISSUE:-true}"

case "${SUMMARY_POST_TO_ISSUE}" in
  true|1|yes|TRUE|YES) SUMMARY_POST_TO_ISSUE=true ;;
  false|0|no|FALSE|NO) SUMMARY_POST_TO_ISSUE=false ;;
  *)
    echo "summarize_attempt: SUMMARY_POST_TO_ISSUE must be true/false, got '${SUMMARY_POST_TO_ISSUE}'" >&2
    exit 2
    ;;
esac

# Count changed files without embedding them; cap displayed list at 10 so
# the comment stays compact. The full list is in ${LOG_DIR}/git_status.txt.
CHANGED_COUNT=0
CHANGED_PREVIEW=""
if [ -s "${LOG_DIR}/git_status.txt" ]; then
  CHANGED_COUNT="$(wc -l < "${LOG_DIR}/git_status.txt" | tr -d ' ')"
  CHANGED_PREVIEW="$(awk '{print $2}' "${LOG_DIR}/git_status.txt" | head -n 10)"
fi

{
  echo "<!-- acpx_auto_tester_temporal:attempt-summary v2 attempt=${ATTEMPT_NUMBER_PADDED} -->"
  echo "## acpx_auto_tester_temporal attempt ${ATTEMPT_NUMBER_PADDED}"
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
  echo "- **Evidence (in-flight, on runner)**: \`${LOG_DIR}\` (lives inside the shared per-issue worktree; removed by housekeeping. \`prompt.txt\` + \`claude_result.txt\` survive in the MR diff)"
  if [ -f "${LOG_DIR}/wiki_artifacts.md" ]; then
    echo "- **Wiki evidence**: published and linked from this issue before MR creation"
  fi

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
  echo "<!-- /acpx_auto_tester_temporal:attempt-summary -->"
} > "${SUMMARY_FILE}"

if [ "${SUMMARY_POST_TO_ISSUE}" = "true" ]; then
  glab api --method POST \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
    -F "body=@${SUMMARY_FILE}" >/dev/null
  echo "SUMMARY_POSTED=true" >&2
else
  echo "SUMMARY_POSTED=false" >&2
fi

echo "${SUMMARY_FILE}"
