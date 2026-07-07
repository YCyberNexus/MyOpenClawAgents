#!/usr/bin/env bash
# Shared branch resolution helpers. Source this file from wrapper scripts.

resolve_origin_default_branch() {
  local repo_path="$1"
  local ref=""
  local branch=""

  ref="$(git -C "${repo_path}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "${ref}" ]; then
    git -C "${repo_path}" remote set-head origin --auto >/dev/null 2>&1 || true
    ref="$(git -C "${repo_path}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  fi

  case "${ref}" in
    origin/*) branch="${ref#origin/}" ;;
    *) branch="${ref}" ;;
  esac

  [ -n "${branch}" ] || return 1
  printf '%s\n' "${branch}"
}
