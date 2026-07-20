#!/usr/bin/env bash
set -euo pipefail

MAX_GITLAB_IID=2147483647
valid_gitlab_iid() {
  local value="$1"

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
  (( ${#value} <= 10 )) || return 1
  (( 10#${value} <= MAX_GITLAB_IID ))
}

if ! valid_gitlab_iid "${ISSUE_IID:-}"; then
  printf 'ISSUE_IID must be an integer between 1 and %s\n' \
    "${MAX_GITLAB_IID}" >&2
  exit 2
fi

trim_whitespace() {
  local value="$1"

  if [[ "${value}" =~ ^[[:space:]]+ ]]; then
    value="${value#"${BASH_REMATCH[0]}"}"
  fi
  if [[ "${value}" =~ [[:space:]]+$ ]]; then
    value="${value%"${BASH_REMATCH[0]}"}"
  fi

  printf '%s' "${value}"
}

normalize_declaration_line() {
  local value="$1"
  local previous=""
  local blockquote_pattern='^>[[:space:]]*'
  local bullet_pattern='^[-+*][[:space:]]+'
  local ordered_list_pattern='^[0-9]+[.)][[:space:]]+'
  local checkbox_pattern='^\[[[:space:]xX-]\][[:space:]]+'
  local heading_pattern='^#{1,6}[[:space:]]+'

  value="$(trim_whitespace "${value}")"
  while [[ "${value}" != "${previous}" ]]; do
    previous="${value}"

    if [[ "${value}" =~ ${blockquote_pattern} ]]; then
      value="${value#"${BASH_REMATCH[0]}"}"
    elif [[ "${value}" =~ ${bullet_pattern} ]]; then
      value="${value#"${BASH_REMATCH[0]}"}"
    elif [[ "${value}" =~ ${ordered_list_pattern} ]]; then
      value="${value#"${BASH_REMATCH[0]}"}"
    elif [[ "${value}" =~ ${checkbox_pattern} ]]; then
      value="${value#"${BASH_REMATCH[0]}"}"
    elif [[ "${value}" =~ ${heading_pattern} ]]; then
      value="${value#"${BASH_REMATCH[0]}"}"
    fi

    value="$(trim_whitespace "${value}")"
  done

  # Bold markers may wrap either the whole declaration or just its key.
  value="${value//\*\*/}"
  value="${value//__/}"
  trim_whitespace "${value}"
}

declare -A dependency_iids=()
invalid_target=false
dependency_issue_pattern='^依赖[[:space:]]*Issue([[:space:]]+|[[:space:]]*:[[:space:]]*|$)(.*)$'
dependency_on_issue_pattern='^依赖于[[:space:]]*Issue([[:space:]]+|[[:space:]]*:[[:space:]]*|$)(.*)$'
dependency_on_pattern='^依赖于([[:space:]]+|[[:space:]]*:[[:space:]]*|$)(.*)$'
prerequisite_issue_pattern='^前置[[:space:]]*Issue([[:space:]]*:[[:space:]]*|$)(.*)$'
depends_on_pattern='^Depends[[:space:]]+on([[:space:]]+|[[:space:]]*:[[:space:]]*|$)(.*)$'
blocked_by_pattern='^Blocked[[:space:]]+by([[:space:]]+|[[:space:]]*:[[:space:]]*|$)(.*)$'
dependency_key_pattern='^dependency([[:space:]]*:[[:space:]]*|$)(.*)$'
depends_on_key_pattern='^depends_on([[:space:]]*:[[:space:]]*|$)(.*)$'
required_hash_target_pattern='^#([1-9][0-9]*)$'
optional_hash_target_pattern='^#?([1-9][0-9]*)$'

shopt -s nocasematch
fence_marker=""
fence_length=0
fence_containers=()
fence_open_pattern='^([ ]{0,3})(`{3,}|~{3,})(.*)$'
fence_close_pattern='^[ ]{0,3}(`{3,}|~{3,})[[:space:]]*$'
html_comment_active=false
inline_code_delimiter_length=0
markdown_lines=()

# Remove Markdown HTML comments without treating comment-looking text inside a
# matched inline code span as markup. CommonMark code spans use an exact-length
# backtick run as both delimiters; a longer or shorter run does not close the
# span, and a span may continue across non-blank paragraph lines.
markup_is_escaped_at() {
  local value="$1" index="$2" slash_count=0 cursor=$((index - 1))

  while (( cursor >= 0 )) && [[ "${value:cursor:1}" == "\\" ]]; do
    slash_count=$((slash_count + 1))
    cursor=$((cursor - 1))
  done
  (( slash_count % 2 == 1 ))
}

future_has_code_span_closer() {
  local start_line="$1" start_index="$2" required_length="$3"
  local line_index="${start_line}" search_index="${start_index}"
  local value length candidate_length

  while (( line_index < ${#markdown_lines[@]} )); do
    value="${markdown_lines[line_index]%$'\r'}"
    if (( line_index > start_line )) && [[ "${value}" =~ ^[[:space:]]*$ ]]; then
      return 1
    fi
    length="${#value}"
    while (( search_index < length )); do
      if [[ "${value:search_index:1}" != '`' ]]; then
        search_index=$((search_index + 1))
        continue
      fi
      candidate_length=1
      while (( search_index + candidate_length < length )) \
          && [[ "${value:search_index+candidate_length:1}" == '`' ]]; do
        candidate_length=$((candidate_length + 1))
      done
      if (( candidate_length == required_length )); then
        return 0
      fi
      search_index=$((search_index + candidate_length))
    done
    line_index=$((line_index + 1))
    search_index=0
  done
  return 1
}

strip_html_comments_preserving_code_spans() {
  local value="$1" current_line_index="$2"
  local output=""
  local index=0
  local length="${#value}"
  local run_length
  local comment_prefix

  INLINE_CODE_TOUCHED_LINE=false
  if (( inline_code_delimiter_length > 0 )); then
    output="INLINE_CODE_SPAN "
    INLINE_CODE_TOUCHED_LINE=true
  fi

  while (( index < length )); do
    if [[ "${html_comment_active}" == true ]]; then
      if [[ "${value:index}" == *'-->'* ]]; then
        comment_prefix="${value:index}"
        comment_prefix="${comment_prefix%%-->*}"
        index=$((index + ${#comment_prefix} + 3))
        html_comment_active=false
        continue
      fi
      index="${length}"
      break
    fi

    if (( inline_code_delimiter_length > 0 )); then
      INLINE_CODE_TOUCHED_LINE=true
      if [[ "${value:index:1}" == '`' ]]; then
        run_length=1
        while (( index + run_length < length )) \
            && [[ "${value:index+run_length:1}" == '`' ]]; do
          run_length=$((run_length + 1))
        done
        index=$((index + run_length))
        if (( run_length == inline_code_delimiter_length )); then
          inline_code_delimiter_length=0
        fi
        continue
      fi
      index=$((index + 1))
      continue
    fi

    if [[ "${value:index:4}" == '<!--' ]] \
        && ! markup_is_escaped_at "${value}" "${index}"; then
      html_comment_active=true
      index=$((index + 4))
      continue
    fi

    if [[ "${value:index:1}" == '`' ]] \
        && ! markup_is_escaped_at "${value}" "${index}"; then
      run_length=1
      while (( index + run_length < length )) \
          && [[ "${value:index+run_length:1}" == '`' ]]; do
        run_length=$((run_length + 1))
      done

      if future_has_code_span_closer "${current_line_index}" \
          "$((index + run_length))" "${run_length}"; then
        INLINE_CODE_TOUCHED_LINE=true
        inline_code_delimiter_length="${run_length}"
        output+=" INLINE_CODE_SPAN "
        index=$((index + run_length))
        continue
      fi

      output+="${value:index:run_length}"
      index=$((index + run_length))
      continue
    fi

    output+="${value:index:1}"
    index=$((index + 1))
  done

  COMMENT_STRIPPED_LINE="${output}"
}

analyze_markdown_containers() {
  local value="$1"
  local quote_pattern='^[ ]{0,3}>[ ]?'
  local bullet_pattern='^[ ]{0,3}[-+*][[:space:]]+'
  local ordered_pattern='^[ ]{0,3}[0-9]+[.)][[:space:]]+'

  MARKDOWN_CONTAINERS=()
  while :; do
    if [[ "${value}" =~ ${quote_pattern} ]]; then
      MARKDOWN_CONTAINERS+=(quote)
      value="${value#"${BASH_REMATCH[0]}"}"
    elif [[ "${value}" =~ ${bullet_pattern} ]]; then
      MARKDOWN_CONTAINERS+=("list:${#BASH_REMATCH[0]}")
      value="${value#"${BASH_REMATCH[0]}"}"
    elif [[ "${value}" =~ ${ordered_pattern} ]]; then
      MARKDOWN_CONTAINERS+=("list:${#BASH_REMATCH[0]}")
      value="${value#"${BASH_REMATCH[0]}"}"
    else
      break
    fi
  done
  MARKDOWN_CONTENT="${value}"
}

while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
  markdown_lines+=("${raw_line}")
done

for ((markdown_line_index = 0;
      markdown_line_index < ${#markdown_lines[@]};
      markdown_line_index++)); do
  raw_line="${markdown_lines[markdown_line_index]}"
  raw_line="${raw_line%$'\r'}"

  # Dependency declarations are metadata, not examples. Ignore fenced and
  # indented Markdown code blocks so a sample YAML snippet cannot accidentally
  # order real Issues. A closing fence must use the same marker character and
  # be at least as long as its opener. A blockquote/list fence ends when its
  # container ends, so the first following top-level line is processed normally.
  if [[ -n "${fence_marker}" ]]; then
    fence_container_active=true
    fence_line="${raw_line}"

    # Strip exactly the containers that owned the opener. Do not use the
    # general opener parser here: a list or nested blockquote marker appearing
    # inside a code block is literal code, not another container to discard.
    for fence_container in "${fence_containers[@]:-}"; do
      [ -n "${fence_container}" ] || continue
      if [[ "${fence_container}" == quote ]]; then
        if [[ "${fence_line}" =~ ^[\ ]{0,3}\>[\ ]? ]]; then
          fence_line="${fence_line#"${BASH_REMATCH[0]}"}"
        else
          fence_container_active=false
          break
        fi
      else
        fence_list_indent="${fence_container#list:}"
        if [[ "${fence_line}" =~ ^[[:space:]]*$ ]]; then
          fence_line=""
          break
        fi
        if [[ "${fence_line}" =~ ^([ ]*) ]]; then
          fence_line_indent="${#BASH_REMATCH[1]}"
        else
          fence_line_indent=0
        fi
        if (( fence_line_indent < fence_list_indent )); then
          fence_container_active=false
          break
        fi
        fence_line="${fence_line:${fence_list_indent}}"
      fi
    done
    if [[ "${fence_container_active}" == true ]]; then
      if [[ "${fence_line}" =~ ${fence_close_pattern} ]]; then
        closing_sequence="${BASH_REMATCH[1]}"
        if [[ "${closing_sequence:0:1}" == "${fence_marker}" ]] \
            && (( ${#closing_sequence} >= fence_length )); then
          fence_marker=""
          fence_length=0
          fence_containers=()
        fi
      fi
      continue
    fi
    fence_marker=""
    fence_length=0
    fence_containers=()
  fi

  # An indented code line is literal before inline HTML parsing. In
  # particular, four spaces followed by <!-- must not open a comment that
  # swallows metadata on later ordinary lines.
  if [[ "${html_comment_active}" != true ]] \
      && (( inline_code_delimiter_length == 0 )); then
    analyze_markdown_containers "${raw_line}"
    pre_comment_content="${MARKDOWN_CONTENT}"
    case "${pre_comment_content}" in
      $'\t'*|'    '*) continue ;;
    esac
    if [[ "${pre_comment_content}" =~ ${fence_open_pattern} ]]; then
      opening_sequence="${BASH_REMATCH[2]}"
      opening_info="${BASH_REMATCH[3]}"
      # CommonMark forbids a backtick in a backtick-fence info string.
      if [[ "${opening_sequence:0:1}" != '`' \
          || "${opening_info}" != *'`'* ]]; then
        fence_marker="${opening_sequence:0:1}"
        fence_length="${#opening_sequence}"
        fence_containers=("${MARKDOWN_CONTAINERS[@]:-}")
        continue
      fi
    fi
  fi

  # Hidden template metadata is not an operator declaration. Strip Markdown
  # HTML comments outside code fences, including multiline and multiple inline
  # comments, before looking for either a fence opener or dependency syntax.
  strip_html_comments_preserving_code_spans \
    "${raw_line}" "${markdown_line_index}"
  comment_line="${COMMENT_STRIPPED_LINE}"

  analyze_markdown_containers "${comment_line}"
  fence_line="${MARKDOWN_CONTENT}"
  case "${fence_line}" in
    $'\t'*|'    '*) continue ;;
  esac
  line="$(normalize_declaration_line "${comment_line}")"
  declaration_rest=""
  hash_optional=false
  declaration_found=false

  if [[ "${line}" =~ ${dependency_issue_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${dependency_on_issue_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${dependency_on_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${prerequisite_issue_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${depends_on_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${blocked_by_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${dependency_key_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
  elif [[ "${line}" =~ ${depends_on_key_pattern} ]]; then
    declaration_rest="${BASH_REMATCH[2]}"
    declaration_found=true
    hash_optional=true
  fi

  if [[ "${declaration_found}" != true ]]; then
    continue
  fi

  declaration_rest="$(trim_whitespace "${declaration_rest}")"
  if [[ "${declaration_rest}" =~ ^Issue[[:space:]]+(.*)$ ]]; then
    declaration_rest="$(trim_whitespace "${BASH_REMATCH[1]}")"
  fi
  dependency_iid=""
  if [[ "${hash_optional}" == true && "${declaration_rest}" =~ ${optional_hash_target_pattern} ]]; then
    dependency_iid="${BASH_REMATCH[1]}"
  elif [[ "${hash_optional}" != true && "${declaration_rest}" =~ ${required_hash_target_pattern} ]]; then
    dependency_iid="${BASH_REMATCH[1]}"
  else
    invalid_target=true
    continue
  fi

  if ! valid_gitlab_iid "${dependency_iid}"; then
    invalid_target=true
    continue
  fi

  dependency_iids["${dependency_iid}"]=1
done
shopt -u nocasematch

if [[ "${invalid_target}" == true ]]; then
  printf '{"status":"invalid","reason":"invalid_dependency_target"}\n'
  exit 0
fi

if (( ${#dependency_iids[@]} > 1 )); then
  printf '{"status":"invalid","reason":"multiple_dependencies"}\n'
  exit 0
fi

if (( ${#dependency_iids[@]} == 0 )); then
  printf '{"status":"none"}\n'
  exit 0
fi

dependency_iid="${!dependency_iids[*]}"
if [[ "${dependency_iid}" == "${ISSUE_IID}" ]]; then
  printf '{"status":"invalid","reason":"self_dependency"}\n'
  exit 0
fi

printf '{"status":"resolved","dependency_iid":%s,"base_branch":"issue/%s"}\n' \
  "${dependency_iid}" "${dependency_iid}"
