#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVER="${SKILL_DIR}/scripts/resolve_dependency_dag_base.sh"

fail() {
  printf 'test_resolve_dependency_dag_base.sh: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  else
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  fi
}

file_mode() {
  local path="$1" mode
  if mode="$(stat -f '%Lp' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -c '%a' "${path}" 2>/dev/null
  fi
}

state_hashes() {
  local state_file
  for state_file in "${ISSUES_ROOT}"/issue-*/state.json; do
    sha256_file "${state_file}"
  done
}

create_source_commit() {
  local branch="$1" base_sha="$2" path="$3" content="$4"
  git -C "${REPO_PATH}" checkout -qB "${branch}" "${base_sha}"
  printf '%s\n' "${content}" >"${REPO_PATH}/${path}"
  git -C "${REPO_PATH}" add "${path}"
  git -C "${REPO_PATH}" commit -qm "${branch}"
  git -C "${REPO_PATH}" push -q origin "HEAD:refs/heads/${branch}"
  git -C "${REPO_PATH}" rev-parse HEAD
}

write_source_state() {
  local iid="$1" execution_id="$2" branch="$3" commit_sha="$4"
  local mr_iid="$5" dependency_plan_sha256="${6:-}"
  local dependency_plan_json="${7:-null}"
  local work_branch_sha="${8:-${commit_sha}}"
  local state_dir="${ISSUES_ROOT}/issue-${iid}"
  local mr_url="https://gitlab.example.test/group/project/-/merge_requests/${mr_iid}"
  mkdir -p "${state_dir}"
  jq -n \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg branch "${branch}" \
    --arg commit_sha "${commit_sha}" \
    --arg work_branch_sha "${work_branch_sha}" \
    --arg mr_url "${mr_url}" \
    --arg dependency_plan_sha256 "${dependency_plan_sha256}" \
    --argjson dependency_plan "${dependency_plan_json}" '{
      iid:$iid,
      status:"done",
      latest_execution_id:$execution_id,
      dependency_pinned_execution_id:$execution_id,
      work_branch:$branch,
      branch_members:[$iid],
      shared_branch_role:null,
      dependency_history_verified:true,
      commit_sha:$commit_sha,
      work_branch_sha:$work_branch_sha,
      merge_request_url:$mr_url
    }
    | if $dependency_plan_sha256 == "" then .
      else
        .dependency_contract_version=2
        | .dependency_plan_sha256=$dependency_plan_sha256
        | .dependency_plan=$dependency_plan
      end
  ' >"${state_dir}/state.json"
  chmod 600 "${state_dir}/state.json"
}

source_snapshot() {
  local iid="$1" execution_id="$2" branch="$3" commit_sha="$4" mr_iid="$5"
  local work_branch_sha="${6:-${commit_sha}}"
  jq -nc \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg branch "${branch}" \
    --arg commit_sha "${commit_sha}" \
    --arg work_branch_sha "${work_branch_sha}" \
    --argjson mr_iid "${mr_iid}" \
    --arg mr_url \
      "https://gitlab.example.test/group/project/-/merge_requests/${mr_iid}" '{
      iid:$iid,
      execution_id:$execution_id,
      work_branch:$branch,
      commit_sha:$commit_sha,
      work_branch_sha:$work_branch_sha,
      verified:true,
      mr:{
        iid:$mr_iid,
        url:$mr_url,
        state:"opened",
        source_branch:$branch,
        target_branch:"main",
        sha:$work_branch_sha
      }
  }'
}

label_branch_snapshot() {
  local iid="$1" branch="$2" sha="$3"
  jq -nc \
    --argjson iid "${iid}" \
    --arg branch "${branch}" \
    --arg sha "${sha}" '{
      iid:$iid,
      identity_source:"gitlab_pr_label_branch",
      work_branch:$branch,
      commit_sha:$sha,
      work_branch_sha:$sha,
      verified:true
    }'
}

build_dependency_plan() {
  local consumer_iid="$1" declared_inputs="$2" effective_inputs="$3"
  local aggregate_base_sha="$4" canonical_json plan_sha256 work_branch
  canonical_json="$(jq -cnS \
    --argjson consumer_iid "${consumer_iid}" \
    --argjson declared_inputs "${declared_inputs}" \
    --argjson effective_inputs "${effective_inputs}" \
    --arg aggregate_base_sha "${aggregate_base_sha}" '{
      version:2,
      algorithm:"ordered-frontier-merge-v1",
      consumer_iid:$consumer_iid,
      target_branch:"main",
      declared_inputs:$declared_inputs,
      effective_inputs:$effective_inputs,
      aggregate_base_sha:$aggregate_base_sha
    }')"
  plan_sha256="$(sha256_text "${canonical_json}")"
  work_branch="issue/${consumer_iid}-dag-${plan_sha256:0:16}"
  jq -cnS \
    --argjson consumer_iid "${consumer_iid}" \
    --argjson declared_inputs "${declared_inputs}" \
    --argjson effective_inputs "${effective_inputs}" \
    --arg aggregate_base_sha "${aggregate_base_sha}" \
    --arg plan_sha256 "${plan_sha256}" \
    --arg work_branch "${work_branch}" '{
      version:2,
      consumer_iid:$consumer_iid,
      target_branch:"main",
      declared_inputs:$declared_inputs,
      effective_inputs:$effective_inputs,
      aggregate_base_sha:$aggregate_base_sha,
      plan_sha256:$plan_sha256,
      work_branch:$work_branch
    }'
}

