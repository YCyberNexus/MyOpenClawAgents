#!/usr/bin/env bash
# Prepare an existing GitLab issue execution request for req_executor.
#
# This helper does not call req_executor. It strips transport wrappers,
# resolves an explicit numeric project ID through one read-only GitLab identity
# lookup when needed, and returns the normalized facts to route and enqueue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# POSIX awk may report byte offsets under the C locale while substr() applies
# character offsets. Select an installed UTF-8 locale before parsing Chinese
# directives so a service process with an empty locale cannot corrupt values.
ensure_utf8_locale() {
  local charmap=""
  local candidate=""

  if command -v locale >/dev/null 2>&1; then
    charmap="$(locale charmap 2>/dev/null || true)"
    case "${charmap}" in
      UTF-8|UTF8|utf-8|utf8) return 0 ;;
    esac

    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 zh_CN.UTF-8 zh_CN.utf8; do
      charmap="$(LC_ALL="${candidate}" locale charmap 2>/dev/null || true)"
      case "${charmap}" in
        UTF-8|UTF8|utf-8|utf8)
          export LC_ALL="${candidate}"
          return 0
          ;;
      esac
    done
  fi

  echo "prepare_executor_issue_payload: a UTF-8 locale is required" >&2
  exit 2
}

ensure_utf8_locale
unset -f ensure_utf8_locale

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
  local auto_merge="${AUTO_MERGE:-false}"
  local merge_target_branch="${MERGE_TARGET_BRANCH:-}"

  if [ "${selector}" = "null" ] && [ -n "${iid}" ]; then
    selector="$(jq -nc --arg iid "${iid}" '{type:"single",iid:($iid | tonumber)}')"
  fi

  jq -nc \
    --arg status "${status}" \
    --arg project "${project}" \
    --argjson selector "${selector}" \
    --argjson force_rerun_pr "${force_rerun_pr}" \
    --argjson auto_merge "${auto_merge}" \
    --arg target_branch "${target_branch}" \
    --arg merge_target_branch "${merge_target_branch}" \
    --arg issue_url "${issue_url}" \
    --arg request_text "${request_text}" \
    --arg reason "${reason}" '
    {
      status: $status,
      project: (if $project == "" then null else $project end),
      iid: (if $selector.type == "single" then $selector.iid else null end),
      selector: $selector,
      force_rerun_pr: $force_rerun_pr,
      auto_merge: $auto_merge,
      target_branch: (if $target_branch == "" then null else $target_branch end),
      merge_target_branch: (if $merge_target_branch == "" then null else $merge_target_branch end),
      issue_url: (if $issue_url == "" then null else $issue_url end),
      request_text: (if $request_text == "" then null else $request_text end),
      reason: (if $reason == "" then null else $reason end)
    }'
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

is_trusted_gitlab_host() {
  local host="$1"
  local host_lc=""
  local configured=""
  local configured_lc=""

  host_lc="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')"
  for configured in "${GITLAB_HOST:-}" "${WIKI_GITLAB_HOST:-}"; do
    [ -n "${configured}" ] || continue
    configured="${configured#http://}"
    configured="${configured#https://}"
    configured="${configured%%/*}"
    configured_lc="$(printf '%s' "${configured}" | tr '[:upper:]' '[:lower:]')"
    [ "${host_lc}" = "${configured_lc}" ] && return 0
  done
  return 1
}

