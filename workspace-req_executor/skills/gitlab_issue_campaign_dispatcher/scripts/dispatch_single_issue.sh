#!/usr/bin/env bash
# dispatch_single_issue.sh — driven single-issue entry (RUN_SINGLE_ISSUE).
#
# This is the req_dispatcher-driven entry point (see
# docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md
# §3.1–§3.3). Instead of req_dispatcher feeding a full RUN_SCHEDULED_ISSUE_CAMPAIGN
# trigger, it sends a minimal trigger carrying only what it knows about ONE issue;
# everything else is either inferred by the executor or held in runner-side config;
# req_dispatcher never holds GitLab config.
#
# What it does:
#   1. Reads the I1 trigger from stdin (multi-line key=value, same text format as
#      dispatch_prepare_tick.sh). Required keys: correlation_id plus either
#      project+iid or issue_url. Optional: dispatcher_callback_target, group,
#      branch.
#   2. Validates project / iid (positive integer) / issue_url / correlation_id.
#   3. Sources config/gitlab.env (host pin), config/campaign_defaults.env
#      (clone parent pin), then optional config/campaign_defaults.local.env
#      (ignored local override) to obtain the clone parent. GitLab token comes
#      only from process env or config/gitlab.env.
#   4. Synthesizes the equivalent RUN_SCHEDULED_ISSUE_CAMPAIGN trigger for a single
#      IID (issue_iids=[iid], issue_min_iid=issue_max_iid=iid, hourly_issue_quota=1,
#      max_concurrent_subagents=1, …) and exports the dispatcher bootstrap env.
#   5. Writes {correlation_id, dispatcher_callback_target} to the per-issue
#      ${ISSUE_ROOT}/dispatch_origin.json so the Phase 6 callback (A3/A4) can find
#      the req_dispatcher to report back to. At this point no attempt has been
#      allocated yet (env_paths.sh derives ISSUE_ROOT only with ISSUE_IID +
#      ATTEMPT_NUMBER), so the file is written under the dispatcher-level
#      ${ISSUES_ROOT}/issue-${iid}/ — which is exactly ${ISSUE_ROOT} once the
#      attempt is later derived.
#   6. Pipes the synthesized trigger on stdin into dispatch_prepare_tick.sh (which
#      reads its trigger from stdin) and forwards its stdout envelope unchanged.
#
# Exit codes:
#   0  — handed off to dispatch_prepare_tick.sh (its envelope is on stdout); the
#        prepare tick itself reports tick-level problems via its JSON envelope.
#   2  — malformed/missing input (bad trigger header, missing/invalid required
#        field, missing pinned token/group). This is a CONFIG-shape error, surfaced
#        to the caller so it can stop and classify (No-Fallback) rather than spawn a
#        half-set-up issue.
#
# Required input env (forwarded to env_paths.sh / dispatch_prepare_tick.sh):
#   (none mandatory on the command line — project/iid/correlation_id arrive on
#    stdin; token comes from env/gitlab.env; group comes from full project,
#    trigger group=, or env override)
# Optional input env (override for smoke tests / non-default deployments):
#   GITLAB_TOKEN          overrides config/gitlab.env GITLAB_TOKEN
#   GROUP                 smoke-test override when trigger project is bare
#   PREPARE_TICK_CMD      path to the prepare-tick script to invoke (default:
#                         the sibling dispatch_prepare_tick.sh). Smoke tests stub
#                         this with a fake that just echoes its env + stdin.
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
CORRELATION_ID="${T[correlation_id]:-}"
DISPATCHER_CALLBACK_TARGET="${T[dispatcher_callback_target]:-}"
GROUP_IN="${T[group]:-}"
BRANCH_IN="${T[branch]:-${T[target_branch]:-}}"