run_resolver() {
  local consumer_iid="$1" snapshots_json="$2"
  REPO_PATH="${REPO_PATH}" \
    ISSUES_ROOT="${ISSUES_ROOT}" \
    DAG_CONSUMER_IID="${consumer_iid}" \
    DAG_TARGET_BRANCH=main \
    DAG_SOURCE_SNAPSHOTS_JSON="${snapshots_json}" \
    bash "${RESOLVER}"
}

assert_derived_work_branch() {
  local output="$1" expected_iid="$2"
  local plan_sha256 work_branch
  plan_sha256="$(printf '%s' "${output}" | jq -r '.plan_sha256')"
  work_branch="$(printf '%s' "${output}" | jq -r '.work_branch')"
  [[ "${plan_sha256}" =~ ^[0-9a-f]{64}$ ]] \
    || fail "resolver did not return a lowercase SHA-256 plan identity"
  [ "${work_branch}" = \
      "issue/${expected_iid}-dag-${plan_sha256:0:16}" ] \
    || fail "work branch was not derived from consumer IID and plan identity"
}

[ -x "${RESOLVER}" ] || fail "resolver is not executable: ${RESOLVER}"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-dag-base.XXXXXX")"
REPO_PATH="${TEST_ROOT}/repo"
REMOTE_REPO="${TEST_ROOT}/origin.git"
ISSUES_ROOT="${TEST_ROOT}/issues"
mkdir -p "${REPO_PATH}" "${ISSUES_ROOT}"

git init --bare -q "${REMOTE_REPO}"
git -C "${REPO_PATH}" init -q
git -C "${REPO_PATH}" config user.name req-executor-test
git -C "${REPO_PATH}" config user.email req-executor-test@example.invalid
git -C "${REPO_PATH}" checkout -qb main
printf '%s\n' 'base' >"${REPO_PATH}/common.txt"
git -C "${REPO_PATH}" add common.txt
git -C "${REPO_PATH}" commit -qm base
git -C "${REPO_PATH}" remote add origin "${REMOTE_REPO}"
git -C "${REPO_PATH}" push -q -u origin main
MAIN_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"

A_BRANCH='issue/11'
A_SHA="$(create_source_commit \
  "${A_BRANCH}" "${MAIN_SHA}" a.txt 'source A')"
write_source_state 11 101 "${A_BRANCH}" "${A_SHA}" 111
A_SNAPSHOT="$(source_snapshot 11 101 "${A_BRANCH}" "${A_SHA}" 111)"

# A live-pr ordinary branch is independently sufficient: no private/batch
# state is needed to resolve and freeze its exact current SHA.
A_STATE_PATH="${ISSUES_ROOT}/issue-11/state.json"
A_STATE_BACKUP="${ISSUES_ROOT}/issue-11/state.before-label-branch.json"
mv "${A_STATE_PATH}" "${A_STATE_BACKUP}"
A_LABEL_BRANCH_SNAPSHOT="$(label_branch_snapshot 11 "${A_BRANCH}" "${A_SHA}")"
A_LABEL_BRANCH_OUTPUT="$(
  run_resolver 90 "[$A_LABEL_BRANCH_SNAPSHOT]" \
    2>"${TEST_ROOT}/label-branch.stderr"
)"
printf '%s' "${A_LABEL_BRANCH_OUTPUT}" | jq -e --arg sha "${A_SHA}" '
  .status == "ready"
  and .consumer_iid == 90
  and .declared_inputs[0].identity_source ==
    "gitlab_pr_label_branch"
  and .aggregate_base_sha == $sha
  and .closure_iids == [11]
' >/dev/null || fail "label/branch-only predecessor was not resolved"
[ ! -e "${A_STATE_PATH}" ] \
  || fail "label/branch-only resolution fabricated private state"
mv "${A_STATE_BACKUP}" "${A_STATE_PATH}"

# B is itself a completed DAG-v2 consumer. Its immutable plan-derived source
# branch proves that multi-level DAGs are accepted without reopening B's MR.
B_INPUTS="$(jq -cn --argjson a "${A_SNAPSHOT}" '[$a]')"
B_PLAN_JSON="$(build_dependency_plan \
  12 "${B_INPUTS}" "${B_INPUTS}" "${A_SHA}")"
B_PLAN_SHA256="$(printf '%s' "${B_PLAN_JSON}" | jq -r '.plan_sha256')"
B_BRANCH="$(printf '%s' "${B_PLAN_JSON}" | jq -r '.work_branch')"
B_SHA="$(create_source_commit \
  "${B_BRANCH}" "${A_SHA}" b.txt 'source B contains A')"

# A merged MR may advance its source branch exactly once after the business
# commit, but only to persist the terminal log directory for that execution.
git -C "${REPO_PATH}" checkout -qB "${B_BRANCH}" "${B_SHA}"
mkdir -p \
  "${REPO_PATH}/.req_executor/issue-12/log/execution-102"
printf '%s\n' '{"status":"done"}' \
  >"${REPO_PATH}/.req_executor/issue-12/log/execution-102/worker_result.json"
git -C "${REPO_PATH}" add -f \
  ".req_executor/issue-12/log/execution-102/worker_result.json"
git -C "${REPO_PATH}" commit -qm "${B_BRANCH} terminal log"
B_LOG_SHA="$(git -C "${REPO_PATH}" rev-parse HEAD)"
git -C "${REPO_PATH}" push -q origin "HEAD:refs/heads/${B_BRANCH}"

write_source_state \
  12 102 "${B_BRANCH}" "${B_SHA}" 112 \
  "${B_PLAN_SHA256}" "${B_PLAN_JSON}" "${B_LOG_SHA}"
B_SNAPSHOT="$(source_snapshot \
  12 102 "${B_BRANCH}" "${B_SHA}" 112 "${B_LOG_SHA}" \
  | jq -c --arg business_sha "${B_SHA}" \
    '.mr.state="merged" | .mr.sha=$business_sha')"

