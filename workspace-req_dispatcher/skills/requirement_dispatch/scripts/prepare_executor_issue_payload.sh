#!/usr/bin/env bash
# Prepare an existing GitLab issue execution request for req_executor.
#
# This helper does not call req_executor. It only strips transport wrappers,
# extracts project/iid/branch from explicit issue locators, and returns the
# normalized facts the orchestrator should route and enqueue.
set -euo pipefail

MESSAGE="${MESSAGE:-}"
MESSAGE_FILE="${MESSAGE_FILE:-}"

if [ -n "${MESSAGE_FILE}" ]; then
  if [ ! -f "${MESSAGE_FILE}" ]; then
    echo "prepare_executor_issue_payload: MESSAGE_FILE not found: ${MESSAGE_FILE}" >&2
    exit 2
  fi
  MESSAGE="$(cat "${MESSAGE_FILE}")"
elif [ -z "${MESSAGE}" ]; then
  MESSAGE="$(cat)"
fi

emit_json() {
  local status="$1"
  local project="$2"
  local iid="$3"
  local target_branch="$4"
  local issue_url="$5"
  local request_text="$6"
  local reason="$7"
  local selector="${8:-null}"
  local force_rerun_pr="${9:-false}"

  if [ "${selector}" = "null" ] && [ -n "${iid}" ]; then
    selector="$(jq -nc --arg iid "${iid}" '{type:"single",iid:($iid | tonumber)}')"
  fi

  jq -nc \
    --arg status "${status}" \
    --arg project "${project}" \
    --argjson selector "${selector}" \
    --argjson force_rerun_pr "${force_rerun_pr}" \
    --arg target_branch "${target_branch}" \
    --arg issue_url "${issue_url}" \
    --arg request_text "${request_text}" \
    --arg reason "${reason}" '
    {
      status: $status,
      project: (if $project == "" then null else $project end),
      iid: (if $selector.type == "single" then $selector.iid else null end),
      selector: $selector,
      force_rerun_pr: $force_rerun_pr,
      target_branch: (if $target_branch == "" then null else $target_branch end),
      issue_url: (if $issue_url == "" then null else $issue_url end),
      request_text: (if $request_text == "" then null else $request_text end),
      reason: (if $reason == "" then null else $reason end)
    }'
}

url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

url_decode_path_component() {
  local value="$1"
  local rest="$1"
  local hex=""

  while [[ "${rest}" == *%* ]]; do
    rest="${rest#*%}"
    if [ "${#rest}" -lt 2 ]; then
      return 1
    fi
    hex="${rest:0:2}"
    case "${hex}" in
      [0-9A-Fa-f][0-9A-Fa-f]) ;;
      *) return 1 ;;
    esac
    rest="${rest:2}"
  done

  printf '%b' "${value//%/\\x}"
}