canonicalize_project_locator_host() {
  local host="$1"
  local port=""

  host="${host#http://}"
  host="${host#https://}"
  while [ -n "${host}" ]; do
    case "${host: -1}" in
      "."|","|";"|"，"|"。"|"；") host="${host%?}" ;;
      *) break ;;
    esac
  done
  case "${host}" in
    ""|*/*|*\?*|*\#*|*@*|*[[:space:]]*) return 1 ;;
  esac
  [[ "${host}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]] || return 1
  if [[ "${host}" == *:* ]]; then
    port="${host##*:}"
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
      return 1
    fi
  fi
  printf '%s\n' "${host}" | tr '[:upper:]' '[:lower:]'
}

extract_project_ids() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    function emit_id(value) {
      sub(/^[^0-9]*/, "", value)
      sub(/[^0-9].*$/, "", value)
      if (value != "") print value
    }
    {
      line = $0
      while (match(line, /项目[[:space:]_-]*([Ii][Dd]|编号)[[:space:]]*[:=：#]?[[:space:]]*[0-9]+/)) {
        emit_id(substr(line, RSTART, RLENGTH))
        line = substr(line, RSTART + RLENGTH)
      }
      line = $0
      while (match(line, /(([Gg][Ii][Tt][Ll][Aa][Bb][[:space:]_-]*)?[Pp][Rr][Oo][Jj][Ee][Cc][Tt][[:space:]_-]*[Ii][Dd])[[:space:]]*[:=：#]?[[:space:]]*[0-9]+/)) {
        emit_id(substr(line, RSTART, RLENGTH))
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' | awk 'NF && !seen[$0]++'
}

extract_project_id_host_candidates() {
  local text="$1"
  local raw=""
  local host=""
  local host_lc=""
  local explicitly_bound=false

  while IFS= read -r raw; do
    [ -n "${raw}" ] || continue
    explicitly_bound=false
    case "${raw}" in
      __PROJECT_ID_HOST__*)
        explicitly_bound=true
        raw="${raw#__PROJECT_ID_HOST__}"
        ;;
    esac
    if ! host="$(canonicalize_project_locator_host "${raw}")"; then
      continue
    fi
    host_lc="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')"
    if { [ "${explicitly_bound}" = true ] \
          && [[ "${host_lc}" == *.* || "${host_lc}" == *:* ]]; } \
        || is_trusted_gitlab_host "${host}" \
        || [[ "${host_lc}" == *gitlab* \
          && ( "${host_lc}" == *.* || "${host_lc}" == *:* ) ]] \
        || [[ "${host_lc}" =~ ^[0-9]+(\.[0-9]+){3}(:[0-9]+)?$ ]] \
        || [[ "${host_lc}" == localhost:* ]]; then
      printf '%s\n' "${host}"
    fi
  done < <(
    # These host scans are intentionally byte-oriented: matched host tokens and
    # the normalized PROJECT_ID marker are ASCII, and C locale keeps
    # match()/substr() offsets aligned when Chinese text precedes the locator.
    printf '%s\n' "${text}" | LC_ALL=C awk '
      {
        line = $0
        while (match(line, /[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/)) {
          print substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
        }
      }
    '
    printf '%s\n' "${text}" | LC_ALL=C awk '
      {
        normalized = $0
        gsub(/项目[[:space:]_-]*([Ii][Dd]|编号)/, " PROJECT_ID ", normalized)
        gsub(/(([Gg][Ii][Tt][Ll][Aa][Bb][[:space:]_-]*)?[Pp][Rr][Oo][Jj][Ee][Cc][Tt][[:space:]_-]*[Ii][Dd])/, " PROJECT_ID ", normalized)
        gsub(/，/, ",", normalized)
        gsub(/；/, ";", normalized)
        gsub(/：/, ":", normalized)
        line = normalized
        while (match(line, /[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?[[:space:],;:]+PROJECT_ID/)) {
          next_start = RSTART + RLENGTH
          value = substr(line, RSTART, RLENGTH)
          if (match(value, /^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/)) {
            print "__PROJECT_ID_HOST__" substr(value, RSTART, RLENGTH)
          }
          line = substr(line, next_start)
        }
        line = normalized
        while (match(line, /PROJECT_ID[[:space:]:=#]*[0-9]+[[:space:],;:@]+[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/)) {
          next_start = RSTART + RLENGTH
          value = substr(line, RSTART, RLENGTH)
          sub(/^PROJECT_ID[[:space:]:=#]*[0-9]+[[:space:],;:@]+/, "", value)
          print "__PROJECT_ID_HOST__" value
          line = substr(line, next_start)
        }
      }
    '
    printf '%s\n' "${text}" | LC_ALL=C awk '
      {
        normalized = $0
        gsub(/[Gg][Ii][Tt][Ll][Aa][Bb][[:space:]_-]*[Hh][Oo][Ss][Tt]/, " GITLAB_HOST ", normalized)
        gsub(/[Gg][Ii][Tt][Ll][Aa][Bb][[:space:]_-]*(实例|地址|服务)/, " GITLAB_HOST ", normalized)
        gsub(/：/, ":", normalized)
        line = normalized
        while (match(line, /GITLAB_HOST[[:space:]:=]+[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/)) {
          next_start = RSTART + RLENGTH
          value = substr(line, RSTART, RLENGTH)
          sub(/^GITLAB_HOST[[:space:]:=]+/, "", value)
          print "__PROJECT_ID_HOST__" value
          line = substr(line, next_start)
        }
      }
    '
  )
}

normalize_project_candidate() {
  local raw="$1"
  local decoded=""

  raw="${raw#/}"
  while [ "${raw}" != "${raw%/}" ]; do
    raw="${raw%/}"
  done
  if ! decoded="$(url_decode_path_component "${raw}")"; then
    return 1
  fi
  decoded="${decoded%.git}"
  validate_project_path "${decoded}" || return 1
  printf '%s\n' "${decoded}"
}

emit_project_candidate() {
  local raw="$1"
  local normalized=""
  if normalized="$(normalize_project_candidate "${raw}")"; then
    printf '%s\n' "${normalized}"
  else
    printf '%s\n' '__INVALID_PROJECT_CANDIDATE__'
  fi
}

normalize_issue_url() {
  local url="$1"
  local last=""
  url="${url%%\#*}"
  url="${url%%\?*}"
  while [ -n "${url}" ]; do
    last="${url: -1}"
    case "${last}" in
      "。"|"."|"!"|"！"|","|"，"|"、"|";"|"；") url="${url%?}" ;;
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
        while (match(line, /https?:\/\/[^[:space:]）)，、]+/)) {
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
  if ! is_trusted_gitlab_host "${url_host_lc}"; then
    PARSE_ISSUE_URL_ERROR="GitLab host is not trusted"
    return 1
  fi
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

extract_project_candidates() {
  local text="$1"
  local raw=""
  local url=""
  local normalized_url=""
  local without_scheme=""
  local host=""
  local path=""
  local project_raw=""

  {
    while IFS= read -r raw; do
      [ -n "${raw}" ] && emit_project_candidate "${raw}"
    done < <(
      printf '%s\n' "${text}" | awk '
        {
          line = $0
          while (match(line, /(^|[^A-Za-z0-9_.-])[Gg][Ll][Aa][Bb][[:space:]]+[Aa][Pp][Ii][[:space:]]+projects\/[A-Za-z0-9_.~%+-]+(%2[Ff][A-Za-z0-9_.~%+-]+)+/)) {
            value = substr(line, RSTART, RLENGTH)
            sub(/^.*projects\//, "", value)
            print value
            line = substr(line, RSTART + RLENGTH)
          }
        }'
    )

    while IFS= read -r url; do
      [ -n "${url}" ] || continue
      normalized_url="$(normalize_issue_url "${url}")"
      without_scheme="${normalized_url#*://}"
      host="${without_scheme%%/*}"
      [ "${without_scheme}" != "${host}" ] || continue
      is_trusted_gitlab_host "${host}" || continue
      path="${without_scheme#*/}"
      case "${path}" in
        api/v[0-9]*/projects/*|projects/*)
          project_raw="${path#*projects/}"
          project_raw="${project_raw%%/*}"
          emit_project_candidate "${project_raw}"
          continue
          ;;
      esac
      case "${path}" in
        */-/*) project_raw="${path%%/-/*}" ;;
        *) project_raw="${path}" ;;
      esac
      emit_project_candidate "${project_raw}"
    done < <(
      printf '%s\n' "${text}" | awk '
        {
          line = $0
          while (match(line, /https?:\/\/[^[:space:]）)，、]+/)) {
            print substr(line, RSTART, RLENGTH)
            line = substr(line, RSTART + RLENGTH)
          }
        }'
    )

    printf '%s\n' "${text}" | awk '
      function has_explicit_project_selector(suffix) {
        return suffix ~ /^[[:space:]]*(的[[:space:]]*)?[Ii][Ss][Ss][Uu][Ee][Ss]?([[:space:]#，,。;；:]|$)/ \
          || suffix ~ /^[[:space:]]*中?[[:space:]]*(所有|全部|未完成|待处理|label|标签|带[[:space:]]*标签)/
      }
      function is_probable_local_file_path(value, suffix, count, parts, tail) {
        count = split(value, parts, "/")
        if (count < 2) return 0
        if (has_explicit_project_selector(suffix)) return 0
        if (parts[1] == "docs" || parts[1] == "src") return 1
        tail = tolower(parts[count])
        return tail ~ /\.(c|cc|cpp|cxx|h|hpp|go|java|kt|kts|py|rb|rs|php|js|jsx|ts|tsx|vue|svelte|sh|bash|zsh|fish|ps1|sql|proto|graphql|json|jsonl|yaml|yml|toml|ini|conf|cfg|xml|html|htm|css|scss|less|md|mdx|rst|txt|csv|tsv|lock)$/
      }
      function strip_label_selector_value(line, prefix, rest) {
        if (!match(line, /(([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：])|带[[:space:]]*标签)[[:space:]]*/)) {
          return line
        }
        prefix = substr(line, 1, RSTART + RLENGTH - 1)
        rest = substr(line, RSTART + RLENGTH)
        if (match(rest, /[[:space:]]+(的[[:space:]]*)?([Oo][Pp][Ee][Nn][[:space:]]+)?[Ii][Ss][Ss][Uu][Ee][Ss]?([[:space:]，,。;；]|$)/)) {
          return prefix substr(rest, RSTART)
        }
        sub(/^[^[:space:]，,。;；]+/, "", rest)
        return prefix rest
      }
      {
        line = $0
        gsub(/https?:\/\/[^[:space:]）)，、]+/, " ", line)
        gsub(/projects\/[A-Za-z0-9_.~%+-]+(%2[Ff][A-Za-z0-9_.~%+-]+)+(\/[^[:space:]，,。;；]*)?/, " ", line)
        line = strip_label_selector_value(line)
      }
      {
        while (match(line, /[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)+/)) {
          candidate = substr(line, RSTART, RLENGTH)
          suffix = substr(line, RSTART + RLENGTH)
          if (!is_probable_local_file_path(candidate, suffix)) print candidate
          line = suffix
        }
      }'
  } | awk 'NF && !seen[$0]++'
}

strip_label_selector_values() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    {
      segment_count = split($0, segments, /[，,。;；]/)
      rebuilt = ""
      for (segment_index = 1; segment_index <= segment_count; segment_index++) {
        remaining = segments[segment_index]
        cleaned = ""
        while (match(remaining, /(([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：])|带[[:space:]]*标签)[[:space:]]*/)) {
          cleaned = cleaned substr(remaining, 1, RSTART - 1)
          rest = substr(remaining, RSTART + RLENGTH)
          if (match(rest, /^[^[:space:]，,。;；]+/)) {
            rest = substr(rest, RLENGTH + 1)
          }
          if (match(rest, /^[[:space:]]+(的[[:space:]]*)?([Oo][Pp][Ee][Nn][[:space:]]+)?[Ii][Ss][Ss][Uu][Ee][Ss]?/)) {
            rest = " issue " substr(rest, RLENGTH + 1)
          }
          remaining = rest
        }
        cleaned = cleaned remaining
        if (segment_index > 1) rebuilt = rebuilt "，"
        rebuilt = rebuilt cleaned
      }
      print rebuilt
    }'
}

# Branch and automatic-merge parsing must ignore label values without
# normalizing surrounding punctuation. The selector helper above deliberately
# rebuilds segment separators as Chinese commas, which would turn an unsafe
# `branch=release;evil` value into the apparently safe `release` token.
strip_label_values_preserving_delimiters() {
  local text="$1"
  local line="${text}"
  local pattern='((([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：]))|带[[:space:]]*标签)[[:space:]]*[^[:space:]，,。;；]+'
  local matched=""

  while [[ "${line}" =~ ${pattern} ]]; do
    matched="${BASH_REMATCH[0]}"
    [ -n "${matched}" ] || break
    line="${line/"${matched}"/ __LABEL_VALUE__ }"
  done
  printf '%s\n' "${line}"
}

extract_selector_range_evidence() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    BEGIN {
      range_pattern = "#?[0-9]+[[:space:]]*(到|至)[[:space:]]*#?[0-9]+|#[0-9]+[[:space:]]*-[[:space:]]*#?[0-9]+|[0-9]+[[:space:]]*-[[:space:]]*#[0-9]+"
    }
    {
      remaining = $0
      while (match(remaining, range_pattern)) {
        value = substr(remaining, RSTART, RLENGTH)
        if (match(value, /[0-9]+/)) {
          iid_min = substr(value, RSTART, RLENGTH)
          value = substr(value, RSTART + RLENGTH)
          if (match(value, /[0-9]+/)) {
            iid_max = substr(value, RSTART, RLENGTH)
            print iid_min "\t" iid_max
          }
        }
        sub(range_pattern, " ", remaining)
      }
    }'
}

strip_selector_ranges() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    BEGIN {
      range_pattern = "#?[0-9]+[[:space:]]*(到|至)[[:space:]]*#?[0-9]+|#[0-9]+[[:space:]]*-[[:space:]]*#?[0-9]+|[0-9]+[[:space:]]*-[[:space:]]*#[0-9]+"
    }
    {
      line = $0
      gsub(range_pattern, " ", line)
      print line
    }'
}

extract_selector_iid_evidence() {
  local text="$1"
  local had_range_context=0

  if [ -n "$(extract_selector_range_evidence "${text}")" ]; then
    had_range_context=1
  fi
  text="$(strip_label_selector_values "${text}")"
  text="$(strip_selector_ranges "${text}")"

  printf '%s\n' "${text}" | awk -v had_range_context="${had_range_context}" '
    function emit_number(value, number) {
      number = value
      sub(/^[^0-9]*/, "", number)
      sub(/[^0-9].*$/, "", number)
      if (number ~ /^[0-9]+$/) print number
    }
    function strip_label_selector_value(line, prefix, rest) {
      if (!match(line, /(([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：])|带[[:space:]]*标签)[[:space:]]*/)) {
        return line
      }
      prefix = substr(line, 1, RSTART + RLENGTH - 1)
      rest = substr(line, RSTART + RLENGTH)
      if (match(rest, /[[:space:]]+(的[[:space:]]*)?([Oo][Pp][Ee][Nn][[:space:]]+)?[Ii][Ss][Ss][Uu][Ee][Ss]?([[:space:]，,。;；]|$)/)) {
        return prefix substr(rest, RSTART)
      }
      sub(/^[^[:space:]，,。;；]+/, "", rest)
      return prefix rest
    }
    {
      line = strip_label_selector_value($0)

      remaining = line
      while (match(remaining, /\/-\/issues\/[0-9]+/)) {
        emit_number(substr(remaining, RSTART, RLENGTH))
        sub(/\/-\/issues\/[0-9]+/, " ", remaining)
      }

      remaining = line
      while (match(remaining, /#[0-9]+/)) {
        emit_number(substr(remaining, RSTART, RLENGTH))
        sub(/#[0-9]+/, " ", remaining)
      }

      remaining = line
      while (match(remaining, /([Ii][Ss][Ss][Uu][Ee]_[Ii][Ii][Dd]|[Ii][Ss][Ss][Uu][Ee]|[Ii][Ii][Dd])[[:space:]#:_-]*[0-9]+/)) {
        emit_number(substr(remaining, RSTART, RLENGTH))
        sub(/([Ii][Ss][Ss][Uu][Ee]_[Ii][Ii][Dd]|[Ii][Ss][Ss][Uu][Ee]|[Ii][Ii][Dd])[[:space:]#:_-]*[0-9]+/, " ", remaining)
      }

      if (had_range_context == 1 \
          || line ~ /([Ii][Ss][Ss][Uu][Ee]_[Ii][Ii][Dd]|[Ii][Ss][Ss][Uu][Ee]|[Ii][Ii][Dd])[[:space:]#:_-]*[0-9]+/ \
          || line ~ /\/-\/issues\/[0-9]+/ \
          || line ~ /#[0-9]+/) {
        continuation_count = split(line, continuation_parts, /(以及|或者|或|跟|和|与|及|、|,|，|[[:space:]]+[Oo][Rr][[:space:]]+|[[:space:]]+[Aa][Nn][Dd][[:space:]]+)/)
        for (continuation_index = 2; continuation_index <= continuation_count; continuation_index++) {
          candidate = continuation_parts[continuation_index]
          context = ""
          sub(/^[[:space:]]*((并|再|再次)[[:space:]]*)*(处理|执行|确认)?[[:space:]]*/, "", candidate)
          if (candidate ~ /^#?[0-9]+/) {
            context = candidate
            sub(/^#?[0-9]+/, "", context)
          }
          if (candidate ~ /^#?[0-9]+/ \
              && context !~ /^[[:space:]]*(版本|版)/ \
              && context !~ /^[\/.]/) {
            emit_number(candidate)
          }
        }
      }
    }
  ' | awk 'NF && !seen[$0]++'
}

has_unsupported_range_filter() {
  local text="$1"
  local status_pattern='(状态|[Ss][Tt][Aa][Tt][Uu][Ss])[[:space:]]*(为|是|:|=|：)?[[:space:]]*([^[:space:]，,。;；]+)'
  local remaining="${text}"
  local matched=""
  local status_value=""

  while [[ "${remaining}" =~ ${status_pattern} ]]; do
    matched="${BASH_REMATCH[0]}"
    status_value="${BASH_REMATCH[3]}"
    case "${status_value}" in
      [Oo][Pp][Ee][Nn]|[Oo][Pp][Ee][Nn][Ee][Dd]|开启|打开|未完成) ;;
      *) return 0 ;;
    esac
    remaining="${remaining/"${matched}"/ }"
  done

  [[ "${text}" =~ (([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|:|=|：)|带[[:space:]]*标签) ]]
}

extract_open_label_evidence() {
  local text="$1"
  printf '%s\n' "${text}" | awk '
    function trim(value) {
      gsub(/^[[:space:]"'\''`“”‘’]+/, "", value)
      gsub(/[[:space:]"'\''`“”‘’，,。;；]+$/, "", value)
      return value
    }
    {
      segment_count = split($0, segments, /[，,。;；]/)
      for (segment_index = 1; segment_index <= segment_count; segment_index++) {
        remaining = segments[segment_index]
        while (match(remaining, /(([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：])|带[[:space:]]*标签)[[:space:]]*/)) {
          rest = substr(remaining, RSTART + RLENGTH)
          if (match(rest, /[[:space:]]+(的[[:space:]]*)?([Oo][Pp][Ee][Nn][[:space:]]+)?[Ii][Ss][Ss][Uu][Ee][Ss]?/)) {
            value = substr(rest, 1, RSTART - 1)
            remaining = substr(rest, RSTART + RLENGTH)
          } else if (match(rest, /(([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：])|带[[:space:]]*标签)[[:space:]]*/)) {
            value = substr(rest, 1, RSTART - 1)
            remaining = substr(rest, RSTART)
          } else {
            value = rest
            remaining = ""
          }
          gsub(/[[:space:]]*(以及|或者|或|跟|和|与|及|[Oo][Rr]|[Aa][Nn][Dd])[[:space:]]*$/, "", value)
          value = trim(value)
          if (value != "") print value
        }
      }
    }'
}

has_open_unfinished_selector() {
  local text="$1"
  local selector_text=""

  selector_text="$(strip_label_selector_values "${text}")"
  [[ "${selector_text}" =~ 未完成 ]] \
    && [[ "${selector_text}" =~ [Ii][Ss][Ss][Uu][Ee][Ss]? ]]
}

collect_selector_evidence() {
  local text="$1"
  local parsed_iid="${2:-}"
  local iid_min=""
  local iid_max=""
  local label=""
  local iid_evidence_json='[]'

  while IFS=$'\t' read -r iid_min iid_max; do
    [ -n "${iid_min}" ] && [ -n "${iid_max}" ] || continue
    jq -ncS \
      --arg iid_min "${iid_min}" \
      --arg iid_max "${iid_max}" \
      '{type:"range",iid_min:($iid_min|tonumber),iid_max:($iid_max|tonumber)}'
  done < <(extract_selector_range_evidence "${text}")

  while IFS= read -r label; do
    [ -n "${label}" ] || continue
    jq -ncS --arg selector_label "${label}" '{type:"open_label",label:$selector_label}'
  done < <(extract_open_label_evidence "${text}")

  if has_open_unfinished_selector "${text}"; then
    printf '%s\n' '{"type":"open_unfinished"}'
  fi

  iid_evidence_json="$({
    extract_selector_iid_evidence "${text}"
    [ -z "${parsed_iid}" ] || printf '%s\n' "${parsed_iid}"
  } | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber) | sort | unique')"

  case "$(jq -r 'length' <<<"${iid_evidence_json}")" in
    0) ;;
    1) jq -cS '{type:"single",iid:.[0]}' <<<"${iid_evidence_json}" ;;
    *) jq -cS '{type:"iid_list",iids:.}' <<<"${iid_evidence_json}" ;;
  esac
}

has_ambiguous_iid_alternative() {
  local text="$1"

  [[ "${text}" =~ 或 ]] \
    || [[ "${text}" =~ [[:space:]][Oo][Rr][[:space:]] ]]
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
      if (!match(line, /(([Ll][Aa][Bb][Ee][Ll]|标签)[[:space:]]*(为|是|[:=：])|带[[:space:]]*标签)[[:space:]]*/)) {
        return line
      }

      prefix = substr(line, 1, RSTART + RLENGTH - 1)
      rest = substr(line, RSTART + RLENGTH)
      if (match(rest, /[[:space:]]+(的[[:space:]]*)?([Oo][Pp][Ee][Nn][[:space:]]+)?[Ii][Ss][Ss][Uu][Ee][Ss]?([[:space:]，,。;；]|$)/)) {
        return prefix substr(rest, RSTART)
      }

      sub(/^[^[:space:]，,。;；]+/, "", rest)
      return prefix rest
    }
    function has_negation(prefix) {
      prefix = trim(prefix)
      sub(/^.*(但|而是|不过|然而)/, "", prefix)
      return prefix ~ /(不要|无需|无须|不用|不必|不能|不可|不得|别|莫|不允许|禁止|严禁|避免|不需要|不是要|不是让|不是需|暂不|暂时不|并非|并不是|不建议|不打算)/
    }
    function is_positive_action(segment, remaining, prefix) {
      remaining = trim(segment)
      while (match(remaining, /(重跑|重新处理|重新执行)/)) {
        prefix = substr(remaining, 1, RSTART - 1)
        if (!has_negation(prefix)) return 1
        remaining = substr(remaining, RSTART + RLENGTH)
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
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*'`'*|*"'"*|*'"'*|*'<'*|*'>'*|*'!'*|*" "*|*$'\t'*|*$'\r'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ] || return 1
  return 0
}

# Emit every explicitly named merge destination. Automatic merge is a
# destructive action, so two different destinations must never be resolved by
# "first match wins" (for example: an old release target followed by "改为
# main"). The caller validates every emitted token and fails closed on a
# distinct-target conflict.
merge_target_tail_is_boundary() {
  local tail="$1"
  local remainder=""

  case "${tail}" in
    ""|，*|,*|。*|\)*|）*) return 0 ;;
    分支*) remainder="${tail#分支}" ;;
    branch*) remainder="${tail#branch}" ;;
    BRANCH*) remainder="${tail#BRANCH}" ;;
    *) return 1 ;;
  esac
  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  case "${remainder}" in
    ""|，*|,*|。*|\)*|）*) return 0 ;;
    *) return 1 ;;
  esac
}

branch_tail_starts_next_directive() {
  local tail="$1"
  case "${tail}" in
    base_branch=*|base_branch:*|base-branch=*|base-branch:*|\
    source_branch=*|source_branch:*|source-branch=*|source-branch:*|\
    branch=*|branch:*|target_branch=*|target_branch:*|target-branch=*|target-branch:*|\
    merge_target_branch=*|merge_target_branch:*|merge-target-branch=*|merge-target-branch:*|\
    mr_target_branch=*|mr_target_branch:*|pr_target_branch=*|pr_target_branch:*|\
    auto_merge=*|auto_merge:*|auto-merge=*|auto-merge:*|\
    目标分支*|合并目标分支*|分支：*|分支:*|\
    完成*|完毕*|结束*|跑完*|做完*|处理完*|执行完*|\
    after*|After*|AFTER*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

semicolon_tail_starts_next_directive() {
  local tail="$1"
  local remainder=""
  case "${tail}" in
    \;*) remainder="${tail#\;}" ;;
    ；*) remainder="${tail#；}" ;;
    *) return 1 ;;
  esac
  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  [ -z "${remainder}" ] \
    || branch_tail_starts_next_directive "${remainder}"
}