# Preserve a three-level frozen closure A -> B -> C. B's branch is already at
# its terminal log child, so resolving C also exercises the recursive form of
# the merged-business-SHA exception rather than only the direct-input form.
CHAIN_C_INPUTS="$(jq -cn --argjson b "${B_SNAPSHOT}" '[$b]')"
CHAIN_C_PLAN_JSON="$(build_dependency_plan \
  18 "${CHAIN_C_INPUTS}" "${CHAIN_C_INPUTS}" "${B_SHA}")"
CHAIN_C_PLAN_SHA256="$(
  printf '%s' "${CHAIN_C_PLAN_JSON}" | jq -r '.plan_sha256'
)"
CHAIN_C_BRANCH="$(printf '%s' "${CHAIN_C_PLAN_JSON}" | jq -r '.work_branch')"
CHAIN_C_SHA="$(create_source_commit \
  "${CHAIN_C_BRANCH}" "${B_SHA}" chain-c.txt 'source C contains B and A')"
write_source_state \
  18 108 "${CHAIN_C_BRANCH}" "${CHAIN_C_SHA}" 118 \
  "${CHAIN_C_PLAN_SHA256}" "${CHAIN_C_PLAN_JSON}"
CHAIN_C_SNAPSHOT="$(
  source_snapshot 18 108 "${CHAIN_C_BRANCH}" "${CHAIN_C_SHA}" 118
)"

C_BRANCH='issue/13'
C_SHA="$(create_source_commit \
  "${C_BRANCH}" "${MAIN_SHA}" c.txt 'source C')"

CONFLICT_LEFT_BRANCH='issue/14'
CONFLICT_LEFT_SHA="$(create_source_commit \
  "${CONFLICT_LEFT_BRANCH}" "${MAIN_SHA}" common.txt 'left')"
CONFLICT_RIGHT_BRANCH='issue/15'
CONFLICT_RIGHT_SHA="$(create_source_commit \
  "${CONFLICT_RIGHT_BRANCH}" "${MAIN_SHA}" common.txt 'right')"

# A merged source branch must not advance to an arbitrary business child.
NON_LOG_BRANCH='issue/16'
NON_LOG_BUSINESS_SHA="$(create_source_commit \
  "${NON_LOG_BRANCH}" "${MAIN_SHA}" non-log-business.txt 'business')"
NON_LOG_TIP_SHA="$(create_source_commit \
  "${NON_LOG_BRANCH}" "${NON_LOG_BUSINESS_SHA}" unrelated.txt 'not a log')"

# Even when its tree delta is entirely under the exact terminal-log prefix, a
# merge commit is not the one direct child permitted after the business SHA.
MULTI_PARENT_BRANCH='issue/17'
MULTI_PARENT_BUSINESS_SHA="$(create_source_commit \
  "${MULTI_PARENT_BRANCH}" "${MAIN_SHA}" multi-parent-business.txt 'business')"
git -C "${REPO_PATH}" checkout -qB \
  "${MULTI_PARENT_BRANCH}" "${MULTI_PARENT_BUSINESS_SHA}"
mkdir -p \
  "${REPO_PATH}/.req_executor/issue-17/log/execution-107"
printf '%s\n' '{"status":"done"}' \
  >"${REPO_PATH}/.req_executor/issue-17/log/execution-107/worker_result.json"
git -C "${REPO_PATH}" add -f \
  ".req_executor/issue-17/log/execution-107/worker_result.json"
MULTI_PARENT_TREE="$(git -C "${REPO_PATH}" write-tree)"
MULTI_PARENT_TIP_SHA="$(
  printf '%s\n' 'malicious multi-parent terminal log' \
    | git -C "${REPO_PATH}" commit-tree "${MULTI_PARENT_TREE}" \
        -p "${MULTI_PARENT_BUSINESS_SHA}" -p "${MAIN_SHA}"
)"
git -C "${REPO_PATH}" push -q origin \
  "${MULTI_PARENT_TIP_SHA}:refs/heads/${MULTI_PARENT_BRANCH}"

# These branches carry an attribute that names a repository-configured merge
# driver. A trusted aggregate must ignore both the untrusted repository config
# and its driver, even when the two frontier trees conflict on that path.
SECURITY_BASE_BRANCH='security/merge-driver-base'
SECURITY_ATTR_SHA="$(create_source_commit \
  "${SECURITY_BASE_BRANCH}" "${MAIN_SHA}" .gitattributes \
  'driver.txt merge=sentinel')"
SECURITY_BASE_SHA="$(create_source_commit \
  "${SECURITY_BASE_BRANCH}" "${SECURITY_ATTR_SHA}" driver.txt 'base')"
SECURITY_LEFT_BRANCH='issue/40'
SECURITY_LEFT_SHA="$(create_source_commit \
  "${SECURITY_LEFT_BRANCH}" "${SECURITY_BASE_SHA}" driver.txt 'left')"
SECURITY_RIGHT_BRANCH='issue/41'
SECURITY_RIGHT_SHA="$(create_source_commit \
  "${SECURITY_RIGHT_BRANCH}" "${SECURITY_BASE_SHA}" driver.txt 'right')"

write_source_state 13 103 "${C_BRANCH}" "${C_SHA}" 113
write_source_state 14 104 "${CONFLICT_LEFT_BRANCH}" "${CONFLICT_LEFT_SHA}" 114
write_source_state 15 105 "${CONFLICT_RIGHT_BRANCH}" "${CONFLICT_RIGHT_SHA}" 115
write_source_state \
  16 106 "${NON_LOG_BRANCH}" "${NON_LOG_BUSINESS_SHA}" 116 \
  "" null "${NON_LOG_TIP_SHA}"
