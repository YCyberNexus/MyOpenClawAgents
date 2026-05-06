#!/usr/bin/env bash
# preflight_issue.sh — gitlab-issues-style dispatcher preflight for one IID.
# It verifies repo/auth reachability, skips fresh-mode IIDs already represented
# by an open MR or existing remote work branch, and writes a short-lived claim
# so another scheduler tick does not dispatch the same IID.

set -euo pipefail

if [ -z "${ISSUE_IID:-}" ] && [ -n "${IID:-}" ]; then
  export ISSUE_IID="${IID}"
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${ISSUE_IID:?ISSUE_IID or IID must be set}"
: "${PROJECT_FULL:?}" "${PROJECT_URI:?}" "${REPO_PATH:?}" "${WORK_BRANCH:?}" "${STATE_DIR:?}"
: "${BRANCH:?}" "${ISSUE_MODE:=fresh}"

bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clone_or_pull.sh" >/dev/null

cd "${REPO_PATH}"
git ls-remote --exit-code origin HEAD >/dev/null
glab auth status --hostname "${GITLAB_HOST}" >/dev/null

if [ "${ISSUE_MODE}" = "fresh" ]; then
  MR_JSON="$(glab mr list \
    --repo "${PROJECT_FULL}" \
    --source-branch "${WORK_BRANCH}" \
    --state opened \
    --output json)"
  MR_URL="$(echo "${MR_JSON}" | jq -r 'if length > 0 then .[0].web_url else "" end')"
  if [ -n "${MR_URL}" ]; then
    jq -nc --arg reason "open_mr_exists" --arg url "${MR_URL}" --arg branch "${WORK_BRANCH}" \
      '{eligible:false, reason:$reason, merge_request_url:$url, work_branch:$branch}'
    exit 0
  fi

  if git ls-remote --exit-code --heads origin "${WORK_BRANCH}" >/dev/null 2>&1; then
    jq -nc --arg reason "remote_branch_exists" --arg branch "${WORK_BRANCH}" \
      '{eligible:false, reason:$reason, work_branch:$branch}'
    exit 0
  fi
fi

CLAIMS_FILE="${STATE_DIR}/claims.json"
CLAIMS_LOCK="${STATE_DIR}/claims.lock"
mkdir -p "${STATE_DIR}"
[ -f "${CLAIMS_FILE}" ] || echo '{}' > "${CLAIMS_FILE}"

exec 8>"${CLAIMS_LOCK}"
flock 8

CUTOFF="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CLAIM_KEY="${PROJECT_FULL}#${ISSUE_IID}"

TMP="$(mktemp "${STATE_DIR}/.claims.XXXXXX")"
jq --arg cutoff "${CUTOFF}" 'to_entries | map(select(.value > $cutoff)) | from_entries' \
  "${CLAIMS_FILE}" > "${TMP}"
mv "${TMP}" "${CLAIMS_FILE}"

EXISTING="$(jq -r --arg key "${CLAIM_KEY}" '.[$key] // ""' "${CLAIMS_FILE}")"
if [ -n "${EXISTING}" ]; then
  jq -nc --arg reason "claimed" --arg key "${CLAIM_KEY}" --arg claimed_at "${EXISTING}" \
    '{eligible:false, reason:$reason, claim_key:$key, claimed_at:$claimed_at}'
  exit 0
fi

TMP="$(mktemp "${STATE_DIR}/.claims.XXXXXX")"
jq --arg key "${CLAIM_KEY}" --arg now "${NOW}" '.[$key] = $now' "${CLAIMS_FILE}" > "${TMP}"
mv "${TMP}" "${CLAIMS_FILE}"

jq -nc --arg key "${CLAIM_KEY}" --arg now "${NOW}" --arg branch "${WORK_BRANCH}" \
  '{eligible:true, claim_key:$key, claimed_at:$now, work_branch:$branch}'
