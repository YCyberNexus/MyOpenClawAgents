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
  local batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"

  mkdir -p "${batch_dir}"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg project "${project}" \
    --arg branch "${branch}" \
    --argjson iid "${iid}" \
    --argjson force_rerun_pr "${force_rerun_pr}" \
    '{
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:$project,
      selector:{type:"single",iid:$iid},
      force_rerun_pr:$force_rerun_pr,
      dispatcher_callback_target:"agent:req_dispatcher:main",
      branch:$branch
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
# same physical key but a different branch, while E proves that equal short
# repo slugs in different groups remain different physical jobs.
create_single_fixture A group/repo 7 main false
create_single_fixture C group/repo 7 main false
create_single_fixture D group/repo 7 release false
create_single_fixture E other/repo 7 main false
jq '.batch_order = ["A","C","D","E"]' \
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

while IFS= read -r reserved_job_id; do
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${reserved_job_id}" STATUS=preparing \
    bash "${RECORD}" >/dev/null
done < <(jq -r '.grants[].job_id' <<<"${first_reserve}")

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
  bash "${RECORD}" >/dev/null
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .memberships["0"].status == "terminal"
' "${SCHEDULER_ROOT}/batches/A/state.json" >/dev/null
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .memberships["0"].status == "terminal"
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

CONFIG_DIR="${CONFIG_DIR}" JOB_ID="$(jq -r '.grants[0].job_id' <<<"${after_terminal}")" STATUS=preparing \
  bash "${RECORD}" >/dev/null
final_replay="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '.grants == [] and .active_count == 2' <<<"${final_replay}" >/dev/null

d_job_id="$(jq -r '.grants[0].job_id' <<<"${after_terminal}")"
launch_failed_out="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${d_job_id}" STATUS=launch_failed \
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
  and .batch_order[-1] == "Y"
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '.status == "completed" and .memberships["0"].status == "terminal"' \
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
  bash "${RECORD}" >/dev/null
next_intent_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,entry_mode,force_rerun_pr}] == [
    {batch_id:"G",entry_mode:"continue",force_rerun_pr:false}
  ]
  and .active_count == 2
' <<<"${next_intent_reserve}" >/dev/null

echo 'ok driven scheduler dedup'
