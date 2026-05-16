#!/usr/bin/env bash
# build_prompt.sh — generate ${LOG_DIR}/prompt.txt from the live issue
# title/description/notes plus a small instruction header.
#
# The prompt has up to three input sections (continue mode):
#   - Issue title + description
#   - Past attempt summaries  (notes posted by acpx_auto_tester itself, marked
#                              with <!-- acpx_auto_tester:attempt-summary ... -->;
#                              legacy pre-rename markers are also recognized)
#   - Reviewer comments       (all OTHER non-system notes, excluding
#                              agent-posted Wiki artifact notes)
#
# In fresh mode only the first section is included.
#
# Required env vars (from env_paths.sh + glab_auth.sh + trigger):
#   GITLAB_HOST, PROJECT_URI,
#   ISSUE_IID, ISSUE_MODE,
#   LOG_DIR, REPO_PATH, WORKTREE_DIR, OUTPUT_DIR, WORK_BRANCH, BRANCH,
#   DEV_BRANCH, UI_ACCOUNTS
#
# `HULAT_DIR` is NOT a trigger input. The test team commits `hulat/` to
# master+dev, so the repo checkout already contains it at
# `${REPO_PATH}/hulat`. env_paths.sh exports `HULAT_DIR=${REPO_PATH}/hulat`
# for any consumer that needs the absolute path, but build_prompt.sh
# does not surface the path in the prompt (the agent reads from `hulat/`
# relative to the repo root).
#
# UI_ACCOUNTS is a JSON array of {"u":"<username>","p":"<password>"} objects,
# allocated by the dispatcher from the deployment-pinned pool. Each subagent
# receives the slot it was assigned by load_ui_accounts.sh — slot size
# = floor(pool_size / max_concurrent_subagents) with the integer remainder
# front-loaded onto the first slots, so the count varies across IIDs in the
# same batch when the pool does not divide evenly. They are
# injected into the prompt's "# Working environment" section with an explicit
# override note: any account named in the issue body MUST be replaced by one
# of these values when Claude Code logs in. Different concurrent subagents
# always receive different accounts (see dispatcher's UI Account Allocation
# Policy), and different robot executions within a subagent MUST use different
# accounts — sharing an account would cause one robot to kick another out of
# the system under test.
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
  "${BRANCH:?}" "${DEV_BRANCH:?}"

# UI accounts are allocated by the dispatcher per-batch from the pool pinned
# at <workspace>/config/ui_accounts.env. Each subagent receives its assigned
# slot (count derived automatically from pool_size / max_concurrent_subagents
# with the integer remainder front-loaded). The dispatcher
# ensures distinct accounts across concurrent batch members AND across
# concurrent robot executions within a subagent — see SKILL.md
# §UI Account Allocation Policy. If UI_ACCOUNTS is missing or invalid,
# this script exits non-zero and the dispatcher marks the IID `blocked`.
if [ -z "${UI_ACCOUNTS:-}" ]; then
  echo "build_prompt: UI_ACCOUNTS is required (dispatcher must pass a JSON array of {\"u\":\"<user>\",\"p\":\"<pass>\"} objects)" >&2
  exit 3
fi
if ! echo "${UI_ACCOUNTS}" | jq -e '. | type == "array" and length > 0' >/dev/null 2>&1; then
  echo "build_prompt: UI_ACCOUNTS must be a non-empty JSON array" >&2
  exit 4
fi
ACCOUNT_COUNT="$(echo "${UI_ACCOUNTS}" | jq 'length')"

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
CURRENT_AGENT_MARKER_PREFIX="acpx_auto_tester"
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

