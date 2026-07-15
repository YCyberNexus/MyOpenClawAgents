#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/set-label-finish-guard.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
GLAB_LOG="${TEST_ROOT}/glab.log"
mkdir -p "${FIXTURE_SCRIPTS}" "${FAKE_BIN}"
cp "${SKILL_DIR}/scripts/set_issue_label.sh" "${FIXTURE_SCRIPTS}/set_issue_label.sh"

fail() {
  echo "test_set_issue_label_finish_guard.sh: $*" >&2
  exit 1
}

cat >"${FIXTURE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export GITLAB_HOST=gitlab.example.test
export PROJECT_URI=group%2Frepo
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GLAB_LOG:?}"
if [ "${1:-}" != api ]; then
  exit 90
fi
if [ "${2:-}" = --method ]; then
  exit 0
fi
jq -cn --argjson labels "${GLAB_LABELS_JSON:-[]}" \
  --arg state "${GLAB_STATE:-opened}" '{labels:$labels,state:$state}'
EOF
chmod +x "${FIXTURE_SCRIPTS}/set_issue_label.sh" \
  "${FIXTURE_SCRIPTS}/env_paths.sh" "${FAKE_BIN}/glab"

: >"${GLAB_LOG}"
finish_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["finish","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add pr
)" || fail "finish-preserving pr transition failed"
[ "${finish_out}" = 'preserve:finish' ] \
  || fail "live finish was not preserved"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 1 ] \
  || fail "finish guard issued a mutating GitLab call"
grep -Fxq 'api projects/group%2Frepo/issues/42' "${GLAB_LOG}" \
  || fail "finish guard did not perform the narrow live read"

: >"${GLAB_LOG}"
failed_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["finish","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add failed-dispatcher
)" || fail "finish-preserving failure transition failed"
[ "${failed_out}" = 'preserve:finish' ] \
  || fail "a late failure label was allowed to replace finish"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 1 ] \
  || fail "failure-label finish guard issued a mutating GitLab call"

: >"${GLAB_LOG}"
late_pr_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["pr","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add doing
)" || fail "pr-preserving doing transition failed"
[ "${late_pr_out}" = 'preserve:pr' ] \
  || fail "a late pr was allowed to be replaced by doing"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 1 ] \
  || fail "pr guard issued a mutating GitLab call"

: >"${GLAB_LOG}"
closed_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_STATE=closed GLAB_LABELS_JSON='[]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add doing
)" || fail "closed-state-preserving doing transition failed"
[ "${closed_out}" = 'preserve:closed' ] \
  || fail "a closed Issue was allowed to transition to doing"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 1 ] \
  || fail "closed-state guard issued a mutating GitLab call"

: >"${GLAB_LOG}"
pr_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["done","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add pr
)" || fail "ordinary pr transition failed"
grep -Fq 'add:pr' <<<"${pr_out}" \
  || fail "ordinary pr transition was not applied"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 2 ] \
  || fail "ordinary pr transition did not perform one read and one update"
grep -Fq -- '-f add_labels=pr' "${GLAB_LOG}" \
  || fail "ordinary pr update omitted add_labels=pr"
if grep -Fq 'custom' "${GLAB_LOG}"; then
  fail "ordinary pr transition attempted to remove a custom label"
fi

: >"${GLAB_LOG}"
finish_add_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add finish
)" || fail "finish transition failed"
grep -Fq 'add:finish' <<<"${finish_add_out}" \
  || fail "finish transition was not applied"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 1 ] \
  || fail "finish transition performed an unnecessary pre-read"
grep -Fq -- '-f add_labels=finish' "${GLAB_LOG}" \
  || fail "finish update omitted add_labels=finish"

echo "ok finish cannot be downgraded by a late workflow transition"
