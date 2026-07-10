#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVER="${SKILL_DIR}/scripts/resolve_driven_repo_path.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-driven-repo-path.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
GIT_LOG="${TEST_ROOT}/git.log"
mkdir -p "${FAKE_BIN}"

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${GIT_LOG:?}"
if [ "$#" -ne 5 ] || [ "$1" != "-C" ] || [ "$3" != "remote" ] || [ "$4" != "get-url" ] || [ "$5" != "origin" ]; then
  echo "unexpected git invocation: $*" >&2
  exit 97
fi
if [ "$2" != "${EXPECTED_LEGACY_PATH:?}" ]; then
  echo "unexpected legacy repo path: expected ${EXPECTED_LEGACY_PATH}, got $2" >&2
  exit 96
fi

case "${FAKE_GIT_MODE:-}" in
  origin)
    printf '%s\n' "${FAKE_GIT_ORIGIN:?}"
    ;;
  fail)
    exit 23
    ;;
  *)
    echo "unexpected fake git mode: ${FAKE_GIT_MODE:-<unset>}" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${FAKE_BIN}/git"

run_resolver() {
  local project_full="$1"
  local repo_parent="$2"
  local git_mode="${3:-}"
  local git_origin="${4:-}"

  PROJECT_FULL="${project_full}" \
    REPO_PARENT_PATH="${repo_parent}" \
    GITLAB_API_PROTOCOL="http" \
    GITLAB_HOST="gitlab-b.pxsemic.tech:30000" \
    FAKE_GIT_MODE="${git_mode}" \
    FAKE_GIT_ORIGIN="${git_origin}" \
    EXPECTED_LEGACY_PATH="${repo_parent}/${project_full##*/}" \
    GIT_LOG="${GIT_LOG}" \
    PATH="${FAKE_BIN}:${PATH}" \
    "${BASH}" "${RESOLVER}"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "${actual}" != "${expected}" ]; then
    echo "${label}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

assert_project_rejected() {
  local project_full="$1"
  if run_resolver "${project_full}" "${SAFE_PARENT}" >"${TEST_ROOT}/rejected.out" 2>"${TEST_ROOT}/rejected.err"; then
    echo "expected unsafe project path to be rejected: ${project_full}" >&2
    exit 1
  fi
}

assert_parent_rejected() {
  local repo_parent="$1"
  if run_resolver "group/repo" "${repo_parent}" >"${TEST_ROOT}/rejected.out" 2>"${TEST_ROOT}/rejected.err"; then
    echo "expected unsafe clone parent to be rejected: ${repo_parent}" >&2
    exit 1
  fi
}

COLLISION_PARENT="${TEST_ROOT}/collision/repos"
mkdir -p "${COLLISION_PARENT}"
: >"${GIT_LOG}"

path_a="$(run_resolver "group-a/repo" "${COLLISION_PARENT}")"
path_b="$(run_resolver "group-b/repo" "${COLLISION_PARENT}")"
assert_eq "${COLLISION_PARENT}/group-a/repo" "${path_a}" "first same-name project path"
assert_eq "${COLLISION_PARENT}/group-b/repo" "${path_b}" "second same-name project path"
if [ "${path_a}" = "${path_b}" ]; then
  echo "same-name projects from different groups must not share a clone path" >&2
  exit 1
fi
if [ -s "${GIT_LOG}" ]; then
  echo "git must not be queried when no legacy clone exists" >&2
  cat "${GIT_LOG}" >&2
  exit 1
fi
if [ -e "${path_a}" ] || [ -e "${path_b}" ]; then
  echo "resolver must not create clone targets" >&2
  exit 1
fi

multi_group_path="$(run_resolver "division/platform/services/repo" "${COLLISION_PARENT}")"
assert_eq "${COLLISION_PARENT}/division/platform/services/repo" "${multi_group_path}" "multi-level group path"

LEGACY_PARENT="${TEST_ROOT}/legacy/repos"
LEGACY_PATH="${LEGACY_PARENT}/repo"
mkdir -p "${LEGACY_PATH}/.git"

: >"${GIT_LOG}"
matching_path="$(run_resolver \
  "group-a/repo" \
  "${LEGACY_PARENT}" \
  origin \
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git")"
assert_eq "${LEGACY_PATH}" "${matching_path}" "matching legacy origin"

mismatching_path="$(run_resolver \
  "group-b/repo" \
  "${LEGACY_PARENT}" \
  origin \
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git")"
assert_eq "${LEGACY_PARENT}/group-b/repo" "${mismatching_path}" "mismatching legacy origin"

