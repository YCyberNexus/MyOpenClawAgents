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
# the already-existing worktree's checked-out branch to BASE_REF; the
# checkout itself leaves untracked files alone. Continue mode restores the
# same-IID runtime subtree for resume, while fresh reset mode quarantines
# that subtree before recreating empty output/log directories. The local
# attempt branch is force-pushed to ${WORK_BRANCH} at commit time.
# Cross-IID parallelism stays safe because different IIDs use different
# worktree paths; same-IID attempts never run concurrently (single-batch
# invariant enforced by the dispatcher's `pending_subagents` bookkeeping),
# so it is safe to reuse one worktree across attempts. The parent checkout
# at ${REPO_PATH} is never mutated by an attempt (only `git fetch` touches
# it under ${WORK_ROOT}/locks/repo.lock).
#
# Mode (env var ISSUE_MODE): always `fresh` on benchmark-test — every attempt
#   bases on origin/${DEV_BRANCH} (clean baseline, no past spec accumulation
#   from other issues). continue / resume is disabled on this branch. After the
#   base checkout, shared test-team configuration paths (`.claude/`, `hulat/`,
#   and `${DATA_BASENAME}/`) are refreshed from the latest origin/${DEV_BRANCH}.
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
#   `--ignore-existing` while excluding shared config paths (so BASE_REF's
#   tracked files, the latest DEV_BRANCH config, and the new worktree's
#   `.git` gitfile are never overwritten), then archives the legacy paths
#   under `${WORKTREES_ROOT}/.preserved-legacy/`. This
#   preserves the "later attempts can see earlier attempts' files" contract
#   that the worktree restructure was meant to provide without physically
#   deleting prior attempt files. The same salvage shape is also applied to
#   the local pre-recreate backup when WORKTREE_REUSE=false but
#   ${WORKTREE_DIR} was a real directory before this script ran (broken
#   registry state).
#
# Branch-switch preservation:
#   Reusing the shared per-IID worktree is not enough by itself: `git
#   checkout -B ... --force` can remove files that are tracked on the prior
#   attempt branch but absent from the next BASE_REF, while leaving untracked
#   files alone. Before an in-place branch switch on attempt N>1, this script
#   snapshots the current `${RESULT_BASENAME}/issue-<iid>/` subtree, archives
#   it, and then quarantines any active same-IID runtime subtree that survived
#   checkout, so old files are not physically deleted but also do not
#   contaminate the fresh run. (benchmark-test is fresh-only; there is no
#   continue-mode restore of that snapshot.)
#
# Shared config freshness:
#   Test-team-owned `.claude/`, `hulat/`, and `${DATA_BASENAME}/` may change on
#   DEV_BRANCH while an issue's WORK_BRANCH is still being reviewed. Every
#   attempt refreshes those tracked paths from the just-fetched
#   origin/${DEV_BRANCH} after the base checkout and before acpx runs. This
#   keeps continue-mode attempts on the latest runner/materials config without
#   changing the resume base for issue output/log history.
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
  fresh) ;;
  *)
    echo "prepare_attempt: ISSUE_MODE must be fresh (continue is disabled on benchmark-test), got '${ISSUE_MODE}'" >&2
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
git fetch --prune origin >&2

