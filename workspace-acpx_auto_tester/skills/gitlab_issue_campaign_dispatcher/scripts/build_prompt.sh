#!/usr/bin/env bash
# build_prompt.sh — generate ${LOG_DIR}/prompt.txt from the live issue
# title/description/notes plus a small instruction header.
#
# The prompt has a single input section — the issue title + description.
# (benchmark-test is fresh-only; continue-mode resume — past-attempt summary
# and reviewer-comment injection — is disabled.)
#
# Required env vars (from env_paths.sh + glab_auth.sh + trigger):
#   GITLAB_HOST, PROJECT_URI,
#   ISSUE_IID, ISSUE_MODE,
#   LOG_DIR, REPO_PATH, WORKTREE_DIR, OUTPUT_DIR, LOCAL_ATTEMPT_BRANCH, BRANCH,
#   DEV_BRANCH, UI_ACCOUNTS
#
# Optional env var (v2 model tier injection):
#   MODEL  — the model name the dispatcher resolved for THIS attempt in
#            PREPARE (per-tick tier pinning from the pin_model_tier trigger
#            field; see SKILL.md §Dispatcher Algorithm and label_lifecycle.md
#            §model tier). When set and non-empty it
#            is surfaced in the prompt's "# Working environment" section so
#            the Claude Code run knows which tier it is operating at. When
#            unset / empty the model line is omitted (legacy behavior).
#
# `HULAT_DIR` is NOT a trigger input. The test team commits `hulat/` to
# master+dev, so the repo checkout already contains it at
# `${REPO_PATH}/hulat`. env_paths.sh exports `HULAT_DIR=${REPO_PATH}/hulat`
# for any consumer that needs the absolute path, but build_prompt.sh
# does not surface the path in the prompt (the agent reads from `hulat/`
# relative to the repo root).
#
# UI_ACCOUNTS is a JSON array of {"u":"<username>","p":"<password>"} objects,
# allocated by the dispatcher from the test-team-owned pool. Each subagent
# receives the slot it was assigned by load_ui_accounts.sh — slot size
# = floor(pool_size / max_concurrent_subagents) with the integer remainder
# front-loaded onto the first slots, then capped by max_accounts_per_issue
# (default 14), so the count varies across IIDs in the same batch when the
# pool does not divide evenly or the cap binds. They are
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

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${LOG_DIR:?}" \
  "${REPO_PATH:?}" "${WORKTREE_DIR:?}" "${OUTPUT_DIR:?}" "${LOCAL_ATTEMPT_BRANCH:?}" \
  "${BRANCH:?}" "${DEV_BRANCH:?}"

# UI accounts are allocated by the dispatcher per-batch from the pool at
# ${REPO_PATH}/${UI_ACCOUNTS_RELPATH} (no default; trigger field
# ui_accounts_relpath, carry-forward persisted). When the deployment did
# NOT configure ui_accounts_relpath, the dispatcher skips the pool load
# entirely and passes either an empty UI_ACCOUNTS env var or UI_ACCOUNTS='[]'
# to this script; in that mode the `# UI test accounts` section of the
# rendered prompt is omitted. When configured, each subagent receives
# its assigned slot (count derived automatically from pool_size /
# max_concurrent_subagents with the integer remainder front-loaded,
# then capped by max_accounts_per_issue). The dispatcher ensures
# distinct accounts across concurrent batch members AND across
# concurrent robot executions within a subagent. UI_ACCOUNTS must be
# either unset, "", "[]", or a non-empty JSON array of
# {"u":"<user>","p":"<pass>"} objects — any other shape exits non-zero
# and the dispatcher marks the IID `blocked`.
ACCOUNT_COUNT=0
if [ -n "${UI_ACCOUNTS:-}" ]; then
  if ! echo "${UI_ACCOUNTS}" | jq -e '. | type == "array"' >/dev/null 2>&1; then
    echo "build_prompt: UI_ACCOUNTS must be a JSON array (got: ${UI_ACCOUNTS})" >&2
    exit 4
  fi
  ACCOUNT_COUNT="$(echo "${UI_ACCOUNTS}" | jq 'length')"