mismatching_origins=(
  "https://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git"
  "http://oauth2:masked-token@gitlab-other.pxsemic.tech:30000/group-a/repo.git"
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech/group-a/repo.git"
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30001/group-a/repo.git"
  "http://oauth2:masked-token@GitLab-b.pxsemic.tech:30000/group-a/repo.git"
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git/"
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo"
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-a/repo.git.git"
)
for mismatching_origin in "${mismatching_origins[@]}"; do
  mismatching_path="$(run_resolver "group-a/repo" "${LEGACY_PARENT}" origin "${mismatching_origin}")"
  assert_eq "${LEGACY_PARENT}/group-a/repo" "${mismatching_path}" "strict legacy origin mismatch"
done

failed_query_path="$(run_resolver "group-c/repo" "${LEGACY_PARENT}" fail)"
assert_eq "${LEGACY_PARENT}/group-c/repo" "${failed_query_path}" "failed legacy origin query"

GIT_FILE_PARENT="${TEST_ROOT}/git-file/repos"
GIT_FILE_LEGACY_PATH="${GIT_FILE_PARENT}/repo"
mkdir -p "${GIT_FILE_LEGACY_PATH}"
printf '%s\n' 'gitdir: ../objects/repo.git' >"${GIT_FILE_LEGACY_PATH}/.git"
git_file_path="$(run_resolver \
  "group-file/repo" \
  "${GIT_FILE_PARENT}" \
  origin \
  "http://oauth2:masked-token@gitlab-b.pxsemic.tech:30000/group-file/repo.git")"
assert_eq "${GIT_FILE_LEGACY_PATH}" "${git_file_path}" "matching legacy origin with .git file"

if grep -q 'set-url' "${GIT_LOG}"; then
  echo "resolver must never rewrite a legacy origin" >&2
  cat "${GIT_LOG}" >&2
  exit 1
fi
if [ "$(grep -c ' remote get-url origin$' "${GIT_LOG}")" -ne 12 ]; then
  echo "expected one read-only origin query for each legacy lookup" >&2
  cat "${GIT_LOG}" >&2
  exit 1
fi

SAFE_PARENT="${TEST_ROOT}/safe_parent"
mkdir -p "${SAFE_PARENT}"

unsafe_projects=(
  "repo"
  "/group/repo"
  "group/repo/"
  "group//repo"
  "group/./repo"
  "group/../repo"
  "group/bad repo"
  "group/repo@other"
  $'group/repo\nother'
  $'group/repo\001other'
)
for unsafe_project in "${unsafe_projects[@]}"; do
  assert_project_rejected "${unsafe_project}"
done

unsafe_parents=(
  "relative/path"
  "/"
  "//server/share"
  "/tmp/../escape"
  "/tmp/./escape"
  "/tmp/unsafe path"
  $'/tmp/control\001path'
)
for unsafe_parent in "${unsafe_parents[@]}"; do
  assert_parent_rejected "${unsafe_parent}"
done

DISPATCH_CONFIG="${TEST_ROOT}/dispatch-config"
DISPATCH_PARENT="${TEST_ROOT}/dispatch/repos"
PREPARE_TICK="${TEST_ROOT}/prepare_tick.sh"
PREPARE_LOG="${TEST_ROOT}/prepare.log"
mkdir -p "${DISPATCH_CONFIG}" "${DISPATCH_PARENT}"

cat >"${DISPATCH_CONFIG}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=gitlab-env-token
EOF
cat >"${DISPATCH_CONFIG}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${DISPATCH_PARENT}
EOF
cat >"${PREPARE_TICK}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

trigger="$(cat)"
printf '%s\n' "${trigger}" >>"${PREPARE_LOG:?}"

if [ "${FAKE_PREPARE_MODE:-clone}" = "fail" ]; then
  printf '%s\n' '{"status":"prepare-failed"}'
  exit 37
fi
if [ "${FAKE_PREPARE_MODE:-clone}" = "no-clone" ]; then
  printf '%s\n' '{"status":"prepared-without-clone"}'
  exit 0
fi

project="$(printf '%s\n' "${trigger}" | sed -n 's/^project=//p')"
repo_parent="$(printf '%s\n' "${trigger}" | sed -n 's/^repo_path=//p')"
repo_target="${repo_parent}/${project}"
if [ -e "${repo_target}" ] && [ ! -e "${repo_target}/.git" ]; then
  echo "prepare tick saw a pre-created non-git clone target: ${repo_target}" >&2
  exit 91
