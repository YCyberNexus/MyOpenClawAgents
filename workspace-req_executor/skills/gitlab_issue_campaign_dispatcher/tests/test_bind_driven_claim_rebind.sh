#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIND_SCRIPT="${SKILL_DIR}/scripts/bind_driven_claim.sh"

fail() {
  echo "test_bind_driven_claim_rebind.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-bind-rebind.XXXXXX")"
REPO_PARENT="${TEST_ROOT}/repos/group"
REPO_PATH="${REPO_PARENT}/repo"
STATE_DIR="${REPO_PATH}/.req_executor/_dispatcher"
mkdir -p "${REPO_PATH}/.git" "${STATE_DIR}"
FAKE_GLAB="${TEST_ROOT}/glab"
cat >"${FAKE_GLAB}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FAKE_GLAB}"

cat >"${STATE_DIR}/campaign_state.json" <<'EOF'
{
  "project":"repo",
  "pending_subagents":{
    "42":{
      "execution_id":1,
      "run_id":null,
      "child_session_key":null,
      "spawned_at":null,
      "placeholder":true,
      "job_id":"A:snapshot-0",
      "batch_id":"A",
      "snapshot_index":0,
      "memberships_source":"scheduler_active_job",
      "claim_generation":1,
      "claim_token":"old-private-claim",
      "bound_at":"2026-07-11T00:00:00Z"
    }
  }
}
EOF

rebound="$(PROJECT=repo GROUP=group GITLAB_TOKEN=fixture \
  GLAB_BIN="${FAKE_GLAB}" \
  REPO_PARENT_PATH="${REPO_PARENT}" IID=42 JOB_ID='A:snapshot-0' \
  CLAIM_GENERATION=2 CLAIM_TOKEN='new-private-claim' \
  NOW_ISO='2026-07-11T00:01:00Z' bash "${BIND_SCRIPT}")"
jq -e '
  .status == "rebound"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 2
' <<<"${rebound}" >/dev/null || fail "safe placeholder was not rebound"
jq -e '
  .pending_subagents["42"].claim_generation == 2
  and .pending_subagents["42"].claim_token == "new-private-claim"
  and .pending_subagents["42"].bound_at == "2026-07-11T00:01:00Z"
' "${STATE_DIR}/campaign_state.json" >/dev/null \
  || fail "new generation was not persisted atomically"

spawned_state="$(jq -c '
  .pending_subagents["42"].placeholder = false
  | .pending_subagents["42"].run_id = "run-42"
  | .pending_subagents["42"].child_session_key = "agent:req_executor:subagent:42"
  | .pending_subagents["42"].spawned_at = "2026-07-11T00:02:00Z"
' "${STATE_DIR}/campaign_state.json")"
printf '%s\n' "${spawned_state}" >"${STATE_DIR}/campaign_state.json"
before="$(jq -cS . "${STATE_DIR}/campaign_state.json")"
set +e
PROJECT=repo GROUP=group GITLAB_TOKEN=fixture \
  GLAB_BIN="${FAKE_GLAB}" \
  REPO_PARENT_PATH="${REPO_PARENT}" IID=42 JOB_ID='A:snapshot-0' \
  CLAIM_GENERATION=3 CLAIM_TOKEN='must-not-bind' \
  bash "${BIND_SCRIPT}" >/dev/null 2>"${TEST_ROOT}/spawned.err"
spawned_rc=$?
set -e
[ "${spawned_rc}" -eq 3 ] \
  || fail "spawned pending accepted a new generation (rc=${spawned_rc})"
[ "$(jq -cS . "${STATE_DIR}/campaign_state.json")" = "${before}" ] \
  || fail "rejected spawned rebind mutated campaign state"

echo "ok claim rebind is limited to an unacked placeholder"
