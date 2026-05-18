#!/usr/bin/env bash
# create_mr.sh — ensure exactly ONE merge request exists for ${WORK_BRANCH}
# at the end of this attempt, rotating away any prior open MR first.
#
# Behavior (BOTH ISSUE_MODE values — `fresh` and `continue` — now follow
# the same MR-rotation policy):
#
#   1. List every open MR currently pointing at ${WORK_BRANCH}.
#   2. Close them without merging (the integration branch is untouched;
#      the closed MR objects remain in GitLab as historical record).
#   3. Create a fresh MR for the new attempt. When a prior MR existed, the
#      new MR's description carries `Supersedes !<old_iid>` references for
#      reviewer traceability.
#
# Why not reuse for fresh mode any more: glab `mr create` shells out to
# `git` for commit metadata even when `--repo` is passed, so the script
# must `cd "${WORKTREE_DIR}"` before invoking glab. With that fix in
# place, paying the extra glab close call per attempt is the price for
# a clean "one MR per attempt" history that matches continue-mode
# behavior — reviewers see each attempt as its own MR object.
#
# Required env vars:
#   PROJECT_FULL    "${GROUP}/${PROJECT}"
#   WORKTREE_DIR    per-attempt linked git worktree (cwd for the glab call;
#                   glab `mr create` invokes `git` internally even with
#                   `--repo`, so we MUST run inside a valid git work tree)
#   ISSUE_IID       from env_paths.sh
#   ISSUE_MODE      "fresh" or "continue" (kept for log correlation only;
#                   no longer changes MR rotation behavior)
#   ISSUE_TITLE     short human title for the MR title
#   LOG_DIR         where mr_description.md lives (under WORKTREE_DIR/${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN)
#   BRANCH          target branch (typically "master")
#   WORK_BRANCH     source branch (single, fixed)
#   ATTEMPT_NUMBER_PADDED  e.g. "002" (used in MR title for visibility)
#
# Output (two lines on stdout):
#   <merge-request-web-url>
#   <mr_action>            "created" when no prior open MR existed,
#                          "rotated" when a prior open MR was closed first.
#   The executor captures both lines into the compact JSON.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${PROJECT_FULL:?}" "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${ISSUE_TITLE:?}" \
  "${LOG_DIR:?}" "${BRANCH:?}" "${WORK_BRANCH:?}" "${ATTEMPT_NUMBER_PADDED:?}"

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "create_mr: ISSUE_MODE must be fresh or continue, got '${ISSUE_MODE}'" >&2
    exit 2
    ;;
esac

# glab `mr create` shells out to `git` internally (for commit metadata
# and source-branch sanity even when `--repo` is passed). OpenClaw runs
# each Bash exec in a fresh shell whose default cwd is NOT inside any
# git work tree, so without this `cd` glab fails with the localized
# "fatal: 不是一个 git 仓库" error. The worktree's `.git` file points
# back at the parent checkout's per-worktree admin dir, which is enough
# for the internal `git` calls.
if [ ! -d "${WORKTREE_DIR}" ]; then
  echo "create_mr: WORKTREE_DIR does not exist: ${WORKTREE_DIR}" >&2
  exit 3
fi
cd "${WORKTREE_DIR}"

list_open_mrs_for_work_branch() {
  # glab 1.93.0 does not recognize `glab mr list --state opened`.
  # The default list scope is open MRs; keep a jq filter as a guard in case a
  # future glab changes the default or includes closed MRs in JSON output.
  glab mr list \
    --repo "${PROJECT_FULL}" \
    --source-branch "${WORK_BRANCH}" \
    --output json |
    jq '[.[] | select((.state // "opened") == "opened")]'
}

# Look up any open MR currently pointing at this branch.
EXISTING_JSON="$(list_open_mrs_for_work_branch 2>/dev/null || echo '[]')"
EXISTING_COUNT="$(echo "${EXISTING_JSON}" | jq -r 'length')"

# Always close existing open MRs before creating a new one. Both fresh
# and continue modes now follow the same rotation policy so every new
# attempt produces a fresh MR object — reviewers see each attempt as its
# own MR rather than a force-pushed branch silently updating an old MR.
# Closing — not merging — preserves the history without changing the
# integration branch.
SUPERSEDES_LINE=""
MR_ACTION="created"
if [ "${EXISTING_COUNT}" -gt 0 ]; then
  SUPERSEDES_REFS="$(echo "${EXISTING_JSON}" | jq -r 'map("!" + (.iid|tostring)) | join(", ")')"
  echo "${EXISTING_JSON}" | jq -r '.[].iid' | while IFS= read -r existing_iid; do
    glab mr close "${existing_iid}" \
      --repo "${PROJECT_FULL}" >/dev/null || {
      echo "create_mr: failed to close MR !${existing_iid}" >&2
      exit 4
    }
  done
  SUPERSEDES_LINE="Supersedes ${SUPERSEDES_REFS} (closed by acpx_auto_tester attempt ${ATTEMPT_NUMBER_PADDED} re-run; mode=${ISSUE_MODE})."
  MR_ACTION="rotated"
fi

# Build / refresh the MR description. `Closes #<iid>` triggers GitLab's
# native auto-close when this MR is eventually merged.
DESC_FILE="${LOG_DIR}/mr_description.md"
{
  echo "Closes #${ISSUE_IID}"
  echo
  if [ -n "${SUPERSEDES_LINE}" ]; then
    echo "${SUPERSEDES_LINE}"
    echo
  fi
  echo "Auto-generated MR for issue #${ISSUE_IID} (attempt ${ATTEMPT_NUMBER_PADDED}, mode=${ISSUE_MODE})."
  echo
  echo "prompt.txt and claude_result.txt for this attempt are committed inside the MR"
  echo "diff under \`${RESULT_BASENAME}/issue-${ISSUE_IID}/log/attempt-${ATTEMPT_NUMBER_PADDED}/\`."
  echo "Raw acpx logs, git status/diff snapshots, and Wiki bookkeeping live only in"
  echo "the per-attempt worktree on the runner (\`${LOG_DIR}\`) until housekeeping"
  echo "removes the worktree."
  echo
  echo "Attempt prompt/result logs are also published to the project Wiki before"
  echo "this MR is created."
  echo
  echo "Per-attempt summaries are posted as comments on the linked issue."
  echo
  echo "Do not merge until reviewed."
} > "${DESC_FILE}"

# NOTE: --description (inline string) is used instead of --description-file
# because some runner-installed glab versions don't recognize the latter.
# See SOUL.md §GitLab Access — verify any new flag with `glab <subcmd> --help`
# on the runner before adopting it.
glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${BRANCH}" \
  --title "Issue #${ISSUE_IID} (attempt ${ATTEMPT_NUMBER_PADDED}): ${ISSUE_TITLE}" \
  --description "$(cat "${DESC_FILE}")" \
  --yes >/dev/null

OPEN_JSON="$(
  list_open_mrs_for_work_branch
)"
OPEN_COUNT="$(echo "${OPEN_JSON}" | jq -r 'length')"
if [ "${OPEN_COUNT}" -ne 1 ]; then
  echo "create_mr: expected exactly one open MR for ${WORK_BRANCH}, found ${OPEN_COUNT}" >&2
  exit 6
fi
echo "${OPEN_JSON}" | jq -r '.[0].web_url'
echo "${MR_ACTION}"
