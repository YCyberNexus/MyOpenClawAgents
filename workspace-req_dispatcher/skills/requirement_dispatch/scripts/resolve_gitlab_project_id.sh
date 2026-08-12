#!/usr/bin/env bash
# Resolve one numeric GitLab project ID to its canonical path_with_namespace.
# This helper performs exactly one read-only GET through `glab api projects/<id>`.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-}"
PROJECT_HOST="${PROJECT_HOST:-}"
GLAB_BIN="${GLAB_BIN:-${WIKI_GLAB_BIN:-glab}}"

emit_failure() {
  local reason="$1"
  jq -nc \
    --arg project_id "${PROJECT_ID}" \
    --arg reason "${reason}" '
    {
      status: "failed",
      project_id: (if $project_id | test("^[1-9][0-9]*$") then ($project_id | tonumber) else null end),
      project: null,
      gitlab_host: null,
      reason: $reason
    }'
  exit 0
}

emit_success() {
  local project="$1"
  local gitlab_host="$2"
  jq -nc \
    --argjson project_id "${PROJECT_ID}" \
    --arg project "${project}" \
    --arg gitlab_host "${gitlab_host}" '
    {
      status: "success",
      project_id: $project_id,
      project: $project,
      gitlab_host: $gitlab_host,
      reason: null
    }'
}

canonicalize_host() {
  local value="$1"
  local port=""

  value="${value#http://}"
  value="${value#https://}"
  case "${value}" in
    ""|*/*|*\?*|*\#*|*@*|*[[:space:]]*) return 1 ;;
  esac
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]] || return 1
  if [[ "${value}" == *:* ]]; then
    port="${value##*:}"
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
      return 1
    fi
  fi
  printf '%s\n' "${value}" | tr '[:upper:]' '[:lower:]'
}

validate_project_path() {
  local project="$1"
  local segment=""
  local -a segments=()

  case "${project}" in
    ""|/*|*/|*//*|*[[:space:]]*) return 1 ;;
  esac
  [[ "${project}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || return 1
  IFS='/' read -r -a segments <<<"${project}"
  for segment in "${segments[@]}"; do
    case "${segment}" in
      .|..) return 1 ;;
    esac
  done
  return 0
}

[[ "${PROJECT_ID}" =~ ^[1-9][0-9]*$ ]] \
  || emit_failure "GitLab project ID 必须是正整数"

GENERIC_TUPLE_PRESENT=false
GENERIC_HOST=""
if [ -n "${GITLAB_HOST:-}" ] \
    || [ -n "${GITLAB_API_PROTOCOL:-}" ] \
    || [ -n "${GITLAB_TOKEN:-}" ]; then
  GENERIC_TUPLE_PRESENT=true
  if [ -z "${GITLAB_HOST:-}" ] \
      || [ -z "${GITLAB_API_PROTOCOL:-}" ] \
      || [ -z "${GITLAB_TOKEN:-}" ]; then
    emit_failure "通用 GitLab 只读凭据配置不完整"
  fi
  case "${GITLAB_API_PROTOCOL}" in
    http|https) ;;
    *) emit_failure "GITLAB_API_PROTOCOL 必须是 http 或 https" ;;
  esac
  if ! GENERIC_HOST="$(canonicalize_host "${GITLAB_HOST}")"; then
    emit_failure "GITLAB_HOST 必须是合法的 host[:port]"
  fi
fi

WIKI_TUPLE_PRESENT=false
WIKI_HOST=""
if [ -n "${WIKI_GITLAB_HOST:-}" ] \
    || [ -n "${WIKI_GITLAB_API_PROTOCOL:-}" ] \
    || [ -n "${WIKI_GITLAB_TOKEN:-}" ]; then
  WIKI_TUPLE_PRESENT=true
  if [ -z "${WIKI_GITLAB_HOST:-}" ] \
      || [ -z "${WIKI_GITLAB_API_PROTOCOL:-}" ] \
      || [ -z "${WIKI_GITLAB_TOKEN:-}" ]; then
    emit_failure "GitLab 只读凭据配置不完整"
  fi
  case "${WIKI_GITLAB_API_PROTOCOL}" in
    http|https) ;;
    *) emit_failure "WIKI_GITLAB_API_PROTOCOL 必须是 http 或 https" ;;
  esac
  if ! WIKI_HOST="$(canonicalize_host "${WIKI_GITLAB_HOST}")"; then
    emit_failure "WIKI_GITLAB_HOST 必须是合法的 host[:port]"
  fi
