#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TARGET_WORKSPACE="${TARGET_WORKSPACE:-workspace-req_executor}"
SKILL_DIR="${REPO_ROOT}/${TARGET_WORKSPACE}/skills/gitlab_issue_campaign_dispatcher"
case "${TARGET_WORKSPACE}" in
  workspace-req_executor) AGENT_PREFIX=req_executor ;;
  workspace-acpx_auto_tester|workspace-emcp) AGENT_PREFIX=acpx_auto_tester ;;
  *) echo "unsupported TARGET_WORKSPACE=${TARGET_WORKSPACE}" >&2; exit 2 ;;
esac
export AGENT_PREFIX
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/build-prompt-comments.XXXXXX")"
FAKE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
REPO_PATH="${TEST_ROOT}/repo"
WORKTREE_DIR="${REPO_PATH}/worktree"
GLAB_LOG="${TEST_ROOT}/glab.log"

mkdir -p "${FAKE_SCRIPTS}" "${FAKE_BIN}" "${WORKTREE_DIR}"
cp "${SKILL_DIR}/scripts/build_prompt.sh" "${FAKE_SCRIPTS}/build_prompt.sh"

cat >"${FAKE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export GITLAB_HOST=gitlab.example.test
export PROJECT_URI=group%2Frepo
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GLAB_LOG}"
case "$*" in
  *'/notes?sort=asc&order_by=created_at')
    jq -cn --arg prefix "${AGENT_PREFIX}" '[
      {system:false,body:"请同时修复评论里提到的边界条件"},
      {system:true,body:"changed label"},
      {system:false,body:("<!-- " + $prefix + ":attempt-summary v2 attempt=001 -->\n旧执行总结")},
      {system:false,body:("<!-- " + $prefix + ":attempt-wiki-artifacts v1 attempt=001 -->\n旧证据链接")}
    ]'
    ;;
  *'/issues/42')
    jq -cn '{title:"测试标题",description:"测试描述"}'
    ;;
  *)
    echo "unexpected glab invocation: $*" >&2
    exit 91
    ;;
esac
EOF
chmod +x "${FAKE_BIN}/glab" "${FAKE_SCRIPTS}/build_prompt.sh"

run_builder() {
  local mode="$1" log_dir="${TEST_ROOT}/log-${1}"
  PATH="${FAKE_BIN}:${PATH}" \
  GLAB_LOG="${GLAB_LOG}" \
  ISSUE_IID=42 ISSUE_MODE="${mode}" LOG_DIR="${log_dir}" \
  REPO_PATH="${REPO_PATH}" WORKTREE_DIR="${WORKTREE_DIR}" \
  OUTPUT_DIR="${WORKTREE_DIR}/output" WORK_BRANCH=issue/42 BRANCH=main \
  DEV_BRANCH=dev RESULT_BASENAME=ifp-result DATA_BASENAME=ifp-data \
  UI_ACCOUNTS='[]' \
    bash "${FAKE_SCRIPTS}/build_prompt.sh" >/dev/null
  printf '%s\n' "${log_dir}/prompt.txt"
}

fresh_prompt="$(run_builder fresh)"
grep -Fq '# Issue comments (non-system, chronological)' "${fresh_prompt}"
grep -Fq '请同时修复评论里提到的边界条件' "${fresh_prompt}"
if grep -Fq '旧执行总结' "${fresh_prompt}" \
    || grep -Fq '旧证据链接' "${fresh_prompt}" \
    || grep -Fq 'changed label' "${fresh_prompt}"; then
  echo "fresh prompt included an excluded system/agent note" >&2
  exit 1
fi

continue_prompt="$(run_builder continue)"
grep -Fq "# Historical run summaries (from older ${AGENT_PREFIX} runs)" \
  "${continue_prompt}"
grep -Fq '旧执行总结' "${continue_prompt}"
grep -Fq '请同时修复评论里提到的边界条件' "${continue_prompt}"
if grep -Fq '旧证据链接' "${continue_prompt}" \
    || grep -Fq 'changed label' "${continue_prompt}"; then
  echo "continue prompt included an excluded system/artifact note" >&2
  exit 1
fi

[ "$(grep -Fc '/notes?sort=asc&order_by=created_at' "${GLAB_LOG}")" -eq 2 ] \
  || { echo "both prompt modes must fetch issue comments" >&2; exit 1; }

echo "ok ${TARGET_WORKSPACE} build_prompt includes issue comments in fresh and continue modes"
