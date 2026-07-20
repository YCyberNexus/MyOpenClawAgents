#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
RECORD="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-driven-dedup.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/_scheduler"
mkdir -p "${CONFIG_DIR}"

printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

create_single_fixture() {
  local batch_id="$1"
  local project="$2"
  local iid="$3"
  local branch="$4"
  local force_rerun_pr="$5"
  local auto_merge="${6:-false}"
  local merge_target_branch="${7:-}"
  local batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"

  mkdir -p "${batch_dir}"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg project "${project}" \
    --arg branch "${branch}" \
    --argjson iid "${iid}" \
    --argjson force_rerun_pr "${force_rerun_pr}" \
    --argjson auto_merge "${auto_merge}" \
    --arg merge_target_branch "${merge_target_branch}" \
    '{
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:$project,
      selector:{type:"single",iid:$iid},
      force_rerun_pr:$force_rerun_pr,
      auto_merge:$auto_merge,
      dispatcher_callback_target:"agent:req_dispatcher:main",
      branch:$branch,
      merge_target_branch:(if $merge_target_branch == "" then null else $merge_target_branch end)
    }' >"${batch_dir}/request.json"
  jq -cnS \
    --arg project "${project}" \
    --argjson iid "${iid}" \
    '{version:1,project:$project,iids:[$iid]}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    '{
      version:1,
      terminal_counts_version:1,
      batch_id:$batch_id,
      status:"queued",
      matched_count:1,
      terminal_count:0,
      done_count:0,
      failed_count:0,
      timeout_count:0,
      skipped_count:0,
      next_snapshot_index:0,
      request_digest:"fixture-request",
      snapshot_digest:"fixture-snapshot",
      memberships:{}
    }' >"${batch_dir}/state.json"
}

# A and C have the same complete physical key and identical intent. D has the
# same physical key but a different branch, E proves that equal short repo
# slugs in different groups remain different physical jobs, and AUTO_CONFLICT conflicts
# with E only by automatic-merge intent.
create_single_fixture A group/repo 7 main false
create_single_fixture C group/repo 7 main false
create_single_fixture D group/repo 7 release false
create_single_fixture E other/repo 7 main false
create_single_fixture AUTO_CONFLICT other/repo 7 main false true main
jq '.batch_order = ["A","C","D","E","AUTO_CONFLICT"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" "${SCHEDULER_ROOT}/scheduler_state.json"

first_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"A",project:"group/repo",iid:7},
    {batch_id:"E",project:"other/repo",iid:7}
  ]
  and .active_count == 2
  and .available_slots == 1
' <<<"${first_reserve}" >/dev/null

a_job_id="$(jq -r '.grants[] | select(.batch_id == "A") | .job_id' <<<"${first_reserve}")"
e_job_id="$(jq -r '.grants[] | select(.batch_id == "E") | .job_id' <<<"${first_reserve}")"
jq -e --arg job_id "${a_job_id}" '
  .active_jobs[$job_id].physical_key == "group/repo#7"
  and (.active_jobs[$job_id].memberships | length) == 2
  and ([.active_jobs[$job_id].memberships[].batch_id] | sort) == ["A","C"]
  and ([.active_jobs[] | select(.iid == 7) | .project] | sort) == ["group/repo","other/repo"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e --arg job_id "${a_job_id}" '
  .memberships["0"].status == "attached"
  and .memberships["0"].job_id == $job_id
' "${SCHEDULER_ROOT}/batches/C/state.json" >/dev/null
jq -e --arg job_id "${a_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/D/state.json" >/dev/null
jq -e --arg job_id "${e_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/AUTO_CONFLICT/state.json" >/dev/null

declare -A CLAIM_TOKENS=()
while IFS= read -r reserved_job_id; do
  claim_output="$(
    CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${reserved_job_id}" STATUS=preparing \
      bash "${RECORD}"
  )"
  CLAIM_TOKENS["${reserved_job_id}"]="$(jq -r '.claim_token' <<<"${claim_output}")"
done < <(jq -r '.grants[].job_id' <<<"${first_reserve}")

spawned_once="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${e_job_id}" STATUS=spawned \
    CLAIM_TOKEN="${CLAIM_TOKENS[${e_job_id}]}" \
    bash "${RECORD}"
)"
spawned_again="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${e_job_id}" STATUS=spawned \
    CLAIM_TOKEN="${CLAIM_TOKENS[${e_job_id}]}" \
    bash "${RECORD}"
)"
jq -e '.job_status == "running" and .should_spawn == false' \
  <<<"${spawned_once}" >/dev/null
jq -e '.job_status == "running" and .should_spawn == false' \
  <<<"${spawned_again}" >/dev/null

running_scheduler_before="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
running_batch_before="$(jq -cS . "${SCHEDULER_ROOT}/batches/E/state.json")"
set +e
running_launch_failed_output="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${e_job_id}" STATUS=launch_failed \
    bash "${RECORD}" 2>&1
)"
running_launch_failed_status=$?
set -e
if [ "${running_launch_failed_status}" -ne 3 ]; then
  echo "expected running launch_failed to exit 3, got ${running_launch_failed_status}: ${running_launch_failed_output}" >&2
  exit 1
