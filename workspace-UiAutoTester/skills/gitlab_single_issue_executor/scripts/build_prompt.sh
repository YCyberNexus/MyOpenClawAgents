#!/usr/bin/env bash
# build_prompt.sh — generate ${LOG_DIR}/prompt.txt from the live issue
# title/description/labels/notes plus a small instruction header. The
# template is documented in references/continue_mode.md (continue mode)
# and references/paths.md (fresh mode).
#
# Required env vars:
#   GITLAB_HOST          from glab_auth.sh
#   PROJECT_URI          URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID            from env_paths.sh
#   ISSUE_MODE           "fresh" or "continue" (resolved by Step 3 of the
#                        executor algorithm)
#   LOG_DIR              from env_paths.sh
#   REPO_PATH            from env_paths.sh
#   WORK_BRANCH          from env_paths.sh
#   BRANCH               from trigger
#   HULAT_DIR            from trigger (string only — passed through to Claude)
#
# Output:
#   Writes ${LOG_DIR}/prompt.txt and prints its absolute path on stdout.
#   Also reports whether reviewer comments were absent (continue mode only)
#   on stderr as the line:  CONTINUE_MODE_NO_COMMENTS=true|false
#
# This script does NOT call acpx and does NOT execute any of the commands
# the reviewer puts in the comments. It only builds the prompt file.
# Running the user-supplied commands is Claude Code's responsibility,
# inside its acpx-launched process.

set -euo pipefail

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${LOG_DIR:?}" \
  "${REPO_PATH:?}" "${WORK_BRANCH:?}" "${BRANCH:?}" "${HULAT_DIR:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "build_prompt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

mkdir -p "${LOG_DIR}"
PROMPT_FILE="${LOG_DIR}/prompt.txt"

# 1. Fetch the live issue.
ISSUE_JSON="$(glab api --hostname "${GITLAB_HOST}" \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"
ISSUE_TITLE="$(echo "${ISSUE_JSON}" | jq -r '.title // ""')"
ISSUE_DESC="$(echo "${ISSUE_JSON}" | jq -r '.description // ""')"

# 2. In continue mode, fetch non-system notes (comments).
COMMENTS_BLOCK=""
NO_COMMENTS=false
if [ "${ISSUE_MODE}" = "continue" ]; then
  NOTES_JSON="$(glab api --hostname "${GITLAB_HOST}" --paginate \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at")"
  # Concatenate non-system notes in chronological order, separated by ---.
  COMMENTS_BLOCK="$(echo "${NOTES_JSON}" \
    | jq -r '[.[] | select(.system == false) | .body] | if length == 0 then "" else (map(.) | join("\n---\n")) end')"
  if [ -z "${COMMENTS_BLOCK}" ]; then
    NO_COMMENTS=true
    COMMENTS_BLOCK="(no reviewer comments — please review the existing diff and decide whether the work is acceptable as-is)"
  fi
fi

# 3. Build the prompt file.
{
  if [ "${ISSUE_MODE}" = "continue" ]; then
    cat <<EOF
This is a CONTINUE-MODE re-run of GitLab issue #${ISSUE_IID}. A prior run on
this same issue produced a merge request and was marked \`done\`, but a human
reviewer has determined the work was incomplete or incorrect. You are
restarting on the existing work branch \`${WORK_BRANCH}\`. The branch already
contains the prior run's commits.

Your first task: review what is already on this branch versus the integration
branch (\`${BRANCH}\`). Then continue or correct the work according to the
reviewer's instructions below.

EOF
  else
    cat <<EOF
You are working on GitLab issue #${ISSUE_IID}. Implement the change requested
in the issue description on the working branch \`${WORK_BRANCH}\` (branched
from \`${BRANCH}\`).

EOF
  fi

  cat <<EOF
# Issue
Title: ${ISSUE_TITLE}

Description:
${ISSUE_DESC}

EOF

  if [ "${ISSUE_MODE}" = "continue" ]; then
    cat <<EOF
# Reviewer comments (chronological)
${COMMENTS_BLOCK}

EOF
  fi

  cat <<EOF
# Working environment
- Repo path: ${REPO_PATH}
- Hulat materials: ${HULAT_DIR}
- Working branch: ${WORK_BRANCH}
- Integration branch: ${BRANCH}

# Rules
- Work only on this issue.
- Modify content under ${REPO_PATH} only. Never write outside the repo.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did${ISSUE_MODE:+ }$([ "${ISSUE_MODE}" = "continue" ] && echo "differently from the prior run").
EOF
} > "${PROMPT_FILE}"

echo "CONTINUE_MODE_NO_COMMENTS=${NO_COMMENTS}" >&2
echo "${PROMPT_FILE}"
