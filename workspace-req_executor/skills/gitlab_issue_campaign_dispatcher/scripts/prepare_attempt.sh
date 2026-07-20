#!/usr/bin/env bash
# prepare_attempt.sh — ensure a per-issue linked git worktree exists for
# this IID and put it on the right starting point for the current attempt.
#
# Strategy A — single fixed remote branch ${WORK_BRANCH}; either `issue/<iid>`
# or a frozen two-Issue `issue/<head>+<tail>` branch.
# Each attempt gets an IID-local branch (${LOCAL_ATTEMPT_BRANCH},
# `issue/<current iid>-att${PADDED}`) checked out into a SHARED per-issue
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
# Modes (env var ISSUE_MODE):
#   fresh     — first attempt for this IID; base on origin/${BRANCH}, where
#               BRANCH is explicit trigger input or the resolved origin/HEAD.
#   continue  — when the dispatcher has preflighted a recoverable C history,
#               base the attempt on its exact CONTINUE_BASE_SHA. Otherwise try
#               origin/${WORK_BRANCH}, then the latest local prior attempt
#               branch, and finally downgrade to fresh on origin/${BRANCH}.
#               CONTINUE_BASE_REQUIRED=true requires that pinned SHA plus its
#               exact source ref and makes disappearance/movement a hard
#               failure before the SHA is checked out.
#               After the base checkout, Claude execution-control paths are
#               refreshed from the latest origin/${CONFIG_BRANCH:-$BRANCH}.
#
# Legacy-path salvage:
#   On the first run after the per-(IID,attempt) worktree scheme was
#   replaced by the shared per-IID scheme, this IID's untracked scratch
#   may still live at ${WORKTREES_ROOT}/issue-<iid>-att-<NNN>/ or at the
#   even older ${RESULT_ROOT}/issue-<iid>/worktree/. This script picks
#   the most recent legacy path as a salvage source, rsync's its
#   untracked content into the freshly-created shared worktree with
#   `--ignore-existing` while excluding shared config paths (so BASE_REF's
#   tracked files and the new worktree's
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
#   snapshots the current `.req_executor/issue-<iid>/` subtree. Continue
#   mode restores that snapshot after checkout so prior attempt output/log
#   files are visible for resume. Fresh reset mode (all non-continue entry
#   labels, including `todo`, `retry`, `new`, `blocked`, and trigger
#   require_labels) archives the snapshot and then quarantines any active
#   same-IID runtime subtree that survived checkout, so old files are not
#   physically deleted but also do not contaminate the reset run.
#
# Shared config freshness:
#   Agent execution-control paths (every `.claude/`, `CLAUDE.md`,
#   `CLAUDE.local.md`, `.mcp.json`, and `.acpxrc.json` in the tree) are
#   refreshed only from CONFIG_BRANCH (default BRANCH) after the base checkout
#   and before acpx runs. A dependency may change the business-code baseline,
#   but never those control files.
#
# What this script does NOT do:
#   - It does NOT mutate the parent checkout at ${REPO_PATH}. Only
#     `git fetch` runs against it; HEAD stays where clone_or_pull put it.
#   - It does NOT copy a `.claude/` runtime config into the worktree. The
#     worktree uses the repository's own `.claude/` path when present.
#   - It does NOT write `.git/info/exclude`. That is `clone_or_pull.sh`'s
#     responsibility (it appends `/.req_executor/` once per clone).
#     Runtime state/logs, `.worktrees/`, and generic `logs/` directories
#     therefore stay locally git-ignored; the current issue's output directory
#     is force-added explicitly by stage_and_guard.sh, which then removes log
#     paths from the index.
#
# Required env vars (all from env_paths.sh + glab_auth.sh + trigger):
#   REPO_PATH, ISSUE_IID, ISSUE_MODE,
#   ATTEMPT_DIR, WORKTREE_DIR, OUTPUT_DIR, LOG_DIR,
#   ATTEMPT_NUMBER_PADDED, WORK_BRANCH, LOCAL_ATTEMPT_BRANCH
# Optional shared-tail inputs:
#   SHARED_BRANCH_ROLE, EXPECTED_COMMIT_PARENT_SHA
#
# Output (to stdout, two lines):
#   <actual-mode>           "fresh" or "continue"
#   <local-branch-name>     ${LOCAL_ATTEMPT_BRANCH}

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env_paths.sh"
source "${SCRIPT_DIR}/git_network_guard.sh"
source "${SCRIPT_DIR}/branch_utils.sh"
GIT_NETWORK_GUARD_CONTEXT=prepare_attempt