# Resolve the base ref. benchmark-test runs every attempt FRESH from the clean
# DEV_BRANCH baseline (no past spec accumulation from other issues); continue /
# resume is disabled, so there is no WORK_BRANCH / prior-attempt-branch base.
BASE_REF="origin/${DEV_BRANCH}"
ACTUAL_MODE="${ISSUE_MODE}"

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
# killed after mv but before the backup was archived (OOM, SIGTERM,
# acpx kill), the backup lives at ${WORKTREE_DIR}.recreate-backup.<old-pid>.
# Enumerate those now so they can join the salvage chain.
WORKTREE_RECREATE_BACKUP=""
WORKTREE_SWITCH_BACKUP=""
STALE_RECREATE_BACKUP=""
STALE_SWITCH_BACKUP=""
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
stale_backup_mtime=0
for stale in "${WORKTREE_DIR}.switch-backup."*; do
  [ -d "${stale}" ] || continue
  mt=0
  if ts="$(stat -c %Y "${stale}" 2>/dev/null)"; then
    mt="${ts}"
  elif ts="$(stat -f %m "${stale}" 2>/dev/null)"; then
    mt="${ts}"
  fi
  if [ "${mt}" -gt "${stale_backup_mtime}" ]; then
    stale_backup_mtime="${mt}"
    STALE_SWITCH_BACKUP="${stale}"
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
    # Non-directory (broken symlink, leftover file). Move it aside so
    # `git worktree add` can claim the path without deleting operator data.
    WORKTREE_OBSTRUCTION_BACKUP="${WORKTREE_DIR}.obstruction-backup.$$"
    mv "${WORKTREE_DIR}" "${WORKTREE_OBSTRUCTION_BACKUP}"
  fi
  if worktree_registered; then
    git worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
fi
git worktree prune >&2

# Ensure the cross-attempt ISSUE_ROOT exists for state.json /
# attempt_state.json / summary.md. The log dir itself lives inside the
# worktree (see below) so it is recreated AFTER the worktree is on the
# correct base ref.
mkdir -p "${ATTEMPT_DIR}"

ISSUE_WORKTREE_REL="${RESULT_BASENAME}/issue-${ISSUE_IID}"
ISSUE_WORKTREE_RUNTIME_DIR="${WORKTREE_DIR}/${ISSUE_WORKTREE_REL}"

snapshot_issue_runtime_tree() {
  local dst="$1"
  if [ ! -d "${ISSUE_WORKTREE_RUNTIME_DIR}" ]; then
    return 0
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "prepare_attempt: rsync is required to preserve prior attempt files from ${ISSUE_WORKTREE_RUNTIME_DIR} but is missing on PATH" >&2
    exit 6
  fi
  mkdir -p "${dst}/${RESULT_BASENAME}"
  echo "prepare_attempt: preserving prior attempt files from ${ISSUE_WORKTREE_RUNTIME_DIR} before branch switch" >&2
  rsync -rltD "${ISSUE_WORKTREE_RUNTIME_DIR}/" "${dst}/${ISSUE_WORKTREE_REL}/"
}

PRESERVED_ATTEMPT_ROOT="${WORKTREES_ROOT}/.preserved-attempts/issue-${ISSUE_IID}"
archive_switch_backup() {
  local src="$1"
  local label="$2"
  if [ -z "${src}" ] || [ ! -d "${src}" ]; then
    return 0
  fi
  mkdir -p "${PRESERVED_ATTEMPT_ROOT}"
  local dest="${PRESERVED_ATTEMPT_ROOT}/${label}.preserved.$$"
  local suffix=1
  while [ -e "${dest}" ]; do
    dest="${PRESERVED_ATTEMPT_ROOT}/${label}.preserved.$$.${suffix}"
    suffix=$((suffix + 1))
  done
  mv "${src}" "${dest}"
  echo "prepare_attempt: archived prior attempt files from ${src} at ${dest}" >&2
}

archive_fresh_active_runtime_tree() {
  if [ ! -d "${ISSUE_WORKTREE_RUNTIME_DIR}" ]; then
    return 0
  fi

  local tracked_paths
  if ! tracked_paths="$(git -C "${WORKTREE_DIR}" ls-files -- "${ISSUE_WORKTREE_REL}")"; then
    echo "prepare_attempt: failed to inspect tracked paths under ${ISSUE_WORKTREE_REL}" >&2
    exit 7
  fi
  if [ -n "${tracked_paths}" ]; then
    echo "prepare_attempt: fresh reset refusing to quarantine ${ISSUE_WORKTREE_RUNTIME_DIR} because ${BASE_REF} has tracked files under ${ISSUE_WORKTREE_REL}" >&2
    echo "prepare_attempt: tracked paths under fresh runtime subtree:" >&2
    printf '%s\n' "${tracked_paths}" >&2
    exit 7
  fi

  archive_switch_backup "${ISSUE_WORKTREE_RUNTIME_DIR}" "fresh-active-before-attempt-${ATTEMPT_NUMBER_PADDED}"
}

