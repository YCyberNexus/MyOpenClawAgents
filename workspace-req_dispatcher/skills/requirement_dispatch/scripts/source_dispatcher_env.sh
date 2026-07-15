#!/usr/bin/env bash
# Source req_dispatcher deployment pins, then optional local overrides.
#
# Usage from the skill dir:
#   source scripts/source_dispatcher_env.sh
#
# Tests may set DISPATCHER_CONFIG_DIR to a throwaway config directory.
if [ -n "${BASH_VERSION:-}" ]; then
  SOURCE_DISPATCHER_ENV_SOURCE_PATH="${BASH_SOURCE[0]}"
  if [ "${SOURCE_DISPATCHER_ENV_SOURCE_PATH}" = "$0" ]; then
    echo "source_dispatcher_env.sh: source this file instead of executing it" >&2
    exit 2
  fi
elif [ -n "${ZSH_VERSION:-}" ]; then
  source_dispatcher_zsh_source_path() {
    printf '%s' "${funcfiletrace[1]%:*}"
  }
  SOURCE_DISPATCHER_ENV_SOURCE_PATH="$(source_dispatcher_zsh_source_path)"
  unset -f source_dispatcher_zsh_source_path
  case "${ZSH_EVAL_CONTEXT:-}" in
    *:file) ;;
    *)
      echo "source_dispatcher_env.sh: source this file instead of executing it" >&2
      exit 2
      ;;
  esac
else
  echo "source_dispatcher_env.sh: bash or zsh is required" >&2
  return 2
fi

SOURCE_DISPATCHER_ENV_SCRIPT_DIR="$(cd "$(dirname "${SOURCE_DISPATCHER_ENV_SOURCE_PATH}")" && pwd)"
SOURCE_DISPATCHER_ENV_SKILL_DIR="$(cd "${SOURCE_DISPATCHER_ENV_SCRIPT_DIR}/.." && pwd)"
SOURCE_DISPATCHER_ENV_CONFIG_DIR="${DISPATCHER_CONFIG_DIR:-$(cd "${SOURCE_DISPATCHER_ENV_SKILL_DIR}/../.." && pwd)/config}"
source_dispatcher_cleanup_helpers() {
  unset SOURCE_DISPATCHER_ALLOWED_HOSTS_ENV_SET
  unset SOURCE_DISPATCHER_ALLOWED_HOSTS_ENV_VALUE
  unset SOURCE_DISPATCHER_PROCESS_EXECUTOR_STATE_SET
  unset SOURCE_DISPATCHER_PROCESS_EXECUTOR_STATE_VALUE
  unset SOURCE_DISPATCHER_ENV_CONFIG_DIR SOURCE_DISPATCHER_ENV_SCRIPT_DIR
  unset SOURCE_DISPATCHER_ENV_SKILL_DIR SOURCE_DISPATCHER_ENV_SOURCE_PATH
  unset SOURCE_DISPATCHER_GENERIC_SOURCE
  unset SOURCE_DISPATCHER_LOCAL_HOST_SET SOURCE_DISPATCHER_LOCAL_HOST_VALUE
  unset SOURCE_DISPATCHER_LOCAL_MODE_ENV_SET SOURCE_DISPATCHER_LOCAL_MODE_ENV_VALUE
  unset SOURCE_DISPATCHER_LOCAL_PROTOCOL_SET SOURCE_DISPATCHER_LOCAL_PROTOCOL_VALUE
  unset SOURCE_DISPATCHER_LOCAL_TOKEN_SET SOURCE_DISPATCHER_LOCAL_TOKEN_VALUE
  unset SOURCE_DISPATCHER_LOCAL_WIKI_HOST_SET SOURCE_DISPATCHER_LOCAL_WIKI_HOST_VALUE
  unset SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_SET
  unset SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_VALUE
  unset SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_SET SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_VALUE
  unset SOURCE_DISPATCHER_PROCESS_HOST_SET SOURCE_DISPATCHER_PROCESS_HOST_VALUE
  unset SOURCE_DISPATCHER_PROCESS_PROTOCOL_SET SOURCE_DISPATCHER_PROCESS_PROTOCOL_VALUE
  unset SOURCE_DISPATCHER_PROCESS_TOKEN_SET SOURCE_DISPATCHER_PROCESS_TOKEN_VALUE
  unset SOURCE_DISPATCHER_PROCESS_WIKI_HOST_SET
  unset SOURCE_DISPATCHER_PROCESS_WIKI_HOST_VALUE
  unset SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_SET
  unset SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_VALUE
  unset SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_SET
  unset SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_VALUE
  unset SOURCE_DISPATCHER_TRACKED_HOST SOURCE_DISPATCHER_TRACKED_PROTOCOL
  unset SOURCE_DISPATCHER_TRACKED_TOKEN SOURCE_DISPATCHER_TRACKED_WIKI_HOST
  unset SOURCE_DISPATCHER_TRACKED_WIKI_PROTOCOL SOURCE_DISPATCHER_TRACKED_WIKI_TOKEN
  unset SOURCE_DISPATCHER_TUPLE_ERROR SOURCE_DISPATCHER_WIKI_SOURCE
}
SOURCE_DISPATCHER_PROCESS_WIKI_HOST_SET="${WIKI_GITLAB_HOST+x}"
SOURCE_DISPATCHER_PROCESS_WIKI_HOST_VALUE="${WIKI_GITLAB_HOST:-}"
SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_SET="${WIKI_GITLAB_API_PROTOCOL+x}"
SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_VALUE="${WIKI_GITLAB_API_PROTOCOL:-}"
SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_SET="${WIKI_GITLAB_TOKEN+x}"
SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_VALUE="${WIKI_GITLAB_TOKEN:-}"
SOURCE_DISPATCHER_PROCESS_HOST_SET="${GITLAB_HOST+x}"
SOURCE_DISPATCHER_PROCESS_HOST_VALUE="${GITLAB_HOST:-}"
SOURCE_DISPATCHER_PROCESS_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
SOURCE_DISPATCHER_PROCESS_PROTOCOL_VALUE="${GITLAB_API_PROTOCOL:-}"
SOURCE_DISPATCHER_PROCESS_TOKEN_SET="${GITLAB_TOKEN+x}"
SOURCE_DISPATCHER_PROCESS_TOKEN_VALUE="${GITLAB_TOKEN:-}"
SOURCE_DISPATCHER_LOCAL_MODE_ENV_SET="${REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE+x}"
SOURCE_DISPATCHER_LOCAL_MODE_ENV_VALUE="${REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE:-}"
SOURCE_DISPATCHER_ALLOWED_HOSTS_ENV_SET="${REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS+x}"
SOURCE_DISPATCHER_ALLOWED_HOSTS_ENV_VALUE="${REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS:-}"
SOURCE_DISPATCHER_PROCESS_EXECUTOR_STATE_SET="${EXECUTOR_SCHEDULER_STATE_FILE+x}"
SOURCE_DISPATCHER_PROCESS_EXECUTOR_STATE_VALUE="${EXECUTOR_SCHEDULER_STATE_FILE:-}"