: "${REPO_PATH:?}" "${WORK_ROOT:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" \
  "${ISSUE_ROOT:?}" \
  "${ATTEMPT_DIR:?}" "${WORKTREE_DIR:?}" "${OUTPUT_DIR:?}" "${LOG_DIR:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${WORK_BRANCH:?}" "${LOCAL_ATTEMPT_BRANCH:?}"
BRANCH="${BRANCH:-}"
CONFIG_BRANCH="${CONFIG_BRANCH:-}"
DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA:-}"
SHARED_BRANCH_ROLE="${SHARED_BRANCH_ROLE:-}"
EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA:-}"
CONTINUE_BASE_REQUIRED="${CONTINUE_BASE_REQUIRED:-false}"
CONTINUE_BASE_SHA="${CONTINUE_BASE_SHA:-}"
CONTINUE_BASE_REF="${CONTINUE_BASE_REF:-}"
case "${CONTINUE_BASE_REQUIRED}" in
  true|false) ;;
  *)
    echo "prepare_attempt: CONTINUE_BASE_REQUIRED must be true or false" >&2
    exit 2
    ;;
esac
if [ -n "${CONTINUE_BASE_SHA}" ] \
    && ! [[ "${CONTINUE_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "prepare_attempt: CONTINUE_BASE_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
if [ "${CONTINUE_BASE_REQUIRED}" = true ] \
    && { [ -z "${CONTINUE_BASE_SHA}" ] \
      || [ -z "${CONTINUE_BASE_REF}" ]; }; then
  echo "prepare_attempt: required continue base must include its pinned SHA and source ref" >&2
  exit 2
fi
if [ -n "${CONTINUE_BASE_REF}" ] \
    && ! git check-ref-format "${CONTINUE_BASE_REF}" >/dev/null 2>&1; then
  echo "prepare_attempt: CONTINUE_BASE_REF must be a valid full Git ref" >&2
  exit 2
fi
if [ -n "${DEPENDENCY_BASE_SHA}" ] \
    && ! [[ "${DEPENDENCY_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "prepare_attempt: DEPENDENCY_BASE_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
case "${SHARED_BRANCH_ROLE}" in
  ''|head|tail) ;;
  *)
    echo "prepare_attempt: SHARED_BRANCH_ROLE must be empty, head, or tail" >&2
    exit 2
    ;;
esac
if [ -n "${EXPECTED_COMMIT_PARENT_SHA}" ] \
    && ! [[ "${EXPECTED_COMMIT_PARENT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "prepare_attempt: EXPECTED_COMMIT_PARENT_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
if [ "${SHARED_BRANCH_ROLE}" = tail ]; then
  if [ -z "${DEPENDENCY_BASE_SHA}" ] \
      || [ -z "${EXPECTED_COMMIT_PARENT_SHA}" ] \
      || [ "${DEPENDENCY_BASE_SHA,,}" != "${EXPECTED_COMMIT_PARENT_SHA,,}" ]; then
    echo "prepare_attempt: shared tail requires its frozen dependency SHA as EXPECTED_COMMIT_PARENT_SHA" >&2
    exit 2
  fi
fi

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
GIT_NO_REPLACE_OBJECTS=1 git_network_guard_run "${REPO_PATH}" fetch \
  --prune --no-tags --refmap= origin \
  '+refs/heads/*:refs/remotes/origin/*' >&2
if [ -z "${BRANCH}" ]; then
  BRANCH="$(resolve_origin_default_branch "${REPO_PATH}")" || {
    echo "prepare_attempt: unable to resolve origin/HEAD default branch" >&2
    exit 5
  }
fi
if [ -z "${CONFIG_BRANCH}" ]; then
  CONFIG_BRANCH="${BRANCH}"
fi

if [ "${CONTINUE_BASE_REQUIRED}" = true ]; then
  expected_remote_continue_ref="refs/remotes/origin/${WORK_BRANCH}"
  expected_local_continue_prefix="refs/heads/issue/${ISSUE_IID}-att"
  continue_ref_allowed=false
  if [ "${CONTINUE_BASE_REF}" = "${expected_remote_continue_ref}" ]; then
    continue_ref_allowed=true
  elif [[ "${CONTINUE_BASE_REF}" == "${expected_local_continue_prefix}"* ]]; then
    continue_ref_suffix="${CONTINUE_BASE_REF#${expected_local_continue_prefix}}"
    if [[ "${continue_ref_suffix}" =~ ^[0-9]+$ ]]; then
      continue_ref_allowed=true
    fi
  fi
  if [ "${continue_ref_allowed}" != true ]; then
    echo "prepare_attempt: CONTINUE_BASE_REF is not an allowed ref for ${WORK_BRANCH}" >&2
    exit 2
  fi

  current_continue_sha="$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify \
    "${CONTINUE_BASE_REF}^{commit}" 2>/dev/null || true)"
  if [ -z "${current_continue_sha}" ] \
      || [ "${current_continue_sha,,}" != "${CONTINUE_BASE_SHA,,}" ]; then
    echo "prepare_attempt: continue source ref disappeared or moved after dependency preflight" >&2
    exit 5
  fi
fi

FRESH_BASE_REF="origin/${BRANCH}"
if [ -n "${DEPENDENCY_BASE_SHA}" ]; then
  resolved_dependency_sha="$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify \
    "${DEPENDENCY_BASE_SHA}^{commit}" 2>/dev/null || true)"
  if [ -z "${resolved_dependency_sha}" ] \
      || [ "${resolved_dependency_sha,,}" != "${DEPENDENCY_BASE_SHA,,}" ]; then
    echo "prepare_attempt: pinned dependency commit is unavailable: ${DEPENDENCY_BASE_SHA}" >&2
    exit 5
  fi
  FRESH_BASE_REF="${DEPENDENCY_BASE_SHA}"
fi

# Resolve the actual base ref.
# Fresh mode bases on BRANCH. Continue mode tries
# WORK_BRANCH first; if missing, fall back to the latest local prior
# attempt branch; if that is missing too, downgrade to fresh on BRANCH.
BASE_REF="${FRESH_BASE_REF}"
ACTUAL_MODE="${ISSUE_MODE}"
if [ "${ACTUAL_MODE}" = "continue" ]; then
  if [ "${CONTINUE_BASE_REQUIRED}" = true ]; then
    # The dispatcher already selected and authenticated the exact pushed (or
    # last verified local) C commit. Never reselect a branch here: doing so
    # could choose a newer unverified local attempt or a remotely moved head.
    BASE_REF="${CONTINUE_BASE_SHA}"
  else
    set +e
    remote_work_branch_rows="$(git_network_guard_run "${REPO_PATH}" \
      ls-remote --exit-code --heads origin "${WORK_BRANCH}" \
      2>/dev/null)"
    ls_remote_status=$?
    set -e
    case "${ls_remote_status}" in 0|2) ;; *) exit "${ls_remote_status}" ;; esac
    remote_work_branch_tips="$(awk \
      -v expected_ref="refs/heads/${WORK_BRANCH}" \
      '$2 == expected_ref {print $1}' <<<"${remote_work_branch_rows}")"
    remote_work_branch_count="$(awk 'NF {count++} END {print count+0}' \
      <<<"${remote_work_branch_tips}")"
    if [ "${remote_work_branch_count}" -gt 1 ]; then
      echo "prepare_attempt: remote returned duplicate exact work-branch refs" >&2
      exit 5
    fi
    case "${remote_work_branch_count}" in
      1)
        BASE_REF="origin/${WORK_BRANCH}"
        ;;
      0)
        PREVIOUS_LOCAL_BRANCH=""
        prev=$((ATTEMPT_NUMBER - 1))
        while [ "${prev}" -ge 1 ]; do
          prev_padded="$(printf '%03d' "${prev}")"
          candidate="issue/${ISSUE_IID}-att${prev_padded}"
          if GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify --quiet \
              "refs/heads/${candidate}" >/dev/null; then
            PREVIOUS_LOCAL_BRANCH="${candidate}"
            break
          fi
          prev=$((prev - 1))
        done
        if [ -n "${PREVIOUS_LOCAL_BRANCH}" ]; then
          BASE_REF="${PREVIOUS_LOCAL_BRANCH}"
        else
          ACTUAL_MODE=fresh
          BASE_REF="${FRESH_BASE_REF}"
        fi
        ;;
      *) exit 5 ;;
    esac
  fi