fi
running_scheduler_after="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
running_batch_after="$(jq -cS . "${SCHEDULER_ROOT}/batches/E/state.json")"
if [ "${running_scheduler_after}" != "${running_scheduler_before}" ]; then
  echo "expected rejected running launch_failed to leave scheduler state unchanged" >&2
  exit 1
fi
if [ "${running_batch_after}" != "${running_batch_before}" ]; then
  echo "expected rejected running launch_failed to leave batch state unchanged" >&2
  exit 1
fi

# Re-reserving while the physical jobs are active must neither create another
# grant nor duplicate the attached membership.
replay_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .grants == []
  and .active_count == 2
  and .available_slots == 1
' <<<"${replay_reserve}" >/dev/null
jq -e --arg job_id "${a_job_id}" '
  (.active_jobs[$job_id].memberships | length) == 2
  and (.active_jobs | length) == 2
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN="${CLAIM_TOKENS[${a_job_id}]}" \
  bash "${RECORD}" >/dev/null
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' "${SCHEDULER_ROOT}/batches/A/state.json" >/dev/null
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' "${SCHEDULER_ROOT}/batches/C/state.json" >/dev/null

after_terminal="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,project,iid,branch}] == [
    {batch_id:"D",project:"group/repo",iid:7,branch:"release"}
  ]
  and .active_count == 2
  and .available_slots == 1
' <<<"${after_terminal}" >/dev/null
jq -e '
  .memberships["0"].status == "reserved"
  and (.memberships["0"] | has("blocked_by_job_id") | not)
' "${SCHEDULER_ROOT}/batches/D/state.json" >/dev/null

d_claim_output="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="$(jq -r '.grants[0].job_id' <<<"${after_terminal}")" STATUS=preparing \
    bash "${RECORD}"
)"
d_claim_token="$(jq -r '.claim_token' <<<"${d_claim_output}")"
final_replay="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '.grants == [] and .active_count == 2' <<<"${final_replay}" >/dev/null

d_job_id="$(jq -r '.grants[0].job_id' <<<"${after_terminal}")"
launch_failed_out="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${d_job_id}" STATUS=launch_failed \
    CLAIM_TOKEN="${d_claim_token}" \
    bash "${RECORD}"
)"
jq -e '.job_status == "launch_failed" and .active_count == 1' \
  <<<"${launch_failed_out}" >/dev/null
jq -e '
  .status == "queued"
  and .memberships["0"].status == "pending"
  and (.memberships["0"] | has("job_id") | not)
' "${SCHEDULER_ROOT}/batches/D/state.json" >/dev/null

retry_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e --arg job_id "${d_job_id}" '
  [.grants[] | {batch_id,iid,job_id}] == [
    {batch_id:"D",iid:7,job_id:$job_id}
  ]
  and .active_count == 2
' <<<"${retry_reserve}" >/dev/null

# The record path uses the same durable transaction boundary. Interrupt its
# final scheduler publish, then emulate create_driven_batch.sh appending a new
# completed registration before recovery; both the terminal release and the
# newly registered batch must survive.
RECORD_CRASH_BIN="${TEST_ROOT}/record-crash-bin"
mkdir -p "${RECORD_CRASH_BIN}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'destination="${*: -1}"' \
  'if [ "${destination}" = "${FAIL_SCHEDULER_DEST:?}" ]; then' \
  '  count=0' \
  '  [ ! -f "${MV_COUNT_FILE:?}" ] || count="$(<"${MV_COUNT_FILE}")"' \
  '  count=$((count + 1))' \
  '  printf "%s" "${count}" >"${MV_COUNT_FILE}"' \
  '  [ "${count}" -ne 2 ] || exit 97' \
  'fi' \
  'exec /bin/mv "$@"' \
  >"${RECORD_CRASH_BIN}/mv"
chmod +x "${RECORD_CRASH_BIN}/mv"

set +e
PATH="${RECORD_CRASH_BIN}:${PATH}" \
  FAIL_SCHEDULER_DEST="${SCHEDULER_ROOT}/scheduler_state.json" \
  MV_COUNT_FILE="${TEST_ROOT}/record-crash-mv-count" \
  CONFIG_DIR="${CONFIG_DIR}" \
  JOB_ID="${d_job_id}" \
  STATUS=terminal \
  TERMINAL_STATUS=done \
  bash "${RECORD}" >"${TEST_ROOT}/record-crash.out" 2>"${TEST_ROOT}/record-crash.err"
record_crash_status=$?
set -e
[ "${record_crash_status}" -eq 97 ] || {
  echo "expected injected record publish failure, got ${record_crash_status}" >&2
  exit 1
}
jq -e '.pending_transaction.version == 1' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

