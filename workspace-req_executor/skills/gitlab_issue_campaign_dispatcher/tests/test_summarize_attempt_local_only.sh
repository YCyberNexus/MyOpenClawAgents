#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/summarize-local-only.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
GLAB_LOG="${TEST_ROOT}/glab.log"

mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GLAB_LOG}"
exit 99
EOF
chmod +x "${FAKE_BIN}/glab"

for workspace in workspace-req_executor workspace-acpx_auto_tester workspace-emcp; do
  source_script="${REPO_ROOT}/${workspace}/skills/gitlab_issue_campaign_dispatcher/scripts/summarize_attempt.sh"
  case_root="${TEST_ROOT}/${workspace}"
  fake_scripts="${case_root}/scripts"
  log_dir="${case_root}/log"
  issue_root="${case_root}/issue"
  summary_file="${issue_root}/summary.md"
  stderr_file="${case_root}/stderr.log"
  mkdir -p "${fake_scripts}" "${log_dir}" "${issue_root}"
  cp "${source_script}" "${fake_scripts}/summarize_attempt.sh"
  cat >"${fake_scripts}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export GITLAB_HOST=gitlab.example.test
export PROJECT_URI=group%2Frepo
EOF
  chmod +x "${fake_scripts}/summarize_attempt.sh"

  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  ISSUE_IID=42 ATTEMPT_NUMBER_PADDED=001 ISSUE_MODE=fresh \
  ATTEMPT_DIR="${issue_root}" ISSUE_ROOT="${issue_root}" \
  LOG_DIR="${log_dir}" SUMMARY_FILE="${summary_file}" \
  ATTEMPT_STATUS=done SUMMARY_POST_TO_ISSUE=true \
    bash "${fake_scripts}/summarize_attempt.sh" \
      >/dev/null 2>"${stderr_file}"

  [ -s "${summary_file}" ] \
    || { echo "${workspace} did not write its local summary" >&2; exit 1; }
  grep -Fxq 'SUMMARY_POSTED=false' "${stderr_file}" \
    || { echo "${workspace} did not report local-only summary state" >&2; exit 1; }
done

if [ -e "${GLAB_LOG}" ]; then
  echo "summarize_attempt unexpectedly invoked glab" >&2
  exit 1
fi

echo "ok summarize_attempt remains local-only in every executor workspace"