fi

# Sanity check the resolved BASE_REF actually exists. If BRANCH is
# missing on the remote, fail loudly — there is no further fallback.
if ! GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify --quiet \
    "${BASE_REF}" >/dev/null; then
  echo "prepare_attempt: base ref ${BASE_REF} does not exist on origin" >&2
  echo "Check that the resolved target branch '${BRANCH}' exists on the remote." >&2
  exit 5
fi
RESOLVED_BASE_SHA="$(GIT_NO_REPLACE_OBJECTS=1 \
  git rev-parse --verify "${BASE_REF}^{commit}")"
if [ "${ACTUAL_MODE}" = "continue" ] \
    && [ "${CONTINUE_BASE_REQUIRED}" = true ] \
    && [ "${RESOLVED_BASE_SHA,,}" != "${CONTINUE_BASE_SHA,,}" ]; then
  echo "prepare_attempt: continue base changed after dependency preflight" >&2
  exit 5
fi
if [ "${ACTUAL_MODE}" = "continue" ] \
    && [ -n "${DEPENDENCY_BASE_SHA}" ] \
    && ! GIT_NO_REPLACE_OBJECTS=1 git merge-base --is-ancestor \
      "${DEPENDENCY_BASE_SHA}" "${RESOLVED_BASE_SHA}" >/dev/null 2>&1; then
  echo "prepare_attempt: persisted dependency is not an ancestor of the continue base" >&2
  exit 5
