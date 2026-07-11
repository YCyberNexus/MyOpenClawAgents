#!/usr/bin/env bash
# dispatch_single_issue.sh — stable compatibility shim for RUN_SINGLE_ISSUE.
#
# The legacy entry no longer creates an independent one-concurrency project
# campaign. It canonicalizes one single-IID selector, derives stable IDs, and
# delegates to the same agent-wide RUN_DRIVEN_ISSUE_BATCH wrapper used by every
# batch. GitLab credentials are neither loaded nor emitted here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# CONFIG_DIR defaults to the workspace-level deployment-pinned config/. It is
# overridable so smoke tests can point at a throwaway config tree without
# touching the real pins (the production deployment never sets this).
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
GITLAB_TOKEN_ENV_OVERRIDE="${GITLAB_TOKEN:-}"
GROUP_ENV_OVERRIDE="${GROUP:-}"

# ─── 1. Parse the I1 trigger from stdin ────────────────────────────
# Same line discipline as dispatch_prepare_tick.sh: tolerate CRLF, skip blank /
# comment lines, accept a bare header line plus key=value lines.

# Strip leading + trailing ASCII whitespace (space and tab) from $1 via a small
# POSIX-pattern loop — no extglob dependency (matches the no-extglob style of the
# other dispatcher scripts while still trimming BOTH ends, unlike the single-char
# trim in dispatch_prepare_tick.sh).
trim_ws() {
  local s="$1"
  while [ -n "${s}" ] && case "${s}" in [[:space:]]*) true ;; *) false ;; esac; do s="${s#?}"; done
  while [ -n "${s}" ] && case "${s}" in *[[:space:]]) true ;; *) false ;; esac; do s="${s%?}"; done
  printf '%s' "${s}"
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

  PARSED_URL_PROJECT="${decoded_project}"
  PARSED_URL_IID="${issue_part}"
  return 0
}

declare -A T
TRIGGER_NAME=""
while IFS= read -r line || [ -n "${line}" ]; do
  line="${line%$'\r'}"
  case "${line}" in
    ''|\#*) continue ;;
    *=*)
      k="$(trim_ws "${line%%=*}")"
      # value: trim full leading+trailing whitespace so `iid= 14 ` (orchestrator
      # spacing) normalizes cleanly before the positive-integer guard below.
      v="$(trim_ws "${line#*=}")"
      T["${k}"]="${v}"
      ;;
    *)
      # A bare non-empty token that is not a key=value line is the trigger
      # header. Record the LAST one seen; the post-loop check rejects anything
      # other than RUN_SINGLE_ISSUE (a mis-wired scheduled trigger must NOT
      # silently fall through to "missing header tolerated").
      TRIGGER_NAME="$(trim_ws "${line}")"
      ;;
  esac
done

# Tolerate a missing header (the orchestrator may strip it), but reject a header
# that names a different trigger — that is a wiring mistake, not a single-issue run.
if [ -n "${TRIGGER_NAME}" ] && [ "${TRIGGER_NAME}" != "RUN_SINGLE_ISSUE" ]; then
  echo "dispatch_single_issue.sh: expected RUN_SINGLE_ISSUE trigger, got: ${TRIGGER_NAME}" >&2
  exit 2
fi

# ─── 2. Validate the required I1 fields ────────────────────────────
ISSUE_URL_IN="${T[issue_url]:-}"
PARSED_URL_PROJECT=""
PARSED_URL_IID=""
if [ -n "${ISSUE_URL_IN}" ]; then
  if ! parse_issue_url "${ISSUE_URL_IN}"; then
    echo "dispatch_single_issue.sh: ${PARSE_ISSUE_URL_ERROR:-issue_url must be a GitLab issue URL containing /-/issues/<iid>}, got: ${ISSUE_URL_IN}" >&2
    exit 2
  fi
fi

PROJECT_IN="${T[project]:-${PARSED_URL_PROJECT}}"
IID_IN="${T[iid]:-${PARSED_URL_IID}}"
CORRELATION_ID_INPUT="${T[correlation_id]:-}"
DISPATCHER_CALLBACK_TARGET="${T[dispatcher_callback_target]:-}"
GROUP_IN="${T[group]:-}"
BRANCH_IN="${T[branch]:-${T[target_branch]:-}}"

[ -n "${PROJECT_IN}" ]    || { echo "dispatch_single_issue.sh: missing required trigger field: project" >&2; exit 2; }
[ -n "${IID_IN}" ]        || { echo "dispatch_single_issue.sh: missing required trigger field: iid" >&2; exit 2; }

if [ -n "${PARSED_URL_PROJECT}" ] && [ -n "${T[project]:-}" ] && [ "${PROJECT_IN}" != "${PARSED_URL_PROJECT}" ]; then
  echo "dispatch_single_issue.sh: project does not match issue_url project (${PROJECT_IN} != ${PARSED_URL_PROJECT})" >&2
  exit 2
fi
if [ -n "${PARSED_URL_IID}" ] && [ -n "${T[iid]:-}" ] && [ "${IID_IN}" != "${PARSED_URL_IID}" ]; then
  echo "dispatch_single_issue.sh: iid does not match issue_url iid (${IID_IN} != ${PARSED_URL_IID})" >&2
  exit 2
fi

# iid must be a positive integer (mirror post_result_note.sh's IID guard, and
# additionally reject a bare 0 — issue IIDs start at 1).
case "${IID_IN}" in
  *[!0-9]*|"") echo "dispatch_single_issue.sh: iid must be a positive integer, got: ${IID_IN}" >&2; exit 2 ;;
