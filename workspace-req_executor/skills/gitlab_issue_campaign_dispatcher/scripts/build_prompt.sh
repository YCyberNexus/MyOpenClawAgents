#!/usr/bin/env bash
# build_prompt.sh — generate ${LOG_DIR}/prompt.txt from the live issue
# title/description/notes plus a small instruction header.
#
# The prompt has up to three input sections (continue mode):
#   - Issue title + description
#   - Past attempt summaries  (notes posted by req_executor itself, marked
#                              with <!-- req_executor:attempt-summary ... -->;
#                              legacy pre-rename markers are also recognized)
#   - Reviewer comments       (all OTHER non-system notes, excluding
#                              agent-posted Wiki artifact notes)
#
# In fresh mode only the first section is included.
#
# Required env vars (from env_paths.sh + glab_auth.sh + trigger):
#   GITLAB_HOST, PROJECT_URI,
#   ISSUE_IID, ISSUE_MODE,
#   LOG_DIR, REPO_PATH, WORKTREE_DIR, OUTPUT_DIR, WORK_BRANCH, BRANCH
#
# Output:
#   Writes ${LOG_DIR}/prompt.txt and prints its absolute path on stdout.
#   Reports auditing flags on stderr:
#     CONTINUE_MODE_NO_REVIEWER_COMMENTS=true|false
#     CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=<int>

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${LOG_DIR:?}" \
  "${REPO_PATH:?}" "${WORKTREE_DIR:?}" "${OUTPUT_DIR:?}" "${WORK_BRANCH:?}" \
  "${BRANCH:?}"

AUTO_MERGE="${AUTO_MERGE:-false}"
MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH}}"
case "${AUTO_MERGE}" in
  true|false) ;;
  *)
    echo "build_prompt: AUTO_MERGE must be true or false" >&2
    exit 2
    ;;
esac
: "${MERGE_TARGET_BRANCH:?build_prompt: MERGE_TARGET_BRANCH or BRANCH must be non-empty}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "build_prompt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

mkdir -p "${LOG_DIR}"
PROMPT_FILE="${LOG_DIR}/prompt.txt"