[ -n "${PROJECT_IN}" ]    || { echo "dispatch_single_issue.sh: missing required trigger field: project" >&2; exit 2; }
[ -n "${IID_IN}" ]        || { echo "dispatch_single_issue.sh: missing required trigger field: iid" >&2; exit 2; }
[ -n "${CORRELATION_ID}" ] || { echo "dispatch_single_issue.sh: missing required trigger field: correlation_id" >&2; exit 2; }

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

# ─── 3. Load deployment pins (host + clone parent) ────────────────
[ -f "${CONFIG_DIR}/gitlab.env" ] || { echo "dispatch_single_issue.sh: missing config/gitlab.env at ${CONFIG_DIR}/gitlab.env" >&2; exit 2; }
[ -f "${CONFIG_DIR}/campaign_defaults.env" ] || { echo "dispatch_single_issue.sh: missing config/campaign_defaults.env at ${CONFIG_DIR}/campaign_defaults.env" >&2; exit 2; }
# shellcheck disable=SC1091
source "${CONFIG_DIR}/gitlab.env"
GITLAB_TOKEN_GITLAB_ENV_PIN="${GITLAB_TOKEN:-}"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/campaign_defaults.env"
if [ -f "${CONFIG_DIR}/campaign_defaults.local.env" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_DIR}/campaign_defaults.local.env"
fi

# I1 `project` carries the FULL name <group>/<project> (git_issuer's callback form,
# which req_dispatcher transparently forwards and uses as its routing key). The
# executor's internal campaign machinery (env_paths.sh) expects a BARE project slug
# plus a separate GROUP — env_paths.sh builds REPO_PATH=${REPO_PARENT_PATH}/${PROJECT}
# and PROJECT_FULL=${GROUP}/${PROJECT}, so feeding it a slashed name would double the
# group and mis-locate the clone. Split here: if `project` has a slash, the part before
# is the group and the part after is the bare slug; if not, it is already a bare slug
# and GROUP must come from I1/env/local config.
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

# GROUP: explicit I1 group wins, then the group split out of a full-name project,
# then the process env override used by smoke tests. dispatch_prepare_tick.sh
# requires `group`.
GROUP_EFF="${GROUP_IN:-${GROUP_FROM_PROJECT:-${GROUP_ENV_OVERRIDE:-}}}"
[ -n "${GROUP_EFF}" ] || { echo "dispatch_single_issue.sh: group is required (provide a full-name project group/project, trigger group=, or env GROUP=)" >&2; exit 2; }