Y_BATCH_DIR="${SCHEDULER_ROOT}/batches/Y"
mkdir -p "${Y_BATCH_DIR}"
jq -cnS '{
  version:1,
  batch_id:"Y",
  correlation_id:"correlation-Y",
  project:"group/y",
  selector:{type:"single",iid:99},
  force_rerun_pr:false,
  dispatcher_callback_target:"agent:req_dispatcher:main",
  branch:"main"
}' >"${Y_BATCH_DIR}/request.json"
jq -cnS '{version:1,project:"group/y",iids:[]}' >"${Y_BATCH_DIR}/snapshot.json"
jq -cnS '{
  version:1,
  terminal_counts_version:1,
  batch_id:"Y",
  status:"completed",
  matched_count:0,
  terminal_count:0,
  done_count:0,
  failed_count:0,
  timeout_count:0,
  skipped_count:0,
  next_snapshot_index:0,
  request_digest:"fixture-request",
  snapshot_digest:"fixture-snapshot",
  memberships:{}
}' >"${Y_BATCH_DIR}/state.json"
jq '.batch_order += ["Y"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-y.json"
/bin/mv "${SCHEDULER_ROOT}/scheduler_state.with-y.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

record_recovered_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '.grants == [] and .active_count == 1 and .available_slots == 2' \
  <<<"${record_recovered_reserve}" >/dev/null
jq -e '
  (.pending_transaction | not)
  and (.active_jobs | length) == 1
  and (.batch_order | index("Y") == null)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
[ -d "${Y_BATCH_DIR}" ] \
  || { echo "completed batch evidence was not retained for direct lookup" >&2; exit 1; }
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' \
  "${SCHEDULER_ROOT}/batches/D/state.json" >/dev/null

# Branch is not the only intent dimension: entry_mode and force_rerun_pr must
# also serialize on the same physical Issue instead of attaching incorrectly.
create_single_fixture F group/intent 8 main false
create_single_fixture G group/intent 8 main false
create_single_fixture H group/intent 8 main true
for intent_spec in 'F fresh' 'G continue' 'H fresh'; do
  intent_batch="${intent_spec%% *}"
  intent_mode="${intent_spec#* }"
  jq --arg entry_mode "${intent_mode}" '.entry_mode = $entry_mode' \
    "${SCHEDULER_ROOT}/batches/${intent_batch}/request.json" \
    >"${SCHEDULER_ROOT}/batches/${intent_batch}/request.next.json"
  /bin/mv \
    "${SCHEDULER_ROOT}/batches/${intent_batch}/request.next.json" \
    "${SCHEDULER_ROOT}/batches/${intent_batch}/request.json"
done
jq '.batch_order += ["F","G","H"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-intents.json"
/bin/mv "${SCHEDULER_ROOT}/scheduler_state.with-intents.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

intent_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,iid,entry_mode,force_rerun_pr}] == [
    {batch_id:"F",iid:8,entry_mode:"fresh",force_rerun_pr:false}
  ]
  and .active_count == 2
' <<<"${intent_reserve}" >/dev/null
f_job_id="$(jq -r '.grants[0].job_id' <<<"${intent_reserve}")"
jq -e --arg job_id "${f_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/G/state.json" >/dev/null
jq -e --arg job_id "${f_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/H/state.json" >/dev/null

CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${f_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done \
  bash "${RECORD}" >/dev/null
next_intent_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,entry_mode,force_rerun_pr}] == [
    {batch_id:"G",entry_mode:"continue",force_rerun_pr:false}
  ]
  and .active_count == 2
' <<<"${next_intent_reserve}" >/dev/null

# A conflicting physical job at the head of one batch must not block a later
# runnable snapshot item from using a free slot in the same round.
SCHEDULER_ROOT="${TEST_ROOT}/head-of-line-scheduler"
CONFIG_DIR="${TEST_ROOT}/head-of-line-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=2' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_single_fixture A group/repo 7 main false
create_single_fixture C group/repo 7 release false
jq '.selector = {type:"range",iid_min:7,iid_max:8}' \
  "${SCHEDULER_ROOT}/batches/C/request.json" \
  >"${SCHEDULER_ROOT}/batches/C/request.next.json"
/bin/mv "${SCHEDULER_ROOT}/batches/C/request.next.json" \
  "${SCHEDULER_ROOT}/batches/C/request.json"
jq '.iids = [7,8]' \
  "${SCHEDULER_ROOT}/batches/C/snapshot.json" \
  >"${SCHEDULER_ROOT}/batches/C/snapshot.next.json"
/bin/mv "${SCHEDULER_ROOT}/batches/C/snapshot.next.json" \
  "${SCHEDULER_ROOT}/batches/C/snapshot.json"
jq '.matched_count = 2' \
  "${SCHEDULER_ROOT}/batches/C/state.json" \
  >"${SCHEDULER_ROOT}/batches/C/state.next.json"
/bin/mv "${SCHEDULER_ROOT}/batches/C/state.next.json" \
  "${SCHEDULER_ROOT}/batches/C/state.json"
jq '.batch_order = ["A","C"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
/bin/mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

