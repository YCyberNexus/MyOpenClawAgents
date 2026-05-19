#!/usr/bin/env bash
# prepare_attempt.sh — ensure a per-issue linked git worktree exists for
# this IID and put it on the right starting point for the current attempt.
#
# Strategy A — single fixed remote branch ${WORK_BRANCH} ("issue/<iid>-auto-fix").
# Each attempt gets its own LOCAL branch (${LOCAL_ATTEMPT_BRANCH},
# "${WORK_BRANCH}-att${PADDED}") checked out into a SHARED per-issue
# linked worktree at ${WORKTREE_DIR}=${WORKTREES_ROOT}/issue-${ISSUE_IID}
# (note: NO -att-<NNN> suffix). On attempt 1 this script creates the
# worktree via `git worktree add -B`. On attempt N>1 it force-switches
# the already-existing worktree's checked-out branch to BASE_REF; this
# leaves untracked files in the worktree alone, so any scratch state
# `acpx claude exec` wrote during attempt N (intermediate notes, Claude
# Code's local caches, etc.) is still on disk for attempt N+1. The local
# attempt branch is force-pushed to ${WORK_BRANCH} at commit time.
# Cross-IID parallelism stays safe because different IIDs use different
# worktree paths; same-IID attempts never run concurrently (single-batch
# invariant enforced by the dispatcher's `pending_subagents` bookkeeping),
# so it is safe to reuse one worktree across attempts. The parent checkout
# at ${REPO_PATH} is never mutated by an attempt (only `git fetch` touches
# it under ${WORK_ROOT}/locks/repo.lock).
#
# Modes (env var ISSUE_MODE):
#   fresh     — base attempt on origin/${DEV_BRANCH} (clean baseline,
#               no past spec accumulation visible to Claude on TRACKED
#               files). Prior attempts' COMMITTED work on ${WORK_BRANCH}
#               is intentionally not used; however, untracked scratch
#               files left in the shared per-issue worktree by an earlier
#               attempt survive the in-place branch switch, which is
#               required so `acpx claude exec` can resume on retries.
#   continue  — base attempt on origin/${WORK_BRANCH} if it exists, else
#               downgrade to fresh (and use origin/${DEV_BRANCH})
#
# Why DEV_BRANCH and not BRANCH for fresh mode:
#   BRANCH is the integration target (e.g. master) and accumulates every
#   completed issue's spec output. Checking out from BRANCH would expose
#   Claude to past issues' files in the repo root, polluting context and
#   inviting accidental edits. DEV_BRANCH is a clean baseline (no spec
#   output) so each fresh attempt starts from zero. PRs still target
#   BRANCH — only the source baseline changes.
#
# What this script does NOT do:
#   - It does NOT mutate the parent checkout at ${REPO_PATH}. Only
#     `git fetch` runs against it; HEAD stays where clone_or_pull put it.
#   - It does NOT symlink hulat into the repo. The test team committed
#     `hulat/` to master+dev, so the worktree already contains it after
#     `git worktree add`.
#   - It does NOT copy a `.claude/` runtime config into the worktree. The
#     test team committed `.claude/` to master+dev, so the worktree
#     already contains that too.
#   - It does NOT write `.git/info/exclude`. That is `clone_or_pull.sh`'s
#     responsibility (it appends `/<basename RESULT_ROOT>/` once per clone).
#     Runtime state/logs and `.worktrees/` therefore stay locally
#     git-ignored; the current issue's output directory is force-added
#     explicitly by stage_and_guard.sh, which bypasses the exclude.
#
# Required env vars (all from env_paths.sh + glab_auth.sh + trigger):
#   REPO_PATH, BRANCH, DEV_BRANCH, ISSUE_IID, ISSUE_MODE,
#   ATTEMPT_DIR, WORKTREE_DIR, OUTPUT_DIR, LOG_DIR,
#   ATTEMPT_NUMBER_PADDED, WORK_BRANCH, LOCAL_ATTEMPT_BRANCH
#
# Output (to stdout, two lines):
#   <actual-mode>           "fresh" or "continue"
#   <local-branch-name>     ${LOCAL_ATTEMPT_BRANCH}

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${REPO_PATH:?}" "${WORK_ROOT:?}" "${BRANCH:?}" "${DEV_BRANCH:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" \
  "${ISSUE_ROOT:?}" \
  "${ATTEMPT_DIR:?}" "${WORKTREE_DIR:?}" "${OUTPUT_DIR:?}" "${LOG_DIR:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${WORK_BRANCH:?}" "${LOCAL_ATTEMPT_BRANCH:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "prepare_attempt: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

LOCK_DIR="${WORK_ROOT}/locks"
mkdir -p "${LOCK_DIR}"
exec 8>"${LOCK_DIR}/repo.lock"
flock 8

# Refresh refs. clone_or_pull.sh has already fetched, but do it again
# defensively in case this script is run standalone.
cd "${REPO_PATH}"
git fetch --prune origin

# Resolve the actual base ref.
# Fresh mode bases on DEV_BRANCH (clean baseline). Continue mode tries
# WORK_BRANCH first; if missing, downgrade to fresh on DEV_BRANCH.
BASE_REF="origin/${DEV_BRANCH}"
ACTUAL_MODE="${ISSUE_MODE}"
if [ "${ACTUAL_MODE}" = "continue" ]; then
  if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
    BASE_REF="origin/${WORK_BRANCH}"
  else
    ACTUAL_MODE=fresh
    BASE_REF="origin/${DEV_BRANCH}"
  fi
fi

# Sanity check the resolved BASE_REF actually exists. If DEV_BRANCH is
# missing on the remote, fail loudly — there is no further fallback.
if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
  echo "prepare_attempt: base ref ${BASE_REF} does not exist on origin" >&2
  echo "Check that --dev_branch=${DEV_BRANCH} is correct and the branch exists on the remote." >&2
  exit 5
fi

# One-time migration cleanup: older deployments placed a linked worktree
# at ifp-result/issue-<iid>/worktree (BEFORE the issues/ nesting — the
# old path was ${RESULT_ROOT}/issue-<iid>/worktree). Remove it if present
# so stale worktree metadata cannot hold old local attempt branches open.
LEGACY_WORKTREE_DIR="${RESULT_ROOT}/issue-${ISSUE_IID}/worktree"
if [ -e "${LEGACY_WORKTREE_DIR}" ]; then
  git worktree remove --force "${LEGACY_WORKTREE_DIR}" 2>/dev/null || true
  rm -rf "${LEGACY_WORKTREE_DIR}"
fi

# Migration cleanup: an earlier scheme used per-attempt worktree paths
# at ${WORKTREES_ROOT}/issue-<iid>-att-<NNN>/. We now reuse ONE shared
# worktree at ${WORKTREES_ROOT}/issue-<iid>/ across every attempt of an
# IID, so drop any leftover per-attempt directories (with their git
# registry entries) before we touch the shared path. A literal-`*` shell
# loop with a no-match guard avoids spurious removal of the new path.
for legacy_per_attempt_dir in "${WORKTREES_ROOT}/issue-${ISSUE_IID}"-att-*; do
  [ -e "${legacy_per_attempt_dir}" ] || continue
  git worktree remove --force "${legacy_per_attempt_dir}" 2>/dev/null || true
  rm -rf "${legacy_per_attempt_dir}"
done

# Look up whether ${WORKTREE_DIR} is currently a registered linked
# worktree (the registry lives in ${REPO_PATH}/.git/worktrees/...).
worktree_registered() {
  git worktree list --porcelain 2>/dev/null \
    | awk '$1 == "worktree" { print $2 }' \
    | grep -qxF "${WORKTREE_DIR}"
}

# Reuse the existing per-issue worktree if it looks healthy
# (`.git` is a file pointing at the registry AND the registry knows the
# path). Otherwise fall through to a clean recreate.
WORKTREE_REUSE=false
if [ -f "${WORKTREE_DIR}/.git" ] && worktree_registered; then
  WORKTREE_REUSE=true
fi

if [ "${WORKTREE_REUSE}" = false ]; then
  # Recreate path. This is normal on attempt 1 of an IID, but on later
  # attempts it implies prior scratch state was lost (operator removed the
  # directory, the registry was pruned, etc.). Log to stderr so the caller
  # captures it in wrapper.log for post-mortems — otherwise "Claude lost
  # its memory across attempts" symptoms are hard to attribute.
  if [ "${ATTEMPT_NUMBER}" -gt 1 ]; then
    dir_present=false; [ -e "${WORKTREE_DIR}" ] && dir_present=true
    reg_present=false; worktree_registered && reg_present=true
    echo "prepare_attempt: recreating worktree at ${WORKTREE_DIR} for attempt ${ATTEMPT_NUMBER_PADDED} (dir_present=${dir_present} registered=${reg_present}); any untracked scratch from prior attempts will be lost" >&2
  fi
  # Defensive cleanup for half-broken state — either an orphan directory
  # without a registry entry, or a registry entry pointing at a missing
  # directory. Then prune before recreating.
  if [ -e "${WORKTREE_DIR}" ] || worktree_registered; then
    git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true
    rm -rf "${WORKTREE_DIR}"
  fi
fi
git worktree prune

# Ensure the cross-attempt ISSUE_ROOT exists for state.json /
# attempt_state.json / summary.md. The log dir itself lives inside the
# worktree (see below) so it is recreated AFTER the worktree is on the
# correct base ref.
mkdir -p "${ATTEMPT_DIR}"

if [ "${WORKTREE_REUSE}" = true ]; then
  # In-place branch switch: create or reset ${LOCAL_ATTEMPT_BRANCH} at
  # ${BASE_REF} inside the existing worktree, overwriting any tracked
  # files modified by the previous attempt. Untracked files (Claude
  # Code's scratch state, intermediate notes, etc.) are NOT touched by
  # `git checkout` and therefore survive into this attempt — that is the
  # whole point of sharing a worktree across attempts. Prior local
  # attempt branches (e.g. ${WORK_BRANCH}-att001) remain in the registry
  # for audit; only the worktree's HEAD moves.
  git -C "${WORKTREE_DIR}" checkout -B "${LOCAL_ATTEMPT_BRANCH}" "${BASE_REF}" --force
else
  # First attempt for this IID (or recovery from a broken state). Create
  # the shared per-issue linked worktree branched from ${BASE_REF}. This
  # is the cwd Claude Code runs in; OUTPUT_DIR and LOG_DIR are inside it.
  # OUTPUT_DIR is force-added by stage_and_guard.sh after the run;
  # LOG_DIR's prompt.txt + claude_result.txt are force-added by the same
  # script, the remaining log files stay locally ignored via the
  # repository `.git/info/exclude` entry.
  mkdir -p "$(dirname "${WORKTREE_DIR}")"
  git worktree add -B "${LOCAL_ATTEMPT_BRANCH}" "${WORKTREE_DIR}" "${BASE_REF}"
fi
mkdir -p "${OUTPUT_DIR}"

# Recreate ONLY the current attempt's log dir so stale evidence from a
# same-(IID, attempt) rerun is not mixed with the current run. The
# worktree is now on ${BASE_REF}; in continue mode that ref may already
# contain prior attempts' tracked `log/attempt-<earlier>/` directories,
# but those use different attempt numbers and so do not collide with the
# current LOG_DIR. Other attempts' log dirs that exist as UNTRACKED files
# in the shared worktree from earlier runs are NOT touched here — only
# the exact current-attempt LOG_DIR is reset. The rm is defensive against
# an exact same-(IID, attempt) rerun (rare — attempt numbers are
# monotonic).
if [ -d "${LOG_DIR}" ]; then
  rm -rf "${LOG_DIR}"
fi
mkdir -p "${LOG_DIR}"

flock -u 8

echo "${ACTUAL_MODE}"
echo "${LOCAL_ATTEMPT_BRANCH}"
