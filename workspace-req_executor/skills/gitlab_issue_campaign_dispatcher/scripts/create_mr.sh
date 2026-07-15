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
#   WORKTREE_DIR    shared per-issue linked git worktree for this IID
#                   (cwd for the glab call; glab `mr create` invokes
#                   `git` internally even with `--repo`, so we MUST run
#                   inside a valid git work tree)
#   ISSUE_IID       from env_paths.sh
#   ISSUE_MODE      "fresh" or "continue" (kept for log correlation only;
#                   no longer changes MR rotation behavior)
#   ISSUE_TITLE     short human title for the MR title
#   LOG_DIR         where mr_description.md lives (under WORKTREE_DIR/.req_executor/issue-<iid>/log/attempt-NNN)
#   BRANCH          default target branch
#   MERGE_TARGET_BRANCH  MR target branch (optional; falls back to BRANCH)
#   AUTO_MERGE      true|false (optional; default false)
#   COMMIT_SHA      exact source HEAD that the MR must expose
#   WORK_BRANCH     source branch (single, fixed)
#   ATTEMPT_NUMBER_PADDED  e.g. "002" (used in MR title for visibility)
#
# Output (four lines on stdout):
#   <merge-request-web-url>
#   <mr_action>            "created" when no prior open MR existed,
#                          "rotated" when a prior open MR was closed first.
#   <merge-request-iid>
#   <merge_outcome>        "merged" only after exact server verification;
#                          otherwise "opened" or conservative "unknown".
#   The first three lines are emitted as soon as the new MR identity is known,
#   so the executor can recover an MR even if the optional merge step stalls.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${PROJECT_FULL:?}" "${WORKTREE_DIR:?}" "${ISSUE_IID:?}" "${ISSUE_MODE:?}" "${ISSUE_TITLE:?}" \
  "${LOG_DIR:?}" "${BRANCH:?}" "${WORK_BRANCH:?}" "${ATTEMPT_NUMBER_PADDED:?}" \
  "${PROJECT_URI:?}" "${COMMIT_SHA:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_MERGE="${AUTO_MERGE:-false}"
MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH}}"
MR_RESULT_FILE="${LOG_DIR}/mr_result.json"

case "${AUTO_MERGE}" in
  true|false) ;;
  *)
    echo "create_mr: AUTO_MERGE must be true or false" >&2
    exit 2
    ;;
esac
if [ -z "${MERGE_TARGET_BRANCH}" ]; then
  echo "create_mr: MERGE_TARGET_BRANCH or BRANCH must be non-empty" >&2
  exit 2
fi
if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  echo "create_mr: COMMIT_SHA must be a hexadecimal Git object ID" >&2
  exit 2
fi

# A prior attempt-local file is untrusted input because the inner model can
# write inside LOG_DIR.  Retire it before any GitLab mutation; only this outer
# fixed script may create the marker consumed for recovery below.
if [ -e "${MR_RESULT_FILE}" ] || [ -L "${MR_RESULT_FILE}" ]; then
  mv "${MR_RESULT_FILE}" "${MR_RESULT_FILE}.stale.$$.${RANDOM}"
fi

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

# Look up any open MR currently pointing at this branch.  This read is the
# mutation fence: an auth/network failure must not be mistaken for an empty
# list, otherwise the script could create a duplicate or close the wrong set.
if ! EXISTING_JSON="$(list_open_mrs_for_work_branch)"; then
  echo "create_mr: failed to list existing open MRs for ${WORK_BRANCH}" >&2
  exit 5
fi
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
  SUPERSEDES_LINE="Supersedes ${SUPERSEDES_REFS} (closed by req_executor attempt ${ATTEMPT_NUMBER_PADDED} re-run; mode=${ISSUE_MODE})."
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
  echo "Attempt logs, including prompt.txt, claude_result.txt, raw acpx logs,"
  echo "and git status/diff snapshots live only in"
  echo "the shared per-issue worktree on the runner (\`${LOG_DIR}\`) until housekeeping"
  echo "removes the worktree."
  echo
  echo "Per-attempt summaries are posted as comments on the linked issue."
  echo
  if [ "${AUTO_MERGE}" = true ]; then
    echo "req_executor will attempt an immediate merge; if GitLab does not confirm it, this MR remains available for normal review."
  else
    echo "Do not merge until reviewed."
  fi
} > "${DESC_FILE}"