head_of_line_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
expected_head_of_line='[{"batch_id":"A","iid":7},{"batch_id":"C","iid":8}]'
actual_head_of_line="$(jq -c '[.grants[] | {batch_id,iid}]' <<<"${head_of_line_reserve}")"
if [ "${actual_head_of_line}" != "${expected_head_of_line}" ]; then
  echo "expected blocked C#7 to yield to runnable C#8: ${expected_head_of_line}, got ${actual_head_of_line}" >&2
  exit 1
fi
jq -e '
  .memberships["0"].status == "pending"
  and (.memberships["0"].blocked_by_job_id | type == "string")
  and .memberships["1"].status == "reserved"
' "${SCHEDULER_ROOT}/batches/C/state.json" >/dev/null

# Missing entry_mode always normalizes to auto, including force reruns. It must
# therefore remain a different intent from an explicit fresh request.
SCHEDULER_ROOT="${TEST_ROOT}/entry-mode-scheduler"
CONFIG_DIR="${TEST_ROOT}/entry-mode-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=2' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_single_fixture MISSING group/mode 9 main true
create_single_fixture FRESH group/mode 9 main true
jq '.entry_mode = "fresh"' \
  "${SCHEDULER_ROOT}/batches/FRESH/request.json" \
  >"${SCHEDULER_ROOT}/batches/FRESH/request.next.json"
/bin/mv "${SCHEDULER_ROOT}/batches/FRESH/request.next.json" \
  "${SCHEDULER_ROOT}/batches/FRESH/request.json"
jq '.batch_order = ["MISSING","FRESH"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
/bin/mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

entry_mode_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
expected_entry_mode='[{"batch_id":"MISSING","entry_mode":"auto"}]'
actual_entry_mode="$(jq -c '[.grants[] | {batch_id,entry_mode}]' <<<"${entry_mode_reserve}")"
if [ "${actual_entry_mode}" != "${expected_entry_mode}" ]; then
  echo "expected missing entry_mode to stay auto: ${expected_entry_mode}, got ${actual_entry_mode}" >&2
  exit 1
fi
jq -e '
  .memberships["0"].status == "pending"
  and (.memberships["0"].blocked_by_job_id | type == "string")
' "${SCHEDULER_ROOT}/batches/FRESH/state.json" >/dev/null

# An old pending transaction must be migrated before recovery validates its
# nested scheduler state. record is deliberately the first entry point: it
# must preserve old reserved work, roll old preparing back, and let only the
# legacy running job finish without a token.
SCHEDULER_ROOT="${TEST_ROOT}/legacy-pending-scheduler"
CONFIG_DIR="${TEST_ROOT}/legacy-pending-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_single_fixture Q group/pending 41 main false
create_single_fixture W group/pending 42 main false
create_single_fixture Z group/pending 43 main false

for pending_spec in 'Q 41 reserved' 'W 42 preparing' 'Z 43 running'; do
  pending_batch_id="${pending_spec%% *}"
  pending_rest="${pending_spec#* }"
  pending_iid="${pending_rest%% *}"
  pending_status="${pending_rest#* }"
  pending_job_id="${pending_batch_id}:snapshot-0"
  jq \
    --arg status "${pending_status}" \
    --arg job_id "${pending_job_id}" \
    --argjson iid "${pending_iid}" '
    .status = "running"
    | .next_snapshot_index = 1
    | .memberships["0"] = {
        snapshot_index:0,
        iid:$iid,
        status:$status,
        job_id:$job_id
      }
  ' "${SCHEDULER_ROOT}/batches/${pending_batch_id}/state.json" \
    >"${TEST_ROOT}/legacy-pending-${pending_batch_id}.json"
done

jq -cnS \
  --slurpfile q_state "${TEST_ROOT}/legacy-pending-Q.json" \
  --slurpfile w_state "${TEST_ROOT}/legacy-pending-W.json" \
  --slurpfile z_state "${TEST_ROOT}/legacy-pending-Z.json" '{
  version:1,
  round_robin_cursor:null,
  active_jobs:{},
  batch_order:["Q","W","Z"],
  pending_transaction:{
    version:1,
    scheduler_state:{
      version:1,
      round_robin_cursor:"Z",
      batch_order:["Q","W","Z"],
      active_jobs:{
        "Q:snapshot-0":{
          job_id:"Q:snapshot-0",physical_key:"group/pending#41",
          project:"group/pending",iid:41,branch:"main",entry_mode:"auto",
          force_rerun_pr:false,status:"reserved",reserved_at:90,updated_at:90,
          owner:{batch_id:"Q",snapshot_index:0},
          memberships:[{batch_id:"Q",snapshot_index:0}]
        },
        "W:snapshot-0":{
          job_id:"W:snapshot-0",physical_key:"group/pending#42",
          project:"group/pending",iid:42,branch:"main",entry_mode:"auto",
          force_rerun_pr:false,status:"preparing",reserved_at:90,updated_at:91,
          owner:{batch_id:"W",snapshot_index:0},
          memberships:[{batch_id:"W",snapshot_index:0}]
        },
        "Z:snapshot-0":{
          job_id:"Z:snapshot-0",physical_key:"group/pending#43",
          project:"group/pending",iid:43,branch:"main",entry_mode:"auto",
          force_rerun_pr:false,status:"running",reserved_at:80,updated_at:92,
          owner:{batch_id:"Z",snapshot_index:0},
          memberships:[{batch_id:"Z",snapshot_index:0}]
        }
      }
    },
    batch_states:{Q:$q_state[0],W:$w_state[0],Z:$z_state[0]}
  }
}' >"${SCHEDULER_ROOT}/scheduler_state.json"

