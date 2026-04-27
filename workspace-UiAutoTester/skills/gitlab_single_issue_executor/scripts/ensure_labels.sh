#!/usr/bin/env bash
# ensure_labels.sh — make sure the six workflow labels exist in the project.
# Only creates labels that are missing; never modifies existing ones.
#
# Required env vars:
#   GITLAB_HOST    from glab_auth.sh
#   PROJECT_URI    URI-encoded "${GROUP}/${PROJECT}"
#
# Workflow labels: todo doing pr done blocked failed

set -euo pipefail

: "${GITLAB_HOST:?}" "${PROJECT_URI:?}"

REQUIRED_LABELS=(todo doing pr done blocked failed)

existing="$(
  glab api --hostname "${GITLAB_HOST}" --paginate \
    "projects/${PROJECT_URI}/labels?per_page=100" \
    | jq -r '.[].name'
)"

for label in "${REQUIRED_LABELS[@]}"; do
  if ! printf '%s\n' "${existing}" | grep -qx "${label}"; then
    glab api --hostname "${GITLAB_HOST}" --method POST \
      "projects/${PROJECT_URI}/labels" \
      -f "name=${label}" -f "color=#808080" >/dev/null
    echo "created:${label}"
  fi
done