# Emit every explicitly named processing/base branch. Automatic merge falls
# back to this branch when no merge destination is named, so distinct values
# must be reported as a conflict instead of resolving them by first match.
collect_base_branches() {
  local text="$1"
  local line="${text}" pattern matched candidate tail trimmed_tail
  local patterns=(
    '(^|[^A-Za-z0-9_-])(base[_ -]?branch|source[_ -]?branch|branch)[[:space:]]*[:=][[:space:]]*["'\''`“”‘’]?([^[:space:]，,。;；]+)'
    '(^|[[:space:]，,;；])分支([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)["'\''`“”‘’]?([^[:space:]，,。;；]+)'
    '(基于|从|以)[[:space:]]*["'\''`“”‘’]?([^[:space:]"'\''`“”‘’，,。;；]+)["'\''`“”‘’]?[[:space:]]*(分支|[Bb][Rr][Aa][Nn][Cc][Hh])'
    '(^|[[:space:]，,;；])(改为|改成|改到|调整为|变更为|切换到|[Ss][Ww][Ii][Tt][Cc][Hh][[:space:]]+[Tt][Oo]|[Uu][Ss][Ee])[[:space:]]*["'\''`“”‘’]?([^[:space:]，,。;；]+)["'\''`“”‘’]?[[:space:]]*(分支|[Bb][Rr][Aa][Nn][Cc][Hh])'
  )
  local capture_indexes=(3 3 2 3)
  local index=0 capture_index found_explicit_base=false

  for pattern in "${patterns[@]}"; do
    if [ "${index}" -eq 3 ] && [ "${found_explicit_base}" != true ]; then
      index=$((index + 1))
      continue
    fi
    capture_index="${capture_indexes[$index]}"
    while [[ "${line}" =~ ${pattern} ]]; do
      matched="${BASH_REMATCH[0]}"
      candidate="${BASH_REMATCH[$capture_index]}"
      [ -n "${matched}" ] || break
      [ "${index}" -ge 3 ] || found_explicit_base=true
      candidate="${candidate#\"}"
      candidate="${candidate#\'}"
      candidate="${candidate#\`}"
      candidate="${candidate%\"}"
      candidate="${candidate%\'}"
      candidate="${candidate%\`}"
      candidate="${candidate%分支}"
      candidate="${candidate%branch}"
      candidate="${candidate%BRANCH}"
      if [ "${index}" -le 1 ]; then
        tail="${line#*"${matched}"}"
        tail="${tail%%$'\n'*}"
        trimmed_tail="${tail#"${tail%%[![:space:]]*}"}"
        trimmed_tail="${trimmed_tail#\"}"
        trimmed_tail="${trimmed_tail#\'}"
        trimmed_tail="${trimmed_tail#\`}"
        if merge_target_tail_is_boundary "${trimmed_tail}" \
            || branch_tail_starts_next_directive "${trimmed_tail}" \
            || semicolon_tail_starts_next_directive "${trimmed_tail}"; then
          :
        else
          candidate="${candidate} ${trimmed_tail}"
        fi
      fi
      [ -z "${candidate}" ] || printf '%s\n' "${candidate}"
      line="${line/"${matched}"/ }"
    done
    index=$((index + 1))
  done
}