set +e
legacy_pending_terminal="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='Z:snapshot-0' STATUS=terminal \
    TERMINAL_STATUS=done \
    NOW_EPOCH=300 bash "${RECORD}" 2>&1
)"
legacy_pending_status=$?
set -e
if [ "${legacy_pending_status}" -ne 0 ]; then
  echo "expected legacy pending transaction recovery to succeed, got ${legacy_pending_status}: ${legacy_pending_terminal}" >&2
  exit 1
fi
jq -e '.job_status == "terminal" and .active_count == 2' \
  <<<"${legacy_pending_terminal}" >/dev/null
jq -e '.memberships["0"].status == "terminal"' \
  "${SCHEDULER_ROOT}/batches/Z/state.json" >/dev/null

legacy_pending_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=301 bash "${RESERVE}"
)"
if ! jq -e '
  [.grants[] | {batch_id,iid}] == [
    {batch_id:"Q",iid:41},
    {batch_id:"W",iid:42}
  ]
  and .active_count == 2
  and .available_slots == 1
' <<<"${legacy_pending_reserve}" >/dev/null; then
  echo "expected migrated pending grants without legacy running replay, got ${legacy_pending_reserve}" >&2
  exit 1
fi
jq -e '
  (.pending_transaction | not)
  and .active_jobs["Q:snapshot-0"].reservation_seq == 2
  and .active_jobs["Q:snapshot-0"].claim_generation == 0
  and .active_jobs["Q:snapshot-0"].claim_token == null
  and .active_jobs["W:snapshot-0"].reservation_seq == 3
  and .active_jobs["W:snapshot-0"].status == "reserved"
  and .active_jobs["W:snapshot-0"].claim_generation == 0
  and .active_jobs["W:snapshot-0"].claim_token == null
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '.memberships["0"].status == "reserved"' \
  "${SCHEDULER_ROOT}/batches/W/state.json" >/dev/null

legacy_w_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='W:snapshot-0' STATUS=preparing \
    NOW_EPOCH=302 bash "${RECORD}"
)"
legacy_w_token="$(jq -r '.claim_token' <<<"${legacy_w_claim}")"
jq -e '
  .should_spawn == true
  and (.claim_token | type == "string" and length > 0)
' <<<"${legacy_w_claim}" >/dev/null
CONFIG_DIR="${CONFIG_DIR}" JOB_ID='W:snapshot-0' STATUS=spawned \
  CLAIM_TOKEN="${legacy_w_token}" NOW_EPOCH=303 \
  bash "${RECORD}" >/dev/null
CONFIG_DIR="${CONFIG_DIR}" JOB_ID='W:snapshot-0' STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN="${legacy_w_token}" NOW_EPOCH=304 \
  bash "${RECORD}" >/dev/null
jq -e '.active_jobs | has("W:snapshot-0") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

# A finalization fence freezes the exact membership snapshot that the importer
# will fan out. A same-intent batch registered in the importer->record window
# must remain pending, then receive an independent physical job after terminal.
SCHEDULER_ROOT="${TEST_ROOT}/finalization-fence-scheduler"
CONFIG_DIR="${TEST_ROOT}/finalization-fence-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_single_fixture X group/fence 71 main false
create_single_fixture Y group/fence 71 main false
jq '.batch_order = ["X","Y"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

fence_reserve="$(CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=400 bash "${RESERVE}")"
fence_job_id="$(jq -r '.grants[0].job_id' <<<"${fence_reserve}")"
fence_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=preparing \
    NOW_EPOCH=401 bash "${RECORD}"
)"
jq -e '
  .should_spawn == true
  and .claim_generation == 1
  and (.claim_token | type == "string" and length > 0)
' <<<"${fence_claim}" >/dev/null || {
  echo "preparing claim response omitted the bind generation"
  exit 1
}
fence_token="$(jq -r '.claim_token' <<<"${fence_claim}")"
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=spawned \
  CLAIM_TOKEN="${fence_token}" NOW_EPOCH=402 bash "${RECORD}" >/dev/null
fence_event_id="${fence_job_id}:claim-1:terminal-1"
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/fence-before-missing-marker.scheduler.json"
cp "${SCHEDULER_ROOT}/batches/X/state.json" \
  "${TEST_ROOT}/fence-before-missing-marker.batch-x.json"
cp "${SCHEDULER_ROOT}/batches/Y/state.json" \
  "${TEST_ROOT}/fence-before-missing-marker.batch-y.json"
