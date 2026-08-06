#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

grep -Fq 'task=payload,' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pass the rendered text as task"
grep -Fq 'runtime="subagent"' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pin runtime=subagent"
grep -Fq 'mode="run"' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pin mode=run"
grep -Fq 'cleanup="keep")' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must use the five-field 4.9/6.11-compatible contract"
grep -Fq 'sessions_yield' "${SKILL_DIR}/SKILL.md" \
  || fail "successful spawns must yield for native completion delivery"
grep -Fq 'ingest_subagent_completion.sh' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion must use the authenticated ingester"
grep -Fq 'env -u PROJECT -u GROUP -u PROJECT_FULL' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion must clear ambient project routing"
grep -Fq -- '-u PROJECT_URI -u REPO_PATH' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion must clear ambient repo routing"
grep -Fq "ingest_subagent_completion.sh <<'COMPLETION_EOF'" "${SKILL_DIR}/SKILL.md" \
  || fail "native completion ingester does not require a Bash heredoc"
grep -Fq 'does not deliver a tool argument named `stdin`' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion path does not explain OpenClaw stdin semantics"
grep -Fq 'never use an `stdin` tool argument' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "workspace rules do not forbid the ignored exec stdin argument"
grep -Fq 'first tool call in this turn' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion does not forbid tool discovery before ingestion"
grep -Fq 'only permitted later tool call is the exact best-effort' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion cleanup exception is not narrowly specified"
grep -Fq 'raw internal completion context' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "workspace rules do not require the minimal 4.9 selector"
if grep -Fq -- '-u REPO_PARENT_PATH' "${SKILL_DIR}/SKILL.md"; then
  fail "native completion must preserve the deployment clone-root override"
fi
grep -Fq 'openclaw_4_9_terminal_reference' "${SKILL_DIR}/SKILL.md" \
  || fail "4.9 native completion must use the terminal reference selector"
grep -Fq 'reconcile_native_subagent_terminal.sh' \
  "${SKILL_DIR}/scripts/run_executor_batch_tick.sh" \
  || fail "heartbeat must invoke fixed native terminal reconciliation"
grep -Fq "authoritative global session registry" "${SKILL_DIR}/SKILL.md" \
  || fail "callback-loss recovery must not depend on requester-scoped runtime listing"
grep -Fq 'global OpenClaw session registry' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "workspace rules do not preserve automatic callback-loss recovery"
grep -Fq 'priority than every command first-line route' "${SKILL_DIR}/SKILL.md" \
  || fail "protected native completion must outrank command routing"
grep -Fq 'Any embedded' "${SKILL_DIR}/SKILL.md" \
  && grep -Fq 'runtime Action asking for a normal user-facing delivery' "${SKILL_DIR}/SKILL.md" \
  || fail "runtime delivery prose must not override Path B"
grep -Fq 'edit, patch, or debug `ingest_subagent_completion.sh`' "${SKILL_DIR}/SKILL.md" \
  || fail "completion rejection must not trigger script debugging"
grep -Fq 'never call `run_executor_batch_tick.sh` before' "${SKILL_DIR}/SKILL.md" \
  || fail "native completion must ingest before any heartbeat"
grep -Fq 'protected native subagent completion' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must route protected completions first"
grep -Fq 'A protected native subagent completion has higher routing priority' "${WORKSPACE_DIR}/SOUL.md" \
  || fail "executor soul must route protected completions before command text"
grep -Fq 'never summarizes the untrusted child Result' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "native completion must not be converted into a user-facing summary"
grep -Fq 'Do not Read any config or *.env file' "${SKILL_DIR}/SKILL.md" \
  || fail "heartbeat tick must not expose private config to the model"
grep -Fq 'Never read config or `*.env` files' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must keep tick config private"
grep -Fq 'Exact `RUN_DRIVEN_ISSUE_BATCH` → Path C' "${SKILL_DIR}/SKILL.md" \
  || fail "executor skill must route batch intake before heartbeat tick"
grep -Fq '`RUN_DRIVEN_ISSUE_BATCH` is never a heartbeat tick' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must distinguish batch intake from tick"
for mission_stop_contract in \
  "${SKILL_DIR}/SKILL.md" \
  "${WORKSPACE_DIR}/AGENTS.md" \
  "${WORKSPACE_DIR}/CLAUDE.md" \
  "${WORKSPACE_DIR}/SOUL.md"
