#!/usr/bin/env bash
# create_mr.sh — ensure exactly ONE merge request exists for ${WORK_BRANCH}
# at the end of this attempt. Ordinary branches rotate prior attempt MRs;
# the tail of a two-Issue shared branch reuses the head's single open MR.
#
# Ordinary branches use the same MR-rotation policy in both ISSUE_MODE values:
#
#   1. List every open MR currently pointing at ${WORK_BRANCH}.
#   2. Close them without merging (the integration branch is untouched;
#      the closed MR objects remain in GitLab as historical record).
#   3. Create a fresh MR for the new attempt. When a prior MR existed, the
#      new MR's description carries `Supersedes !<old_iid>` references for
#      reviewer traceability.
#
# A frozen `issue/<A>+<C>` branch is different: A must create the only MR and
# include both closing references; C must find and reuse exactly that open MR.
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
#   LOG_DIR         fixed issue-local log directory
#   BRANCH          default target branch
#   MERGE_TARGET_BRANCH  MR target branch (optional; falls back to BRANCH)
#   AUTO_MERGE      true|false (optional; default false)
#   DEPENDENCY_IID / DEPENDENCY_BRANCH / DEPENDENCY_BASE_SHA
#                   optional complete dependency identity used to fence merge
#   COMMIT_SHA      exact source HEAD that the MR must expose
#   WORK_BRANCH     source branch (single, fixed)
#   EXECUTION_ID    opaque execution identity used only for machine fencing
#
# Output (four lines on stdout):
#   <merge-request-web-url>
#   <mr_action>            "created" when no prior open MR existed,
#                          "rotated" when a prior ordinary MR was closed first,
#                          "reused" for the tail commit of issue/<A>+<C>.
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
  "${LOG_DIR:?}" "${BRANCH:?}" "${WORK_BRANCH:?}" "${EXECUTION_ID:?}" \
  "${PROJECT_URI:?}" "${COMMIT_SHA:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_MERGE="${AUTO_MERGE:-false}"
MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH}}"
DEPENDENCY_IID="${DEPENDENCY_IID:-}"
DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH:-}"
DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA:-}"
DEPENDENCY_CONTRACT_VERSION="${DEPENDENCY_CONTRACT_VERSION:-}"
DEPENDENCY_PLAN_SHA256="${DEPENDENCY_PLAN_SHA256:-}"
SHARED_MR_RECOVERY="${SHARED_MR_RECOVERY:-false}"
MR_RESULT_FILE="${LOG_DIR}/mr_result.json"
SHARED_BRANCH=false
SHARED_BRANCH_ROLE=""
SHARED_HEAD_IID=""
SHARED_TAIL_IID=""
EXPECTED_SHARED_MR_IID=""
EXPECTED_SHARED_MR_URL=""
SHARED_MR_INTENT_ID=""
DAG_BRANCH=false
RECOVERY_MARKER_MR_IID=""
RECOVERY_MARKER_MR_URL=""
if [[ "${WORK_BRANCH}" =~ ^issue/([1-9][0-9]*)\+([1-9][0-9]*)$ ]]; then
  SHARED_BRANCH=true
  SHARED_HEAD_IID="${BASH_REMATCH[1]}"
  SHARED_TAIL_IID="${BASH_REMATCH[2]}"
  if [ "${SHARED_HEAD_IID}" = "${SHARED_TAIL_IID}" ]; then
    echo "create_mr: shared branch members must be distinct" >&2
    exit 2
  elif [ "${ISSUE_IID}" = "${SHARED_HEAD_IID}" ]; then
    SHARED_BRANCH_ROLE=head
  elif [ "${ISSUE_IID}" = "${SHARED_TAIL_IID}" ]; then
    SHARED_BRANCH_ROLE=tail
  else
    echo "create_mr: current Issue is not a member of the shared work branch" >&2
    exit 2
  fi
  if [ "${AUTO_MERGE}" != false ]; then
    echo "create_mr: automatic merge is unsupported for shared work branches" >&2
    exit 2
  fi
fi
if [ -n "${DEPENDENCY_CONTRACT_VERSION}${DEPENDENCY_PLAN_SHA256}" ]; then
  if [ "${DEPENDENCY_CONTRACT_VERSION}" != 2 ] \
      || ! [[ "${DEPENDENCY_PLAN_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
      || [ "${WORK_BRANCH}" != \
        "issue/${ISSUE_IID}-dag-${DEPENDENCY_PLAN_SHA256:0:16}" ] \
      || [ "${SHARED_BRANCH}" = true ] \
      || [ "${AUTO_MERGE}" != false ]; then
    echo "create_mr: invalid DAG-v2 branch identity" >&2
    exit 2
  fi
  DAG_BRANCH=true
fi

case "${AUTO_MERGE}" in
  true|false) ;;
  *)
    echo "create_mr: AUTO_MERGE must be true or false" >&2
    exit 2
    ;;
esac
case "${SHARED_MR_RECOVERY}" in
  true|false) ;;
  *)
    echo "create_mr: SHARED_MR_RECOVERY must be true or false" >&2
    exit 2
    ;;
esac

# The normal wrapper and the post-acpx MR-only recovery path may overlap after
# a lost callback.  Serialize every mutation/readback sequence for the exact
# source branch so two fixed wrappers cannot create or adopt competing MRs.
# Both members of issue/<A>+<C> deliberately resolve to the same lock file.
MR_FINALIZATION_LOCK_ROOT="${WORK_ROOT:-${ISSUES_ROOT:-${LOG_DIR}}}"
if [ "${SHARED_BRANCH}" = true ]; then
  MR_FINALIZATION_LOCK_FILE="${MR_FINALIZATION_LOCK_ROOT}/mr-finalization-${SHARED_HEAD_IID}-${SHARED_TAIL_IID}.lock"
else
  MR_FINALIZATION_LOCK_FILE="${MR_FINALIZATION_LOCK_ROOT}/mr-finalization-${ISSUE_IID}.lock"
fi
if [ -L "${MR_FINALIZATION_LOCK_FILE}" ]; then
  echo "create_mr: MR finalization lock must not be a symlink" >&2
  exit 2
