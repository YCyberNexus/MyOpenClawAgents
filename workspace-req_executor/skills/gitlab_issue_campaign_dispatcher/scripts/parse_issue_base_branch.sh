#!/usr/bin/env bash
# Resolve an optional processing baseline declared by a GitLab Issue body.
#
# Preferred machine-readable marker (normally written by git_issuer):
#   <!-- req_executor_base_branch:v1 branch=release/2026.08 -->
#
# Backward-compatible strict text forms are also accepted outside fenced code:
#   base_branch=release/2026.08
#   source_branch: release/2026.08
#   基于 release/2026.08 分支创建
#
# Output is always one compact JSON object with status none, resolved, invalid,
# or conflict. Invalid/conflicting Issue metadata is data, not a parser crash,
# so those statuses still exit zero and let the dispatcher classify the Issue.
set -euo pipefail

emit_result() {
  local status="$1"
  local branch="${2:-}"
  local reason="${3:-}"

  jq -cn \
    --arg status "${status}" \
    --arg branch "${branch}" \
    --arg reason "${reason}" '{
      status:$status,
      branch:(if $branch == "" then null else $branch end),
      reason:(if $reason == "" then null else $reason end)
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
  git check-ref-format --branch "${branch}" >/dev/null 2>&1
}

normalize_candidate() {
  local value="$1"

  value="${value#\`}"; value="${value%\`}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#“}"; value="${value%”}"
  value="${value#‘}"; value="${value%’}"
  printf '%s' "${value}"
}

is_matching_fence_close() {
  local text="$1"
  local opener="$2"
  local fence_char="${opener:0:1}"
  local run=""
  local rest=""

  while [ -n "${text}" ] && [ "${text:0:1}" = "${fence_char}" ]; do
    run+="${fence_char}"
    text="${text:1}"
  done
  [ "${#run}" -ge "${#opener}" ] || return 1
  rest="${text}"
  [[ "${rest}" =~ ^[[:space:]]*$ ]]
}

has_natural_language_negation() {
  local original="$1"
  local lower="$2"

  # Natural-language declarations are only a compatibility path. Reject a
  # whole line on any common negative/contrast signal instead of trying to
  # infer which clause it scopes; the versioned marker remains unambiguous.
  case "${original}" in
    *不*|*无*|*勿*|*禁*|*否*|*别*|*莫*|*未*|*非*|*避免*) return 0 ;;
  esac
  case " ${lower} " in
    *" not "*|*" no "*|*" never "*|*" without "*|\
    *" do not "*|*" don't "*|*" cannot "*|*" can't "*|\
    *" should not "*|*" shouldn't "*|*" must not "*|*" mustn't "*|\
    *" isn't "*|*" aren't "*|\
    *" avoid "*|*" instead of "*|*" rather than "*) return 0 ;;
  esac
  return 1
}

DESCRIPTION="$(cat)"
declare -a CANDIDATES=()
FENCE_OPENER=""
NATURAL_CONFLICT=false
FENCE_START_PATTERN='^(`{3,}|~{3,})'
MARKER_PATTERN='^[[:space:]]*<!--[[:space:]]*req_executor_base_branch:v1[[:space:]]+branch=([^[:space:]]+)[[:space:]]*-->[[:space:]]*$'
ASSIGNMENT_PATTERN='^[[:space:]]*([-*][[:space:]]+)?(base_branch|source_branch|branch)[[:space:]]*[:=][[:space:]]*([^[:space:]]+)[[:space:]]*$'
CN_BASE_PATTERN='(基于|从)[[:space:]]*["`“”‘’]?([A-Za-z0-9._/+@%=-]+)["`“”‘’]?[[:space:]]*分支'
CN_BENCHMARK_PATTERN='以[[:space:]]*["`“”‘’]?([A-Za-z0-9._/+@%=-]+)["`“”‘’]?[[:space:]]*分支[[:space:]]*为(基准|基础)'
CN_ALT_PATTERN='(或|或者|还是|和|及|、)[[:space:]]*["`“”‘’]?([A-Za-z0-9._/+@%=-]+)["`“”‘’]?[[:space:]]*分支'
EN_BASE_PATTERN='based[[:space:]]+on[[:space:]]+["`]?([A-Za-z0-9._/+@%=-]+)["`]?[[:space:]]+branch'
EN_ALT_PATTERN='(or|and)[[:space:]]+["`]?([A-Za-z0-9._/+@%=-]+)["`]?[[:space:]]+branch'

