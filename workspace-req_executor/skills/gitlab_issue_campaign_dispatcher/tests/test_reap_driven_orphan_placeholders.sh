#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAPER="${SKILL_DIR}/scripts/reap_driven_orphan_placeholders.sh"

fail() {
  echo "test_reap_driven_orphan_placeholders.sh: $*" >&2
  exit 1
}

[ -x "${REAPER}" ] || fail "orphan placeholder reaper is missing or not executable"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-orphan-reaper.XXXXXX")"
REPO_PARENT="${TEST_ROOT}/repos/group"
REPO_PATH="${REPO_PARENT}/repo"
STATE_DIR="${REPO_PATH}/.req_executor/_dispatcher"
STATE_FILE="${STATE_DIR}/campaign_state.json"
LOCK_FILE="${STATE_DIR}/campaign.lock"
mkdir -p "${REPO_PATH}/.git" "${STATE_DIR}/log"

write_state() {
  local only_orphan="${1:-false}"
  jq -cnS --argjson only_orphan "${only_orphan}" '{
    project:"repo",
    pending_subagents:({
      "4":{
        attempt_number:1,run_id:null,child_session_key:null,
        spawned_at:null,placeholder:true,
        memberships_source:"scheduler_active_job",
        job_id:"old-batch:snapshot-4",claim_generation:0,claim_token:null
      }
    } + (if $only_orphan then {} else {
      "5":{
        attempt_number:1,run_id:null,child_session_key:null,
        spawned_at:null,placeholder:true,
        memberships_source:"scheduler_active_job",
        job_id:"active-batch:snapshot-5",claim_generation:1,claim_token:"active"
      },
      "6":{
        attempt_number:2,run_id:null,child_session_key:null,
        spawned_at:null,placeholder:true,
        memberships_source:"scheduler_active_job",
        job_id:"launch-batch:snapshot-6",claim_generation:1,claim_token:"launch"
      },
      "7":{
        attempt_number:1,run_id:"run-7",child_session_key:"agent:req_executor:7",
        spawned_at:"2026-07-14T00:00:00Z",placeholder:false,
        memberships_source:"scheduler_active_job",job_id:"running:snapshot-7"
      },
      "8":{
        attempt_number:1,run_id:null,child_session_key:null,
        spawned_at:null,placeholder:true,
        memberships_source:"scheduler_active_job"
      },
      "9":{
        attempt_number:1,run_id:null,child_session_key:null,
        spawned_at:null,placeholder:true
      }
    } end)),
    active_issue_iids:(if $only_orphan then [4] else [4,5,6,7,8,9] end),
    active_issue_sessions:(if $only_orphan then ["issue-repo-4"] else
      ["issue-repo-4","issue-repo-5","issue-repo-6",
       "issue-repo-7","issue-repo-8","issue-repo-9"] end),
    unfinished_iids:[],completed_iids:[],blocked_iids:[],failed_iids:[],
    timeout_iids:[],campaign_status:"waiting_for_callbacks"
  }' >"${STATE_FILE}"
}

run_reaper() {
  local input="$1"
  printf '%s' "${input}" | \
    PROJECT=repo GROUP=group GITLAB_TOKEN=fake-token \
    GITLAB_HOST=gitlab.example.test GITLAB_API_PROTOCOL=https \
    REPO_PARENT_PATH="${REPO_PARENT}" \
      bash "${REAPER}"
}

write_state false
protected_input='{"protected_job_ids":["active-batch:snapshot-5","launch-batch:snapshot-6"]}'
first_output="$(run_reaper "${protected_input}")" || fail "first reaper call failed"
jq -e '
  .status == "reaped"
  and .reaped_entries == [{
    iid:4,job_id:"old-batch:snapshot-4",attempt_number:1
  }]
  and ([.protected_entries[].iid] | sort) == [5,6]
  and .unresolved_iids == [8]
' <<<"${first_output}" >/dev/null || fail "reaper envelope was incorrect"
jq -e '
  (.pending_subagents | has("4") | not)
  and (.pending_subagents | keys | map(tonumber) | sort) == [5,6,7,8,9]
  and .active_issue_iids == [5,6,7,8,9]
  and .active_issue_sessions == [
    "issue-repo-5","issue-repo-6","issue-repo-7",
    "issue-repo-8","issue-repo-9"
  ]
  and .campaign_status == "waiting_for_callbacks"
' "${STATE_FILE}" >/dev/null || fail "reaper mutated protected or non-candidate pending entries"

replay_output="$(run_reaper "${protected_input}")" || fail "reaper replay failed"
jq -e '
  .status == "reaped"
  and .reaped_entries == []
  and ([.protected_entries[].iid] | sort) == [5,6]
  and .unresolved_iids == [8]
' <<<"${replay_output}" >/dev/null || fail "reaper replay was not idempotent"

write_state true
last_output="$(run_reaper '{"protected_job_ids":[]}')" \
  || fail "last-placeholder reaper call failed"
jq -e '.status == "reaped" and [.reaped_entries[].iid] == [4]' \
  <<<"${last_output}" >/dev/null || fail "last orphan was not reaped"
jq -e '
  .pending_subagents == {}
  and .active_issue_iids == []
  and .active_issue_sessions == []
  and .campaign_status == "running"
' "${STATE_FILE}" >/dev/null || fail "last orphan did not release waiting_for_callbacks"

write_state true
exec 8>"${LOCK_FILE}"
flock -n 8 || fail "unable to hold campaign lock"
lock_output="$(run_reaper '{"protected_job_ids":[]}')" \
  || fail "lock-held reaper call failed"
flock -u 8
exec 8>&-
jq -e '.status == "lock_held" and .reaped_entries == []' \
  <<<"${lock_output}" >/dev/null || fail "campaign lock was not respected"
jq -e '.pending_subagents | has("4")' "${STATE_FILE}" >/dev/null \
  || fail "lock-held reaper mutated state"

if run_reaper '{"protected_job_ids":["bad job"]}' \
    >"${TEST_ROOT}/invalid.out" 2>"${TEST_ROOT}/invalid.err"; then
  fail "invalid protected job id was accepted"
fi

echo "ok driven orphan placeholders are reaped only outside the protected scheduler set"