fi
exec {MR_FINALIZATION_LOCK_FD}>"${MR_FINALIZATION_LOCK_FILE}"
chmod 600 "${MR_FINALIZATION_LOCK_FILE}"
flock -x "${MR_FINALIZATION_LOCK_FD}"

if [ -z "${MERGE_TARGET_BRANCH}" ]; then
  echo "create_mr: MERGE_TARGET_BRANCH or BRANCH must be non-empty" >&2
  exit 2
fi
if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  echo "create_mr: COMMIT_SHA must be a hexadecimal Git object ID" >&2
  exit 2
fi
if [ -n "${DEPENDENCY_IID}${DEPENDENCY_BRANCH}${DEPENDENCY_BASE_SHA}" ]; then
  if ! [[ "${DEPENDENCY_IID}" =~ ^[1-9][0-9]*$ ]] \
      || ! [[ "${DEPENDENCY_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
    echo "create_mr: dependency identity must be a complete IID/branch/full-SHA tuple" >&2
    exit 2
  fi
  if [ "${SHARED_BRANCH}" = true ]; then
    if [ "${SHARED_BRANCH_ROLE}" != tail ] \
        || [ "${DEPENDENCY_IID}" != "${SHARED_HEAD_IID}" ] \
        || [ "${DEPENDENCY_BRANCH}" != "${WORK_BRANCH}" ]; then
      echo "create_mr: shared tail dependency identity does not match the work branch" >&2
      exit 2
    fi
  elif [ "${DAG_BRANCH}" = true ]; then
    if [ -z "${DEPENDENCY_BRANCH}" ]; then
      echo "create_mr: DAG-v2 dependency anchor branch is missing" >&2
      exit 2
    fi
  elif [ "${DEPENDENCY_BRANCH}" != "issue/${DEPENDENCY_IID}" ]; then
    echo "create_mr: dependency branch does not match its IID" >&2
    exit 2
  fi
elif { [ "${SHARED_BRANCH}" = true ] \
      && [ "${SHARED_BRANCH_ROLE}" = tail ]; } \
    || [ "${DAG_BRANCH}" = true ]; then
  echo "create_mr: shared branch tail requires a complete dependency identity" >&2
  exit 2
fi

private_state_mode() {
  local path="$1" mode
  if mode="$(stat -c '%a' "${path}" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  elif mode="$(stat -f '%Lp' "${path}" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  else
    return 1
  fi
}

private_state_owner() {
  local path="$1" owner
  if owner="$(stat -c '%u' "${path}" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  elif owner="$(stat -f '%u' "${path}" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  else
    return 1
  fi
}

require_private_state_file() {
  local path="$1" mode owner bytes
  [ -f "${path}" ] && [ ! -L "${path}" ] || return 1
  mode="$(private_state_mode "${path}")" || return 1
  owner="$(private_state_owner "${path}")" || return 1
  bytes="$(wc -c <"${path}" 2>/dev/null | tr -d '[:space:]')"
  [ "${mode}" = 600 ] && [ "${owner}" = "$(id -u)" ] \
    && [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${bytes}" -le 65536 ]
}

sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

if [ "${DAG_BRANCH}" = true ]; then
  DAG_PLAN_JSON=""
  DAG_PLAN_CANONICAL=""
  DAG_PLAN_CALCULATED_SHA=""
  require_private_state_file "${ISSUE_STATE_FILE}" || {
    echo "create_mr: DAG-v2 Issue state is missing or unsafe" >&2
    exit 2
  }
  if ! jq -e \
      --argjson iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --arg commit_sha "${COMMIT_SHA}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" \
      --argjson dependency_iid "${DEPENDENCY_IID}" \
      --arg dependency_branch "${DEPENDENCY_BRANCH}" \
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
      --arg plan_sha256 "${DEPENDENCY_PLAN_SHA256}" '
      def full_oid:
        type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$");
      def positive_integer:
        type == "number" and . == floor and . > 0;
      def label_branch_source:
        . as $input
        | type == "object"
        and ((keys | sort) == ([
          "commit_sha","identity_source","iid","verified",
          "work_branch","work_branch_sha"
        ] | sort))
        and $input.identity_source == "gitlab_pr_label_branch"
        and ($input.iid | positive_integer and . <= 2147483647)
        and $input.work_branch == ("issue/" + ($input.iid | tostring))
        and ($input.commit_sha | full_oid)
        and ($input.work_branch_sha | full_oid)
        and (($input.commit_sha | ascii_downcase)
          == ($input.work_branch_sha | ascii_downcase))
        and $input.verified == true;
      def executor_source($target_branch):
        . as $input
        | type == "object"
        and ((keys | sort) == ([
          "commit_sha","execution_id","iid","mr","verified",
          "work_branch","work_branch_sha"
        ] | sort))
        and ($input.iid | positive_integer and . <= 2147483647)
        and ($input.execution_id
          | positive_integer and . <= 281474976710655)
        and (
          $input.work_branch == ("issue/" + ($input.iid | tostring))
          or ($input.work_branch | test(
            "^issue/" + ($input.iid | tostring)
            + "-dag-[0-9a-f]{16}$"))
        )
        and ($input.commit_sha | full_oid)
        and ($input.work_branch_sha | full_oid)
        and $input.verified == true
        and ($input.mr | type == "object")
        and (($input.mr | keys | sort) == ([
          "iid","sha","source_branch","state","target_branch","url"
        ] | sort))
        and ($input.mr.iid | positive_integer and . <= 2147483647)
        and ($input.mr.url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
        and ($input.mr.url | test(
          "/-/merge_requests/" + ($input.mr.iid | tostring) + "/?$"))
        and ($input.mr.state == "opened" or $input.mr.state == "merged")
        and $input.mr.source_branch == $input.work_branch
        and $input.mr.target_branch == $target_branch
        and ($input.mr.sha | full_oid)
        and (
          if $input.mr.state == "opened" then
            (($input.mr.sha | ascii_downcase)
              == ($input.work_branch_sha | ascii_downcase))
          else
            (($input.mr.sha | ascii_downcase)
              == ($input.commit_sha | ascii_downcase))
            or (($input.mr.sha | ascii_downcase)
              == ($input.work_branch_sha | ascii_downcase))
          end
        );
      def source_snapshot($target_branch):
        label_branch_source or executor_source($target_branch);
      .dependency_plan as $plan
      | ($plan.effective_inputs | map(.iid)) as $effective_iids
      |
      type == "object"
      and .iid == $iid
      and .latest_execution_id == $execution_id
      and .dependency_pinned_execution_id == $execution_id
      and .dependency_contract_version == 2
      and .dependency_plan_sha256 == $plan_sha256
      and (.dependency_plan | type == "object")
      and ((.dependency_plan | keys | sort) == ([
        "aggregate_base_sha","consumer_iid","declared_inputs",
        "effective_inputs","plan_sha256","target_branch","version",
        "work_branch"
      ] | sort))
      and .dependency_plan.version == 2
      and .dependency_plan.consumer_iid == $iid
      and .dependency_plan.plan_sha256 == $plan_sha256
      and .dependency_plan.work_branch == $work_branch
      and .dependency_plan.target_branch == $target_branch
      and .dependency_plan.aggregate_base_sha == $dependency_base_sha
      and (.dependency_plan.aggregate_base_sha | full_oid)
      and (.dependency_plan.declared_inputs | type == "array"
        and length >= 1 and length <= 8)
      and ([.dependency_plan.declared_inputs[].iid]
        | length == (unique | length))
      and all(.dependency_plan.declared_inputs[];
        source_snapshot($target_branch))
      and (.dependency_plan.effective_inputs | type == "array"
        and length >= 1 and length <= 8)
      and ([.dependency_plan.effective_inputs[].iid]
        | length == (unique | length))
      and all(.dependency_plan.effective_inputs[];
        . as $effective
        | any($plan.declared_inputs[]; . == $effective))
      and ([
        $plan.declared_inputs[].iid
        | . as $declared_iid
        | select($effective_iids | index($declared_iid) != null)
      ] == $effective_iids)
      and .dependency_plan.declared_inputs[0].iid == $dependency_iid
      and .dependency_plan.declared_inputs[0].work_branch == $dependency_branch
      and .work_branch == $work_branch
      and .branch_members == [$iid]
      and (.shared_branch_role // null) == null
      and .dependency_iid == $dependency_iid
      and .dependency_branch == $dependency_branch
      and .dependency_base_sha == $dependency_base_sha
      and .dependency_history_verified == true
      and ((.commit_sha | ascii_downcase) == ($commit_sha | ascii_downcase))
      and ((.work_branch_sha | ascii_downcase)
        == ($commit_sha | ascii_downcase))
    ' "${ISSUE_STATE_FILE}" >/dev/null 2>&1; then
    echo "create_mr: DAG-v2 Issue state does not match the fixed execution" >&2
    exit 2
  fi
  DAG_PLAN_JSON="$(jq -cS '.dependency_plan' "${ISSUE_STATE_FILE}")" || exit 2
  DAG_PLAN_CANONICAL="$(printf '%s' "${DAG_PLAN_JSON}" | jq -cS '{
    version:2,
    algorithm:"ordered-frontier-merge-v1",
    consumer_iid:.consumer_iid,
    target_branch:.target_branch,
    declared_inputs:.declared_inputs,
    effective_inputs:.effective_inputs,
    aggregate_base_sha:.aggregate_base_sha
  }')" || exit 2
  DAG_PLAN_CALCULATED_SHA="$(sha256_text "${DAG_PLAN_CANONICAL}")" || {
    echo "create_mr: unable to hash DAG-v2 dependency plan" >&2
    exit 2
  }
  if [ "${DAG_PLAN_CALCULATED_SHA}" != "${DEPENDENCY_PLAN_SHA256}" ]; then
    echo "create_mr: DAG-v2 dependency plan digest mismatch" >&2
    exit 2
  fi
fi

# Every shared MR operation is authorized by the private post-push checkpoint.
# A generates this intent; C inherits it from A's verified binding. The same
# high-entropy value is embedded in the MR description and prevents a recovery
# retry from adopting an externally pre-created MR for the branch.
if [ "${SHARED_BRANCH}" = true ]; then
  require_private_state_file "${ISSUE_STATE_FILE}" || {
    echo "create_mr: shared Issue state is missing or unsafe" >&2
    exit 2
  }
  SHARED_MR_INTENT_ID="$(jq -er \
    --argjson iid "${ISSUE_IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg work_branch "${WORK_BRANCH}" \
    --argjson head_iid "${SHARED_HEAD_IID}" \
    --argjson tail_iid "${SHARED_TAIL_IID}" \
    --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
    --arg commit_sha "${COMMIT_SHA}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" '
    if .iid == $iid
      and .work_branch == $work_branch
      and .branch_members == [$head_iid,$tail_iid]
      and .shared_branch_role == $shared_branch_role
      and .dependency_history_verified == true
      and ((.work_branch_sha | ascii_downcase) == ($commit_sha | ascii_downcase))
      and (.mr_finalization | type == "object")
      and ((.mr_finalization | keys | sort) == ([
        "branch_members","commit_sha","intent_id","shared_branch_role",
        "source_execution_id","status","target_branch","work_branch"
      ] | sort))
      and .mr_finalization.status == "pending"
      and .mr_finalization.source_execution_id == $execution_id
      and .mr_finalization.work_branch == $work_branch
      and .mr_finalization.branch_members == [$head_iid,$tail_iid]
      and .mr_finalization.shared_branch_role == $shared_branch_role
      and ((.mr_finalization.commit_sha | ascii_downcase)
        == ($commit_sha | ascii_downcase))
      and .mr_finalization.target_branch == $target_branch
      and (.mr_finalization.intent_id | type == "string"
        and test("^[0-9a-f]{64}$"))
    then .mr_finalization.intent_id else empty end
  ' "${ISSUE_STATE_FILE}" 2>/dev/null)" || {
    echo "create_mr: shared MR pending intent is missing or mismatched" >&2
    exit 2
  }
fi

# The tail may only reuse the exact MR that the completed head persisted. An
# arbitrary open MR for the same source branch is not group ownership proof.
if [ "${SHARED_BRANCH_ROLE}" = tail ]; then
  : "${ISSUES_ROOT:?create_mr: ISSUES_ROOT must be set for a shared tail}"
  SHARED_HEAD_STATE_FILE="${ISSUES_ROOT}/issue-${SHARED_HEAD_IID}/state.json"
  if ! require_private_state_file "${SHARED_HEAD_STATE_FILE}"; then
    echo "create_mr: shared branch head state is missing or unsafe" >&2
    exit 2
  fi
  if ! EXPECTED_SHARED_MR_URL="$(jq -er \
      --argjson head "${SHARED_HEAD_IID}" \
      --argjson tail "${SHARED_TAIL_IID}" \
      --arg branch "${WORK_BRANCH}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" \
      --arg intent_id "${SHARED_MR_INTENT_ID}" \
      --arg dependency_sha "${DEPENDENCY_BASE_SHA}" '
      if .iid == $head
        and .status == "done"
        and .work_branch == $branch
        and .branch_members == [$head, $tail]
        and .shared_branch_role == "head"
        and .dependency_history_verified == true
        and ((.work_branch_sha | ascii_downcase)
          == (.commit_sha | ascii_downcase))
        and ((.commit_sha | ascii_downcase)
          == ($dependency_sha | ascii_downcase))
        and (.merge_request_url | type == "string" and length > 0)
        and (.mr_finalization | type == "object")
        and .mr_finalization.status == "verified_open"
        and .mr_finalization.work_branch == $branch
        and .mr_finalization.branch_members == [$head,$tail]
        and .mr_finalization.shared_branch_role == "head"
        and ((.mr_finalization.commit_sha | ascii_downcase)
          == ($dependency_sha | ascii_downcase))
        and .mr_finalization.target_branch == $target_branch
        and .mr_finalization.intent_id == $intent_id
        and .mr_finalization.mr_action == "created"
        and (.mr_finalization.iid | type == "number"
          and . == floor and . > 0)
        and .mr_finalization.web_url == .merge_request_url
        and ((.mr_finalization.web_url) as $url
          | (.mr_finalization.iid | tostring) as $mr_iid
          | $url | test("/-/merge_requests/" + $mr_iid + "/?$"))
      then .merge_request_url else empty end
    ' "${SHARED_HEAD_STATE_FILE}" 2>/dev/null)"; then
    echo "create_mr: shared branch head state does not bind the expected MR" >&2
    exit 2
  fi
  if [[ "${EXPECTED_SHARED_MR_URL}" =~ /-/merge_requests/([1-9][0-9]*)/?$ ]]; then
    EXPECTED_SHARED_MR_IID="${BASH_REMATCH[1]}"
  else
    echo "create_mr: shared branch head MR URL is invalid" >&2
    exit 2
  fi
fi

# Preserve any exact prior MR identity before invalidating the issue-local marker.
# A recovery call may re-verify this MR, but it must never use a closed or moved
# MR as permission to create a replacement and violate the one-MR invariant.
if [ "${SHARED_BRANCH_ROLE}" = head ] \
    && [ "${SHARED_MR_RECOVERY}" = true ] \
    && require_private_state_file "${MR_RESULT_FILE}"; then
  RECOVERY_MARKER_IDENTITY="$(jq -ce \
    --argjson issue_iid "${ISSUE_IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg sha "${COMMIT_SHA}" \
    --arg intent_id "${SHARED_MR_INTENT_ID}" '
      if type == "object"
        and (keys | sort) == ([
          "execution_id","auto_merge","dependency_base_sha","iid",
          "issue_iid","merge_api_succeeded","merge_attempted","mr_action",
          "observed_state","outcome","reason","sha","shared_mr_intent_id",
          "source_branch","target_branch","verified","version","web_url"
        ] | sort)
        and .version == 1
        and .issue_iid == $issue_iid
        and .execution_id == $execution_id
        and .auto_merge == false
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
        and .shared_mr_intent_id == $intent_id
        and .mr_action == "created"
        and (.iid | type == "number" and . == floor and . > 0)
        and (.web_url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/"
            + (.iid | tostring) + "/?$"))
      then {iid:.iid,web_url:.web_url} else empty end
    ' "${MR_RESULT_FILE}" 2>/dev/null || true)"
  if [ -n "${RECOVERY_MARKER_IDENTITY}" ]; then
    RECOVERY_MARKER_MR_IID="$(jq -r '.iid' \
      <<<"${RECOVERY_MARKER_IDENTITY}")"
    RECOVERY_MARKER_MR_URL="$(jq -r '.web_url' \
      <<<"${RECOVERY_MARKER_IDENTITY}")"
  fi
fi

# An existing issue-local file is untrusted input because the inner model can
# write inside LOG_DIR. Invalidate a regular file before any GitLab mutation;
# quarantine unsafe filesystem shapes without assigning them an attempt path.
# Only this fixed script may create the marker consumed for recovery below.
if [ -e "${MR_RESULT_FILE}" ] || [ -L "${MR_RESULT_FILE}" ]; then
  if [ -L "${MR_RESULT_FILE}" ] || [ ! -f "${MR_RESULT_FILE}" ]; then
    MR_QUARANTINE_ROOT="${WORKTREES_ROOT:-${WORK_ROOT}}/.quarantine/issue-${ISSUE_IID}"
    mkdir -p "${MR_QUARANTINE_ROOT}"
    mv "${MR_RESULT_FILE}" \
      "${MR_QUARANTINE_ROOT}/unsafe-mr-result.quarantined.$$.${RANDOM}"
  else
    MR_RESULT_RESET_TMP="$(umask 077; mktemp "${LOG_DIR}/.mr-result-reset.XXXXXX")"
    chmod 600 "${MR_RESULT_RESET_TMP}"
    mv -f "${MR_RESULT_RESET_TMP}" "${MR_RESULT_FILE}"
  fi
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

CURRENT_GITLAB_USERNAME=""
if [ "${SHARED_BRANCH}" = true ]; then
  CURRENT_GITLAB_USERNAME="$(glab api user \
    | jq -er '.username | select(type == "string" and length > 0 and length <= 255)')" || {
    echo "create_mr: unable to resolve the current GitLab principal" >&2
    exit 5
  }
fi

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

read_owned_shared_mr() {
  local mr_iid="$1" mr_url="$2" response marker_text closes_head closes_tail
  [ "${SHARED_BRANCH}" = true ] || return 1
  marker_text="<!-- req_executor-shared-mr-intent:${SHARED_MR_INTENT_ID} -->"
  closes_head="Closes #${SHARED_HEAD_IID}"
  closes_tail="Closes #${SHARED_TAIL_IID}"
  response="$(glab api \
    "projects/${PROJECT_URI}/merge_requests/${mr_iid}")" || return 1
  jq -ce \
    --argjson iid "${mr_iid}" \
    --arg web_url "${mr_url}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg sha "${COMMIT_SHA}" \
    --arg marker_text "${marker_text}" \
    --arg author_username "${CURRENT_GITLAB_USERNAME}" \
    --arg closes_head "${closes_head}" \
    --arg closes_tail "${closes_tail}" '
    if .iid == $iid
      and .web_url == $web_url
      and .source_branch == $source_branch
      and .target_branch == $target_branch
      and (((.sha // "") | ascii_downcase) == ($sha | ascii_downcase))
      and .state == "opened"
      and .author.username == $author_username
      and (.description | type == "string" and contains($marker_text))
      and ((.description | split("\n")) | index($closes_head) != null)
      and ((.description | split("\n")) | index($closes_tail) != null)
    then . else error("shared MR ownership mismatch") end
  ' <<<"${response}" 2>/dev/null
}

list_owned_shared_mrs_all_states() {
  local encoded_source response marker_text closes_head closes_tail
  local page=1 page_count page_rows previous_page_rows="" all_rows='[]'
  local history_complete=true
  [ "${SHARED_BRANCH_ROLE}" = head ] || return 1
  encoded_source="$(jq -rn --arg value "${WORK_BRANCH}" '$value | @uri')" \
    || return 1
  while :; do
    response="$(glab api \
      "projects/${PROJECT_URI}/merge_requests?scope=all&state=all&source_branch=${encoded_source}&per_page=100&page=${page}")" \
      || return 1
    page_rows="$(jq -ce '
      if type == "array" and length <= 100
        and all(.[];
          type == "object"
          and (.iid | type == "number" and . == floor and . > 0)
          and (.web_url | type == "string" and length > 0)
          and (.source_branch | type == "string")
          and (.target_branch | type == "string")
          and (.sha | type == "string")
          and (.state | type == "string")
          and (.author.username | type == "string")
          and (.description | type == "string"))
      then . else error("invalid shared MR history page") end
    ' <<<"${response}" 2>/dev/null)" || return 1
    page_count="$(jq -r 'length' <<<"${page_rows}")"

    # A proxy or test double that ignores `page` must not keep recovery in an
    # unbounded read loop. Treat a repeated full page (or the hard safety cap)
    # as incomplete history; the caller persists terminal conflict evidence
    # from the identities already observed and never creates a replacement MR.
    if [ "${page_count}" -eq 100 ] \
        && [ -n "${previous_page_rows}" ] \
        && [ "${page_rows}" = "${previous_page_rows}" ]; then
      history_complete=false
      break
    fi
    all_rows="$(jq -cn \
      --argjson prior "${all_rows}" \
      --argjson current "${page_rows}" '$prior + $current')" || return 1
    [ "${page_count}" -lt 100 ] && break
    if [ "${page}" -ge 1000 ]; then
      history_complete=false
      break
    fi
    previous_page_rows="${page_rows}"
    page=$((page + 1))
  done

  marker_text="<!-- req_executor-shared-mr-intent:${SHARED_MR_INTENT_ID} -->"
  closes_head="Closes #${SHARED_HEAD_IID}"
  closes_tail="Closes #${SHARED_TAIL_IID}"
  jq -nce \
    --argjson rows "${all_rows}" \
    --argjson history_complete "${history_complete}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg marker_text "${marker_text}" \
    --arg author_username "${CURRENT_GITLAB_USERNAME}" \
    --arg closes_head "${closes_head}" \
    --arg closes_tail "${closes_tail}" '
      [$rows[] | select(.source_branch == $source_branch)] as $source_rows
      | {
          history_complete:$history_complete,
          source_history_count:($source_rows | length),
          source:[$source_rows[] |
            {iid,web_url,state,source_branch,target_branch,sha}],
          owned:[$source_rows[] | select(
            .source_branch == $source_branch
            and .author.username == $author_username
            and (.description | type == "string" and contains($marker_text))
            and ((.description | split("\n")) | index($closes_head) != null)
            and ((.description | split("\n")) | index($closes_tail) != null)
            and (.iid | type == "number" and . == floor and . > 0)
            and (.web_url | type == "string" and length > 0)
          ) | {iid,web_url,state,source_branch,target_branch,sha}]
        }
    ' 2>/dev/null
}

# Persist read-only identity evidence for Phase 6 before returning a
# deterministic shared-MR conflict. The evidence never authorizes success by
# itself: Phase 6 binds it to the private commit intent and performs a fresh
# exact GitLab read. This prevents a closed, moved, retargeted, or foreign MR
# from leaving the scheduler claim permanently pending after recovery refuses
# to create a replacement.
persist_shared_mr_identity_evidence() {
  local mr_iid="$1" mr_url="$2" evidence_reason="$3"
  local evidence_action=created evidence_tmp
  [ "${SHARED_BRANCH}" = true ] || return 1
  [[ "${mr_iid}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${mr_url}" =~ ^https?://[^[:space:]]+/-/merge_requests/${mr_iid}/?$ ]] \
    || return 1
  case "${evidence_reason}" in
    shared_mr_live_recheck_required|shared_mr_history_conflict) ;;
    *) return 1 ;;
  esac
  [ "${SHARED_BRANCH_ROLE}" != tail ] || evidence_action=reused
  evidence_tmp="$(mktemp "${MR_RESULT_FILE}.tmp.XXXXXX")"
  if ! jq -cn \
      --argjson iid "${mr_iid}" \
      --arg web_url "${mr_url}" \
      --arg source_branch "${WORK_BRANCH}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" \
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
      --arg sha "${COMMIT_SHA}" \
      --arg reason "${evidence_reason}" \
      --arg mr_action "${evidence_action}" \
      --argjson issue_iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg shared_mr_intent_id "${SHARED_MR_INTENT_ID}" '{
        version:1,iid:$iid,web_url:$web_url,
        source_branch:$source_branch,target_branch:$target_branch,
        dependency_base_sha:$dependency_base_sha,sha:$sha,
        observed_state:"unknown",outcome:"unknown",verified:false,
        merge_attempted:false,merge_api_succeeded:false,reason:$reason,
        mr_action:$mr_action,issue_iid:$issue_iid,
        execution_id:$execution_id,auto_merge:false,
        shared_mr_intent_id:$shared_mr_intent_id
      }' >"${evidence_tmp}"; then
    return 1
  fi
  chmod 600 "${evidence_tmp}"
  mv "${evidence_tmp}" "${MR_RESULT_FILE}"
}

# Look up any open MR currently pointing at this branch.  This read is the
# mutation fence: an auth/network failure must not be mistaken for an empty
# list, otherwise the script could create a duplicate or close the wrong set.
if ! EXISTING_JSON="$(list_open_mrs_for_work_branch)"; then
  echo "create_mr: failed to list existing open MRs for ${WORK_BRANCH}" >&2
  exit 5
fi
EXISTING_COUNT="$(echo "${EXISTING_JSON}" | jq -r 'length')"
OWNED_SHARED_HISTORY_JSON='{ "history_complete":true, "source_history_count":0, "source":[], "owned":[] }'
OWNED_SHARED_HISTORY_COUNT=0
SHARED_SOURCE_HISTORY_COUNT=0
SHARED_HISTORY_COMPLETE=true
SHARED_SOURCE_FIRST_IID=""
SHARED_SOURCE_FIRST_URL=""
if [ "${SHARED_BRANCH_ROLE}" = head ]; then
  if ! OWNED_SHARED_HISTORY_JSON="$(list_owned_shared_mrs_all_states)"; then
    echo "create_mr: failed to inspect the complete shared MR history" >&2
    exit 5
  fi
  OWNED_SHARED_HISTORY_COUNT="$(jq -r '.owned | length' \
    <<<"${OWNED_SHARED_HISTORY_JSON}")"
  SHARED_SOURCE_HISTORY_COUNT="$(jq -r '.source_history_count' \
    <<<"${OWNED_SHARED_HISTORY_JSON}")"
  SHARED_HISTORY_COMPLETE="$(jq -r '.history_complete' \
    <<<"${OWNED_SHARED_HISTORY_JSON}")"
  if [ "${SHARED_SOURCE_HISTORY_COUNT}" -gt 0 ]; then
    SHARED_SOURCE_FIRST_IID="$(jq -r '.source[0].iid' \
      <<<"${OWNED_SHARED_HISTORY_JSON}")"
    SHARED_SOURCE_FIRST_URL="$(jq -r '.source[0].web_url' \
      <<<"${OWNED_SHARED_HISTORY_JSON}")"
  fi
  if [ "${SHARED_HISTORY_COMPLETE}" != true ]; then
    if [ "${SHARED_SOURCE_HISTORY_COUNT}" -gt 0 ]; then
      persist_shared_mr_identity_evidence \
        "${SHARED_SOURCE_FIRST_IID}" "${SHARED_SOURCE_FIRST_URL}" \
        shared_mr_history_conflict || exit 5
      echo "create_mr: shared MR history pagination is incomplete or repeating" >&2
      exit 6
    fi
    echo "create_mr: shared MR history pagination is incomplete without a usable identity" >&2
    exit 5
  fi
  if [ "${SHARED_SOURCE_HISTORY_COUNT}" -gt 1 ]; then
    persist_shared_mr_identity_evidence \
      "${SHARED_SOURCE_FIRST_IID}" "${SHARED_SOURCE_FIRST_URL}" \
      shared_mr_history_conflict || exit 5
    echo "create_mr: multiple historical MRs exist for the shared source branch" >&2
    exit 6
  fi
  if [ "${OWNED_SHARED_HISTORY_COUNT}" -gt 1 ]; then
    echo "create_mr: multiple MRs carry the current shared ownership intent" >&2
    exit 6
  fi
fi

# Ordinary branches close existing open MRs before creating a new one. Both fresh
# and continue modes now follow the same rotation policy so every new
# attempt produces a fresh MR object — reviewers see each attempt as its
# own MR rather than a force-pushed branch silently updating an old MR.
# Closing — not merging — preserves the history without changing the
# integration branch.
SUPERSEDES_LINE=""
MR_ACTION="created"
REUSE_EXISTING=false
if [ "${SHARED_BRANCH}" = true ] && [ "${SHARED_BRANCH_ROLE}" = tail ]; then
  if [ "${EXISTING_COUNT}" -ne 1 ]; then
    tail_evidence_reason=shared_mr_live_recheck_required
    if [ "${EXISTING_COUNT}" -gt 1 ]; then
      tail_evidence_reason=shared_mr_history_conflict
    fi
    persist_shared_mr_identity_evidence \
      "${EXPECTED_SHARED_MR_IID}" "${EXPECTED_SHARED_MR_URL}" \
      "${tail_evidence_reason}" || exit 5
    echo "create_mr: shared branch tail expected exactly one open MR, found ${EXISTING_COUNT}" >&2
    exit 6
  fi
  if ! jq -e \
      --argjson iid "${EXPECTED_SHARED_MR_IID}" \
      --arg web_url "${EXPECTED_SHARED_MR_URL}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      .[0].iid == $iid
      and .[0].web_url == $web_url
      and ((.[0].target_branch // $target_branch) == $target_branch)
      ' <<<"${EXISTING_JSON}" >/dev/null; then
    persist_shared_mr_identity_evidence \
      "${EXPECTED_SHARED_MR_IID}" "${EXPECTED_SHARED_MR_URL}" \
      shared_mr_live_recheck_required || exit 5
    echo "create_mr: open MR does not match the shared head's durable MR identity" >&2
    exit 6
  fi
  if ! read_owned_shared_mr "${EXPECTED_SHARED_MR_IID}" \
      "${EXPECTED_SHARED_MR_URL}" >/dev/null; then
    persist_shared_mr_identity_evidence \
      "${EXPECTED_SHARED_MR_IID}" "${EXPECTED_SHARED_MR_URL}" \
      shared_mr_live_recheck_required || exit 5
    echo "create_mr: open MR does not carry the shared group's exact ownership intent" >&2
    exit 6
  fi
  REUSE_EXISTING=true
  MR_ACTION="reused"
elif [ "${SHARED_BRANCH_ROLE}" = head ] \
    && [ "${SHARED_MR_RECOVERY}" = true ]; then
  # Recovery may either create the first MR when no owned MR has ever existed,
  # or re-verify the one owned MR. A closed, merged, retargeted, or moved MR is
  # terminal evidence, never permission to create a replacement.
  if [ "${OWNED_SHARED_HISTORY_COUNT}" -eq 1 ]; then
    recovery_iid="$(jq -r '.owned[0].iid' <<<"${OWNED_SHARED_HISTORY_JSON}")"
    recovery_url="$(jq -r '.owned[0].web_url' <<<"${OWNED_SHARED_HISTORY_JSON}")"
    if { [ -n "${RECOVERY_MARKER_MR_IID}" ] \
          && { [ "${RECOVERY_MARKER_MR_IID}" != "${recovery_iid}" ] \
            || [ "${RECOVERY_MARKER_MR_URL}" != "${recovery_url}" ]; }; } \
        || [ "${EXISTING_COUNT}" -ne 1 ] \
        || ! jq -e \
          --argjson iid "${recovery_iid}" \
          --arg web_url "${recovery_url}" '
            .[0].iid == $iid and .[0].web_url == $web_url
          ' <<<"${EXISTING_JSON}" >/dev/null \
        || ! read_owned_shared_mr \
          "${recovery_iid}" "${recovery_url}" >/dev/null; then
      persist_shared_mr_identity_evidence \
        "${recovery_iid}" "${recovery_url}" \
        shared_mr_live_recheck_required || exit 5
      echo "create_mr: the one owned shared MR is no longer exactly open" >&2
      exit 6
    fi
    REUSE_EXISTING=true
    MR_ACTION="created"
  elif [ "${SHARED_SOURCE_HISTORY_COUNT}" -ne 0 ] \
      || [ -n "${RECOVERY_MARKER_MR_IID}" ]; then
    if [ "${SHARED_SOURCE_HISTORY_COUNT}" -eq 1 ]; then
      persist_shared_mr_identity_evidence \
        "${SHARED_SOURCE_FIRST_IID}" "${SHARED_SOURCE_FIRST_URL}" \
        shared_mr_live_recheck_required || exit 5
    else
      persist_shared_mr_identity_evidence \
        "${RECOVERY_MARKER_MR_IID}" "${RECOVERY_MARKER_MR_URL}" \
        shared_mr_history_conflict || exit 5
    fi
    echo "create_mr: shared MR history exists without one exact open owned MR; refusing replacement" >&2
    exit 6
  elif [ "${EXISTING_COUNT}" -ne 0 ]; then
    persist_shared_mr_identity_evidence \
      "$(jq -r '.[0].iid' <<<"${EXISTING_JSON}")" \
      "$(jq -r '.[0].web_url' <<<"${EXISTING_JSON}")" \
      shared_mr_history_conflict || exit 5
    echo "create_mr: shared branch head refuses an unowned existing MR" >&2
    exit 6
  fi
elif [ "${SHARED_BRANCH_ROLE}" = head ]; then
  if [ "${SHARED_SOURCE_HISTORY_COUNT}" -ne 0 ] \
      || [ "${EXISTING_COUNT}" -ne 0 ]; then
    if [ "${SHARED_SOURCE_HISTORY_COUNT}" -eq 1 ]; then
      persist_shared_mr_identity_evidence \
        "${SHARED_SOURCE_FIRST_IID}" "${SHARED_SOURCE_FIRST_URL}" \
        shared_mr_history_conflict || exit 5
    else
      persist_shared_mr_identity_evidence \
        "$(jq -r '.[0].iid' <<<"${EXISTING_JSON}")" \
        "$(jq -r '.[0].web_url' <<<"${EXISTING_JSON}")" \
        shared_mr_history_conflict || exit 5
    fi
    echo "create_mr: shared branch history already exists; only exact recovery may reuse its one MR" >&2
    exit 6
  fi
elif [ "${EXISTING_COUNT}" -gt 0 ]; then
  SUPERSEDES_REFS="$(echo "${EXISTING_JSON}" | jq -r 'map("!" + (.iid|tostring)) | join(", ")')"
  echo "${EXISTING_JSON}" | jq -r '.[].iid' | while IFS= read -r existing_iid; do
    glab mr close "${existing_iid}" \
      --repo "${PROJECT_FULL}" >/dev/null || {
      echo "create_mr: failed to close MR !${existing_iid}" >&2
      exit 4
    }
  done
  SUPERSEDES_LINE="Supersedes ${SUPERSEDES_REFS} (closed by a req_executor re-run; mode=${ISSUE_MODE})."
  MR_ACTION="rotated"
fi

# Build / refresh the MR description. `Closes #<iid>` triggers GitLab's
# native auto-close when this MR is eventually merged.
DESC_FILE="${LOG_DIR}/mr_description.md"
if [ "${REUSE_EXISTING}" != true ]; then
  {
    if [ "${SHARED_BRANCH}" = true ]; then
      echo "Closes #${SHARED_HEAD_IID}"
      echo "Closes #${SHARED_TAIL_IID}"
      echo "<!-- req_executor-shared-mr-intent:${SHARED_MR_INTENT_ID} -->"
    else
      echo "Closes #${ISSUE_IID}"
    fi
    echo
    if [ -n "${SUPERSEDES_LINE}" ]; then
      echo "${SUPERSEDES_LINE}"
      echo
    fi
    if [ "${SHARED_BRANCH}" = true ]; then
      echo "Auto-generated shared MR for issues #${SHARED_HEAD_IID} and #${SHARED_TAIL_IID}."
    else
      echo "Auto-generated MR for issue #${ISSUE_IID} (mode=${ISSUE_MODE})."
    fi
    echo
    echo "The complete staging-time execution log directory is committed and"
    echo "pushed together with the business changes on this Issue branch."
    echo "Terminal evidence is appended later as a log-only child on the same branch"
    echo "when doing so preserves the exact MR recovery fence."
    echo
    echo "Per-attempt summaries remain in the executor's local issue state and are not posted as issue comments."
    echo
    if [ "${AUTO_MERGE}" = true ]; then
      echo "req_executor will attempt an immediate merge; if GitLab does not confirm it, this MR remains available for normal review."
    else
      echo "Do not merge until reviewed."
    fi
  } > "${DESC_FILE}"
fi

# NOTE: --description (inline string) is used instead of --description-file
# because some runner-installed glab versions don't recognize the latter.
# See SOUL.md §GitLab Access — verify any new flag with `glab <subcmd> --help`
# on the runner before adopting it.
if [ "${REUSE_EXISTING}" != true ]; then
  glab mr create \
    --repo "${PROJECT_FULL}" \
    --source-branch "${WORK_BRANCH}" \
    --target-branch "${MERGE_TARGET_BRANCH}" \
    --title "Issue #${ISSUE_IID}: ${ISSUE_TITLE}" \
    --description "$(cat "${DESC_FILE}")" \
    --yes >/dev/null
fi

OPEN_JSON="$(
  list_open_mrs_for_work_branch
)"
OPEN_COUNT="$(echo "${OPEN_JSON}" | jq -r 'length')"
if [ "${OPEN_COUNT}" -ne 1 ]; then
  if [ "${SHARED_BRANCH}" = true ] && [ "${OPEN_COUNT}" -gt 0 ]; then
    persist_shared_mr_identity_evidence \
      "$(jq -r '.[0].iid' <<<"${OPEN_JSON}")" \
      "$(jq -r '.[0].web_url' <<<"${OPEN_JSON}")" \
      shared_mr_history_conflict || exit 5
  fi
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
if [ "${SHARED_BRANCH}" = true ] \
    && ! read_owned_shared_mr "${MR_IID}" "${MR_URL}" >/dev/null; then
  persist_shared_mr_identity_evidence \
    "${MR_IID}" "${MR_URL}" shared_mr_live_recheck_required || exit 5
  echo "create_mr: shared MR ownership could not be verified" >&2
  exit 6
fi

persist_mr_result() {
  local result_json="$1" result_tmp
  result_tmp="$(mktemp "${MR_RESULT_FILE}.tmp.XXXXXX")"
  if ! jq -c \
      --arg mr_action "${MR_ACTION}" \
      --argjson issue_iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --argjson auto_merge "${AUTO_MERGE}" \
      --argjson shared_branch "${SHARED_BRANCH}" \
      --arg shared_mr_intent_id "${SHARED_MR_INTENT_ID}" '
        . + {
          mr_action:$mr_action,
          issue_iid:$issue_iid,
          execution_id:$execution_id,
          auto_merge:$auto_merge
        }
        | if $shared_branch then
            .shared_mr_intent_id = $shared_mr_intent_id
          else . end
      ' <<<"${result_json}" >"${result_tmp}"; then
    echo "create_mr: failed to render ${MR_RESULT_FILE}" >&2
    return 1
  fi
  chmod 600 "${result_tmp}"
  mv "${result_tmp}" "${MR_RESULT_FILE}"
}

# Persist before emitting stdout. If the process is interrupted after identity
# discovery, callback recovery can rely on the private marker rather than on a
# possibly truncated stdout stream.
INITIAL_RESULT="$(jq -cn \
  --argjson iid "${MR_IID}" \
  --arg web_url "${MR_URL}" \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
  --arg sha "${COMMIT_SHA}" '{
    version:1,
    iid:$iid,
    web_url:$web_url,
    source_branch:$source_branch,
    target_branch:$target_branch,
    dependency_base_sha:$dependency_base_sha,
    sha:$sha,
    observed_state:"unknown",
    outcome:"unknown",
    verified:false,
    merge_attempted:false,
    merge_api_succeeded:false,
    reason:"exact_mr_verification_pending"
  }')"
persist_mr_result "${INITIAL_RESULT}"
printf '%s\n%s\n%s\n' "${MR_URL}" "${MR_ACTION}" "${MR_IID}"

set +e
MERGE_RESULT="$(
  MERGE_MR_MODE=attempt \
  AUTO_MERGE="${AUTO_MERGE}" \
  MR_IID="${MR_IID}" \
  MERGE_REQUEST_URL="${MR_URL}" \
  WORK_BRANCH="${WORK_BRANCH}" \
  MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
  DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA}" \
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
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
      --arg sha "${COMMIT_SHA}" '
        type == "object"
        and .version == 1
        and .iid == $iid
        and .web_url == $web_url
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.dependency_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
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
    --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
    --arg sha "${COMMIT_SHA}" '{
      version:1,
      iid:$iid,
      web_url:$web_url,
      source_branch:$source_branch,
      target_branch:$target_branch,
      dependency_base_sha:$dependency_base_sha,
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

# A shared branch has one MR identity for two independently completed Issues.
# Neither member may publish success while the exact source SHA is merely
# pending/unknown: doing so would let A release C, or let C finish, without
# proving that the shared MR now points at the commit just pushed above.
if [ "${SHARED_BRANCH}" = true ] \
    && ! jq -e '
      .verified == true
      and .outcome == "opened"
      and .observed_state == "opened"
    ' <<<"${MERGE_RESULT}" >/dev/null; then
  echo "create_mr: shared MR identity was not exactly verified as opened" >&2
  exit 7
fi

jq -r '.outcome' <<<"${MERGE_RESULT}"