write_source_state \
  17 107 "${MULTI_PARENT_BRANCH}" "${MULTI_PARENT_BUSINESS_SHA}" 117 \
  "" null "${MULTI_PARENT_TIP_SHA}"
write_source_state \
  40 140 "${SECURITY_LEFT_BRANCH}" "${SECURITY_LEFT_SHA}" 140
write_source_state \
  41 141 "${SECURITY_RIGHT_BRANCH}" "${SECURITY_RIGHT_SHA}" 141

C_SNAPSHOT="$(source_snapshot 13 103 "${C_BRANCH}" "${C_SHA}" 113)"
CONFLICT_LEFT_SNAPSHOT="$(
  source_snapshot 14 104 "${CONFLICT_LEFT_BRANCH}" "${CONFLICT_LEFT_SHA}" 114
)"
CONFLICT_RIGHT_SNAPSHOT="$(
  source_snapshot 15 105 "${CONFLICT_RIGHT_BRANCH}" "${CONFLICT_RIGHT_SHA}" 115
)"
NON_LOG_SNAPSHOT="$(
  source_snapshot \
    16 106 "${NON_LOG_BRANCH}" "${NON_LOG_BUSINESS_SHA}" 116 \
      "${NON_LOG_TIP_SHA}" \
    | jq -c '.mr.state="merged"'
)"
MULTI_PARENT_SNAPSHOT="$(
  source_snapshot \
    17 107 "${MULTI_PARENT_BRANCH}" "${MULTI_PARENT_BUSINESS_SHA}" 117 \
      "${MULTI_PARENT_TIP_SHA}" \
    | jq -c '.mr.state="merged"'
)"
SECURITY_LEFT_SNAPSHOT="$(
  source_snapshot \
    40 140 "${SECURITY_LEFT_BRANCH}" "${SECURITY_LEFT_SHA}" 140
)"
SECURITY_RIGHT_SNAPSHOT="$(
  source_snapshot \
    41 141 "${SECURITY_RIGHT_BRANCH}" "${SECURITY_RIGHT_SHA}" 141
)"
SECURITY_SNAPSHOTS="$(jq -cn \
  --argjson left "${SECURITY_LEFT_SNAPSHOT}" \
  --argjson right "${SECURITY_RIGHT_SNAPSHOT}" '[$left,$right]')"

# A corrupt frozen source plan that recursively names its own IID must be
# classified as invalid source history, not confused with a repeated ancestor.
SELF_DECLARED_SNAPSHOT="$(
  source_snapshot 60 160 'issue/60' "${A_SHA}" 160
)"
SELF_INPUTS="$(jq -cn \
  --argjson source "${SELF_DECLARED_SNAPSHOT}" '[$source]')"
SELF_PLAN_JSON="$(build_dependency_plan \
  60 "${SELF_INPUTS}" "${SELF_INPUTS}" "${A_SHA}")"
SELF_PLAN_SHA256="$(printf '%s' "${SELF_PLAN_JSON}" | jq -r '.plan_sha256')"
SELF_BRANCH="$(printf '%s' "${SELF_PLAN_JSON}" | jq -r '.work_branch')"
SELF_SHA="$(create_source_commit \
  "${SELF_BRANCH}" "${A_SHA}" self.txt 'recursive source plan')"
write_source_state \
  60 160 "${SELF_BRANCH}" "${SELF_SHA}" 160 \
  "${SELF_PLAN_SHA256}" "${SELF_PLAN_JSON}"
SELF_SNAPSHOT="$(source_snapshot 60 160 "${SELF_BRANCH}" "${SELF_SHA}" 160)"

# Eight unique dependency IIDs are valid. These aliases intentionally point at
# A's exact commit so the maximum-cardinality case also exercises stable
# duplicate-commit reduction without manufacturing unnecessary commit history.
MAX_SNAPSHOTS="$(jq -cn --argjson a "${A_SNAPSHOT}" '[$a]')"
OVER_MAX_SNAPSHOTS="${MAX_SNAPSHOTS}"
for alias_iid in 101 102 103 104 105 106 107 108; do
  alias_branch="issue/${alias_iid}"
  alias_execution_id="$((200 + alias_iid))"
  alias_mr_iid="$((300 + alias_iid))"
  git -C "${REPO_PATH}" push -q origin \
    "${A_SHA}:refs/heads/${alias_branch}"
  write_source_state \
    "${alias_iid}" "${alias_execution_id}" "${alias_branch}" \
    "${A_SHA}" "${alias_mr_iid}"
  alias_snapshot="$(
    source_snapshot \
      "${alias_iid}" "${alias_execution_id}" "${alias_branch}" \
      "${A_SHA}" "${alias_mr_iid}"
  )"
  OVER_MAX_SNAPSHOTS="$(jq -cn \
    --argjson current "${OVER_MAX_SNAPSHOTS}" \
    --argjson item "${alias_snapshot}" '$current + [$item]')"
  if [ "${alias_iid}" -ne 108 ]; then
    MAX_SNAPSHOTS="$(jq -cn \
      --argjson current "${MAX_SNAPSHOTS}" \
      --argjson item "${alias_snapshot}" '$current + [$item]')"
  fi
done

AB_SNAPSHOTS="$(jq -cn \
  --argjson a "${A_SNAPSHOT}" --argjson b "${B_SNAPSHOT}" '[$a,$b]')"
BC_SNAPSHOTS="$(jq -cn \
  --argjson b "${B_SNAPSHOT}" --argjson c "${C_SNAPSHOT}" '[$b,$c]')"
