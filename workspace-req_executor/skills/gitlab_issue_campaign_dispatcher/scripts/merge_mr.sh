#!/usr/bin/env bash
# Resolve one exact GitLab merge request and optionally attempt an immediate
# merge.  The same helper is used by the executor attempt and by Phase 6:
# `attempt` may issue the merge PUT, while `verify` is strictly read-only.
#
# Required env vars:
#   MR_IID                 project-local merge request IID
#   MERGE_REQUEST_URL      exact expected MR web URL
#   WORK_BRANCH            exact expected source branch
#   COMMIT_SHA             exact expected source HEAD
#   MERGE_TARGET_BRANCH    exact expected target branch (falls back to BRANCH)
#
# Optional env vars:
#   MERGE_MR_MODE          attempt (default) | verify
#   AUTO_MERGE             true | false (default false; ignored by verify mode)
#   DEPENDENCY_BASE_SHA    legacy ordinary dependency identity. Shared
#                          `issue/A+C` jobs are rejected before this helper and
#                          never enter automatic merge. Kept for exact recovery
#                          of older ordinary records.
#
# Output: exactly one compact JSON line.  Only
#   verified=true + outcome="merged"
# authorizes callers to apply the `finish` issue label.  GitLab read/merge
# failures are represented conservatively as outcome="unknown" (or as a
# verified still-open MR) and exit 0; only invalid local input exits non-zero.

set -euo pipefail

CALLER_WORK_BRANCH="${WORK_BRANCH-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
[ -z "${CALLER_WORK_BRANCH}" ] || WORK_BRANCH="${CALLER_WORK_BRANCH}"

MERGE_MR_MODE="${MERGE_MR_MODE:-attempt}"
AUTO_MERGE="${AUTO_MERGE:-false}"
MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH:-}}"
DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA:-}"

: "${PROJECT_URI:?merge_mr.sh: PROJECT_URI must be set}" \
  "${MR_IID:?merge_mr.sh: MR_IID must be set}" \
  "${MERGE_REQUEST_URL:?merge_mr.sh: MERGE_REQUEST_URL must be set}" \
  "${WORK_BRANCH:?merge_mr.sh: WORK_BRANCH must be set}" \
  "${MERGE_TARGET_BRANCH:?merge_mr.sh: MERGE_TARGET_BRANCH or BRANCH must be set}" \
  "${COMMIT_SHA:?merge_mr.sh: COMMIT_SHA must be set}"

case "${MERGE_MR_MODE}" in
  attempt|verify) ;;
  *)
    echo "merge_mr: MERGE_MR_MODE must be attempt or verify" >&2
    exit 2
    ;;
esac
case "${AUTO_MERGE}" in
  true|false) ;;
  *)
    echo "merge_mr: AUTO_MERGE must be true or false" >&2
    exit 2
    ;;
esac
if [[ "${WORK_BRANCH}" =~ ^issue/[1-9][0-9]*\+[1-9][0-9]*$ ]] \
    && [ "${MERGE_MR_MODE}" = attempt ] \
    && [ "${AUTO_MERGE}" = true ]; then
  echo "merge_mr: automatic merge is unsupported for shared work branches" >&2
  exit 2
