#!/usr/bin/env bash
# set_issue_label.sh — add or remove a label on the current issue
# without disturbing unrelated non-workflow labels.
#
# Usage:
#   bash scripts/set_issue_label.sh add doing
#   bash scripts/set_issue_label.sh remove todo
#
# Required env vars:
#   GITLAB_HOST    from glab_auth.sh
#   PROJECT_URI    URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID      from env_paths.sh
#
# Use this script (not a full labels overwrite) for every label transition,
# so manually-added labels on the issue are preserved. Adding a workflow label
# also removes conflicting workflow labels to keep the issue in a single
# workflow state. Allowed transient pairs: done+blocked-cc and done+blocked-dispatcher
# (failure after `done`, before a stable completion label). `pr` replaces `done`
# after ordinary MR creation; `finish` replaces `done`/`pr` only after the exact
# explicitly requested automatic merge is independently verified. `pr` and
# `finish` are mutually exclusive stable completion labels.
# model:<tier> and quality:low are orthogonal (not in WORKFLOW_LABELS) — adding/removing
# them never disturbs work labels, and adding a work label never disturbs them.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_URI:?}" "${ISSUE_IID:?}"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 add|remove <label>" >&2
  exit 2
fi

OP="$1"
LABEL="$2"

# Legacy single `blocked`/`failed` are kept in this list ONLY so that adding a
# new workflow state still clears any stray residue of them; the agent never
# WRITES single blocked/failed anymore (it uses *-cc / *-dispatcher).
WORKFLOW_LABELS=(todo retry new doing pr finish done blocked-cc blocked-dispatcher failed-cc failed-dispatcher blocked failed timeout continue contiune)

is_workflow_label() {
  local label="$1"
  local candidate
  for candidate in "${WORKFLOW_LABELS[@]}"; do
    if [ "${label}" = "${candidate}" ]; then
      return 0
    fi
  done
  return 1
}

is_kept_label() {
  local candidate="$1"
  shift
  local kept
  for kept in "$@"; do
    if [ "${candidate}" = "${kept}" ]; then
      return 0
    fi
  done
  return 1
}

workflow_conflicts_for_add() {
  local label="$1"
  local keep=("${label}")
  local candidate

  if ! is_workflow_label "${label}"; then
    return 0
  fi

  case "${label}" in
    pr|finish)
      keep=("${label}")
      ;;
    blocked-cc)
      keep=(done blocked-cc)
      ;;
    blocked-dispatcher)
      keep=(done blocked-dispatcher)
      ;;
  esac

  for candidate in "${WORKFLOW_LABELS[@]}"; do
    if ! is_kept_label "${candidate}" "${keep[@]}"; then
      printf '%s\n' "${candidate}"
    fi
  done
}

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

case "${OP}" in
  add)    FIELD="add_labels" ;;
  remove) FIELD="remove_labels" ;;
  *)
    echo "bad op: ${OP} (expected add or remove)" >&2
    exit 2
    ;;
esac