collect_merge_target_branches() {
  local text="$1"
  local line="${text}" pattern matched candidate tail trimmed_tail
  local patterns=(
    '(merge[_ -]?target[_ -]?branch|mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch)[[:space:]]*[:=][[:space:]]*["'\''`“”‘’]?([^[:space:]，,。;；]+)'
    '(合并目标分支|[Mm][Rr][[:space:]]*目标分支|[Pp][Rr][[:space:]]*目标分支|目标分支)([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)["'\''`“”‘’]?([^[:space:]，,。;；]+)'
    '(合并到|合到|[Mm][Ee][Rr][Gg][Ee][[:space:]]*(到|[Tt][Oo]|[Ii][Nn][Tt][Oo]))[[:space:]]*["'\''`“”‘’]?([^[:space:]，,。;；]+)'
    '(^|[[:space:]，,;；])(改为|改成|改到|调整为|变更为|切换到|[Ss][Ww][Ii][Tt][Cc][Hh][[:space:]]+[Tt][Oo]|[Uu][Ss][Ee])[[:space:]]*["'\''`“”‘’]?([^[:space:]，,。;；]+)'
  )
  local capture_indexes=(2 3 3 3)
  local index=0 capture_index found_explicit_target=false

  for pattern in "${patterns[@]}"; do
    if [ "${index}" -eq 3 ] && [ "${found_explicit_target}" != true ]; then
      index=$((index + 1))
      continue
    fi
    capture_index="${capture_indexes[$index]}"
    while [[ "${line}" =~ ${pattern} ]]; do
      matched="${BASH_REMATCH[0]}"
      candidate="${BASH_REMATCH[$capture_index]}"
      [ -n "${matched}" ] || break
      [ "${index}" -ge 3 ] || found_explicit_target=true
      candidate="${candidate#\"}"
      candidate="${candidate#\'}"
      candidate="${candidate#\`}"
      candidate="${candidate%\"}"
      candidate="${candidate%\'}"
      candidate="${candidate%\`}"
      candidate="${candidate%分支}"
      candidate="${candidate%branch}"
      candidate="${candidate%BRANCH}"
      tail="${line#*"${matched}"}"
      tail="${tail%%$'\n'*}"
      trimmed_tail="${tail#"${tail%%[![:space:]]*}"}"
      trimmed_tail="${trimmed_tail#\"}"
      trimmed_tail="${trimmed_tail#\'}"
      trimmed_tail="${trimmed_tail#\`}"
      # A punctuation boundary may follow the branch token.  Do not treat a
      # semicolon as a boundary for assignment syntax: values such as
      # `target_branch=release;evil` must reach validate_branch_name intact
      # and fail closed, just like the legacy base-branch parser.  A semicolon
      # is accepted only when its remainder starts another recognized branch
      # or completion directive.
      if merge_target_tail_is_boundary "${trimmed_tail}" \
          || branch_tail_starts_next_directive "${trimmed_tail}" \
          || semicolon_tail_starts_next_directive "${trimmed_tail}"; then
        :
      else
        candidate="${candidate} ${trimmed_tail}"
      fi
      [ -z "${candidate}" ] || printf '%s\n' "${candidate}"
      line="${line/"${matched}"/ }"
    done
    index=$((index + 1))
  done
}

