#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SKILL_DIR}/scripts/merge_mr.sh"

fail() {
  echo "test_merge_mr.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/merge-mr.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "${FIXTURE_SCRIPTS}" "${FAKE_BIN}"
cp "${HELPER}" "${FIXTURE_SCRIPTS}/merge_mr.sh"
chmod +x "${FIXTURE_SCRIPTS}/merge_mr.sh"

cat >"${FIXTURE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PROJECT_URI='group%2Frepo'
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GLAB_LOG:?}"

if [ "${1:-}" != api ]; then
  exit 90
fi
shift

if [ "${1:-}" = --method ] && [ "${2:-}" = PUT ]; then
  case "${GLAB_SCENARIO:?}" in
    api_fail_but_merged) exit 1 ;;
    *) printf '%s\n' '{"state":"accepted"}'; exit 0 ;;
  esac
fi

count=0
if [ -f "${GLAB_COUNT_FILE:?}" ]; then
  count="$(cat "${GLAB_COUNT_FILE}")"
fi
count=$((count + 1))
printf '%s\n' "${count}" >"${GLAB_COUNT_FILE}"

case "${GLAB_SCENARIO}" in
  verify_merged) state=merged ;;
  attempt_merge|api_fail_but_merged)
    if [ "${count}" -eq 1 ]; then state=opened; else state=merged; fi
    ;;
  stays_open) state=opened ;;
  wrong_identity) state=merged ;;
  read_fail) exit 1 ;;
  *) exit 91 ;;
esac

target=release
[ "${GLAB_SCENARIO}" != wrong_identity ] || target=other
jq -cn \
  --arg state "${state}" \
  --arg target "${target}" '{
    iid:7,
    web_url:"https://gitlab.example.test/group/repo/-/merge_requests/7",
    source_branch:"issue/42",
    target_branch:$target,
    sha:"0123456789abcdef0123456789abcdef01234567",
    state:$state
  }'
EOF
chmod +x "${FIXTURE_SCRIPTS}/env_paths.sh" "${FAKE_BIN}/glab"

run_case() {
  local scenario="$1" mode="$2" auto_merge="$3"
  local log="${TEST_ROOT}/${scenario}-${mode}.log"
  local count_file="${TEST_ROOT}/${scenario}-${mode}.count"
  PATH="${FAKE_BIN}:${PATH}" \
  GLAB_SCENARIO="${scenario}" GLAB_LOG="${log}" GLAB_COUNT_FILE="${count_file}" \
  PROJECT=repo GROUP=group ISSUE_IID=42 ATTEMPT_NUMBER=1 \
  BRANCH=main MERGE_TARGET_BRANCH=release WORK_BRANCH=issue/42 \
  MR_IID=7 \
  MERGE_REQUEST_URL='https://gitlab.example.test/group/repo/-/merge_requests/7' \
  COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
  MERGE_MR_MODE="${mode}" AUTO_MERGE="${auto_merge}" \
    bash "${FIXTURE_SCRIPTS}/merge_mr.sh"
}

verify_out="$(run_case verify_merged verify true)" \
  || fail "read-only verify mode failed"
jq -e '
  .verified == true and .outcome == "merged"
  and .observed_state == "merged"
  and .merge_attempted == false
  and .merge_api_succeeded == false
  and (keys | sort) == ([
    "iid","merge_api_succeeded","merge_attempted","observed_state",
    "outcome","reason","sha","source_branch","target_branch",
    "verified","version","web_url"
  ] | sort)
' <<<"${verify_out}" >/dev/null || fail "verify mode returned an invalid contract"
if grep -Fq -- '--method PUT' "${TEST_ROOT}/verify_merged-verify.log"; then
  fail "verify mode issued a merge mutation"
fi

merged_out="$(run_case attempt_merge attempt true)" \
  || fail "immediate merge case failed"
jq -e '
  .verified == true and .outcome == "merged"
  and .merge_attempted == true and .merge_api_succeeded == true
' <<<"${merged_out}" >/dev/null || fail "successful PUT was not verified by a second GET"
grep -Fq -- '--method PUT projects/group%2Frepo/merge_requests/7/merge' \
  "${TEST_ROOT}/attempt_merge-attempt.log" \
  || fail "immediate merge did not use the exact MR REST endpoint"
grep -Fq -- '-f sha=0123456789abcdef0123456789abcdef01234567' \
  "${TEST_ROOT}/attempt_merge-attempt.log" \
  || fail "immediate merge omitted the source SHA fence"

ambiguous_out="$(run_case api_fail_but_merged attempt true)" \
  || fail "ambiguous merge case failed"
jq -e '
  .verified == true and .outcome == "merged"
  and .merge_attempted == true and .merge_api_succeeded == false
' <<<"${ambiguous_out}" >/dev/null \
  || fail "failed PUT with server-side merged state was not recovered"

open_out="$(run_case stays_open attempt true)" \
  || fail "still-open merge case failed"
jq -e '
  .verified == true and .outcome == "opened"
  and .merge_attempted == true
' <<<"${open_out}" >/dev/null \
  || fail "unmerged exact MR was not conservatively left opened"

wrong_out="$(run_case wrong_identity attempt true)" \
  || fail "identity mismatch case failed"
jq -e '
  .verified == false and .outcome == "unknown"
  and .merge_attempted == false and .reason == "mr_identity_mismatch"
' <<<"${wrong_out}" >/dev/null \
  || fail "identity mismatch was allowed to authorize a merge"
if grep -Fq -- '--method PUT' "${TEST_ROOT}/wrong_identity-attempt.log"; then
  fail "identity mismatch reached the merge endpoint"
fi

read_fail_out="$(run_case read_fail attempt true 2>/dev/null)" \
  || fail "read failure did not return a conservative result"
jq -e '
  .verified == false and .outcome == "unknown"
  and .merge_attempted == false and .reason == "mr_read_failed"
' <<<"${read_fail_out}" >/dev/null \
  || fail "read failure did not stay fail-closed"

echo "ok exact MR helper separates read-only verification from safe merge attempts"
