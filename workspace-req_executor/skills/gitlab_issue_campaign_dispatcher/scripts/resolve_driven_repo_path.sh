#!/usr/bin/env bash
# Resolve a driven issue's final clone path without creating or modifying it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/git_network_guard.sh"
GIT_NETWORK_GUARD_CONTEXT=resolve_driven_repo_path

fail() {
  echo "resolve_driven_repo_path.sh: $*" >&2
  exit 2
}

[ -n "${PROJECT_FULL:-}" ] || fail "PROJECT_FULL must be set"
[ -n "${REPO_PARENT_PATH:-}" ] || fail "REPO_PARENT_PATH must be set"
[ -n "${GITLAB_API_PROTOCOL:-}" ] || fail "GITLAB_API_PROTOCOL must be set"
[ -n "${GITLAB_HOST:-}" ] || fail "GITLAB_HOST must be set"

case "${GITLAB_API_PROTOCOL}" in
  http|https) ;;
  *) fail "GITLAB_API_PROTOCOL must be http or https" ;;
esac
case "${GITLAB_HOST}" in
  */*|*@*|*[[:space:]]*|*[[:cntrl:]]*) fail "GITLAB_HOST is unsafe" ;;
esac

if ! [[ "${PROJECT_FULL}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  fail "PROJECT_FULL must contain at least two safe path segments"
fi
IFS='/' read -r -a project_segments <<<"${PROJECT_FULL}"
for segment in "${project_segments[@]}"; do
  case "${segment}" in
    .|..) fail "PROJECT_FULL must not contain dot segments" ;;
  esac
done

REPO_PARENT_NORMALIZED="${REPO_PARENT_PATH}"
while [ "${REPO_PARENT_NORMALIZED}" != "/" ] && [ "${REPO_PARENT_NORMALIZED%/}" != "${REPO_PARENT_NORMALIZED}" ]; do
  REPO_PARENT_NORMALIZED="${REPO_PARENT_NORMALIZED%/}"
done
case "${REPO_PARENT_NORMALIZED}" in
  /*) ;;
  *) fail "REPO_PARENT_PATH must be absolute" ;;
esac
case "${REPO_PARENT_NORMALIZED}" in
  /|//*|*/../*|*/..|*/./*|*/.) fail "REPO_PARENT_PATH is unsafe" ;;
esac
case "${REPO_PARENT_NORMALIZED}" in
  *[!A-Za-z0-9_./-]*) fail "REPO_PARENT_PATH contains unsupported characters" ;;
esac

PROJECT_SLUG="${PROJECT_FULL##*/}"
LEGACY_PATH="${REPO_PARENT_NORMALIZED}/${PROJECT_SLUG}"
NESTED_PATH="${REPO_PARENT_NORMALIZED}/${PROJECT_FULL}"

if [ -d "${LEGACY_PATH}/.git" ]; then
  if git_network_guard_assert_origin_only "${LEGACY_PATH}" \
      >/dev/null 2>&1; then
    printf '%s\n' "${LEGACY_PATH}"
    exit 0
  fi
fi

printf '%s\n' "${NESTED_PATH}"
