#!/usr/bin/env bash
# Prepare git_issuer payloads from a GitLab wiki URL and wiki Markdown content.
set -euo pipefail

MESSAGE="${MESSAGE:-}"
MESSAGE_FILE="${MESSAGE_FILE:-}"
WIKI_CONTENT="${WIKI_CONTENT:-}"
FETCH_WIKI="${FETCH_WIKI:-0}"
GLAB_BIN="${GLAB_BIN:-${WIKI_GLAB_BIN:-glab}}"
GITLAB_HOST="${GITLAB_HOST:-${WIKI_GITLAB_HOST:-}}"
GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL:-${WIKI_GITLAB_API_PROTOCOL:-}}"
GITLAB_TOKEN="${GITLAB_TOKEN:-${WIKI_GITLAB_TOKEN:-}}"

if [ -n "${MESSAGE_FILE}" ]; then
  if [ ! -f "${MESSAGE_FILE}" ]; then
    echo "prepare_wiki_downstream_payloads: MESSAGE_FILE not found: ${MESSAGE_FILE}" >&2
    exit 2
  fi
  MESSAGE="$(cat "${MESSAGE_FILE}")"
elif [ -z "${MESSAGE}" ]; then
  MESSAGE="$(cat)"
fi

trim_one_line() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

trim_multiline() {
  awk '
    { lines[NR] = $0 }
    END {
      start = 1
      while (start <= NR && lines[start] ~ /^[[:space:]]*$/) start++
      end = NR
      while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
      for (i = start; i <= end; i++) print lines[i]
    }'
}

emit_json() {
  local status="$1"
  local project="$2"
  local target_branch="$3"
  local wiki_url="$4"
  local wiki_slug="$5"
  local requirements_json="$6"
  local payloads_json="$7"
  local reason="$8"
  jq -nc \
    --arg status "${status}" \
    --arg project "${project}" \
    --arg target_branch "${target_branch}" \
    --arg wiki_url "${wiki_url}" \
    --arg wiki_slug "${wiki_slug}" \
    --argjson requirements "${requirements_json}" \
    --argjson git_issuer_payloads "${payloads_json}" \
    --arg reason "${reason}" '
    {
      status: $status,
      project: (if $project == "" then null else $project end),
      target_branch: (if $target_branch == "" then null else $target_branch end),
      wiki_url: (if $wiki_url == "" then null else $wiki_url end),
      wiki_slug: (if $wiki_slug == "" then null else $wiki_slug end),
      requirements: $requirements,
      git_issuer_payloads: $git_issuer_payloads,
      reason: (if $reason == "" then null else $reason end)
    }'
}

fail_json() {
  emit_json failed "" "" "" "" "[]" "[]" "$1"
}

url_encode() {
  jq -nr --arg v "$1" '$v|@uri'
}

url_decode() {
  local v="${1//+/ }"
  printf '%b' "${v//%/\\x}"
}

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\[*|*\]*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ] || return 1
  return 0
}

extract_target_branch() {
  local text="$1"
  printf '%s\n' "${text}" | awk '
    function emit(value) {
      gsub(/^[[:space:]"'\''`“”‘’]+/, "", value)
      gsub(/[[:space:]"'\''`“”‘’)，,。;；]+$/, "", value)
      print value
    }
    {
      line = $0
      if (match(line, /(mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch|branch)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._\/-]+/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/^[^:=]*[:=][[:space:]]*/, "", value)
        emit(value)
        exit
      }
      if (match(line, /(目标分支|分支)[[:space:]]*[：:=][[:space:]]*[A-Za-z0-9._\/-]+/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/^.*[：:=][[:space:]]*/, "", value)
        emit(value)
        exit
      }
      if (match(line, /(合并到|合到|merge[[:space:]]+to)[[:space:]]*[A-Za-z0-9._\/-]+/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/^(合并到|合到|merge[[:space:]]+to)[[:space:]]*/, "", value)
        emit(value)
        exit
      }
    }'
}

if [ -z "${MESSAGE}" ]; then
  fail_json "需求文本为空"
  exit 0
fi

TARGET_BRANCH="$(extract_target_branch "${MESSAGE}")"
if [ -n "${TARGET_BRANCH}" ] && ! validate_branch_name "${TARGET_BRANCH}"; then
  fail_json "target branch must be a safe Git ref name"
  exit 0
fi

WIKI_URL="$(
  printf '%s\n' "${MESSAGE}" |
    awk '
      match($0, /https?:\/\/[^[:space:]]+\/-\/wikis\/[^[:space:]）)，]*/) {
        print substr($0, RSTART, RLENGTH)
        exit
      }'
)"

if [ -z "${WIKI_URL}" ]; then
  fail_json "消息中未包含可识别的 GitLab wiki URL"
  exit 0
fi

WIKI_URL="${WIKI_URL%%\#*}"
WIKI_URL="${WIKI_URL%%\?*}"
while [[ "${WIKI_URL}" =~ [。.!！]$ ]]; do
  WIKI_URL="${WIKI_URL%?}"
done
AFTER_SCHEME="${WIKI_URL#*://}"
URL_PATH="${AFTER_SCHEME#*/}"

case "${URL_PATH}" in
  */-/wikis/*) ;;
  *)
    fail_json "GitLab wiki URL 必须包含 /-/wikis/"
    exit 0
    ;;
esac

PROJECT_RAW="${URL_PATH%%/-/wikis/*}"
WIKI_SLUG_RAW="${URL_PATH#*/-/wikis/}"
PROJECT="$(url_decode "${PROJECT_RAW}")"
WIKI_SLUG="$(url_decode "${WIKI_SLUG_RAW}")"

