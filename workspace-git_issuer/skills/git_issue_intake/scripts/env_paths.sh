#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CONFIG_DIR="${WORKSPACE_ROOT}/config"
GITLAB_ENV_FILE="${GITLAB_ENV_FILE:-${CONFIG_DIR}/gitlab.env}"

trim_env_value() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

load_gitlab_env() {
  local file="${1:-${GITLAB_ENV_FILE}}"
  local raw_line line key value current

  if [ -f "${file}" ]; then
    while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
      line="$(trim_env_value "${raw_line}")"
      [ -n "${line}" ] || continue
      case "${line}" in
        \#*) continue ;;
        *=*) ;;
        *) continue ;;
      esac

      key="$(trim_env_value "${line%%=*}")"
      value="$(trim_env_value "${line#*=}")"
      case "${key}" in
        GITLAB_HOST|GITLAB_API_PROTOCOL|GITLAB_TOKEN|DEFAULT_ENTRY_LABEL|STATE_ROOT)
          current="${!key-}"
          if [ -z "${current}" ]; then
            export "${key}=${value}"
          fi
          ;;
      esac
    done <"${file}"
  fi

  export GITLAB_HOST="${GITLAB_HOST:-gitlab-b.pxsemic.tech:30000}"
  export GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL:-http}"
  export DEFAULT_ENTRY_LABEL="${DEFAULT_ENTRY_LABEL:-todo}"
}

project_uri_for() {
  local project="$1"
  printf '%s' "${project//\//%2F}"
}

require_value() {
  local name="$1"
  local value="${!name-}"
  if [ -z "${value}" ]; then
    printf '%s is required\n' "${name}"
    return 1
  fi
}

ensure_glab_auth() {
  if ! command -v glab >/dev/null 2>&1; then
    printf 'glab command not found\n'
    return 1
  fi
  if [ -z "${GITLAB_TOKEN:-}" ]; then
    printf 'GITLAB_TOKEN is required\n'
    return 1
  fi
  if ! glab auth login --hostname "${GITLAB_HOST}" --token "${GITLAB_TOKEN}" --api-protocol "${GITLAB_API_PROTOCOL}" >/dev/null 2>&1; then
    printf 'glab auth login failed\n'
    return 1
  fi
  if ! glab auth status --hostname "${GITLAB_HOST}" >/dev/null 2>&1; then
    printf 'glab auth status failed\n'
    return 1
  fi
}