fi

if [ "${GENERIC_TUPLE_PRESENT}" = false ] && [ "${WIKI_TUPLE_PRESENT}" = false ]; then
  emit_failure "未配置可用于解析 GitLab project ID 的只读凭据"
fi

EXPLICIT_HOST=""
if [ -n "${PROJECT_HOST}" ]; then
  if ! EXPLICIT_HOST="$(canonicalize_host "${PROJECT_HOST}")"; then
    emit_failure "提示词中的 GitLab host 不是合法的 host[:port]"
  fi
fi

SELECTED_HOST=""
SELECTED_PROTOCOL=""
SELECTED_TOKEN=""
if [ -n "${EXPLICIT_HOST}" ]; then
  if [ "${WIKI_TUPLE_PRESENT}" = true ] && [ "${EXPLICIT_HOST}" = "${WIKI_HOST}" ]; then
    SELECTED_HOST="${WIKI_GITLAB_HOST}"
    SELECTED_PROTOCOL="${WIKI_GITLAB_API_PROTOCOL}"
    SELECTED_TOKEN="${WIKI_GITLAB_TOKEN}"
  elif [ "${GENERIC_TUPLE_PRESENT}" = true ] && [ "${EXPLICIT_HOST}" = "${GENERIC_HOST}" ]; then
    SELECTED_HOST="${GITLAB_HOST}"
    SELECTED_PROTOCOL="${GITLAB_API_PROTOCOL}"
    SELECTED_TOKEN="${GITLAB_TOKEN}"
  else
    emit_failure "提示词中的 GitLab host 与已配置实例不一致"
  fi
elif [ "${GENERIC_TUPLE_PRESENT}" = true ] \
    && [ "${WIKI_TUPLE_PRESENT}" = true ] \
    && [ "${GENERIC_HOST}" != "${WIKI_HOST}" ]; then
  emit_failure "配置了多个 GitLab 实例；使用 project ID 时必须同时明确 GitLab host"
elif [ "${WIKI_TUPLE_PRESENT}" = true ]; then
  SELECTED_HOST="${WIKI_GITLAB_HOST}"
  SELECTED_PROTOCOL="${WIKI_GITLAB_API_PROTOCOL}"
  SELECTED_TOKEN="${WIKI_GITLAB_TOKEN}"
else
  SELECTED_HOST="${GITLAB_HOST}"
  SELECTED_PROTOCOL="${GITLAB_API_PROTOCOL}"
  SELECTED_TOKEN="${GITLAB_TOKEN}"
fi

if ! command -v "${GLAB_BIN}" >/dev/null 2>&1; then
  emit_failure "找不到用于解析 GitLab project ID 的 glab 可执行文件"
fi

LOOKUP_JSON=""
if LOOKUP_JSON="$(
  GITLAB_HOST="${SELECTED_HOST}" \
  GITLAB_API_PROTOCOL="${SELECTED_PROTOCOL}" \
  GITLAB_TOKEN="${SELECTED_TOKEN}" \
    "${GLAB_BIN}" api "projects/${PROJECT_ID}" 2>/dev/null
)"; then
  :
else
  emit_failure "GitLab project ID 查询失败或当前只读凭据无权访问该项目"
fi

PROJECT=""
if PROJECT="$(
  jq -er --argjson expected_id "${PROJECT_ID}" '
    if ((type == "object")
      and ((.id | type) == "number")
      and (.id == $expected_id)
      and ((.path_with_namespace | type) == "string")
      and ((.path_with_namespace | length) > 0))
    then .path_with_namespace
    else empty
    end
  ' <<<"${LOOKUP_JSON}" 2>/dev/null
)"; then
  :
else
  emit_failure "GitLab project ID 查询返回了不匹配或不完整的项目身份"
fi

validate_project_path "${PROJECT}" \
  || emit_failure "GitLab project ID 查询返回了不安全的 path_with_namespace"

SELECTED_CANONICAL_HOST="$(canonicalize_host "${SELECTED_HOST}")"
emit_success "${PROJECT}" "${SELECTED_CANONICAL_HOST}"