A_MERGED_SNAPSHOT="$(printf '%s' "${A_SNAPSHOT}" \
  | jq -c '.mr.state="merged"')"
ABC_SNAPSHOTS="$(jq -cn \
  --argjson a "${A_MERGED_SNAPSHOT}" --argjson b "${B_SNAPSHOT}" \
  --argjson c "${C_SNAPSHOT}" '[$a,$b,$c]')"
CB_SNAPSHOTS="$(jq -cn \
  --argjson b "${B_SNAPSHOT}" --argjson c "${C_SNAPSHOT}" '[$c,$b]')"
CONFLICT_SNAPSHOTS="$(jq -cn \
  --argjson left "${CONFLICT_LEFT_SNAPSHOT}" \
  --argjson right "${CONFLICT_RIGHT_SNAPSHOT}" '[$left,$right]')"

git -C "${REPO_PATH}" fetch -q origin \
  '+refs/heads/*:refs/remotes/origin/*'
REFS_BEFORE="$(git -C "${REPO_PATH}" show-ref | LC_ALL=C sort)"
STATE_HASHES_BEFORE="$(state_hashes)"

# Install the attacker-controlled repository config before the first
# multi-frontier aggregate also creates its isolated merge Git directory.
MERGE_SENTINEL_SECRET='dag-merge-secret-must-not-escape'
MALICIOUS_SIDE_EFFECT="${TEST_ROOT}/malicious-merge-driver-ran"
git -C "${REPO_PATH}" config merge.sentinel.name \
  'untrusted sentinel merge driver'
git -C "${REPO_PATH}" config merge.sentinel.driver \
  "sh -c 'printf %s \"\${DAG_MERGE_SENTINEL_SECRET-}\" >\"${MALICIOUS_SIDE_EFFECT}\"'"
TRUSTED_MERGE_GIT_DIR="${ISSUES_ROOT}/../_dispatcher/dag-merge.git"
mkdir -p "${ISSUES_ROOT}/../_dispatcher"
git init --bare -q "${TRUSTED_MERGE_GIT_DIR}"
chmod 755 "${TRUSTED_MERGE_GIT_DIR}"
chmod 644 "${TRUSTED_MERGE_GIT_DIR}/config"

# A one-element frontier uses the exact source SHA, not a synthetic commit.
SINGLE_OUTPUT="$(run_resolver 20 "[$A_SNAPSHOT]")" \
  || fail "single-frontier resolution failed"
printf '%s' "${SINGLE_OUTPUT}" | jq -e \
  --arg sha "${A_SHA}" '
  .version == 2 and .status == "ready" and .consumer_iid == 20
  and .target_branch == "main"
  and (.declared_inputs | map(.iid)) == [11]
  and (.effective_inputs | map(.iid)) == [11]
  and .aggregate_base_sha == $sha
' >/dev/null || fail "single-frontier result is incorrect"
assert_derived_work_branch "${SINGLE_OUTPUT}" 20

# A merged MR is pinned to B's business SHA even though the exact remote branch
# and private work_branch_sha have advanced to one direct terminal log child L.
MERGED_LOG_OUTPUT="$(run_resolver 26 "[$B_SNAPSHOT]")" \
  || fail "merged source with one terminal log child was rejected"
printf '%s' "${MERGED_LOG_OUTPUT}" | jq -e \
  --arg business_sha "${B_SHA}" \
  --arg log_sha "${B_LOG_SHA}" '
  (.declared_inputs | map(.iid)) == [12]
  and (.effective_inputs | map(.iid)) == [12]
  and .closure_iids == [11,12]
  and .aggregate_base_sha == $business_sha
  and .aggregate_base_sha != $log_sha
' >/dev/null \
  || fail "terminal log child replaced the merged business aggregate"
assert_derived_work_branch "${MERGED_LOG_OUTPUT}" 26

# The same merged B/L identity remains valid when reached recursively through
# the frozen three-level A -> B -> C closure.
CHAIN_OUTPUT="$(run_resolver 27 "[$CHAIN_C_SNAPSHOT]")" \
  || fail "three-level closure containing merged B/L source was rejected"
printf '%s' "${CHAIN_OUTPUT}" | jq -e \
  --arg sha "${CHAIN_C_SHA}" '
  (.declared_inputs | map(.iid)) == [18]
  and (.effective_inputs | map(.iid)) == [18]
  and .closure_iids == [11,12,18]
  and .aggregate_base_sha == $sha
' >/dev/null || fail "three-level frozen closure is incorrect"
assert_derived_work_branch "${CHAIN_OUTPUT}" 27

# The full supported width is eight ordered, unique IIDs. Equal source commit
# identities are reduced deterministically to their first declaration.
MAX_OUTPUT="$(run_resolver 400 "${MAX_SNAPSHOTS}")" \
  || fail "eight-input dependency resolution failed"
printf '%s' "${MAX_OUTPUT}" | jq -e \
  --arg sha "${A_SHA}" '
  (.declared_inputs | length) == 8
  and (.declared_inputs | map(.iid)) == [11,101,102,103,104,105,106,107]
  and (.effective_inputs | map(.iid)) == [11]
  and .aggregate_base_sha == $sha
' >/dev/null || fail "eight-input dependency contract is incorrect"
assert_derived_work_branch "${MAX_OUTPUT}" 400

# A is an ancestor of B, so the ordered declared vector remains [A,B] while
# the effective frontier is reduced to B and uses B's exact SHA.
REDUCED_OUTPUT="$(run_resolver 21 "${AB_SNAPSHOTS}")" \
  || fail "transitive reduction failed"
