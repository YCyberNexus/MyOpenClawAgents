#!/usr/bin/env bash
# Prepare an existing GitLab issue execution request for req_executor.
#
# This helper does not call req_executor. It only strips transport wrappers,
# extracts project/iid/branch from explicit issue locators, and returns the
# normalized facts the orchestrator should route and enqueue.
set -euo pipefail

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

extract_selector_range_evidence() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    {
      remaining = $0
      while (match(remaining, /#?[0-9]+[[:space:]]*(到|至)[[:space:]]*#?[0-9]+/)) {
        value = substr(remaining, RSTART, RLENGTH)
        if (match(value, /[0-9]+/)) {
          iid_min = substr(value, RSTART, RLENGTH)
          value = substr(value, RSTART + RLENGTH)
          if (match(value, /[0-9]+/)) {
            iid_max = substr(value, RSTART, RLENGTH)
            print iid_min "\t" iid_max
          }
        }
        sub(/#?[0-9]+[[:space:]]*(到|至)[[:space:]]*#?[0-9]+/, " ", remaining)
      }
    }'
}

strip_selector_ranges() {
  local text="$1"

  printf '%s\n' "${text}" | awk '
    {
      line = $0
      gsub(/#?[0-9]+[[:space:]]*(到|至)[[:space:]]*#?[0-9]+/, " ", line)
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
  local iid_min=""
  local iid_max=""
  local label=""
  local evidence_iid=""

  while IFS=$'\t' read -r iid_min iid_max; do
    [ -n "${iid_min}" ] && [ -n "${iid_max}" ] || continue
    jq -ncS \
      --arg iid_min "${iid_min}" \
      --arg iid_max "${iid_max}" \
      '{type:"range",iid_min:($iid_min|tonumber),iid_max:($iid_max|tonumber)}'
  done < <(extract_selector_range_evidence "${text}")

  while IFS= read -r label; do
    [ -n "${label}" ] || continue
    jq -ncS --arg label "${label}" '{type:"open_label",label:$label}'
  done < <(extract_open_label_evidence "${text}")

  if has_open_unfinished_selector "${text}"; then
    printf '%s\n' '{"type":"open_unfinished"}'
  fi

  while IFS= read -r evidence_iid; do
    [ -n "${evidence_iid}" ] || continue
    jq -ncS --arg iid "${evidence_iid}" '{type:"single",iid:($iid|tonumber)}'
  done < <(extract_selector_iid_evidence "${text}")
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
      if (match(line, /(目标分支|分支)([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)/)) {
        emit_explicit(substr(line, RSTART + RLENGTH))
        exit
      }
      if (match(line, /(合并到|合到|merge[[:space:]]+to)[[:space:]]*/)) {
        emit_explicit(substr(line, RSTART + RLENGTH))
        exit
      }
      if (match(line, /(基于|从|以)[[:space:]]*["'\''`“”‘’]?[^[:space:]"'\''`“”‘’，,。;；]+["'\''`“”‘’]?[[:space:]]*(分支|branch)/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/^(基于|从|以)[[:space:]]*["'\''`“”‘’]?/, "", value)
        sub(/["'\''`“”‘’]?[[:space:]]*(分支|branch).*$/, "", value)
        emit(value)
        exit
      }
    }'
}

strip_target_branch_directive() {
  local text="$1"
  local line="${text}"
  local pattern=""
  local matched=""
  local patterns=(
    '[[:space:]]*(mr[_ -]?target[_ -]?branch|pr[_ -]?target[_ -]?branch|target[_ -]?branch|branch)[[:space:]]*[:=][[:space:]]*[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
    '[[:space:]]*(目标分支|分支)([[:space:]]*[：:=][[:space:]]*|[[:space:]]+)[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
    '[[:space:]]*(合并到|合到|merge[[:space:]]+to)[[:space:]]*[^[:space:]，,。;；]+[[:space:]]*[，,;；]?'
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

SELECTOR_EVIDENCE_JSON="$({
  collect_selector_evidence "${PROJECT_SOURCE}"
  if [ -n "${PARSED_IID}" ]; then
    jq -ncS --arg iid "${PARSED_IID}" '{type:"single",iid:($iid|tonumber)}'
  fi
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
  range)
    RANGE_IID_MIN="$(jq -r '.iid_min' <<<"${SELECTOR_JSON}")"
    RANGE_IID_MAX="$(jq -r '.iid_max' <<<"${SELECTOR_JSON}")"
    if [ "${RANGE_IID_MIN}" -le 0 ] || [ "${RANGE_IID_MAX}" -le 0 ]; then
      SELECTOR_ERROR="issue IID 范围端点必须是正整数"
    elif [ "${RANGE_IID_MIN}" -gt "${RANGE_IID_MAX}" ]; then
      SELECTOR_ERROR="issue IID 范围必须满足 iid_min <= iid_max"
    elif [ -z "${SELECTOR_ERROR}" ] \
        && has_unsupported_range_filter "${PROJECT_SOURCE}"; then
      SELECTOR_ERROR="当前只支持 single/range/open_unfinished/open_label 四类独立选择器；请拆成一个受支持的选择器后重试"
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
