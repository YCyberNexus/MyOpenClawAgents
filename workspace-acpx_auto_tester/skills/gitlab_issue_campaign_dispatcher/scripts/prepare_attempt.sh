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
# Legacy-path salvage:
#   On the first run after the per-(IID,attempt) worktree scheme was
#   replaced by the shared per-IID scheme, this IID's untracked scratch
#   may still live at ${WORKTREES_ROOT}/issue-<iid>-att-<NNN>/ or at the
#   even older ${RESULT_ROOT}/issue-<iid>/worktree/. This script picks
#   the most recent legacy path as a salvage source, rsync's its
#   untracked content into the freshly-created shared worktree with
#   `--ignore-existing` (so BASE_REF's tracked files and the new
#   worktree's `.git` gitfile are never overwritten), then deletes the
#   legacy paths. This preserves the "later attempts can see earlier
#   attempts' files" contract that the worktree restructure was meant to
#   provide. The same salvage shape is also applied to the local
#   pre-recreate backup when WORKTREE_REUSE=false but ${WORKTREE_DIR}
#   was a real directory before this script ran (broken registry state).
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

# ─── Identify legacy worktree paths whose untracked scratch must be
#     salvaged before they get deregistered ───────────────────────────
#
# Earlier path schemes for this IID's worktree:
#   - very old: ${RESULT_ROOT}/issue-<iid>/worktree
#                (single-worktree, pre-`issues/` nesting)
#   - intermediate: ${WORKTREES_ROOT}/issue-<iid>-att-<NNN>
#                (per-(IID,attempt), pre-shared-per-IID)
#
# Both can hold untracked scratch (Claude Code local state, intermediate
# notes, log files) that continue-mode attempts must carry forward —
# that is the whole reason the worktree was restructured to be shared
# per IID. The previous version of this script deleted legacy paths
# unconditionally, which silently discarded the very data the new
# scheme was supposed to preserve. We now collect the legacy paths
# here, pick the most recent one as a salvage source, defer deletion
# until AFTER the new shared worktree is created, then rsync untracked
# content from the salvage source into the new shared worktree with
# `--ignore-existing` (so BASE_REF's freshly-checked-out tracked files
# and the new worktree's `.git` gitfile are never overwritten).
LEGACY_SINGLE_WORKTREE_DIR="${RESULT_ROOT}/issue-${ISSUE_IID}/worktree"

LEGACY_PER_ATTEMPT_DIRS=()
for legacy_per_attempt_dir in "${WORKTREES_ROOT}/issue-${ISSUE_IID}"-att-*; do
  [ -d "${legacy_per_attempt_dir}" ] || continue
  LEGACY_PER_ATTEMPT_DIRS+=("${legacy_per_attempt_dir}")
done

# Pick salvage source: latest `-att-<NNN>` wins over the very-old
# single-worktree path because per-attempt paths are more recent.
SALVAGE_SRC=""
salvage_src_num=-1
for d in "${LEGACY_PER_ATTEMPT_DIRS[@]:-}"; do
  [ -n "${d}" ] || continue
  suffix="${d##*-att-}"
  case "${suffix}" in
    ''|*[!0-9]*) continue ;;
  esac
  n="$((10#${suffix}))"
  if [ "${n}" -gt "${salvage_src_num}" ]; then
    salvage_src_num="${n}"
    SALVAGE_SRC="${d}"
  fi
done
if [ -z "${SALVAGE_SRC}" ] && [ -d "${LEGACY_SINGLE_WORKTREE_DIR}" ]; then
  SALVAGE_SRC="${LEGACY_SINGLE_WORKTREE_DIR}"
fi

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

# When we are about to recreate the shared worktree and the existing
# path is a real directory, move it aside FIRST so its untracked
# scratch can be rsync'd back into the rebuilt worktree. The mv-aside
# MUST happen before any `git worktree remove --force` call because
# remove deletes the directory including untracked files (even when
# the registry is intact but the `.git` gitfile is missing/corrupt —
# a `registered=T + dir=present + .gitfile-broken` state would
# otherwise lose scratch silently).
#
# Stale recreate backups: if a prior run of *this very script* was
# killed between mv and the trailing rm -rf (OOM, SIGTERM, acpx kill),
# the backup lives at ${WORKTREE_DIR}.recreate-backup.<old-pid>.
# Enumerate those now so they can join the salvage chain.
WORKTREE_RECREATE_BACKUP=""
STALE_RECREATE_BACKUP=""
stale_backup_mtime=0
for stale in "${WORKTREE_DIR}.recreate-backup."*; do
  [ -d "${stale}" ] || continue
  # stat -c %Y (GNU) / stat -f %m (BSD) for mtime; pick the newest.
  mt=0
  if ts="$(stat -c %Y "${stale}" 2>/dev/null)"; then
    mt="${ts}"
  elif ts="$(stat -f %m "${stale}" 2>/dev/null)"; then
    mt="${ts}"
  fi
  if [ "${mt}" -gt "${stale_backup_mtime}" ]; then
    stale_backup_mtime="${mt}"
    STALE_RECREATE_BACKUP="${stale}"
  fi
