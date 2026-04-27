#!/usr/bin/env bash
# glab_auth.sh — bootstrap glab CLI authentication from trigger inputs.
#
# Required env vars:
#   GITLAB_ADDRESS   e.g. http://gitlab-b.pxsemic.tech:30000
#   GITLAB_TOKEN     personal/group access token
#
# On success, prints the resolved GITLAB_HOST to stdout (the agent should
# capture it: GITLAB_HOST=$(bash scripts/glab_auth.sh)).
# On failure, exits non-zero. The dispatcher MUST NOT fall back to curl.

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
