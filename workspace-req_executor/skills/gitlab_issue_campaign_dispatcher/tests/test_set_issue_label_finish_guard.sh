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
  labels="${GLAB_LABELS_JSON:-[]}"
  state="${GLAB_STATE:-opened}"
  if [ "${GLAB_UPDATE_STALE:-0}" != 1 ]; then
    add_label=""
    remove_labels=""
    for arg in "$@"; do
      case "${arg}" in
        add_labels=*) add_label="${arg#add_labels=}" ;;
        remove_labels=*) remove_labels="${arg#remove_labels=}" ;;
      esac
    done
    labels="$(jq -c --arg remove_labels "${remove_labels}" --arg add_label "${add_label}" '
      ($remove_labels | split(",") | map(select(length > 0))) as $removed
      | map(select(. as $candidate_label | ($removed | index($candidate_label)) == null))
      | if $add_label != "" and index($add_label) == null
        then . + [$add_label] else . end
    ' <<<"${labels}")"
  fi
  jq -cn --argjson labels "${labels}" --arg state "${state}" \
    '{labels:$labels,state:$state}'
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
remove_retry_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["retry","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" remove retry
)" || fail "retry removal failed"
[ "${remove_retry_out}" = 'remove:retry' ] \
  || fail "retry removal was not confirmed from the GitLab response"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 1 ] \
  || fail "retry removal performed an unexpected GitLab call"

: >"${GLAB_LOG}"
doing_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["retry","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add doing
)" || fail "retry-to-doing transition failed"
grep -Fq 'add:doing' <<<"${doing_out}" \
  || fail "retry-to-doing transition was not confirmed"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 2 ] \
  || fail "retry-to-doing transition did not perform one read and one update"
grep -Fq 'retry' "${GLAB_LOG}" \
  || fail "retry-to-doing transition did not remove the retry label"

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
existing_pr_out="$(
  PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
  GLAB_LABELS_JSON='["pr","done","custom"]' ISSUE_IID=42 \
    bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add pr
)" || fail "existing pr convergence failed"
grep -Fq 'add:pr' <<<"${existing_pr_out}" \
  || fail "existing pr short-circuited before conflict cleanup"
[ "$(wc -l <"${GLAB_LOG}" | tr -d ' ')" = 2 ] \
  || fail "existing pr convergence did not perform one read and one update"
grep -Fq -- '-f remove_labels=' "${GLAB_LOG}" \
  || fail "existing pr convergence omitted conflict removal"
grep -Fq 'done' "${GLAB_LOG}" \
  || fail "existing pr convergence did not remove residual done"
if grep -Fq 'custom' "${GLAB_LOG}"; then
  fail "existing pr convergence attempted to remove a custom label"
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

: >"${GLAB_LOG}"
set +e
PATH="${FAKE_BIN}:${PATH}" GLAB_LOG="${GLAB_LOG}" \
GLAB_LABELS_JSON='["doing","custom"]' GLAB_UPDATE_STALE=1 ISSUE_IID=42 \
  bash "${FIXTURE_SCRIPTS}/set_issue_label.sh" add blocked-cc \
  >"${TEST_ROOT}/stale.stdout" 2>"${TEST_ROOT}/stale.stderr"
stale_rc=$?
set -e
[ "${stale_rc}" -eq 4 ] \
  || fail "an unapplied workflow-label update was reported as success"
grep -Fq 'did not apply add blocked-cc atomically' \
  "${TEST_ROOT}/stale.stderr" \
  || fail "an unapplied workflow-label update lacked a precise error"

echo "ok finish cannot be downgraded by a late workflow transition"