# 1. Issue body. The dispatcher passes the exact live Issue snapshot used for
# dependency selection so a body edit between preflight and prompt rendering
# cannot change the requested baseline. Standalone callers retain the original
# live API fallback.
ISSUE_JSON_FILE="${ISSUE_JSON_FILE:-}"
if [ -n "${ISSUE_JSON_FILE}" ]; then
  case "${ISSUE_JSON_FILE}" in
    /*) ;;
    *) echo "build_prompt: ISSUE_JSON_FILE must be absolute" >&2; exit 2 ;;
  esac
  if [ ! -f "${ISSUE_JSON_FILE}" ] || [ -L "${ISSUE_JSON_FILE}" ] \
      || [ ! -r "${ISSUE_JSON_FILE}" ]; then
    echo "build_prompt: ISSUE_JSON_FILE must be a readable regular non-symlink file" >&2
    exit 2
  fi
  ISSUE_JSON="$(jq -ce 'if type == "object" then . else error("invalid") end' \
    "${ISSUE_JSON_FILE}")"
else
  ISSUE_JSON="$(glab api \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"
fi
ISSUE_TITLE="$(echo "${ISSUE_JSON}" | jq -r '.title // ""')"
ISSUE_DESC="$(echo "${ISSUE_JSON}" | jq -r '.description // ""')"

# 2. Notes (continue mode only).
PAST_ATTEMPTS_BLOCK=""
REVIEWER_BLOCK=""
NO_REVIEWER_COMMENTS=true
PRIOR_ATTEMPT_COUNT=0
CURRENT_AGENT_MARKER_PREFIX="req_executor"
LEGACY_AGENT_MARKER_PREFIX="uiauto""tester"
SUMMARY_MARKER_RE="<!-- (${CURRENT_AGENT_MARKER_PREFIX}|${LEGACY_AGENT_MARKER_PREFIX}):attempt-summary v[0-9]+ "
AUTO_MARKER_RE="<!-- (${CURRENT_AGENT_MARKER_PREFIX}|${LEGACY_AGENT_MARKER_PREFIX}):attempt-(summary|attachments|wiki-artifacts) v[0-9]+ "

if [ "${ISSUE_MODE}" = "continue" ]; then
  NOTES_JSON="$(glab api --paginate \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at")"

  # Split notes:
  #   agent-posted summaries → match the marker comment
  #   agent-posted Wiki artifact notes → ignore for prompt purposes
  #   everything else (non-system) → reviewer comments
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

  if [ -z "${PAST_ATTEMPTS_BLOCK}" ]; then
    PAST_ATTEMPTS_BLOCK="(no prior attempt summaries found — this is unusual; treat the issue branch's existing commits as authoritative for prior work)"
  fi

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

A prior attempt on this issue already ran, and a human reviewer requested
resume by applying the \`continue\` label. You are running inside the shared
per-issue git worktree at ${WORKTREE_DIR} (reused across every attempt of
this IID). The dispatcher has prepared the worktree and restored prior files
under .req_executor/issue-${ISSUE_IID}/ so you can inspect them and
continue. Read what's already there, then continue or correct it
according to the past-attempt summaries and reviewer guidance below.

EOF
  else
    cat <<EOF
You are working on GitLab issue #${ISSUE_IID}. Implement the change
requested in the issue description. You are running inside the shared
per-issue git worktree at ${WORKTREE_DIR} (reused across every attempt
of this IID). The dispatcher has prepared this worktree for the current
attempt. Any same-IID runtime output/log subtree that survived a previous
attempt has been quarantined outside this active worktree before this prompt
was written.

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
# Past attempt summaries (auto-posted by req_executor)
${PAST_ATTEMPTS_BLOCK}

# Reviewer comments (everything else, chronological)
${REVIEWER_BLOCK}

EOF
  fi

  # Only advertise optional Claude runtime config when it actually exists.
  # The issue body remains the source of truth for what work to perform.
  SHARED_CONFIG_BLOCK=""
  if [ -d "${WORKTREE_DIR}/.claude" ]; then
    SHARED_CONFIG_BLOCK+="- Claude runtime config:      ${WORKTREE_DIR}/.claude (available in this worktree)"$'\n'
  fi
  SHARED_CONFIG_BLOCK="${SHARED_CONFIG_BLOCK%$'\n'}"

  cat <<EOF
# Working environment
- Repository cwd:             ${WORKTREE_DIR} (shared per-issue linked git worktree)
- Output directory:           ${OUTPUT_DIR} (for standalone deliverables that need to be preserved separately — force-added at commit time. Other source-code changes in the repo commit normally and do NOT need to go under this directory)
${SHARED_CONFIG_BLOCK}
- Working branch (local):     fixed IID-local branch in this worktree, will be pushed to origin/${WORK_BRANCH}
- Processing base branch:       ${BRANCH}
- Merge-request target branch:  ${MERGE_TARGET_BRANCH}
- Completion policy:            $([ "${AUTO_MERGE}" = true ] && echo "merge automatically after exact GitLab verification" || echo "leave the merge request open for review")

EOF

  cat <<EOF
# Rules
- Work only on this issue.
- Modify whatever files in the repository the issue requires. If the issue produces standalone artifacts (spec / report / test files), put those under \`${OUTPUT_DIR}\`; otherwise edit source files directly where they live, and note in your final summary which files you changed.
- Modify content under ${WORKTREE_DIR} only. Do NOT write outside this worktree.
- Use the issue description and reviewer comments as the task prompt. Do not assume any project-specific testing framework or material directory unless the issue explicitly names one.
- Do not inspect or modify dispatcher runtime state, the parent checkout, or another Issue's worktree/state. Those paths are outside the current Issue's authorized work scope even if the host process can technically reach them.
- Destructive deletion is forbidden. Do NOT call \`rm\`, \`/bin/rm\`, \`git rm\`, \`unlink\`, \`find -delete\`, or script file deletion through Python, Node, or another runtime. Do not delete files or directories for cleanup. If the issue seems to require deleting something, leave it in place and explain the blocker in your final summary.
- Git ownership is split deliberately. You may use only read-only Git inspection such as \`git status\`, \`git diff\`, \`git log\`, \`git show\`, and \`git ls-files\`. Do NOT run \`git add\`, \`git commit\`, \`git push\`, \`git fetch\`, \`git pull\`, \`git reset\`, \`git checkout\`, \`git switch\`, \`git restore\`, \`git clean\`, \`git worktree\`, \`git branch\` mutations, or any other Git command that changes refs, the index, remotes, or working-tree state. The outer fixed executor pipeline owns stage, commit, push, and merge-request creation or reuse after you return.
- Do NOT run \`glab\` in any form. GitLab reads and mutations are owned by the outer fixed executor scripts; do not inspect credentials, remotes, auth state, issues, merge requests, or labels yourself.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did$([ "${ISSUE_MODE}" = "continue" ] && echo " differently from the prior run").
EOF
} > "${PROMPT_FILE}"

echo "CONTINUE_MODE_NO_REVIEWER_COMMENTS=${NO_REVIEWER_COMMENTS}" >&2
echo "CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=${PRIOR_ATTEMPT_COUNT}" >&2
echo "${PROMPT_FILE}"
