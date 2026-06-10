#!/usr/bin/env bash
# ensure_labels.sh — make sure the workflow labels exist in the project.
# Only creates labels that are missing; never modifies existing ones.
#
# Required env vars:
#   GITLAB_HOST    from glab_auth.sh
#   PROJECT_URI    URI-encoded "${GROUP}/${PROJECT}"
#
# Workflow labels (mutually-exclusive group — exactly one at any time):
#   todo retry new doing done pr blocked-cc blocked-dispatcher timeout
#   failed-cc failed-dispatcher continue
# Orthogonal persistent model dimension (one of, never cleared on entering doing):
#   model:<tier> for each entry in MODEL_TIERS (ordered low→high; default
#   flash → pro → max). The label set is DERIVED from MODEL_TIERS so that an
#   operator who overrides model_tiers via trigger gets the right labels created.
# One-shot soft signal:
#   quality:low (human-applied in AWAITING_REVIEW; consumed when an upgrade lands or the tier is capped)
#
# v2 note: the single `blocked` / `failed` labels were split by attribution
# into `blocked-cc` / `blocked-dispatcher` and `failed-cc` / `failed-dispatcher`
# so a reviewer can tell from the label which side to fix. `pr` REPLACES `done`
# (it is no longer additive). ensure_labels only CREATES missing labels and
# never deletes existing ones, so any historical `blocked` / `failed` labels
# left on old issues are not auto-cleaned — that is acceptable, no migration of
# historical issues is required.
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
# a human strips the label.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_URI:?}"

# Model-dimension tiers (single source of truth across ensure_labels.sh,
# set_issue_label.sh, reconcile.sh): an ordered, comma-separated list from
# lowest (TIER_0, default) to highest (cap). The dispatcher passes the
# trigger's configured model_tiers via MODEL_TIERS; when unset we fall back to
# the documented default so the subagent path and legacy callers are unchanged.
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_LABELS=()
IFS=',' read -r -a __model_tier_tokens <<< "${MODEL_TIERS}"
for __tier in ${__model_tier_tokens[@]+"${__model_tier_tokens[@]}"}; do
  __tier="${__tier#"${__tier%%[![:space:]]*}"}"   # ltrim
  __tier="${__tier%"${__tier##*[![:space:]]}"}"   # rtrim
  [ -z "${__tier}" ] && continue
  MODEL_LABELS+=("model:${__tier}")
done

# Work-label mutual-exclusion group (v2): single `blocked` / `failed` replaced
# by per-side variants. Plus the orthogonal model:{tier} dimension (derived
# from MODEL_TIERS above) and the one-shot quality:low soft signal.
REQUIRED_LABELS=(
  todo retry new doing done pr
  blocked-cc blocked-dispatcher timeout failed-cc failed-dispatcher
  continue
  ${MODEL_LABELS[@]+"${MODEL_LABELS[@]}"}
  quality:low
  # Dispatcher-side tick-level marker (§16b environment precheck): non-workflow,
  # coexists with the workflow label, cleared on the next `doing` transition.
  precheck-failed
)

existing="$(
  glab api --paginate \
    "projects/${PROJECT_URI}/labels?per_page=100" \
    | jq -r '.[].name'
)"

for label in "${REQUIRED_LABELS[@]}"; do
  if ! printf '%s\n' "${existing}" | grep -qx "${label}"; then
    # Single grey for every label except the precheck-failed marker, which is
    # red so a tick-level environment failure stands out on the issue board.
    color="#808080"
    [ "${label}" = "precheck-failed" ] && color="#d9534f"
    glab api --method POST \
      "projects/${PROJECT_URI}/labels" \
      -f "name=${label}" -f "color=${color}" >/dev/null
    echo "created:${label}"
  fi
done
