#!/usr/bin/env bash
# allocate_attempt.sh — atomically allocate the next attempt number for an
# IID and persist it into the per-issue state file. Returns the allocated
# number on stdout for the dispatcher to put into the prepared-worker trigger as
# `attempt_number=<N>`.
#
# Why this exists: the worker's env_paths.sh used to auto-increment the
# attempt number every time it was sourced. If the worker session got
# cold-restarted or env_paths was sourced multiple times in one logical
# resolution, you ended up with multiple attempt numbers and stale
# attempt-scoped paths because each source() advanced attempt state. The
# fix is to make attempt allocation a SINGLE event owned by the dispatcher:
# dispatcher allocates once before spawning, worker reads the allocated number from the
# trigger and never derives its own.
#
# Required env vars:
#   ISSUES_ROOT       from env_paths.sh (dispatcher)
#   IID               the issue IID being allocated for
#
# Side effects:
#   - creates ${ISSUES_ROOT}/issue-${IID}/ if missing
#   - reads or initializes ${ISSUES_ROOT}/issue-${IID}/state.json
#   - increments .attempts_total by 1 and writes back
#
# Output:
#   prints the new attempt_number (e.g. "7") on stdout, no trailing junk

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${ISSUES_ROOT:?run scripts/env_paths.sh first}"
: "${IID:?IID must be set}"

ISSUE_ROOT="${ISSUES_ROOT}/issue-${IID}"
STATE_FILE="${ISSUE_ROOT}/state.json"
LOCK_FILE="${ISSUE_ROOT}/.alloc.lock"

mkdir -p "${ISSUE_ROOT}"

# Use flock so two dispatcher invocations (shouldn't happen given the
# concurrency policy, but defensive) cannot both allocate the same number.
exec 8>"${LOCK_FILE}"
flock 8

if [ -s "${STATE_FILE}" ]; then
  CURRENT="$(jq -r '.attempts_total // 0' "${STATE_FILE}")"
else
  CURRENT=0
  # Initialize a minimal state file. Other fields (status, mode, etc.)
  # will be filled in by dispatcher preparation and the worker.
  jq -n --argjson iid "${IID}" '{
    iid: $iid,
    status: "pending",
    mode: "fresh",
    attempts_total: 0,
    skill_version: "2026-05-06.4"
  }' > "${STATE_FILE}"
fi

NEXT="$((CURRENT + 1))"

# Atomic update: write to a temp file, then rename.
TMP="$(mktemp "${ISSUE_ROOT}/.state.XXXXXX")"
jq --argjson n "${NEXT}" \
   --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.attempts_total = $n
    | .latest_attempt_number = $n
    | .updated_at = $now' "${STATE_FILE}" > "${TMP}"
mv "${TMP}" "${STATE_FILE}"

echo "${NEXT}"