A prior run on this issue produced a merge request and was marked \`done\` + \`pr\`,
but a human reviewer has determined the work was incomplete or incorrect.
You are running inside a per-attempt git worktree at ${WORKTREE_DIR},
branched from \`origin/${WORK_BRANCH}\` (the work-in-progress branch
from the prior run). Read what's already there, then continue or
correct it according to the past-attempt summaries and reviewer
guidance below.

EOF
  else
    cat <<EOF
You are working on GitLab issue #${ISSUE_IID}. Implement the change
requested in the issue description. You are running inside a per-attempt
git worktree at ${WORKTREE_DIR}, branched from \`origin/${DEV_BRANCH}\`
(the clean baseline). The integration branch \`${BRANCH}\` already
contains spec output from previously completed issues, but you should
NOT see that here when ${DEV_BRANCH} is kept clean.

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
${PAST_ATTEMPTS_BLOCK:-(no prior attempt summaries found — this is unusual; treat the issue branch's existing commits as authoritative for prior work)}

# Reviewer comments (everything else, chronological)
${REVIEWER_BLOCK}

EOF
  fi

  cat <<EOF
# Working environment
- Repository cwd:             ${WORKTREE_DIR} (per-attempt linked git worktree)
- Output directory:           ${OUTPUT_DIR} (the only place to write spec results — force-added at commit time)
- Hulat materials:            ${WORKTREE_DIR}/hulat   (committed in ${BRANCH}/${DEV_BRANCH}, available in this worktree)
- Claude runtime config:      ${WORKTREE_DIR}/.claude (committed in ${BRANCH}/${DEV_BRANCH}, available in this worktree)
- Knowledge base:             ${WORKTREE_DIR}/${DATA_BASENAME} (committed in ${BRANCH}/${DEV_BRANCH}, available in this worktree)
- Working branch (local):     attempt-local branch in this worktree, will be force-pushed to origin/${WORK_BRANCH}
- Source baseline branch:     ${DEV_BRANCH}  (where this worktree was branched from in fresh mode)
- Integration / target branch: ${BRANCH}  (where the merge request will be opened against)

# UI test accounts (dispatcher-allocated — overrides any account in the issue body)
The orchestrator has allocated the following ${ACCOUNT_COUNT} test accounts for THIS run.
When the issue description names a UI account (for example "use F100001 to log in"),
you MUST IGNORE that name and use one of the credentials below instead. Other concurrent
runs are using DIFFERENT accounts; reusing the issue body's account would cause
both runs to log each other out of the system under test.

This run has ${ACCOUNT_COUNT} accounts available — one per robot test file. Assign
distinct accounts to concurrent robot executions; never share an account between two
concurrently-running robots.

$(echo "${UI_ACCOUNTS}" | jq -r 'to_entries | .[] | "- Account \(.key + 1): username=\(.value.u), password=\(.value.p)"')

# Rules
- Work only on this issue.
- **Output isolation.** Place all spec / report / artifact output for this issue under \`${OUTPUT_DIR}\`. Do NOT write spec output anywhere else. Do NOT modify files outside this subdirectory unless absolutely necessary; if you must touch a shared file (e.g. a project-level config that applies to everyone), explain why in your final summary.
- Modify content under ${WORKTREE_DIR} only. Do NOT write outside this worktree.
- Treat \`hulat/\`, \`.claude/\`, and \`${DATA_BASENAME}/\` as shared repository content. Change them only when the issue genuinely requires it, and mention those changes in your final summary.
- The dispatcher's runtime state and other issues' subtrees live OUTSIDE this worktree (in the parent checkout's \`${RESULT_BASENAME}/_dispatcher/\` and \`${RESULT_BASENAME}/issue-*/\`) and are not visible to you here. Keep your edits under \`${OUTPUT_DIR}\` unless the issue genuinely requires modifying the test team's shared content above.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did${ISSUE_MODE:+ }$([ "${ISSUE_MODE}" = "continue" ] && echo "differently from the prior run").
EOF
} > "${PROMPT_FILE}"

echo "CONTINUE_MODE_NO_REVIEWER_COMMENTS=${NO_REVIEWER_COMMENTS}" >&2
echo "CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=${PRIOR_ATTEMPT_COUNT}" >&2
echo "${PROMPT_FILE}"
