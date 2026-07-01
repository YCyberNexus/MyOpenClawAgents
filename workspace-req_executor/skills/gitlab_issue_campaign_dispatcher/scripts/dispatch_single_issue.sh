#!/usr/bin/env bash
# dispatch_single_issue.sh — driven single-issue entry (RUN_SINGLE_ISSUE).
#
# This is the req_dispatcher-driven entry point (see
# docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md
# §3.1–§3.3). Instead of req_dispatcher feeding a full RUN_SCHEDULED_ISSUE_CAMPAIGN
# trigger, it sends a minimal trigger carrying only what it knows about ONE issue;
# everything else (token / branch / quota / timeouts / basenames …) comes from the
# per-project deployment pin in config/ — req_dispatcher never holds GitLab config.
#
# What it does:
#   1. Reads the I1 trigger from stdin (multi-line key=value, same text format as
#      dispatch_prepare_tick.sh). Required keys: project, iid, correlation_id.
#      Optional: dispatcher_callback_target, group.
#   2. Validates project / iid (positive integer) / correlation_id.
#   3. Sources config/gitlab.env (host pin) + config/campaign_defaults.env (campaign
#      pin) to obtain the pinned campaign fields and the GitLab token.
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
#    stdin; token/group come from config or env override; see below)
# Optional input env (override for smoke tests / non-default deployments):
#   GITLAB_TOKEN          overrides config/campaign_defaults.env GITLAB_TOKEN
#   GROUP                 overrides config/campaign_defaults.env GROUP and the
#                         optional stdin `group` key
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
PROJECT_IN="${T[project]:-}"
IID_IN="${T[iid]:-}"
CORRELATION_ID="${T[correlation_id]:-}"
DISPATCHER_CALLBACK_TARGET="${T[dispatcher_callback_target]:-}"
GROUP_IN="${T[group]:-}"

[ -n "${PROJECT_IN}" ]    || { echo "dispatch_single_issue.sh: missing required trigger field: project" >&2; exit 2; }
[ -n "${IID_IN}" ]        || { echo "dispatch_single_issue.sh: missing required trigger field: iid" >&2; exit 2; }
[ -n "${CORRELATION_ID}" ] || { echo "dispatch_single_issue.sh: missing required trigger field: correlation_id" >&2; exit 2; }

# iid must be a positive integer (mirror post_result_note.sh's IID guard, and
# additionally reject a bare 0 — issue IIDs start at 1).
case "${IID_IN}" in
  *[!0-9]*|"") echo "dispatch_single_issue.sh: iid must be a positive integer, got: ${IID_IN}" >&2; exit 2 ;;
esac
[ "${IID_IN}" -ge 1 ] || { echo "dispatch_single_issue.sh: iid must be a positive integer (>=1), got: ${IID_IN}" >&2; exit 2; }

# ─── 3. Load deployment pins (host + campaign defaults) ────────────
[ -f "${CONFIG_DIR}/gitlab.env" ] || { echo "dispatch_single_issue.sh: missing config/gitlab.env at ${CONFIG_DIR}/gitlab.env" >&2; exit 2; }
[ -f "${CONFIG_DIR}/campaign_defaults.env" ] || { echo "dispatch_single_issue.sh: missing config/campaign_defaults.env at ${CONFIG_DIR}/campaign_defaults.env" >&2; exit 2; }
# shellcheck disable=SC1091
source "${CONFIG_DIR}/gitlab.env"
# shellcheck disable=SC1091
source "${CONFIG_DIR}/campaign_defaults.env"

# I1 `project` carries the FULL name <group>/<project> (git_issuer's callback form,
# which req_dispatcher transparently forwards and uses as its routing key). The
# executor's internal campaign machinery (env_paths.sh) expects a BARE project slug
# plus a separate GROUP — env_paths.sh builds REPO_PATH=${REPO_PARENT_PATH}/${PROJECT}
# and PROJECT_FULL=${GROUP}/${PROJECT}, so feeding it a slashed name would double the
# group and mis-locate the clone. Split here: if `project` has a slash, the part before
# is the group and the part after is the bare slug; if not, it is already a bare slug
# and GROUP must come from I1/pin.
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
# then the GROUP env override / pin. dispatch_prepare_tick.sh requires `group`.
GROUP_EFF="${GROUP_IN:-${GROUP_FROM_PROJECT:-${GROUP:-}}}"
[ -n "${GROUP_EFF}" ] || { echo "dispatch_single_issue.sh: group is required (provide a full-name project group/project, trigger group=, env GROUP=, or pin GROUP= in campaign_defaults.env)" >&2; exit 2; }