if [ ! -f "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.env" ]; then
  echo "source_dispatcher_env.sh: missing dispatcher.env at ${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.env" >&2
  source_dispatcher_cleanup_helpers
  unset -f source_dispatcher_cleanup_helpers
  return 2
fi

set -a
# shellcheck disable=SC1091
source "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.env"
SOURCE_DISPATCHER_TRACKED_WIKI_HOST="${WIKI_GITLAB_HOST:-}"
SOURCE_DISPATCHER_TRACKED_WIKI_PROTOCOL="${WIKI_GITLAB_API_PROTOCOL:-}"
SOURCE_DISPATCHER_TRACKED_WIKI_TOKEN="${WIKI_GITLAB_TOKEN:-}"
SOURCE_DISPATCHER_TRACKED_HOST="${GITLAB_HOST:-}"
SOURCE_DISPATCHER_TRACKED_PROTOCOL="${GITLAB_API_PROTOCOL:-}"
SOURCE_DISPATCHER_TRACKED_TOKEN="${GITLAB_TOKEN:-}"
unset WIKI_GITLAB_HOST WIKI_GITLAB_API_PROTOCOL WIKI_GITLAB_TOKEN
unset GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
if [ -f "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.local.env" ]; then
  # shellcheck disable=SC1091
  source "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.local.env"
fi
set +a

if [ "${SOURCE_DISPATCHER_PROCESS_EXECUTOR_STATE_SET}" = x ]; then
  EXECUTOR_SCHEDULER_STATE_FILE="${SOURCE_DISPATCHER_PROCESS_EXECUTOR_STATE_VALUE}"