# NOTE: --description (inline string) is used instead of --description-file
# because some runner-installed glab versions don't recognize the latter.
# See SOUL.md §GitLab Access — verify any new flag with `glab <subcmd> --help`
# on the runner before adopting it.
glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${MERGE_TARGET_BRANCH}" \
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

MR_IID="$(jq -er '.[0].iid | select(type == "number" and . == floor and . > 0)' <<<"${OPEN_JSON}")" || {
  echo "create_mr: created MR is missing a valid project-local IID" >&2
  exit 6
}
MR_URL="$(jq -er '.[0].web_url | select(type == "string" and length > 0)' <<<"${OPEN_JSON}")" || {
  echo "create_mr: created MR is missing a valid web URL" >&2
  exit 6
}

persist_mr_result() {
  local result_json="$1" result_tmp
  result_tmp="$(mktemp "${MR_RESULT_FILE}.tmp.XXXXXX")"
  if ! jq -c \
      --arg mr_action "${MR_ACTION}" \
      --argjson issue_iid "${ISSUE_IID}" \
      --argjson attempt_number "${ATTEMPT_NUMBER}" \
      --argjson auto_merge "${AUTO_MERGE}" '
        . + {
          mr_action:$mr_action,
          issue_iid:$issue_iid,
          attempt_number:$attempt_number,
          auto_merge:$auto_merge
        }
      ' <<<"${result_json}" >"${result_tmp}"; then
    echo "create_mr: failed to render ${MR_RESULT_FILE}" >&2
    return 1
  fi
  chmod 600 "${result_tmp}"
  mv "${result_tmp}" "${MR_RESULT_FILE}"
}

# Emit the durable identity before the optional merge call.  If the helper is
# later killed, run_executor_attempt.sh can still recover this exact MR and
# conservatively apply `pr`, never `finish`.
printf '%s\n%s\n%s\n' "${MR_URL}" "${MR_ACTION}" "${MR_IID}"
INITIAL_RESULT="$(jq -cn \
  --argjson iid "${MR_IID}" \
  --arg web_url "${MR_URL}" \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg sha "${COMMIT_SHA}" '{
    version:1,
    iid:$iid,
    web_url:$web_url,
    source_branch:$source_branch,
    target_branch:$target_branch,
    sha:$sha,
    observed_state:"unknown",
    outcome:"unknown",
    verified:false,
    merge_attempted:false,
    merge_api_succeeded:false,
    reason:"exact_mr_verification_pending"
  }')"
persist_mr_result "${INITIAL_RESULT}"

set +e
MERGE_RESULT="$(
  MERGE_MR_MODE=attempt \
  AUTO_MERGE="${AUTO_MERGE}" \
  MR_IID="${MR_IID}" \
  MERGE_REQUEST_URL="${MR_URL}" \
  WORK_BRANCH="${WORK_BRANCH}" \
  MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
  COMMIT_SHA="${COMMIT_SHA}" \
    bash "${SCRIPT_DIR}/merge_mr.sh"
)"
MERGE_HELPER_RC=$?
set -e

if [ "${MERGE_HELPER_RC}" -ne 0 ] \
    || ! jq -e \
      --argjson iid "${MR_IID}" \
      --arg web_url "${MR_URL}" \
      --arg source_branch "${WORK_BRANCH}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" \
      --arg sha "${COMMIT_SHA}" '
        type == "object"
        and .version == 1
        and .iid == $iid
        and .web_url == $web_url
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
        and (.outcome as $outcome
          | ["merged","opened","unknown"] | index($outcome) != null)
        and (.verified | type == "boolean")
        and (.merge_attempted | type == "boolean")
        and (.merge_api_succeeded | type == "boolean")
        and (.observed_state | type == "string")
        and (.reason | type == "string")
      ' <<<"${MERGE_RESULT}" >/dev/null 2>&1; then
  MERGE_RESULT="$(jq -cn \
    --argjson iid "${MR_IID}" \
    --arg web_url "${MR_URL}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg sha "${COMMIT_SHA}" '{
      version:1,
      iid:$iid,
      web_url:$web_url,
      source_branch:$source_branch,
      target_branch:$target_branch,
      sha:$sha,
      observed_state:"unknown",
      outcome:"unknown",
      verified:false,
      merge_attempted:false,
      merge_api_succeeded:false,
      reason:"merge_helper_failed_or_invalid"
    }')"
fi

persist_mr_result "${MERGE_RESULT}"
jq -r '.outcome' <<<"${MERGE_RESULT}"