# Full <group>/<project> name for dispatch_origin.json / the I2 callback (always the
# full name, even when I1 project arrived as a bare slug).
case "${PROJECT_IN}" in
  */*) PROJECT_FULL="${PROJECT_IN}" ;;
  *)   PROJECT_FULL="${GROUP_EFF}/${PROJECT_SLUG}" ;;
esac

# GITLAB_TOKEN: env override wins, then gitlab.env. The clone defaults layer is
# intentionally ignored for secrets.
GITLAB_TOKEN_EFF="${GITLAB_TOKEN_ENV_OVERRIDE:-${GITLAB_TOKEN_GITLAB_ENV_PIN:-}}"
[ -n "${GITLAB_TOKEN_EFF}" ] || { echo "dispatch_single_issue.sh: GITLAB_TOKEN is required (set env GITLAB_TOKEN or pin it in config/gitlab.env)" >&2; exit 2; }

ACPX_TIMEOUT_EFF=18000
MAX_RUNTIME_MINUTES_EFF=300
BLOCKED_RETRY_LIMIT_EFF=3
BLOCKED_COOLDOWN_TICKS_EFF=1
# REPO_PARENT_PATH is the only campaign default required in tracked config.
# env_paths.sh additionally validates it.
REPO_PARENT_EFF="${REPO_PARENT_PATH:-/data}"

# driven single-issue run is always quota=1, concurrency=1, IID-scoped to one issue.
HOURLY_ISSUE_QUOTA_EFF=1
MAX_CONCURRENT_SUBAGENTS_EFF=1

# ─── 4. Export the dispatcher bootstrap env for env_paths.sh ───────
export PROJECT="${PROJECT_SLUG}"
export GROUP="${GROUP_EFF}"
export GITLAB_TOKEN="${GITLAB_TOKEN_EFF}"
export REPO_PARENT_PATH="${REPO_PARENT_EFF}"

# ─── 5. Persist the driven origin for the Phase 6 callback ─────────
# env_paths.sh derives ISSUES_ROOT at the dispatcher level (no ISSUE_IID needed).
# ISSUE_ROOT proper is ${ISSUES_ROOT}/issue-${iid}, which is what we write under here
# — identical to the path env_paths.sh will export once an attempt is allocated.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_paths.sh"

: "${ISSUES_ROOT:?dispatch_single_issue.sh: env_paths.sh did not export ISSUES_ROOT}"
ISSUE_ROOT_FOR_IID="${ISSUES_ROOT}/issue-${IID_IN}"
DISPATCH_ORIGIN_FILE="${ISSUE_ROOT_FOR_IID}/dispatch_origin.json"

mkdir -p "${ISSUE_ROOT_FOR_IID}"
ORIGIN_TMP="$(mktemp "${DISPATCH_ORIGIN_FILE}.tmp.XXXXXX")"
jq -nc \
  --arg correlation_id "${CORRELATION_ID}" \
  --arg dispatcher_callback_target "${DISPATCHER_CALLBACK_TARGET}" \
  --arg project "${PROJECT_FULL}" \
  --argjson iid "${IID_IN}" '
  {correlation_id: $correlation_id,
   dispatcher_callback_target: ($dispatcher_callback_target | select(. != "") // null),
   project: $project,
   iid: $iid}' >"${ORIGIN_TMP}"
mv -f "${ORIGIN_TMP}" "${DISPATCH_ORIGIN_FILE}"
echo "dispatch_single_issue.sh: wrote dispatch_origin.json for #${IID_IN} (correlation_id=${CORRELATION_ID})" >&2

# ─── 6. Synthesize the equivalent single-IID scheduled trigger ─────
# dispatch_prepare_tick.sh reads its trigger from stdin as multi-line key=value.
# The fixed-value preflight fields and the per-issue scope (issue_iids=[iid],
# issue_min_iid=issue_max_iid=iid) are pinned here; quota / concurrency are forced
# to 1 for a single-issue run.
SYNTH_TRIGGER="$(cat <<EOF
RUN_SCHEDULED_ISSUE_CAMPAIGN
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
project=${PROJECT_SLUG}
group=${GROUP_EFF}
gitlab_token=${GITLAB_TOKEN_EFF}
issue_iids=${IID_IN}
issue_min_iid=${IID_IN}
issue_max_iid=${IID_IN}
hourly_issue_quota=${HOURLY_ISSUE_QUOTA_EFF}
max_concurrent_subagents=${MAX_CONCURRENT_SUBAGENTS_EFF}
max_runtime_minutes=${MAX_RUNTIME_MINUTES_EFF}
blocked_retry_limit=${BLOCKED_RETRY_LIMIT_EFF}
blocked_cooldown_ticks=${BLOCKED_COOLDOWN_TICKS_EFF}
acpx_timeout_seconds=${ACPX_TIMEOUT_EFF}
repo_path=${REPO_PARENT_EFF}
EOF
)"
# Append the optional fields only when a non-empty value exists, so we never feed
# dispatch_prepare_tick.sh an empty key it would reject.
[ -n "${BRANCH_IN}" ] && SYNTH_TRIGGER="${SYNTH_TRIGGER}"$'\n'"branch=${BRANCH_IN}"

# ─── 7. Hand off to the existing prepare-tick body ─────────────────
PREPARE_TICK_CMD="${PREPARE_TICK_CMD:-${SCRIPT_DIR}/dispatch_prepare_tick.sh}"
printf '%s\n' "${SYNTH_TRIGGER}" | bash "${PREPARE_TICK_CMD}"