set +e
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN="${fence_token}" FINALIZATION_EVENT_ID="${fence_event_id}" \
  NOW_EPOCH=403 bash "${RECORD}" \
  >"${TEST_ROOT}/fence-terminal-missing-marker.out" \
  2>"${TEST_ROOT}/fence-terminal-missing-marker.err"
missing_marker_rc=$?
set -e
if [ "${missing_marker_rc}" -ne 3 ]; then
  echo "terminal event without finalization fence exited ${missing_marker_rc}, expected 3" >&2
  exit 1
fi
for unchanged_pair in \
  "${SCHEDULER_ROOT}/scheduler_state.json:${TEST_ROOT}/fence-before-missing-marker.scheduler.json" \
  "${SCHEDULER_ROOT}/batches/X/state.json:${TEST_ROOT}/fence-before-missing-marker.batch-x.json" \
  "${SCHEDULER_ROOT}/batches/Y/state.json:${TEST_ROOT}/fence-before-missing-marker.batch-y.json"
do
  current_file="${unchanged_pair%%:*}"
  before_file="${unchanged_pair#*:}"
  cmp -s "${current_file}" "${before_file}" || {
    echo "missing finalization fence rejection changed durable state" >&2
    exit 1
  }
done
jq \
  --arg job_id "${fence_job_id}" \
  --arg event_id "${fence_event_id}" \
  --arg token "${fence_token}" '
  .active_jobs[$job_id].finalization = {
    event_id:$event_id,
    claim_generation:1,
    claim_token:$token,
    membership_keys:["X:snapshot-0","Y:snapshot-0"]
  }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.finalizing.json"
mv "${SCHEDULER_ROOT}/scheduler_state.finalizing.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

create_single_fixture ZF group/fence 71 main false
jq '.batch_order += ["ZF"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-zf.json"
mv "${SCHEDULER_ROOT}/scheduler_state.with-zf.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

fence_window_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=403 bash "${RESERVE}"
)"
jq -e '.grants == [] and .active_count == 1' \
  <<<"${fence_window_reserve}" >/dev/null
jq -e --arg job_id "${fence_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/ZF/state.json" >/dev/null \
  || {
    echo "finalization fence allowed a late membership to attach" >&2
    exit 1
  }
jq -e --arg job_id "${fence_job_id}" '
  [.active_jobs[$job_id].memberships[].batch_id] == ["X","Y"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/fence-before-rejected-spawned.scheduler.json"
cp "${SCHEDULER_ROOT}/batches/X/state.json" \
  "${TEST_ROOT}/fence-before-rejected-spawned.batch-x.json"
if CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=spawned \
  CLAIM_TOKEN="${fence_token}" NOW_EPOCH=404 bash "${RECORD}" \
  >"${TEST_ROOT}/fence-spawned.out" 2>"${TEST_ROOT}/fence-spawned.err"; then
  echo "finalization job accepted a non-terminal transition" >&2
  exit 1
fi
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/fence-before-rejected-spawned.scheduler.json" \
  || {
    echo "rejected finalization transition changed scheduler state" >&2
    exit 1
  }
cmp -s "${SCHEDULER_ROOT}/batches/X/state.json" \
  "${TEST_ROOT}/fence-before-rejected-spawned.batch-x.json" \
  || {
    echo "rejected finalization transition changed batch state" >&2
    exit 1
  }

if CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN="${fence_token}" NOW_EPOCH=405 bash "${RECORD}" \
  >"${TEST_ROOT}/fence-terminal-no-event.out" \
  2>"${TEST_ROOT}/fence-terminal-no-event.err"; then
  echo "finalization terminal accepted a missing event identity" >&2
  exit 1
fi
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/fence-before-rejected-spawned.scheduler.json" \
  || {
    echo "missing finalization event changed scheduler state" >&2
    exit 1
  }

jq --arg job_id "${fence_job_id}" '
  .active_jobs[$job_id].finalization.membership_keys = ["X:snapshot-0"]
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.bad-finalization-memberships.json"
mv "${SCHEDULER_ROOT}/scheduler_state.bad-finalization-memberships.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/fence-before-membership-mismatch.scheduler.json"
if CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN="${fence_token}" FINALIZATION_EVENT_ID="${fence_event_id}" \
  NOW_EPOCH=406 bash "${RECORD}" \
  >"${TEST_ROOT}/fence-terminal-membership-mismatch.out" \
  2>"${TEST_ROOT}/fence-terminal-membership-mismatch.err"; then
  echo "finalization terminal accepted a changed membership snapshot" >&2
  exit 1
fi
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/fence-before-membership-mismatch.scheduler.json" \
  || {
    echo "membership mismatch changed scheduler state" >&2
    exit 1
  }
jq --arg job_id "${fence_job_id}" '
  .active_jobs[$job_id].finalization.membership_keys = [
    "X:snapshot-0",
    "Y:snapshot-0"
  ]
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.restored-finalization.json"
mv "${SCHEDULER_ROOT}/scheduler_state.restored-finalization.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${fence_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN="${fence_token}" FINALIZATION_EVENT_ID="${fence_event_id}" \
  NOW_EPOCH=407 bash "${RECORD}" >/dev/null