validate_project_path() {
  local project="$1"
  case "${project}" in
    ""|/*|*/|*//*|*[[:space:]]*) return 1 ;;
  esac
  [[ "${project}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]
}

normalize_issue_url() {
  local url="$1"
  local last=""
  url="${url%%\#*}"
  url="${url%%\?*}"
  while [ -n "${url}" ]; do
    last="${url: -1}"
    case "${last}" in
      "。"|"."|"!"|"！"|","|"，"|";"|"；") url="${url%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "${url}"
}

extract_issue_url() {
  local text="$1"
  local url=""
  url="$(
    printf '%s\n' "${text}" | awk '
      {
        line = $0
        while (match(line, /https?:\/\/[^[:space:]）)，]+/)) {
          candidate = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          if (candidate ~ /\/-\/issues\/[0-9]+([\/?#.,，。!！;；)]|$)/ || candidate ~ /\/-\/issues\/[0-9]+$/) {
            print candidate
            exit
          }
        }
      }'
  )"
  if [ -n "${url}" ]; then
    normalize_issue_url "${url}"
  fi
}

parse_issue_url() {
  local url="$1"
  local after_scheme=""
  local url_host=""
  local url_host_lc=""
  local url_path=""
  local project_raw=""
  local issue_part=""
  local decoded_project=""

  url="$(normalize_issue_url "${url}")"
  PARSE_ISSUE_URL_ERROR="issue_url must be a GitLab issue URL containing /-/issues/<iid>"
  case "${url}" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  after_scheme="${url#*://}"
  url_host="${after_scheme%%/*}"
  url_host_lc="$(printf '%s' "${url_host}" | tr '[:upper:]' '[:lower:]')"
  case "${url_host_lc}" in
    *gitlab*) ;;
    *)
      PARSE_ISSUE_URL_ERROR="GitLab host must contain gitlab"
      return 1
      ;;
  esac
  url_path="${after_scheme#*/}"
  case "${url_path}" in
    */-/issues/*) ;;
    *) return 1 ;;
  esac

  project_raw="${url_path%%/-/issues/*}"
  issue_part="${url_path#*/-/issues/}"
  issue_part="${issue_part%%/*}"
  case "${issue_part}" in
    *[!0-9]*|""|0) return 1 ;;
  esac

  if ! decoded_project="$(url_decode_path_component "${project_raw}")"; then
    PARSE_ISSUE_URL_ERROR="GitLab project path in issue_url contains malformed percent encoding"
    return 1
  fi
  if ! validate_project_path "${decoded_project}"; then
    PARSE_ISSUE_URL_ERROR="GitLab project path in issue_url contains unsafe characters"
    return 1
  fi

  PARSED_ISSUE_URL="${url}"
  PARSED_PROJECT="${decoded_project}"
  PARSED_IID="${issue_part}"

  return 0
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
          sub(/[。.!！,，;；]+$/, "", url)
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