fi

case "${ISSUE_MODE}" in
  fresh) ;;
  *)
    echo "build_prompt: ISSUE_MODE must be fresh (continue is disabled on benchmark-test), got '${ISSUE_MODE}'" >&2
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

# 2. Build the prompt file.
{
  cat <<EOF
You are working on GitLab issue #${ISSUE_IID}. Implement the change
requested in the issue description. You are running inside the shared
per-issue git worktree at ${WORKTREE_DIR} (reused across every attempt
of this IID). Tracked files have just been reset to
\`origin/${DEV_BRANCH}\` (the clean baseline). Any same-IID runtime
output/log subtree that survived a previous attempt has been quarantined
outside this active worktree before this prompt was written. The integration
branch \`${BRANCH}\` already contains spec output from previously completed
issues, but you should NOT see that on tracked files here when ${DEV_BRANCH}
is kept clean.

EOF

  cat <<EOF
# Issue
Title: ${ISSUE_TITLE}

Description:
${ISSUE_DESC}

EOF

  cat <<EOF
# Working environment
- Repository cwd:             ${WORKTREE_DIR} (shared per-issue linked git worktree)
- Output directory:           ${OUTPUT_DIR} (the only place to write spec results — force-added at commit time)
- Hulat materials:            ${WORKTREE_DIR}/hulat   (committed in ${BRANCH}/${DEV_BRANCH}, available in this worktree)
- Claude runtime config:      ${WORKTREE_DIR}/.claude (committed in ${BRANCH}/${DEV_BRANCH}, available in this worktree)
- Knowledge base:             ${WORKTREE_DIR}/${DATA_BASENAME} (committed in ${BRANCH}/${DEV_BRANCH}, available in this worktree)
- Remote branch (this attempt): origin/${LOCAL_ATTEMPT_BRANCH} (immutable per-attempt branch; this attempt's commit is pushed here at commit time, never overwritten)
- Source baseline:            origin/${DEV_BRANCH} (clean baseline; shared config paths are refreshed from latest ${DEV_BRANCH} before every run)
- Integration / target branch: ${BRANCH}
$([ -n "${MODEL:-}" ] && printf -- '- Model tier (this attempt):  %s  (pinned per tick by the dispatcher for benchmarking)\n' "${MODEL}")

EOF

  if [ "${ACCOUNT_COUNT}" -gt 0 ]; then
    cat <<EOF
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

EOF
  fi

  cat <<EOF
# Rules
- Work only on this issue.
- **Output isolation.** Place all spec / report / artifact output for this issue under \`${OUTPUT_DIR}\`. Do NOT write spec output anywhere else. Do NOT modify files outside this subdirectory unless absolutely necessary; if you must touch a shared file (e.g. a project-level config that applies to everyone), explain why in your final summary.
- Modify content under ${WORKTREE_DIR} only. Do NOT write outside this worktree.
- Treat \`hulat/\`, \`.claude/\`, and \`${DATA_BASENAME}/\` as shared repository content. Change them only when the issue genuinely requires it, and mention those changes in your final summary.
- The dispatcher's runtime state and other issues' subtrees live OUTSIDE this worktree (in the parent checkout's \`${RESULT_BASENAME}/_dispatcher/\` and \`${RESULT_BASENAME}/issue-*/\`) and are not visible to you here. Keep your edits under \`${OUTPUT_DIR}\` unless the issue genuinely requires modifying the test team's shared content above.
- Destructive deletion is forbidden. Do NOT call \`rm\`, \`/bin/rm\`, \`git rm\`, \`unlink\`, \`find -delete\`, or script file deletion through Python, Node, or another runtime. Do not delete files or directories for cleanup. If the issue seems to require deleting something, leave it in place and explain the blocker in your final summary.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did.
EOF
} > "${PROMPT_FILE}"

echo "${PROMPT_FILE}"
