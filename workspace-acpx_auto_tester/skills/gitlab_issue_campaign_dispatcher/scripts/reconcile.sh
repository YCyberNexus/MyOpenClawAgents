#!/usr/bin/env bash
# reconcile.sh — query GitLab for a set of IIDs and write a single evidence
# JSON file the dispatcher can grep + jq later. This is the fail-closed
# evidence required by the Source-of-Truth Policy: if this file was not
# produced this tick, reconciliation did not happen.
#
# Two invocation shapes (added 2026-05-08.1):
#   - Range mode (default):  set MIN_IID + MAX_IID. Iterates seq MIN_IID MAX_IID.
#   - List mode:             set IID_LIST="14,17,20" (comma-separated, whitespace
#                            tolerated). MIN_IID/MAX_IID are ignored when
#                            IID_LIST is set (even when empty string).
#                            IID_LIST="" (set but empty) is the legitimate
#                            "filter narrowed to zero IIDs" case → write [].
#
# Required env vars:
#   GITLAB_HOST           resolved hostname (output of glab_auth.sh)
#   PROJECT_FULL          "<group>/<project>"
#   DISPATCHER_LOG_DIR    where to put reconcile-<ts>.json
#   one of:
#     MIN_IID + MAX_IID   (range mode)
#     IID_LIST            (list mode; takes precedence when set, even when empty)
#
# Output:
#   Prints the absolute path of the evidence file to stdout.
#   Evidence file is a JSON array of objects with these fields per IID:
#     {
#       "iid":               <integer>,
#       "state":             "opened" | "closed" | null,
#       "labels":            [...] | null,
#       "title":             "..."  | null,
#       "has_pr":            bool,   # labels include "pr" (v2: pr REPLACES done, so the completion signal is the pr label)
#       "is_closed_on_gitlab": bool,  # state is "closed"
#       "is_done_on_gitlab": bool,   # terminal for dispatcher: closed OR has pr
#       "has_timeout":       bool,   # labels include "timeout" (terminal until a human strips it or adds retry/continue)
#       "has_retry":         bool,   # labels include "retry" (also re-enqueues timeout issues)
#       "has_blocked_cc":         bool,  # labels include "blocked-cc" (CC-side retryable failure)
#       "has_blocked_dispatcher": bool,  # labels include "blocked-dispatcher" (dispatcher-side retryable failure)
#       "has_failed_cc":          bool,  # labels include "failed-cc" (CC-side retry exhausted)
#       "has_failed_dispatcher":  bool,  # labels include "failed-dispatcher" (dispatcher-side retry exhausted)
#       "model_tier":        <integer>,  # current model:{tier} mapped to its 0-based index in MODEL_TIERS (default flash/pro/max → 0/1/2); no model label → 0 (TIER_0)
#       "user_reopened":     bool,   # opened, no pr, and no failed-*/blocked-*/continue/contiune label; timeout is allowed only with retry
#       "needs_continue":    bool,   # opened and labels include literal "continue" (or legacy misspelling "contiune")
#       "missing":           bool    # GET returned non-OK (treat as not done)
#     }
#
# Semantics for the dispatcher (consumed in Source-of-Truth Policy):
#   - `is_closed_on_gitlab == true`                       → finished, skip
#   - `is_done_on_gitlab == true` (has `pr` or closed) AND no `needs_continue` → finished, skip
#   - `needs_continue == true`                            → re-enqueue; the
#         executor will re-run the resolution flow against the existing
#         work branch (or build one from master if none exists)
#   - `user_reopened == true`                             → re-enqueue from
#         scratch (label was reverted to todo / doing, or is done-only
#         before MR / pr completion)
#
# Closed issue state wins over every label combination, including `continue`.
# For opened issues, `needs_continue` wins over every other label combination.
# The jq below keeps `needs_continue` and `user_reopened` mutually exclusive.

set -euo pipefail

# __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?}" "${PROJECT_FULL:?}" "${DISPATCHER_LOG_DIR:?}"