strip_base_branch_directive() {
  local text="$1"
  local line="${text}"
  local pattern=""
  local matched=""
  local patterns=(
    '(^|[[:space:]，,;；])(base[_ -]?branch|source[_ -]?branch|branch)[[:space:]]*[:=][[:space:]]*[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
    '(^|[[:space:]，,;；])分支([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
    '[[:space:]]*(请)?[[:space:]]*(基于|从|以)[[:space:]]*["'\''`“”‘’]?[^[:space:]"'\''`“”‘’，,。;；]+["'\''`“”‘’]?[[:space:]]*(分支|branch)[[:space:]]*(开发|处理|执行|实现|修改|修复)?[[:space:]]*[，,;；]?'
  )

  for pattern in "${patterns[@]}"; do
    while [[ "${line}" =~ ${pattern} ]]; do
      matched="${BASH_REMATCH[0]}"
      [ -n "${matched}" ] || break
      line="${line/"${matched}"/ }"
    done
  done

  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "${line}" ] || printf '%s\n' "${line}"
}

strip_merge_target_directive() {
  local text="$1"
  local line="${text}"
  local pattern=""
  local matched=""
  local patterns=(
    '[[:space:]]*(merge[_ -]?target[_ -]?branch|mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch)[[:space:]]*[:=][[:space:]]*[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
    '[[:space:]]*(合并目标分支|[Mm][Rr][[:space:]]*目标分支|[Pp][Rr][[:space:]]*目标分支|目标分支)([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
    '[[:space:]]*(合并到|合到|[Mm][Ee][Rr][Gg][Ee][[:space:]]*(到|[Tt][Oo]|[Ii][Nn][Tt][Oo]))[[:space:]]*[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
  )

  for pattern in "${patterns[@]}"; do
    while [[ "${line}" =~ ${pattern} ]]; do
      matched="${BASH_REMATCH[0]}"
      [ -n "${matched}" ] || break
      line="${line/"${matched}"/ }"
    done
  done

  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "${line}" ] || printf '%s\n' "${line}"
}

