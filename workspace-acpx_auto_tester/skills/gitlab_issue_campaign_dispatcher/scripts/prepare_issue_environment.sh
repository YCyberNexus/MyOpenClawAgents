#!/usr/bin/env bash
# prepare_issue_environment.sh — single dispatcher entrypoint that turns an
# allocated IID attempt into a fully prepared worker handoff. It performs all
# filesystem/repo/prompt setup before sessions_spawn.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${SKILL_DIR}"
source "${SCRIPT_DIR}/env_paths.sh"

: "${PROJECT:?}" "${GROUP:?}" "${GITLAB_TOKEN:?}" "${PROJECT_URI:?}" "${PROJECT_FULL:?}"
: "${ISSUE_IID:?}" "${ATTEMPT_NUMBER:?}" "${BRANCH:?}" "${DEV_BRANCH:?}" "${HULAT_DIR:?}"
: "${UI_ACCOUNT:?}" "${UI_PASSWORD:?}"
: "${ISSUE_ROOT:?}" "${ISSUE_STATE_FILE:?}" "${ATTEMPT_STATE_FILE:?}" "${HANDOFF_FILE:?}" \
  "${SUBAGENT_TASK_FILE:?}" "${LOG_DIR:?}" "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" \
  "${LOCAL_ATTEMPT_BRANCH:?}" "${SUMMARY_FILE:?}"

ISSUE_MODE_REQUESTED="${ISSUE_MODE:-fresh}"
case "${ISSUE_MODE_REQUESTED}" in
  fresh|continue) ;;
  *)
    echo "prepare_issue_environment: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE_REQUESTED}'" >&2
    exit 2
    ;;
esac

bash scripts/clone_or_pull.sh >/dev/null

ISSUE_JSON="$(glab api "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"
ISSUE_TITLE="$(echo "${ISSUE_JSON}" | jq -r '.title // ""')"
HAS_CONTINUE="$(echo "${ISSUE_JSON}" | jq -r '((.labels // []) | index("continue") != null)')"
if [ "${HAS_CONTINUE}" = "true" ]; then
  ISSUE_MODE_REQUESTED=continue
fi

PREP_OUTPUT="$(ISSUE_MODE="${ISSUE_MODE_REQUESTED}" bash scripts/prepare_attempt.sh)"
ISSUE_MODE_ACTUAL="$(printf '%s\n' "${PREP_OUTPUT}" | sed -n '1p')"
PREP_LOCAL_BRANCH="$(printf '%s\n' "${PREP_OUTPUT}" | sed -n '2p')"

BUILD_STDERR="${LOG_DIR}/build_prompt.stderr"
UI_ACCOUNT="${UI_ACCOUNT}" UI_PASSWORD="${UI_PASSWORD}" ISSUE_MODE="${ISSUE_MODE_ACTUAL}" \
  bash scripts/build_prompt.sh 2>"${BUILD_STDERR}" >/dev/null

NO_REVIEWER_COMMENTS="$(grep '^CONTINUE_MODE_NO_REVIEWER_COMMENTS=' "${BUILD_STDERR}" | tail -n 1 | cut -d= -f2- || true)"
PRIOR_ATTEMPT_COUNT="$(grep '^CONTINUE_MODE_PRIOR_ATTEMPT_COUNT=' "${BUILD_STDERR}" | tail -n 1 | cut -d= -f2- || true)"
NO_REVIEWER_COMMENTS="${NO_REVIEWER_COMMENTS:-true}"
PRIOR_ATTEMPT_COUNT="${PRIOR_ATTEMPT_COUNT:-0}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SESSION_NAME="issue-${PROJECT}-${ISSUE_IID}"
MODE_DOWNGRADED_FROM="null"
if [ "${ISSUE_MODE_REQUESTED}" != "${ISSUE_MODE_ACTUAL}" ]; then
  MODE_DOWNGRADED_FROM="\"${ISSUE_MODE_REQUESTED}\""
fi

PREV_RETRY_COUNT=0
if [ -s "${ISSUE_STATE_FILE}" ]; then
  PREV_RETRY_COUNT="$(jq -r '.retry_count // 0' "${ISSUE_STATE_FILE}")"
fi
RETRY_COUNT="${PREV_RETRY_COUNT}"

jq -n \
  --argjson iid "${ISSUE_IID}" \
  --argjson attempt_number "${ATTEMPT_NUMBER}" \
  --arg attempt_started_at "${NOW}" \
  --arg mode_requested "${ISSUE_MODE_REQUESTED}" \
  --arg mode_actual "${ISSUE_MODE_ACTUAL}" \
  --argjson mode_downgraded_from "${MODE_DOWNGRADED_FROM}" \
  --argjson no_reviewer_comments "${NO_REVIEWER_COMMENTS}" \
  --argjson prior_attempt_count "${PRIOR_ATTEMPT_COUNT}" \
  --arg local_branch "${PREP_LOCAL_BRANCH}" \
  --arg log_dir "${LOG_DIR}" \
  --arg skill_version "2026-05-06.3" \
  '{
    iid: $iid,
    attempt_number: $attempt_number,
    attempt_started_at: $attempt_started_at,
    mode_requested: $mode_requested,
    mode_actual: $mode_actual,
    mode_downgraded_from: $mode_downgraded_from,
    no_reviewer_comments: $no_reviewer_comments,
    prior_attempt_count: $prior_attempt_count,
    local_branch: $local_branch,
    log_dir: $log_dir,
    status: "in_progress",
    block_reason: null,
    summary_posted_to_issue: false,
    skill_version: $skill_version
  }' > "${ATTEMPT_STATE_FILE}"

