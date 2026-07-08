#!/usr/bin/env bash
# write_branch_summary.sh — write a per-attempt SCORECARD summary.md INSIDE the
# shared per-issue worktree so it lands on the immutable per-attempt branch
# ${LOCAL_ATTEMPT_BRANCH} for a successful (done) run.
#
# Scope — done branches ONLY. The executor calls this from the NORMAL flow as
# Step 2.5, between Step 2 (stage_and_guard.sh → STAGED_OK) and Step 3
# (commit_and_push.sh). It is deliberately NOT wired into <blocked_push_flow>
# or <timeout_flow>, so failed / timed-out attempt branches do NOT carry a
# summary.md. That is exactly the "仅成功 done 分支带成绩单" requirement.
#
# Why AFTER STAGED_OK, not before — force-adding summary.md ahead of the
# NO_CHANGES test in stage_and_guard.sh would always present a staged file and
# mask an empty (Claude-produced-nothing) attempt, defeating the NO_CHANGES →
# blocked signal. By running only after STAGED_OK, an empty attempt has already
# short-circuited to blocked and never reaches this script.
#
# Content — a key-value markdown scorecard with five dimensions: Issue,
# Attempt, Model, Time (wall_clock_seconds), Accuracy (Robot-Framework pass
# rate). NO commit sha and NO branch name: the file lives ON the attempt branch,
# so the branch itself identifies the run (a commit cannot embed its own sha —
# the chicken-and-egg this placement is built around).
#
# BEST-EFFORT (same contract as collect_metrics.sh): a missing/garbled
# metrics.json degrades Time → "n/a" / Accuracy → "N/A"; a failed `git add -f`
# only warns. The only hard failure is a genuine inability to WRITE summary.md
# (unwritable dir), which exits non-zero. The executor treats ANY non-zero exit
# as best-effort: it NOTEs it and still proceeds to Step 3, so this script can
# never block the pending commit / done.
#
# Required env: BRANCH_SUMMARY_FILE, LOG_DIR, ISSUE_IID, ATTEMPT_NUMBER_PADDED
#               Production additionally requires MODEL: env_paths.sh enforces it
#               as required whenever ISSUE_IID is set (LOG_DIR and
#               LOCAL_ATTEMPT_BRANCH carry the tier suffix), so a missing MODEL
#               exits inside env_paths.sh BEFORE this script's body runs. The
#               "unknown" fallback below is therefore reachable ONLY under the
#               WRITE_BRANCH_SUMMARY_SKIP_ENV_PATHS unit-test hatch.
# Optional env: WORKTREE_DIR   (git add -f cwd; the add is skipped when this is
#                               unset or is not a git worktree)
#               WRITE_BRANCH_SUMMARY_SKIP_ENV_PATHS=1  (unit-test escape hatch:
#                               skip sourcing env_paths.sh so the script can run
#                               from fixtures without the full trigger env)
#
# Output: writes ${BRANCH_SUMMARY_FILE} and prints its path on stdout.

# NOTE: intentionally NOT `set -e` — best-effort, mirroring collect_metrics.sh.
set +e

if [ "${WRITE_BRANCH_SUMMARY_SKIP_ENV_PATHS:-0}" != "1" ]; then
  # __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"
fi

: "${BRANCH_SUMMARY_FILE:?write_branch_summary: BRANCH_SUMMARY_FILE required}"
: "${LOG_DIR:?write_branch_summary: LOG_DIR required}"
: "${ISSUE_IID:?write_branch_summary: ISSUE_IID required}"
: "${ATTEMPT_NUMBER_PADDED:?write_branch_summary: ATTEMPT_NUMBER_PADDED required}"
MODEL="${MODEL:-}"
model_display="${MODEL:-unknown}"

metrics="${LOG_DIR}/metrics.json"

