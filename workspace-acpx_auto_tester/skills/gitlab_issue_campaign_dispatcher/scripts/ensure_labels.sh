#!/usr/bin/env bash
# ensure_labels.sh — make sure the workflow labels exist in the project.
# Only creates labels that are missing; never modifies existing ones.
#
# Required env vars:
#   GITLAB_HOST    from glab_auth.sh
#   PROJECT_URI    URI-encoded "${GROUP}/${PROJECT}"
#
# Workflow labels (v2): todo retry new doing done pr blocked-cc
#   blocked-dispatcher timeout failed-cc failed-dispatcher continue
# Orthogonal persistent model dimension: model:<tier> for each tier in the
#   configured MODEL_TIERS list (default flash,pro,max → model:flash
#   model:pro model:max).
# One-shot soft signal:                  quality:low
#
# v2 split the single `blocked` / `failed` labels into per-side variants
# (`-cc` = the Claude Code attempt itself failed; `-dispatcher` = the
# dispatcher-side prep / spawn / eviction failed before or around the
# attempt). `pr` now REPLACES `done` after MR creation rather than stacking
# on top of it, and the model tier follows the issue for its whole life.
# ensure_labels.sh only CREATES missing labels and never removes existing
# ones, so historical `blocked` / `failed` labels left over from v1 are not
# cleaned up here — that is acceptable; no historical migration is needed.
#
# `continue` is a human-applied review label. Reviewers set it on an issue
# whose MR was created and labeled `pr` by the agent, but where the
# Claude Code run actually didn't finish (env error, partial edits, etc.).
# When the dispatcher's reconciliation sees `continue` on an issue, it
# re-enqueues the IID and the executor restarts the resolution flow on
# the existing work branch (or creates one from master if none exists).
#
# `timeout` is a subagent-applied terminal label set when `acpx claude exec`
# exceeded its wall-clock cap. Whatever Claude Code managed to produce is
# still committed and force-pushed to `${WORK_BRANCH}`, but no MR / `pr`
# is opened. Treated by the dispatcher as terminal (NOT auto-retried) until
# a human strips the label. `timeout` never consumes retry budget and is
# never promoted to a `failed-*` variant.
#
# `model:{tier}` is a persistent orthogonal dimension (one of model:flash /
# model:pro / model:max — flash is TIER_0 / lowest / default). It is NOT a
# workflow label: it survives the transition into `doing` and follows the
# issue monotonically (never downgraded) until the issue is CLOSED. The tier
# list here is a 3-tier example; the trigger may configure an ordered model
# list of any length.
#
# `quality:low` is a one-shot human-applied soft signal added in
# AWAITING_REVIEW to mark a mediocre round. It triggers a single model
# upgrade and is then removed (consumed) by the dispatcher.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_URI:?}"

# Workflow labels (mutually-exclusive group) get the neutral gray; the
# persistent model tiers and the one-shot quality signal get distinct
# colors so they stand out from the workflow state in the GitLab UI.
WORKFLOW_LABELS=(todo retry new doing done pr blocked-cc blocked-dispatcher timeout failed-cc failed-dispatcher continue)
# The model tier set is configuration-driven: MODEL_TIERS is an ordered,
# comma-separated list (the dispatcher passes the trigger-configured
# model_tiers through verbatim). It defaults to "flash,pro,max" so the
# created label set is unchanged for the default deployment.
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_LABELS=()
while IFS= read -r __tier; do
  [ -n "${__tier}" ] && MODEL_LABELS+=("model:${__tier}")
done < <(printf '%s' "${MODEL_TIERS}" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
QUALITY_LABELS=(quality:low)

existing="$(
  glab api --paginate \
    "projects/${PROJECT_URI}/labels?per_page=100" \
    | jq -r '.[].name'
)"

# label_color <label> — pick a color for a label that needs creating.
label_color() {
  case "$1" in
    model:*)   printf '%s' "#1f78d1" ;;  # blue — persistent model tier
    quality:*) printf '%s' "#ed9121" ;;  # amber — one-shot soft signal
    *)         printf '%s' "#808080" ;;  # gray  — workflow state
  esac
}

for label in "${WORKFLOW_LABELS[@]}" "${MODEL_LABELS[@]}" "${QUALITY_LABELS[@]}"; do
  if ! printf '%s\n' "${existing}" | grep -qx "${label}"; then
    glab api --method POST \
      "projects/${PROJECT_URI}/labels" \
      -f "name=${label}" -f "color=$(label_color "${label}")" >/dev/null
    echo "created:${label}"
  fi
done
