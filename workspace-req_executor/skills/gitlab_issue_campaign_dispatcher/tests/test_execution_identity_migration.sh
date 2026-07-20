#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/execution-identity-migration.XXXXXX")"

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export DISPATCHER_LOG_DIR="${TEST_ROOT}/log"
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT_URI="group%2Frepo"
export PROJECT="repo"
export REPO_PARENT_PATH="${TEST_ROOT}/repos/group"

fail() {
  echo "test_execution_identity_migration.sh: $*" >&2
  exit 1
}

mkdir -p "${DISPATCHER_LOG_DIR}" "${ISSUES_ROOT}/issue-9"
cat >"${CAMPAIGN_STATE_FILE}" <<'EOF'
{
  "run_timeout_seconds": 3600,
  "pending_subagents": {
    "9": {
      "attempt_number": 7,
      "finish_label_retry_attempt": 7
    }
  },
  "driven_handoff_intents": {}
}
EOF
cat >"${ISSUES_ROOT}/issue-9/attempt_state.json" <<'EOF'
{"attempt_number":7,"status":"in_progress"}
EOF
cat >"${ISSUES_ROOT}/issue-9/state.json" <<'EOF'
{"iid":9,"status":"in_progress","attempts_total":7,"latest_attempt_number":7,"preparing_attempt_number":8,"latest_attempt_dir":"attempt-007","prior_attempt_count":6}
EOF

# shellcheck source=../scripts/_dispatch_lib.sh
source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

# The unlocked completion-ingest reader may normalize its returned JSON, but it
# must never mutate any durable file.
cp "${CAMPAIGN_STATE_FILE}" "${TEST_ROOT}/campaign.before-load.json"
cp "${ISSUES_ROOT}/issue-9/attempt_state.json" "${TEST_ROOT}/counter.before-load.json"
cp "${ISSUES_ROOT}/issue-9/state.json" "${TEST_ROOT}/issue.before-load.json"
loaded="$(load_state)"
jq -e '
  (.pending_subagents["9"].attempt_number == 7)
  and (has("run_timeout_seconds") | not)
' <<<"${loaded}" >/dev/null || fail "load_state did not remain a pure normalization"
cmp -s "${CAMPAIGN_STATE_FILE}" "${TEST_ROOT}/campaign.before-load.json" \
  || fail "load_state mutated campaign state without the project lock"
cmp -s "${ISSUES_ROOT}/issue-9/attempt_state.json" \
  "${TEST_ROOT}/counter.before-load.json" \
  || fail "load_state mutated the legacy counter without the project lock"
cmp -s "${ISSUES_ROOT}/issue-9/state.json" "${TEST_ROOT}/issue.before-load.json" \
  || fail "load_state mutated Issue state without the project lock"

# An active legacy identity must drain under the old release. It is never
# deterministically hashed or otherwise converted into a new execution ID.
migration_rc=0
migrate_legacy_execution_state_locked || migration_rc=$?
[ "${migration_rc}" -eq 2 ] \
  || fail "active legacy state was not rejected with the drain-required code"
[ ! -e "${CAMPAIGN_STATE_FILE}.execution-identity-v2-migrated" ] \
  || fail "active legacy state received a false completed marker"
cmp -s "${CAMPAIGN_STATE_FILE}" "${TEST_ROOT}/campaign.before-load.json" \
  || fail "drain-required migration rewrote the legacy identity"

# After the old release has drained all active work, the locked one-time sweep
# may remove historical counter metadata and install a tombstone.
cat >"${CAMPAIGN_STATE_FILE}" <<'EOF'
{
  "project": "repo",
  "run_timeout_seconds": 3600,
  "pending_subagents": {},
  "driven_handoff_intents": {},
  "historical_execution": {
    "attempt_number": 7,
    "source_attempt_number": 7
  }
}
EOF
# Version 1 came from the former unlocked implementation and cannot certify
# that the project was quiet. The locked migration must replace it.
jq -nc '{version:1,completed:true}' \
  >"${CAMPAIGN_STATE_FILE}.execution-identity-v2-migrated"
migrate_legacy_execution_state_locked \
  || fail "quiescent legacy metadata cleanup failed"

jq -e '
  (keys | sort) == ["completed","requires_quiescent_lock","version"]
  and .version == 2 and .completed == true
  and .requires_quiescent_lock == true
' "${CAMPAIGN_STATE_FILE}.execution-identity-v2-migrated" >/dev/null \
  || fail "quiescent cleanup did not persist its completion marker"
jq -e '
  .project == "repo"
  and (.pending_subagents | length) == 0
  and (has("run_timeout_seconds") | not)
  and (.historical_execution | has("attempt_number") | not)
  and (.historical_execution | has("source_attempt_number") | not)
' "${CAMPAIGN_STATE_FILE}" >/dev/null \
  || fail "campaign state retained legacy execution counters"
jq -e '
  .iid == 9
  and .status == "in_progress"
  and (has("attempts_total") | not)
  and (has("latest_attempt_number") | not)
  and (has("preparing_attempt_number") | not)
  and (has("latest_attempt_dir") | not)
  and (has("prior_attempt_count") | not)
' "${ISSUES_ROOT}/issue-9/state.json" >/dev/null \
  || fail "Issue state retained legacy execution counters"
jq -e '
  (keys | sort) == ["deprecated","replacement","version"]
  and .version == 1
  and .deprecated == true
  and .replacement == "execution-scoped-state"
' "${ISSUES_ROOT}/issue-9/attempt_state.json" >/dev/null \
  || fail "legacy counter file was not replaced by a count-free tombstone"

echo "ok execution migration is locked, quiescent, and never derives an ID from a counter"