# ── Time: wall_clock_seconds from metrics.json (collect_metrics.sh) ──────────
wall_display="n/a"
if [ -f "${metrics}" ] && command -v jq >/dev/null 2>&1; then
  w="$(jq -r '.wall_clock_seconds // empty' "${metrics}" 2>/dev/null)"
  case "${w}" in
    ''|*[!0-9]*) : ;;                       # null / missing / non-numeric → n/a
    *) wall_display="${w}s" ;;
  esac
fi

# ── Accuracy: Robot-Framework pass rate from metrics.json.accuracy ───────────
# available:false (scan/gen mode, no output.xml) or any garble → "N/A".
acc_display="N/A"
if [ -f "${metrics}" ] && command -v jq >/dev/null 2>&1; then
  available="$(jq -r '.accuracy.available // false' "${metrics}" 2>/dev/null)"
  if [ "${available}" = "true" ]; then
    p="$(jq -r '.accuracy.passed // 0' "${metrics}" 2>/dev/null)"
    f="$(jq -r '.accuracy.failed // 0' "${metrics}" 2>/dev/null)"
    r="$(jq -r '.accuracy.pass_rate // empty' "${metrics}" 2>/dev/null)"
    case "${p}" in ''|*[!0-9]*) p=0 ;; esac
    case "${f}" in ''|*[!0-9]*) f=0 ;; esac
    # r feeds an awk arithmetic expression below; restrict to a numeric literal
    # so a garbled value can never inject into the awk program.
    case "${r}" in ''|*[!0-9.]*) r="" ;; esac
    denom=$(( p + f ))
    pct=""
    if [ -n "${r}" ]; then
      pct="$(awk "BEGIN{printf \"%.1f\", ${r} * 100}" 2>/dev/null)"
    fi
    if [ "${denom}" -gt 0 ]; then
      if [ -n "${pct}" ]; then
        acc_display="${p}/${denom} passed (${pct}%)"
      else
        acc_display="${p}/${denom} passed"
      fi
    fi
  fi
fi

# ── write the scorecard ──────────────────────────────────────────────────────
# A genuine write failure (unwritable dir) is the only hard error: surface it
# non-zero rather than silently losing the scorecard. The executor still treats
# it as best-effort and proceeds to the commit.
mkdir -p "$(dirname "${BRANCH_SUMMARY_FILE}")" 2>/dev/null
if ! {
  printf '# acpx_auto_tester_test — issue #%s attempt %s (%s)\n\n' \
    "${ISSUE_IID}" "${ATTEMPT_NUMBER_PADDED}" "${model_display}"
  printf -- '- Issue: #%s\n'   "${ISSUE_IID}"
  printf -- '- Attempt: %s\n'  "${ATTEMPT_NUMBER_PADDED}"
  printf -- '- Model: %s\n'    "${model_display}"
  printf -- '- Time: %s\n'     "${wall_display}"
  printf -- '- Accuracy: %s\n' "${acc_display}"
} > "${BRANCH_SUMMARY_FILE}"; then
  echo "write_branch_summary: FATAL — failed to write ${BRANCH_SUMMARY_FILE}" >&2
  exit 1
fi

# ── force-add so it survives the /${RESULT_BASENAME}/ line in .git/info/exclude ─
# Best-effort: a non-git context (unit test) or an add failure only warns — the
# file is already on disk and the pending commit must never be blocked. A linked
# worktree's .git is a FILE (gitdir pointer), so probe with rev-parse, not -d.
if [ -n "${WORKTREE_DIR:-}" ] && \
   git -C "${WORKTREE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${WORKTREE_DIR}" add -f "${BRANCH_SUMMARY_FILE}" \
    || echo "write_branch_summary: WARN — git add -f failed for ${BRANCH_SUMMARY_FILE}" >&2
else
  echo "write_branch_summary: WARN — WORKTREE_DIR unset or not a git worktree; skipped git add -f" >&2
fi

echo "${BRANCH_SUMMARY_FILE}"
exit 0
