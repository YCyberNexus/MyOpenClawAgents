#!/usr/bin/env bash
# glab_auth.sh — resolve the effective GitLab target before any network call,
# verify the trigger's gitlab_address matches, then refresh glab's stored token.
#
# Required env vars (from trigger):
#   GITLAB_TOKEN     personal/group access token (may rotate per tick)
#
# Optional env vars (from trigger):
#   GITLAB_ADDRESS   verification value, e.g. http://gitlab-b.pxsemic.tech:30000.
#                    If set, MUST resolve to the same host+protocol as the
#                    effective target or the script aborts. If unset, the
#                    resolved target is used as-is with no cross-check.
#
# Target precedence:
#   1. Explicit process GITLAB_HOST + GITLAB_API_PROTOCOL.
#   2. Ignored config/campaign_defaults.local.env target, when present.
#   3. Tracked config/gitlab.env deployment target.
#
# A process target must provide its own process GITLAB_TOKEN. A local-file
# target may use a process token or a token from that same ignored file, but
# never falls through to the tracked deployment token. The tracked target
# keeps the deployment contract where a process token overrides its fallback.
#
# The local file is intentionally the same ignored override already loaded by
# scheduler_env.sh. This keeps workstation-only GitLab values out of tracked
# configuration and, critically, chooses the effective target before glab is
# invoked. An override is never applied after authenticating to the pin.
#
# Required deployment file:
#   <workspace>/config/gitlab.env  (must define GITLAB_HOST and GITLAB_API_PROTOCOL)
#
# Optional local-test guard:
#   REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true
#   REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081,127.0.0.1:8081
#
# When enabled, the tracked deployment host is always denied and the effective
# host must be an exact member of the comma-separated allowlist. The guard runs
# before lock creation and before every glab invocation in this script.
#
# On success:
#   - prints the effective GITLAB_HOST to stdout
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

GITLAB_TOKEN_ENV_OVERRIDE="${GITLAB_TOKEN:-}"
GITLAB_TOKEN_ENV_SET="${GITLAB_TOKEN+x}"
GLAB_BIN_ENV_OVERRIDE="${GLAB_BIN:-}"
GLAB_BIN_ENV_SET="${GLAB_BIN+x}"
GITLAB_HOST_ENV_OVERRIDE="${GITLAB_HOST:-}"
GITLAB_HOST_ENV_SET="${GITLAB_HOST+x}"
GITLAB_PROTOCOL_ENV_OVERRIDE="${GITLAB_API_PROTOCOL:-}"
GITLAB_PROTOCOL_ENV_SET="${GITLAB_API_PROTOCOL+x}"
LOCAL_TEST_MODE_ENV_OVERRIDE="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE:-}"
LOCAL_TEST_MODE_ENV_SET="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE+x}"
ALLOWED_HOSTS_ENV_OVERRIDE="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS:-}"
ALLOWED_HOSTS_ENV_SET="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS+x}"
GLAB_CONFIG_DIR_ENV_OVERRIDE="${GLAB_CONFIG_DIR:-}"
GLAB_CONFIG_DIR_ENV_SET="${GLAB_CONFIG_DIR+x}"

# Resolve workspace root from this script's location:
#   <workspace>/skills/<name>/scripts/glab_auth.sh -> ../../..
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-${WORKSPACE_ROOT}/config}"
PIN_FILE="${CONFIG_DIR}/gitlab.env"
LOCAL_FILE="${CONFIG_DIR}/campaign_defaults.local.env"

if [ ! -f "${PIN_FILE}" ]; then
  echo "glab_auth: missing pin file ${PIN_FILE}; deployment incomplete" >&2
  exit 10
fi

# shellcheck disable=SC1090
source "${PIN_FILE}"
TRACKED_GITLAB_HOST="${GITLAB_HOST:-}"
TRACKED_GITLAB_HOST_SET="${GITLAB_HOST+x}"
TRACKED_GITLAB_PROTOCOL="${GITLAB_API_PROTOCOL:-}"
TRACKED_GITLAB_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
TRACKED_GITLAB_TOKEN="${GITLAB_TOKEN:-}"
TRACKED_GITLAB_TOKEN_SET="${GITLAB_TOKEN+x}"

