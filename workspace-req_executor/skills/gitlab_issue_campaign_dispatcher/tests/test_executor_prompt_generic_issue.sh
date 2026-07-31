#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROMPT_TEMPLATE="${SKILL_DIR}/references/executor_prompt.md"
BUILD_PROMPT="${SKILL_DIR}/scripts/build_prompt.sh"
RUN_SCRIPT="${SKILL_DIR}/scripts/run_acpx_attempt.sh"
ATTEMPT_WRAPPER="${SKILL_DIR}/scripts/run_executor_attempt.sh"
DISPATCH_SINGLE="${SKILL_DIR}/scripts/dispatch_single_issue.sh"
DISPATCH_PREPARE="${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
PREPARE_ATTEMPT="${SKILL_DIR}/scripts/prepare_attempt.sh"
ENV_PATHS="${SKILL_DIR}/scripts/env_paths.sh"
SKILL_FILE="${SKILL_DIR}/SKILL.md"

rendered_block="$(awk '
  /^# REQ_EXECUTOR_EXECUTOR_PROMPT_V1$/ { found=1 }
  found {
    if ($0 == "# REQ_EXECUTOR_EXECUTOR_PROMPT_V1_END") { exit }
    print
  }
' "${PROMPT_TEMPLATE}")"

fail() {
  echo "$1" >&2
  exit 1
}

[ -n "${rendered_block}" ] || fail "rendered executor prompt block was not found"

grep -Fq 'task=payload,' "${SKILL_FILE}" \
  || fail "SKILL.md must pass the rendered executor prompt through sessions_spawn task"
for forbidden_spawn_form in 'sessions_spawn(payload=' 'timeoutSeconds=' 'runTimeoutSeconds='; do
  if grep -Fq "${forbidden_spawn_form}" "${SKILL_FILE}" "${PROMPT_TEMPLATE}"; then
    fail "executor contract still contains unsupported sessions_spawn form: ${forbidden_spawn_form}"
  fi
done

for old_term in \
  "hu""lat" \
  "i""fp-""data" \
  "DATA_""BASENAME" \
  "data_""basename" \
  "RESULT_""BASENAME" \
  "result_""basename" \
  "UI_""ACCOUNTS_""RELPATH" \
  "ui_""accounts_""relpath" \
  "i""fp-""result" \
  "a""cpx_auto_""tester" \
  "TASK_OUTPUT_DIR"
do
  if printf '%s\n' "${rendered_block}" | grep -Fqi "${old_term}"; then
    fail "outer executor prompt still contains legacy term: ${old_term}"
  fi
done

if ! printf '%s\n' "${rendered_block}" | grep -Fq "run_acpx_attempt.sh"; then
  fail "outer executor prompt no longer delegates acpx execution to run_acpx_attempt.sh"
fi
if ! printf '%s\n' "${rendered_block}" | grep -Fq "run_executor_attempt.sh"; then
  fail "outer executor prompt no longer delegates the whole attempt to run_executor_attempt.sh"
fi
if ! printf '%s\n' "${rendered_block}" \
    | grep -Fq 'REPO_PARENT_PATH= REPO_PATH={REPO_PATH} \'; then
  fail "outer executor prompt must clear an inherited clone parent before using its fixed repo path"
fi
if ! printf '%s\n' "${rendered_block}" \
    | grep -Fq 'EXPECTED_COMMIT_PARENT_SHA={EXPECTED_COMMIT_PARENT_SHA} \'; then
  fail "outer executor prompt must keep the commit parent separate from the remote push lease"
fi
if ! printf '%s\n' "${rendered_block}" \
    | grep -Fq 'DEPENDENCY_CONTRACT_VERSION={DEPENDENCY_CONTRACT_VERSION} \'; then
  fail "outer executor prompt must pass the dependency contract version"
fi
if ! printf '%s\n' "${rendered_block}" \
    | grep -Fq 'DEPENDENCY_PLAN_SHA256={DEPENDENCY_PLAN_SHA256} \'; then
  fail "outer executor prompt must pass the frozen DAG plan identity"
fi
if [ ! -x "${ATTEMPT_WRAPPER}" ]; then
  fail "run_executor_attempt.sh is missing or not executable"
fi

