#!/usr/bin/env bash
# precheck.sh — environment readiness precheck, run every scheduled tick after
# clone_or_pull.sh and after the batch is formed, before any per-IID acpx work.
#
# The project team ships a JSON manifest (declared via the `precheck_relpath`
# trigger field, resolved at ${REPO_PATH}/${PRECHECK_RELPATH}) listing the
# external URLs / commands / env vars / files the project depends on. This
# script probes each entry and decides whether the environment is ready:
#
#   - required entry fails → exit 1 (dispatcher aborts the whole tick and tags
#     the batch IIDs `precheck-failed`)
#   - optional entry fails → recorded as a warning, does NOT affect the exit code
#
# Probing is dependency-free and does NOT touch the no-curl rule:
#   - URL  : pure-bash /dev/tcp TCP reachability (only "can we connect", no HTTP)
#   - cmd  : command -v <bin>
#   - env  : variable is set and non-empty (value is NEVER read into any output)
#   - file : -f / -d / -e
#
# Exit codes:
#   0  all required passed (optional may have failed), OR manifest absent (skip)
#   1  at least one required failed
#   2  manifest present but not valid JSON
#
# A `precheck-<ts>.json` evidence file is always written under
# ${DISPATCHER_LOG_DIR} (same convention as reconcile-<ts>.json). The evidence
# records each check's name/type/severity/result/detail; for env vars the detail
# only ever says "set and non-empty" / "unset or empty" — never the value.
#
# Required env vars:
#   PRECHECK_RELPATH   relative path of the manifest under ${REPO_PATH}
#   (plus the dispatcher-minimum set env_paths.sh needs to derive REPO_PATH:
#    PROJECT / GROUP / GITLAB_TOKEN / optionally REPO_PARENT_PATH / basenames)
# Optional env vars (probe tunables):
#   PRECHECK_TCP_TIMEOUT          per-connect timeout seconds (default 5)
#   PRECHECK_TCP_RETRIES          max attempts per URL          (default 3)
#   PRECHECK_TCP_RETRY_INTERVAL   seconds between attempts       (default 2)

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${PRECHECK_RELPATH:?precheck.sh requires PRECHECK_RELPATH}"
: "${REPO_PATH:?}" "${DISPATCHER_LOG_DIR:?}"

PRECHECK_FILE="${PRECHECK_FILE:-${REPO_PATH}/${PRECHECK_RELPATH}}"
TCP_TIMEOUT="${PRECHECK_TCP_TIMEOUT:-5}"
TCP_RETRIES="${PRECHECK_TCP_RETRIES:-3}"
TCP_RETRY_INTERVAL="${PRECHECK_TCP_RETRY_INTERVAL:-2}"

TS="$(date +%s)"
mkdir -p "${DISPATCHER_LOG_DIR}"
EVIDENCE="${DISPATCHER_LOG_DIR}/precheck-${TS}.json"

# ─── Terminal helpers ─────────────────────────────────────────────
emit_envelope() {  # status checks_json required_failures_json
  local status="$1" checks_json="$2" reqfail_json="$3"
  local summary
  summary="$(printf '%s' "${checks_json}" | jq -c '{
    required_total:  ([.[] | select(.severity=="required")]                      | length),
    required_passed: ([.[] | select(.severity=="required" and .result=="pass")] | length),
    required_failed: ([.[] | select(.severity=="required" and .result=="fail")] | length),
    optional_total:  ([.[] | select(.severity=="optional")]                      | length),
    optional_passed: ([.[] | select(.severity=="optional" and .result=="pass")] | length),
    optional_failed: ([.[] | select(.severity=="optional" and .result=="fail")] | length)
  }')"
  jq -nc \
    --argjson ts "${TS}" \
    --arg rel "${PRECHECK_RELPATH}" \
    --arg path "${PRECHECK_FILE}" \
    --arg status "${status}" \
    --argjson summary "${summary}" \
    --argjson checks "${checks_json}" \
    --argjson reqfail "${reqfail_json}" \
    '{ts:$ts, manifest_relpath:$rel, manifest_path:$path, status:$status,
      summary:$summary, checks:$checks, required_failures:$reqfail}' > "${EVIDENCE}"
}