done

if [ "${WORKTREE_REUSE}" = false ]; then
  if [ "${ATTEMPT_NUMBER}" -gt 1 ]; then
    dir_present=false; [ -e "${WORKTREE_DIR}" ] && dir_present=true
    reg_present=false; worktree_registered && reg_present=true
    echo "prepare_attempt: recreating worktree at ${WORKTREE_DIR} for attempt ${ATTEMPT_NUMBER_PADDED} (dir_present=${dir_present} registered=${reg_present}); will salvage untracked scratch after recreate" >&2
  fi
  # Salvage: if the directory exists, move it aside BEFORE we touch the
  # registry. Only then call `git worktree remove --force` on the
  # now-empty path to clear the registry entry (the `--force` flag is
  # still needed because git will otherwise refuse to remove a worktree
  # that has uncommitted changes on its active branch; but the directory
  # is already gone, so the scratch is safe).
  if [ -d "${WORKTREE_DIR}" ]; then
    WORKTREE_RECREATE_BACKUP="${WORKTREE_DIR}.recreate-backup.$$"
    mv "${WORKTREE_DIR}" "${WORKTREE_RECREATE_BACKUP}"
  elif [ -e "${WORKTREE_DIR}" ]; then
    # Non-directory (broken symlink, leftover file). Nothing meaningful
    # to salvage; remove so `git worktree add` can claim the path.
    rm -f "${WORKTREE_DIR}"
  fi
  if worktree_registered; then
    git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true
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

# ─── Salvage untracked scratch from salvage sources into the worktree ─
#
# Priority chain (first existing source wins; only one is chosen):
#   1. WORKTREE_RECREATE_BACKUP — fresh mv-aside a few lines above.
#   2. STALE_RECREATE_BACKUP   — orphan backup left by a prior crashed
#      run of this script (mv succeeded, trailing rm -rf never ran).
#   3. SALVAGE_SRC             — legacy `-att-<NNN>` or very-old
#      single-worktree path, picked above before deregistration.
#
# Sources 2 and 3 only fire when this is a genuine recreate (not the
# shared-worktree REUSE path). When REUSE=true the existing untracked
# scratch already on disk is authoritative; rsyncing from a stale
# backup or legacy path would resurrect files Claude Code deliberately
# deleted in a prior successful attempt.
#
# `rsync -rltD --ignore-existing` (no -pgo ownership flags) because:
#   - `--ignore-existing` prevents clobbering BASE_REF tracked files
#     and the new worktree's `.git` gitfile.
#   - `-rltD` excludes ownership (–pgo) to avoid non-root code-23
#     partial-transfer warnings when the backup was written by a
#     different uid.
#   - `--exclude='/.git'` blocks the source-root gitfile; the new
#     worktree already has its own correct `.git` from `git worktree
#     add`.
salvage_into_worktree() {
  local src="$1"
  if [ -z "${src}" ] || [ ! -d "${src}" ]; then
    return 0
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "prepare_attempt: rsync is required to salvage untracked scratch from ${src} but is missing on PATH" >&2
    exit 6
  fi
  echo "prepare_attempt: salvaging untracked scratch from ${src} into ${WORKTREE_DIR}" >&2
  rsync -rltD --ignore-existing \
    --exclude='/.git' \
    "${src}/" "${WORKTREE_DIR}/"
}

salvage_into_worktree "${WORKTREE_RECREATE_BACKUP}"
if [ "${WORKTREE_REUSE}" = false ]; then
  if [ -z "${WORKTREE_RECREATE_BACKUP}" ] || [ ! -d "${WORKTREE_RECREATE_BACKUP}" ]; then
    salvage_into_worktree "${STALE_RECREATE_BACKUP}"
    if [ -z "${STALE_RECREATE_BACKUP}" ] || [ ! -d "${STALE_RECREATE_BACKUP}" ]; then
      salvage_into_worktree "${SALVAGE_SRC}"
    fi
  fi
fi

# Now that any meaningful scratch has been salvaged, drop the
# pre-recreate backups, stale backups, and every legacy worktree path.
# From here on out the shared per-issue worktree at ${WORKTREE_DIR} is
# the only place this IID's untracked state lives.
for stale in "${WORKTREE_DIR}.recreate-backup."*; do
  [ -d "${stale}" ] || continue
  rm -rf "${stale}"
done
for d in "${LEGACY_PER_ATTEMPT_DIRS[@]:-}"; do
  [ -n "${d}" ] || continue
  git worktree remove --force "${d}" 2>/dev/null || true
  rm -rf "${d}"
done
if [ -e "${LEGACY_SINGLE_WORKTREE_DIR}" ]; then
  git worktree remove --force "${LEGACY_SINGLE_WORKTREE_DIR}" 2>/dev/null || true
  rm -rf "${LEGACY_SINGLE_WORKTREE_DIR}"
fi
git worktree prune

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
