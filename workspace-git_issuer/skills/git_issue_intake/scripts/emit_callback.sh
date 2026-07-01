#!/usr/bin/env bash
set -euo pipefail

json_string_or_null() {
  local value="${1:-}"
  if [ -z "${value}" ]; then
    printf 'null'
  else
    jq -Rn --arg v "${value}" '$v'
  fi
}

STATUS="${STATUS:-failed}"
ACTION="${ACTION:-none}"
ISSUE_IID="${ISSUE_IID:-}"
ISSUE_URL="${ISSUE_URL:-}"
PROJECT_FULL="${PROJECT_FULL:-}"
ENTRY_LABEL="${ENTRY_LABEL:-}"
SUPERSEDED_BY="${SUPERSEDED_BY:-}"
REASON="${REASON:-}"
CORRELATION_ID="${CORRELATION_ID:-}"

jq -cn \
  --arg status "${STATUS}" \
  --arg action "${ACTION}" \
  --arg issue_iid "${ISSUE_IID}" \
  --arg issue_url "${ISSUE_URL}" \
  --arg project "${PROJECT_FULL}" \
  --arg entry_label "${ENTRY_LABEL}" \
  --arg superseded_by "${SUPERSEDED_BY}" \
  --arg reason "${REASON}" \
  --arg correlation_id "${CORRELATION_ID}" '
  {
    status: $status,
    action: $action,
    issue_iid: (if $issue_iid == "" then null else ($issue_iid | tonumber) end),
    issue_url: (if $issue_url == "" then null else $issue_url end),
    project: (if $project == "" then null else $project end),
    entry_label: (if $entry_label == "" then null else $entry_label end),
    superseded_by: (if $superseded_by == "" then null else ($superseded_by | tonumber) end),
    reason: (if $reason == "" then null else $reason end),
    correlation_id: (if $correlation_id == "" then null else $correlation_id end)
  }'
