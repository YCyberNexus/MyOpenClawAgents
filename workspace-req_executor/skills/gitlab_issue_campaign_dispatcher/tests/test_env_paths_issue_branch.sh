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

derived_project_identity="$(
  PROJECT="req_executor_test" \
    GROUP="claw_gitlab" \
    PROJECT_FULL="stale_group/stale_project" \
    PROJECT_URI="stale_group%2Fstale_project" \
    REPO_PARENT_PATH="${REPO_PARENT}" \
    ISSUE_IID="42" \
    EXECUTION_ID="9" \
    GITLAB_HOST="local-gitlab.invalid:9443" \
    GITLAB_API_PROTOCOL="https" \
    GITLAB_TOKEN="test-token" \
    REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="local-gitlab.invalid:9443" \
    bash -c 'source "$1"; printf "%s\n%s\n" "${PROJECT_FULL}" "${PROJECT_URI}"' \
      _ "${SKILL_DIR}/scripts/env_paths.sh"
)"
[ "$(printf '%s\n' "${derived_project_identity}" | sed -n '1p')" = \
    "claw_gitlab/req_executor_test" ] \
  || { echo "ambient PROJECT_FULL overrode GROUP + PROJECT" >&2; exit 1; }
[ "$(printf '%s\n' "${derived_project_identity}" | sed -n '2p')" = \
    "claw_gitlab%2Freq_executor_test" ] \
  || { echo "ambient PROJECT_URI was not re-derived" >&2; exit 1; }

project_full_only_identity="$(
  env -u GROUP \
    PROJECT="req_executor_test" \
    PROJECT_FULL="division/platform/req_executor_test" \
    PROJECT_URI="stale_project_uri" \
    REPO_PARENT_PATH="${REPO_PARENT}" \
    ISSUE_IID="42" \
    EXECUTION_ID="10" \
    GITLAB_HOST="local-gitlab.invalid:9443" \
    GITLAB_API_PROTOCOL="https" \
    GITLAB_TOKEN="test-token" \
    REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
    REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="local-gitlab.invalid:9443" \
    bash -c 'source "$1"; printf "%s\n%s\n" "${PROJECT_FULL}" "${PROJECT_URI}"' \
      _ "${SKILL_DIR}/scripts/env_paths.sh"
)"
[ "$(printf '%s\n' "${project_full_only_identity}" | sed -n '1p')" = \
    "division/platform/req_executor_test" ] \
  || { echo "PROJECT_FULL-only compatibility was broken" >&2; exit 1; }
[ "$(printf '%s\n' "${project_full_only_identity}" | sed -n '2p')" = \
    "division%2Fplatform%2Freq_executor_test" ] \
  || { echo "PROJECT_FULL-only URI was not re-derived" >&2; exit 1; }

echo "ok env_paths derives stable issue branches and isolated execution paths"