if [ -z "${PROJECT}" ] || [ -z "${WIKI_SLUG}" ] || [ "${PROJECT}" = "${URL_PATH}" ]; then
  fail_json "无法从 GitLab wiki URL 解析 project 或 wiki slug"
  exit 0
fi

case "${PROJECT}" in
  */*) ;;
  *)
    fail_json "GitLab wiki URL 中的 project 必须是 group/project 格式"
    exit 0
    ;;
esac

case "${FETCH_WIKI}" in
  0|1|true|false) ;;
  *)
    fail_json "FETCH_WIKI must be 0 or 1"
    exit 0
    ;;
esac

if [ -z "${WIKI_CONTENT}" ] && { [ "${FETCH_WIKI}" = "1" ] || [ "${FETCH_WIKI}" = "true" ]; }; then
  if [ -z "${GITLAB_HOST}" ]; then
    fail_json "GITLAB_HOST is required when FETCH_WIKI=1"
    exit 0
  fi
  if [ -z "${GITLAB_API_PROTOCOL}" ]; then
    fail_json "GITLAB_API_PROTOCOL is required when FETCH_WIKI=1"
    exit 0
  fi
  if [ -z "${GITLAB_TOKEN}" ]; then
    fail_json "GITLAB_TOKEN is required when FETCH_WIKI=1"
    exit 0
  fi
  project_api="$(url_encode "${PROJECT}")"
  wiki_slug_api="$(url_encode "${WIKI_SLUG}")"
  api_path="projects/${project_api}/wikis/${wiki_slug_api}"
  set +e
  wiki_json="$(
    GITLAB_HOST="${GITLAB_HOST}" \
    GITLAB_TOKEN="${GITLAB_TOKEN}" \
    "${GLAB_BIN}" api "${api_path}" 2>&1
  )"
  glab_exit=$?
  set -e
  if [ "${glab_exit}" -ne 0 ]; then
    fail_json "wiki fetch failed: ${wiki_json}"
    exit 0
  fi
  if ! WIKI_CONTENT="$(printf '%s' "${wiki_json}" | jq -r '.content // empty' 2>/dev/null)"; then
    fail_json "wiki fetch response is not valid JSON"
    exit 0
  fi
fi

if [ -z "${WIKI_CONTENT}" ]; then
  fail_json "wiki content is required when WIKI_CONTENT is not provided and fetch is disabled"
  exit 0
fi

NORMALIZED_CONTENT="$(printf '%s\n' "${WIKI_CONTENT}" | tr -d '\r' | trim_multiline)"
if [ -z "${NORMALIZED_CONTENT}" ]; then
  fail_json "wiki content is empty"
  exit 0
fi

declare -a ITEM_TITLES=()
declare -a ITEM_BODIES=()

append_item() {
  local title="$1"
  local body="$2"
  title="$(trim_one_line "${title}")"
  body="$(printf '%s' "${body}" | trim_multiline)"
  if [ -z "${body}" ]; then
    return 0
  fi
  if is_metadata_title "${title}"; then
    return 0
  fi
  if [ -z "${title}" ]; then
    title="Wiki requirement $(( ${#ITEM_TITLES[@]} + 1 ))"
  fi
  ITEM_TITLES+=("${title}")
  ITEM_BODIES+=("${body}")
}

is_metadata_title() {
  local title="$1"
  local title_lower
  title_lower="$(printf '%s' "${title}" | tr '[:upper:]' '[:lower:]')"
  case "${title_lower}" in
    background|context|overview|introduction|intro|summary|toc|"table of contents"|metadata)
      return 0
      ;;
  esac
  case "${title}" in
    背景|上下文|概述|简介|摘要|目录|元数据)
      return 0
      ;;
  esac
  return 1
}

split_by_headings() {
  local current_title=""
  local current_body=""
  local line=""
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" =~ ^#{2,3}[[:space:]]+(.+)$ ]]; then
      if [ -n "${current_title}" ]; then
        append_item "${current_title}" "${current_body}"
      fi
      current_title="${BASH_REMATCH[1]}"
      current_body=""
    else
      if [ -n "${current_title}" ]; then
        current_body+="${line}"$'\n'
      fi
    fi
  done <<<"${NORMALIZED_CONTENT}"
  if [ -n "${current_title}" ]; then
    append_item "${current_title}" "${current_body}"
  fi
}

split_by_numbered_blocks() {
  local current_title=""
  local current_body=""
  local line=""
  local numbered_re='^[[:space:]]*([0-9]+[.)、]|需求[[:space:]]*[0-9一二三四五六七八九十]+[：:、.[:space:]])'
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" =~ ${numbered_re} ]]; then
      if [ -n "${current_body}" ]; then
        append_item "${current_title}" "${current_body}"
      fi
      current_title="$(trim_one_line "${line}")"
      current_body="$(trim_one_line "${line}")"$'\n'
    else
      if [ -n "${current_body}" ]; then
        current_body+="${line}"$'\n'
      fi
    fi
  done <<<"${NORMALIZED_CONTENT}"
  if [ -n "${current_body}" ]; then
    append_item "${current_title}" "${current_body}"
  fi
}

split_by_headings
if [ "${#ITEM_TITLES[@]}" -lt 2 ]; then
  ITEM_TITLES=()
  ITEM_BODIES=()
  split_by_numbered_blocks
fi
if [ "${#ITEM_TITLES[@]}" -lt 2 ]; then
  ITEM_TITLES=()
  ITEM_BODIES=()
  append_item "Wiki requirement 1" "${NORMALIZED_CONTENT}"
fi

if [ "${#ITEM_TITLES[@]}" -eq 0 ]; then
  fail_json "wiki content does not contain usable requirements"
  exit 0
fi

requirements_json="[]"
payloads_json="[]"
for idx in "${!ITEM_TITLES[@]}"; do
  ordinal="$((idx + 1))"
  title="${ITEM_TITLES[$idx]}"
  body="${ITEM_BODIES[$idx]}"
  item_json="$(
    jq -nc \
      --argjson ordinal "${ordinal}" \
      --arg title "${title}" \
      --arg body "${body}" \
      --arg wiki_url "${WIKI_URL}" \
      --arg wiki_section "${title}" \
      '{ordinal: $ordinal, title: $title, body: $body, wiki_url: $wiki_url, wiki_section: $wiki_section}'
  )"
  requirements_json="$(jq -c --argjson item "${item_json}" '. + [$item]' <<<"${requirements_json}")"

  payload="$(cat <<EOF
CREATE_GITLAB_ISSUE
repo=${PROJECT}
source=req_dispatcher_wiki
wiki_url=${WIKI_URL}
wiki_section=${title}
wiki_item_ordinal=${ordinal}

请根据下面的需求创建一个 GitLab issue；不要反问 repo，repo 已在上方给出。
只负责创建或变更 issue，不要调用 req_executor，不要回复企微用户。
完成后最后一行输出 req_dispatcher 契约 JSON。

需求正文：
${body}
EOF
)"
  payloads_json="$(jq -c --arg payload "${payload}" '. + [$payload]' <<<"${payloads_json}")"
done

emit_json success "${PROJECT}" "${TARGET_BRANCH}" "${WIKI_URL}" "${WIKI_SLUG}" "${requirements_json}" "${payloads_json}" ""