fi
if ! [[ "${MR_IID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "merge_mr: MR_IID must be a positive integer" >&2
  exit 2
fi
if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  echo "merge_mr: COMMIT_SHA must be a hexadecimal Git object ID" >&2
  exit 2
fi
if [ -n "${DEPENDENCY_BASE_SHA}" ] \
    && ! [[ "${DEPENDENCY_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "merge_mr: DEPENDENCY_BASE_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
if ! git check-ref-format --branch "${WORK_BRANCH}" >/dev/null 2>&1 \
    || ! git check-ref-format --branch "${MERGE_TARGET_BRANCH}" >/dev/null 2>&1; then
  echo "merge_mr: source and target branches must be valid Git branch names" >&2
  exit 2
fi
case "${MERGE_REQUEST_URL}" in
  http://*|https://*) ;;
  *)
    echo "merge_mr: MERGE_REQUEST_URL must be an HTTP(S) URL" >&2
    exit 2
    ;;
esac
if ! jq -en \
    --arg url "${MERGE_REQUEST_URL}" \
    --arg source "${WORK_BRANCH}" \
    --arg target "${MERGE_TARGET_BRANCH}" '
      [$url,$source,$target]
      | all(.[]; length > 0 and (explode | all(. >= 32 and . != 127)))
    ' >/dev/null; then
  echo "merge_mr: URL and branch inputs must be printable non-empty strings" >&2
  exit 2
fi

MR_ENDPOINT="projects/${PROJECT_URI}/merge_requests/${MR_IID}"

read_exact_mr() {
  local response
  response="$(glab api "${MR_ENDPOINT}")" || return 1
  if ! jq -e \
      --argjson iid "${MR_IID}" \
      --arg web_url "${MERGE_REQUEST_URL}" \
      --arg source_branch "${WORK_BRANCH}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" \
      --arg sha "${COMMIT_SHA}" '
        .iid == $iid
        and .web_url == $web_url
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and (((.sha // "") | ascii_downcase) == ($sha | ascii_downcase))
        and (.state | type == "string" and length > 0)
      ' <<<"${response}" >/dev/null; then
    return 2
  fi
  printf '%s' "${response}"
}

emit_result() {
  local observed_state="$1" outcome="$2" verified="$3" \
        merge_attempted="$4" merge_api_succeeded="$5" reason="$6"
  jq -cn \
    --argjson iid "${MR_IID}" \
    --arg web_url "${MERGE_REQUEST_URL}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
    --arg sha "${COMMIT_SHA}" \
    --arg observed_state "${observed_state}" \
    --arg outcome "${outcome}" \
    --argjson verified "${verified}" \
    --argjson merge_attempted "${merge_attempted}" \
    --argjson merge_api_succeeded "${merge_api_succeeded}" \
    --arg reason "${reason}" '{
      version:1,
      iid:$iid,
      web_url:$web_url,
      source_branch:$source_branch,
      target_branch:$target_branch,
      dependency_base_sha:$dependency_base_sha,
      sha:$sha,
      observed_state:$observed_state,
      outcome:$outcome,
      verified:$verified,
      merge_attempted:$merge_attempted,
      merge_api_succeeded:$merge_api_succeeded,
      reason:$reason
    }'
}

EXACT_MR_JSON=""
if EXACT_MR_JSON="$(read_exact_mr)"; then
  :
else
  READ_RC=$?
  if [ "${READ_RC}" -eq 2 ]; then
    REASON="mr_identity_mismatch"
  else
    REASON="mr_read_failed"
  fi
  emit_result unknown unknown false false false "${REASON}"
  exit 0
fi

OBSERVED_STATE="$(jq -r '.state' <<<"${EXACT_MR_JSON}")"
MERGE_ATTEMPTED=false
MERGE_API_SUCCEEDED=false

verify_dependency_target_ancestry() {
  local target_ref="refs/remotes/origin/${MERGE_TARGET_BRANCH}"
  local repo_lock_root="${WORK_ROOT:-${REPO_PATH}/.req_executor}"
  local ancestry_rc=0

  : "${REPO_PATH:?merge_mr: REPO_PATH is required for dependency ancestry verification}"
  # shellcheck source=git_network_guard.sh
  source "${SCRIPT_DIR}/git_network_guard.sh"
  GIT_NETWORK_GUARD_CONTEXT=merge_mr_dependency_gate
  if ! mkdir -p "${repo_lock_root}/locks"; then
    DEPENDENCY_GATE_REASON="dependency_repo_lock_failed"
    return 1
  fi
  exec 8>"${repo_lock_root}/locks/repo.lock" || {
    DEPENDENCY_GATE_REASON="dependency_repo_lock_failed"
    return 1
  }
  if ! flock 8; then
    exec 8>&-
    DEPENDENCY_GATE_REASON="dependency_repo_lock_failed"
    return 1
  fi

  # All workers share the parent checkout's remote-tracking refs. Serialize
  # the fetch and every ancestry read against prepare/other merge gates so two
  # concurrent Issues cannot race on the same refs/remotes/origin/* lock.
  if ! GIT_NO_REPLACE_OBJECTS=1 git_network_guard_run "${REPO_PATH}" \
      fetch --no-tags --refmap= origin \
      "+refs/heads/${MERGE_TARGET_BRANCH}:${target_ref}" >&2; then
    DEPENDENCY_GATE_REASON="dependency_target_fetch_failed"
    ancestry_rc=1
  elif ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" cat-file -e \
      "${DEPENDENCY_BASE_SHA}^{commit}" 2>/dev/null; then
    DEPENDENCY_GATE_REASON="dependency_commit_unavailable"
    ancestry_rc=1
  elif ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" rev-parse --verify \
      "${target_ref}^{commit}" >/dev/null 2>&1; then
    DEPENDENCY_GATE_REASON="dependency_target_ref_unavailable"
    ancestry_rc=1
  elif ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
      merge-base --is-ancestor \
      "${DEPENDENCY_BASE_SHA}" "${target_ref}" >/dev/null 2>&1; then
    DEPENDENCY_GATE_REASON="dependency_not_in_merge_target"
    ancestry_rc=1
  else
    DEPENDENCY_GATE_REASON="dependency_in_merge_target"
  fi
  if ! flock -u 8; then
    DEPENDENCY_GATE_REASON="dependency_repo_unlock_failed"
    ancestry_rc=1
  fi
  exec 8>&-
  return "${ancestry_rc}"
}

verify_dependency_target_protection() {
  local protection_pages protection_rules

  if ! protection_pages="$(glab api --paginate \
      "projects/${PROJECT_URI}/protected_branches?per_page=100" \
      2>/dev/null)"; then
    DEPENDENCY_GATE_REASON="dependency_target_protection_unavailable"
    return 1
  fi
  # glab emits one JSON array per page. Slurp and flatten every page before
  # checking policy; an empty, malformed, or partially non-array response is
  # never protection evidence.
  if ! protection_rules="$(jq -cse '
      if length > 0 and all(.[]; type == "array")
      then add
      else error("invalid protected-branches response")
      end
    ' <<<"${protection_pages}" 2>/dev/null)"; then
    DEPENDENCY_GATE_REASON="dependency_target_protection_unavailable"
    return 1
  fi
  # GitLab applies the most permissive setting when multiple exact, wildcard,
  # project, or inherited rules match. Reimplementing all server-side wildcard
  # precedence here would be brittle, so use a stricter sufficient condition:
  # require an exact rule for this target and reject if *any* visible rule in
  # the project permits force-push. This can reject an unrelated permissive
  # rule, but it cannot misclassify that rule as safe for this merge.
  if ! jq -e --arg target "${MERGE_TARGET_BRANCH}" '
      type == "array"
      and any(.[]; type == "object"
        and .name == $target
        and .allow_force_push == false)
      and all(.[]; type == "object" and .allow_force_push == false)
    ' <<<"${protection_rules}" >/dev/null; then
    DEPENDENCY_GATE_REASON="dependency_target_not_immutably_protected"
    return 1
  fi
  return 0
}

# Revalidate at the mutation boundary. The preparation-time check may be hours
# old, and a target branch can be rewritten while C is being implemented.
# Verify mode repeats the fence for recovery before Phase 6 authorizes finish.
if [ -n "${DEPENDENCY_BASE_SHA}" ] \
    && { [ "${MERGE_MR_MODE}" = verify ] \
      || { [ "${MERGE_MR_MODE}" = attempt ] \
        && [ "${AUTO_MERGE}" = true ]; }; }; then
  DEPENDENCY_GATE_REASON=""
  # Protection is checked before the fresh fetch. With force-push disabled,
  # subsequent ordinary target updates can only retain the dependency
  # ancestor. Administrative unprotect/delete operations remain an external
  # deployment invariant and must be denied by the branch rule permissions.
  if ! verify_dependency_target_protection \
      || ! verify_dependency_target_ancestry; then
    if [ "${OBSERVED_STATE}" = opened ]; then
      emit_result "${OBSERVED_STATE}" opened true false false \
        "${DEPENDENCY_GATE_REASON}"
    else
      emit_result "${OBSERVED_STATE}" unknown false false false \
        "${DEPENDENCY_GATE_REASON}"
    fi
    exit 0
  fi
fi

# GitLab's merge endpoint offers a source-SHA CAS but no target-branch CAS.
# Even after the exact MR/target and ancestry checks above, another actor with
# MR update permission could retarget it before the PUT; a post-merge GET can
# detect that race but cannot undo the wrong merge. Therefore the executor
# never issues an automatic merge mutation for a dependency-based MR. It keeps
# the verified MR open for human/server-side policy to merge, while verify mode
# can still recognize an externally completed exact MR during reconciliation.
if [ -n "${DEPENDENCY_BASE_SHA}" ] \
    && [ "${MERGE_MR_MODE}" = attempt ] \
    && [ "${AUTO_MERGE}" = true ] \
    && [ "${OBSERVED_STATE}" = opened ]; then
  emit_result "${OBSERVED_STATE}" opened true false false \
    dependency_auto_merge_requires_manual_review
  exit 0
fi

if [ "${MERGE_MR_MODE}" = attempt ] \
    && [ "${AUTO_MERGE}" = true ] \
    && [ "${OBSERVED_STATE}" = opened ]; then
  MERGE_ATTEMPTED=true
  set +e
  glab api --method PUT "${MR_ENDPOINT}/merge" \
    -f "sha=${COMMIT_SHA}" \
    -f "should_remove_source_branch=false" >/dev/null
  MERGE_API_RC=$?
  set -e
  [ "${MERGE_API_RC}" -ne 0 ] || MERGE_API_SUCCEEDED=true

  # The PUT exit code is not completion evidence: a timed-out request might
  # have merged, while a successful request might only have scheduled work.
  # Re-read the exact MR and trust only its current server-side state.
  if EXACT_MR_JSON="$(read_exact_mr)"; then
    :
  else
    READ_RC=$?
    if [ "${READ_RC}" -eq 2 ]; then
      REASON="post_merge_identity_mismatch"
    else
      REASON="post_merge_read_failed"
    fi
    emit_result unknown unknown false \
      "${MERGE_ATTEMPTED}" "${MERGE_API_SUCCEEDED}" "${REASON}"
    exit 0
  fi
  OBSERVED_STATE="$(jq -r '.state' <<<"${EXACT_MR_JSON}")"
fi

case "${OBSERVED_STATE}" in
  merged)
    OUTCOME=merged
    REASON=verified_merged
    ;;
  opened)
    OUTCOME=opened
    if [ "${MERGE_MR_MODE}" = verify ]; then
      REASON=verified_opened
    elif [ "${AUTO_MERGE}" != true ]; then
      REASON=auto_merge_disabled
    elif [ "${MERGE_API_SUCCEEDED}" = true ]; then
      REASON=merge_api_succeeded_but_mr_opened
    else
      REASON=merge_api_failed_mr_opened
    fi
    ;;
  *)
    OUTCOME=unknown
    REASON=verified_non_open_non_merged_state
    ;;
esac

emit_result "${OBSERVED_STATE}" "${OUTCOME}" true \
  "${MERGE_ATTEMPTED}" "${MERGE_API_SUCCEEDED}" "${REASON}"
