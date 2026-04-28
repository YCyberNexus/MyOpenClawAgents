#!/usr/bin/env bash
# create_mr.sh — ensure exactly ONE merge request exists for ${WORK_BRANCH}
# (Strategy A). On the first attempt the script creates the MR; on
# subsequent attempts it just looks up the existing one. The MR's
# commits update automatically because of the force-push in
# commit_and_push.sh.
#
# Required env vars:
#   PROJECT_FULL    "${GROUP}/${PROJECT}"
#   ISSUE_IID       from env_paths.sh
#   ISSUE_TITLE     short human title for the MR title
#   LOG_DIR         where mr_description.md lives (under ATTEMPT_DIR)
#   BRANCH          target branch (typically "master")
#   WORK_BRANCH     source branch (single, fixed)
#
# Output:
#   Prints the MR web URL to stdout. The executor writes this to the
#   per-issue state file.

set -euo pipefail

: "${PROJECT_FULL:?}" "${ISSUE_IID:?}" "${ISSUE_TITLE:?}" \
  "${LOG_DIR:?}" "${BRANCH:?}" "${WORK_BRANCH:?}"

# 1. If an open MR already exists for this source branch, reuse it.
EXISTING_URL="$(
  glab mr list \
    --repo "${PROJECT_FULL}" \
    --source-branch "${WORK_BRANCH}" \
    --state opened \
    --output json 2>/dev/null \
  | jq -r 'if length > 0 then .[0].web_url else "" end' \
)"

if [ -n "${EXISTING_URL}" ]; then
  echo "${EXISTING_URL}"
  exit 0
fi

# 2. Otherwise create a new one. Description starts with `Closes #<iid>`
#    so GitLab auto-closes the issue on merge.
DESC_FILE="${LOG_DIR}/mr_description.md"
if [ ! -f "${DESC_FILE}" ]; then
  cat > "${DESC_FILE}" <<EOF
Closes #${ISSUE_IID}

Auto-generated MR for issue #${ISSUE_IID}.

Execution evidence (logs, prompts, raw acpx output) is preserved on the
runner under: ${LOG_DIR}

Per-attempt summaries are posted as comments on the linked issue.

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
