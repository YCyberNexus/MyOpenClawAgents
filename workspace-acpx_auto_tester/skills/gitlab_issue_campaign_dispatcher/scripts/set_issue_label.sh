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
# workflow state, except for the allowed transient pairs (see below).
#
# v2 label model:
#   - Workflow labels are a mutually-exclusive group (todo / new / retry /
#     continue / doing / done / pr / blocked-cc / blocked-dispatcher /
#     timeout / failed-cc / failed-dispatcher). Adding any one removes the
#     others. `pr` REPLACES `done` (its keep-set is just `pr`); the only
#     allowed transient pair is `done` + `blocked-cc` or `done` +
#     `blocked-dispatcher` (a failure after `done` but before the MR / `pr`).
#   - `model:{tier}` is a separate persistent dimension that is internally
#     mutually exclusive: adding `model:pro` removes `model:flash` /
#     `model:max` but does NOT touch any workflow label or `quality:low`.
#     This is what keeps the model tier alive across the transition into
#     `doing`.
#   - `quality:low` is a one-shot soft signal: adding or removing it touches
#     nothing else.
#   - `precheck-failed` is a dispatcher-side, tick-level marker (NOT a workflow
#     state). It is an unknown non-workflow / non-model label here, so adding it
#     produces no conflicts and it coexists with any workflow label. The
#     dispatcher applies it to a tick's batch IIDs when environment precheck
#     fails (dispatch_prepare_tick.sh §16b) and removes it explicitly when the
#     issue next enters `doing` (it is in that script's into-`doing`
#     REMOVE_LBLS set). It does not consume retry and does not upgrade the model
#     tier. See references/precheck_manifest.md / references/label_lifecycle.md.

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

# Workflow mutual-exclusion group (v2). `contiune` is the legacy misspelling
# of `continue`, tolerated on removal so stale issues get cleaned up.
WORKFLOW_LABELS=(todo retry new doing done pr blocked-cc blocked-dispatcher timeout failed-cc failed-dispatcher continue contiune)
# Model tier dimension — internally mutually exclusive, orthogonal to the
# workflow group (NOT cleared when a workflow label is added). The tier set
# is configuration-driven: MODEL_TIERS is an ordered, comma-separated list
# (the dispatcher passes the trigger-configured model_tiers through). It
# defaults to "flash,pro,max" so the model mutual-exclusion is unchanged for
# the default deployment.
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_LABELS=()
while IFS= read -r __tier; do
  [ -n "${__tier}" ] && MODEL_LABELS+=("model:${__tier}")
done < <(printf '%s' "${MODEL_TIERS}" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

is_in_set() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [ "${needle}" = "${candidate}" ]; then
      return 0
    fi
  done
  return 1
}

is_workflow_label() { is_in_set "$1" "${WORKFLOW_LABELS[@]}"; }
is_model_label()    { is_in_set "$1" "${MODEL_LABELS[@]}"; }

is_kept_label() {
  local candidate="$1"
  shift
  is_in_set "${candidate}" "$@"
}

# conflicts_for_add <label> — print, one per line, the labels that must be
# removed in the SAME GitLab update when <label> is added. Returns nothing
# (no conflicts) for `quality:low` and any unknown non-workflow / non-model
# label, so those are added without disturbing other labels.
conflicts_for_add() {
  local label="$1"
  local candidate

  if is_model_label "${label}"; then
    # Model dimension is internally exclusive: drop the other tiers, keep
    # every workflow label and quality:low untouched.
    for candidate in "${MODEL_LABELS[@]}"; do
      if [ "${candidate}" != "${label}" ]; then
        printf '%s\n' "${candidate}"
      fi
    done
    return 0
  fi

  if ! is_workflow_label "${label}"; then
    # quality:low and any other non-workflow / non-model label: no conflicts.
    return 0
  fi

  local keep=("${label}")
  case "${label}" in
    pr)
      # pr REPLACES done — keep ONLY pr (done is removed in the same update).
      keep=(pr)
      ;;
    blocked-cc)
      # Allowed transient pair: a failure after `done` but before `pr`.
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
  done < <(conflicts_for_add "${LABEL}")
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
