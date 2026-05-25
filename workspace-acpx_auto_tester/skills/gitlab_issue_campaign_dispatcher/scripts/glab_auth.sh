#!/usr/bin/env bash
# glab_auth.sh — load the pinned GitLab host from workspace config, verify
# the trigger's gitlab_address matches, then refresh glab's stored token.
#
# Required env vars (from trigger):
#   GITLAB_TOKEN     personal/group access token (may rotate per tick)
#
# Optional env vars (from trigger):
#   GITLAB_ADDRESS   verification value, e.g. http://gitlab-b.pxsemic.tech:30000.
#                    If set, MUST resolve to the same host+protocol as the
#                    deployment pin or the script aborts. If unset, the pin
#                    is used as-is with no cross-check.
#
# Required deployment file:
#   <workspace>/config/gitlab.env  (must define GITLAB_HOST and GITLAB_API_PROTOCOL)
#
# On success:
#   - prints the pinned GITLAB_HOST to stdout
#
# On failure: exits non-zero. The dispatcher MUST mark the affected work
# blocked / abort the tick — it MUST NOT fall back to curl or to re-deriving
# the host from GITLAB_ADDRESS.
#
# Recommended caller pattern:
#   source scripts/env_paths.sh
#
# env_paths.sh calls this script, exports GITLAB_HOST / GITLAB_API_PROTOCOL,
# and computes PROJECT_FULL / PROJECT_URI for the current shell. Do not call
# this script separately and then hand-export derived project vars.
#
# IMPORTANT:
#   After this script runs, all subsequent `glab api` calls MUST rely on
#   the GITLAB_HOST env var (which glab natively respects) and MUST NOT
#   pass --hostname themselves. Passing --hostname with a "host:port"
#   value confuses glab's URL resolution for some subcommands and caused
#   the agent to spin trying alternative invocations (env var, -R flag,
#   different config keys, etc.). The single allowed convention is:
#   set GITLAB_HOST once via env_paths.sh, then drop --hostname everywhere.

set -euo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN must be set (trigger input)}"

# Resolve workspace root from this script's location:
#   <workspace>/skills/<name>/scripts/glab_auth.sh -> ../../..
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PIN_FILE="${WORKSPACE_ROOT}/config/gitlab.env"

if [ ! -f "${PIN_FILE}" ]; then
  echo "glab_auth: missing pin file ${PIN_FILE}; deployment incomplete" >&2
  exit 10
fi

# shellcheck disable=SC1090
source "${PIN_FILE}"

if [ -z "${GITLAB_HOST:-}" ] || [ -z "${GITLAB_API_PROTOCOL:-}" ]; then
  echo "glab_auth: ${PIN_FILE} must define GITLAB_HOST and GITLAB_API_PROTOCOL" >&2
  exit 11
fi

case "${GITLAB_API_PROTOCOL}" in
  http|https) ;;
  *)
    echo "glab_auth: GITLAB_API_PROTOCOL must be http or https, got '${GITLAB_API_PROTOCOL}'" >&2
    exit 12
    ;;
esac

# If the trigger supplied GITLAB_ADDRESS, verify it resolves to the same
# host+protocol as the pin. If not supplied, the pin is the sole source.
if [ -n "${GITLAB_ADDRESS:-}" ]; then
  TRIGGER_HOST="$(echo "${GITLAB_ADDRESS}" | sed -E 's#^https?://##; s#/$##')"
  TRIGGER_PROTO=http
  if echo "${GITLAB_ADDRESS}" | grep -qE '^https://'; then
    TRIGGER_PROTO=https
  fi

  if [ "${TRIGGER_HOST}" != "${GITLAB_HOST}" ] || [ "${TRIGGER_PROTO}" != "${GITLAB_API_PROTOCOL}" ]; then
    echo "glab_auth: trigger gitlab_address (${TRIGGER_PROTO}://${TRIGGER_HOST}) does not match deployment pin (${GITLAB_API_PROTOCOL}://${GITLAB_HOST})" >&2
    echo "Refusing to switch hosts. Fix the trigger or update ${PIN_FILE}." >&2
    exit 13
  fi
fi

# Refresh glab's stored token against the pinned host.
LOCK_ROOT="/tmp/acpx_auto_tester_temporal_locks"
mkdir -p "${LOCK_ROOT}"
LOCK_HOST="$(printf '%s' "${GITLAB_HOST}" | tr -c 'A-Za-z0-9_.-' '_')"
exec 8>"${LOCK_ROOT}/glab-auth-${LOCK_HOST}.lock"
flock 8

glab auth login \
  --hostname "${GITLAB_HOST}" \
  --token "${GITLAB_TOKEN}" \
  --api-protocol "${GITLAB_API_PROTOCOL}" >/dev/null

glab auth status --hostname "${GITLAB_HOST}" >/dev/null

export GITLAB_HOST GITLAB_API_PROTOCOL
echo "${GITLAB_HOST}"
