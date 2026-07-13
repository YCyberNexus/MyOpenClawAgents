#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVER="${SKILL_DIR}/scripts/resolve_driven_repo_path.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-driven-repo-path.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
GIT_LOG="${TEST_ROOT}/git.log"
mkdir -p "${FAKE_BIN}"

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GIT_LOG:?}"
[ "$#" -eq 5 ] && [ "$1" = -C ] && [ "$3" = remote ] \
  && [ "$4" = get-url ] && [ "$5" = origin ] || exit 97
[ "$2" = "${EXPECTED_LEGACY_PATH:?}" ] || exit 96
case "${FAKE_GIT_MODE:-}" in
  origin) printf '%s\n' "${FAKE_GIT_ORIGIN:?}" ;;
  fail) exit 23 ;;
  *) exit 98 ;;
esac
EOF
chmod +x "${FAKE_BIN}/git"

run_resolver() {
  local project_full="$1" repo_parent="$2"
  local git_mode="${3:-}" git_origin="${4:-}"
  PROJECT_FULL="${project_full}" \
    REPO_PARENT_PATH="${repo_parent}" \
    GITLAB_API_PROTOCOL=http \
    GITLAB_HOST=gitlab-b.pxsemic.tech:30000 \
    FAKE_GIT_MODE="${git_mode}" FAKE_GIT_ORIGIN="${git_origin}" \
    EXPECTED_LEGACY_PATH="${repo_parent}/${project_full##*/}" \
    GIT_LOG="${GIT_LOG}" PATH="${FAKE_BIN}:${PATH}" \
    "${BASH}" "${RESOLVER}"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "${actual}" = "${expected}" ] || {
    echo "${label}: expected ${expected}, got ${actual}" >&2
    exit 1
  }
}

COLLISION_PARENT="${TEST_ROOT}/collision/repos"
mkdir -p "${COLLISION_PARENT}"
: >"${GIT_LOG}"
path_a="$(run_resolver group-a/repo "${COLLISION_PARENT}")"
path_b="$(run_resolver group-b/repo "${COLLISION_PARENT}")"
assert_eq "${COLLISION_PARENT}/group-a/repo" "${path_a}" \
  "first same-name project path"
assert_eq "${COLLISION_PARENT}/group-b/repo" "${path_b}" \
  "second same-name project path"
[ "${path_a}" != "${path_b}" ] \
  || { echo "same-name projects shared a clone path" >&2; exit 1; }
[ ! -s "${GIT_LOG}" ] \
  || { echo "resolver queried git without a legacy clone" >&2; exit 1; }
multi_path="$(run_resolver division/platform/services/repo "${COLLISION_PARENT}")"
assert_eq "${COLLISION_PARENT}/division/platform/services/repo" "${multi_path}" \
  "multi-level group path"

LEGACY_PARENT="${TEST_ROOT}/legacy/repos"
LEGACY_PATH="${LEGACY_PARENT}/repo"
mkdir -p "${LEGACY_PATH}/.git"
matching_path="$(run_resolver group-a/repo "${LEGACY_PARENT}" origin \
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git')"
assert_eq "${LEGACY_PATH}" "${matching_path}" "matching legacy origin"
mismatching_path="$(run_resolver group-b/repo "${LEGACY_PARENT}" origin \
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git')"
assert_eq "${LEGACY_PARENT}/group-b/repo" "${mismatching_path}" \
  "mismatching legacy origin"
mismatching_origins=(
  'https://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git'
  'http://oauth2:masked-token@gitlab-other.pxsemic.tech:30000/group-a/repo.git'
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech/group-a/repo.git'
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30001/group-a/repo.git'
  'http://oauth2:masked-token@GitLab-b.pxsemic.tech:30000/group-a/repo.git'
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git/'
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo'
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git.git'
)
for origin in "${mismatching_origins[@]}"; do
  result="$(run_resolver group-a/repo "${LEGACY_PARENT}" origin "${origin}")"
  assert_eq "${LEGACY_PARENT}/group-a/repo" "${result}" \
    "strict legacy origin mismatch"
done
failed_query_path="$(run_resolver group-c/repo "${LEGACY_PARENT}" fail)"
assert_eq "${LEGACY_PARENT}/group-c/repo" "${failed_query_path}" \
  "failed legacy origin query"

GIT_FILE_PARENT="${TEST_ROOT}/git-file/repos"
GIT_FILE_PATH="${GIT_FILE_PARENT}/repo"
mkdir -p "${GIT_FILE_PATH}"
printf '%s\n' 'gitdir: ../objects/repo.git' >"${GIT_FILE_PATH}/.git"
git_file_result="$(run_resolver group-file/repo "${GIT_FILE_PARENT}" origin \
  'http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-file/repo.git')"
assert_eq "${GIT_FILE_PARENT}/group-file/repo" "${git_file_result}" \
  "legacy linked worktree path"
if grep -q 'set-url' "${GIT_LOG}"; then
  echo "resolver rewrote a legacy origin" >&2
  exit 1
fi

SAFE_PARENT="${TEST_ROOT}/safe-parent"
mkdir -p "${SAFE_PARENT}"
unsafe_projects=(
  repo /group/repo group/repo/ group//repo group/./repo group/../repo
  'group/bad repo' group/repo@other
  $'group/repo\nother' $'group/repo\001other'
)
for unsafe_project in "${unsafe_projects[@]}"; do
  if run_resolver "${unsafe_project}" "${SAFE_PARENT}" >/dev/null 2>&1; then
    echo "unsafe project path was accepted: ${unsafe_project}" >&2
    exit 1
  fi
