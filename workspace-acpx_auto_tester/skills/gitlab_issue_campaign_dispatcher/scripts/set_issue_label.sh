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
# so manually-added labels on the issue are preserved. Adding a work label
# also removes conflicting work labels to keep the issue in a single workflow
# state. v2 exceptions:
#   - `pr` REPLACES `done` (done is removed, not kept) — they never coexist.
#   - the only allowed transient coexistence pair is `done` + `blocked-cc` or
#     `done` + `blocked-dispatcher` (a failure after `done` but before `pr`).
#
# The `model:{tier}` dimension (model:<tier> for each entry in MODEL_TIERS;
# default flash / pro / max) and the one-shot `quality:low` soft signal are NOT
# work labels: they are orthogonal and persistent, so adding a work label
# (including `doing`) never removes them. The model dimension is internally
# mutually exclusive — adding one `model:{tier}` removes the other tiers, but
# leaves every work label and `quality:low` untouched. The tier set is derived
# from MODEL_TIERS so an operator override of model_tiers stays consistent.

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

# v2 work-label mutual-exclusion group. `contiune` is tolerated as a legacy
# misspelling of `continue` so a stray legacy label is cleared on the next
# transition; the agent never creates it.
WORKFLOW_LABELS=(
  todo retry new doing done pr
  blocked-cc blocked-dispatcher timeout failed-cc failed-dispatcher
  continue contiune
)

# Model-dimension labels (orthogonal, persistent, internally mutually
# exclusive). Adding one removes the others, but NOT any work label or
# quality:low. quality:low itself is a standalone one-shot signal with no
# exclusivity. The label set is DERIVED from MODEL_TIERS (ordered,
# comma-separated, default "flash,pro,max") so an operator who overrides
# model_tiers via trigger gets the model dimension's internal mutual exclusion
# computed over the configured tiers, not a hard-coded flash/pro/max triple.
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_LABELS=()
IFS=',' read -r -a __model_tier_tokens <<< "${MODEL_TIERS}"
for __tier in ${__model_tier_tokens[@]+"${__model_tier_tokens[@]}"}; do
  __tier="${__tier#"${__tier%%[![:space:]]*}"}"   # ltrim
  __tier="${__tier%"${__tier##*[![:space:]]}"}"   # rtrim
  [ -z "${__tier}" ] && continue
  MODEL_LABELS+=("model:${__tier}")
done

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

is_model_label() {
  local label="$1"
  local candidate
  for candidate in ${MODEL_LABELS[@]+"${MODEL_LABELS[@]}"}; do
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

  # Model-dimension add: internally mutually exclusive — drop the other tiers,
  # leave every work label (and quality:low) untouched.
  if is_model_label "${label}"; then
    for candidate in ${MODEL_LABELS[@]+"${MODEL_LABELS[@]}"}; do
      if ! is_kept_label "${candidate}" "${keep[@]}"; then
        printf '%s\n' "${candidate}"
      fi
    done
    return 0
  fi

  if ! is_workflow_label "${label}"; then
    return 0
  fi

  case "${label}" in
    pr)
      # pr REPLACES done: keep only pr, so done is removed in this update.
      keep=(pr)
      ;;
    blocked-cc)
      # Allowed transient coexistence: a failure after done, before pr.
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