do
  grep -Fq 'emit_mission_stop_receipt.sh' "${mission_stop_contract}" \
    || fail "mission-stop strict receipt emitter is missing from ${mission_stop_contract}"
done

PATH_C_SECTION="$(sed -n '/^### Path C /,/^### Path D /p' "${SKILL_DIR}/SKILL.md")"
PATH_D_SECTION="$(sed -n '/^### Path D /,/^### Path E /p' "${SKILL_DIR}/SKILL.md")"
PATH_E_SECTION="$(sed -n '/^### Path E /,/^### Path F /p' "${SKILL_DIR}/SKILL.md")"
grep -Fq 'MUST NOT call' <<<"${PATH_C_SECTION}" \
  && grep -Fq '`sessions_yield` anywhere in this turn' <<<"${PATH_C_SECTION}" \
  || fail "Path C must absolutely forbid sessions_yield"
if grep -Fq 'Path D steps 3–5' <<<"${PATH_C_SECTION}"; then
  fail "Path C must not inherit Path D termination step 5"
fi
grep -Fq "record_executor_batch_spawn.sh <<'JSON_EOF'" <<<"${PATH_D_SECTION}" \
  || fail "Path D must show strict JSON stdin recorder invocation"
grep -Fq 'Do not pass JOB_ID, CLAIM_GENERATION' <<<"${PATH_D_SECTION}" \
  || fail "Path D must forbid the unrelated environment-variable recorder contract"
grep -Fq 'On Path D only' <<<"${PATH_D_SECTION}" \
  || fail "post-recorder sessions_yield must be scoped to Path D"
grep -Fq 'MUST NOT call' <<<"${PATH_E_SECTION}" \
  && grep -Fq '`sessions_yield` anywhere in this turn' <<<"${PATH_E_SECTION}" \
  || fail "Path E must absolutely forbid sessions_yield"
grep -Fq 'recorder is the mandatory next tool call' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must persist spawn ack before yielding"
grep -Fq 'never jump from the intake wrapper to the' "${WORKSPACE_DIR}/AGENTS.md" \
  && grep -Fq 'acceptance emitter' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must not skip a Path C spawn grant"
grep -Fq 'fixed emitter is the hard runtime-action fence' "${SKILL_DIR}/SKILL.md" \
  || fail "Path C must document the deterministic acceptance fence"
grep -Fq 'Unmatched human prose is not a scheduler trigger' \
  "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "operator prose must not authorize manual spawn recovery"

RECORDER_STDERR="$(mktemp "${TMPDIR:-/tmp}/req-executor-recorder-empty-stdin.XXXXXX")"
set +e
JOB_ID=ignored CLAIM_GENERATION=1 PROJECT=group/repo IID=1 EXECUTION_ID=1 \
STATUS=spawned RUN_ID=ignored CHILD_SESSION_KEY=ignored \
  bash "${SKILL_DIR}/scripts/record_executor_batch_spawn.sh" \
  </dev/null 2>"${RECORDER_STDERR}"
RECORDER_RC=$?
set -e
[ "${RECORDER_RC}" -eq 2 ] \
  || fail "recorder accepted environment fields without strict JSON stdin"
grep -Fq 'stdin must be one strict spawned or launch_failed result object' \
  "${RECORDER_STDERR}" \
  || fail "recorder empty-stdin rejection was not explicit"
[ "$(cat "${WORKSPACE_DIR}/HEARTBEAT.md")" = 'RUN_EXECUTOR_BATCH_TICK' ] \
  || fail "executor deployment artifact must keep durable-result recovery heartbeat active"

for forbidden in \
  'sessions_spawn(payload=' \
  'payload=payload' \
  'timeoutSeconds=' \
  'runTimeoutSeconds=' \
  'context="isolated"'
do
  if rg -n -F "${forbidden}" \
    "${SKILL_DIR}/SKILL.md" \
    "${SKILL_DIR}/references" \
    "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh" \
    "${WORKSPACE_DIR}/CLAUDE.md" \
    "${WORKSPACE_DIR}/SOUL.md" \
    "${WORKSPACE_DIR}/AGENTS.md" \
    "${WORKSPACE_DIR}/docs/REQ_EXECUTOR_USAGE.md"; then
    fail "active spawn contract still contains forbidden form: ${forbidden}"
  fi
done

echo "ok req_executor uses the common OpenClaw 2026.4.9/2026.6.11 spawn contract"
