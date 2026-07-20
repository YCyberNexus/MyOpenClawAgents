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
if grep -Fq -- '-u REPO_PARENT_PATH' "${SKILL_DIR}/SKILL.md"; then
  fail "native completion must preserve the deployment clone-root override"
fi
grep -Fq 'openclaw_4_9_terminal_reference' "${SKILL_DIR}/SKILL.md" \
  || fail "4.9 native completion must use the terminal reference selector"
grep -Fq 'priority than every command first-line route' "${SKILL_DIR}/SKILL.md" \
  || fail "protected native completion must outrank command routing"
grep -Fq 'edit, patch, or debug `ingest_subagent_completion.sh`' "${SKILL_DIR}/SKILL.md" \
  || fail "completion rejection must not trigger script debugging"
grep -Fq 'protected native subagent completion' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must route protected completions first"
grep -Fq 'A protected native subagent completion has higher routing priority' "${WORKSPACE_DIR}/SOUL.md" \
  || fail "executor soul must route protected completions before command text"
grep -Fq 'Do not Read any config or *.env file' "${SKILL_DIR}/SKILL.md" \
  || fail "heartbeat tick must not expose private config to the model"
grep -Fq 'Never read config or `*.env` files' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must keep tick config private"
grep -Fq 'Exact `RUN_DRIVEN_ISSUE_BATCH` → Path C' "${SKILL_DIR}/SKILL.md" \
  || fail "executor skill must route batch intake before heartbeat tick"
grep -Fq '`RUN_DRIVEN_ISSUE_BATCH` is never a heartbeat tick' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "executor bootstrap rules must distinguish batch intake from tick"
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