emit_empty() {  # status — for skipped / manifest_error (no checks)
  jq -nc \
    --argjson ts "${TS}" \
    --arg rel "${PRECHECK_RELPATH}" \
    --arg path "${PRECHECK_FILE}" \
    --arg status "$1" \
    '{ts:$ts, manifest_relpath:$rel, manifest_path:$path, status:$status,
      summary:{}, checks:[], required_failures:[]}' > "${EVIDENCE}"
}

# Manifest absent → skip (opt-in: configured relpath but team has not shipped
# the file yet). Not an error.
if [ ! -f "${PRECHECK_FILE}" ]; then
  emit_empty "skipped"
  echo "precheck: manifest not found at ${PRECHECK_FILE} — skipped"
  exit 0
fi

# Manifest present but unparseable → hard configuration error.
if ! MANIFEST="$(jq -c '.' "${PRECHECK_FILE}" 2>/dev/null)"; then
  emit_empty "manifest_error"
  echo "precheck: manifest at ${PRECHECK_FILE} is not valid JSON — manifest_error" >&2
  exit 2
fi

# ─── Probes ───────────────────────────────────────────────────────
norm_severity() { case "$1" in optional) printf 'optional' ;; *) printf 'required' ;; esac; }

# probe_tcp host port → 0 if a TCP connection succeeds within the retry budget.
# host/port are passed as positional args (not string-interpolated into the
# command) so a hostile manifest value cannot inject shell.
probe_tcp() {
  local host="$1" port="$2" i
  for ((i=1; i<=TCP_RETRIES; i++)); do
    if timeout "${TCP_TIMEOUT}" bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "${host}" "${port}" 2>/dev/null; then
      return 0
    fi
    if [ "${i}" -lt "${TCP_RETRIES}" ]; then sleep "${TCP_RETRY_INTERVAL}"; fi
  done
  return 1
}

# parse_url <url> → sets URL_HOST / URL_PORT, returns 1 on bad format.
parse_url() {
  local url="$1" rest hostport default_port host port
  case "${url}" in
    http://*)  rest="${url#http://}";  default_port=80  ;;
    https://*) rest="${url#https://}"; default_port=443 ;;
    tcp://*)   rest="${url#tcp://}";   default_port=""  ;;
    *) return 1 ;;
  esac
  hostport="${rest%%/*}"          # strip any /path
  hostport="${hostport%%\?*}"     # strip any ?query (defensive)
  # Reject userinfo (user[:pass]@host) and IPv6 literal hosts ([::1]): the
  # manifest contract is a bare hostname / IPv4 with an optional :port. A
  # ':'-split on those would silently mis-parse host/port, so fail the format
  # explicitly (the entry is judged a fail with a clear "invalid url format"
  # detail rather than probing the wrong host).
  case "${hostport}" in
    *@*|*'['*|*']'*) return 1 ;;
  esac
  case "${hostport}" in
    *:*) host="${hostport%%:*}"; port="${hostport##*:}" ;;
    *)   host="${hostport}";     port="${default_port}" ;;
  esac
  [ -n "${host}" ] || return 1
  [ -n "${port}" ] || return 1    # tcp:// without an explicit port is invalid
  case "${port}" in *[!0-9]*) return 1 ;; esac
  URL_HOST="${host}"; URL_PORT="${port}"
  return 0
}

CHECKS_FILE="$(mktemp)"
trap 'rm -f "${CHECKS_FILE}"' EXIT
record_check() {  # name type severity result detail
  jq -nc --arg name "$1" --arg type "$2" --arg severity "$3" --arg result "$4" --arg detail "$5" \
    '{name:$name, type:$type, severity:$severity, result:$result, detail:$detail}' >> "${CHECKS_FILE}"
}