CONFLICT_LABELS=""
if [ "${OP}" = "add" ]; then
  # Re-read stable terminal evidence at the mutation boundary so a reconcile
  # failure or a pr/finish/closed race cannot let a late ordinary transition
  # downgrade the Issue. An explicit rerun removes pr/finish before adding
  # doing; newly arriving terminal evidence still wins fail-closed.
  if [ "${LABEL}" != finish ] && is_workflow_label "${LABEL}"; then
    CURRENT_LABELS_JSON="$(glab api \
      "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"
    if ! jq -e '
        type == "object"
        and (.labels | type == "array")
        and all(.labels[]; type == "string")
        and ((.state // "opened") | type == "string")
      ' <<<"${CURRENT_LABELS_JSON}" >/dev/null; then
      echo "set_issue_label: current Issue labels response is invalid" >&2
      exit 3
    fi
    if jq -e '.state == "closed"' <<<"${CURRENT_LABELS_JSON}" >/dev/null; then
      echo "preserve:closed"
      exit 0
    fi
    if jq -e '(.labels | index("finish")) != null' \
        <<<"${CURRENT_LABELS_JSON}" >/dev/null; then
      echo "preserve:finish"
      exit 0
    fi
    if [ "${LABEL}" != pr ] \
        && jq -e '(.labels | index("pr")) != null' \
        <<<"${CURRENT_LABELS_JSON}" >/dev/null; then
      echo "preserve:pr"
      exit 0
    fi
  fi

  CONFLICTS=()
  while IFS= read -r conflict_label; do
    CONFLICTS+=("${conflict_label}")
  done < <(workflow_conflicts_for_add "${LABEL}")
  if [ "${#CONFLICTS[@]}" -gt 0 ]; then
    CONFLICT_LABELS="$(join_by_comma "${CONFLICTS[@]}")"
    UPDATED_ISSUE_JSON="$(glab api --method PUT \
      "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
      -f "remove_labels=${CONFLICT_LABELS}" \
      -f "${FIELD}=${LABEL}")"
  else
    UPDATED_ISSUE_JSON="$(glab api --method PUT \
      "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
      -f "${FIELD}=${LABEL}")"
  fi
else
  UPDATED_ISSUE_JSON="$(glab api --method PUT \
    "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
    -f "${FIELD}=${LABEL}")"
fi

if ! jq -e '
    type == "object"
    and (.labels | type == "array")
    and all(.labels[]; type == "string")
    and ((.state // "opened") | type == "string")
  ' <<<"${UPDATED_ISSUE_JSON}" >/dev/null; then
  echo "set_issue_label: updated Issue response is invalid" >&2
  exit 3
fi

if [ "${OP}" = add ]; then
  # A stable completion/closure may win the race between the pre-read and the
  # update. Report preservation instead of claiming the requested label was
  # applied. The outer result then cannot falsely advertise a transition.
  if [ "${LABEL}" != finish ] \
      && jq -e --arg wanted_label "${LABEL}" '
        .state == "closed" and (.labels | index($wanted_label)) == null
      ' <<<"${UPDATED_ISSUE_JSON}" >/dev/null; then
    echo "preserve:closed"
    exit 0
  fi
  if [ "${LABEL}" != finish ] \
      && jq -e --arg wanted_label "${LABEL}" '
        (.labels | index($wanted_label)) == null
        and (.labels | index("finish")) != null
      ' \
        <<<"${UPDATED_ISSUE_JSON}" >/dev/null; then
    echo "preserve:finish"
    exit 0
  fi
  if [ "${LABEL}" != pr ] && [ "${LABEL}" != finish ] \
      && jq -e --arg wanted_label "${LABEL}" '
        (.labels | index($wanted_label)) == null
        and (.labels | index("pr")) != null
      ' \
        <<<"${UPDATED_ISSUE_JSON}" >/dev/null; then
    echo "preserve:pr"
    exit 0
  fi
  if ! jq -e --arg wanted_label "${LABEL}" --arg conflicts "${CONFLICT_LABELS}" '
      . as $issue
      | ($issue.labels | index($wanted_label)) != null
      and ($conflicts == ""
        or all($conflicts | split(",")[];
          . as $conflict | ($issue.labels | index($conflict)) == null))
    ' <<<"${UPDATED_ISSUE_JSON}" >/dev/null; then
    echo "set_issue_label: GitLab did not apply add ${LABEL} atomically" >&2
    exit 4
  fi
  [ -z "${CONFLICT_LABELS}" ] \
    || echo "remove_conflicts:${CONFLICT_LABELS}"
else
  if ! jq -e --arg wanted_label "${LABEL}" '
      (.labels | index($wanted_label)) == null
    ' <<<"${UPDATED_ISSUE_JSON}" >/dev/null; then
    echo "set_issue_label: GitLab did not apply remove ${LABEL}" >&2
    exit 4
  fi
fi

echo "${OP}:${LABEL}"