esac
[ "${IID_IN}" -ge 1 ] || { echo "dispatch_single_issue.sh: iid must be a positive integer (>=1), got: ${IID_IN}" >&2; exit 2; }

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

if [ -n "${BRANCH_IN}" ] && ! validate_branch_name "${BRANCH_IN}"; then
  echo "dispatch_single_issue.sh: branch must be a safe Git ref name, got: ${BRANCH_IN}" >&2
  exit 2
fi

# Convert the compatibility bare-slug form into the full project identity
# required by create_driven_batch.sh. New callers should always send the full
# group/project path.
case "${PROJECT_IN}" in
  */*)
    GROUP_FROM_PROJECT="${PROJECT_IN%/*}"
    PROJECT_SLUG="${PROJECT_IN##*/}"
    ;;
  *)
    GROUP_FROM_PROJECT=""
    PROJECT_SLUG="${PROJECT_IN}"
    ;;
esac
[ -n "${PROJECT_SLUG}" ] || { echo "dispatch_single_issue.sh: project resolves to an empty slug: ${PROJECT_IN}" >&2; exit 2; }

if [ -n "${GROUP_FROM_PROJECT}" ] && [ -n "${GROUP_IN}" ] && [ "${GROUP_IN}" != "${GROUP_FROM_PROJECT}" ]; then
  echo "dispatch_single_issue.sh: group does not match full project group (${GROUP_IN} != ${GROUP_FROM_PROJECT})" >&2
  exit 2
fi

GROUP_EFF="${GROUP_IN:-${GROUP_FROM_PROJECT:-${GROUP_ENV_OVERRIDE:-}}}"
[ -n "${GROUP_EFF}" ] || { echo "dispatch_single_issue.sh: group is required (provide a full-name project group/project, trigger group=, or env GROUP=)" >&2; exit 2; }

# Full <group>/<project> name for dispatch_origin.json / the I2 callback (always the
# full name, even when I1 project arrived as a bare slug).
case "${PROJECT_IN}" in
  */*) PROJECT_FULL="${PROJECT_IN}" ;;
  *)   PROJECT_FULL="${GROUP_EFF}/${PROJECT_SLUG}" ;;
esac
validate_project_path "${PROJECT_FULL}" \
  || { echo "dispatch_single_issue.sh: project must be a safe full group/project path" >&2; exit 2; }

case "${CORRELATION_ID_INPUT}${DISPATCHER_CALLBACK_TARGET}" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "dispatch_single_issue.sh: correlation_id and dispatcher_callback_target must not contain control characters" >&2
    exit 2
    ;;
esac
[ -n "${DISPATCHER_CALLBACK_TARGET}" ] \
  || { echo "dispatch_single_issue.sh: missing required trigger field: dispatcher_callback_target" >&2; exit 2; }

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "dispatch_single_issue.sh: no SHA-256 command is available" >&2
    return 2
  fi
}

IDENTITY_JSON="$(jq -cnS \
  --arg project "${PROJECT_FULL}" \
  --argjson iid "${IID_IN}" \
  --arg callback_target "${DISPATCHER_CALLBACK_TARGET}" \
  --arg branch "${BRANCH_IN}" '{
    project:$project,
    iid:$iid,
    dispatcher_callback_target:$callback_target,
    branch:(if $branch == "" then null else $branch end)
  }')"
IDENTITY_DIGEST="$(printf '%s' "${IDENTITY_JSON}" | sha256_text)"
if [ -n "${CORRELATION_ID_INPUT}" ]; then
  CORRELATION_ID="${CORRELATION_ID_INPUT}"
else
  CORRELATION_ID="single-correlation-${IDENTITY_DIGEST}"
fi

REQUEST_ID_JSON="$(jq -cnS \
  --argjson identity "${IDENTITY_JSON}" \
  --arg correlation_id "${CORRELATION_ID}" '
  $identity + {correlation_id:$correlation_id}')"
BATCH_ID="single-$(printf '%s' "${REQUEST_ID_JSON}" | sha256_text)"

DRIVEN_TRIGGER="$(cat <<EOF
RUN_DRIVEN_ISSUE_BATCH
batch_id=${BATCH_ID}
correlation_id=${CORRELATION_ID}
project=${PROJECT_FULL}
selector_type=single
iid=${IID_IN}
force_rerun_pr=false
dispatcher_callback_target=${DISPATCHER_CALLBACK_TARGET}
EOF
)"
[ -n "${BRANCH_IN}" ] \
  && DRIVEN_TRIGGER="${DRIVEN_TRIGGER}"$'\n'"branch=${BRANCH_IN}"

DRIVEN_BATCH_CMD="${DRIVEN_BATCH_CMD:-${SCRIPT_DIR}/run_driven_issue_batch.sh}"
case "${DRIVEN_BATCH_CMD}" in
  /*) ;;
  *) echo "dispatch_single_issue.sh: DRIVEN_BATCH_CMD must be absolute" >&2; exit 2 ;;
esac
[ -f "${DRIVEN_BATCH_CMD}" ] && [ -x "${DRIVEN_BATCH_CMD}" ] \
  || { echo "dispatch_single_issue.sh: DRIVEN_BATCH_CMD must be executable" >&2; exit 2; }

printf '%s\n' "${DRIVEN_TRIGGER}" | \
  CONFIG_DIR="${CONFIG_DIR}" bash "${DRIVEN_BATCH_CMD}"