# URLs — TCP reachability only.
while IFS=$'\t' read -r name url severity; do
  [ -n "${name}${url}" ] || continue
  severity="$(norm_severity "${severity}")"
  if parse_url "${url}"; then
    if probe_tcp "${URL_HOST}" "${URL_PORT}"; then
      record_check "${name}" url "${severity}" pass "tcp ${URL_HOST}:${URL_PORT} reachable"
    else
      record_check "${name}" url "${severity}" fail "tcp ${URL_HOST}:${URL_PORT} unreachable after ${TCP_RETRIES} attempt(s)"
    fi
  else
    record_check "${name}" url "${severity}" fail "invalid url format (need http://host[:port], https://host[:port], or tcp://host:port)"
  fi
done < <(printf '%s' "${MANIFEST}" | jq -r '(.urls // [])[] | [(.name // ""), (.url // ""), (.severity // "required")] | @tsv')

# Commands — present in PATH.
while IFS=$'\t' read -r name bin severity; do
  [ -n "${name}${bin}" ] || continue
  severity="$(norm_severity "${severity}")"
  if [ -n "${bin}" ] && command -v "${bin}" >/dev/null 2>&1; then
    record_check "${name}" command "${severity}" pass "'${bin}' found in PATH"
  else
    record_check "${name}" command "${severity}" fail "'${bin}' not found in PATH"
  fi
done < <(printf '%s' "${MANIFEST}" | jq -r '(.commands // [])[] | [(.name // ""), (.bin // ""), (.severity // "required")] | @tsv')

# Env vars — set and non-empty. The VALUE is never read into any output;
# printenv keeps it in a transient local only for the emptiness test.
while IFS=$'\t' read -r name var severity; do
  [ -n "${name}${var}" ] || continue
  severity="$(norm_severity "${severity}")"
  if [ -n "${var}" ] && [ -n "$(printenv -- "${var}" 2>/dev/null || true)" ]; then
    record_check "${name}" env_var "${severity}" pass "set and non-empty"
  else
    record_check "${name}" env_var "${severity}" fail "unset or empty"
  fi
done < <(printf '%s' "${MANIFEST}" | jq -r '(.env_vars // [])[] | [(.name // ""), (.var // ""), (.severity // "required")] | @tsv')

# Files — exist (kind: file/dir/any). Relative paths resolve under ${REPO_PATH}.
while IFS=$'\t' read -r name path kind severity; do
  [ -n "${name}${path}" ] || continue
  severity="$(norm_severity "${severity}")"
  case "${path}" in /*) abs="${path}" ;; *) abs="${REPO_PATH}/${path}" ;; esac
  ok=false
  case "${kind}" in
    file) [ -f "${abs}" ] && ok=true ;;
    dir)  [ -d "${abs}" ] && ok=true ;;
    *)    [ -e "${abs}" ] && ok=true ;;
  esac
  if [ "${ok}" = true ]; then
    record_check "${name}" file "${severity}" pass "${kind:-any} exists: ${path}"
  else
    record_check "${name}" file "${severity}" fail "${kind:-any} missing: ${path}"
  fi
done < <(printf '%s' "${MANIFEST}" | jq -r '(.files // [])[] | [(.name // ""), (.path // ""), (.kind // "any"), (.severity // "required")] | @tsv')

# ─── Aggregate + emit ─────────────────────────────────────────────
CHECKS_JSON="$(jq -sc '.' "${CHECKS_FILE}")"
REQUIRED_FAILURES="$(printf '%s' "${CHECKS_JSON}" | jq -c '[.[] | select(.severity=="required" and .result=="fail") | .name]')"
REQ_FAIL_COUNT="$(printf '%s' "${REQUIRED_FAILURES}" | jq 'length')"

if [ "${REQ_FAIL_COUNT}" -gt 0 ]; then
  emit_envelope "failed" "${CHECKS_JSON}" "${REQUIRED_FAILURES}"
  echo "precheck: status=failed (${REQ_FAIL_COUNT} required failed: $(printf '%s' "${REQUIRED_FAILURES}" | jq -r 'join(", ")')); evidence=${EVIDENCE}" >&2
  exit 1
fi

emit_envelope "passed" "${CHECKS_JSON}" "${REQUIRED_FAILURES}"
echo "precheck: status=passed; evidence=${EVIDENCE}"
exit 0
