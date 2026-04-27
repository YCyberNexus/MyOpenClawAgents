#!/usr/bin/env bash
# create_mr.sh — create the merge request for this issue's work branch.
# The executor MUST NOT call `glab mr merge` afterwards; the MR stays open.
#
# Required env vars:
#   PROJECT_FULL    "${GROUP}/${PROJECT}"
#   ISSUE_IID       from env_paths.sh
#   ISSUE_TITLE     short human title for the MR title
#   LOG_DIR         where mr_description.md lives (under WORK_ROOT)
#   BRANCH          target branch (typically "master")
#   WORK_BRANCH     source branch (set by env_paths.sh)
#
# Output:
#   Prints the MR web URL to stdout. The executor writes this to
#   ${ISSUE_STATE_FILE}.merge_request_url.

set -euo pipefail

: "${PROJECT_FULL:?}" "${ISSUE_IID:?}" "${ISSUE_TITLE:?}" \
  "${LOG_DIR:?}" "${BRANCH:?}" "${WORK_BRANCH:?}"

DESC_FILE="${LOG_DIR}/mr_description.md"
if [ ! -f "${DESC_FILE}" ]; then
  cat > "${DESC_FILE}" <<EOF
Auto-generated MR for issue #${ISSUE_IID}.

Execution evidence (logs, prompts, raw acpx output) is preserved on the
runner under: ${LOG_DIR}

Do not merge until reviewed.
EOF
fi

glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${BRANCH}" \
  --title "Issue #${ISSUE_IID}: ${ISSUE_TITLE}" \
  --description-file "${DESC_FILE}" \
  --yes >/dev/null

glab mr view "${WORK_BRANCH}" --repo "${PROJECT_FULL}" --output json \
  | jq -r '.web_url'
