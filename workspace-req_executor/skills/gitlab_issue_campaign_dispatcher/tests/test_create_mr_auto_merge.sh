#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "test_create_mr_auto_merge.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/create-mr-auto.XXXXXX")"
FIXTURE_SCRIPTS="${TEST_ROOT}/scripts"
FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "${FIXTURE_SCRIPTS}" "${FAKE_BIN}"
cp "${SKILL_DIR}/scripts/create_mr.sh" "${SKILL_DIR}/scripts/merge_mr.sh" \
  "${FIXTURE_SCRIPTS}/"
chmod +x "${FIXTURE_SCRIPTS}/create_mr.sh" "${FIXTURE_SCRIPTS}/merge_mr.sh"

cat >"${FIXTURE_SCRIPTS}/env_paths.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PROJECT_FULL='group/repo'
export PROJECT_URI='group%2Frepo'
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GLAB_LOG:?}"

case "${1:-} ${2:-}" in
  'mr list')
    if [ "${GLAB_SCENARIO:?}" = list_fail ]; then
      exit 1
    fi
    count=0
    if [ -f "${LIST_COUNT_FILE:?}" ]; then count="$(cat "${LIST_COUNT_FILE}")"; fi
    count=$((count + 1))
    printf '%s\n' "${count}" >"${LIST_COUNT_FILE}"
    if [ "${count}" -eq 1 ]; then
      printf '%s\n' '[]'
    else
      jq -cn '[{
        iid:7,
        web_url:"https://gitlab.example.test/group/repo/-/merge_requests/7",
        source_branch:"issue/42",
        target_branch:"release",
        state:"opened"
      }]'
    fi
    ;;
  'mr create')
    exit 0
    ;;
  'api --method')
    # Exact immediate-merge endpoint.  The following GET reports the actual
    # merged state; the PUT response itself is deliberately not trusted.
    printf '%s\n' '{"accepted":true}'
    ;;
  api*)
    api_count=0
    if [ -f "${API_COUNT_FILE:?}" ]; then api_count="$(cat "${API_COUNT_FILE}")"; fi
    api_count=$((api_count + 1))
    printf '%s\n' "${api_count}" >"${API_COUNT_FILE}"
    state=opened
    if [ "${GLAB_SCENARIO}" = merged ] && [ "${api_count}" -gt 1 ]; then
      state=merged
    fi
    jq -cn --arg state "${state}" '{
      iid:7,
      web_url:"https://gitlab.example.test/group/repo/-/merge_requests/7",
      source_branch:"issue/42",
      target_branch:"release",
      sha:"0123456789abcdef0123456789abcdef01234567",
      state:$state
    }'
    ;;
  *) exit 90 ;;
esac
EOF
chmod +x "${FIXTURE_SCRIPTS}/env_paths.sh" "${FAKE_BIN}/glab"

run_create() {
  local scenario="$1" auto_merge="$2"
  local case_name="${3:-${scenario}-${auto_merge}}" seed_mode="${4:-}"
  local case_root="${TEST_ROOT}/${case_name}"
  local worktree="${case_root}/worktree" log_dir="${case_root}/log"
  mkdir -p "${worktree}" "${log_dir}"
  case "${seed_mode}" in
    readonly)
      printf '{"stale":true}\n' >"${log_dir}/mr_result.json"
      chmod 000 "${log_dir}/mr_result.json"
      ;;
    hardlink)
      printf '{"sentinel":"must-survive"}\n' >"${case_root}/hardlink-target.json"
      ln "${case_root}/hardlink-target.json" "${log_dir}/mr_result.json"
      ;;
    '') ;;
    *) fail "unknown seed mode: ${seed_mode}" ;;
  esac
  PATH="${FAKE_BIN}:${PATH}" \
  GLAB_SCENARIO="${scenario}" GLAB_LOG="${case_root}/glab.log" \
  LIST_COUNT_FILE="${case_root}/list.count" API_COUNT_FILE="${case_root}/api.count" \
  PROJECT=repo GROUP=group ISSUE_IID=42 EXECUTION_ID=1 EXECUTION_ID=001 \
  ISSUE_MODE=fresh ISSUE_TITLE='测试 issue' \
  WORKTREE_DIR="${worktree}" LOG_DIR="${log_dir}" \
  BRANCH=main MERGE_TARGET_BRANCH=release WORK_BRANCH=issue/42 \
  AUTO_MERGE="${auto_merge}" \
  COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
    bash "${FIXTURE_SCRIPTS}/create_mr.sh"
}

merged_out="$(run_create merged true)" || fail "verified merged MR creation failed"
[ "${merged_out}" = 'https://gitlab.example.test/group/repo/-/merge_requests/7
created
7
merged' ] || fail "MR identity/outcome output contract is wrong: ${merged_out}"
merged_root="${TEST_ROOT}/merged-true"
jq -e '
  .version == 1 and .iid == 7 and .issue_iid == 42
  and .execution_id == 1 and .mr_action == "created"
  and .source_branch == "issue/42" and .target_branch == "release"
  and .dependency_base_sha == ""
  and .sha == "0123456789abcdef0123456789abcdef01234567"
  and .verified == true and .outcome == "merged"
  and .observed_state == "merged" and .auto_merge == true
' "${merged_root}/log/mr_result.json" >/dev/null \
  || fail "verified exact MR identity was not persisted"
grep -Fq -- '--target-branch release' "${merged_root}/glab.log" \
  || fail "MR was not created against MERGE_TARGET_BRANCH"
grep -Fq -- '--method PUT projects/group%2Frepo/merge_requests/7/merge' \
  "${merged_root}/glab.log" \
  || fail "auto-merge did not call the exact MR REST endpoint"

opened_out="$(run_create opened false)" || fail "ordinary MR creation failed"
[ "$(printf '%s\n' "${opened_out}" | tail -n 1)" = opened ] \
  || fail "AUTO_MERGE=false did not preserve the ordinary opened MR"
if grep -Fq -- '--method PUT' "${TEST_ROOT}/opened-false/glab.log"; then
  fail "AUTO_MERGE=false issued a merge mutation"
fi

readonly_out="$(run_create opened false opened-readonly readonly)" \
  || fail "read-only stale MR evidence blocked MR creation"
[ "$(printf '%s\n' "${readonly_out}" | tail -n 1)" = opened ] \
  || fail "read-only stale MR evidence changed the MR outcome"

hardlink_out="$(run_create opened false opened-hardlink hardlink)" \
  || fail "hard-linked stale MR evidence blocked MR creation"
[ "$(printf '%s\n' "${hardlink_out}" | tail -n 1)" = opened ] \
  || fail "hard-linked stale MR evidence changed the MR outcome"
[ "$(cat "${TEST_ROOT}/opened-hardlink/hardlink-target.json")" = \
    '{"sentinel":"must-survive"}' ] \
  || fail "MR creation truncated the hard-linked evidence target"
jq -e '.verified == true and .outcome == "opened"' \
  "${TEST_ROOT}/opened-hardlink/log/mr_result.json" >/dev/null \
  || fail "MR creation did not replace hard-linked evidence with its marker"

set +e
run_create list_fail true >"${TEST_ROOT}/list-fail.out" 2>"${TEST_ROOT}/list-fail.err"
list_fail_rc=$?
set -e
[ "${list_fail_rc}" -ne 0 ] || fail "initial MR list failure was treated as an empty list"
if grep -Fq -- 'mr create' "${TEST_ROOT}/list_fail-true/glab.log"; then
  fail "initial MR list failure reached MR creation"
fi

echo "ok MR creation is fail-closed and persists an exact merge-verification identity"
