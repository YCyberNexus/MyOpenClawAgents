#!/usr/bin/env bash
# Shared branch resolution helpers. Source this file from wrapper scripts.

resolve_origin_default_branch() {
  local repo_path="$1"
  local ref=""
  local branch=""
  local symref_output=""

  ref="$(git -C "${repo_path}" symbolic-ref \
    --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "${ref}" ]; then
    symref_output="$(cd "${repo_path}" \
      && git ls-remote --symref origin HEAD)" || return
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
