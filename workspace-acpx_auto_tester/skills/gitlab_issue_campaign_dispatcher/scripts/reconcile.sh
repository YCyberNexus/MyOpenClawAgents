#!/usr/bin/env bash
# reconcile.sh — query GitLab for every IID in [MIN_IID, MAX_IID] and write
# a single evidence JSON file the dispatcher can grep + jq later. This is the
# fail-closed evidence required by the Source-of-Truth Policy: if this file
# was not produced this tick, reconciliation did not happen.
#
# Required env vars:
#   GITLAB_HOST           resolved hostname (output of glab_auth.sh)
#   PROJECT_FULL          "<group>/<project>"
#   MIN_IID               inclusive
#   MAX_IID               inclusive
#   DISPATCHER_LOG_DIR    where to put reconcile-<ts>.json
#
# Output:
#   Prints the absolute path of the evidence file to stdout.
#   Evidence file is a JSON array of objects with these fields per IID:
#     {
#       "iid":               <integer>,
#       "state":             "opened" | "closed" | null,
#       "labels":            [...] | null,
#       "title":             "..."  | null,
#       "has_done_pr":       bool,   # labels include both "done" and "pr"
#       "is_closed_on_gitlab": bool,  # state is "closed"
#       "is_done_on_gitlab": bool,   # terminal for dispatcher: closed OR done+pr
#       "user_reopened":     bool,   # opened, no completed pair, and no failed/blocked/continue label
#       "needs_continue":    bool,   # opened and labels include literal "continue"
#       "missing":           bool    # GET returned non-OK (treat as not done)
#     }
#
# Semantics for the dispatcher (consumed in Source-of-Truth Policy):
#   - `is_closed_on_gitlab == true`                       → finished, skip
#   - `is_done_on_gitlab == true` AND no `needs_continue` → finished, skip
#   - `needs_continue == true`                            → re-enqueue; the
#         dispatcher will prepare a continue-mode handoff against the existing
#         work branch (or build one from master if none exists)
#   - `user_reopened == true`                             → re-enqueue from
#         scratch (label was reverted to todo / doing, or is done-only
#         before MR / pr completion)
#
# Closed issue state wins over every label combination, including `continue`.
# For opened issues, `needs_continue` wins over every other label combination.
# The jq below keeps `needs_continue` and `user_reopened` mutually exclusive.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_FULL:?}" "${MIN_IID:?}" "${MAX_IID:?}" "${DISPATCHER_LOG_DIR:?}"

mkdir -p "${DISPATCHER_LOG_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${DISPATCHER_LOG_DIR}/reconcile-${TS}.json"
PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"

echo "[" > "${OUT_FILE}"
first=1
for iid in $(seq "${MIN_IID}" "${MAX_IID}"); do
  if body="$(glab api "projects/${PROJECT_URI}/issues/${iid}" 2>/dev/null)"; then
    digest="$(echo "${body}" | jq -c --argjson iid "${iid}" '
      . as $issue |
      ($issue.labels // []) as $labels |
      (($labels | index("done") != null) and ($labels | index("pr") != null)) as $done_with_pr |
      ($issue.state == "closed") as $closed |
      {
        iid: $iid,
        state: $issue.state,
        labels: $labels,
        title: $issue.title,
        has_done_pr: $done_with_pr,
        is_closed_on_gitlab: $closed,
        is_done_on_gitlab: ($closed or $done_with_pr),
        user_reopened: (
          ($closed | not) and
          ($done_with_pr | not) and
          ($labels | index("failed") == null) and
          ($labels | index("blocked") == null) and
          ($labels | index("continue") == null)
        ),
        needs_continue: (($closed | not) and ($labels | index("continue") != null)),
        missing: false
      }')"
  else
    digest="$(jq -nc --argjson iid "${iid}" '{iid:$iid, state:null, labels:null, title:null, has_done_pr:false, is_closed_on_gitlab:false, is_done_on_gitlab:false, user_reopened:false, needs_continue:false, missing:true}')"
  fi
  if [ "${first}" -eq 1 ]; then first=0; else printf ",\n" >> "${OUT_FILE}"; fi
  printf "  %s" "${digest}" >> "${OUT_FILE}"
done
printf "\n]\n" >> "${OUT_FILE}"

echo "${OUT_FILE}"