refresh_shared_config_from_dev() {
  local config_ref="origin/${DEV_BRANCH}"
  local config_paths=(".claude" "hulat" "${DATA_BASENAME}")
  local path

  for path in "${config_paths[@]}"; do
    if ! git -C "${REPO_PATH}" cat-file -e "${config_ref}:${path}" 2>/dev/null; then
      echo "prepare_attempt: required shared config path ${path} does not exist on ${config_ref}" >&2
      echo "prepare_attempt: check dev_branch=${DEV_BRANCH} and the project config layout before retrying." >&2
      exit 8
    fi
  done

  # A prior model-settings override (the dispatcher's per-tier copy of
  # ${MODEL}-settings.json) may have marked .claude/settings.json skip-worktree.
  # Clear that bit for tracked config paths before overlaying origin/${DEV_BRANCH},
  # otherwise explicit config updates can be ignored.
  local tracked_config_paths
  if tracked_config_paths="$(git -C "${WORKTREE_DIR}" ls-files -- "${config_paths[@]}")" \
     && [ -n "${tracked_config_paths}" ]; then
    while IFS= read -r path || [ -n "${path}" ]; do
      [ -n "${path}" ] || continue
      git -C "${WORKTREE_DIR}" update-index --no-skip-worktree -- "${path}" 2>/dev/null || true
    done <<<"${tracked_config_paths}"
  fi

  echo "prepare_attempt: refreshing shared config paths from ${config_ref}: ${config_paths[*]}" >&2
  git -C "${WORKTREE_DIR}" checkout "${config_ref}" -- "${config_paths[@]}" >&2
  # `git checkout <tree> -- <path>` stages those paths. Leave them unstaged so
  # stage_and_guard.sh captures the full pre-stage diff/evidence before commit.
  git -C "${WORKTREE_DIR}" reset -q -- "${config_paths[@]}" 2>/dev/null || true
}

if [ "${WORKTREE_REUSE}" = true ]; then
  if [ "${ATTEMPT_NUMBER}" -gt 1 ]; then
    WORKTREE_SWITCH_BACKUP="${WORKTREE_DIR}.switch-backup.$$"
    snapshot_issue_runtime_tree "${WORKTREE_SWITCH_BACKUP}"
  fi
  # In-place branch switch: create or reset ${LOCAL_ATTEMPT_BRANCH} at
  # ${BASE_REF} inside the existing worktree. The issue runtime subtree
  # is snapshotted above before the switch can remove tracked paths absent
  # from ${BASE_REF}; continue mode restores it, while fresh reset mode
  # archives it outside the active worktree. Prior local attempt branches
  # (e.g. ${WORK_BRANCH}-att001) remain in the registry for audit; only the
  # worktree's HEAD moves.
  git -C "${WORKTREE_DIR}" checkout -B "${LOCAL_ATTEMPT_BRANCH}" "${BASE_REF}" --force >&2
else
  # First attempt for this IID (or recovery from a broken state). Create
  # the shared per-issue linked worktree branched from ${BASE_REF}. This
  # is the cwd Claude Code runs in; OUTPUT_DIR and LOG_DIR are inside it.
  # OUTPUT_DIR is force-added by stage_and_guard.sh after the run;
  # LOG_DIR's prompt.txt + claude_result.txt are force-added by the same
  # script, the remaining log files stay locally ignored via the
  # repository `.git/info/exclude` entry.
  mkdir -p "$(dirname "${WORKTREE_DIR}")"
  git worktree add -B "${LOCAL_ATTEMPT_BRANCH}" "${WORKTREE_DIR}" "${BASE_REF}" >&2
