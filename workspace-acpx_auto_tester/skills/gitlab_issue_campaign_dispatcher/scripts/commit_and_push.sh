#!/usr/bin/env bash
# commit_and_push.sh — commit the staged changes inside the repo root and
# push to the remote. On the benchmark-test (model-eval) branch this is a
# DUAL write: (1) force-push the per-attempt local branch to the single fixed
# ${WORK_BRANCH} (legacy Strategy A "latest pointer"; retired in phase 2), AND
# (2) push an IMMUTABLE per-attempt branch ${LOCAL_ATTEMPT_BRANCH} that is
# never overwritten — that is the durable artifact each pinned model run leaves
# behind for benchmarking.
#
# Required env vars:
#   WORKTREE_DIR             repo root cwd for git commands
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   LOCAL_ATTEMPT_BRANCH     "issue/<iid>-auto-fix-att<NNN>"
#   WORK_BRANCH              "issue/<iid>-auto-fix" (single remote)
#   ISSUE_TITLE              short human title for commit message
#
# Why force-push: Strategy A keeps a single MR pointing at a single
# remote branch. Each attempt overwrites that branch's tip with the
# new attempt's history. Local attempt branches are preserved in
# ${REPO_PATH}/.git/refs/heads/ for audit; only the remote moves.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${LOCAL_ATTEMPT_BRANCH:?}" "${WORK_BRANCH:?}" "${ISSUE_TITLE:?}"

cd "${WORKTREE_DIR}"

git commit -m "fix(issue-${ISSUE_IID}): ${ISSUE_TITLE} (attempt ${ATTEMPT_NUMBER_PADDED})"

# Force-push the local attempt branch to the fixed remote branch.
# Use --force-with-lease where possible; fall back to --force if the
# remote ref doesn't exist yet (first attempt).
if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
  git push --force-with-lease origin "${LOCAL_ATTEMPT_BRANCH}:${WORK_BRANCH}"
else
  git push origin "${LOCAL_ATTEMPT_BRANCH}:${WORK_BRANCH}"
fi

# eval mode: also push an IMMUTABLE per-attempt remote branch so every attempt
# (= every pinned model run) is preserved and never overwritten. LOCAL_ATTEMPT_BRANCH
# is "issue/<iid>-auto-fix-att<NNN>" (unique per attempt); push it to the same
# name on the remote (NOT force — it must never overwrite an existing ref).
#
# Idempotency guard: a same-(IID, attempt) re-run (stuck-pending eviction that
# re-feeds the IID, a lost-callback re-dispatch) can legitimately reach here with
# the immutable branch already on origin. A plain non-force push would then be
# rejected (non-fast-forward) and abort the whole script under `set -e`, which
# the executor contract misattributes to `blocked-cc` (a CC-side failure) even
# though the WORK_BRANCH force-push above already succeeded. Skip the immutable
# push when the ref exists so the re-run stays green and never overwrites the
# preserved artifact.
if git ls-remote --exit-code --heads origin "${LOCAL_ATTEMPT_BRANCH}" >/dev/null 2>&1; then
  echo "commit_and_push: immutable per-attempt branch ${LOCAL_ATTEMPT_BRANCH} already on origin; skipping immutable push (same-attempt re-run)" >&2
else
  git push origin "${LOCAL_ATTEMPT_BRANCH}:${LOCAL_ATTEMPT_BRANCH}"
fi

git rev-parse HEAD
