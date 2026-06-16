#!/usr/bin/env bash
# Local smoke test for write_branch_summary.sh — runnable on the dev machine
# (no acpx / glab / git worktree needed). Drives the script via the
# WRITE_BRANCH_SUMMARY_SKIP_ENV_PATHS escape hatch with inline metrics.json
# fixtures and asserts the rendered scorecard. WORKTREE_DIR is left unset so the
# best-effort `git add -f` is skipped (the script still exits 0).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

run_summary() {
  # $1 = LOG_DIR, $2 = BRANCH_SUMMARY_FILE, $3 = iid, $4 = padded attempt, $5 = model
  BRANCH_SUMMARY_FILE="$2" LOG_DIR="$1" ISSUE_IID="$3" \
    ATTEMPT_NUMBER_PADDED="$4" MODEL="$5" \
    WRITE_BRANCH_SUMMARY_SKIP_ENV_PATHS=1 \
    bash "${SCRIPTS}/write_branch_summary.sh" 2>/dev/null
}

# ── case 1: available:true accuracy + integer wall ───────────────────────────
L1="${TMP}/c1/log"; mkdir -p "${L1}"
S1="${TMP}/c1/issue-14/summary.md"
cat > "${L1}/metrics.json" <<'JSON'
{"iid":14,"attempt_number":2,"model":"pro","wall_clock_seconds":2545,
 "accuracy":{"available":true,"passed":23,"failed":23,"skipped":0,"total":46,"pass_rate":0.5,"robot_files":2}}
JSON
out1="$(run_summary "${L1}" "${S1}" 14 002 pro)"
[ "${out1}" = "${S1}" ]                                          || fail "case1 stdout path: ${out1}"
[ -f "${S1}" ]                                                  || fail "case1 summary.md not written"
grep -qxF -- "- Issue: #14"                    "${S1}"          || fail "case1 Issue"
grep -qxF -- "- Attempt: 002"                  "${S1}"          || fail "case1 Attempt"
grep -qxF -- "- Model: pro"                    "${S1}"          || fail "case1 Model"
grep -qxF -- "- Time: 2545s"                   "${S1}"          || fail "case1 Time"
grep -qxF -- "- Accuracy: 23/46 passed (50.0%)" "${S1}"         || fail "case1 Accuracy: $(grep Accuracy "${S1}")"

# ── case 2: available:false accuracy (scan/gen mode) ─────────────────────────
L2="${TMP}/c2/log"; mkdir -p "${L2}"
S2="${TMP}/c2/issue-7/summary.md"
cat > "${L2}/metrics.json" <<'JSON'
{"iid":7,"attempt_number":1,"model":"flash","wall_clock_seconds":297,
 "accuracy":{"available":false}}
JSON
run_summary "${L2}" "${S2}" 7 001 flash >/dev/null
grep -qxF -- "- Time: 297s"   "${S2}"                           || fail "case2 Time"
grep -qxF -- "- Accuracy: N/A" "${S2}"                          || fail "case2 Accuracy: $(grep Accuracy "${S2}")"

# ── case 3: missing metrics.json → graceful degrade ──────────────────────────
L3="${TMP}/c3/log"; mkdir -p "${L3}"   # no metrics.json
S3="${TMP}/c3/issue-9/summary.md"
run_summary "${L3}" "${S3}" 9 003 max >/dev/null
grep -qxF -- "- Model: max"    "${S3}"                          || fail "case3 Model"
grep -qxF -- "- Time: n/a"     "${S3}"                          || fail "case3 Time degrade"
grep -qxF -- "- Accuracy: N/A" "${S3}"                          || fail "case3 Accuracy degrade"

# ── case 4: real linked git worktree → force-add lands summary.md in index ───
# Covers the production main path: the /ifp-result/ exclude hides the subtree
# from `git add -A`, and write_branch_summary.sh must force-add through it via
# the rev-parse worktree probe. A linked worktree's .git is a FILE.
if command -v git >/dev/null 2>&1; then
  REPO="${TMP}/repo"; mkdir -p "${REPO}"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email t@t; git -C "${REPO}" config user.name t
  : > "${REPO}/seed"; git -C "${REPO}" add seed; git -C "${REPO}" commit -qm seed
  WT="${TMP}/wt"
  git -C "${REPO}" worktree add -q "${WT}" -b wb >/dev/null 2>&1
  printf '/ifp-result/\n' >> "${REPO}/.git/info/exclude"   # repo-wide, covers WT
  L4="${WT}/ifp-result/issue-5/log"; mkdir -p "${L4}"
  printf '{"wall_clock_seconds":10,"accuracy":{"available":false}}\n' > "${L4}/metrics.json"
  S4="${WT}/ifp-result/issue-5/summary.md"
  BRANCH_SUMMARY_FILE="${S4}" LOG_DIR="${L4}" ISSUE_IID=5 \
    ATTEMPT_NUMBER_PADDED=001 MODEL=pro WORKTREE_DIR="${WT}" \
    WRITE_BRANCH_SUMMARY_SKIP_ENV_PATHS=1 \
    bash "${SCRIPTS}/write_branch_summary.sh" >/dev/null 2>&1
  staged="$(git -C "${WT}" diff --cached --name-only)"
  printf '%s\n' "${staged}" | grep -qxF "ifp-result/issue-5/summary.md" \
    || fail "case4 summary.md not force-added through exclude (staged: ${staged})"
else
  echo "SKIP case4 (git unavailable)"
fi

echo "PASS test_write_branch_summary"