fi
refresh_shared_config_from_dev
# benchmark-test is fresh-only: archive any pre-switch snapshot and quarantine
# the active same-IID runtime subtree (continue-mode restore is removed).
archive_switch_backup "${STALE_SWITCH_BACKUP}" "stale-switch-before-attempt-${ATTEMPT_NUMBER_PADDED}"
archive_switch_backup "${WORKTREE_SWITCH_BACKUP}" "before-attempt-${ATTEMPT_NUMBER_PADDED}"
archive_fresh_active_runtime_tree
mkdir -p "${OUTPUT_DIR}"

# benchmark-test is fresh-only: there is no continue-mode salvage of prior
# scratch back into the worktree. Drop the pre-recreate backups and archive
# every leftover switch backup / legacy
# worktree path.
# From here on out the shared per-issue worktree at ${WORKTREE_DIR} is
# the only place this IID's current resume state lives, while old physical
# directories stay available under .preserved-* for forensics.
for stale in "${WORKTREE_DIR}.recreate-backup."*; do
  [ -d "${stale}" ] || continue
  archive_switch_backup "${stale}" "leftover-recreate-before-attempt-${ATTEMPT_NUMBER_PADDED}"
done
for stale in "${WORKTREE_DIR}.switch-backup."*; do
  [ -d "${stale}" ] || continue
  archive_switch_backup "${stale}" "leftover-switch-before-attempt-${ATTEMPT_NUMBER_PADDED}"
done

PRESERVED_LEGACY_ROOT="${WORKTREES_ROOT}/.preserved-legacy/issue-${ISSUE_IID}"
archive_legacy_path() {
  local src="$1"
  local label="$2"
  if [ ! -e "${src}" ]; then
    return 0
  fi
  mkdir -p "${PRESERVED_LEGACY_ROOT}"
  local dest="${PRESERVED_LEGACY_ROOT}/${label}.preserved.$$"
  local suffix=1
  while [ -e "${dest}" ]; do
    dest="${PRESERVED_LEGACY_ROOT}/${label}.preserved.$$.${suffix}"
    suffix=$((suffix + 1))
  done
  mv "${src}" "${dest}"
  echo "prepare_attempt: archived legacy worktree path ${src} at ${dest}" >&2
}

for d in "${LEGACY_PER_ATTEMPT_DIRS[@]:-}"; do
  [ -n "${d}" ] || continue
  archive_legacy_path "${d}" "$(basename "${d}")"
done
if [ -e "${LEGACY_SINGLE_WORKTREE_DIR}" ]; then
  archive_legacy_path "${LEGACY_SINGLE_WORKTREE_DIR}" "legacy-single-worktree"
fi
git worktree prune >&2

# Recreate ONLY the current attempt's log dir so stale evidence from a
# same-(IID, attempt) rerun is not mixed with the current run. The
# worktree is now on ${BASE_REF}; in continue mode that ref may already
# contain prior attempts' tracked `log/attempt-<earlier>/` directories,
# but those use different attempt numbers and so do not collide with the
# current LOG_DIR. Fresh mode has already quarantined the active same-IID
# runtime subtree, so this reset only needs to defend against an exact
# same-(IID, attempt) rerun.
# This is defensive against an exact same-(IID, attempt) rerun (rare —
# attempt numbers are monotonic).
if [ -d "${LOG_DIR}" ]; then
  LOG_RERUN_ARCHIVE_ROOT="${WORKTREES_ROOT}/.preserved-log-reruns/issue-${ISSUE_IID}"
  mkdir -p "${LOG_RERUN_ARCHIVE_ROOT}"
  LOG_RERUN_ARCHIVE="${LOG_RERUN_ARCHIVE_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}.$(date +%Y%m%dT%H%M%S).$$"
  mv "${LOG_DIR}" "${LOG_RERUN_ARCHIVE}"
fi
mkdir -p "${LOG_DIR}"

flock -u 8

echo "${ACTUAL_MODE}"
echo "${LOCAL_ATTEMPT_BRANCH}"
