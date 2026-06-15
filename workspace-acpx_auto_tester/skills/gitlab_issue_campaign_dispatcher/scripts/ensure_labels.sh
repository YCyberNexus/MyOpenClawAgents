#!/usr/bin/env bash
# ensure_labels.sh — make sure the workflow labels exist in the project.
# Only creates labels that are missing; never modifies existing ones.
#
# Required env vars:
#   GITLAB_HOST    from glab_auth.sh
#   PROJECT_URI    URI-encoded "${GROUP}/${PROJECT}"
#
# Workflow labels (benchmark-test): todo retry new doing done blocked-cc
#   blocked-dispatcher timeout failed-cc failed-dispatcher
# Orthogonal persistent model dimension: model:<tier> for each tier in the
#   configured MODEL_TIERS list (default flash,pro,max → model:flash
#   model:pro model:max).
#
# Per-side blocked / failed variants (`-cc` = the Claude Code attempt itself
# failed; `-dispatcher` = the dispatcher-side prep / spawn / eviction failed).
# On benchmark-test `done` is the terminal success label (no MR / `pr`).
# ensure_labels.sh only CREATES missing labels and never removes existing ones,
# so historical labels left over from earlier deployments are not cleaned up
# here — that is acceptable; no historical migration is needed.
#
# `timeout` is a subagent-applied terminal label set when `acpx claude exec`
# exceeded its wall-clock cap. Whatever Claude Code produced is still committed
# and pushed to `${LOCAL_ATTEMPT_BRANCH}`, but no MR is opened. Treated as terminal
# (NOT auto-retried) until a human strips the label; never consumes retry budget
# and never promoted to a `failed-*` variant.
#
# `model:{tier}` is a persistent orthogonal dimension (e.g. model:flash /
# model:pro / model:max). It is NOT a workflow label: it survives the transition
# into `doing`. On benchmark-test the tier is pinned per tick (not escalated),
# so it is not monotonic. The trigger may configure an ordered model list of any
# length.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_URI:?}"

# Workflow labels (mutually-exclusive group) get the neutral gray; the
# persistent model tiers get a distinct color so they stand out from the
# workflow state in the GitLab UI.
WORKFLOW_LABELS=(todo retry new doing done blocked-cc blocked-dispatcher timeout failed-cc failed-dispatcher)
# The model tier set is configuration-driven: MODEL_TIERS is an ordered,
# comma-separated list (the dispatcher passes the trigger-configured
# model_tiers through verbatim). It defaults to "flash,pro,max" so the
# created label set is unchanged for the default deployment.
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_LABELS=()
while IFS= read -r __tier; do
  [ -n "${__tier}" ] && MODEL_LABELS+=("model:${__tier}")
done < <(printf '%s' "${MODEL_TIERS}" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
# Dispatcher-side tick-level marker (NOT a mutually-exclusive workflow state):
# precheck-failed is applied to a tick's batch IIDs when environment precheck
# fails (dispatch_prepare_tick.sh §16b), and cleared when the issue next enters
# `doing`. See references/precheck_manifest.md / references/label_lifecycle.md.
DISPATCHER_LABELS=(precheck-failed)

existing="$(
  glab api --paginate \
    "projects/${PROJECT_URI}/labels?per_page=100" \
    | jq -r '.[].name'
)"

# label_color <label> — pick a color for a label that needs creating.
label_color() {
  case "$1" in
    model:*)         printf '%s' "#1f78d1" ;;  # blue  — persistent model tier
    precheck-failed) printf '%s' "#d9534f" ;;  # red   — dispatcher precheck gate
    *)               printf '%s' "#808080" ;;  # gray  — workflow state
  esac
}

for label in "${WORKFLOW_LABELS[@]}" "${MODEL_LABELS[@]}" "${DISPATCHER_LABELS[@]}"; do
  if ! printf '%s\n' "${existing}" | grep -qx "${label}"; then
    glab api --method POST \
      "projects/${PROJECT_URI}/labels" \
      -f "name=${label}" -f "color=$(label_color "${label}")" >/dev/null
    echo "created:${label}"
  fi
done
