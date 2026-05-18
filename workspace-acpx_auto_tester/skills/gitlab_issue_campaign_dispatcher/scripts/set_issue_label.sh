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
# workflow state, except for the allowed done+pr and done+blocked pairs.

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

WORKFLOW_LABELS=(todo retry new doing pr done blocked failed continue contiune)

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
    pr)
      keep=(done pr)
      ;;
    blocked)
      keep=(done blocked)
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

if [ "${OP}" = "add" ]; then
  CONFLICTS=()
  while IFS= read -r conflict_label; do
    CONFLICTS+=("${conflict_label}")
  done < <(workflow_conflicts_for_add "${LABEL}")
  if [ "${#CONFLICTS[@]}" -gt 0 ]; then
    CONFLICT_LABELS="$(join_by_comma "${CONFLICTS[@]}")"
    glab api --method PUT \
      "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
      -f "remove_labels=${CONFLICT_LABELS}" \
      -f "${FIELD}=${LABEL}" >/dev/null
    echo "remove_conflicts:${CONFLICT_LABELS}"
    echo "${OP}:${LABEL}"
    exit 0
  fi
fi

glab api --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "${FIELD}=${LABEL}" >/dev/null

echo "${OP}:${LABEL}"
