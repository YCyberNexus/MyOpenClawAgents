#!/usr/bin/env bash
# set_issue_label.sh — add or remove a single label on the current issue
# without disturbing unrelated labels.
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
# so manually-added labels on the issue are preserved.

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

case "${OP}" in
  add)    FIELD="add_labels" ;;
  remove) FIELD="remove_labels" ;;
  *)
    echo "bad op: ${OP} (expected add or remove)" >&2
    exit 2
    ;;
esac

glab api --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "${FIELD}=${LABEL}" >/dev/null

echo "${OP}:${LABEL}"
