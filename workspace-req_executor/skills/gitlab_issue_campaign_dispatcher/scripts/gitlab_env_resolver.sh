#!/usr/bin/env bash
# Source-only, network-free GitLab tuple resolver for scheduler wrappers.
# It runs glab_auth.sh's resolver in a subshell so sourcing an ignored local
# config cannot overwrite unrelated caller settings such as scheduler roots.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "gitlab_env_resolver.sh must be sourced" >&2
  exit 2
fi

__gitlab_env_resolver_main() {
  local script_dir auth_script resolver_json resolver_rc
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  auth_script="${script_dir}/glab_auth.sh"
  [ -f "${auth_script}" ] || {
    echo "gitlab_env_resolver: glab_auth.sh is missing" >&2
    return 2
  }

  if resolver_json="$(
    CONFIG_DIR="${CONFIG_DIR:-}" GLAB_AUTH_RESOLVE_ONLY=true \
      bash -c '
        set -euo pipefail
        source "$1" >/dev/null
        jq -cn \
          --arg host "$GITLAB_HOST" \
          --arg protocol "$GITLAB_API_PROTOCOL" \
          --arg token "$GITLAB_TOKEN" \
          --arg target_source "$GITLAB_TARGET_SOURCE" \
          --arg token_source "$GITLAB_TOKEN_SOURCE" \
          --arg glab_config_dir "${GLAB_CONFIG_DIR:-}" \
          --arg local_test_mode "${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE:-}" \
          --arg allowed_hosts "${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS:-}" \
          "{host:\$host,protocol:\$protocol,token:\$token,target_source:\$target_source,token_source:\$token_source,glab_config_dir:\$glab_config_dir,local_test_mode:\$local_test_mode,allowed_hosts:\$allowed_hosts}"
      ' _ "${auth_script}"
  )"; then
    :
  else
    resolver_rc=$?
    echo "gitlab_env_resolver: unable to resolve the GitLab target tuple" >&2
    return "${resolver_rc}"
  fi

  if ! jq -e '
      type == "object"
      and (keys | sort) == [
        "allowed_hosts","glab_config_dir","host","local_test_mode",
        "protocol","target_source","token","token_source"
      ]
      and (.host | type == "string" and length > 0)
      and (.protocol == "http" or .protocol == "https")
      and (.token | type == "string" and length > 0)
      and (.target_source == "process" or .target_source == "local"
        or .target_source == "tracked")
      and (.token_source == "process" or .token_source == "local"
        or .token_source == "tracked")
      and (.glab_config_dir | type == "string")
      and (.local_test_mode | type == "string")
      and (.allowed_hosts | type == "string")
    ' <<<"${resolver_json}" >/dev/null; then
    echo "gitlab_env_resolver: resolved GitLab tuple has an invalid shape" >&2
    return 2
  fi

  GITLAB_HOST="$(jq -r '.host' <<<"${resolver_json}")"
  GITLAB_API_PROTOCOL="$(jq -r '.protocol' <<<"${resolver_json}")"
  GITLAB_TOKEN="$(jq -r '.token' <<<"${resolver_json}")"
  GITLAB_TARGET_SOURCE="$(jq -r '.target_source' <<<"${resolver_json}")"
  GITLAB_TOKEN_SOURCE="$(jq -r '.token_source' <<<"${resolver_json}")"
  GLAB_CONFIG_DIR="$(jq -r '.glab_config_dir' <<<"${resolver_json}")"
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE="$(jq -r '.local_test_mode' <<<"${resolver_json}")"
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS="$(jq -r '.allowed_hosts' <<<"${resolver_json}")"
  export GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_TOKEN
  export GITLAB_TARGET_SOURCE GITLAB_TOKEN_SOURCE
  export REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE
  export REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS
  if [ -n "${GLAB_CONFIG_DIR}" ]; then
    export GLAB_CONFIG_DIR
  else
    unset GLAB_CONFIG_DIR
  fi
}

if __gitlab_env_resolver_main; then
  unset -f __gitlab_env_resolver_main
else
  case $? in
    1) unset -f __gitlab_env_resolver_main; return 1 ;;
    10) unset -f __gitlab_env_resolver_main; return 10 ;;
    11) unset -f __gitlab_env_resolver_main; return 11 ;;
    12) unset -f __gitlab_env_resolver_main; return 12 ;;
    13) unset -f __gitlab_env_resolver_main; return 13 ;;
    14) unset -f __gitlab_env_resolver_main; return 14 ;;
    *) unset -f __gitlab_env_resolver_main; return 2 ;;
  esac
fi