fi

materialize_git() {
  # Repository/Issue content must never select a checkout hook, fsmonitor
  # command, or user/system attributes file while the outer process still has
  # scheduler/GitLab authority. Repository .gitattributes remain in force, but
  # dependency baselines containing an external filter attribute are rejected
  # below before any blob is materialized.
  env GIT_ATTR_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 git \
    -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false \
    -c core.attributesFile=/dev/null \
    -c submodule.recurse=false \
    "$@"
}

reject_dependency_checkout_filters() {
  local base_sha="$1" attributes_path attributes_entry attributes_mode
  local attributes_payload attributes_line attribute_index
  local info_attributes_path
  local -a attribute_tokens

  [ -n "${DEPENDENCY_BASE_SHA}" ] || return 0

  attributes_payload_has_filter() {
    local payload="$1"

    while IFS= read -r attributes_line || [ -n "${attributes_line}" ]; do
      [[ "${attributes_line}" == \#* ]] && continue
      read -r -a attribute_tokens <<<"${attributes_line}"
      for ((attribute_index = 1;
            attribute_index < ${#attribute_tokens[@]};
            attribute_index++)); do
        case "${attribute_tokens[attribute_index]}" in
          filter|-filter|!filter|filter=*) return 0 ;;
        esac
      done
    done <<<"${payload}"
    return 1
  }

  info_attributes_path="$(git rev-parse --git-path info/attributes)"
  case "${info_attributes_path}" in
    /*) ;;
    *) info_attributes_path="${REPO_PATH}/${info_attributes_path}" ;;
  esac
  if [ -L "${info_attributes_path}" ] \
      || { [ -e "${info_attributes_path}" ] \
        && [ ! -f "${info_attributes_path}" ]; }; then
    echo "prepare_attempt: repository info/attributes must be a regular file" >&2
    exit 7
  fi
  if [ -f "${info_attributes_path}" ]; then
    attributes_payload="$(<"${info_attributes_path}")"
    if attributes_payload_has_filter "${attributes_payload}"; then
      echo "prepare_attempt: repository info/attributes checkout filters are not allowed" >&2
      exit 7
    fi
  fi

  while IFS= read -r -d '' attributes_path; do
    case "${attributes_path}" in
      .gitattributes|*/.gitattributes) ;;
      *) continue ;;
    esac
    attributes_entry="$(GIT_NO_REPLACE_OBJECTS=1 \
      git ls-tree "${base_sha}" -- "${attributes_path}")"
    attributes_mode="${attributes_entry%% *}"
    case "${attributes_mode}" in
      100644|100755) ;;
      *)
        echo "prepare_attempt: dependency .gitattributes must be a regular file: ${attributes_path}" >&2
        exit 7
        ;;
    esac
    if ! attributes_payload="$(GIT_NO_REPLACE_OBJECTS=1 git cat-file blob \
        "${base_sha}:${attributes_path}")"; then
      echo "prepare_attempt: unable to inspect dependency attributes: ${attributes_path}" >&2
      exit 7
    fi
    if attributes_payload_has_filter "${attributes_payload}"; then
      echo "prepare_attempt: dependency checkout filters are not allowed: ${attributes_path}" >&2
      exit 7
    fi
  done < <(GIT_NO_REPLACE_OBJECTS=1 \
    git ls-tree -r --name-only -z "${base_sha}")
}

reject_dependency_checkout_filters "${RESOLVED_BASE_SHA}"

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
    git worktree remove --force \
      "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
fi
git worktree prune >&2

# Ensure the cross-attempt ISSUE_ROOT exists for state.json /
# attempt_state.json / summary.md. The log dir itself lives inside the
# worktree (see below) so it is recreated AFTER the worktree is on the
# correct base ref.
mkdir -p "${ATTEMPT_DIR}"

