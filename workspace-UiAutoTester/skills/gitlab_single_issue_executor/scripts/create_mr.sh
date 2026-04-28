#!/usr/bin/env bash
# create_mr.sh — ensure exactly ONE merge request exists for ${WORK_BRANCH}
# at the end of this attempt.
#
# Behavior depends on ISSUE_MODE:
#
#   fresh    — if an open MR already exists for ${WORK_BRANCH}, reuse it
#              (its commits update automatically because of the force-push
#              in commit_and_push.sh). If none exists, create one.
#              This matches the original Strategy A.
#
#   continue — close any existing open MR for ${WORK_BRANCH} (without
#              merging), then create a fresh MR. Each continue cycle
#              therefore produces a new MR object in GitLab so reviewers
#              can see the history of resolution attempts. The new MR's
#              description references the closed predecessor for
#              traceability.
#
# Required env vars:
#   PROJECT_FULL    "${GROUP}/${PROJECT}"
#   ISSUE_IID       from env_paths.sh
#   ISSUE_MODE      "fresh" or "continue" (set by Step 3 of executor algo)
#   ISSUE_TITLE     short human title for the MR title
#   LOG_DIR         where mr_description.md lives (under ATTEMPT_DIR)
#   BRANCH          target branch (typically "master")
#   WORK_BRANCH     source branch (single, fixed)
#   ATTEMPT_NUMBER_PADDED  e.g. "002" (used in MR title for visibility)
#
# Output:
#   Prints the resulting MR web URL to stdout. The executor writes this to
#   the per-issue and per-attempt state files.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${PROJECT_FULL:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${ISSUE_TITLE:?}" \
  "${LOG_DIR:?}" "${BRANCH:?}" "${WORK_BRANCH:?}" "${ATTEMPT_NUMBER_PADDED:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "create_mr: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

# Look up any open MR currently pointing at this branch.
EXISTING_JSON="$(
  glab mr list \
    --repo "${PROJECT_FULL}" \
    --source-branch "${WORK_BRANCH}" \
    --state opened \
    --output json 2>/dev/null \
  || echo '[]'
)"
EXISTING_URL="$(echo "${EXISTING_JSON}" | jq -r 'if length > 0 then .[0].web_url else "" end')"
EXISTING_IID="$(echo "${EXISTING_JSON}" | jq -r 'if length > 0 then (.[0].iid|tostring) else "" end')"

if [ "${ISSUE_MODE}" = "fresh" ] && [ -n "${EXISTING_URL}" ]; then
  # Strategy A reuse for fresh mode.
  echo "${EXISTING_URL}"
  exit 0
fi

# For continue mode, close the existing MR (if any) before creating the
# new one. Closing — not merging — preserves the history without changing
# the integration branch.
SUPERSEDES_LINE=""
if [ "${ISSUE_MODE}" = "continue" ] && [ -n "${EXISTING_IID}" ]; then
  glab mr close "${EXISTING_IID}" \
    --repo "${PROJECT_FULL}" >/dev/null
  SUPERSEDES_LINE="Supersedes !${EXISTING_IID} (closed by UiAutoTester continue-mode re-run)."
fi

# Build / refresh the MR description. `Closes #<iid>` triggers GitLab's
# native auto-close when this MR is eventually merged.
DESC_FILE="${LOG_DIR}/mr_description.md"
{
  echo "Closes #${ISSUE_IID}"
  echo
  if [ -n "${SUPERSEDES_LINE}" ]; then
    echo "${SUPERSEDES_LINE}"
    echo
  fi
  echo "Auto-generated MR for issue #${ISSUE_IID} (attempt ${ATTEMPT_NUMBER_PADDED}, mode=${ISSUE_MODE})."
  echo
  echo "Execution evidence (logs, prompts, raw acpx output) is preserved on the"
  echo "runner under: ${LOG_DIR}"
  echo
  echo "Per-attempt summaries are posted as comments on the linked issue."
  echo
  echo "Do not merge until reviewed."
} > "${DESC_FILE}"

glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${BRANCH}" \
  --title "Issue #${ISSUE_IID} (attempt ${ATTEMPT_NUMBER_PADDED}): ${ISSUE_TITLE}" \
  --description-file "${DESC_FILE}" \
  --yes >/dev/null

glab mr view "${WORK_BRANCH}" --repo "${PROJECT_FULL}" --output json \
  | jq -r '.web_url'