fi
mkdir -p "${repo_target}/.git"
printf '%s\n' '{"status":"prepared"}'
EOF
chmod +x "${PREPARE_TICK}"
: >"${PREPARE_LOG}"

if ! CONFIG_DIR="${DISPATCH_CONFIG}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  PREPARE_LOG="${PREPARE_LOG}" \
  FAKE_PREPARE_MODE="clone" \
  PATH="${FAKE_BIN}:${PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" \
    >"${TEST_ROOT}/dispatch.out" 2>"${TEST_ROOT}/dispatch.err" <<'EOF'
RUN_SINGLE_ISSUE
project=division/platform/repo
iid=42
correlation_id=reqd-driven-path
dispatcher_callback_target=agent:req_dispatcher:main
branch=release/2026.07
EOF
then
  echo "dispatch_single_issue.sh should resolve the full driven repo path" >&2
  cat "${TEST_ROOT}/dispatch.err" >&2
  exit 1
fi

if ! grep -Fqx '{"status":"prepared"}' "${TEST_ROOT}/dispatch.out"; then
  echo "expected captured prepare JSON to be forwarded unchanged" >&2
  cat "${TEST_ROOT}/dispatch.out" >&2
  exit 1
fi
if ! grep -Fqx "repo_path=${DISPATCH_PARENT}/division/platform" "${PREPARE_LOG}"; then
  echo "expected synthesized repo_path to be the resolved clone parent" >&2
  cat "${PREPARE_LOG}" >&2
  exit 1
fi
EXPECTED_ORIGIN_FILE="${DISPATCH_PARENT}/division/platform/repo/.req_executor/issues/issue-42/dispatch_origin.json"
if [ ! -f "${EXPECTED_ORIGIN_FILE}" ]; then
  echo "expected dispatch origin under the resolved full project clone path" >&2
  exit 1
fi
if ! grep -Fqx 'branch=release/2026.07' "${PREPARE_LOG}"; then
  echo "expected branch forwarding to survive repo path resolution" >&2
  exit 1
fi

FAILED_PROJECT_PATH="${DISPATCH_PARENT}/failure/group/repo"
if CONFIG_DIR="${DISPATCH_CONFIG}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  PREPARE_LOG="${PREPARE_LOG}" \
  FAKE_PREPARE_MODE="fail" \
  PATH="${FAKE_BIN}:${PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" \
    >"${TEST_ROOT}/prepare-failed.out" 2>"${TEST_ROOT}/prepare-failed.err" <<'EOF'
RUN_SINGLE_ISSUE
project=failure/group/repo
iid=43
correlation_id=reqd-prepare-failed
EOF
then
  echo "expected prepare failure to propagate" >&2
  exit 1
else
  prepare_status=$?
fi
if [ "${prepare_status}" -ne 37 ]; then
  echo "expected prepare failure status 37, got ${prepare_status}" >&2
  exit 1
fi
if ! grep -Fqx '{"status":"prepare-failed"}' "${TEST_ROOT}/prepare-failed.out"; then
  echo "expected failed prepare stdout to be preserved" >&2
  cat "${TEST_ROOT}/prepare-failed.out" >&2
  exit 1
fi
if [ -e "${FAILED_PROJECT_PATH}" ]; then
  echo "prepare failure must not leave a repo target or dispatch origin" >&2
  exit 1
fi

NO_CLONE_PROJECT_PATH="${DISPATCH_PARENT}/missing/clone/repo"
if CONFIG_DIR="${DISPATCH_CONFIG}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  PREPARE_LOG="${PREPARE_LOG}" \
  FAKE_PREPARE_MODE="no-clone" \
  PATH="${FAKE_BIN}:${PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" \
    >"${TEST_ROOT}/no-clone.out" 2>"${TEST_ROOT}/no-clone.err" <<'EOF'
RUN_SINGLE_ISSUE
project=missing/clone/repo
iid=47
correlation_id=reqd-no-clone
EOF
then
  echo "expected successful prepare without .git to fail" >&2
  exit 1
else
  no_clone_status=$?
fi
if [ "${no_clone_status}" -ne 12 ]; then
  echo "expected no-clone status 12, got ${no_clone_status}" >&2
  exit 1
fi
if ! grep -Fqx '{"status":"prepared-without-clone"}' "${TEST_ROOT}/no-clone.out"; then
  echo "expected no-clone prepare stdout to be preserved" >&2
  cat "${TEST_ROOT}/no-clone.out" >&2
  exit 1
fi
if [ -e "${NO_CLONE_PROJECT_PATH}" ]; then
  echo "successful prepare without .git must not leave a repo target or origin" >&2
  exit 1
fi

CONFLICT_LEGACY_PATH="${DISPATCH_PARENT}/repo"
mkdir -p "${CONFLICT_LEGACY_PATH}/.git"
: >"${GIT_LOG}"
: >"${PREPARE_LOG}"
if CONFIG_DIR="${DISPATCH_CONFIG}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  PREPARE_LOG="${PREPARE_LOG}" \
  FAKE_PREPARE_MODE="clone" \
  FAKE_GIT_MODE="origin" \
  FAKE_GIT_ORIGIN="http://gitlab-b.pxsemic.tech:30000/group-a/repo.git" \
  EXPECTED_LEGACY_PATH="${CONFLICT_LEGACY_PATH}" \
  GIT_LOG="${GIT_LOG}" \
  PATH="${FAKE_BIN}:${PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" \
    >"${TEST_ROOT}/group-conflict.out" 2>"${TEST_ROOT}/group-conflict.err" <<'EOF'
RUN_SINGLE_ISSUE
project=group-a/repo
group=group-b
iid=44
correlation_id=reqd-group-conflict
EOF
then
  group_conflict_status=0
else
  group_conflict_status=$?
fi
group_conflict_failed=0
if [ "${group_conflict_status}" -ne 2 ]; then
  echo "expected conflicting explicit group to exit 2, got ${group_conflict_status}" >&2
  group_conflict_failed=1
fi
if [ -s "${PREPARE_LOG}" ]; then
  echo "conflicting explicit group must be rejected before prepare" >&2
  group_conflict_failed=1
fi
if [ -s "${GIT_LOG}" ]; then
  echo "conflicting explicit group must be rejected before legacy origin lookup" >&2
  cat "${GIT_LOG}" >&2
  group_conflict_failed=1
fi
if [ -e "${CONFLICT_LEGACY_PATH}/.req_executor" ]; then
  echo "conflicting explicit group must not write into the legacy repo" >&2
  group_conflict_failed=1
fi
if [ "${group_conflict_failed}" -ne 0 ]; then
  exit 1
fi

: >"${GIT_LOG}"
: >"${PREPARE_LOG}"
if ! CONFIG_DIR="${DISPATCH_CONFIG}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  PREPARE_LOG="${PREPARE_LOG}" \
  FAKE_PREPARE_MODE="clone" \
  FAKE_GIT_MODE="origin" \
  FAKE_GIT_ORIGIN="http://gitlab-b.pxsemic.tech:30000/group-a/repo.git" \
  EXPECTED_LEGACY_PATH="${CONFLICT_LEGACY_PATH}" \
  GIT_LOG="${GIT_LOG}" \
  PATH="${FAKE_BIN}:${PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" \
    >"${TEST_ROOT}/group-equal.out" 2>"${TEST_ROOT}/group-equal.err" <<'EOF'
RUN_SINGLE_ISSUE
project=group-a/repo
group=group-a
iid=45
correlation_id=reqd-group-equal
EOF
then
  echo "matching explicit group should be accepted" >&2
  cat "${TEST_ROOT}/group-equal.err" >&2
  exit 1
fi

: >"${GIT_LOG}"
: >"${PREPARE_LOG}"
if ! CONFIG_DIR="${DISPATCH_CONFIG}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  PREPARE_LOG="${PREPARE_LOG}" \
  FAKE_PREPARE_MODE="clone" \
  FAKE_GIT_MODE="origin" \
  FAKE_GIT_ORIGIN="http://gitlab-b.pxsemic.tech:30000/group-a/repo.git" \
  EXPECTED_LEGACY_PATH="${CONFLICT_LEGACY_PATH}" \
  GIT_LOG="${GIT_LOG}" \
  PATH="${FAKE_BIN}:${PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/dispatch_single_issue.sh" \
    >"${TEST_ROOT}/multi-group-equal.out" 2>"${TEST_ROOT}/multi-group-equal.err" <<'EOF'
RUN_SINGLE_ISSUE
project=division/platform/repo
group=division/platform
iid=46
correlation_id=reqd-multi-group-equal
EOF
then
  echo "matching multi-level explicit group should be accepted" >&2
  cat "${TEST_ROOT}/multi-group-equal.err" >&2
  exit 1
fi

echo "ok driven repo paths avoid collisions and safely reuse matching legacy clones"