while IFS= read -r line || [ -n "${line}" ]; do
  line="${line%$'\r'}"
  trimmed="${line#"${line%%[![:space:]]*}"}"
  if [ -n "${FENCE_OPENER}" ]; then
    if is_matching_fence_close "${trimmed}" "${FENCE_OPENER}"; then
      FENCE_OPENER=""
    fi
    continue
  fi
  if [[ "${trimmed}" =~ ${FENCE_START_PATTERN} ]]; then
    FENCE_OPENER="${BASH_REMATCH[1]}"
    continue
  fi

  if [[ "${line}" =~ ${MARKER_PATTERN} ]]; then
    CANDIDATES+=("$(normalize_candidate "${BASH_REMATCH[1]}")")
    continue
  fi
  if [[ "${line}" =~ ${ASSIGNMENT_PATTERN} ]]; then
    CANDIDATES+=("$(normalize_candidate "${BASH_REMATCH[3]}")")
    continue
  fi

  lower_line="$(LC_ALL=C printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"
  if has_natural_language_negation "${line}" "${lower_line}"; then
    continue
  fi

  line_primary_match=false
  remaining="${line}"
  while [[ "${remaining}" =~ ${CN_BASE_PATTERN} ]]; do
    CANDIDATES+=("${BASH_REMATCH[2]}")
    line_primary_match=true
    matched_text="${BASH_REMATCH[0]}"
    remaining="${remaining#*"${matched_text}"}"
  done
  remaining="${line}"
  while [[ "${remaining}" =~ ${CN_BENCHMARK_PATTERN} ]]; do
    CANDIDATES+=("${BASH_REMATCH[1]}")
    line_primary_match=true
    matched_text="${BASH_REMATCH[0]}"
    remaining="${remaining#*"${matched_text}"}"
  done
  remaining="${line}"
  while [[ "${remaining}" =~ ${CN_ALT_PATTERN} ]]; do
    [ "${line_primary_match}" = true ] || NATURAL_CONFLICT=true
    CANDIDATES+=("${BASH_REMATCH[2]}")
    matched_text="${BASH_REMATCH[0]}"
    remaining="${remaining#*"${matched_text}"}"
  done

  nocasematch_was_set=false
  shopt -q nocasematch && nocasematch_was_set=true
  shopt -s nocasematch
  english_primary_match=false
  remaining="${line}"
  while [[ "${remaining}" =~ ${EN_BASE_PATTERN} ]]; do
    CANDIDATES+=("${BASH_REMATCH[1]}")
    english_primary_match=true
    matched_text="${BASH_REMATCH[0]}"
    remaining="${remaining#*"${matched_text}"}"
  done
  remaining="${line}"
  while [[ "${remaining}" =~ ${EN_ALT_PATTERN} ]]; do
    [ "${english_primary_match}" = true ] || NATURAL_CONFLICT=true
    CANDIDATES+=("${BASH_REMATCH[2]}")
    matched_text="${BASH_REMATCH[0]}"
    remaining="${remaining#*"${matched_text}"}"
  done
  [ "${nocasematch_was_set}" = true ] || shopt -u nocasematch
done <<<"${DESCRIPTION}"

if [ "${NATURAL_CONFLICT}" = true ]; then
  emit_result conflict "" conflicting_issue_base_branches
  exit 0
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  emit_result none
  exit 0
fi

declare -a UNIQUE=()
for candidate in "${CANDIDATES[@]}"; do
  if ! validate_branch_name "${candidate}"; then
    emit_result invalid "" unsafe_issue_base_branch
    exit 0
  fi
  duplicate=false
  for existing in "${UNIQUE[@]:-}"; do
    if [ "${existing}" = "${candidate}" ]; then
      duplicate=true
      break
    fi
  done
  [ "${duplicate}" = true ] || UNIQUE+=("${candidate}")
done

if [ "${#UNIQUE[@]}" -ne 1 ]; then
  emit_result conflict "" conflicting_issue_base_branches
  exit 0
fi

emit_result resolved "${UNIQUE[0]}"