ISSUE_WORKTREE_RUNTIME_DIR="${WORKTREE_DIR}/${ISSUE_WORKTREE_REL}"

# The dependency commit is business-code input. It must never be able to turn
# the fixed worktree-local runtime directory into an alias for the durable
# parent checkout (for example by committing `.req_executor` as a symlink).
# Validate every existing ancestor before any snapshot/move/rsync/mkdir that
# touches the runtime tree. The lexical equality checks also ensure a future
# env_paths change cannot silently widen this boundary.
validate_runtime_path_boundary() {
  local expected_runtime="${WORKTREE_DIR}/${REQ_EXECUTOR_DIR}/issue-${ISSUE_IID}"
  local expected_output="${expected_runtime}/output"
  local expected_log="${expected_runtime}/log/attempt-${ATTEMPT_NUMBER_PADDED}"
  local root_real component component_real path_component log_component

  if [ "${ISSUE_WORKTREE_RUNTIME_DIR}" != "${expected_runtime}" ] \
      || [ "${OUTPUT_DIR}" != "${expected_output}" ] \
      || [ "${LOG_DIR}" != "${expected_log}" ]; then
    echo "prepare_attempt: runtime path derivation escaped the fixed worktree layout" >&2
    return 1
  fi
  if [ ! -d "${WORKTREE_DIR}" ] || [ -L "${WORKTREE_DIR}" ]; then
    echo "prepare_attempt: worktree root must be a real directory" >&2
    return 1
  fi
  root_real="$(cd -P "${WORKTREE_DIR}" 2>/dev/null && pwd -P)" || {
    echo "prepare_attempt: unable to canonicalize worktree root" >&2
    return 1
  }

  component="${WORKTREE_DIR}"
  for path_component in \
      "${REQ_EXECUTOR_DIR}" "issue-${ISSUE_IID}" output; do
    component="${component}/${path_component}"
    if [ -L "${component}" ]; then
      echo "prepare_attempt: runtime ancestor must not be a symlink: ${component}" >&2
      return 1
    fi
    if [ -e "${component}" ]; then
      if [ ! -d "${component}" ]; then
        echo "prepare_attempt: runtime ancestor must be a directory: ${component}" >&2
        return 1
      fi
      component_real="$(cd -P "${component}" 2>/dev/null && pwd -P)" || return 1
      case "${component_real}" in
        "${root_real}"/*) ;;
        *)
          echo "prepare_attempt: runtime ancestor resolves outside the worktree: ${component}" >&2
          return 1
          ;;
      esac
    fi
  done

  component="${expected_runtime}/log"
  for log_component in "${component}" "${component}/attempt-${ATTEMPT_NUMBER_PADDED}"; do
    if [ -L "${log_component}" ]; then
      echo "prepare_attempt: log ancestor must not be a symlink: ${log_component}" >&2
      return 1
    fi
    if [ -e "${log_component}" ]; then
      if [ ! -d "${log_component}" ]; then
        echo "prepare_attempt: log ancestor must be a directory: ${log_component}" >&2
        return 1
      fi
      component_real="$(cd -P "${log_component}" 2>/dev/null && pwd -P)" || return 1
      case "${component_real}" in
        "${root_real}"/*) ;;
        *)
          echo "prepare_attempt: log ancestor resolves outside the worktree: ${log_component}" >&2
          return 1
          ;;
      esac
    fi
  done
}

snapshot_issue_runtime_tree() {
  local dst="$1"
  if [ ! -d "${ISSUE_WORKTREE_RUNTIME_DIR}" ]; then
    return 0
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "prepare_attempt: rsync is required to preserve prior attempt files from ${ISSUE_WORKTREE_RUNTIME_DIR} but is missing on PATH" >&2
    exit 6
  fi
  mkdir -p "${dst}/${REQ_EXECUTOR_DIR}"
  echo "prepare_attempt: preserving prior attempt files from ${ISSUE_WORKTREE_RUNTIME_DIR} before branch switch" >&2
  rsync -rltD "${ISSUE_WORKTREE_RUNTIME_DIR}/" "${dst}/${ISSUE_WORKTREE_REL}/"
}

restore_issue_runtime_tree() {
  local src="$1"
  if [ -z "${src}" ] || [ ! -d "${src}/${ISSUE_WORKTREE_REL}" ]; then
    return 0
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "prepare_attempt: rsync is required to restore prior attempt files from ${src} but is missing on PATH" >&2
    exit 6
  fi
  echo "prepare_attempt: restoring prior attempt files from ${src}/${ISSUE_WORKTREE_REL} into ${ISSUE_WORKTREE_RUNTIME_DIR}" >&2
  mkdir -p "${ISSUE_WORKTREE_RUNTIME_DIR}"
  rsync -rltD "${src}/${ISSUE_WORKTREE_REL}/" "${ISSUE_WORKTREE_RUNTIME_DIR}/"
}

PRESERVED_ATTEMPT_ROOT="${WORKTREES_ROOT}/.preserved-attempts/issue-${ISSUE_IID}"
archive_switch_backup() {
  local src="$1"
  local label="$2"
  if [ -z "${src}" ] \
      || { [ ! -e "${src}" ] && [ ! -L "${src}" ]; }; then
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
  if ! tracked_paths="$(git -C "${WORKTREE_DIR}" \
      ls-files -- "${ISSUE_WORKTREE_REL}")"; then
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

refresh_shared_config_from_branch() {
  local config_ref="origin/${CONFIG_BRANCH}"
  local dependency_control_paths=()
  local config_paths=()
  local path trusted_path path_is_trusted control_counter=0
  local config_entry config_mode

  is_execution_control_path() {
    local candidate="$1"
    case "${candidate}" in
      .claude|*/.claude|.claude/*|*/.claude/*|CLAUDE.md|*/CLAUDE.md|\
      CLAUDE.local.md|*/CLAUDE.local.md|.mcp.json|*/.mcp.json|\
      .acpxrc.json|*/.acpxrc.json)
        return 0
        ;;
      *) return 1 ;;
    esac
  }

  if ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
      cat-file -e "${config_ref}^{commit}" 2>/dev/null; then
    echo "prepare_attempt: trusted config ref ${config_ref} is unavailable" >&2
    exit 7
  fi

  # Remember which control paths came from the selected business-code
  # baseline. Paths absent from CONFIG_BRANCH are replaced with inert regular
  # placeholders below, rather than left as deletions that stage_and_guard.sh
  # must reject.
  while IFS= read -r -d '' path; do
    if is_execution_control_path "${path}"; then
      dependency_control_paths+=("${path}")
    fi
  done < <(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    ls-tree -r --name-only -z HEAD)

  # A dependency branch is an untrusted business-code input, not an execution