TMP="$(mktemp "${ISSUE_ROOT}/.state.XXXXXX")"
if [ -s "${ISSUE_STATE_FILE}" ]; then
  jq \
    --argjson iid "${ISSUE_IID}" \
    --arg session "${SESSION_NAME}" \
    --arg mode "${ISSUE_MODE_ACTUAL}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg latest_attempt_dir "${ATTEMPT_DIR}" \
    --argjson retry_count "${RETRY_COUNT}" \
    --arg skill_version "2026-05-06.3" \
    --arg now "${NOW}" \
    '.iid = $iid
      | .session = $session
      | .status = "in_progress"
      | .mode = $mode
      | .attempts_total = $attempt_number
      | .latest_attempt_number = $attempt_number
      | .latest_attempt_dir = $latest_attempt_dir
      | .retry_count = $retry_count
      | .block_reason = null
      | .skill_version = $skill_version
      | .updated_at = $now' "${ISSUE_STATE_FILE}" > "${TMP}"
else
  jq -n \
    --argjson iid "${ISSUE_IID}" \
    --arg session "${SESSION_NAME}" \
    --arg mode "${ISSUE_MODE_ACTUAL}" \
    --argjson attempt_number "${ATTEMPT_NUMBER}" \
    --arg latest_attempt_dir "${ATTEMPT_DIR}" \
    --argjson retry_count "${RETRY_COUNT}" \
    --arg skill_version "2026-05-06.3" \
    --arg now "${NOW}" \
    '{
      iid: $iid,
      session: $session,
      status: "in_progress",
      mode: $mode,
      attempts_total: $attempt_number,
      latest_attempt_number: $attempt_number,
      latest_attempt_dir: $latest_attempt_dir,
      retry_count: $retry_count,
      block_reason: null,
      merge_request_url: null,
      skill_version: $skill_version,
      updated_at: $now
    }' > "${TMP}"
fi
mv "${TMP}" "${ISSUE_STATE_FILE}"

jq -n \
  --arg handoff_version "1" \
  --arg project "${PROJECT}" \
  --arg group "${GROUP}" \
  --arg project_full "${PROJECT_FULL}" \
  --argjson iid "${ISSUE_IID}" \
  --argjson attempt_number "${ATTEMPT_NUMBER}" \
  --arg issue_title "${ISSUE_TITLE}" \
  --arg issue_mode_requested "${ISSUE_MODE_REQUESTED}" \
  --arg issue_mode_actual "${ISSUE_MODE_ACTUAL}" \
  --arg branch "${BRANCH}" \
  --arg dev_branch "${DEV_BRANCH}" \
  --arg hulat_dir "${HULAT_DIR}" \
  --arg worktree_dir "${WORKTREE_DIR}" \
  --arg log_dir "${LOG_DIR}" \
  --arg prompt_file "${LOG_DIR}/prompt.txt" \
  --arg work_branch "${WORK_BRANCH}" \
  --arg local_branch "${PREP_LOCAL_BRANCH}" \
  --arg issue_state_file "${ISSUE_STATE_FILE}" \
  --arg attempt_state_file "${ATTEMPT_STATE_FILE}" \
  --arg summary_file "${SUMMARY_FILE}" \
  --arg created_at "${NOW}" \
  '{
    handoff_version: $handoff_version,
    project: $project,
    group: $group,
    project_full: $project_full,
    iid: $iid,
    attempt_number: $attempt_number,
    issue_title: $issue_title,
    issue_mode_requested: $issue_mode_requested,
    issue_mode_actual: $issue_mode_actual,
    branch: $branch,
    dev_branch: $dev_branch,
    hulat_dir: $hulat_dir,
    worktree_dir: $worktree_dir,
    log_dir: $log_dir,
    prompt_file: $prompt_file,
    work_branch: $work_branch,
    local_branch: $local_branch,
    issue_state_file: $issue_state_file,
    attempt_state_file: $attempt_state_file,
    summary_file: $summary_file,
    created_at: $created_at
  }' > "${HANDOFF_FILE}"

cat > "${SUBAGENT_TASK_FILE}" <<EOF
# Prepared Issue Worker Handoff

RUN_PREPARED_ISSUE_WORKER

You are already inside a runtime-created prepared child worker.
Logical issue key:
${SESSION_NAME}

Role guard:
- Do NOT call sessions_spawn.
- Do NOT call sessions_history.
- Do NOT run dispatcher logic, RUN_SCHEDULED_ISSUE_CAMPAIGN, or RUN_CHILD_COMPLETION_CALLBACK.
- Do NOT load or read SKILL.md, SOUL.md, AGENTS.md, or reference files.

The dispatcher has already synced the repo, created the worktree, copied local
runtime config, built the Claude prompt, and initialized state. Run only the
prepared worker command below, then return its compact JSON result.

Handoff file:
${HANDOFF_FILE}

Required trigger/env values not persisted in the handoff:
- gitlab_token

Command to run from the executor skill directory:

\`\`\`bash
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../gitlab_single_issue_executor" && pwd)"
PROJECT="${PROJECT}" GROUP="${GROUP}" ISSUE_IID="${ISSUE_IID}" ATTEMPT_NUMBER="${ATTEMPT_NUMBER}" \\
BRANCH="${BRANCH}" DEV_BRANCH="${DEV_BRANCH}" HULAT_DIR="${HULAT_DIR}" \\
GITLAB_TOKEN="<gitlab_token from RUN_PREPARED_ISSUE_WORKER payload>" \\
HANDOFF_FILE="${HANDOFF_FILE}" PREPARED_WORKER=1 \\
bash scripts/run_prepared_worker.sh
\`\`\`

If you are about to use any tool other than Bash to run that command, stop and
run the command instead. This worker is a leaf task, not a dispatcher.
EOF

jq -c . "${HANDOFF_FILE}"
