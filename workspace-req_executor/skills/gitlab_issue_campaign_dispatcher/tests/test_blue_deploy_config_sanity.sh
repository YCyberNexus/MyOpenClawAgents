#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQ_EXECUTOR_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${REQ_EXECUTOR_DIR}/.." && pwd)"
REQ_DISPATCHER_DIR="${REPO_ROOT}/workspace-req_dispatcher"

fail() {
  echo "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "${actual}" != "${expected}" ]; then
    fail "expected ${label}=${expected}, got ${actual}"
  fi
}

assert_nonempty() {
  local actual="$1"
  local label="$2"

  if [ -z "${actual}" ]; then
    fail "expected ${label} to be set"
  fi
}

source "${REQ_EXECUTOR_DIR}/config/gitlab.env"
source "${REQ_EXECUTOR_DIR}/config/campaign_defaults.env"
source "${REQ_DISPATCHER_DIR}/config/dispatcher.env"

assert_eq "gitlab-b.pxsemic.tech:30000" "${GITLAB_HOST:-}" "GITLAB_HOST"
assert_eq "http" "${GITLAB_API_PROTOCOL:-}" "GITLAB_API_PROTOCOL"
assert_eq "/data" "${REPO_PARENT_PATH:-}" "REPO_PARENT_PATH"
assert_eq "/data/req_executor/_scheduler" "${EXECUTOR_SCHEDULER_ROOT:-}" "EXECUTOR_SCHEDULER_ROOT"
assert_eq "3" "${EXECUTOR_MAX_CONCURRENCY:-}" "EXECUTOR_MAX_CONCURRENCY"
assert_nonempty "${GITLAB_TOKEN:-}" "GITLAB_TOKEN"
assert_eq "/data/req_dispatcher" "${STATE_ROOT:-}" "STATE_ROOT"
assert_eq "agent:req_dispatcher:main" "${DISPATCHER_CALLBACK_TARGET:-}" "DISPATCHER_CALLBACK_TARGET"

local_only_patterns=(
  "/Users/""yuanchenxiang"
  "/Users/"
  "/tmp/"
  "openclaw-local-""data"
  "flow""test"
  "test-""token"
  "local""host:8081"
)

for config_file in \
  "${REQ_EXECUTOR_DIR}/config/gitlab.env" \
  "${REQ_EXECUTOR_DIR}/config/campaign_defaults.env" \
  "${REQ_EXECUTOR_DIR}/config/campaign_defaults.local.env.example" \
  "${REQ_DISPATCHER_DIR}/config/dispatcher.env"
do
  for pattern in "${local_only_patterns[@]}"; do
    if grep -Fq "${pattern}" "${config_file}"; then
      fail "tracked deploy config still contains local-only literal: ${config_file}"
    fi
  done
done

echo "ok blue deploy config sanity"