extract_iid() {
  local text="$1"
  printf '%s\n' "${text}" | awk '
    {
      line = $0
      lower = tolower(line)
      if (match(lower, /(issue|iid|issue_iid)[[:space:]#:_-]*[0-9]+/)) {
        value = substr(line, RSTART, RLENGTH)
        if (match(value, /[0-9]+/)) {
          print substr(value, RSTART, RLENGTH)
          exit
        }
      }
      if (match(line, /#[0-9]+/)) {
        value = substr(line, RSTART + 1, RLENGTH - 1)
        print value
        exit
      }
    }'
}

extract_iid_range() {
  local text="$1"
  local range_pattern='#?([0-9]+)[[:space:]]*(到|至)[[:space:]]*#?([0-9]+)'

  RANGE_IID_MIN=""
  RANGE_IID_MAX=""
  if [[ "${text}" =~ ${range_pattern} ]]; then
    RANGE_IID_MIN="${BASH_REMATCH[1]}"
    RANGE_IID_MAX="${BASH_REMATCH[3]}"
  fi
}

extract_open_label() {
  local text="$1"
  printf '%s\n' "${text}" | awk '
    function trim(value) {
      gsub(/^[[:space:]"'\''`“”‘’]+/, "", value)
      gsub(/[[:space:]"'\''`“”‘’，,。;；]+$/, "", value)
      return value
    }
    {
      line = $0
      if (match(line, /(label|标签)[[:space:]]*(为|是|[:=：])[[:space:]]*/)) {
        value = substr(line, RSTART + RLENGTH)
        sub(/[[:space:]]+(的[[:space:]]*)?([Ii]ssue|[Ii]ssues).*$/, "", value)
        value = trim(value)
        if (value != "") {
          print value
          exit
        }
      }
    }'
}

has_explicit_rerun_action() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function strip_label_selector_value(line, prefix, rest) {
      if (!match(line, /(label|标签)[[:space:]]*(为|是|[:=：])[[:space:]]*/)) {
        return line
      }

      prefix = substr(line, 1, RSTART + RLENGTH - 1)
      rest = substr(line, RSTART + RLENGTH)
      if (match(rest, /[[:space:]]+(的[[:space:]]*)?([Ii]ssue|[Ii]ssues)([[:space:]，,。;；]|$)/)) {
        return prefix substr(rest, RSTART)
      }

      sub(/^[^[:space:]，,。;；]+/, "", rest)
      return prefix rest
    }
    function is_positive_action(segment) {
      segment = trim(segment)
      if (segment ~ /^(重跑|重新处理|重新执行)/) {
        return 1
      }
      if (segment ~ /(^|[[:space:]])(请|需要)[[:space:]]*(重跑|重新处理|重新执行)/) {
        return 1
      }
      return 0
    }
    {
      line = strip_label_selector_value($0)
      segment_count = split(line, segments, /[，,。；;：:！!？?]/)
      for (segment_index = 1; segment_index <= segment_count; segment_index++) {
        if (is_positive_action(segments[segment_index])) {
          found = 1
          exit
        }
      }
    }
    END {
      exit(found ? 0 : 1)
    }'
}

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
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
    function emit_explicit(rest, candidate, tail, trimmed_tail) {
      gsub(/^[[:space:]"'\''`“”‘’]+/, "", rest)
      if (match(rest, /^[A-Za-z0-9._\/-]+/)) {
        candidate = substr(rest, RSTART, RLENGTH)
        tail = substr(rest, RLENGTH + 1)
        trimmed_tail = tail
        gsub(/^[[:space:]"'\''`“”‘’]+/, "", trimmed_tail)
        if (trimmed_tail != "" && trimmed_tail !~ /^[，,。)）]/) {
          candidate = candidate tail
        }
      } else {
        candidate = rest
      }
      emit(candidate)
    }
    {
      line = $0
      if (match(line, /(mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch|branch)[[:space:]]*[:=][[:space:]]*/)) {
        emit_explicit(substr(line, RSTART + RLENGTH))
        exit
      }
      if (match(line, /(目标分支|分支)[[:space:]]*[：:=][[:space:]]*/)) {
        emit_explicit(substr(line, RSTART + RLENGTH))
        exit
      }
      if (match(line, /(合并到|合到|merge[[:space:]]+to)[[:space:]]*/)) {
        emit_explicit(substr(line, RSTART + RLENGTH))
        exit
      }
      normalized = line
      gsub(/["'\''`“”‘’]/, "", normalized)
      if (match(normalized, /(基于|从|以)[[:space:]]*[A-Za-z0-9._\/-]+[[:space:]]*(分支|branch)/)) {
        value = substr(normalized, RSTART, RLENGTH)
        sub(/^(基于|从|以)[[:space:]]*/, "", value)
        sub(/[[:space:]]*(分支|branch).*$/, "", value)
        emit(value)
        exit
      }
    }'
}

strip_target_branch_directive() {
  local text="$1"
  printf '%s\n' "${text}" | awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = $0
      gsub(/[[:space:]]*(mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch|branch)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._\/-]+[[:space:]]*[，,;；]?/, " ", line)
      gsub(/[[:space:]]*(目标分支|分支)[[:space:]]*[：:=][[:space:]]*[A-Za-z0-9._\/-]+[[:space:]]*[，,;；]?/, " ", line)
      gsub(/[[:space:]]*(合并到|合到|merge[[:space:]]+to)[[:space:]]*[A-Za-z0-9._\/-]+[[:space:]]*[，,;；]?/, " ", line)
      gsub(/[[:space:]]*(请)?[[:space:]]*(基于|从|以)[[:space:]]*["'\''`“”‘’]?[A-Za-z0-9._\/-]+["'\''`“”‘’]?[[:space:]]*(分支|branch)[[:space:]]*(开发|处理|执行|实现|修改|修复)?[[:space:]]*[，,;；]?/, " ", line)
      line = trim(line)
      if (line != "") print line
    }'
}

if [ -z "${MESSAGE}" ]; then
  emit_json failed "" "" "" "" "" "请求文本为空"
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

if [ -z "${NORMALIZED}" ]; then
  emit_json failed "" "" "" "" "" "请求正文为空"
  exit 0
fi

TARGET_BRANCH="$(extract_target_branch "${NORMALIZED}")"
if [ -n "${TARGET_BRANCH}" ] && ! validate_branch_name "${TARGET_BRANCH}"; then
  emit_json failed "" "" "" "" "${NORMALIZED}" "branch must be a safe Git ref name"
  exit 0
fi

PROJECT_SOURCE="${NORMALIZED}"
if [ -n "${TARGET_BRANCH}" ]; then
  PROJECT_SOURCE="$(strip_target_branch_directive "${NORMALIZED}")"
fi

PARSED_ISSUE_URL=""
PARSED_PROJECT=""
PARSED_IID=""
FORCE_RERUN_PR=false
if has_explicit_rerun_action "${PROJECT_SOURCE}"; then
  FORCE_RERUN_PR=true
fi

ISSUE_URL="$(extract_issue_url "${PROJECT_SOURCE}")"
if [ -n "${ISSUE_URL}" ]; then
  if ! parse_issue_url "${ISSUE_URL}"; then
    emit_json failed "" "" "${TARGET_BRANCH}" "" "${NORMALIZED}" "${PARSE_ISSUE_URL_ERROR:-issue_url must be a GitLab issue URL containing /-/issues/<iid>}"
    exit 0
  fi
fi

PROJECT="${PARSED_PROJECT:-}"
IID="${PARSED_IID:-}"
SELECTOR_JSON="null"
SELECTOR_ERROR=""

if [ -z "${PROJECT}" ]; then
  PROJECT="$(extract_project "${PROJECT_SOURCE}")"
fi

if [ -n "${IID}" ]; then
  SELECTOR_JSON="$(jq -nc --arg iid "${IID}" '{type:"single",iid:($iid | tonumber)}')"
else
  extract_iid_range "${PROJECT_SOURCE}"
  if [ -n "${RANGE_IID_MIN}" ]; then
    if [ "${RANGE_IID_MIN}" -gt "${RANGE_IID_MAX}" ]; then
      SELECTOR_ERROR="issue IID 范围必须满足 iid_min <= iid_max"
    else
      SELECTOR_JSON="$(
        jq -nc \
          --arg iid_min "${RANGE_IID_MIN}" \
          --arg iid_max "${RANGE_IID_MAX}" \
          '{type:"range",iid_min:($iid_min | tonumber),iid_max:($iid_max | tonumber)}'
      )"
    fi
  else
    OPEN_LABEL="$(extract_open_label "${PROJECT_SOURCE}")"
    if [ -n "${OPEN_LABEL}" ]; then
      SELECTOR_JSON="$(jq -nc --arg label "${OPEN_LABEL}" '{type:"open_label",label:$label}')"
    elif [[ "${PROJECT_SOURCE}" == *未完成* ]] && [[ "${PROJECT_SOURCE}" == *issue* || "${PROJECT_SOURCE}" == *Issue* ]]; then
      SELECTOR_JSON='{"type":"open_unfinished"}'
    else
      IID="$(extract_iid "${PROJECT_SOURCE}")"
      if [ -n "${IID}" ]; then
        SELECTOR_JSON="$(jq -nc --arg iid "${IID}" '{type:"single",iid:($iid | tonumber)}')"
      fi
    fi
  fi
fi

if [ -z "${PROJECT}" ]; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "处理 issue 需要明确 GitLab project（格式 group/project）或具体 GitLab issue URL" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
  exit 0
fi

case "${PROJECT}" in
  */*) ;;
  *)
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project 必须是 group/project 格式" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
    ;;
esac
if ! validate_project_path "${PROJECT}"; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project path contains unsafe characters" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
  exit 0
fi

if [ -n "${SELECTOR_ERROR}" ]; then
  emit_json failed "${PROJECT}" "" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "${SELECTOR_ERROR}" null "${FORCE_RERUN_PR}"
  exit 0
fi

if [ "${SELECTOR_JSON}" = "null" ]; then
  emit_json failed "${PROJECT}" "" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "处理 issue 需要明确 issue IID、IID 范围、未完成选择器、label 选择器或具体 GitLab issue URL" null "${FORCE_RERUN_PR}"
  exit 0
fi

if [ "$(jq -r '.type' <<<"${SELECTOR_JSON}")" = "single" ]; then
  case "${IID}" in
    *[!0-9]*|""|0)
      emit_json failed "${PROJECT}" "" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "issue IID 必须是正整数" null "${FORCE_RERUN_PR}"
      exit 0
      ;;
  esac
fi

emit_json success "${PROJECT}" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