# Clear only the GitLab tuple before reading the ignored layer so an omitted
# local value cannot silently inherit a tracked value and create a mixed
# target/credential tuple.
unset GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN

if [ -f "${LOCAL_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${LOCAL_FILE}"
fi

LOCAL_GITLAB_HOST="${GITLAB_HOST:-}"
LOCAL_GITLAB_HOST_SET="${GITLAB_HOST+x}"
LOCAL_GITLAB_PROTOCOL="${GITLAB_API_PROTOCOL:-}"
LOCAL_GITLAB_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
LOCAL_GITLAB_TOKEN="${GITLAB_TOKEN:-}"
LOCAL_GITLAB_TOKEN_SET="${GITLAB_TOKEN+x}"

if [ "${GLAB_BIN_ENV_SET}" = x ]; then
  GLAB_BIN="${GLAB_BIN_ENV_OVERRIDE}"
fi
if [ "${LOCAL_TEST_MODE_ENV_SET}" = x ]; then
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE="${LOCAL_TEST_MODE_ENV_OVERRIDE}"
fi
if [ "${ALLOWED_HOSTS_ENV_SET}" = x ]; then
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="${ALLOWED_HOSTS_ENV_OVERRIDE}"
fi
if [ "${GLAB_CONFIG_DIR_ENV_SET}" = x ]; then
  GLAB_CONFIG_DIR="${GLAB_CONFIG_DIR_ENV_OVERRIDE}"
fi
GLAB_BIN="${GLAB_BIN:-glab}"

if [ -n "${GLAB_CONFIG_DIR:-}" ]; then
  case "${GLAB_CONFIG_DIR}" in
    /*) ;;
    *) echo "glab_auth: GLAB_CONFIG_DIR must be absolute" >&2; exit 11 ;;
  esac
  case "${GLAB_CONFIG_DIR}" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "glab_auth: GLAB_CONFIG_DIR contains control characters" >&2
      exit 11
      ;;
  esac
  export GLAB_CONFIG_DIR
fi

PROCESS_TARGET_SET=false
if [ "${GITLAB_HOST_ENV_SET}" = x ] \
    || [ "${GITLAB_PROTOCOL_ENV_SET}" = x ]; then
  PROCESS_TARGET_SET=true
fi
LOCAL_TARGET_SET=false
if [ "${LOCAL_GITLAB_HOST_SET}" = x ] \
    || [ "${LOCAL_GITLAB_PROTOCOL_SET}" = x ]; then
  LOCAL_TARGET_SET=true
fi

if [ "${PROCESS_TARGET_SET}" = true ]; then
  if [ "${GITLAB_HOST_ENV_SET}" != x ] \
      || [ "${GITLAB_PROTOCOL_ENV_SET}" != x ]; then
    echo "glab_auth: process GITLAB_HOST and GITLAB_API_PROTOCOL must be provided together" >&2
    exit 11
  fi
  if [ "${GITLAB_TOKEN_ENV_SET}" != x ]; then
    echo "glab_auth: a process GitLab target requires process GITLAB_TOKEN" >&2
    exit 11
  fi
  GITLAB_HOST="${GITLAB_HOST_ENV_OVERRIDE}"
  GITLAB_API_PROTOCOL="${GITLAB_PROTOCOL_ENV_OVERRIDE}"
  GITLAB_TOKEN="${GITLAB_TOKEN_ENV_OVERRIDE}"
  GITLAB_TARGET_SOURCE=process
  GITLAB_TOKEN_SOURCE=process
elif [ "${LOCAL_TARGET_SET}" = true ]; then
  if [ "${LOCAL_GITLAB_HOST_SET}" != x ] \
      || [ "${LOCAL_GITLAB_PROTOCOL_SET}" != x ]; then
    echo "glab_auth: local GitLab host and protocol must be provided together" >&2
    exit 11
  fi
  GITLAB_HOST="${LOCAL_GITLAB_HOST}"
  GITLAB_API_PROTOCOL="${LOCAL_GITLAB_PROTOCOL}"
  GITLAB_TARGET_SOURCE=local
  if [ "${GITLAB_TOKEN_ENV_SET}" = x ]; then
    GITLAB_TOKEN="${GITLAB_TOKEN_ENV_OVERRIDE}"
    GITLAB_TOKEN_SOURCE=process
  elif [ "${LOCAL_GITLAB_TOKEN_SET}" = x ]; then
    GITLAB_TOKEN="${LOCAL_GITLAB_TOKEN}"
    GITLAB_TOKEN_SOURCE=local
  else
    echo "glab_auth: a local GitLab target requires a process or local-file GITLAB_TOKEN" >&2
    exit 11
  fi
elif [ "${LOCAL_GITLAB_TOKEN_SET}" = x ]; then
  echo "glab_auth: local GITLAB_TOKEN requires a local host and protocol" >&2
  exit 11
else
  if [ "${TRACKED_GITLAB_HOST_SET}" != x ] \
      || [ "${TRACKED_GITLAB_PROTOCOL_SET}" != x ]; then
    echo "glab_auth: ${PIN_FILE} must define GITLAB_HOST and GITLAB_API_PROTOCOL" >&2
    exit 11
  fi
  GITLAB_HOST="${TRACKED_GITLAB_HOST}"
  GITLAB_API_PROTOCOL="${TRACKED_GITLAB_PROTOCOL}"
  GITLAB_TARGET_SOURCE=tracked
  if [ "${GITLAB_TOKEN_ENV_SET}" = x ]; then
    GITLAB_TOKEN="${GITLAB_TOKEN_ENV_OVERRIDE}"
    GITLAB_TOKEN_SOURCE=process
  elif [ "${TRACKED_GITLAB_TOKEN_SET}" = x ]; then
    GITLAB_TOKEN="${TRACKED_GITLAB_TOKEN}"
    GITLAB_TOKEN_SOURCE=tracked
  else
    GITLAB_TOKEN=""
    GITLAB_TOKEN_SOURCE=tracked
  fi
fi

: "${GITLAB_TOKEN:?GITLAB_TOKEN must be set for the resolved GitLab target}"

if [ -z "${GITLAB_HOST:-}" ] || [ -z "${GITLAB_API_PROTOCOL:-}" ]; then
  echo "glab_auth: effective GITLAB_HOST and GITLAB_API_PROTOCOL must be non-empty" >&2
  exit 11
fi

if ! [[ "${GITLAB_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]]; then
  echo "glab_auth: GITLAB_HOST must be an exact host[:port] value without a URL scheme or path" >&2
  exit 11
fi
if [[ "${GITLAB_HOST}" == *:* ]]; then
  GITLAB_PORT="${GITLAB_HOST##*:}"
  if [ "${GITLAB_PORT}" -lt 1 ] || [ "${GITLAB_PORT}" -gt 65535 ]; then
    echo "glab_auth: GITLAB_HOST port must be between 1 and 65535" >&2
    exit 11
  fi
fi

case "${GITLAB_API_PROTOCOL}" in
  http|https) ;;
  *)
    echo "glab_auth: GITLAB_API_PROTOCOL must be http or https, got '${GITLAB_API_PROTOCOL}'" >&2
    exit 12
    ;;
esac

LOCAL_TEST_MODE="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE:-false}"
case "${LOCAL_TEST_MODE}" in
  true|1) LOCAL_TEST_MODE=true ;;
  false|0|'') LOCAL_TEST_MODE=false ;;
  *)
    echo "glab_auth: REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE must be true or false" >&2
    exit 14
    ;;
esac

if [ "${LOCAL_TEST_MODE}" = true ]; then
  if [ "${GITLAB_TARGET_SOURCE}" = tracked ] \
      || [ "${GITLAB_TOKEN_SOURCE}" = tracked ]; then
    echo "glab_auth: local-test mode refuses tracked GitLab target or token values" >&2
    exit 14
  fi
  if [ -n "${TRACKED_GITLAB_TOKEN}" ] \
      && [ "${GITLAB_TOKEN}" = "${TRACKED_GITLAB_TOKEN}" ]; then
    echo "glab_auth: local-test mode refuses a token equal to the tracked deployment token" >&2
    exit 14
  fi
  if [ "${GITLAB_HOST}" = "${TRACKED_GITLAB_HOST}" ]; then
    echo "glab_auth: local-test mode refuses the tracked deployment GitLab host" >&2
    exit 14
  fi
  ALLOWED_HOSTS="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS:-}"
  [ -n "${ALLOWED_HOSTS}" ] || {
    echo "glab_auth: local-test mode requires REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS" >&2
    exit 14
  }
  ALLOWED_MATCH=false
  ALLOWED_REMAINING="${ALLOWED_HOSTS},"
  while [ -n "${ALLOWED_REMAINING}" ]; do
    allowed_host="${ALLOWED_REMAINING%%,*}"
    ALLOWED_REMAINING="${ALLOWED_REMAINING#*,}"
    if [ -z "${allowed_host}" ] \
        || ! [[ "${allowed_host}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]]; then
      echo "glab_auth: local-test GitLab allowlist contains an invalid host" >&2
      exit 14
    fi
    if [[ "${allowed_host}" == *:* ]]; then
      allowed_port="${allowed_host##*:}"
      if [ "${allowed_port}" -lt 1 ] || [ "${allowed_port}" -gt 65535 ]; then
        echo "glab_auth: local-test GitLab allowlist contains an invalid port" >&2
        exit 14
      fi
    fi
    if [ "${allowed_host}" = "${GITLAB_HOST}" ]; then
      ALLOWED_MATCH=true
    fi
  done
  if [ "${ALLOWED_MATCH}" != true ]; then
    echo "glab_auth: effective GitLab host is not allowed in local-test mode" >&2
    exit 14
  fi
fi

# If the trigger supplied GITLAB_ADDRESS, verify it resolves to the effective
# host+protocol. It must never select or rewrite the target by itself.
if [ -n "${GITLAB_ADDRESS:-}" ]; then
  if [[ "${GITLAB_ADDRESS}" =~ ^(https?)://([A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?)/?$ ]]; then
    TRIGGER_PROTO="${BASH_REMATCH[1]}"
    TRIGGER_HOST="${BASH_REMATCH[2]}"
  else
    echo "glab_auth: trigger gitlab_address must be an exact http(s)://host[:port] URL" >&2
    exit 13
  fi

  if [ "${TRIGGER_HOST}" != "${GITLAB_HOST}" ] || [ "${TRIGGER_PROTO}" != "${GITLAB_API_PROTOCOL}" ]; then
    echo "glab_auth: trigger gitlab_address does not match the effective GitLab target" >&2
    echo "Refusing to switch hosts. Fix the trigger or the explicit local override." >&2
    exit 13
  fi
fi

# Source-only mode lets scheduler wrappers reuse this exact tuple resolver and
# local-test fence without performing auth network I/O. It must be sourced,
# never executed, so the resolved values remain in the caller's environment.
case "${GLAB_AUTH_RESOLVE_ONLY:-false}" in
  true|1)
    if [ "${BASH_SOURCE[0]}" = "$0" ]; then
      echo "glab_auth: GLAB_AUTH_RESOLVE_ONLY must be sourced" >&2
      exit 11
    fi
    export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
    export GITLAB_TARGET_SOURCE GITLAB_TOKEN_SOURCE
    unset GLAB_AUTH_RESOLVE_ONLY
    return 0
    ;;
  false|0|'') ;;
  *)
    echo "glab_auth: GLAB_AUTH_RESOLVE_ONLY must be true or false" >&2
    exit 11
    ;;
esac

# Refresh glab's stored token against the already validated effective host.
export GITLAB_HOST GITLAB_API_PROTOCOL
LOCK_ROOT="/tmp/req_executor_locks"
mkdir -p "${LOCK_ROOT}"
LOCK_HOST="$(printf '%s' "${GITLAB_HOST}" | tr -c 'A-Za-z0-9_.-' '_')"
exec 8>"${LOCK_ROOT}/glab-auth-${LOCK_HOST}.lock"
flock 8

"${GLAB_BIN}" auth login \
  --hostname "${GITLAB_HOST}" \
  --token "${GITLAB_TOKEN}" \
  --api-protocol "${GITLAB_API_PROTOCOL}" >/dev/null

"${GLAB_BIN}" auth status --hostname "${GITLAB_HOST}" >/dev/null

echo "${GITLAB_HOST}"
