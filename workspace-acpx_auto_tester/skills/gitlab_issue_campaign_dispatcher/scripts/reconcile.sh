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
#       "has_pr":            bool,   # labels include "pr" (v2 completion signal: pr REPLACES done)
#       "is_closed_on_gitlab": bool,  # state is "closed"
#       "is_done_on_gitlab": bool,   # terminal for dispatcher: closed OR has_pr
#       "has_blocked_cc":    bool,   # labels include "blocked-cc" (Claude Code-side retryable failure)
#       "has_blocked_dispatcher": bool, # labels include "blocked-dispatcher" (dispatcher-side retryable failure)
#       "has_failed_cc":     bool,   # labels include "failed-cc" (CC-side retry budget exhausted, terminal)
#       "has_failed_dispatcher": bool,  # labels include "failed-dispatcher" (dispatcher-side terminal)
#       "model_tier":        <integer 0-based>, # index of the highest present model:<tier> in the configured MODEL_TIERS list (0 when none present); default flash,pro,max → flash=0/pro=1/max=2
#       "has_timeout":       bool,   # labels include "timeout" (terminal until a human strips it or adds retry/continue)
#       "has_retry":         bool,   # labels include "retry" (also re-enqueues timeout issues)
#       "user_reopened":     bool,   # opened, no completed signal, and no failed-*/blocked-*/continue/contiune label; timeout is allowed only with retry
#       "needs_continue":    bool,   # opened and labels include literal "continue" (or legacy misspelling "contiune")
#       "missing":           bool    # GET returned non-OK (treat as not done)
#     }
#
# v2 model tier: the persistent `model:{tier}` dimension is reported as a
# 0-based integer (model:flash / no label => 0, model:pro => 1, model:max
# => 2). Side-split blocked/failed signals (has_blocked_cc /
# has_blocked_dispatcher / has_failed_cc / has_failed_dispatcher) replace the
# v1 single has_blocked / has_failed signals. The CC-side variants are the
# ones that drive model-upgrade decisions in PREPARE; dispatcher-side
# variants never upgrade the model.
#
# Semantics for the dispatcher (consumed in Source-of-Truth Policy):
#   - `is_closed_on_gitlab == true`                       → finished, skip
#   - `is_done_on_gitlab == true` AND no `needs_continue` → finished, skip
#         (v2: `is_done_on_gitlab` is closed OR `has_pr`; `done` alone is the
#         pre-MR transient state and is NOT terminal completion)
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

# Configuration-driven model tier order. MODEL_TIERS is an ordered,
# comma-separated list (the dispatcher passes the trigger-configured
# model_tiers through). It defaults to "flash,pro,max" so the reported
# model_tier integers are unchanged for the default deployment
# (model:flash => 0, model:pro => 1, model:max => 2). The reported tier is
# the highest 0-based index whose model:<tier> label is present (0 when none
# is present, including the lowest tier).
MODEL_TIERS="${MODEL_TIERS:-flash,pro,max}"
MODEL_TIERS_JSON="$(printf '%s' "${MODEL_TIERS}" \
  | tr ',' '\n' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | jq -Rsc 'split("\n") | map(select(length>0))')"

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
      # v2: pr REPLACES done; the completion signal is just the `pr` label.
      ($labels | index("pr") != null) as $has_pr |
      ($issue.state == "closed") as $closed |
      (($labels | index("continue") != null) or ($labels | index("contiune") != null)) as $needs_continue |
      (($labels | index("retry") != null)) as $has_retry |
      (($labels | index("timeout") != null)) as $has_timeout |
      ($labels | index("blocked-cc") != null) as $has_blocked_cc |
      ($labels | index("blocked-dispatcher") != null) as $has_blocked_dispatcher |
      ($labels | index("failed-cc") != null) as $has_failed_cc |
      ($labels | index("failed-dispatcher") != null) as $has_failed_dispatcher |
      # Persistent model tier as a 0-based integer, indexed against the
      # configured ordered tier list ($tiers). Highest present tier wins
      # (defensive: the model dimension is internally exclusive, so at most
      # one is ever set, but max() tolerates a stale duplicate). A model:<name>
      # label whose <name> is not in the configured list is ignored, so a tier
      # list shrunk by config drift never yields an out-of-range index.
      ([ $tiers | to_entries[]
          | . as $e
          | select(($labels | index("model:" + $e.value)) != null)
          | $e.key ]
        | if length == 0 then 0 else max end) as $model_tier |
      {
        iid: $iid,
        state: $issue.state,
        labels: $labels,
        title: $issue.title,
        has_pr: $has_pr,
        is_closed_on_gitlab: $closed,
        is_done_on_gitlab: ($closed or $has_pr),
        has_blocked_cc: $has_blocked_cc,
        has_blocked_dispatcher: $has_blocked_dispatcher,
        has_failed_cc: $has_failed_cc,
        has_failed_dispatcher: $has_failed_dispatcher,
        model_tier: $model_tier,
        has_timeout: $has_timeout,
        has_retry: $has_retry,
        user_reopened: (
          ($closed | not) and
          ($has_pr | not) and
          ($has_failed_cc | not) and
          ($has_failed_dispatcher | not) and
          ($has_blocked_cc | not) and
          ($has_blocked_dispatcher | not) and
          (($has_timeout | not) or $has_retry) and
          ($needs_continue | not)
        ),
        needs_continue: (($closed | not) and $needs_continue),
        missing: false
      }')"
  else
    digest="$(jq -nc --argjson iid "${iid}" '{iid:$iid, state:null, labels:null, title:null, has_pr:false, is_closed_on_gitlab:false, is_done_on_gitlab:false, has_blocked_cc:false, has_blocked_dispatcher:false, has_failed_cc:false, has_failed_dispatcher:false, model_tier:0, has_timeout:false, has_retry:false, user_reopened:false, needs_continue:false, missing:true}')"
  fi
  if [ "${first}" -eq 1 ]; then first=0; else printf ",\n" >> "${OUT_FILE}"; fi
  printf "  %s" "${digest}" >> "${OUT_FILE}"
done
printf "\n]\n" >> "${OUT_FILE}"

echo "${OUT_FILE}"
