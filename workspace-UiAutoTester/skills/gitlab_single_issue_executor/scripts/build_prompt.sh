#!/usr/bin/env bash
# build_prompt.sh — generate ${LOG_DIR}/prompt.txt from the live issue
# title/description/notes plus a small instruction header.
#
# The prompt has up to three input sections (continue mode):
#   - Issue title + description
#   - Past attempt summaries  (notes posted by uiautotester itself, marked
#                              with <!-- uiautotester:attempt-summary ... -->)
#   - Reviewer comments       (all OTHER non-system notes)
#
# In fresh mode only the first section is included.
#
# Required env vars (from env_paths.sh + glab_auth.sh + trigger):
#   GITLAB_HOST, PROJECT_URI,
#   ISSUE_IID, ISSUE_MODE,
#   LOG_DIR, REPO_PATH, WORKTREE_DIR, WORK_BRANCH, BRANCH, DEV_BRANCH, HULAT_DIR
#
# Output:
#   Writes ${LOG_DIR}/prompt.txt and prints its absolute path on stdout.
#   Reports auditing flags on stderr:
#     CONTINUE_MODE_NO_REVIEWER_COMMENTS=true|false
#     CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=<int>

set -euo pipefail

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${LOG_DIR:?}" \
  "${REPO_PATH:?}" "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" \
  "${BRANCH:?}" "${DEV_BRANCH:?}" "${HULAT_DIR:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "build_prompt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

mkdir -p "${LOG_DIR}"
PROMPT_FILE="${LOG_DIR}/prompt.txt"

# 1. Issue body.
ISSUE_JSON="$(glab api \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"
ISSUE_TITLE="$(echo "${ISSUE_JSON}" | jq -r '.title // ""')"
ISSUE_DESC="$(echo "${ISSUE_JSON}" | jq -r '.description // ""')"

# 2. Notes (continue mode only).
PAST_ATTEMPTS_BLOCK=""
REVIEWER_BLOCK=""
NO_REVIEWER_COMMENTS=true
PRIOR_ATTEMPT_COUNT=0

if [ "${ISSUE_MODE}" = "continue" ]; then
  NOTES_JSON="$(glab api --paginate \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at")"

  # Split notes:
  #   agent-posted summaries → match the marker comment
  #   everything else (non-system) → reviewer comments
  PAST_ATTEMPTS_BLOCK="$(echo "${NOTES_JSON}" | jq -r '
    [ .[] | select(.system == false)
          | select(.body | test("<!-- uiautotester:attempt-summary v[0-9]+ ")) | .body ]
    | if length == 0 then "" else (join("\n\n")) end
  ')"
  PRIOR_ATTEMPT_COUNT="$(echo "${NOTES_JSON}" | jq -r '
    [ .[] | select(.system == false)
          | select(.body | test("<!-- uiautotester:attempt-summary v[0-9]+ ")) ] | length
  ')"

  REVIEWER_BLOCK="$(echo "${NOTES_JSON}" | jq -r '
    [ .[] | select(.system == false)
          | select(.body | test("<!-- uiautotester:attempt-summary v[0-9]+ ") | not) | .body ]
    | if length == 0 then "" else (join("\n---\n")) end
  ')"

  if [ -z "${REVIEWER_BLOCK}" ]; then
    REVIEWER_BLOCK="(no reviewer comments — please review the prior attempt summaries above plus the existing diff and decide whether the work is acceptable as-is)"
  else
    NO_REVIEWER_COMMENTS=false
  fi
fi

# 3. Build the prompt file.
{
  if [ "${ISSUE_MODE}" = "continue" ]; then
    cat <<EOF
This is a CONTINUE-MODE re-run of GitLab issue #${ISSUE_IID}.

A prior run on this issue produced a merge request and was marked \`done\`,
but a human reviewer has determined the work was incomplete or incorrect.
You are running inside a fresh git worktree at ${WORKTREE_DIR}, branched
from \`origin/${WORK_BRANCH}\` (the work-in-progress branch from the prior
run). Read what's already there, then continue or correct it according to
the past-attempt summaries and reviewer guidance below.

EOF
  else
    cat <<EOF
You are working on GitLab issue #${ISSUE_IID}. Implement the change
requested in the issue description. You are running inside a fresh git
worktree at ${WORKTREE_DIR}, branched from \`origin/${DEV_BRANCH}\`
(the clean baseline). The integration branch \`${BRANCH}\` already
contains spec output from previously completed issues, but you should
NOT see that here — your worktree starts clean.

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
# Past attempt summaries (auto-posted by UiAutoTester)
${PAST_ATTEMPTS_BLOCK:-(no prior attempt summaries found — this is unusual; treat the issue branch's existing commits as authoritative for prior work)}

# Reviewer comments (everything else, chronological)
${REVIEWER_BLOCK}

EOF
  fi

  cat <<EOF
# Working environment
- Worktree (your cwd):        ${WORKTREE_DIR}
- Hulat materials (symlink):  ${WORKTREE_DIR}/_hulat → ${HULAT_DIR}
- Working branch (local):     attempt-local branch in this worktree, will be force-pushed to origin/${WORK_BRANCH}
- Source baseline branch:     ${DEV_BRANCH}  (where this worktree was branched from in fresh mode)
- Integration / target branch: ${BRANCH}  (where the merge request will be opened against)

# Rules
- Work only on this issue.
- **Output isolation.** Place all spec / report / artifact output for this issue under \`hulat-spec-issue${ISSUE_IID}/\` at the worktree root. Do NOT write spec output anywhere else. Do NOT modify files outside this subdirectory unless absolutely necessary; if you must touch a shared file (e.g. a project-level config that applies to everyone), explain why in your final summary.
- Modify content under ${WORKTREE_DIR} only. Do NOT write outside the worktree.
- Read configuration from ${WORKTREE_DIR}/_hulat (the symlink); do not modify hulat materials — they are shared, read-only.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did${ISSUE_MODE:+ }$([ "${ISSUE_MODE}" = "continue" ] && echo "differently from the prior run").
EOF
} > "${PROMPT_FILE}"

echo "CONTINUE_MODE_NO_REVIEWER_COMMENTS=${NO_REVIEWER_COMMENTS}" >&2
echo "CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=${PRIOR_ATTEMPT_COUNT}" >&2
echo "${PROMPT_FILE}"