after_fence_terminal="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=408 bash "${RESERVE}"
)"
jq -e '
  [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"ZF",project:"group/fence",iid:71}
  ]
' <<<"${after_fence_terminal}" >/dev/null

# Dependency deferral is a non-terminal slot release. It parks both the owner
# and same-intent attached memberships, lets ordinary pending/lazy work win the
# next reservation, then returns the deferred work under a new job generation.
SCHEDULER_ROOT="${TEST_ROOT}/dependency-defer-scheduler"
CONFIG_DIR="${TEST_ROOT}/dependency-defer-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=1' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_single_fixture C group/dependency 30 main false
create_single_fixture C_ATTACH group/dependency 30 main false
create_single_fixture A group/dependency 10 main false
jq '.batch_order = ["C","C_ATTACH","A"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

dependency_first_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=500 bash "${RESERVE}"
)"
jq -e '
  [.grants[] | {batch_id,iid,job_id}] == [
    {batch_id:"C",iid:30,job_id:"C:snapshot-0"}
  ]
  and .active_count == 1
  and .available_slots == 0
' <<<"${dependency_first_reserve}" >/dev/null
jq -e '
  .active_jobs["C:snapshot-0"].status == "reserved"
  and [.active_jobs["C:snapshot-0"].memberships[].batch_id]
    == ["C","C_ATTACH"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '
  .memberships["0"].status == "attached"
  and .memberships["0"].job_id == "C:snapshot-0"
' "${SCHEDULER_ROOT}/batches/C_ATTACH/state.json" >/dev/null

reserved_dependency_defer="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0' \
    ACTION=dependency_deferred NOW_EPOCH=501 bash "${RECORD}"
)"
jq -e '
  .status == "recorded"
  and .job_id == "C:snapshot-0"
  and .job_status == "retry_wait"
  and .active_count == 0
  and .should_spawn == false
  and .claim_generation == null
  and .claim_token == null
' <<<"${reserved_dependency_defer}" >/dev/null
jq -e '.active_jobs | has("C:snapshot-0") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
for deferred_batch in C C_ATTACH; do
  jq -e '
    .status == "queued"
    and .terminal_count == 0
    and .done_count == 0
    and .failed_count == 0
    and .timeout_count == 0
    and .skipped_count == 0
    and .memberships["0"].status == "retry_wait"
    and .memberships["0"].defer_count == 1
    and (.memberships["0"] | has("job_id") | not)
    and (.memberships["0"] | has("blocked_by_job_id") | not)
  ' "${SCHEDULER_ROOT}/batches/${deferred_batch}/state.json" >/dev/null
done

# C's retry_wait membership must yield the only slot to later ordinary work.
dependency_later_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=502 bash "${RESERVE}"
)"
jq -e '
  [.grants[] | {batch_id,iid,job_id}] == [
    {batch_id:"A",iid:10,job_id:"A:snapshot-0"}
  ]
  and .active_count == 1
  and .available_slots == 0
' <<<"${dependency_later_reserve}" >/dev/null
CONFIG_DIR="${CONFIG_DIR}" JOB_ID='A:snapshot-0' STATUS=terminal \
  TERMINAL_STATUS=done NOW_EPOCH=503 bash "${RECORD}" >/dev/null

dependency_retry_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=504 bash "${RESERVE}"
)"
jq -e '
  [.grants[] | {batch_id,iid,job_id}] == [
    {batch_id:"C",iid:30,job_id:"C:snapshot-0::defer-1"}
  ]
  and .active_count == 1
' <<<"${dependency_retry_reserve}" >/dev/null
jq -e '
  .active_jobs["C:snapshot-0::defer-1"].status == "reserved"
  and [.active_jobs["C:snapshot-0::defer-1"].memberships[].batch_id]
    == ["C","C_ATTACH"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
for deferred_batch in C C_ATTACH; do
  jq -e '
    .memberships["0"].defer_count == 1
    and .memberships["0"].job_id == "C:snapshot-0::defer-1"
    and (.memberships["0"].status == "reserved"
      or .memberships["0"].status == "attached")
  ' "${SCHEDULER_ROOT}/batches/${deferred_batch}/state.json" >/dev/null
done

# A running deferral is claim-fenced. A bad token cannot mutate durable state;
# the exact current claim releases the job and increments each membership once.
dependency_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-1' \
    STATUS=preparing NOW_EPOCH=505 bash "${RECORD}"
)"
dependency_claim_token="$(jq -r '.claim_token' <<<"${dependency_claim}")"
dependency_claim_generation="$(jq -r '.claim_generation' <<<"${dependency_claim}")"
CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-1' STATUS=spawned \
  CLAIM_TOKEN="${dependency_claim_token}" NOW_EPOCH=506 \
  bash "${RECORD}" >/dev/null
dependency_running_scheduler_before="$(jq -cS . \
  "${SCHEDULER_ROOT}/scheduler_state.json")"