# Full <group>/<project> name for dispatch_origin.json / the I2 callback (always the
# full name, even when I1 project arrived as a bare slug).
case "${PROJECT_IN}" in
  */*) PROJECT_FULL="${PROJECT_IN}" ;;
  *)   PROJECT_FULL="${GROUP_EFF}/${PROJECT_SLUG}" ;;
esac

# GITLAB_TOKEN: env override wins, else the pin. req_dispatcher never sends the
# token; it always comes from the executor-side deployment.
GITLAB_TOKEN_EFF="${GITLAB_TOKEN:-}"
[ -n "${GITLAB_TOKEN_EFF}" ] || { echo "dispatch_single_issue.sh: GITLAB_TOKEN is required (set env GITLAB_TOKEN or pin it in campaign_defaults.env)" >&2; exit 2; }

# Pinned campaign fields with safe defaults (campaign_defaults.env should set
# these; defaults mirror dispatch_prepare_tick.sh's own fallbacks so a partial
# pin still yields a valid single-issue tick).
BRANCH_EFF="${BRANCH:-master}"
DEV_BRANCH_EFF="${DEV_BRANCH:-dev}"
MAX_ACCOUNTS_EFF="${MAX_ACCOUNTS_PER_ISSUE:-14}"
ACPX_TIMEOUT_EFF="${ACPX_TIMEOUT_SECONDS:-18000}"
RUN_TIMEOUT_EFF="${RUN_TIMEOUT_SECONDS:-}"
RESULT_BASENAME_EFF="${RESULT_BASENAME:-ifp-result}"
DATA_BASENAME_EFF="${DATA_BASENAME:-ifp-data}"
# REPO_PARENT_PATH is pinned in campaign_defaults.env (default /data); env_paths.sh
# additionally validates it.
REPO_PARENT_EFF="${REPO_PARENT_PATH:-/data}"
UI_ACCOUNTS_RELPATH_EFF="${UI_ACCOUNTS_RELPATH:-}"

# driven single-issue run is always quota=1, concurrency=1, IID-scoped to one issue.
HOURLY_ISSUE_QUOTA_EFF=1
MAX_CONCURRENT_SUBAGENTS_EFF=1

# ─── 4. Export the dispatcher bootstrap env for env_paths.sh ───────
export PROJECT="${PROJECT_SLUG}"
export GROUP="${GROUP_EFF}"
export GITLAB_TOKEN="${GITLAB_TOKEN_EFF}"
export REPO_PARENT_PATH="${REPO_PARENT_EFF}"
export RESULT_BASENAME="${RESULT_BASENAME_EFF}"
export DATA_BASENAME="${DATA_BASENAME_EFF}"
[ -n "${UI_ACCOUNTS_RELPATH_EFF}" ] && export UI_ACCOUNTS_RELPATH="${UI_ACCOUNTS_RELPATH_EFF}"

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
branch=${BRANCH_EFF}
dev_branch=${DEV_BRANCH_EFF}
issue_iids=${IID_IN}
issue_min_iid=${IID_IN}
issue_max_iid=${IID_IN}
hourly_issue_quota=${HOURLY_ISSUE_QUOTA_EFF}
max_concurrent_subagents=${MAX_CONCURRENT_SUBAGENTS_EFF}
max_accounts_per_issue=${MAX_ACCOUNTS_EFF}
max_runtime_minutes=${MAX_RUNTIME_MINUTES:-300}
blocked_retry_limit=${BLOCKED_RETRY_LIMIT:-3}
blocked_cooldown_ticks=${BLOCKED_COOLDOWN_TICKS:-1}
acpx_timeout_seconds=${ACPX_TIMEOUT_EFF}
result_basename=${RESULT_BASENAME_EFF}
data_basename=${DATA_BASENAME_EFF}
repo_path=${REPO_PARENT_EFF}
EOF
)"
# Append the optional fields only when a non-empty value exists, so we never feed
# dispatch_prepare_tick.sh an empty key it would reject.
[ -n "${RUN_TIMEOUT_EFF}" ]          && SYNTH_TRIGGER="${SYNTH_TRIGGER}"$'\n'"run_timeout_seconds=${RUN_TIMEOUT_EFF}"
[ -n "${UI_ACCOUNTS_RELPATH_EFF}" ]  && SYNTH_TRIGGER="${SYNTH_TRIGGER}"$'\n'"ui_accounts_relpath=${UI_ACCOUNTS_RELPATH_EFF}"
[ -n "${STUCK_AFTER_MINUTES:-}" ]    && SYNTH_TRIGGER="${SYNTH_TRIGGER}"$'\n'"stuck_after_minutes=${STUCK_AFTER_MINUTES}"

# ─── 7. Hand off to the existing prepare-tick body ─────────────────
PREPARE_TICK_CMD="${PREPARE_TICK_CMD:-${SCRIPT_DIR}/dispatch_prepare_tick.sh}"
printf '%s\n' "${SYNTH_TRIGGER}" | bash "${PREPARE_TICK_CMD}"
