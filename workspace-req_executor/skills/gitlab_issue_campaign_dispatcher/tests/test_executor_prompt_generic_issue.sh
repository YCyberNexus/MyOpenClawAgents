#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROMPT_TEMPLATE="${SKILL_DIR}/references/executor_prompt.md"
BUILD_PROMPT="${SKILL_DIR}/scripts/build_prompt.sh"
RUN_SCRIPT="${SKILL_DIR}/scripts/run_acpx_attempt.sh"
DISPATCH_SINGLE="${SKILL_DIR}/scripts/dispatch_single_issue.sh"
DISPATCH_PREPARE="${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
PREPARE_ATTEMPT="${SKILL_DIR}/scripts/prepare_attempt.sh"
ENV_PATHS="${SKILL_DIR}/scripts/env_paths.sh"

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

if ! printf '%s\n' "${rendered_block}" | grep -Fq "GITLAB_TOKEN={GITLAB_TOKEN}"; then
  fail "outer executor prompt must render the GitLab token into subagent context"
fi

if ! printf '%s\n' "${rendered_block}" | grep -Fq "PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \\"; then
  fail "outer executor prompt must tell the subagent to pass GitLab token env vars"
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

if ! grep -Fq 'acpx --auth-policy skip claude exec -f "${prompt_file}"' "${RUN_SCRIPT}"; then
  fail "run_acpx_attempt.sh acpx invocation changed unexpectedly"
fi

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
