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
