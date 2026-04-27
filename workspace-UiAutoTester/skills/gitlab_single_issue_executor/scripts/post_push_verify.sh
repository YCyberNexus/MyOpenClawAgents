#!/usr/bin/env bash
# post_push_verify.sh — confirm the remote work branch contains only repo
# code, no agent artifacts. If verification fails the executor must mark the
# issue blocked and skip MR creation.
#
# Required env vars:
#   REPO_PATH      git working tree
#   WORK_BRANCH    "issue/<iid>-auto-fix"
#
# Exit codes:
#   0   remote is clean; safe to create MR
#   4   remote contains agent artifacts; caller must mark issue blocked
#
# Stdout: REMOTE_CLEAN on success
# Stderr: REMOTE_POLLUTED + offending paths on failure

set -euo pipefail

: "${REPO_PATH:?}" "${WORK_BRANCH:?}"

cd "${REPO_PATH}"
git fetch origin "${WORK_BRANCH}"

POLLUTED="$(
  git ls-tree -r --name-only "origin/${WORK_BRANCH}" \
    | grep -E '^(openclaw_log/|openclaw_state/)' || true
)"

if [ -n "${POLLUTED}" ]; then
  echo "REMOTE_POLLUTED" >&2
  echo "${POLLUTED}" >&2
  exit 4
fi

echo "REMOTE_CLEAN"