done
unsafe_parents=(
  relative/path / //server/share /tmp/../escape /tmp/./escape
  '/tmp/unsafe path' $'/tmp/control\001path'
)
for unsafe_parent in "${unsafe_parents[@]}"; do
  if run_resolver group/repo "${unsafe_parent}" >/dev/null 2>&1; then
    echo "unsafe clone parent was accepted: ${unsafe_parent}" >&2
    exit 1
  fi
done

# RUN_SINGLE_ISSUE now delegates the full project identity to the driven batch
# scheduler. It does not resolve/clone a repo or write dispatch_origin.json.
CONFIG_DIR="${TEST_ROOT}/dispatch-config"
DRIVEN_BATCH="${TEST_ROOT}/run_driven_issue_batch.sh"
CAPTURE_FILE="${TEST_ROOT}/driven-trigger.txt"
mkdir -p "${CONFIG_DIR}"
cat >"${DRIVEN_BATCH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >"${CAPTURE_FILE:?}"
if [ "${DRIVEN_MODE:-success}" = fail ]; then
  printf '%s\n' '{"status":"delegate-failed"}'
  exit 37
fi
jq -cn '{status:"accepted",spawn_grants:[],reconcile_actions:[]}'
EOF
chmod +x "${DRIVEN_BATCH}"

run_single() {
  local mode="$1" input_file="$2"
  CONFIG_DIR="${CONFIG_DIR}" DRIVEN_BATCH_CMD="${DRIVEN_BATCH}" \
    CAPTURE_FILE="${CAPTURE_FILE}" DRIVEN_MODE="${mode}" \
    GIT_LOG="${GIT_LOG}" PATH="${FAKE_BIN}:${PATH}" \
    "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" <"${input_file}"
}

SUCCESS_INPUT="${TEST_ROOT}/single-success.txt"
cat >"${SUCCESS_INPUT}" <<'EOF'
RUN_SINGLE_ISSUE
project=division/platform/repo
iid=42
correlation_id=reqd-driven-path
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=7777777777777777777777777777777777777777777777777777777777777777
branch=release/2026.07
EOF
: >"${GIT_LOG}"
run_single success "${SUCCESS_INPUT}" >"${TEST_ROOT}/dispatch.out" \
  || { echo "single shim rejected a full project" >&2; exit 1; }
grep -qx 'RUN_DRIVEN_ISSUE_BATCH' "${CAPTURE_FILE}" \
  || { echo "single shim did not enter the driven scheduler" >&2; exit 1; }
grep -qx 'project=division/platform/repo' "${CAPTURE_FILE}" \
  || { echo "single shim lost the full project" >&2; exit 1; }
grep -qx 'branch=release/2026.07' "${CAPTURE_FILE}" \
  || { echo "single shim lost the branch" >&2; exit 1; }
if grep -Eq 'repo_path' "${CAPTURE_FILE}"; then
  echo "single shim copied the deployment path into driven I1" >&2
  exit 1
fi
[ ! -s "${GIT_LOG}" ] \
  || { echo "single shim performed a legacy origin lookup" >&2; exit 1; }

set +e
run_single fail "${SUCCESS_INPUT}" >"${TEST_ROOT}/delegate-failed.out"
delegate_rc=$?
set -e
[ "${delegate_rc}" -eq 37 ] \
  || { echo "delegate failure did not propagate" >&2; exit 1; }
grep -Fqx '{"status":"delegate-failed"}' "${TEST_ROOT}/delegate-failed.out" \
  || { echo "delegate failure output was lost" >&2; exit 1; }

CONFLICT_INPUT="${TEST_ROOT}/single-conflict.txt"
cat >"${CONFLICT_INPUT}" <<'EOF'
RUN_SINGLE_ISSUE
project=group-a/repo
group=group-b
iid=44
correlation_id=reqd-group-conflict
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=7777777777777777777777777777777777777777777777777777777777777777
EOF
: >"${CAPTURE_FILE}"
set +e
run_single success "${CONFLICT_INPUT}" >/dev/null 2>"${TEST_ROOT}/conflict.err"
conflict_rc=$?
set -e
[ "${conflict_rc}" -eq 2 ] \
  || { echo "conflicting explicit group was accepted" >&2; exit 1; }
[ ! -s "${CAPTURE_FILE}" ] \
  || { echo "group conflict reached the driven wrapper" >&2; exit 1; }

for group_spec in 'group-a/repo group-a' \
  'division/platform/repo division/platform'
do
  project="${group_spec% *}"
  group="${group_spec##* }"
  input_file="${TEST_ROOT}/single-group-${group//\//_}.txt"
  cat >"${input_file}" <<EOF
RUN_SINGLE_ISSUE
project=${project}
group=${group}
iid=45
correlation_id=reqd-group-equal
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=7777777777777777777777777777777777777777777777777777777777777777
EOF
  run_single success "${input_file}" >/dev/null \
    || { echo "matching explicit group was rejected: ${group}" >&2; exit 1; }
done

echo "ok driven repo paths and single batch delegation avoid project collisions"
