#!/usr/bin/env bash
# post_push_verify.sh — confirm the remote ${WORK_BRANCH}'s MR diff contains
# only allowed issue output under ifp-result/, with no dispatcher state,
# logs, other issue subtrees, or protected test-team inputs. If verification
# fails the executor must mark the issue blocked and skip MR creation.
#
# The committed output path is:
#   ifp-result/issue-<iid>/hulat-spec-issue<iid>/
#
# Existing content on the target branch is not a leak by itself; this script
# checks the MR-style diff from origin/${BRANCH} to origin/${WORK_BRANCH}.
#
# Required env vars:
#   WORKTREE_DIR    repo root cwd
#   WORK_BRANCH     "issue/<iid>-auto-fix"
#   BRANCH          integration / target branch
#   ISSUE_IID       current issue IID
#
# Exit codes:
#   0   remote is clean; safe to create / keep MR
#   4   remote MR diff contains protected paths; caller must mark issue blocked

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${WORK_BRANCH:?}" "${BRANCH:?}" "${ISSUE_IID:?}"

cd "${WORKTREE_DIR}"
git fetch origin "${WORK_BRANCH}"
git fetch origin "${BRANCH}"

ALLOWED_OUTPUT_RE="^ifp-result/issue-${ISSUE_IID}/hulat-spec-issue${ISSUE_IID}(/|$)"
POLLUTED="$(
  git diff --name-only "origin/${BRANCH}...origin/${WORK_BRANCH}" \
    | { grep -E '^(ifp-result/|\.claude(/|$)|hulat(/|$)|ifp-data(/|$))' || true; } \
    | { grep -vE "${ALLOWED_OUTPUT_RE}" || true; }
)"

if [ -n "${POLLUTED}" ]; then
  echo "REMOTE_PROTECTED_PATHS_LEAKED" >&2
  echo "${POLLUTED}" >&2
  exit 4
fi

echo "REMOTE_CLEAN"