# Resolve the IID iteration set: list mode takes precedence over range mode
# whenever IID_LIST is set (including the deliberate empty string for
# "narrowed to zero IIDs").
IIDS=()
if [ "${IID_LIST+set}" = "set" ]; then
  # Tokenize on commas, trim whitespace per token, drop empty tokens.
  # An entirely empty/whitespace-only IID_LIST yields an empty array → empty
  # evidence file, which is the legitimate "filter matched nothing" case.
  __raw_tokens=()
  IFS=',' read -r -a __raw_tokens <<< "${IID_LIST}"
  # nounset-safe AND quote-preserving: ${arr[@]+"${arr[@]}"} stays empty when
  # the array has no elements (safe under `set -u` even on bash < 4.4), and the
  # inner double quotes are honored so tokens are NOT re-split or glob-expanded.
  for tok in ${__raw_tokens[@]+"${__raw_tokens[@]}"}; do
    tok="${tok#"${tok%%[![:space:]]*}"}"   # ltrim
    tok="${tok%"${tok##*[![:space:]]}"}"   # rtrim
    [ -z "${tok}" ] && continue
    if ! [[ "${tok}" =~ ^[0-9]+$ ]]; then
      echo "reconcile.sh: IID_LIST token is not a non-negative integer: '${tok}'" >&2
      exit 14
    fi
    IIDS+=("${tok}")
  done
else
  : "${MIN_IID:?reconcile.sh: MIN_IID must be set when IID_LIST is unset}"
  : "${MAX_IID:?reconcile.sh: MAX_IID must be set when IID_LIST is unset}"
  while IFS= read -r iid; do
    IIDS+=("${iid}")
  done < <(seq "${MIN_IID}" "${MAX_IID}")
fi

mkdir -p "${DISPATCHER_LOG_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${DISPATCHER_LOG_DIR}/reconcile-${TS}.json"
PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"

# Model-dimension tiers (single source of truth shared with ensure_labels.sh /
# set_issue_label.sh): an ordered, comma-separated list low→high (default
# "flash,pro,max"). model_tier is the 0-based index of the highest-ranked
# model:<name> label present whose <name> is in this list; no model label → 0.
# Deriving the mapping from MODEL_TIERS (instead of a hard-coded flash/pro/max
# triple) keeps reconcile consistent when an operator overrides model_tiers.
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_TIERS_JSON="$(printf %s "${MODEL_TIERS}" \
  | tr ',' '\n' \
  | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/,""); if(length>0) print}' \
  | jq -Rsc 'split("\n") | map(select(length>0))')"
if [ "$(printf %s "${MODEL_TIERS_JSON}" | jq 'length')" -lt 1 ]; then
  echo "reconcile.sh: MODEL_TIERS resolved to an empty tier list" >&2
  exit 15
fi

# Empty IID set → write a degenerate but well-formed empty array so the
# evidence-file-must-exist invariant still holds. The dispatcher treats this
# as "filter narrowed to zero IIDs", which is distinct from "reconcile failed".
if [ "${#IIDS[@]}" -eq 0 ]; then
  printf "[]\n" > "${OUT_FILE}"
  echo "${OUT_FILE}"
  exit 0
fi

echo "[" > "${OUT_FILE}"
first=1
for iid in "${IIDS[@]}"; do
  if body="$(glab api "projects/${PROJECT_URI}/issues/${iid}" 2>/dev/null)"; then
    digest="$(echo "${body}" | jq -c --argjson iid "${iid}" --argjson tiers "${MODEL_TIERS_JSON}" '
      . as $issue |
      ($issue.labels // []) as $labels |
      # v2: pr REPLACES done, so the completion signal is the pr label.
      (($labels | index("pr") != null)) as $has_pr |
      ($issue.state == "closed") as $closed |
      (($labels | index("continue") != null) or ($labels | index("contiune") != null)) as $needs_continue |
      (($labels | index("retry") != null)) as $has_retry |
      (($labels | index("timeout") != null)) as $has_timeout |
      # v2: blocked / failed split by attribution side (CC vs dispatcher).
      (($labels | index("blocked-cc") != null)) as $has_blocked_cc |
      (($labels | index("blocked-dispatcher") != null)) as $has_blocked_dispatcher |
      (($labels | index("failed-cc") != null)) as $has_failed_cc |
      (($labels | index("failed-dispatcher") != null)) as $has_failed_dispatcher |
      ($has_blocked_cc or $has_blocked_dispatcher) as $has_blocked_any |
      ($has_failed_cc or $has_failed_dispatcher) as $has_failed_any |
      # model:{tier} → 0-based tier index over the configured $tiers list
      # (default flash/pro/max → 0/1/2). Take the HIGHEST-ranked present tier;
      # no model:<name> in $tiers present → TIER_0 (0).
      ([ $tiers | to_entries[]
         | select(("model:" + .value) as $l | ($labels | index($l)) != null)
         | .key ] | max // 0) as $model_tier |
      {
        iid: $iid,
        state: $issue.state,
        labels: $labels,
        title: $issue.title,
        has_pr: $has_pr,
        is_closed_on_gitlab: $closed,
        is_done_on_gitlab: ($closed or $has_pr),
        has_timeout: $has_timeout,
        has_retry: $has_retry,
        has_blocked_cc: $has_blocked_cc,
        has_blocked_dispatcher: $has_blocked_dispatcher,
        has_failed_cc: $has_failed_cc,
        has_failed_dispatcher: $has_failed_dispatcher,
        model_tier: $model_tier,
        user_reopened: (
          ($closed | not) and
          ($has_pr | not) and
          ($has_failed_any | not) and
          ($has_blocked_any | not) and
          (($has_timeout | not) or $has_retry) and
          ($needs_continue | not)
        ),
        needs_continue: (($closed | not) and $needs_continue),
        missing: false
      }')"
  else
    digest="$(jq -nc --argjson iid "${iid}" '{iid:$iid, state:null, labels:null, title:null, has_pr:false, is_closed_on_gitlab:false, is_done_on_gitlab:false, has_timeout:false, has_retry:false, has_blocked_cc:false, has_blocked_dispatcher:false, has_failed_cc:false, has_failed_dispatcher:false, model_tier:0, user_reopened:false, needs_continue:false, missing:true}')"
  fi
  if [ "${first}" -eq 1 ]; then first=0; else printf ",\n" >> "${OUT_FILE}"; fi
  printf "  %s" "${digest}" >> "${OUT_FILE}"
done
printf "\n]\n" >> "${OUT_FILE}"

echo "${OUT_FILE}"