if printf '%s\n' "${rendered_block}" | grep -Fq "{GITLAB_TOKEN}"; then
  fail "outer executor prompt must not render the GitLab token into subagent context"
fi

if printf '%s\n' "${rendered_block}" | grep -Eq '(^|[[:space:]])GITLAB_TOKEN='; then
  fail "outer executor prompt must not pass the GitLab token to executor scripts"
fi

for issue_controlled_placeholder in \
  '{ISSUE_TITLE}' '{ISSUE_TITLE_QUOTED}' '{ISSUE_URL}' \
  '{ISSUE_LABELS}' '{ISSUE_BODY}' '<issue>'
do
  if printf '%s\n' "${rendered_block}" \
      | grep -Fq "${issue_controlled_placeholder}"; then
    fail "outer executor prompt exposes Issue-controlled text: ${issue_controlled_placeholder}"
  fi
done

if ! grep -Fq "GitLab credentials are never rendered into this payload" \
    "${PROMPT_TEMPLATE}"; then
  fail "outer executor prompt must document private credential resolution"
fi

for removed_wiki_term in \
  "upload_attempt_artifacts.sh" \
  "WIKI evidence" \
  "Do NOT skip Wiki" \
  "attempt wiki artifact publication"
do
  if printf '%s\n' "${rendered_block}" | grep -Fq "${removed_wiki_term}"; then
    fail "outer executor prompt still publishes attempt evidence to wiki: ${removed_wiki_term}"
  fi
done

grep -Fq '"${ACPX_EXECUTABLE}" --auth-policy skip claude exec -f "${prompt_file}"' \
  "${RUN_SCRIPT}" \
  || fail "run_acpx_attempt.sh no longer uses its pinned acpx executable"
grep -Fq '"${TIMEOUT_EXECUTABLE}" --kill-after=30s "${ACPX_TIMEOUT_SECONDS}s"' \
  "${RUN_SCRIPT}" \
  || fail "run_acpx_attempt.sh no longer uses its pinned timeout executable"

for old_inner_term in \
  "Hu""lat materials" \
  "Knowledge base:" \
  "hu""lat/" \
  "DATA_""BASENAME" \
  "RESULT_""BASENAME" \
  "UI_""ACCOUNTS_""RELPATH" \
  "ui_""accounts_""relpath" \
  "i""fp-""result" \
  "i""fp-""data"
do
  if grep -Fq "${old_inner_term}" "${BUILD_PROMPT}"; then
    fail "inner Claude Code prompt builder still contains legacy term: ${old_inner_term}"
  fi
done

grep -Fq 'Do NOT request nested worktree or branch isolation' "${BUILD_PROMPT}" \
  || fail "inner Claude Code prompt must forbid nested worktree isolation"
grep -Fq 'isolation: "worktree"' "${BUILD_PROMPT}" \
  || fail "inner Claude Code prompt must name the forbidden Task isolation argument"
grep -Fq 'omit the isolation field' "${BUILD_PROMPT}" \
  || fail "inner Claude Code prompt must tell Task callers how to use the current worktree"

for script_term in \
  "data_""basename" \
  "DATA_""BASENAME" \
  "result_""basename" \
  "RESULT_""BASENAME" \
  "ui_""accounts_""relpath" \
  "UI_""ACCOUNTS_""RELPATH" \
  "HU""LAT_""DIR" \
  "DATA_""DIR" \
  "i""fp-""result" \
  "i""fp-""data"
do
  if grep -Fq "${script_term}" "${DISPATCH_SINGLE}" "${DISPATCH_PREPARE}" "${ENV_PATHS}"; then
    fail "trigger/path scripts still expose legacy data-dir term: ${script_term}"
  fi
done

for prepare_term in \
  "\"hu""lat\"" \
  "\"\${DATA_""BASENAME}\"" \
  "--exclude='/hu""lat'" \
  "--exclude=\"/\${DATA_""BASENAME}\"" \
  "i""fp-""data"
do
  if grep -Fq -- "${prepare_term}" "${PREPARE_ATTEMPT}"; then
    fail "prepare_attempt.sh still treats old shared data paths as runtime scaffolding: ${prepare_term}"
  fi
done

echo "ok executor prompts are generic issue prompts"
