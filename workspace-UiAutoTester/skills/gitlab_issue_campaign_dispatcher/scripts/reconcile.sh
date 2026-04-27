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
#   Evidence file is a JSON array of objects:
#     [
#       {"iid": 1, "state": "opened", "labels": ["todo"],   "title": "...", "is_done_on_gitlab": false, "user_reopened": true},
#       {"iid": 2, "state": "opened", "labels": ["done"],   "title": "...", "is_done_on_gitlab": true,  "user_reopened": false},
#       {"iid": 3, "state": null,     "labels": null,       "title": null,  "is_done_on_gitlab": false, "user_reopened": false, "missing": true},
#       ...
#     ]
#   Missing/404 issues are recorded with "missing": true.

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
      {
        iid: $iid,
        state: .state,
        labels: (.labels // []),
        title: .title,
        is_done_on_gitlab: ((.labels // []) | index("done") != null),
        user_reopened: (
          ((.labels // []) | index("done") == null) and
          ((.labels // []) | index("failed") == null)
        ),
        missing: false
      }')"
  else
    digest="$(jq -nc --argjson iid "${iid}" '{iid:$iid, state:null, labels:null, title:null, is_done_on_gitlab:false, user_reopened:false, missing:true}')"
  fi
  if [ "${first}" -eq 1 ]; then first=0; else printf ",\n" >> "${OUT_FILE}"; fi
  printf "  %s" "${digest}" >> "${OUT_FILE}"
done
printf "\n]\n" >> "${OUT_FILE}"

echo "${OUT_FILE}"
