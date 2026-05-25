#!/usr/bin/env bash
# load_ui_accounts.sh — read the test-team-owned UI test account pool
# (${REPO_PATH}/${DATA_BASENAME}/ifp-common/ifp_users.json) and print
# accounts to stdout, one per line in "user:pass" form, in JSON order.
#
# The dispatcher uses this to allocate distinct test accounts per IID in
# a concurrent batch. The system under test logs out an account when the
# same credentials log in twice, so two concurrent subagents — and two
# concurrent robot executions within a subagent — MUST NOT share an
# account. The pool is therefore divided into per-subagent slots whose
# size is computed automatically from the pool size,
# MAX_CONCURRENT_SUBAGENTS (the configured concurrency cap, NOT the
# actual batch size — slot sizes stay stable across batches that may
# pick fewer IIDs than the cap), and MAX_ACCOUNTS_PER_ISSUE (the
# per-IID account cap, default 14).
#
# Optional env vars:
#   MAX_CONCURRENT_SUBAGENTS   integer ≥ 1, ≤ pool_size. Required for
#                              batch allocation (info-only mode runs
#                              when omitted: just dumps the pool).
#   MAX_ACCOUNTS_PER_ISSUE     integer ≥ 1. Defaults to 14. Caps each
#                              per-IID slot after pool/concurrency
#                              division.
#
# When MAX_CONCURRENT_SUBAGENTS is set:
#   - The script validates 1 ≤ MAX_CONCURRENT_SUBAGENTS ≤ pool_size.
#   - It computes raw per-slot sizes by dividing pool_size by
#     MAX_CONCURRENT_SUBAGENTS. The integer remainder is front-loaded
#     onto the first slots. It then caps each slot at
#     MAX_ACCOUNTS_PER_ISSUE. Examples:
#       pool=3,  max=2 → SLOT_SIZES=2,1
#       pool=50, max=4, cap=14 → SLOT_SIZES=13,13,12,12
#       pool=40, max=1, cap=14 → SLOT_SIZES=14
#       pool=40, max=1, cap=10 → SLOT_SIZES=10
#   - It prints `POOL_SIZE=<n>` and capped `SLOT_SIZES=<csv>` to
#     stderr; the orchestrator captures these to slice stdout into
#     per-IID blocks.
#   - The csv length equals MAX_CONCURRENT_SUBAGENTS. The k-th IID of
#     the batch (0-indexed) takes SLOT_SIZES[k] accounts starting at
#     offset SUM(SLOT_SIZES[0..k-1]) in the stdout pool listing.
#
# Output (stdout):
#   <user1>:<pass1>
#   <user2>:<pass2>
#   ...                   (pool_size lines, in JSON order)
#
# Output (stderr, info only — captured by the orchestrator when
# MAX_CONCURRENT_SUBAGENTS is set):
#   POOL_SIZE=<n>
#   SLOT_SIZES=<count_0>,<count_1>,...,<count_{MAX_CONCURRENT_SUBAGENTS-1}>
#
# Exit codes:
#   0   success
#   10  account JSON file missing (deployment incomplete)
#   11  pool is empty (no valid entries)
#   12  pool JSON is malformed or contains an invalid entry
#   13  MAX_CONCURRENT_SUBAGENTS > pool_size (each in-flight subagent
#       MUST hold at least one distinct UI account; cannot satisfy)
#   14  MAX_CONCURRENT_SUBAGENTS is set but not a positive integer
#   15  MAX_ACCOUNTS_PER_ISSUE is set but not a positive integer
#
# On failure: the dispatcher MUST abort the tick (No-Fallback Policy —
# never improvise an account; never share an account between subagents).

set -euo pipefail

# Resolve only the repo/data paths this script needs. Do not source
# env_paths.sh here: that also bootstraps glab, but account loading is a
# local filesystem read.
: "${PROJECT:?load_ui_accounts: PROJECT must be set}"
: "${REPO_PARENT_PATH:=}"
if [ -n "${REPO_PARENT_PATH}" ]; then
  while [ "${REPO_PARENT_PATH}" != "/" ] && [ "${REPO_PARENT_PATH%/}" != "${REPO_PARENT_PATH}" ]; do
    REPO_PARENT_PATH="${REPO_PARENT_PATH%/}"
  done
  REPO_PATH="${REPO_PARENT_PATH}/${PROJECT}"
else
  : "${REPO_PATH:=/data/${PROJECT}}"
  while [ "${REPO_PATH}" != "/" ] && [ "${REPO_PATH%/}" != "${REPO_PATH}" ]; do
    REPO_PATH="${REPO_PATH%/}"
  done
fi
: "${DATA_BASENAME:=ifp-data}"
DATA_DIR="${REPO_PATH}/${DATA_BASENAME}"

POOL_FILE="${DATA_DIR}/ifp-common/ifp_users.json"

if [ ! -f "${POOL_FILE}" ]; then
  echo "load_ui_accounts: missing pool file ${POOL_FILE}; deployment incomplete" >&2
  exit 10