printf '%s' "${REDUCED_OUTPUT}" | jq -e \
  --arg sha "${B_SHA}" '
  (.declared_inputs | map(.iid)) == [11,12]
  and (.effective_inputs | map(.iid)) == [12]
  and .aggregate_base_sha == $sha
' >/dev/null || fail "transitive reduction did not eliminate ancestor A"
assert_derived_work_branch "${REDUCED_OUTPUT}" 21

# Independent B and C frontiers produce an unreachable deterministic merge
# commit. Repeating the same plan returns byte-identical output.
MERGE_OUTPUT_ONE="$(run_resolver 22 "${BC_SNAPSHOTS}")" \
  || fail "multi-frontier resolution failed"
MERGE_OUTPUT_TWO="$(run_resolver 22 "${BC_SNAPSHOTS}")" \
  || fail "repeated multi-frontier resolution failed"
[ "${MERGE_OUTPUT_ONE}" = "${MERGE_OUTPUT_TWO}" ] \
  || fail "the same dependency plan did not resolve deterministically"
MERGE_SHA="$(printf '%s' "${MERGE_OUTPUT_ONE}" | jq -r '.aggregate_base_sha')"
printf '%s' "${MERGE_OUTPUT_ONE}" | jq -e '
  (.declared_inputs | map(.iid)) == [12,13]
  and (.effective_inputs | map(.iid)) == [12,13]
' >/dev/null || fail "multi-frontier ordering was not preserved"
git -C "${REPO_PATH}" merge-base --is-ancestor "${B_SHA}" "${MERGE_SHA}" \
  || fail "aggregate base does not contain B"
git -C "${REPO_PATH}" merge-base --is-ancestor "${C_SHA}" "${MERGE_SHA}" \
  || fail "aggregate base does not contain C"
PARENTS="$(git -C "${REPO_PATH}" cat-file -p "${MERGE_SHA}" \
  | awk '$1 == "parent" {print $2}')"
[ "${PARENTS}" = "${B_SHA}
${C_SHA}" ] || fail "aggregate commit parent ordering is not [B,C]"
assert_derived_work_branch "${MERGE_OUTPUT_ONE}" 22
[ "$(file_mode "${TRUSTED_MERGE_GIT_DIR}")" = 700 ] \
  || fail "trusted merge directory was not normalized from 0755"
[ "$(file_mode "${TRUSTED_MERGE_GIT_DIR}/config")" = 600 ] \
  || fail "trusted merge config was not normalized from 0644"

# Exact core.attributesFile is forbidden in the persistent trusted Git dir;
# the audit must not rely on a regex that only catches dotted subkeys.
git --git-dir="${TRUSTED_MERGE_GIT_DIR}" config \
  core.attributesFile "${REPO_PATH}/.gitattributes"
set +e
ATTR_CONFIG_OUTPUT="$(run_resolver 23 "${BC_SNAPSHOTS}" \
  2>"${TEST_ROOT}/trusted-attributes.stderr")"
ATTR_CONFIG_RC=$?
set -e
[ "${ATTR_CONFIG_RC}" -eq 5 ] \
  || fail "trusted core.attributesFile returned ${ATTR_CONFIG_RC}, expected 5"
printf '%s' "${ATTR_CONFIG_OUTPUT}" | jq -e '
  .status == "failed" and .reason == "dependency_merge_environment_unsafe"
' >/dev/null || fail "trusted core.attributesFile was not rejected"
git --git-dir="${TRUSTED_MERGE_GIT_DIR}" config --unset core.attributesFile

# Redundant declared ancestry changes provenance/plan identity, but after
# reduction the same effective ordered frontier produces the same base commit.
REDUNDANT_OUTPUT="$(run_resolver 22 "${ABC_SNAPSHOTS}")" \
  || fail "three-input transitive reduction failed"
printf '%s' "${REDUNDANT_OUTPUT}" | jq -e \
  --arg aggregate_sha "${MERGE_SHA}" '
  (.declared_inputs | map(.iid)) == [11,12,13]
  and (.effective_inputs | map(.iid)) == [12,13]
  and .aggregate_base_sha == $aggregate_sha
' >/dev/null || fail "redundant A changed the effective aggregate baseline"
[ "$(printf '%s' "${REDUNDANT_OUTPUT}" | jq -r '.plan_sha256')" != \
    "$(printf '%s' "${MERGE_OUTPUT_ONE}" | jq -r '.plan_sha256')" ] \
  || fail "declared provenance was omitted from the final plan identity"

# Input order is semantic and therefore changes the deterministic parent order.
REVERSED_OUTPUT="$(run_resolver 22 "${CB_SNAPSHOTS}")" \
  || fail "reversed multi-frontier resolution failed"
REVERSED_SHA="$(printf '%s' "${REVERSED_OUTPUT}" | jq -r '.aggregate_base_sha')"
[ "${REVERSED_SHA}" != "${MERGE_SHA}" ] \
  || fail "reversing the ordered frontier did not change its aggregate commit"
printf '%s' "${REVERSED_OUTPUT}" | jq -e '
  (.effective_inputs | map(.iid)) == [13,12]
' >/dev/null || fail "reversed effective input order was not retained"

# Two downstream consumers can reuse A without sharing or moving A's branch.
FANOUT_ONE="$(run_resolver 30 "[$A_SNAPSHOT]")" \
  || fail "first fan-out consumer failed"
FANOUT_TWO="$(run_resolver 31 "[$A_SNAPSHOT]")" \
  || fail "second fan-out consumer failed"
[ "$(printf '%s' "${FANOUT_ONE}" | jq -r '.aggregate_base_sha')" = "${A_SHA}" ] \
  || fail "first fan-out consumer did not pin A"
[ "$(printf '%s' "${FANOUT_TWO}" | jq -r '.aggregate_base_sha')" = "${A_SHA}" ] \
  || fail "second fan-out consumer did not pin A"
[ "$(printf '%s' "${FANOUT_ONE}" | jq -r '.work_branch')" != \
    "$(printf '%s' "${FANOUT_TWO}" | jq -r '.work_branch')" ] \
  || fail "fan-out consumers were assigned the same work branch"

# B's frozen plan names A. Planning a new A from B therefore closes an indirect
# issue dependency cycle and fails with a stable, machine-readable reason.
set +e
CYCLE_OUTPUT_ONE="$(
  run_resolver 11 "[$B_SNAPSHOT]" 2>"${TEST_ROOT}/cycle-one.stderr"
)"
CYCLE_RC_ONE=$?
CYCLE_OUTPUT_TWO="$(
  run_resolver 11 "[$B_SNAPSHOT]" 2>"${TEST_ROOT}/cycle-two.stderr"
)"
CYCLE_RC_TWO=$?
set -e
[ "${CYCLE_RC_ONE}" -eq 5 ] && [ "${CYCLE_RC_TWO}" -eq 5 ] \
  || fail "indirect dependency cycle did not return exit code 5"