dependency_running_c_before="$(jq -cS . \
  "${SCHEDULER_ROOT}/batches/C/state.json")"
set +e
bad_running_defer="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-1' \
    ACTION=dependency_deferred \
    CLAIM_GENERATION="${dependency_claim_generation}" \
    CLAIM_TOKEN='wrong-dependency-claim' NOW_EPOCH=507 \
    bash "${RECORD}" 2>&1
)"
bad_running_defer_rc=$?
set -e
if [ "${bad_running_defer_rc}" -ne 3 ]; then
  echo "running dependency defer with a bad claim exited ${bad_running_defer_rc}: ${bad_running_defer}" >&2
  exit 1
fi
[ "$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")" \
    = "${dependency_running_scheduler_before}" ] || {
  echo "rejected running dependency defer changed scheduler state" >&2
  exit 1
}
[ "$(jq -cS . "${SCHEDULER_ROOT}/batches/C/state.json")" \
    = "${dependency_running_c_before}" ] || {
  echo "rejected running dependency defer changed batch state" >&2
  exit 1
}

running_dependency_defer="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-1' \
    ACTION=dependency_deferred \
    CLAIM_GENERATION="${dependency_claim_generation}" \
    CLAIM_TOKEN="${dependency_claim_token}" NOW_EPOCH=508 \
    bash "${RECORD}"
)"
jq -e '
  .job_status == "retry_wait"
  and .active_count == 0
  and .should_spawn == false
  and .claim_generation == null
  and .claim_token == null
' <<<"${running_dependency_defer}" >/dev/null
jq -e '.active_jobs | has("C:snapshot-0::defer-1") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
for deferred_batch in C C_ATTACH; do
  jq -e '
    .status == "queued"
    and .terminal_count == 0
    and .done_count == 0
    and .failed_count == 0
    and .timeout_count == 0
    and .skipped_count == 0
    and .memberships["0"].status == "retry_wait"
    and .memberships["0"].defer_count == 2
    and (.memberships["0"] | has("job_id") | not)
  ' "${SCHEDULER_ROOT}/batches/${deferred_batch}/state.json" >/dev/null
done

# An expired preparing lease becomes tokenless reserved while retaining its
# positive generation. Dependency deferral must require that exact generation:
# a stale generation is read-only, and the current one releases the slot.
dependency_expired_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=509 \
    DRIVEN_PREPARING_LEASE_SECONDS=1 bash "${RESERVE}"
)"
jq -e '
  [.grants[] | {job_id,iid}] == [
    {job_id:"C:snapshot-0::defer-2",iid:30}
  ]
' <<<"${dependency_expired_reserve}" >/dev/null
dependency_expiring_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-2' \
    STATUS=preparing NOW_EPOCH=510 DRIVEN_PREPARING_LEASE_SECONDS=1 \
    bash "${RECORD}"
)"
dependency_expiring_generation="$(jq -r '.claim_generation' \
  <<<"${dependency_expiring_claim}")"
CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=512 \
  DRIVEN_PREPARING_LEASE_SECONDS=1 bash "${RESERVE}" >/dev/null
jq -e \
  --argjson generation "${dependency_expiring_generation}" '
  .active_jobs["C:snapshot-0::defer-2"].status == "reserved"
  and .active_jobs["C:snapshot-0::defer-2"].claim_generation == $generation
  and .active_jobs["C:snapshot-0::defer-2"].claim_token == null
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
dependency_expired_scheduler_before="$(jq -cS . \
  "${SCHEDULER_ROOT}/scheduler_state.json")"
set +e
bad_expired_defer="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-2' \
    ACTION=dependency_deferred \
    CLAIM_GENERATION="$((dependency_expiring_generation + 1))" NOW_EPOCH=513 \
    bash "${RECORD}" 2>&1
)"
bad_expired_defer_rc=$?
set -e
if [ "${bad_expired_defer_rc}" -ne 3 ]; then
  echo "recovered dependency defer with stale generation exited ${bad_expired_defer_rc}: ${bad_expired_defer}" >&2
  exit 1
fi
[ "$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")" \
    = "${dependency_expired_scheduler_before}" ] || {
  echo "stale recovered dependency generation changed scheduler state" >&2
  exit 1
}
expired_dependency_defer="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='C:snapshot-0::defer-2' \
    ACTION=dependency_deferred \
    CLAIM_GENERATION="${dependency_expiring_generation}" NOW_EPOCH=514 \
    bash "${RECORD}"
)"
jq -e '
  .job_status == "retry_wait"
  and .active_count == 0
  and .claim_generation == null
  and .claim_token == null
' <<<"${expired_dependency_defer}" >/dev/null
for deferred_batch in C C_ATTACH; do
  jq -e '
    .memberships["0"].status == "retry_wait"
    and .memberships["0"].defer_count == 3
  ' "${SCHEDULER_ROOT}/batches/${deferred_batch}/state.json" >/dev/null
done

echo 'ok driven scheduler dedup'
