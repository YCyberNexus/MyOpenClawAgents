#!/usr/bin/env bash
# Analyse an inbound 114 requirement enough to build downstream messages.
#
# This helper does not touch GitLab and does not decide executor routing. It
# only removes transport wrappers, requires an explicit <group>/<project>, and
# prepares the text req_dispatcher should send to git_issuer.
set -euo pipefail

MESSAGE="${MESSAGE:-}"
MESSAGE_FILE="${MESSAGE_FILE:-}"

if [ -n "${MESSAGE_FILE}" ]; then
  if [ ! -f "${MESSAGE_FILE}" ]; then
    echo "prepare_downstream_payloads: MESSAGE_FILE not found: ${MESSAGE_FILE}" >&2
    exit 2
  fi
  MESSAGE="$(cat "${MESSAGE_FILE}")"
elif [ -z "${MESSAGE}" ]; then
  MESSAGE="$(cat)"
fi

emit_json() {
  local status="$1"
  local project="$2"
  local requirement_text="$3"
  local git_issuer_payload="$4"
  local reason="$5"
  jq -nc \
    --arg status "${status}" \
    --arg project "${project}" \
    --arg requirement_text "${requirement_text}" \
    --arg git_issuer_payload "${git_issuer_payload}" \
    --arg reason "${reason}" '
    {
      status: $status,
      project: (if $project == "" then null else $project end),
      requirement_text: (if $requirement_text == "" then null else $requirement_text end),
      git_issuer_payload: (if $git_issuer_payload == "" then null else $git_issuer_payload end),
      reason: (if $reason == "" then null else $reason end)
    }'
}

url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

extract_project() {
  local text="$1"
  local candidate=""

  candidate="$(
    printf '%s\n' "${text}" | awk '
      match($0, /projects\/[A-Za-z0-9_.~%+-]+%2[Ff][A-Za-z0-9_.~%+-]+/) {
        value = substr($0, RSTART + length("projects/"), RLENGTH - length("projects/"))
        sub(/\/.*/, "", value)
        print value
        exit
      }'
  )"
  if [ -n "${candidate}" ]; then
    url_decode "${candidate}"
    return 0
  fi

  candidate="$(
    printf '%s\n' "${text}" | awk -v configured_host="${GITLAB_HOST:-${WIKI_GITLAB_HOST:-}}" '
      function is_gitlab_host(host, configured_host, host_lc) {
        if (configured_host != "" && host == configured_host) return 1
        host_lc = tolower(host)
        return host_lc ~ /(^|[.-])gitlab([.-]|$)/
      }
      {
        line = $0
        while (match(line, /https?:\/\/[^[:space:]）)，]+/)) {
          url = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          sub(/[?#].*/, "", url)
          sub(/[。.!！]+$/, "", url)
          without_scheme = url
          sub(/^https?:\/\//, "", without_scheme)
          host = without_scheme
          sub(/\/.*/, "", host)
          path = without_scheme
          if (path !~ /\//) continue
          sub(/^[^\/]+\//, "", path)
          if (!is_gitlab_host(host, configured_host) && path !~ /^[^\/]+\/[^\/]+\/-\//) continue
          sub(/\/-\/.*/, "", path)
          n = split(path, parts, "/")
          if (n >= 2 && parts[1] != "" && parts[2] != "") {
            print parts[1] "/" parts[2]
            exit
          }
        }
      }'
  )"
  if [ -n "${candidate}" ]; then
    url_decode "${candidate}"
    return 0
  fi

  printf '%s\n' "${text}" | awk '
    {
      line = $0
      gsub(/https?:\/\/[^[:space:]）)，]+/, " ", line)
    }
    match(line, /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) {
      print substr(line, RSTART, RLENGTH)
      exit
    }'
}

if [ -z "${MESSAGE}" ]; then
  emit_json failed "" "" "" "需求文本为空"
  exit 0
fi

NORMALIZED="$(
  printf '%s\n' "${MESSAGE}" | tr -d '\r' | awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = trim($0)
      if (line == "") next
      if (line ~ /^\[origin\][[:space:]]/) next
      if (line ~ /^origin=\{/) next
      sub(/^\[[^]]*来自114[^]]*\][[:space:]]*/, "", line)
      sub(/^【[^】]*来自114[^】]*】[[:space:]]*/, "", line)
      sub(/^来自114[[:space:]]*/, "", line)
      sub(/^用户[^：:[:space:]]+[[:space:]]*请求[：:][[:space:]]*/, "", line)
      line = trim(line)
      if (line != "") print line
    }'
)"

NORMALIZED="$(
  printf '%s\n' "${NORMALIZED}" | sed -E 's/[[:space:]]*(请)?(处理)?完成后回复[。.!！]*[[:space:]]*$//'
)"

if [ -z "${NORMALIZED}" ]; then
  emit_json failed "" "" "" "需求正文为空"
  exit 0
fi

PROJECT="$(extract_project "${NORMALIZED}")"

if [ -z "${PROJECT}" ]; then
  emit_json failed "" "${NORMALIZED}" "" "需求文本未包含可识别的 GitLab project（格式 group/project），请补充目标 group/project 或具体 GitLab/Wiki URL"
  exit 0
fi

case "${PROJECT}" in
  */*) ;;
  *)
    emit_json failed "" "${NORMALIZED}" "" "GitLab project 必须是 group/project 格式"
    exit 0
    ;;
esac

NORMALIZED="$(
  printf '%s\n' "${NORMALIZED}" | awk -v project="${PROJECT}" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = $0
      project_pos = index(line, project)
      if (project_pos > 0) {
        before_project = substr(line, 1, project_pos - 1)
        if (before_project ~ /^[[:space:]]*(请)?[[:space:]]*(在)?[[:space:]]*(GitLab|repo=)?[[:space:]]*$/) {
          line = substr(line, project_pos + length(project))
        }
      }
      sub(/^[[:space:]]*(中|里|上|下|项目)?[[:space:]]*/, "", line)
      sub(/^(处理|实现|完成)[[:space:]]*[：:][[:space:]]*/, "", line)
      line = trim(line)
      if (line != "") print line
    }'
)"

if [ -z "${NORMALIZED}" ]; then
  emit_json failed "" "" "" "需求正文为空"
  exit 0
fi

GIT_ISSUER_PAYLOAD="$(cat <<EOF
CREATE_GITLAB_ISSUE
repo=${PROJECT}
source=req_dispatcher

请根据下面的需求创建一个 GitLab issue；不要反问 repo，repo 已在上方给出。
只负责创建或变更 issue，不要调用 req_executor，不要回复企微用户。
完成后最后一行输出 req_dispatcher 契约 JSON。

需求正文：
${NORMALIZED}
EOF
)"

emit_json success "${PROJECT}" "${NORMALIZED}" "${GIT_ISSUER_PAYLOAD}" ""