[ "${CYCLE_OUTPUT_ONE}" = "${CYCLE_OUTPUT_TWO}" ] \
  || fail "indirect dependency cycle was not a stable failure"
printf '%s' "${CYCLE_OUTPUT_ONE}" | jq -e '
  .status == "failed" and .reason == "dependency_cycle"
  and .consumer_iid == 11 and .source_iid == 12
' >/dev/null || fail "indirect dependency cycle envelope is incorrect"

set +e
DIRECT_CYCLE_OUTPUT="$(
  run_resolver 11 "[$A_SNAPSHOT]" 2>"${TEST_ROOT}/direct-cycle.stderr"
)"
DIRECT_CYCLE_RC=$?
set -e
[ "${DIRECT_CYCLE_RC}" -eq 5 ] \
  || fail "direct self-dependency did not return exit code 5"
printf '%s' "${DIRECT_CYCLE_OUTPUT}" | jq -e '
  .status == "failed" and .reason == "dependency_cycle"
  and .consumer_iid == 11 and .source_iid == 11
' >/dev/null || fail "direct dependency-cycle envelope is incorrect"

# A recursion-stack repeat inside a frozen predecessor plan is corruption of
# that source plan. It is distinct from a diamond ancestor already fully
# visited through another path (covered by the successful [A,B,C] case).
set +e
SOURCE_PLAN_INVALID_OUTPUT="$(
  run_resolver 70 "[$SELF_SNAPSHOT]" \
    2>"${TEST_ROOT}/source-plan-invalid.stderr"
)"
SOURCE_PLAN_INVALID_RC=$?
set -e
[ "${SOURCE_PLAN_INVALID_RC}" -eq 5 ] \
  || fail "recursive frozen source plan did not return exit code 5"
printf '%s' "${SOURCE_PLAN_INVALID_OUTPUT}" | jq -e '
  .status == "failed"
  and .reason == "dependency_source_plan_invalid"
  and .consumer_iid == 70 and .source_iid == 60
' >/dev/null || fail "recursive frozen source-plan envelope is incorrect"

# A merged MR exception is deliberately narrow: an arbitrary direct child and
# a log-only merge child must both fail before either can affect an aggregate.
set +e
NON_LOG_OUTPUT="$(
  run_resolver 28 "[$NON_LOG_SNAPSHOT]" \
    2>"${TEST_ROOT}/non-log-descendant.stderr"
)"
NON_LOG_RC=$?
MULTI_PARENT_OUTPUT="$(
  run_resolver 29 "[$MULTI_PARENT_SNAPSHOT]" \
    2>"${TEST_ROOT}/multi-parent-descendant.stderr"
)"
MULTI_PARENT_RC=$?
set -e
[ "${NON_LOG_RC}" -eq 5 ] && [ "${MULTI_PARENT_RC}" -eq 5 ] \
  || fail "unsafe merged-MR descendant did not return exit code 5"
printf '%s' "${NON_LOG_OUTPUT}" | jq -e '
  .status == "failed"
  and .reason == "dependency_source_state_identity_mismatch"
  and .consumer_iid == 28 and .source_iid == 16
' >/dev/null || fail "non-log descendant failure envelope is incorrect"
printf '%s' "${MULTI_PARENT_OUTPUT}" | jq -e '
  .status == "failed"
  and .reason == "dependency_source_state_identity_mismatch"
  and .consumer_iid == 29 and .source_iid == 17
' >/dev/null || fail "multi-parent descendant failure envelope is incorrect"

# The full hash is checked rather than trusted from state. Mutating one nested
# exact MR identity while retaining the old hash is deterministic corruption.
B_STATE_FILE="${ISSUES_ROOT}/issue-12/state.json"
B_STATE_ORIGINAL="$(<"${B_STATE_FILE}")"
B_STATE_TAMPERED="$(mktemp "${TEST_ROOT}/state-12-tampered.XXXXXX")"
printf '%s' "${B_STATE_ORIGINAL}" | jq \
  '.dependency_plan.declared_inputs[0].mr.url
    = "https://gitlab.example.test/group/project/-/merge_requests/999"' \
  >"${B_STATE_TAMPERED}"