# policy source. Move every current Claude control path out of the active
# worktree first, including nested and untracked paths, then restore only the
# trusted CONFIG_BRANCH copies. This also prevents a prior attempt from
# persisting newly-created control files across continue. `find` never follows
# symlinks, and the private runtime subtree is excluded from the walk.
  while IFS= read -r -d '' path; do
    control_counter=$((control_counter + 1))
    archive_switch_backup "${path}" \
      "execution-control-${control_counter}-before-attempt-${ATTEMPT_NUMBER_PADDED}"
  done < <(find -P "${WORKTREE_DIR}" \
    -path "${WORKTREE_DIR}/${REQ_EXECUTOR_DIR}" -prune -o \
    \( -name .claude -print0 -prune \) -o \
    \( -name CLAUDE.md -o -name CLAUDE.local.md -o -name .mcp.json \
       -o -name .acpxrc.json \) -print0)

  # A task-agnostic issue executor may run against repos that do not carry
# execution-control files. Enumerate the trusted tree with NUL delimiters so
# nested paths and legal whitespace cannot be misparsed.
  while IFS= read -r -d '' path; do
    if is_execution_control_path "${path}"; then
      config_entry="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
        ls-tree "${config_ref}" -- "${path}")"
      config_mode="${config_entry%% *}"
      case "${config_mode}" in
        100644|100755) ;;
        *)
          echo "prepare_attempt: trusted execution-control path must be a regular file: ${path}" >&2
          exit 7
          ;;
      esac
      config_paths+=("${path}")
    fi
  done < <(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
    ls-tree -r --name-only -z "${config_ref}")

  if [ "${#config_paths[@]}" -eq 0 ]; then
    echo "prepare_attempt: no shared control paths present on ${config_ref}; using inert placeholders for dependency-only controls" >&2
  else
    # A prior claude_settings_path override may have marked
    # .claude/settings.json skip-worktree. Clear that bit for tracked config
    # paths before overlaying origin/${CONFIG_BRANCH}, otherwise explicit
    # config updates can be ignored.
    local tracked_config_paths
    if tracked_config_paths="$(git -C "${WORKTREE_DIR}" \
        ls-files -- "${config_paths[@]}")" \
       && [ -n "${tracked_config_paths}" ]; then
      while IFS= read -r path || [ -n "${path}" ]; do
        [ -n "${path}" ] || continue
        materialize_git -C "${WORKTREE_DIR}" update-index \
          --no-skip-worktree -- "${path}" 2>/dev/null || true
      done <<<"${tracked_config_paths}"
    fi

    echo "prepare_attempt: refreshing shared control paths from ${config_ref}: ${config_paths[*]}" >&2
    materialize_git -C "${WORKTREE_DIR}" checkout \
      --no-recurse-submodules "${config_ref}" -- "${config_paths[@]}" >&2
    # `git checkout <tree> -- <path>` stages those paths. Leave them unstaged
    # so stage_and_guard.sh captures the full pre-stage diff/evidence before
    # commit.
    materialize_git -C "${WORKTREE_DIR}" reset \
      -q -- "${config_paths[@]}" 2>/dev/null || true
  fi

  # A dependency-only control path cannot remain active, but simply moving it
  # away would look like a forbidden destructive deletion. Replace it with an
  # inert regular file; the eventual C commit sanitizes that inherited path.
  for path in "${dependency_control_paths[@]:-}"; do
    [ -n "${path}" ] || continue
    path_is_trusted=false
    for trusted_path in "${config_paths[@]:-}"; do
      if [ "${path}" = "${trusted_path}" ] \
          || { [[ "${path}" = .claude || "${path}" = */.claude ]] \
            && [[ "${trusted_path}" = "${path}/"* ]]; }; then
        path_is_trusted=true
        break
      fi
    done
    if [ "${path_is_trusted}" = true ]; then
      continue
    fi
    mkdir -p "$(dirname "${WORKTREE_DIR}/${path}")"
    case "${path}" in
      *.json) printf '{}\n' >"${WORKTREE_DIR}/${path}" ;;
      *) printf '\n' >"${WORKTREE_DIR}/${path}" ;;
    esac
    chmod 600 "${WORKTREE_DIR}/${path}" 2>/dev/null || true
    echo "prepare_attempt: replaced dependency-only execution control path with an inert file: ${path}" >&2
  done
}

