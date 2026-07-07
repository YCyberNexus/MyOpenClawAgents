#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-env-branch.XXXXXX")"
REPO_PARENT="${TEST_ROOT}/repos"
mkdir -p "${REPO_PARENT}"

WORK_BRANCH_ACTUAL="$(
  PROJECT="req_executor_test" \
    GROUP="claw_gitlab" \
    REPO_PARENT_PATH="${REPO_PARENT}" \
    ISSUE_IID="42" \
    ATTEMPT_NUMBER="7" \
    GITLAB_HOST="gitlab-b.pxsemic.tech:30000" \
    GITLAB_API_PROTOCOL="http" \
    GITLAB_TOKEN="test-token" \
    bash -c 'source "$1"; printf "%s\n%s\n" "${WORK_BRANCH}" "${LOCAL_ATTEMPT_BRANCH}"' _ "${SKILL_DIR}/scripts/env_paths.sh"
)"

work_branch="$(printf '%s\n' "${WORK_BRANCH_ACTUAL}" | sed -n '1p')"
local_attempt_branch="$(printf '%s\n' "${WORK_BRANCH_ACTUAL}" | sed -n '2p')"

if [ "${work_branch}" != "issue/42" ]; then
  echo "expected WORK_BRANCH issue/42, got ${work_branch}" >&2
  exit 1
fi

if [ "${local_attempt_branch}" != "issue/42-att007" ]; then
  echo "expected LOCAL_ATTEMPT_BRANCH issue/42-att007, got ${local_attempt_branch}" >&2
  exit 1
fi

echo "ok env_paths derives issue-only branch names"
