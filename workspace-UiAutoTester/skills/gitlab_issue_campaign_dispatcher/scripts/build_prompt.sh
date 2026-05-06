#!/usr/bin/env bash
# build_prompt.sh — dispatcher-owned prompt generation for a prepared
# issue worker. It reads the live issue and optional continue-mode notes,
# injects the dispatcher-allocated UI account, and writes ${LOG_DIR}/prompt.txt.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${LOG_DIR:?}" \
  "${REPO_PATH:?}" "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" \
  "${BRANCH:?}" "${DEV_BRANCH:?}" "${HULAT_DIR:?}"

if [ -z "${UI_ACCOUNT:-}" ]; then
  echo "build_prompt: UI_ACCOUNT is required" >&2
  exit 3
fi
if [ -z "${UI_PASSWORD:-}" ]; then
  echo "build_prompt: UI_PASSWORD is required" >&2
  exit 4
fi

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "build_prompt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

mkdir -p "${LOG_DIR}"
PROMPT_FILE="${LOG_DIR}/prompt.txt"

ISSUE_JSON="$(glab api "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"
ISSUE_TITLE="$(echo "${ISSUE_JSON}" | jq -r '.title // ""')"
ISSUE_DESC="$(echo "${ISSUE_JSON}" | jq -r '.description // ""')"

PAST_ATTEMPTS_BLOCK=""
REVIEWER_BLOCK=""
NO_REVIEWER_COMMENTS=true
PRIOR_ATTEMPT_COUNT=0
CURRENT_AGENT_MARKER_PREFIX="acpx_auto_tester"
LEGACY_AGENT_MARKER_PREFIX="uiauto""tester"
SUMMARY_MARKER_RE="<!-- (${CURRENT_AGENT_MARKER_PREFIX}|${LEGACY_AGENT_MARKER_PREFIX}):attempt-summary v[0-9]+ "
AUTO_MARKER_RE="<!-- (${CURRENT_AGENT_MARKER_PREFIX}|${LEGACY_AGENT_MARKER_PREFIX}):attempt-(summary|attachments|wiki-artifacts) v[0-9]+ "

if [ "${ISSUE_MODE}" = "continue" ]; then
  NOTES_JSON="$(glab api --paginate \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at")"

  PAST_ATTEMPTS_BLOCK="$(echo "${NOTES_JSON}" | jq -r --arg marker_re "${SUMMARY_MARKER_RE}" '
    [ .[] | select(.system == false)
          | select(.body | test($marker_re)) | .body ]
    | if length == 0 then "" else (join("\n\n")) end
  ')"
  PRIOR_ATTEMPT_COUNT="$(echo "${NOTES_JSON}" | jq -r --arg marker_re "${SUMMARY_MARKER_RE}" '
    [ .[] | select(.system == false)
          | select(.body | test($marker_re)) ] | length
  ')"

  REVIEWER_BLOCK="$(echo "${NOTES_JSON}" | jq -r --arg marker_re "${AUTO_MARKER_RE}" '
    [ .[] | select(.system == false)
          | select(.body | test($marker_re) | not) | .body ]
    | if length == 0 then "" else (join("\n---\n")) end
  ')"

  if [ -z "${REVIEWER_BLOCK}" ]; then
    REVIEWER_BLOCK="(no reviewer comments - review the prior attempt summaries above plus the existing diff and decide whether the work is acceptable as-is)"
  else
    NO_REVIEWER_COMMENTS=false
  fi
fi

{
  if [ "${ISSUE_MODE}" = "continue" ]; then
    cat <<EOF
This is a CONTINUE-MODE re-run of GitLab issue #${ISSUE_IID}.

A prior run on this issue produced a merge request and was marked done + pr,
but a human reviewer has determined the work was incomplete or incorrect.
You are running inside a prepared git worktree at ${WORKTREE_DIR}, branched
from origin/${WORK_BRANCH} when that branch exists. Read what is already
there, then continue or correct it according to the past-attempt summaries
and reviewer guidance below.

EOF
  else
    cat <<EOF
You are working on GitLab issue #${ISSUE_IID}. Implement the change requested
in the issue description. You are running inside a prepared git worktree at
${WORKTREE_DIR}, branched from origin/${DEV_BRANCH} (the clean baseline).
The integration branch ${BRANCH} may contain spec output from previous issues,
but this worktree starts from the clean baseline.

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
# Past attempt summaries (auto-posted by acpx_auto_tester)
${PAST_ATTEMPTS_BLOCK:-(no prior attempt summaries found - treat the issue branch's existing commits as authoritative for prior work)}

# Reviewer comments (everything else, chronological)
${REVIEWER_BLOCK}

EOF
  fi

  cat <<EOF
# Working environment
- Worktree (your cwd):         ${WORKTREE_DIR}
- Hulat materials (symlink):   ${WORKTREE_DIR}/hulat -> ${HULAT_DIR}
- Claude runtime config:       ${WORKTREE_DIR}/.claude (local-only)
- Working branch (local):      ${LOCAL_ATTEMPT_BRANCH}
- Remote work branch:          origin/${WORK_BRANCH}
- Source baseline branch:      ${DEV_BRANCH}
- Integration / target branch: ${BRANCH}

# UI test account (dispatcher-allocated)
Use the credentials below for THIS run. If the issue body names another UI
account, ignore it; other concurrent runs have distinct accounts.

- Username: ${UI_ACCOUNT}
- Password: ${UI_PASSWORD}

# Rules
- Work only on this issue.
- Place all spec / report / artifact output for this issue under hulat-spec-issue${ISSUE_IID}/ at the worktree root.
- Modify content under ${WORKTREE_DIR} only. Do not write outside the worktree.
- Read configuration from ${WORKTREE_DIR}/hulat; do not modify hulat materials.
- Treat ${WORKTREE_DIR}/.claude as local runtime config; do not modify it or include it in issue output.
- Do not ask the user questions. Make the best reasonable decisions.
- When finished, summarize briefly what you did.
EOF
} > "${PROMPT_FILE}"

echo "CONTINUE_MODE_NO_REVIEWER_COMMENTS=${NO_REVIEWER_COMMENTS}" >&2
echo "CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=${PRIOR_ATTEMPT_COUNT}" >&2
echo "${PROMPT_FILE}"