if [ "${WORKTREE_REUSE}" = true ] \
    && ! validate_runtime_path_boundary; then
  # A prior rejected base can leave a registered worktree whose runtime path
  # is a symlink or other unsafe shape. Never inspect/snapshot that runtime,
  # but do preserve the whole worktree for forensics and recreate from the new
  # verified BASE_REF so a later safe retry is not permanently wedged.
  echo "prepare_attempt: unsafe reusable runtime; archiving worktree before safe recreate" >&2
  WORKTREE_RECREATE_BACKUP="${WORKTREE_DIR}.recreate-backup.$$"
  mv "${WORKTREE_DIR}" "${WORKTREE_RECREATE_BACKUP}"
  if worktree_registered; then
    git worktree remove --force \
      "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
  git worktree prune >&2
  WORKTREE_REUSE=false
fi

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
  materialize_git -C "${WORKTREE_DIR}" checkout \
    --no-recurse-submodules -B "${LOCAL_ATTEMPT_BRANCH}" \
    "${BASE_REF}" --force >&2
else
  # First attempt for this IID (or recovery from a broken state). Create
  # the shared per-issue linked worktree branched from ${BASE_REF}. This
  # is the cwd Claude Code runs in; OUTPUT_DIR and LOG_DIR are inside it.
  # OUTPUT_DIR is force-added by stage_and_guard.sh after the run; LOG_DIR and
  # generic logs/ directories stay local and are removed from the index.
  mkdir -p "$(dirname "${WORKTREE_DIR}")"
  materialize_git worktree add \
    -B "${LOCAL_ATTEMPT_BRANCH}" "${WORKTREE_DIR}" "${BASE_REF}" >&2
fi
validate_runtime_path_boundary || exit 7
refresh_shared_config_from_branch
if [ "${SHARED_BRANCH_ROLE}" = tail ]; then
  if [ "${ACTUAL_MODE}" = continue ]; then
    # Continue resumes C's published tree, but the shared branch contract keeps
    # exactly one replaceable C commit above frozen A. Move only the local
    # attempt branch/index back to A and leave the working tree intact, turning
    # all prior C content plus this attempt's later edits into one aggregate
    # worktree diff. EXPECTED_WORK_BRANCH_SHA remains the independent C lease.
    materialize_git -C "${WORKTREE_DIR}" reset --mixed \
      --no-recurse-submodules "${EXPECTED_COMMIT_PARENT_SHA}" >&2
  fi
  prepared_parent_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-parse --verify HEAD^{commit})"
  if [ "${prepared_parent_sha,,}" != "${EXPECTED_COMMIT_PARENT_SHA,,}" ]; then
    echo "prepare_attempt: shared tail local branch is not based on its frozen commit parent" >&2
    exit 5
  fi