strip_merge_target_value_for_action() {
  local text="$1"
  local line="${text}"
  local assignment_pattern='(merge[_ -]?target[_ -]?branch|mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch)[[:space:]]*[:=][[:space:]]*[^[:space:]，,。;；]+'
  local named_natural_pattern='(合并目标分支|[Mm][Rr][[:space:]]*目标分支|[Pp][Rr][[:space:]]*目标分支|目标分支)([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)[^[:space:]，,。;；]+'
  local natural_pattern='(合并到|合到|[Mm][Ee][Rr][Gg][Ee][[:space:]]*(到|[Tt][Oo]|[Ii][Nn][Tt][Oo]))[[:space:]]*["'\''`“”‘’]?[^[:space:]"'\''`“”‘’，,。;；]+'
  local matched=""
  local action=""

  while [[ "${line}" =~ ${assignment_pattern} ]]; do
    matched="${BASH_REMATCH[0]}"
    [ -n "${matched}" ] || break
    line="${line/"${matched}"/ }"
  done
  while [[ "${line}" =~ ${named_natural_pattern} ]]; do
    matched="${BASH_REMATCH[0]}"
    [ -n "${matched}" ] || break
    line="${line/"${matched}"/ }"
  done
  while [[ "${line}" =~ ${natural_pattern} ]]; do
    matched="${BASH_REMATCH[0]}"
    action="${BASH_REMATCH[1]}"
    [ -n "${matched}" ] || break
    line="${line/"${matched}"/"${action}"}"
  done
  printf '%s\n' "${line}"
}

