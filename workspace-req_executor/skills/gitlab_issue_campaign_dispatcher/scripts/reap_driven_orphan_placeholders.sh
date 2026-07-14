#!/usr/bin/env bash
# Remove scheduler-driven pre-spawn placeholders whose exact physical job is
# absent from both the scheduler active set and every unfinished durable launch
# coordinator. The executor tick builds that protected set while holding its
# global tick lock; this project-side wrapper performs the final identity check
# and state mutation under campaign.lock.

set -euo pipefail

: "${PROJECT:?reap_driven_orphan_placeholders.sh: PROJECT must be set}"
: "${GROUP:?reap_driven_orphan_placeholders.sh: GROUP must be set}"
: "${GITLAB_TOKEN:?reap_driven_orphan_placeholders.sh: GITLAB_TOKEN must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_dispatch_lib.sh"

INPUT_RAW="$(cat)"
if ! INPUT_JSON="$(printf '%s' "${INPUT_RAW}" | jq -ce '
  def safe_job_id:
    type == "string"
    and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$");
  if type == "object"
    and (keys == ["protected_job_ids"])
    and (.protected_job_ids | type == "array")
    and (all(.protected_job_ids[]; safe_job_id))
    and ((.protected_job_ids | length)
      == (.protected_job_ids | unique | length))
  then .protected_job_ids |= (unique | sort)
  else error("invalid protected job set")
  end
' 2>/dev/null)"; then
  echo "reap_driven_orphan_placeholders.sh: stdin must be strict {protected_job_ids:[unique safe job ids]} JSON" >&2
  exit 2
fi

PROTECTED_JOB_IDS="$(jq -c '.protected_job_ids' <<<"${INPUT_JSON}")"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  jq -cn '{
    status:"lock_held",
    reaped_entries:[],
    protected_entries:[],
    unresolved_iids:[]
  }'
  exit 0
fi

STATE_JSON="$(load_state)"
if ! jq -e '
    type == "object"
    and ((.pending_subagents // {}) | type == "object")
  ' <<<"${STATE_JSON}" >/dev/null; then
  echo "reap_driven_orphan_placeholders.sh: campaign pending state is invalid" >&2
  exit 3
fi

# Only scheduler-driven placeholders with no runtime acknowledgement are
# candidates. Missing/invalid physical identity stays unresolved instead of
# being guessed from IID, attempt, labels, or batch history.
CANDIDATES="$(jq -ce '
  [(.pending_subagents // {}) | to_entries[]
    | select(
        (.value | type == "object")
        and (.value.placeholder == true)
        and (.value.run_id // null) == null
        and (.value.child_session_key // null) == null
        and (.value.spawned_at // null) == null
        and .value.memberships_source == "scheduler_active_job"
      )
    | {
        key:.key,
        iid:(try (.key | tonumber) catch null),
        attempt_number:(.value.attempt_number // null),
        job_id:(.value.job_id // null)
      }]
' <<<"${STATE_JSON}")"

REAPED_ENTRIES='[]'
PROTECTED_ENTRIES='[]'
UNRESOLVED_IIDS='[]'
while IFS= read -r candidate; do
  [ -n "${candidate}" ] || continue
  candidate_key="$(jq -r '.key' <<<"${candidate}")"
  candidate_iid="$(jq -r '.iid // 0' <<<"${candidate}")"
  candidate_attempt="$(jq -r '.attempt_number // 0' <<<"${candidate}")"
  candidate_job_id="$(jq -r '.job_id // empty' <<<"${candidate}")"

  if ! [[ "${candidate_key}" =~ ^[1-9][0-9]*$ ]] \
      || [ "${candidate_iid}" != "${candidate_key}" ] \
      || ! [[ "${candidate_attempt}" =~ ^[1-9][0-9]*$ ]] \
      || ! [[ "${candidate_job_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$ ]]; then
    if [[ "${candidate_iid}" =~ ^[1-9][0-9]*$ ]]; then
      UNRESOLVED_IIDS="$(jq -ce --argjson iid "${candidate_iid}" \
        '(. + [$iid]) | unique | sort' <<<"${UNRESOLVED_IIDS}")"
    fi
    continue
  fi

  if jq -e --arg job_id "${candidate_job_id}" \
      'index($job_id) != null' <<<"${PROTECTED_JOB_IDS}" >/dev/null; then
    PROTECTED_ENTRIES="$(jq -ce \
      --argjson iid "${candidate_iid}" \
      --arg job_id "${candidate_job_id}" \
      --argjson attempt_number "${candidate_attempt}" \
      '. + [{iid:$iid,job_id:$job_id,attempt_number:$attempt_number}]' \
      <<<"${PROTECTED_ENTRIES}")"
    continue
  fi

  # Re-check the exact bytes selected above inside the in-memory lock-held
  # state before deletion. No IID-only or job-only deletion is permitted.
  if ! jq -e \
      --arg key "${candidate_key}" \
      --arg job_id "${candidate_job_id}" \
      --argjson attempt_number "${candidate_attempt}" '
      .pending_subagents[$key] as $pending
      | ($pending | type == "object")
        and $pending.placeholder == true
        and ($pending.run_id // null) == null
        and ($pending.child_session_key // null) == null
        and ($pending.spawned_at // null) == null
        and $pending.memberships_source == "scheduler_active_job"
        and $pending.job_id == $job_id
        and $pending.attempt_number == $attempt_number
    ' <<<"${STATE_JSON}" >/dev/null; then
    UNRESOLVED_IIDS="$(jq -ce --argjson iid "${candidate_iid}" \
      '(. + [$iid]) | unique | sort' <<<"${UNRESOLVED_IIDS}")"
    continue
  fi

  STATE_JSON="$(jq -ce \
    --arg key "${candidate_key}" \
    --arg project "${PROJECT}" '
    del(.pending_subagents[$key])
    | .active_issue_iids = (.pending_subagents | keys | map(tonumber) | sort)
    | .active_issue_sessions =
        (.active_issue_iids
          | map("issue-" + $project + "-" + (.|tostring)))
    | if (.active_issue_iids | length) == 0
        and .campaign_status == "waiting_for_callbacks"
      then .campaign_status = "running"
      else .
      end
  ' <<<"${STATE_JSON}")"
  REAPED_ENTRIES="$(jq -ce \
    --argjson iid "${candidate_iid}" \
    --arg job_id "${candidate_job_id}" \
    --argjson attempt_number "${candidate_attempt}" \
    '. + [{iid:$iid,job_id:$job_id,attempt_number:$attempt_number}]' \
    <<<"${REAPED_ENTRIES}")"
done < <(jq -c '.[]' <<<"${CANDIDATES}")

if [ "$(jq -r 'length' <<<"${REAPED_ENTRIES}")" -gt 0 ]; then
  persist_state "${STATE_JSON}"
  while IFS= read -r reaped; do
    [ -n "${reaped}" ] || continue
    wrapper_log orphan_reaper \
      "reaped scheduler orphan iid=$(jq -r '.iid' <<<"${reaped}") job_id=$(jq -r '.job_id' <<<"${reaped}") attempt=$(jq -r '.attempt_number' <<<"${reaped}")"
  done < <(jq -c '.[]' <<<"${REAPED_ENTRIES}")
fi

jq -cn \
  --argjson reaped_entries "${REAPED_ENTRIES}" \
  --argjson protected_entries "${PROTECTED_ENTRIES}" \
  --argjson unresolved_iids "${UNRESOLVED_IIDS}" '{
  status:"reaped",
  reaped_entries:$reaped_entries,
  protected_entries:$protected_entries,
  unresolved_iids:$unresolved_iids
}'