fi

SOURCE_DISPATCHER_LOCAL_WIKI_HOST_SET="${WIKI_GITLAB_HOST+x}"
SOURCE_DISPATCHER_LOCAL_WIKI_HOST_VALUE="${WIKI_GITLAB_HOST:-}"
SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_SET="${WIKI_GITLAB_API_PROTOCOL+x}"
SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_VALUE="${WIKI_GITLAB_API_PROTOCOL:-}"
SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_SET="${WIKI_GITLAB_TOKEN+x}"
SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_VALUE="${WIKI_GITLAB_TOKEN:-}"
SOURCE_DISPATCHER_LOCAL_HOST_SET="${GITLAB_HOST+x}"
SOURCE_DISPATCHER_LOCAL_HOST_VALUE="${GITLAB_HOST:-}"
SOURCE_DISPATCHER_LOCAL_PROTOCOL_SET="${GITLAB_API_PROTOCOL+x}"
SOURCE_DISPATCHER_LOCAL_PROTOCOL_VALUE="${GITLAB_API_PROTOCOL:-}"
SOURCE_DISPATCHER_LOCAL_TOKEN_SET="${GITLAB_TOKEN+x}"
SOURCE_DISPATCHER_LOCAL_TOKEN_VALUE="${GITLAB_TOKEN:-}"

unset WIKI_GITLAB_HOST WIKI_GITLAB_API_PROTOCOL WIKI_GITLAB_TOKEN
unset GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
SOURCE_DISPATCHER_TUPLE_ERROR=""
if [ "${SOURCE_DISPATCHER_PROCESS_WIKI_HOST_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_SET}" = x ]; then
  if [ "${SOURCE_DISPATCHER_PROCESS_WIKI_HOST_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_SET}" != x ] \
      || [ -z "${SOURCE_DISPATCHER_PROCESS_WIKI_HOST_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_VALUE}" ]; then
    SOURCE_DISPATCHER_TUPLE_ERROR="process WIKI_GITLAB tuple must be complete"
  else
    WIKI_GITLAB_HOST="${SOURCE_DISPATCHER_PROCESS_WIKI_HOST_VALUE}"
    WIKI_GITLAB_API_PROTOCOL="${SOURCE_DISPATCHER_PROCESS_WIKI_PROTOCOL_VALUE}"
    WIKI_GITLAB_TOKEN="${SOURCE_DISPATCHER_PROCESS_WIKI_TOKEN_VALUE}"
  fi
  SOURCE_DISPATCHER_WIKI_SOURCE=process
elif [ "${SOURCE_DISPATCHER_LOCAL_WIKI_HOST_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_SET}" = x ]; then
  if [ "${SOURCE_DISPATCHER_LOCAL_WIKI_HOST_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_SET}" != x ] \
      || [ -z "${SOURCE_DISPATCHER_LOCAL_WIKI_HOST_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_VALUE}" ]; then
    SOURCE_DISPATCHER_TUPLE_ERROR="local WIKI_GITLAB tuple must be complete"
  else
    WIKI_GITLAB_HOST="${SOURCE_DISPATCHER_LOCAL_WIKI_HOST_VALUE}"
    WIKI_GITLAB_API_PROTOCOL="${SOURCE_DISPATCHER_LOCAL_WIKI_PROTOCOL_VALUE}"
    WIKI_GITLAB_TOKEN="${SOURCE_DISPATCHER_LOCAL_WIKI_TOKEN_VALUE}"
  fi
  SOURCE_DISPATCHER_WIKI_SOURCE=local
else
  WIKI_GITLAB_HOST="${SOURCE_DISPATCHER_TRACKED_WIKI_HOST}"
  WIKI_GITLAB_API_PROTOCOL="${SOURCE_DISPATCHER_TRACKED_WIKI_PROTOCOL}"
  WIKI_GITLAB_TOKEN="${SOURCE_DISPATCHER_TRACKED_WIKI_TOKEN}"
  SOURCE_DISPATCHER_WIKI_SOURCE=tracked
fi

