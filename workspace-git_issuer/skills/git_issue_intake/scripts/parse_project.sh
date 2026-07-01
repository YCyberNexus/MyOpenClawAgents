#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ROUTING_FILE="${ROUTING_FILE:-${WORKSPACE_ROOT}/config/project_routing.env}"
REQUIREMENT_TEXT="${REQUIREMENT_TEXT:-}"

emit_parse_json() {
  local status="$1"
  local project="$2"
  local group="$3"
  local slug="$4"
  local matched="$5"
  local reason="$6"
  jq -cn \
    --arg status "${status}" \
    --arg project "${project}" \
    --arg group "${group}" \
    --arg slug "${slug}" \
    --arg matched "${matched}" \
    --arg reason "${reason}" '
    {
      status: $status,
      project: (if $project == "" then null else $project end),
      group: (if $group == "" then null else $group end),
      project_slug: (if $slug == "" then null else $slug end),
      matched: (if $matched == "" then null else $matched end),
      reason: (if $reason == "" then null else $reason end)
    }'
}

if [ -z "${REQUIREMENT_TEXT}" ]; then
  emit_parse_json failed "" "" "" "" "REQUIREMENT_TEXT is required"
  exit 2
fi

if [ ! -f "${ROUTING_FILE}" ]; then
  emit_parse_json failed "" "" "" "" "project routing file not found: ${ROUTING_FILE}"
  exit 2
fi

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

matches_text() {
  local needle="$1"
  [ -n "${needle}" ] || return 1
  case "${REQUIREMENT_TEXT}" in
    *"${needle}"*) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
  line="$(trim "${raw_line}")"
  [ -n "${line}" ] || continue
  case "${line}" in
    \#*) continue ;;
  esac

  case "${line}" in
    *"|"*) ;;
    *)
      emit_parse_json failed "" "" "" "" "project routing line malformed: ${line}"
      exit 2
      ;;
  esac

  project_full="$(trim "${line%%|*}")"
  aliases_csv="$(trim "${line#*|}")"
  if [ -z "${project_full}" ]; then
    emit_parse_json failed "" "" "" "" "project routing line has empty project: ${line}"
    exit 2
  fi
  case "${project_full}" in
    */*) ;;
    *)
      emit_parse_json failed "" "" "" "" "project routing project must be <group>/<project>: ${project_full}"
      exit 2
      ;;
  esac

  group="${project_full%/*}"
  slug="${project_full##*/}"

  if matches_text "${project_full}"; then
    emit_parse_json success "${project_full}" "${group}" "${slug}" "${project_full}" ""
    exit 0
  fi
  if matches_text "${slug}"; then
    emit_parse_json success "${project_full}" "${group}" "${slug}" "${slug}" ""
    exit 0
  fi

  IFS=',' read -r -a aliases <<<"${aliases_csv}"
  for alias in "${aliases[@]}"; do
    alias="$(trim "${alias}")"
    if matches_text "${alias}"; then
      emit_parse_json success "${project_full}" "${group}" "${slug}" "${alias}" ""
      exit 0
    fi
  done
done <"${ROUTING_FILE}"

emit_parse_json failed "" "" "" "" "无法从需求文本解析出目标 project"