fi
if [ "${ACTUAL_MODE}" = "continue" ]; then
  restore_issue_runtime_tree "${STALE_SWITCH_BACKUP}"
  restore_issue_runtime_tree "${WORKTREE_SWITCH_BACKUP}"
else
  archive_switch_backup "${STALE_SWITCH_BACKUP}" "stale-switch-before-attempt-${ATTEMPT_NUMBER_PADDED}"
  archive_switch_backup "${WORKTREE_SWITCH_BACKUP}" "before-attempt-${ATTEMPT_NUMBER_PADDED}"
  archive_fresh_active_runtime_tree
fi
mkdir -p "${OUTPUT_DIR}"

# ─── Continue-mode salvage from backup sources into the worktree ─────
#
# Priority chain (first existing source wins; only one is chosen):
#   1. WORKTREE_RECREATE_BACKUP — fresh mv-aside a few lines above.
#   2. STALE_RECREATE_BACKUP   — orphan backup left by a prior crashed
#      run of this script after the mv-aside step.
#   3. SALVAGE_SRC             — legacy `-att-<NNN>` or very-old
#      single-worktree path, picked above before deregistration.
#
# This block runs only in continue mode. Fresh reset mode (all non-continue
# entry labels) deliberately leaves these sources out of the active worktree
# and archives them below. Sources 2 and 3 only fire when this is a genuine
# recreate (not the shared-worktree REUSE path). When REUSE=true the existing
# untracked scratch already on disk is authoritative; rsyncing from a stale
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
#   - Shared config paths are excluded from salvage because they are refreshed
#     from origin/${BRANCH} for every attempt.
salvage_into_worktree() {
  local src="$1"
  local runtime_source_unsafe=false
  local runtime_component="${src}"
  local runtime_part
  if [ -z "${src}" ] || [ ! -d "${src}" ]; then
    return 0
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "prepare_attempt: rsync is required to salvage untracked scratch from ${src} but is missing on PATH" >&2
    exit 6
  fi
  echo "prepare_attempt: salvaging untracked scratch from ${src} into ${WORKTREE_DIR}" >&2
  for runtime_part in "${REQ_EXECUTOR_DIR}" "issue-${ISSUE_IID}"; do
    runtime_component="${runtime_component}/${runtime_part}"
    if [ -L "${runtime_component}" ] \
        || { [ -e "${runtime_component}" ] \
          && [ ! -d "${runtime_component}" ]; }; then
      runtime_source_unsafe=true
      break
    fi
  done
  if [ "${runtime_source_unsafe}" = true ]; then
    echo "prepare_attempt: unsafe backup runtime excluded from salvage: ${src}/${REQ_EXECUTOR_DIR}" >&2
    rsync -rltD --ignore-existing \
      --exclude='/.git' \
      --exclude="/${REQ_EXECUTOR_DIR}" \
      --exclude='.claude/' \
      --exclude='CLAUDE.md' \
      --exclude='CLAUDE.local.md' \
      --exclude='.mcp.json' \
      --exclude='.acpxrc.json' \
      "${src}/" "${WORKTREE_DIR}/"
  else
    rsync -rltD --ignore-existing \
      --exclude='/.git' \
      --exclude='.claude/' \
      --exclude='CLAUDE.md' \
      --exclude='CLAUDE.local.md' \
      --exclude='.mcp.json' \
      --exclude='.acpxrc.json' \
      "${src}/" "${WORKTREE_DIR}/"
  fi
}

if [ "${ACTUAL_MODE}" = "continue" ]; then
  salvage_into_worktree "${WORKTREE_RECREATE_BACKUP}"
  if [ "${WORKTREE_REUSE}" = false ]; then
    if [ -z "${WORKTREE_RECREATE_BACKUP}" ] || [ ! -d "${WORKTREE_RECREATE_BACKUP}" ]; then
      salvage_into_worktree "${STALE_RECREATE_BACKUP}"
      if [ -z "${STALE_RECREATE_BACKUP}" ] || [ ! -d "${STALE_RECREATE_BACKUP}" ]; then
        salvage_into_worktree "${SALVAGE_SRC}"
      fi
    fi
  fi
fi

# A backup/legacy source is untrusted too. Recheck after salvage before any
# runtime mkdir/move so a copied top-level symlink cannot redirect state.
validate_runtime_path_boundary || exit 7

# Now that any meaningful scratch has been salvaged, drop the
# pre-recreate backups and archive every leftover switch backup / legacy
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