fi

# Parse the test team's JSON shape:
#   [{"username":"F100001","password":"123456","name":"..."}]
# Only username/password are consumed. `name` and other fields are ignored.
ACCOUNTS=()
VALIDATION_ERR="$(
  jq -e '
    def validate_entry:
      .key as $idx
      | .value as $entry
      | ($entry.username? | type) as $utype
      | ($entry.password? | type) as $ptype
      | if ($entry | type) != "object" then
          error("entry " + ($idx|tostring) + " must be an object")
        elif $utype != "string" or $ptype != "string" then
          error("entry " + ($idx|tostring) + " must contain string username/password")
        elif ($entry.username | length) == 0 or ($entry.password | length) == 0 then
          error("entry " + ($idx|tostring) + " has empty username/password")
        elif ($entry.username | test("[:\n\r]")) then
          error("entry " + ($idx|tostring) + " username must not contain colon or newline")
        elif ($entry.password | test("[\n\r]")) then
          error("entry " + ($idx|tostring) + " password must not contain newline")
        else
          true
        end;
    if type != "array" then
      error("top-level JSON must be an array")
    else
      to_entries | map(validate_entry) | all
    end
  ' "${POOL_FILE}" 2>&1 >/dev/null
)" || {
  echo "load_ui_accounts: ${POOL_FILE}: malformed account JSON: ${VALIDATION_ERR}" >&2
  exit 12
}

ACCOUNT_TEXT="$(jq -r 'to_entries[] | "\(.value.username):\(.value.password)"' "${POOL_FILE}")" || {
  echo "load_ui_accounts: ${POOL_FILE}: failed to read validated account JSON" >&2
  exit 12
}

if [ -n "${ACCOUNT_TEXT}" ]; then
  while IFS= read -r ACCOUNT_LINE || [ -n "${ACCOUNT_LINE}" ]; do
    ACCOUNTS+=("${ACCOUNT_LINE}")
  done <<<"${ACCOUNT_TEXT}"
fi

POOL_SIZE="${#ACCOUNTS[@]}"
if [ "${POOL_SIZE}" -eq 0 ]; then
  echo "load_ui_accounts: ${POOL_FILE} contains no valid entries" >&2
  exit 11
fi

if [ -n "${MAX_CONCURRENT_SUBAGENTS:-}" ]; then
  if ! [[ "${MAX_CONCURRENT_SUBAGENTS}" =~ ^[0-9]+$ ]] || [ "${MAX_CONCURRENT_SUBAGENTS}" -lt 1 ]; then
    echo "load_ui_accounts: MAX_CONCURRENT_SUBAGENTS must be a positive integer, got '${MAX_CONCURRENT_SUBAGENTS}'" >&2
    exit 14
  fi
  EFFECTIVE_MAX_ACCOUNTS_PER_ISSUE="${MAX_ACCOUNTS_PER_ISSUE:-14}"
  if ! [[ "${EFFECTIVE_MAX_ACCOUNTS_PER_ISSUE}" =~ ^[0-9]+$ ]] || [ "${EFFECTIVE_MAX_ACCOUNTS_PER_ISSUE}" -lt 1 ]; then
    echo "load_ui_accounts: MAX_ACCOUNTS_PER_ISSUE must be a positive integer, got '${EFFECTIVE_MAX_ACCOUNTS_PER_ISSUE}'" >&2
    exit 15
  fi
  if [ "${MAX_CONCURRENT_SUBAGENTS}" -gt "${POOL_SIZE}" ]; then
    echo "POOL_SIZE=${POOL_SIZE}" >&2
    echo "load_ui_accounts: MAX_CONCURRENT_SUBAGENTS ${MAX_CONCURRENT_SUBAGENTS} > pool size ${POOL_SIZE}; cannot give every concurrent subagent at least one distinct account" >&2
    exit 13
  fi

  BASE=$((POOL_SIZE / MAX_CONCURRENT_SUBAGENTS))
  REM=$((POOL_SIZE % MAX_CONCURRENT_SUBAGENTS))
  SLOT_SIZES=""
  for ((k = 0; k < MAX_CONCURRENT_SUBAGENTS; k++)); do
    if [ "${k}" -lt "${REM}" ]; then
      SIZE=$((BASE + 1))
    else
      SIZE="${BASE}"
    fi
    if [ "${SIZE}" -gt "${EFFECTIVE_MAX_ACCOUNTS_PER_ISSUE}" ]; then
      SIZE="${EFFECTIVE_MAX_ACCOUNTS_PER_ISSUE}"
    fi
    if [ -z "${SLOT_SIZES}" ]; then
      SLOT_SIZES="${SIZE}"
    else
      SLOT_SIZES="${SLOT_SIZES},${SIZE}"
    fi
  done
  echo "POOL_SIZE=${POOL_SIZE}" >&2
  echo "SLOT_SIZES=${SLOT_SIZES}" >&2
fi

for entry in "${ACCOUNTS[@]}"; do
  printf '%s\n' "${entry}"
done
