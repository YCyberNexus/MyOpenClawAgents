#!/usr/bin/env bash
# glab_auth.sh — bootstrap glab CLI authentication from trigger inputs.
#
# Required env vars:
#   GITLAB_ADDRESS   e.g. http://gitlab-b.pxsemic.tech:30000
#   GITLAB_TOKEN     personal/group access token
#
# On success, prints the resolved GITLAB_HOST to stdout. The agent should
# also derive PROJECT_FULL and PROJECT_URI for use by the rest of the scripts:
#
#   GITLAB_HOST=$(bash scripts/glab_auth.sh)
#   PROJECT_FULL="${GROUP}/${PROJECT}"
#   PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"
#   export GITLAB_HOST PROJECT_FULL PROJECT_URI
#
# On failure, exits non-zero. The executor MUST mark the issue `blocked`
# with block_reason="glab auth failed" instead of falling back to curl.

set -euo pipefail

: "${GITLAB_ADDRESS:?GITLAB_ADDRESS must be set}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN must be set}"

GITLAB_HOST="$(echo "${GITLAB_ADDRESS}" | sed -E 's#^https?://##; s#/$##')"

if echo "${GITLAB_ADDRESS}" | grep -qE '^https://'; then
  PROTO=https
else
  PROTO=http
fi

glab auth login \
  --hostname "${GITLAB_HOST}" \
  --token "${GITLAB_TOKEN}" \
  --api-protocol "${PROTO}" >/dev/null

glab auth status --hostname "${GITLAB_HOST}" >/dev/null

echo "${GITLAB_HOST}"
