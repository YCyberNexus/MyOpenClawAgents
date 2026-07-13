#!/usr/bin/env bash
# Shared branch resolution helpers. Source this file from wrapper scripts.

BRANCH_UTILS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F git_network_guard_run >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${BRANCH_UTILS_SCRIPT_DIR}/git_network_guard.sh"
fi

resolve_origin_default_branch() {
  local repo_path="$1"
  local ref=""
  local branch=""
  local symref_output=""

  ref="$(git -C "${repo_path}" symbolic-ref \
    --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "${ref}" ]; then
    symref_output="$(git_network_guard_run "${repo_path}" \
      ls-remote --symref origin HEAD)" || return
    branch="$(awk '$1 == "ref:" && $3 == "HEAD" {
      sub(/^refs\/heads\//, "", $2)
      print $2
      exit
    }' <<<"${symref_output}")"
    [ -n "${branch}" ] || return 1
    git check-ref-format --branch "${branch}" >/dev/null \
      || return 1
    git -C "${repo_path}" symbolic-ref \
      refs/remotes/origin/HEAD "refs/remotes/origin/${branch}" || return
    ref="origin/${branch}"
  fi

  case "${ref}" in
    origin/*) branch="${ref#origin/}" ;;
    *) branch="${ref}" ;;
  esac

  [ -n "${branch}" ] || return 1
  git check-ref-format --branch "${branch}" >/dev/null \
    || return 1
  printf '%s\n' "${branch}"
}
