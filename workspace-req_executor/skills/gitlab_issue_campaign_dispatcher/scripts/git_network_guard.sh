#!/usr/bin/env bash
# Shared fail-closed Git transport guard. Source this file, then route every
# clone/fetch/ls-remote/push through git_network_guard_clone or
# git_network_guard_run. The guard validates the effective GitLab target,
# local-test allowlist, proxy/rewrite configuration, pushurl, and exact origin
# components immediately before each network-capable Git command.

GIT_NETWORK_GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git_network_guard_die() {
  echo "${GIT_NETWORK_GUARD_CONTEXT:-git_network_guard}: $1" >&2
  return "${2:-86}"
}

git_network_guard_validate_target() {
  : "${GITLAB_HOST:?git_network_guard: GITLAB_HOST must be set}" \
    "${GITLAB_API_PROTOCOL:?git_network_guard: GITLAB_API_PROTOCOL must be set}"
  case "${GITLAB_API_PROTOCOL}" in
    http|https) ;;
    *) git_network_guard_die "GITLAB_API_PROTOCOL must be exactly http or https" || return ;;
  esac
  if ! [[ "${GITLAB_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]]; then
    git_network_guard_die "GITLAB_HOST must be an exact host[:port] value" || return
  fi
  if [[ "${GITLAB_HOST}" == *:* ]]; then
    local port="${GITLAB_HOST##*:}"
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
      git_network_guard_die "GITLAB_HOST port must be between 1 and 65535" || return
    fi
  fi

  if [ -n "${PROJECT_FULL:-}" ]; then
    GIT_NETWORK_GUARD_PROJECT_FULL="${PROJECT_FULL}"
  else
    : "${GROUP:?git_network_guard: GROUP must be set}" \
      "${PROJECT:?git_network_guard: PROJECT must be set}"
    GIT_NETWORK_GUARD_PROJECT_FULL="${GROUP}/${PROJECT}"
  fi
  if ! [[ "${GIT_NETWORK_GUARD_PROJECT_FULL}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] \
      || [[ "/${GIT_NETWORK_GUARD_PROJECT_FULL}/" == *"/../"* ]] \
      || [[ "/${GIT_NETWORK_GUARD_PROJECT_FULL}/" == *"/./"* ]]; then
    git_network_guard_die "project must contain at least two safe path segments" || return
  fi
}

git_network_guard_host_is_allowlisted() {
  local candidate="$1" remaining allowed matched=false
  remaining="${REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS:-},"
  while [ -n "${remaining}" ]; do
    allowed="${remaining%%,*}"
    remaining="${remaining#*,}"
    [ -n "${allowed}" ] || return 1
    if ! [[ "${allowed}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]]; then
      return 1
    fi
    if [[ "${allowed}" == *:* ]]; then
      local port="${allowed##*:}"
      [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || return 1
    fi
    [ "${candidate}" != "${allowed}" ] || matched=true
  done
  [ "${matched}" = true ]
}

git_network_guard_enforce_local_test_host() {
  local mode="${REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE:-false}"
  local pin_file tracked_host tracked_token
  case "${mode}" in
    true|1) ;;
    false|0|'') return 0 ;;
    *) git_network_guard_die "REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE must be true or false" || return ;;
  esac
  pin_file="${CONFIG_DIR:-$(cd "${GIT_NETWORK_GUARD_SCRIPT_DIR}/../../.." && pwd)/config}/gitlab.env"
  [ -f "${pin_file}" ] \
    || { git_network_guard_die "local-test mode cannot verify the tracked GitLab host" || return; }
  tracked_host="$(awk -F= '$1 == "GITLAB_HOST" { print substr($0, index($0, "=") + 1); exit }' "${pin_file}")"
  tracked_token="$(awk -F= '$1 == "GITLAB_TOKEN" { print substr($0, index($0, "=") + 1); exit }' "${pin_file}")"
  [ -n "${tracked_host}" ] \
    || { git_network_guard_die "local-test mode cannot read the tracked GitLab host" || return; }
  if [ "${GITLAB_HOST}" = "${tracked_host}" ]; then
    git_network_guard_die "local-test mode refuses the tracked deployment GitLab host" || return
  fi
  if [ -n "${tracked_token}" ] \
      && [ "${GITLAB_TOKEN:-}" = "${tracked_token}" ]; then
    git_network_guard_die "local-test mode refuses a token equal to the tracked deployment token" || return
  fi
  git_network_guard_host_is_allowlisted "${GITLAB_HOST}" \
    || { git_network_guard_die "effective GitLab host is not allowed in local-test mode" || return; }
}

git_network_guard_reject_proxy_environment() {
  local name value
  for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    eval 'value=${'"${name}"':-}'
    if [ -n "${value}" ]; then
      git_network_guard_die "proxy environment is not allowed for GitLab Git transport" || return
    fi
  done
}

git_network_guard_config_must_not_match() {
  local repo="$1" pattern="$2" description="$3" rc
  local -a command=(git)
  if [ -n "${repo}" ]; then
    command+=( -C "${repo}" )
  fi
  if "${command[@]}" config --name-only --get-regexp "${pattern}" \
      >/dev/null 2>&1; then
    git_network_guard_die "${description} is not allowed for GitLab Git transport" || return
  else
    rc=$?
    [ "${rc}" -eq 1 ] \
      || { git_network_guard_die "unable to audit Git configuration before network access" || return; }
  fi
}

git_network_guard_validate_origin_target_url() {
  local url="$1" remainder authority host_port path
  case "${url}" in
    "${GITLAB_API_PROTOCOL}://"*) remainder="${url#${GITLAB_API_PROTOCOL}://}" ;;
    *) return 1 ;;
  esac
  [ "${remainder}" != "${remainder%%/*}" ] || return 1
  authority="${remainder%%/*}"
  path="/${remainder#*/}"
  host_port="${authority##*@}"
  [ -n "${authority}" ] && [ "${host_port}" = "${GITLAB_HOST}" ] \
    && [ "${path}" = "/${GIT_NETWORK_GUARD_PROJECT_FULL}.git" ] \
    && [[ "${path}" != *\?* ]] && [[ "${path}" != *\#* ]]
}

git_network_guard_validate_origin_url() {
  local url="$1" remainder authority host_port path
  case "${url}" in
    "${GITLAB_API_PROTOCOL}://"*) remainder="${url#${GITLAB_API_PROTOCOL}://}" ;;
    *) return 1 ;;
  esac
  [ "${remainder}" != "${remainder%%/*}" ] || return 1
  authority="${remainder%%/*}"
  path="/${remainder#*/}"
  if [[ "${authority}" == *@* ]]; then
    [ -n "${GITLAB_TOKEN:-}" ] \
      && [[ "${GITLAB_TOKEN}" =~ ^[A-Za-z0-9._~-]+$ ]] \
      && [ "${authority}" = "oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}" ] \
      || return 1
    host_port="${GITLAB_HOST}"
  else
    return 1
  fi
  [ -n "${authority}" ] && [ "${host_port}" = "${GITLAB_HOST}" ] \
    && [ "${path}" = "/${GIT_NETWORK_GUARD_PROJECT_FULL}.git" ] \
    && [[ "${path}" != *\?* ]] && [[ "${path}" != *\#* ]]
}

git_network_guard_assert_single_origin() {
  local repo="$1" origin rc
  if origin="$(git -C "${repo}" config --get-all remote.origin.url 2>/dev/null)"; then
    :
  else
    rc=$?
    git_network_guard_die "origin URL is missing or unreadable (git config exit ${rc})" || return
  fi
  [ -n "${origin}" ] && [[ "${origin}" != *$'\n'* ]] \
    || { git_network_guard_die "origin must contain exactly one URL" || return; }
  git_network_guard_validate_origin_url "${origin}" \
    || { git_network_guard_die "origin URL does not exactly match the expected protocol, host, port, and project path" || return; }
  if git -C "${repo}" config --get-all remote.origin.pushurl \
      >/dev/null 2>&1; then
    git_network_guard_die "remote.origin.pushurl is not allowed" || return
  else
    rc=$?
    [ "${rc}" -eq 1 ] \
      || { git_network_guard_die "unable to audit remote.origin.pushurl" || return; }
  fi
}

git_network_guard_assert_single_origin_target() {
  local repo="$1" origin rc
  if origin="$(git -C "${repo}" config --get-all remote.origin.url 2>/dev/null)"; then
    :
  else
    rc=$?
    git_network_guard_die "origin URL is missing or unreadable (git config exit ${rc})" || return
  fi
  [ -n "${origin}" ] && [[ "${origin}" != *$'\n'* ]] \
    || { git_network_guard_die "origin must contain exactly one URL" || return; }
  git_network_guard_validate_origin_target_url "${origin}" \
    || { git_network_guard_die "origin URL does not exactly match the expected protocol, host, port, and project path" || return; }
  if git -C "${repo}" config --get-all remote.origin.pushurl \
      >/dev/null 2>&1; then
    git_network_guard_die "remote.origin.pushurl is not allowed" || return
  else
    rc=$?
    [ "${rc}" -eq 1 ] \
      || { git_network_guard_die "unable to audit remote.origin.pushurl" || return; }
  fi
}

git_network_guard_set_args() {
  GIT_NETWORK_GUARD_CONFIG_ARGS=(
    -c http.followRedirects=false
    -c protocol.allow=never
    -c "protocol.${GITLAB_API_PROTOCOL}.allow=always"
    -c credential.helper=
    -c credential.interactive=never
  )
}

git_network_guard_assert_clone_context() {
  git_network_guard_validate_target || return
  git_network_guard_enforce_local_test_host || return
  git_network_guard_reject_proxy_environment || return
  git_network_guard_config_must_not_match "" \
    '^url\..*\.(insteadof|pushinsteadof)$' \
    "Git URL rewrite configuration" || return
  git_network_guard_config_must_not_match "" \
    '^(http(\..*)?\.proxy|https\.proxy|remote\..*\.proxy|core\.gitproxy)$' \
    "Git proxy configuration" || return
  git_network_guard_set_args
}

git_network_guard_assert_repo() {
  local repo="$1"
  git_network_guard_validate_target || return
  git_network_guard_enforce_local_test_host || return
  git_network_guard_reject_proxy_environment || return
  git_network_guard_config_must_not_match "${repo}" \
    '^url\..*\.(insteadof|pushinsteadof)$' \
    "Git URL rewrite configuration" || return
  git_network_guard_config_must_not_match "${repo}" \
    '^(http(\..*)?\.proxy|https\.proxy|remote\..*\.proxy|core\.gitproxy)$' \
    "Git proxy configuration" || return
  git_network_guard_assert_single_origin "${repo}" || return
  git_network_guard_set_args
}

git_network_guard_assert_repo_rewrite_context() {
  local repo="$1"
  git_network_guard_validate_target || return
  git_network_guard_enforce_local_test_host || return
  git_network_guard_reject_proxy_environment || return
  git_network_guard_config_must_not_match "${repo}" \
    '^url\..*\.(insteadof|pushinsteadof)$' \
    "Git URL rewrite configuration" || return
  git_network_guard_config_must_not_match "${repo}" \
    '^(http(\..*)?\.proxy|https\.proxy|remote\..*\.proxy|core\.gitproxy)$' \
    "Git proxy configuration" || return
  git_network_guard_assert_single_origin_target "${repo}" || return
  git_network_guard_set_args
}

git_network_guard_assert_origin_only() {
  local repo="$1"
  git_network_guard_validate_target || return
  git_network_guard_assert_single_origin "${repo}"
}

git_network_guard_harden_repo() {
  local repo="$1"
  git -C "${repo}" config --local http.followRedirects false
  git -C "${repo}" config --local protocol.allow never
  git -C "${repo}" config --local "protocol.${GITLAB_API_PROTOCOL}.allow" always
}

git_network_guard_clone() {
  git_network_guard_assert_clone_context || return
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
    git "${GIT_NETWORK_GUARD_CONFIG_ARGS[@]}" clone "$@"
}

git_network_guard_run() {
  local repo="$1"
  shift
  git_network_guard_assert_repo "${repo}" || return
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
    git -C "${repo}" "${GIT_NETWORK_GUARD_CONFIG_ARGS[@]}" "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "git_network_guard.sh must be sourced" >&2
  exit 2
fi
