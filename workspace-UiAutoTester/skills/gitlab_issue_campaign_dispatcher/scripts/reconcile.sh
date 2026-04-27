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
#       "is_done_on_gitlab": bool,   # labels include literal "done"
#       "user_reopened":     bool,   # neither "done" nor "failed" in labels
#       "needs_continue":    bool,   # labels include literal "continue"
#       "missing":           bool    # GET returned non-OK (treat as not done)
#     }
#
# Semantics for the dispatcher (consumed in Source-of-Truth Policy):
#   - `is_done_on_gitlab == true` AND no `needs_continue` → finished, skip
#   - `needs_continue == true`                            → re-enqueue; the
#         executor will re-run the resolution flow against the existing
#         work branch (or build one from master if none exists)
#   - `user_reopened == true`                             → re-enqueue from
#         scratch (label was reverted to todo / doing)
#
# `needs_continue` and `user_reopened` are not mutually exclusive. If both
# are true, treat the IID as continue mode (existing branch reuse) — the
# human reviewer asked for a re-run, not a wipe.

set -euo pipefail

: "${GITLAB_HOST:?}" "${PROJECT_FULL:?}" "${MIN_IID:?}" "${MAX_IID:?}" "${DISPATCHER_LOG_DIR:?}"

mkdir -p "${DISPATCHER_LOG_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${DISPATCHER_LOG_DIR}/reconcile-${TS}.json"
PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"

echo "[" > "${OUT_FILE}"
first=1
for iid in $(seq "${MIN_IID}" "${MAX_IID}"); do
  if body="$(glab api --hostname "${GITLAB_HOST}" "projects/${PROJECT_URI}/issues/${iid}" 2>/dev/null)"; then
    digest="$(echo "${body}" | jq -c --argjson iid "${iid}" '
      . as $issue |
      ($issue.labels // []) as $labels |
      {
        iid: $iid,
        state: $issue.state,
        labels: $labels,
        title: $issue.title,
        is_done_on_gitlab: ($labels | index("done") != null),
        user_reopened: (
          ($labels | index("done") == null) and
          ($labels | index("failed") == null) and
          ($labels | index("continue") == null)
        ),
        needs_continue: ($labels | index("continue") != null),
        missing: false
      }')"
  else
    digest="$(jq -nc --argjson iid "${iid}" '{iid:$iid, state:null, labels:null, title:null, is_done_on_gitlab:false, user_reopened:false, needs_continue:false, missing:true}')"
  fi
  if [ "${first}" -eq 1 ]; then first=0; else printf ",\n" >> "${OUT_FILE}"; fi
  printf "  %s" "${digest}" >> "${OUT_FILE}"
done
printf "\n]\n" >> "${OUT_FILE}"

echo "${OUT_FILE}"
