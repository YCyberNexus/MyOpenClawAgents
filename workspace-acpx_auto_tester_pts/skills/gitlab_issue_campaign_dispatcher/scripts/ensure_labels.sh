#!/usr/bin/env bash
# ensure_labels.sh — make sure the workflow labels exist in the project.
# Only creates labels that are missing; never modifies existing ones.
#
# Required env vars:
#   GITLAB_HOST    from glab_auth.sh
#   PROJECT_URI    URI-encoded "${GROUP}/${PROJECT}"
#
# Workflow labels: todo retry new doing pr done blocked failed continue
#
# `continue` is a human-applied review label. Reviewers set it on an issue
# whose MR was created and labeled `done` + `pr` by the agent, but where the
# Claude Code run actually didn't finish (env error, partial edits, etc.).
# When the dispatcher's reconciliation sees `continue` on an issue, it
# re-enqueues the IID and the executor restarts the resolution flow on
# the existing work branch (or creates one from master if none exists).

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_URI:?}"

REQUIRED_LABELS=(todo retry new doing pr done blocked failed continue)

existing="$(
  glab api --paginate \
    "projects/${PROJECT_URI}/labels?per_page=100" \
    | jq -r '.[].name'
)"

for label in "${REQUIRED_LABELS[@]}"; do
  if ! printf '%s\n' "${existing}" | grep -qx "${label}"; then
    glab api --method POST \
      "projects/${PROJECT_URI}/labels" \
      -f "name=${label}" -f "color=#808080" >/dev/null
    echo "created:${label}"
  fi
done
