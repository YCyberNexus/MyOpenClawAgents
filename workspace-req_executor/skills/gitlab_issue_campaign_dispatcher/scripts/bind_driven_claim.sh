#!/usr/bin/env bash
# Bind the scheduler preparing claim that Task9 is about to spawn to the
# matching project-campaign pending entry.
set -euo pipefail

: "${PROJECT:?bind_driven_claim.sh: PROJECT must be set}"
: "${GROUP:?bind_driven_claim.sh: GROUP must be set}"
: "${GITLAB_TOKEN:?bind_driven_claim.sh: GITLAB_TOKEN must be set}"
: "${REPO_PARENT_PATH:?bind_driven_claim.sh: REPO_PARENT_PATH must be set}"
: "${IID:?bind_driven_claim.sh: IID must be set}"
: "${JOB_ID:?bind_driven_claim.sh: JOB_ID must be set}"
: "${CLAIM_TOKEN:?bind_driven_claim.sh: CLAIM_TOKEN must be set}"
: "${CLAIM_GENERATION:?bind_driven_claim.sh: CLAIM_GENERATION must be set}"

case "${IID}" in
  ''|*[!0-9]*) echo "bind_driven_claim.sh: IID must be a positive integer" >&2; exit 2 ;;
esac
case "${CLAIM_GENERATION}" in
  ''|*[!0-9]*) echo "bind_driven_claim.sh: CLAIM_GENERATION must be a positive integer" >&2; exit 2 ;;
esac
if [[ "${IID}" =~ ^0+$ ]] || [[ "${CLAIM_GENERATION}" =~ ^0+$ ]]; then
  echo "bind_driven_claim.sh: IID and CLAIM_GENERATION must be positive integers" >&2
  exit 2
fi
case "${JOB_ID}${CLAIM_TOKEN}" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "bind_driven_claim.sh: JOB_ID and CLAIM_TOKEN must not contain control characters" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

BOUND_AT="${NOW_ISO:-$(utc_now)}"

exec 9>"${LOCK_FILE}"
flock -x 9

STATE_JSON="$(load_state)"
PENDING_JSON="$(jq -c --argjson iid "${IID}" \
  '.pending_subagents[($iid | tostring)] // null' <<<"${STATE_JSON}")"
if [ "${PENDING_JSON}" = null ]; then
  echo "bind_driven_claim.sh: pending entry is missing for IID ${IID}" >&2
  exit 3
fi
if ! jq -e --arg job_id "${JOB_ID}" '
  type == "object"
  and .job_id == $job_id
  and .memberships_source == "scheduler_active_job"
' <<<"${PENDING_JSON}" >/dev/null; then
  echo "bind_driven_claim.sh: pending entry does not match scheduler job ${JOB_ID}" >&2
  exit 3
fi

HAS_BINDING="$(jq -r '
  has("claim_generation") or has("claim_token") or has("bound_at")
' <<<"${PENDING_JSON}")"
if [ "${HAS_BINDING}" = true ]; then
  if jq -e \
    --argjson generation "${CLAIM_GENERATION}" \
    --arg token "${CLAIM_TOKEN}" '
    .claim_generation == $generation
    and .claim_token == $token
    and (.bound_at | type == "string" and length > 0)
  ' <<<"${PENDING_JSON}" >/dev/null; then
    jq -cn \
      --argjson iid "${IID}" \
      --arg job_id "${JOB_ID}" \
      --argjson claim_generation "${CLAIM_GENERATION}" '{
        status:"idempotent",
        iid:$iid,
        job_id:$job_id,
        claim_generation:$claim_generation
    }'
    exit 0
  fi
  # A claim whose actionable grant was emitted but never acked may be fenced
  # back to reserved by the preparing lease. The project placeholder is safe
  # to rebind only while no runtime run/session/spawn timestamp was recorded,
  # and only to a strictly newer generation for the same physical job.
  if jq -e \
    --argjson generation "${CLAIM_GENERATION}" '
    .placeholder == true
    and (.run_id == null)
    and (.child_session_key == null)
    and (.spawned_at == null)
    and (.claim_generation | type == "number" and . >= 1 and . < $generation)
    and (.claim_token | type == "string" and length > 0)
  ' <<<"${PENDING_JSON}" >/dev/null; then
    NEXT_STATE="$(jq -c \
      --argjson iid "${IID}" \
      --argjson claim_generation "${CLAIM_GENERATION}" \
      --arg claim_token "${CLAIM_TOKEN}" \
      --arg bound_at "${BOUND_AT}" '
      .pending_subagents[($iid | tostring)].claim_generation = $claim_generation
      | .pending_subagents[($iid | tostring)].claim_token = $claim_token
      | .pending_subagents[($iid | tostring)].bound_at = $bound_at
    ' <<<"${STATE_JSON}")"
    persist_state "${NEXT_STATE}"
    jq -cn \
      --argjson iid "${IID}" \
      --arg job_id "${JOB_ID}" \
      --argjson claim_generation "${CLAIM_GENERATION}" '{
        status:"rebound",
        iid:$iid,
        job_id:$job_id,
        claim_generation:$claim_generation
      }'
    exit 0
  fi
  echo "bind_driven_claim.sh: pending entry already carries a different claim" >&2
  exit 3
fi

NEXT_STATE="$(jq -c \
  --argjson iid "${IID}" \
  --argjson claim_generation "${CLAIM_GENERATION}" \
  --arg claim_token "${CLAIM_TOKEN}" \
  --arg bound_at "${BOUND_AT}" '
  .pending_subagents[($iid | tostring)].claim_generation = $claim_generation
  | .pending_subagents[($iid | tostring)].claim_token = $claim_token
  | .pending_subagents[($iid | tostring)].bound_at = $bound_at
' <<<"${STATE_JSON}")"
persist_state "${NEXT_STATE}"

jq -cn \
  --argjson iid "${IID}" \
  --arg job_id "${JOB_ID}" \
  --argjson claim_generation "${CLAIM_GENERATION}" '{
    status:"bound",
    iid:$iid,
    job_id:$job_id,
    claim_generation:$claim_generation
  }'