chmod 600 "${B_STATE_TAMPERED}"
mv "${B_STATE_TAMPERED}" "${B_STATE_FILE}"
set +e
HASH_MISMATCH_OUTPUT="$(
  run_resolver 71 "[$B_SNAPSHOT]" \
    2>"${TEST_ROOT}/source-plan-hash-mismatch.stderr"
)"
HASH_MISMATCH_RC=$?
set -e
printf '%s\n' "${B_STATE_ORIGINAL}" >"${B_STATE_FILE}"
chmod 600 "${B_STATE_FILE}"
[ "${HASH_MISMATCH_RC}" -eq 5 ] \
  || fail "tampered frozen plan did not return exit code 5"
printf '%s' "${HASH_MISMATCH_OUTPUT}" | jq -e '
  .status == "failed"
  and .reason == "dependency_source_plan_invalid"
  and .consumer_iid == 71 and .source_iid == 12
' >/dev/null || fail "tampered frozen-plan envelope is incorrect"

# A textual merge conflict is a stable failure and cannot create a consumer
# ref, move a source ref, or alter any private source state.
set +e
CONFLICT_OUTPUT_ONE="$(
  run_resolver 23 "${CONFLICT_SNAPSHOTS}" 2>"${TEST_ROOT}/conflict-one.stderr"
)"
CONFLICT_RC_ONE=$?
CONFLICT_OUTPUT_TWO="$(
  run_resolver 23 "${CONFLICT_SNAPSHOTS}" 2>"${TEST_ROOT}/conflict-two.stderr"
)"
CONFLICT_RC_TWO=$?
set -e
[ "${CONFLICT_RC_ONE}" -eq 6 ] && [ "${CONFLICT_RC_TWO}" -eq 6 ] \
  || fail "dependency conflict did not return stable exit code 6"
[ "${CONFLICT_OUTPUT_ONE}" = "${CONFLICT_OUTPUT_TWO}" ] \
  || fail "dependency conflict did not return a stable failure envelope"
printf '%s' "${CONFLICT_OUTPUT_ONE}" | jq -e '
  .version == 2 and .status == "failed"
  and .reason == "dependency_merge_conflict"
  and .consumer_iid == 23 and .source_iid == 15
  and .work_branch == null and .plan_sha256 == null
  and (.declared_inputs | map(.iid)) == [14,15]
  and (.effective_inputs | map(.iid)) == [14,15]
' >/dev/null || fail "dependency conflict envelope is incorrect"

# The repository's config is attacker-controlled relative to this resolver.
# Its custom driver would both copy a secret and create a side effect if the
# aggregate inherited that config or environment.
set +e
SECURITY_OUTPUT="$(
  DAG_MERGE_SENTINEL_SECRET="${MERGE_SENTINEL_SECRET}" \
    run_resolver 42 "${SECURITY_SNAPSHOTS}" \
      2>"${TEST_ROOT}/security-merge.stderr"
)"
SECURITY_RC=$?
set -e
[ "${SECURITY_RC}" -eq 6 ] \
  || fail "trusted aggregate did not reject the untrusted-driver conflict"
printf '%s' "${SECURITY_OUTPUT}" | jq -e '
  .status == "failed"
  and .reason == "dependency_merge_conflict"
  and .consumer_iid == 42 and .source_iid == 41
  and (.declared_inputs | map(.iid)) == [40,41]
  and (.effective_inputs | map(.iid)) == [40,41]
' >/dev/null || fail "untrusted-driver conflict envelope is incorrect"
[ ! -e "${MALICIOUS_SIDE_EFFECT}" ] \
  || fail "repository merge driver executed during trusted aggregation"
SECURITY_STDERR="$(<"${TEST_ROOT}/security-merge.stderr")"
case "${SECURITY_OUTPUT}${SECURITY_STDERR}" in
  *"${MERGE_SENTINEL_SECRET}"*)
    fail "sentinel secret escaped the trusted aggregate environment"
    ;;
esac

# Unsafe private state and malformed cardinality are rejected before use.
chmod 644 "${ISSUES_ROOT}/issue-11/state.json"
set +e
UNSAFE_OUTPUT="$(
  run_resolver 24 "[$A_SNAPSHOT]" 2>"${TEST_ROOT}/unsafe-state.stderr"
)"
UNSAFE_RC=$?
set -e
chmod 600 "${ISSUES_ROOT}/issue-11/state.json"
[ "${UNSAFE_RC}" -eq 5 ] \
  || fail "unsafe private state did not return exit code 5"
printf '%s' "${UNSAFE_OUTPUT}" | jq -e '
  .status == "failed"
  and .reason == "dependency_source_state_unsafe"
  and .source_iid == 11
' >/dev/null || fail "unsafe-state failure envelope is incorrect"

set +e
run_resolver 25 '[]' >/dev/null 2>"${TEST_ROOT}/empty.stderr"
EMPTY_RC=$?
run_resolver 25 "$(jq -cn --argjson a "${A_SNAPSHOT}" '[$a,$a]')" \
  >/dev/null 2>"${TEST_ROOT}/duplicate.stderr"
DUPLICATE_RC=$?
run_resolver 25 "${OVER_MAX_SNAPSHOTS}" \
  >/dev/null 2>"${TEST_ROOT}/over-max.stderr"
OVER_MAX_RC=$?
set -e
[ "${EMPTY_RC}" -eq 2 ] && [ "${DUPLICATE_RC}" -eq 2 ] \
  && [ "${OVER_MAX_RC}" -eq 2 ] \
  || fail "invalid dependency cardinality or duplicate IID was accepted"

[ "$(git -C "${REPO_PATH}" show-ref | LC_ALL=C sort)" = "${REFS_BEFORE}" ] \
  || fail "resolver created, moved, or deleted a Git ref"
[ "$(state_hashes)" = "${STATE_HASHES_BEFORE}" ] \
  || fail "resolver changed private source state"

printf '%s\n' 'test_resolve_dependency_dag_base.sh: PASS'