has_explicit_auto_merge_action() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function has_negation(prefix, lower) {
      prefix = trim(prefix)
      sub(/^.*(但|而是|不过|然而)/, "", prefix)
      lower = tolower(prefix)
      return prefix ~ /(不要|无需|无须|不用|不必|不能|不可|不得|别|莫|不允许|禁止|严禁|避免|不需要|不是要|不是让|暂不|暂时不|并非|并不是|不建议|不打算)/ \
        || prefix ~ /不[[:space:]]*$/ \
        || prefix ~ /不[[:space:]]*(自动|直接|将|把)[^，,。;；:：!！?？]*$/ \
        || lower ~ /(^|[^a-z])(do[[:space:]]+not|don'\''t|never|without)([^a-z]|$)/
    }
    function has_nominal_suffix(suffix, lower) {
      suffix = trim(suffix)
      gsub(/^[[:space:]"'\''`“”‘’]+/, "", suffix)
      lower = tolower(suffix)
      return suffix ~ /^(功能|按钮|逻辑|流程|能力|代码|配置|解析|失败|失效|问题|异常|示例|文档|策略|规则|方案|请求|说明|状态|记录|历史|测试|用例|需求|选项|提示|操作|检查|验证)/ \
        || lower ~ /^(feature|button|logic|flow|code|config|parser|failure|error|bug|example|document|strategy|rule|policy|plan|request|description|status|record|history|test|case|requirement|option|prompt|operation|check|validation)([^a-z]|$)/
    }
    function is_positive_action(segment, remaining, prefix, suffix) {
      remaining = trim(segment)
      while (match(remaining, /(((执行|处理|开发|实现|修改|修复|运行|跑)?[[:space:]]*(完成|完毕|结束|跑完|做完|处理完|执行完)[[:space:]]*(后|以后|之后)?[[:space:]]*(就|即|自动|直接)?[[:space:]]*(合并|合到|[Mm][Ee][Rr][Gg][Ee]))|([Aa][Ff][Tt][Ee][Rr][^，,。;；:：!！?？]*(complete|completed|done|finish|finished)[^，,。;；:：!！?？]*[Mm][Ee][Rr][Gg][Ee]))/)) {
        prefix = substr(remaining, 1, RSTART - 1)
        suffix = substr(remaining, RSTART + RLENGTH)
        if (!has_negation(prefix) && !has_nominal_suffix(suffix)) return 1
        remaining = substr(remaining, RSTART + RLENGTH)
      }
      return 0
    }
    function has_completion_marker(segment, lower) {
      lower = tolower(segment)
      return segment ~ /((执行|处理|开发|实现|修改|修复|运行|跑)?[[:space:]]*(完成|完毕|结束|跑完|做完|处理完|执行完)[[:space:]]*(后|以后|之后))/ \
        || lower ~ /after[^。；;!！?？]*(complete|completed|done|finish|finished)/
    }
    function strip_followup_prefix(value) {
      value = trim(value)
      while (sub(/^(并且|而且|然后|随后|同时|接着|并|且|再)[[:space:]]*/, "", value)) {
        value = trim(value)
      }
      return value
    }
    function has_non_action_suffix(suffix) {
      return has_nominal_suffix(suffix) || suffix ~ /^[-_A-Za-z0-9]/
    }
    function is_followup_merge_action(segment, remaining, suffix) {
      remaining = strip_followup_prefix(segment)
      if (remaining ~ /^(如果|若|假如|视情况|必要时|可以考虑)/) return 0

      # Once a preceding clause has established "完成后", a later clause is
      # still an explicit merge action when it starts with the merge command.
      # This covers "完成后，保存结果，并且合并到 main" without treating
      # "完成后，检查合并功能" as a destructive instruction.
      if (match(remaining, /^((请|务必|需要|需|应|要|必须)[[:space:]]*)*(自动|直接)?[[:space:]]*(合并|合到|[Mm][Ee][Rr][Gg][Ee])/)) {
        suffix = substr(remaining, RSTART + RLENGTH)
        return !has_non_action_suffix(suffix)
      }

      # The source branch may be stated as a role rather than a ref name.  It
      # is the object of the action here and must never be parsed as a base
      # branch declaration.
      if (match(remaining, /^((请|务必|需要|需|应|要|必须)[[:space:]]*)*((将|把)[[:space:]]*)?((本次|当前|该|这个|此|工作|执行|处理|任务|源)[[:space:]]*)*分支[[:space:]]*(需要|需|应|要|必须)?[[:space:]]*(自动|直接)?[[:space:]]*(合并|合到|[Mm][Ee][Rr][Gg][Ee])/)) {
        suffix = substr(remaining, RSTART + RLENGTH)
        return !has_non_action_suffix(suffix)
      }
      return 0
    }
    {
      if (text != "") text = text "，"
      text = text $0
    }
    END {
      sentence_count = split(text, sentences, /[。；;！!？?]/)
      for (sentence_index = 1; sentence_index <= sentence_count && !found; sentence_index++) {
        completion_seen = 0
        clause_count = split(sentences[sentence_index], clauses, /[，,：:]|并且|而且|然后|随后|接着/)
        for (clause_index = 1; clause_index <= clause_count; clause_index++) {
          clause = trim(clauses[clause_index])
          if (clause == "") continue
          if (is_positive_action(clause)) {
            found = 1
            break
          }
          if (has_completion_marker(clause)) {
            completion_seen = 1
          } else if (completion_seen && is_followup_merge_action(clause)) {
            found = 1
            break
          }
        }
      }
      exit(found ? 0 : 1)
    }'
}

# Return true when any sentence explicitly negates automatic/direct merge.
# The full request is scanned even after a positive sentence was found: mixed
# positive/negative instructions disable the destructive action rather than
# allowing sentence order to choose the outcome.
has_explicit_auto_merge_negation() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function has_negation(prefix, lower) {
      prefix = trim(prefix)
      sub(/^.*(但|而是|不过|然而)/, "", prefix)
      lower = tolower(prefix)
      return prefix ~ /(不要|无需|无须|不用|不必|不能|不可|不得|别|莫|不允许|禁止|严禁|避免|不需要|不是要|不是让|暂不|暂时不|并非|并不是|不建议|不打算)/ \
        || prefix ~ /不[[:space:]]*$/ \
        || prefix ~ /不[[:space:]]*(自动|直接|将|把)[^，,。;；:：!！?？]*$/ \
        || lower ~ /(^|[^a-z])(do[[:space:]]+not|don'\''t|never|without)([^a-z]|$)/
    }
    function has_nominal_suffix(suffix, lower) {
      suffix = trim(suffix)
      gsub(/^[[:space:]"'\''`“”‘’]+/, "", suffix)
      lower = tolower(suffix)
      return suffix ~ /^(功能|按钮|逻辑|流程|能力|代码|配置|解析|失败|失效|问题|异常|示例|文档|策略|规则|方案|请求|说明|状态|记录|历史|测试|用例|需求|选项|提示|操作|检查|验证)/ \
        || lower ~ /^(feature|button|logic|flow|code|config|parser|failure|error|bug|example|document|strategy|rule|policy|plan|request|description|status|record|history|test|case|requirement|option|prompt|operation|check|validation)([^a-z]|$)/
    }
    function has_negated_action(segment, remaining, prefix) {
      remaining = trim(segment)
      while (match(remaining, /([Aa][Uu][Tt][Oo][ _-]?[Mm][Ee][Rr][Gg][Ee][[:space:]]*[:=][[:space:]]*(true|TRUE|True|1|yes|YES|Yes)|自动[[:space:]]*(合并|[Mm][Ee][Rr][Gg][Ee])|直接[[:space:]]*(合并|合到|[Mm][Ee][Rr][Gg][Ee])|((执行|处理|开发|实现|修改|修复|运行|跑)?[[:space:]]*(完成|完毕|结束|跑完|做完|处理完|执行完)[[:space:]]*(后|以后|之后)?[[:space:]]*(就|即|自动|直接)?[[:space:]]*(合并|合到|[Mm][Ee][Rr][Gg][Ee]))|([Aa][Ff][Tt][Ee][Rr][^，,。;；:：!！?？]*(complete|completed|done|finish|finished)[^，,。;；:：!！?？]*[Mm][Ee][Rr][Gg][Ee]))/)) {
        prefix = substr(remaining, 1, RSTART - 1)
        if (has_negation(prefix)) return 1
        remaining = substr(remaining, RSTART + RLENGTH)
      }
      return 0
    }
    function has_negated_merge_token(segment, remaining, consumed, prefix, suffix, token) {
      remaining = trim(segment)
      consumed = ""
      while (match(remaining, /(合并|合到|[Mm][Ee][Rr][Gg][Ee])/)) {
        prefix = consumed substr(remaining, 1, RSTART - 1)
        token = substr(remaining, RSTART, RLENGTH)
        suffix = substr(remaining, RSTART + RLENGTH)
        if ((token !~ /^[Mm]/ || (prefix !~ /[-_A-Za-z0-9]$/ && suffix !~ /^[-_A-Za-z0-9]/)) \
            && has_negation(prefix) && !has_nominal_suffix(suffix)) {
          return 1
        }
        consumed = prefix token
        remaining = suffix
      }
      return 0
    }
    {
      lower = tolower($0)
      if (lower ~ /auto[ _-]?merge[[:space:]]*[:=][[:space:]]*(false|0|no)/) {
        found = 1
        exit
      }
      segment_count = split($0, segments, /[，,。；;：:！!？?]/)
      for (segment_index = 1; segment_index <= segment_count; segment_index++) {
        if (has_negated_action(segments[segment_index]) \
            || has_negated_merge_token(segments[segment_index])) {
          found = 1
          exit
        }
      }
    }
    END { exit(found ? 0 : 1) }'
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

BRANCH_PARSE_SOURCE="$(strip_label_values_preserving_delimiters "${NORMALIZED}")"
# Parse processing and merge branches independently from the same untouched
# source.  In particular, never remove `合并到 <name>` before looking for a
# processing branch: removing only that span from `执行分支合并到 master 分支`
# used to leave `执行分支 分支`, which the legacy fallback misread as a branch
# literally named `分支`.
BASE_BRANCHES_JSON="$(collect_base_branches "${BRANCH_PARSE_SOURCE}" | jq -Rsc '
  split("\n") | map(select(length > 0)) | unique
')"
BASE_BRANCH_COUNT="$(jq -r 'length' <<<"${BASE_BRANCHES_JSON}")"
if [ "${BASE_BRANCH_COUNT}" -gt 1 ]; then
  emit_json failed "" "" "" "" "${NORMALIZED}" \
    "conflicting processing branches; specify exactly one base branch"
  exit 0
elif [ "${BASE_BRANCH_COUNT}" -eq 1 ]; then
  TARGET_BRANCH="$(jq -r '.[0]' <<<"${BASE_BRANCHES_JSON}")"
else
  TARGET_BRANCH=""
fi
MERGE_TARGET_BRANCHES_JSON="$(collect_merge_target_branches \
  "${BRANCH_PARSE_SOURCE}" | jq -Rsc '
    split("\n") | map(select(length > 0)) | unique
  ')"
MERGE_TARGET_BRANCH_COUNT="$(jq -r 'length' <<<"${MERGE_TARGET_BRANCHES_JSON}")"
if [ "${MERGE_TARGET_BRANCH_COUNT}" -gt 1 ]; then
  MERGE_TARGET_BRANCH=""
  emit_json failed "" "" "${TARGET_BRANCH}" "" "${NORMALIZED}" \
    "conflicting merge target branches; specify exactly one destination"
  exit 0
elif [ "${MERGE_TARGET_BRANCH_COUNT}" -eq 1 ]; then
  MERGE_TARGET_BRANCH="$(jq -r '.[0]' <<<"${MERGE_TARGET_BRANCHES_JSON}")"
else
  MERGE_TARGET_BRANCH=""
fi
AUTO_MERGE_SOURCE="$(strip_merge_target_value_for_action "${BRANCH_PARSE_SOURCE}")"
AUTO_MERGE_SOURCE="$(strip_base_branch_directive "${AUTO_MERGE_SOURCE}")"
AUTO_MERGE=false
if has_explicit_auto_merge_action "${AUTO_MERGE_SOURCE}" \
    && ! has_explicit_auto_merge_negation "${AUTO_MERGE_SOURCE}"; then
  AUTO_MERGE=true
fi

# A merge destination is also the safest processing baseline when the user did
# not name a separate base branch. If neither branch is stated, keep both fields
# unset: req_executor resolves each Issue's declared creation baseline and only
# then falls back to the repository default branch.
if [ -z "${TARGET_BRANCH}" ] && [ -n "${MERGE_TARGET_BRANCH}" ]; then
  TARGET_BRANCH="${MERGE_TARGET_BRANCH}"
fi
if [ "${AUTO_MERGE}" = true ]; then
  if [ -z "${MERGE_TARGET_BRANCH}" ] && [ -n "${TARGET_BRANCH}" ]; then
    MERGE_TARGET_BRANCH="${TARGET_BRANCH}"
  fi
  if [ -z "${TARGET_BRANCH}" ] && [ -n "${MERGE_TARGET_BRANCH}" ]; then
    TARGET_BRANCH="${MERGE_TARGET_BRANCH}"
  fi
fi

if [ -n "${TARGET_BRANCH}" ] && ! validate_branch_name "${TARGET_BRANCH}"; then
  emit_json failed "" "" "" "" "${NORMALIZED}" "branch must be a safe Git ref name"
  exit 0
fi
if [ -n "${MERGE_TARGET_BRANCH}" ] && ! validate_branch_name "${MERGE_TARGET_BRANCH}"; then
  emit_json failed "" "" "${TARGET_BRANCH}" "" "${NORMALIZED}" "merge target branch must be a safe Git ref name"
  exit 0
fi

PROJECT_SOURCE="${NORMALIZED}"
PROJECT_SOURCE="$(strip_merge_target_directive "${PROJECT_SOURCE}")"
PROJECT_SOURCE="$(strip_base_branch_directive "${PROJECT_SOURCE}")"

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

IID=""
SELECTOR_JSON="null"
SELECTOR_ERROR=""
SELECTOR_EVIDENCE_JSON='[]'
SELECTOR_EVIDENCE_COUNT=0
PROJECT_CANDIDATE_COUNT=0
PROJECT_CANDIDATE_ROWS="$(extract_project_candidates "${PROJECT_SOURCE}")"
PROJECT_CANDIDATE_INVALID=false
if printf '%s\n' "${PROJECT_CANDIDATE_ROWS}" | grep -qx '__INVALID_PROJECT_CANDIDATE__'; then
  PROJECT_CANDIDATE_INVALID=true
fi
PROJECT_CANDIDATES="$(
  printf '%s\n' "${PROJECT_CANDIDATE_ROWS}" \
    | awk 'NF && $0 != "__INVALID_PROJECT_CANDIDATE__" && !seen[$0]++'
)"
PROJECT_CANDIDATE_COUNT="$(
  printf '%s\n' "${PROJECT_CANDIDATES}" | awk 'NF { count++ } END { print count + 0 }'
)"
PROJECT="$(printf '%s\n' "${PROJECT_CANDIDATES}" | sed -n '1p')"
PROJECT_ID_ROWS="$(extract_project_ids "${PROJECT_SOURCE}")"
PROJECT_ID_COUNT="$(
  printf '%s\n' "${PROJECT_ID_ROWS}" | awk 'NF { count++ } END { print count + 0 }'
)"
PROJECT_ID="$(printf '%s\n' "${PROJECT_ID_ROWS}" | sed -n '1p')"
PROJECT_HOST_ROWS=""
PROJECT_HOST_COUNT=0
PROJECT_HOST=""
if [ "${PROJECT_ID_COUNT}" -gt 0 ]; then
  PROJECT_HOST_ROWS="$(
    extract_project_id_host_candidates "${PROJECT_SOURCE}" | awk 'NF && !seen[$0]++'
  )"
  PROJECT_HOST_COUNT="$(
    printf '%s\n' "${PROJECT_HOST_ROWS}" | awk 'NF { count++ } END { print count + 0 }'
  )"
  PROJECT_HOST="$(printf '%s\n' "${PROJECT_HOST_ROWS}" | sed -n '1p')"