if [ "${SOURCE_DISPATCHER_PROCESS_HOST_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_PROCESS_PROTOCOL_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_PROCESS_TOKEN_SET}" = x ]; then
  if [ "${SOURCE_DISPATCHER_PROCESS_HOST_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_PROCESS_PROTOCOL_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_PROCESS_TOKEN_SET}" != x ] \
      || [ -z "${SOURCE_DISPATCHER_PROCESS_HOST_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_PROCESS_PROTOCOL_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_PROCESS_TOKEN_VALUE}" ]; then
    SOURCE_DISPATCHER_TUPLE_ERROR="${SOURCE_DISPATCHER_TUPLE_ERROR:+${SOURCE_DISPATCHER_TUPLE_ERROR}; }process GitLab tuple must be complete"
  else
    GITLAB_HOST="${SOURCE_DISPATCHER_PROCESS_HOST_VALUE}"
    GITLAB_API_PROTOCOL="${SOURCE_DISPATCHER_PROCESS_PROTOCOL_VALUE}"
    GITLAB_TOKEN="${SOURCE_DISPATCHER_PROCESS_TOKEN_VALUE}"
  fi
  SOURCE_DISPATCHER_GENERIC_SOURCE=process
elif [ "${SOURCE_DISPATCHER_LOCAL_HOST_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_LOCAL_PROTOCOL_SET}" = x ] \
    || [ "${SOURCE_DISPATCHER_LOCAL_TOKEN_SET}" = x ]; then
  if [ "${SOURCE_DISPATCHER_LOCAL_HOST_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_LOCAL_PROTOCOL_SET}" != x ] \
      || [ "${SOURCE_DISPATCHER_LOCAL_TOKEN_SET}" != x ] \
      || [ -z "${SOURCE_DISPATCHER_LOCAL_HOST_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_LOCAL_PROTOCOL_VALUE}" ] \
      || [ -z "${SOURCE_DISPATCHER_LOCAL_TOKEN_VALUE}" ]; then
    SOURCE_DISPATCHER_TUPLE_ERROR="${SOURCE_DISPATCHER_TUPLE_ERROR:+${SOURCE_DISPATCHER_TUPLE_ERROR}; }local GitLab tuple must be complete"
  else
    GITLAB_HOST="${SOURCE_DISPATCHER_LOCAL_HOST_VALUE}"
    GITLAB_API_PROTOCOL="${SOURCE_DISPATCHER_LOCAL_PROTOCOL_VALUE}"
    GITLAB_TOKEN="${SOURCE_DISPATCHER_LOCAL_TOKEN_VALUE}"
  fi
  SOURCE_DISPATCHER_GENERIC_SOURCE=local
elif [ -n "${SOURCE_DISPATCHER_TRACKED_HOST}" ] \
    || [ -n "${SOURCE_DISPATCHER_TRACKED_PROTOCOL}" ] \
    || [ -n "${SOURCE_DISPATCHER_TRACKED_TOKEN}" ]; then
  GITLAB_HOST="${SOURCE_DISPATCHER_TRACKED_HOST}"
  GITLAB_API_PROTOCOL="${SOURCE_DISPATCHER_TRACKED_PROTOCOL}"
  GITLAB_TOKEN="${SOURCE_DISPATCHER_TRACKED_TOKEN}"
  SOURCE_DISPATCHER_GENERIC_SOURCE=tracked
else
  SOURCE_DISPATCHER_GENERIC_SOURCE=none
fi
export WIKI_GITLAB_HOST WIKI_GITLAB_API_PROTOCOL WIKI_GITLAB_TOKEN
if [ "${SOURCE_DISPATCHER_GENERIC_SOURCE}" != none ]; then
  export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
fi

if [ "${SOURCE_DISPATCHER_LOCAL_MODE_ENV_SET}" = x ]; then
  REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE="${SOURCE_DISPATCHER_LOCAL_MODE_ENV_VALUE}"
fi
if [ "${SOURCE_DISPATCHER_ALLOWED_HOSTS_ENV_SET}" = x ]; then
  REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS="${SOURCE_DISPATCHER_ALLOWED_HOSTS_ENV_VALUE}"
fi
export REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE
export REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS

source_dispatcher_local_guard() {
  local tracked_host="$1" tracked_token="$2" wiki_source="$3"
  local generic_source="$4" tuple_error="$5"
  local mode="${REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE:-false}"
  local remaining allowed candidate matched
  if [ -n "${tuple_error}" ]; then
    echo "source_dispatcher_env: ${tuple_error}" >&2
    return 14
  fi
  case "${mode}" in
    true|1) ;;
    false|0|'') return 0 ;;
    *)
      echo "source_dispatcher_env: REQ_DISPATCHER_GITLAB_LOCAL_TEST_MODE must be true or false" >&2
      return 14
      ;;
  esac

  [ -n "${REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS:-}" ] || {
    echo "source_dispatcher_env: local-test mode requires REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS" >&2
    return 14
  }
  if [ "${wiki_source}" = tracked ] \
      || [ "${generic_source}" = tracked ]; then
    echo "source_dispatcher_env: local-test mode refuses tracked GitLab tuple values" >&2
    return 14
  fi
  if [ -z "${WIKI_GITLAB_HOST:-}" ] \
      || [ -z "${WIKI_GITLAB_API_PROTOCOL:-}" ] \
      || [ -z "${WIKI_GITLAB_TOKEN:-}" ]; then
    echo "source_dispatcher_env: local-test mode requires the complete WIKI_GITLAB tuple" >&2
    return 14
  fi
  case "${WIKI_GITLAB_API_PROTOCOL}" in
    http|https) ;;
    *)
      echo "source_dispatcher_env: WIKI_GITLAB_API_PROTOCOL must be http or https" >&2
      return 14
      ;;
  esac
  if [ -n "${GITLAB_HOST:-}" ]; then
    if [ -z "${GITLAB_API_PROTOCOL:-}" ] || [ -z "${GITLAB_TOKEN:-}" ]; then
      echo "source_dispatcher_env: local-test mode requires a complete generic GitLab tuple" >&2
      return 14
    fi
    case "${GITLAB_API_PROTOCOL}" in
      http|https) ;;
      *)
        echo "source_dispatcher_env: GITLAB_API_PROTOCOL must be http or https" >&2
        return 14
        ;;
    esac
  fi

  if [ "${WIKI_GITLAB_HOST}" = "${tracked_host}" ]; then
    echo "source_dispatcher_env: local-test mode refuses the tracked deployment GitLab host" >&2
    return 14
  fi
  if [ -n "${tracked_token}" ] \
      && { [ "${WIKI_GITLAB_TOKEN}" = "${tracked_token}" ] \
        || [ "${GITLAB_TOKEN:-}" = "${tracked_token}" ]; }; then
    echo "source_dispatcher_env: local-test mode refuses a token equal to the tracked deployment token" >&2
    return 14
  fi

  for candidate in "${WIKI_GITLAB_HOST}" "${GITLAB_HOST:-}"; do
    [ -n "${candidate}" ] || continue
    if ! [[ "${candidate}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]]; then
      echo "source_dispatcher_env: local-test GitLab host must be an exact host[:port] value" >&2
      return 14
    fi
    if [[ "${candidate}" == *:* ]]; then
      local candidate_port="${candidate##*:}"
      if [ "${candidate_port}" -lt 1 ] || [ "${candidate_port}" -gt 65535 ]; then
        echo "source_dispatcher_env: local-test GitLab host port is invalid" >&2
        return 14
      fi
    fi
    matched=false
    remaining="${REQ_DISPATCHER_GITLAB_ALLOWED_HOSTS},"
    while [ -n "${remaining}" ]; do
      allowed="${remaining%%,*}"
      remaining="${remaining#*,}"
      if [ -z "${allowed}" ] \
          || ! [[ "${allowed}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]]; then
        echo "source_dispatcher_env: local-test GitLab allowlist contains an invalid host" >&2
        return 14
      fi
      [ "${candidate}" != "${allowed}" ] || matched=true
    done
    if [ "${matched}" != true ]; then
      echo "source_dispatcher_env: effective GitLab host is not allowed in local-test mode" >&2
      return 14
    fi
  done
}

if source_dispatcher_local_guard \
    "${SOURCE_DISPATCHER_TRACKED_WIKI_HOST}" \
    "${SOURCE_DISPATCHER_TRACKED_WIKI_TOKEN}" \
    "${SOURCE_DISPATCHER_WIKI_SOURCE}" \
    "${SOURCE_DISPATCHER_GENERIC_SOURCE}" \
    "${SOURCE_DISPATCHER_TUPLE_ERROR}"; then
  :
else
  unset -f source_dispatcher_local_guard
  source_dispatcher_cleanup_helpers
  unset -f source_dispatcher_cleanup_helpers
  return 14
fi
unset -f source_dispatcher_local_guard
source_dispatcher_cleanup_helpers
unset -f source_dispatcher_cleanup_helpers
