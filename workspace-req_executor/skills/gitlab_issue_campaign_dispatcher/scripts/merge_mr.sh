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
if ! [[ "${MR_IID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "merge_mr: MR_IID must be a positive integer" >&2
  exit 2
fi
if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  echo "merge_mr: COMMIT_SHA must be a hexadecimal Git object ID" >&2
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