fi

SELECTOR_EVIDENCE_JSON="$({
  collect_selector_evidence "${PROJECT_SOURCE}" "${PARSED_IID}"
} | jq -csS 'unique')"
SELECTOR_EVIDENCE_COUNT="$(jq -r 'length' <<<"${SELECTOR_EVIDENCE_JSON}")"

case "${SELECTOR_EVIDENCE_COUNT}" in
  0) ;;
  1) SELECTOR_JSON="$(jq -cS '.[0]' <<<"${SELECTOR_EVIDENCE_JSON}")" ;;
  *)
    SELECTOR_ERROR="检测到多个不同 issue selector，请只保留一个规范 selector 后重试"
    ;;
esac

SELECTOR_TYPE="$(jq -r '.type // ""' <<<"${SELECTOR_JSON}")"
case "${SELECTOR_TYPE}" in
  single)
    IID="$(jq -r '.iid' <<<"${SELECTOR_JSON}")"
    ;;
  iid_list)
    PARSED_ISSUE_URL=""
    if has_ambiguous_iid_alternative "${PROJECT_SOURCE}"; then
      SELECTOR_ERROR="离散 issue IID 列表必须明确表示全部执行，不能使用“或/or”表达备选项"
    fi
    ;;
  range)
    RANGE_IID_MIN="$(jq -r '.iid_min' <<<"${SELECTOR_JSON}")"
    RANGE_IID_MAX="$(jq -r '.iid_max' <<<"${SELECTOR_JSON}")"
    if [ "${RANGE_IID_MIN}" -le 0 ] || [ "${RANGE_IID_MAX}" -le 0 ]; then
      SELECTOR_ERROR="issue IID 范围端点必须是正整数"
    elif [ "${RANGE_IID_MIN}" -gt "${RANGE_IID_MAX}" ]; then
      SELECTOR_ERROR="issue IID 范围必须满足 iid_min <= iid_max"
    elif [ -z "${SELECTOR_ERROR}" ] \
        && has_unsupported_range_filter "${PROJECT_SOURCE}"; then
      SELECTOR_ERROR="当前只支持 single/iid_list/range/open_unfinished/open_label 五类独立选择器；请拆成一个受支持的选择器后重试"
    fi
    ;;
esac

if [ "${PROJECT_CANDIDATE_INVALID}" = true ]; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project path contains unsafe characters" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
  exit 0
fi

if [ "${PROJECT_CANDIDATE_COUNT}" -gt 1 ]; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "检测到多个 GitLab project，请明确唯一仓库后重试" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
  exit 0
fi

if [ "${PROJECT_ID_COUNT}" -gt 1 ]; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "检测到多个不同 GitLab project ID，请只保留一个项目定位条件" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
  exit 0
fi

if [ "${PROJECT_HOST_COUNT}" -gt 1 ]; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "检测到多个 GitLab host；project ID 必须对应唯一 GitLab 实例" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
  exit 0
fi

if [ "${PROJECT_ID_COUNT}" -eq 1 ]; then
  if ! [[ "${PROJECT_ID}" =~ ^[1-9][0-9]*$ ]]; then
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project ID 必须是正整数" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
  fi

  PROJECT_ID_RESOLUTION_JSON=""
  if PROJECT_ID_RESOLUTION_JSON="$(
    PROJECT_ID="${PROJECT_ID}" \
    PROJECT_HOST="${PROJECT_HOST}" \
      "${BASH}" "${SCRIPT_DIR}/resolve_gitlab_project_id.sh"
  )"; then
    :
  else
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project ID 解析器执行失败" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
  fi

  if ! jq -e --argjson expected_id "${PROJECT_ID}" '
    (type == "object")
    and ((keys | sort) == ["gitlab_host","project","project_id","reason","status"])
    and (
      (.status == "success"
        and .project_id == $expected_id
        and (.project | type == "string")
        and (.gitlab_host | type == "string")
        and .reason == null)
      or (.status == "failed"
        and (.project_id == null or .project_id == $expected_id)
        and .project == null
        and .gitlab_host == null
        and (.reason | type == "string" and length > 0))
    )
  ' <<<"${PROJECT_ID_RESOLUTION_JSON}" >/dev/null 2>&1; then
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project ID 解析器返回了无效结果" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
  fi

  if [ "$(jq -r '.status' <<<"${PROJECT_ID_RESOLUTION_JSON}")" != success ]; then
    PROJECT_ID_REASON="$(jq -r '.reason' <<<"${PROJECT_ID_RESOLUTION_JSON}")"
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "${PROJECT_ID_REASON}" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
  fi

  RESOLVED_PROJECT="$(jq -r '.project' <<<"${PROJECT_ID_RESOLUTION_JSON}")"
  if ! validate_project_path "${RESOLVED_PROJECT}"; then
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "GitLab project ID 解析结果包含不安全的 path_with_namespace" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
  fi
  if [ -n "${PROJECT}" ] && [ "${PROJECT}" != "${RESOLVED_PROJECT}" ]; then
    emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "显式 GitLab project 与 project ID 解析结果不一致，已拒绝执行" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
    exit 0
  fi
  PROJECT="${RESOLVED_PROJECT}"
fi

if [ -z "${PROJECT}" ]; then
  emit_json failed "" "${IID}" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "处理 issue 需要明确 GitLab project（group/project）、GitLab host + project ID 或具体 GitLab issue URL" "${SELECTOR_JSON}" "${FORCE_RERUN_PR}"
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
  emit_json failed "${PROJECT}" "" "${TARGET_BRANCH}" "${PARSED_ISSUE_URL}" "${NORMALIZED}" "处理 issue 需要明确 issue IID（单个或离散列表）、IID 范围、未完成选择器、label 选择器或具体 GitLab issue URL" null "${FORCE_RERUN_PR}"
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
