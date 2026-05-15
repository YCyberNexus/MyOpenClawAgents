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
#   DEV_BRANCH, UI_ACCOUNT, UI_PASSWORD
#
# `HULAT_DIR` is NOT a trigger input. The test team commits `hulat/` to
# master+dev, so the repo checkout already contains it at
# `${REPO_PATH}/hulat`. env_paths.sh exports `HULAT_DIR=${REPO_PATH}/hulat`
# for any consumer that needs the absolute path, but build_prompt.sh
# does not surface the path in the prompt (the agent reads from `hulat/`
# relative to the repo root).
#
# UI_ACCOUNT / UI_PASSWORD are the test credentials for the subagent,
# read from the first entry of <workspace>/config/ui_accounts.env.
# All concurrent subagents share the same account (the test team has
# confirmed the system under test does not log out on duplicate login).
# They are injected into the prompt's "# Working environment" section
# with an override note: any account named in the issue body MUST be
# replaced by these values when Claude Code logs in.
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

# UI account is read from the first entry of the pool pinned at
# <workspace>/config/ui_accounts.env. All concurrent subagents share the
# same account (test team confirmed no duplicate-login issue).
# If either env var is missing, this script exits non-zero and the
# dispatcher marks the IID `blocked`.
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
if [ "${ACPX_RESUME:-false}" = "true" ]; then
  # Resume mode: the previous acpx run was interrupted. The Claude Code
  # session persists via `-s {SESSION_NAME}`, so the full task description
  # and past conversation are already in the session history. The prompt
  # written here is a step-aware resume hint: it lists the three hulat
  # sub-agents and instructs Claude Code to inspect OUTPUT_DIR on startup
  # and selectively invoke only the agents whose output is missing.
  {
    cat <<EOF
The previous run was interrupted before completion.

Issue:           #${ISSUE_IID} — ${ISSUE_TITLE}
Working dir:     ${WORKTREE_DIR}
Output dir:      ${OUTPUT_DIR}

You have access to the full conversation history from the previous run.

# Step-by-step layout (hulat agents under ${WORKTREE_DIR}/hulat/agents/)

This task runs three sub-agents in order, each writing under ${OUTPUT_DIR}:

  step1-scanner   -> detector.md            (analyzes the issue/site, produces scanner output)
  step2-generator -> testcase-generator.md  (produces test cases from scanner output)
  step3-executor  -> executor.md            (executes the test cases, produces the test report)

These agents do NOT have built-in skip logic. You are responsible for
choosing which agents to invoke based on what is already on disk.

# Resume decision (run this BEFORE anything else)

Before classifying, also check for partial / corrupt output from the
interrupted run: a file that exists but is zero-byte, has malformed
JSON, has an obviously truncated tail, or whose surrounding log
indicates an error at write time is NOT "complete" — treat the step
that produced it as incomplete (or earlier, if the corruption suggests
the input was already bad).

  1. \`ls -la ${OUTPUT_DIR}/\` and inspect what is already there from the
     previous run. Compare against what each step is expected to produce.
  2. If step2 (testcase-generator) has already produced a COMPLETE and
     uncorrupted set of test cases — i.e. detector output is present
     and consistent AND test cases are present and parseable — invoke
     ONLY step3 (executor.md) against the existing output. DO NOT
     invoke detector.md. DO NOT invoke testcase-generator.md — UNLESS
     you find concrete evidence the existing output is corrupted (e.g.
     zero-byte testcase files, malformed JSON, parse errors on first
     read). In that case, treat the corrupted step as incomplete and
     re-run from it.
  3. If step1 (detector) output is complete AND consistent but step2
     is missing/incomplete, invoke step2 (testcase-generator.md) and
     then step3 (executor.md). DO NOT invoke detector.md (same
     corruption-escape applies as in branch 2).
  4. If OUTPUT_DIR is empty, only has unrelated scraps, or step1
     output is itself partial/truncated/corrupted, run all three
     agents in order from step1.

When you are unsure whether step2's output is "complete", look at the
detector output (if step1 emits a structured manifest / scan list of
items to generate cases for, compare 1:1 against the testcase
artifacts present in OUTPUT_DIR; if detector's output is free-form,
fall back to file sizes and timestamps to judge completeness). If
every scanned item has a corresponding test case, step2 is complete.
Otherwise treat step2 as incomplete and re-run it for the missing
items.

# Reporting

When you finish, summarize briefly:
  - Which agents you invoked (and which you skipped, with the reason).
  - Any new outputs produced vs. carried over from the prior run.
EOF
  } > "${PROMPT_FILE}"
  echo "CONTINUE_MODE_NO_REVIEWER_COMMENTS=true" >&2
  echo "CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=0" >&2
  echo "${PROMPT_FILE}"
  exit 0
fi

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

# UI test account
The following test account is used for THIS run. When the issue description
names a UI account (for example "use F100001 to log in"), you MUST IGNORE that
name and use the credentials below instead.

- Username: ${UI_ACCOUNT}
- Password: ${UI_PASSWORD}

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
