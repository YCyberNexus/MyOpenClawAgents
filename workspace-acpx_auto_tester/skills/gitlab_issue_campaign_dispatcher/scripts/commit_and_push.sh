#!/usr/bin/env bash
# commit_and_push.sh — commit the staged changes inside the repo root and
# push to the remote. On the benchmark-test (model-eval) branch each attempt
# (= each pinned model run) publishes exactly ONE remote branch: the IMMUTABLE
# per-attempt branch ${LOCAL_ATTEMPT_BRANCH} ("issue/<iid>-auto-fix-att<NNN>"),
# which is never overwritten and is the durable artifact each run leaves behind
# for benchmarking. The legacy mutable "latest pointer" ${WORK_BRANCH}
# ("issue/<iid>-auto-fix") is NO LONGER pushed — it would only be a redundant
# force-overwritten copy of the highest-numbered attempt branch. WORK_BRANCH
# survives solely as the naming prefix env_paths.sh derives LOCAL_ATTEMPT_BRANCH
# from; this script never touches it.
#
# Required env vars:
#   WORKTREE_DIR             repo root cwd for git commands
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   LOCAL_ATTEMPT_BRANCH     "issue/<iid>-auto-fix-att<NNN>" (the single remote)
#   ISSUE_TITLE              short human title for commit message
#
# Why a plain (non-force) push: the per-attempt branch name is unique per
# attempt, so the first push of each attempt always creates a new remote ref
# and never overwrites a prior attempt's preserved history.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${LOCAL_ATTEMPT_BRANCH:?}" "${ISSUE_TITLE:?}"

cd "${WORKTREE_DIR}"

git commit -m "fix(issue-${ISSUE_IID}): ${ISSUE_TITLE} (attempt ${ATTEMPT_NUMBER_PADDED})"

# Push an IMMUTABLE per-attempt remote branch so every attempt (= every pinned
# model run) is preserved and never overwritten. LOCAL_ATTEMPT_BRANCH is
# "issue/<iid>-auto-fix-att<NNN>" (unique per attempt); push it to the same
# name on the remote (NOT force — it must never overwrite an existing ref).
#
# Idempotency guard: a same-(IID, attempt) re-run (stuck-pending eviction that
# re-feeds the IID, a lost-callback re-dispatch) can legitimately reach here with
# the immutable branch already on origin. A plain non-force push would then be
# rejected (non-fast-forward) and abort the whole script under `set -e`, which
# the executor contract misattributes to `blocked-cc` (a CC-side failure). Skip
# the immutable push when the ref exists so the re-run stays green and never
# overwrites the preserved artifact.
if git ls-remote --exit-code --heads origin "${LOCAL_ATTEMPT_BRANCH}" >/dev/null 2>&1; then
  echo "commit_and_push: immutable per-attempt branch ${LOCAL_ATTEMPT_BRANCH} already on origin; skipping immutable push (same-attempt re-run)" >&2
else
  git push origin "${LOCAL_ATTEMPT_BRANCH}:${LOCAL_ATTEMPT_BRANCH}"
fi

git rev-parse HEAD
