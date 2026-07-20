#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-env-branch.XXXXXX")"
REPO_PARENT="${TEST_ROOT}/repos"
mkdir -p "${REPO_PARENT}"

derive_paths() {
  local execution_id="$1"
  PROJECT="req_executor_test" \
    GROUP="claw_gitlab" \
    REPO_PARENT_PATH="${REPO_PARENT}" \
    ISSUE_IID="42" \
    EXECUTION_ID="${execution_id}" \
    GITLAB_HOST="local-gitlab.invalid:9443" \
    GITLAB_API_PROTOCOL="https" \
    GITLAB_TOKEN="test-token" \
    REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="local-gitlab.invalid:9443" \
    bash -c 'source "$1"; printf "%s\n%s\n%s\n" "${WORK_BRANCH}" "${LOCAL_ISSUE_BRANCH}" "${LOG_DIR}"' _ "${SKILL_DIR}/scripts/env_paths.sh"
}

PATHS_EXECUTION_7="$(derive_paths 7)"
PATHS_EXECUTION_8="$(derive_paths 8)"

work_branch="$(printf '%s\n' "${PATHS_EXECUTION_7}" | sed -n '1p')"
local_issue_branch="$(printf '%s\n' "${PATHS_EXECUTION_7}" | sed -n '2p')"
issue_log_dir="$(printf '%s\n' "${PATHS_EXECUTION_7}" | sed -n '3p')"

if [ "${work_branch}" != "issue/42" ]; then
  echo "expected WORK_BRANCH issue/42, got ${work_branch}" >&2
  exit 1
fi

if [ "${local_issue_branch}" != "issue/42" ]; then
  echo "expected LOCAL_ISSUE_BRANCH issue/42, got ${local_issue_branch}" >&2
  exit 1
fi

case "${issue_log_dir}" in
  */.req_executor/.worktrees/issue-42/.req_executor/issue-42/log/execution-7) ;;
  *) echo "unexpected execution-scoped log path: ${issue_log_dir}" >&2; exit 1 ;;
esac

if [ "$(printf '%s\n' "${PATHS_EXECUTION_7}" | sed -n '1,2p')" != \
     "$(printf '%s\n' "${PATHS_EXECUTION_8}" | sed -n '1,2p')" ]; then
  echo "different executions derived different issue branches" >&2
  exit 1
fi
case "$(printf '%s\n' "${PATHS_EXECUTION_8}" | sed -n '3p')" in
  */.req_executor/.worktrees/issue-42/.req_executor/issue-42/log/execution-8) ;;
  *) echo "second execution did not receive an isolated log path" >&2; exit 1 ;;
esac

echo "ok env_paths derives stable issue branches and isolated execution paths"
