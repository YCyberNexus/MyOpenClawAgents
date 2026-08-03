#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "test_prepare_attempt_dependency_base.sh: $*" >&2
  exit 1
}

file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  else
    return 1
  fi
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-dependency-base.XXXXXX")"
FIXTURE_SKILL="${TEST_ROOT}/skill"
FIXTURE_SCRIPTS="${FIXTURE_SKILL}/scripts"
CONFIG_DIR="${TEST_ROOT}/config"
REPO_PARENT="${TEST_ROOT}/repos/group"
REPO_PATH="${REPO_PARENT}/project"
AUTHOR_REPO="${TEST_ROOT}/author"
ORIGIN_REPO="${TEST_ROOT}/origin.git"
HOOK_SENTINEL="${TEST_ROOT}/dependency-post-checkout-fired"
FILTER_SENTINEL="${TEST_ROOT}/dependency-filter-fired"
mkdir -p "${FIXTURE_SCRIPTS}" "${CONFIG_DIR}" "${REPO_PARENT}"

for name in prepare_attempt.sh env_paths.sh branch_utils.sh \
  gitlab_env_resolver.sh glab_auth.sh; do
  cp "${SKILL_DIR}/scripts/${name}" "${FIXTURE_SCRIPTS}/${name}"
done
cat >"${FIXTURE_SCRIPTS}/git_network_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git_network_guard_run() {
  local repo="$1"
  shift
  git -C "${repo}" "$@"
}
git_network_guard_enforce_local_test_host() {
  return 0
}
EOF
chmod +x "${FIXTURE_SCRIPTS}"/*.sh

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.test.invalid
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=dependency-test-token
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${REPO_PARENT}
EOF

git init -q --bare "${ORIGIN_REPO}"
git clone -q "${ORIGIN_REPO}" "${AUTHOR_REPO}"
git -C "${AUTHOR_REPO}" config user.email req-executor-test@example.invalid
git -C "${AUTHOR_REPO}" config user.name req-executor-test
mkdir -p "${AUTHOR_REPO}/.claude" "${AUTHOR_REPO}/docs"
printf 'main-code\n' >"${AUTHOR_REPO}/app.txt"
printf '{"hooks":{"trusted":true}}\n' >"${AUTHOR_REPO}/.claude/settings.json"
printf 'trusted project instructions\n' >"${AUTHOR_REPO}/CLAUDE.md"
printf 'trusted nested instructions\n' >"${AUTHOR_REPO}/docs/CLAUDE.md"
printf '{"mcpServers":{}}\n' >"${AUTHOR_REPO}/.mcp.json"
printf '{"agents":{}}\n' >"${AUTHOR_REPO}/.acpxrc.json"
git -C "${AUTHOR_REPO}" add app.txt .claude/settings.json CLAUDE.md \
  docs/CLAUDE.md .mcp.json .acpxrc.json
git -C "${AUTHOR_REPO}" commit -qm main
git -C "${AUTHOR_REPO}" branch -M main
git -C "${AUTHOR_REPO}" push -q -u origin main
git --git-dir="${ORIGIN_REPO}" symbolic-ref HEAD refs/heads/main

git -C "${AUTHOR_REPO}" switch -qc issue/9
printf 'dependency-code\n' >"${AUTHOR_REPO}/app.txt"
printf '{"hooks":{"evil":true}}\n' >"${AUTHOR_REPO}/.claude/settings.json"
printf 'untrusted dependency instructions\n' >"${AUTHOR_REPO}/CLAUDE.md"
printf 'untrusted nested instructions\n' >"${AUTHOR_REPO}/docs/CLAUDE.md"
printf '{"mcpServers":{"evil":{"command":"false"}}}\n' >"${AUTHOR_REPO}/.mcp.json"
printf '{"agents":{"claude":{"command":"./evil-acp"}}}\n' \
  >"${AUTHOR_REPO}/.acpxrc.json"
mkdir -p "${AUTHOR_REPO}/.githooks"
printf '#!/bin/sh\nprintf fired >"%s"\n' "${HOOK_SENTINEL}" \
  >"${AUTHOR_REPO}/.githooks/post-checkout"
chmod +x "${AUTHOR_REPO}/.githooks/post-checkout"
printf '#!/bin/sh\nprintf fired >"%s"\n' "${HOOK_SENTINEL}" \
  >"${AUTHOR_REPO}/.githooks/post-index-change"
chmod +x "${AUTHOR_REPO}/.githooks/post-index-change"
mkdir -p "${AUTHOR_REPO}/dependency-only/.claude"
printf 'dependency-only instructions\n' \
  >"${AUTHOR_REPO}/dependency-only/CLAUDE.local.md"
printf '#!/usr/bin/env bash\necho evil\n' \
  >"${AUTHOR_REPO}/dependency-only/.claude/hook.sh"
git -C "${AUTHOR_REPO}" add app.txt .claude/settings.json CLAUDE.md \
  docs/CLAUDE.md .mcp.json .acpxrc.json .githooks dependency-only
git -C "${AUTHOR_REPO}" commit -qm dependency
PINNED_SHA="$(git -C "${AUTHOR_REPO}" rev-parse HEAD)"
git -C "${AUTHOR_REPO}" push -q -u origin issue/9

# Move the remote dependency branch after the dispatcher would have pinned its
# verified commit. prepare_attempt must still checkout PINNED_SHA.
printf 'moved-after-preflight\n' >"${AUTHOR_REPO}/app.txt"
git -C "${AUTHOR_REPO}" add app.txt
git -C "${AUTHOR_REPO}" commit -qm moved
git -C "${AUTHOR_REPO}" push -q origin issue/9

# Malicious dependency shapes used to verify path boundaries. A committed
# runtime symlink must be rejected before any state mkdir/move, while a
# `.claude` symlink must be archived and replaced from the trusted config ref.
OUTSIDE_RUNTIME="${TEST_ROOT}/outside-runtime"
OUTSIDE_CLAUDE="${TEST_ROOT}/outside-claude"
mkdir -p "${OUTSIDE_RUNTIME}" "${OUTSIDE_CLAUDE}"
printf 'runtime-sentinel\n' >"${OUTSIDE_RUNTIME}/sentinel"
printf 'claude-sentinel\n' >"${OUTSIDE_CLAUDE}/sentinel"

git -C "${AUTHOR_REPO}" switch -qc issue/10 main
ln -s "${OUTSIDE_RUNTIME}" "${AUTHOR_REPO}/.req_executor"
git -C "${AUTHOR_REPO}" add .req_executor
git -C "${AUTHOR_REPO}" commit -qm malicious-runtime-symlink
MALICIOUS_RUNTIME_SHA="$(git -C "${AUTHOR_REPO}" rev-parse HEAD)"
git -C "${AUTHOR_REPO}" push -q -u origin issue/10

git -C "${AUTHOR_REPO}" switch -q main
git -C "${AUTHOR_REPO}" switch -qc issue/11
mv "${AUTHOR_REPO}/.claude" "${TEST_ROOT}/main-claude-backup"
ln -s "${OUTSIDE_CLAUDE}" "${AUTHOR_REPO}/.claude"
git -C "${AUTHOR_REPO}" add -A
git -C "${AUTHOR_REPO}" commit -qm malicious-claude-symlink
MALICIOUS_CLAUDE_SHA="$(git -C "${AUTHOR_REPO}" rev-parse HEAD)"
git -C "${AUTHOR_REPO}" push -q -u origin issue/11

git -C "${AUTHOR_REPO}" switch -q main
git -C "${AUTHOR_REPO}" switch -qc issue/12
printf '*.txt filter=dependency-evil\n' >"${AUTHOR_REPO}/.gitattributes"
git -C "${AUTHOR_REPO}" add .gitattributes
git -C "${AUTHOR_REPO}" commit -qm malicious-checkout-filter
MALICIOUS_FILTER_SHA="$(git -C "${AUTHOR_REPO}" rev-parse HEAD)"
git -C "${AUTHOR_REPO}" push -q -u origin issue/12

git clone -q "${ORIGIN_REPO}" "${REPO_PATH}"
git -C "${REPO_PATH}" config core.hooksPath .githooks
git -C "${REPO_PATH}" config filter.dependency-evil.smudge \
  "sh -c 'printf fired >\"${FILTER_SENTINEL}\"; cat'"
PREP_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=2 EXECUTION_ID=1 ISSUE_MODE=fresh \
  BRANCH=issue/9 CONFIG_BRANCH=main DEPENDENCY_BASE_SHA="${PINNED_SHA}" \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "prepare_attempt rejected a valid pinned dependency"

[ "$(sed -n '1p' <<<"${PREP_OUTPUT}")" = fresh ] \
  || fail "fresh dependency attempt returned the wrong mode"
[ "$(sed -n '2p' <<<"${PREP_OUTPUT}")" = issue/2 ] \
  || fail "dependency attempt returned the wrong local branch"

WORKTREE_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-2"
[ "$(git -C "${WORKTREE_DIR}" rev-parse HEAD)" = "${PINNED_SHA}" ] \
  || fail "worktree followed the moved branch instead of the pinned commit"
[ "$(cat "${WORKTREE_DIR}/app.txt")" = dependency-code ] \
  || fail "business code did not come from the dependency commit"
[ "$(cat "${WORKTREE_DIR}/.claude/settings.json")" = \
    '{"hooks":{"trusted":true}}' ] \
  || fail "Claude config came from the dependency branch instead of main"
[ "$(cat "${WORKTREE_DIR}/CLAUDE.md")" = 'trusted project instructions' ] \
  || fail "root Claude instructions came from the dependency branch"
[ "$(cat "${WORKTREE_DIR}/docs/CLAUDE.md")" = 'trusted nested instructions' ] \
  || fail "nested Claude instructions came from the dependency branch"
[ "$(cat "${WORKTREE_DIR}/.mcp.json")" = '{"mcpServers":{}}' ] \
  || fail "project MCP config came from the dependency branch"
[ "$(cat "${WORKTREE_DIR}/.acpxrc.json")" = '{"agents":{}}' ] \
  || fail "ACPx project agent override came from the dependency branch"
[ "$(cat "${WORKTREE_DIR}/dependency-only/CLAUDE.local.md")" = '' ] \
  || fail "dependency-only Claude instructions remained active"
[ "$(cat "${WORKTREE_DIR}/dependency-only/.claude/hook.sh")" = '' ] \
  || fail "dependency-only Claude hook remained active"
[ ! -e "${HOOK_SENTINEL}" ] \
  || fail "dependency checkout/index hook ran during worktree materialization"
[ -z "$(git -C "${WORKTREE_DIR}" diff --name-only --diff-filter=D)" ] \
  || fail "sanitized dependency-only control paths became forbidden deletions"

# A later execution of the same Issue reuses the local branch but receives an
# isolated log directory. Earlier evidence remains immutable, and fresh files
# are created privately for the new execution.
ISSUE_LOG_ROOT="${WORKTREE_DIR}/.req_executor/issue-2/log"
FIRST_EXECUTION_LOG_DIR="${ISSUE_LOG_ROOT}/execution-1"
SECOND_EXECUTION_LOG_DIR="${ISSUE_LOG_ROOT}/execution-2"
printf '{"execution_id":1}\n' >"${FIRST_EXECUTION_LOG_DIR}/acpx_terminal.json"
chmod 000 "${FIRST_EXECUTION_LOG_DIR}/acpx_terminal.json"
HARDLINK_TARGET="${TEST_ROOT}/worker-result-hardlink-target.json"
printf '{"sentinel":"must-survive"}\n' >"${HARDLINK_TARGET}"
ln "${HARDLINK_TARGET}" "${FIRST_EXECUTION_LOG_DIR}/worker_result.json"
printf '{"execution_id":1}\n' >"${FIRST_EXECUTION_LOG_DIR}/mr_result.json"
chmod 600 "${FIRST_EXECUTION_LOG_DIR}/mr_result.json"
PREP_REUSE_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=2 EXECUTION_ID=2 ISSUE_MODE=fresh \
  BRANCH=issue/9 CONFIG_BRANCH=main DEPENDENCY_BASE_SHA="${PINNED_SHA}" \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "prepare_attempt rejected fixed issue-local reuse"
[ "$(sed -n '2p' <<<"${PREP_REUSE_OUTPUT}")" = issue/2 ] \
  || fail "later run did not reuse the fixed issue-local branch"
for evidence_name in acpx_terminal.json worker_result.json mr_result.json; do
  [ ! -e "${SECOND_EXECUTION_LOG_DIR}/${evidence_name}" ] \
    || fail "new execution inherited stale ${evidence_name} content"
done
[ -s "${FIRST_EXECUTION_LOG_DIR}/acpx_terminal.json" ] \
  || fail "new execution modified earlier terminal evidence"
[ -s "${FIRST_EXECUTION_LOG_DIR}/mr_result.json" ] \
  || fail "new execution modified earlier MR evidence"
[ "$(cat "${HARDLINK_TARGET}")" = '{"sentinel":"must-survive"}' ] \
  || fail "later run truncated the hard-linked evidence target"
[ -z "$(git -C "${REPO_PATH}" for-each-ref \
  --format='%(refname)' 'refs/heads/issue/2-att*')" ] \
  || fail "prepare_attempt created a numbered attempt branch"
[ ! -e "${REPO_PATH}/.req_executor/.worktrees/.preserved-attempts" ] \
  || fail "prepare_attempt created a per-attempt runtime archive"
[ ! -e "${REPO_PATH}/.req_executor/.worktrees/.preserved-log-reruns" ] \
  || fail "prepare_attempt created a per-attempt log archive"

set +e
CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
ISSUE_IID=8 EXECUTION_ID=1 ISSUE_MODE=fresh \
BRANCH=issue/12 CONFIG_BRANCH=main \
DEPENDENCY_BASE_SHA="${MALICIOUS_FILTER_SHA}" \
  bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh" \
  >"${TEST_ROOT}/filter.out" 2>"${TEST_ROOT}/filter.err"
FILTER_RC=$?
set -e
[ "${FILTER_RC}" -ne 0 ] \
  || fail "dependency checkout filter was allowed to materialize"
grep -Fq 'dependency checkout filters are not allowed' \
  "${TEST_ROOT}/filter.err" \
  || fail "dependency checkout filter did not return the named safety error"
[ ! -e "${FILTER_SENTINEL}" ] \
  || fail "dependency checkout filter executed before rejection"
[ ! -e "${REPO_PATH}/.req_executor/.worktrees/issue-8" ] \
  || fail "rejected dependency filter created a worktree"

SYMLINK_CONTROL_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=5 EXECUTION_ID=1 ISSUE_MODE=fresh \
  BRANCH=issue/11 CONFIG_BRANCH=main \
  DEPENDENCY_BASE_SHA="${MALICIOUS_CLAUDE_SHA}" \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "trusted config refresh did not isolate a dependency .claude symlink"
SYMLINK_CONTROL_WORKTREE="${REPO_PATH}/.req_executor/.worktrees/issue-5"
[ -d "${SYMLINK_CONTROL_WORKTREE}/.claude" ] \
  && [ ! -L "${SYMLINK_CONTROL_WORKTREE}/.claude" ] \
  || fail "dependency .claude symlink survived trusted config refresh"
[ "$(cat "${SYMLINK_CONTROL_WORKTREE}/.claude/settings.json")" = \
    '{"hooks":{"trusted":true}}' ] \
  || fail "trusted .claude settings were not restored over a dependency symlink"
[ "$(cat "${OUTSIDE_CLAUDE}/sentinel")" = 'claude-sentinel' ] \
  || fail "dependency .claude symlink modified its outside target"

set +e
CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
ISSUE_IID=4 EXECUTION_ID=1 ISSUE_MODE=fresh \
BRANCH=issue/10 CONFIG_BRANCH=main \
DEPENDENCY_BASE_SHA="${MALICIOUS_RUNTIME_SHA}" \
  bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh" \
  >"${TEST_ROOT}/runtime-symlink.out" \
  2>"${TEST_ROOT}/runtime-symlink.err"
RUNTIME_SYMLINK_RC=$?
set -e
[ "${RUNTIME_SYMLINK_RC}" -ne 0 ] \
  || fail "dependency .req_executor symlink escaped the worktree runtime boundary"
[ "$(cat "${OUTSIDE_RUNTIME}/sentinel")" = 'runtime-sentinel' ] \
  || fail "dependency runtime symlink moved or rewrote outside durable state"
[ ! -e "${OUTSIDE_RUNTIME}/issue-4" ] \
  || fail "dependency runtime symlink created attempt state outside the worktree"

# The rejected worktree remains registered for audit, but a later safe retry
# must archive it and recreate from the new baseline instead of failing forever
# on the old runtime symlink before checkout.
SAFE_RETRY_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=4 EXECUTION_ID=2 ISSUE_MODE=fresh \
  BRANCH=main CONFIG_BRANCH=main \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "safe retry could not recover from a rejected runtime symlink"
printf '%s' "${SAFE_RETRY_OUTPUT}" | grep -Fxq fresh \
  || fail "safe runtime recovery did not remain a fresh attempt"
RECOVERED_RUNTIME_WORKTREE="${REPO_PATH}/.req_executor/.worktrees/issue-4"
[ -d "${RECOVERED_RUNTIME_WORKTREE}/.req_executor" ] \
  && [ ! -L "${RECOVERED_RUNTIME_WORKTREE}/.req_executor" ] \
  || fail "safe retry retained the malicious runtime symlink"
[ "$(git -C "${RECOVERED_RUNTIME_WORKTREE}" rev-parse HEAD)" = \
    "$(git -C "${REPO_PATH}" rev-parse refs/remotes/origin/main)" ] \
  || fail "safe runtime recovery did not checkout the requested baseline"
[ "$(cat "${OUTSIDE_RUNTIME}/sentinel")" = 'runtime-sentinel' ] \
  || fail "safe runtime recovery modified the outside symlink target"

# A fixed local issue branch may be the only verified continue source when the
# canonical remote branch is unavailable. Preparation must use the pinned SHA.
VERIFIED_CONTINUE_SHA="$(git -C "${REPO_PATH}" rev-parse refs/remotes/origin/main)"
UNVERIFIED_CONTINUE_SHA="${PINNED_SHA}"
git -C "${REPO_PATH}" update-ref refs/heads/issue/6 \
  "${VERIFIED_CONTINUE_SHA}"
PINNED_CONTINUE_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=6 EXECUTION_ID=3 ISSUE_MODE=continue \
  BRANCH=main CONFIG_BRANCH=main CONTINUE_BASE_REQUIRED=true \
  CONTINUE_BASE_SHA="${VERIFIED_CONTINUE_SHA}" \
  CONTINUE_BASE_REF=refs/heads/issue/6 \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "exact verified local continue base was rejected"
[ "$(sed -n '1p' <<<"${PINNED_CONTINUE_OUTPUT}")" = continue ] \
  || fail "exact local continue base unexpectedly downgraded"
PINNED_CONTINUE_WORKTREE="${REPO_PATH}/.req_executor/.worktrees/issue-6"
[ "$(git -C "${PINNED_CONTINUE_WORKTREE}" rev-parse HEAD)" = \
    "${VERIFIED_CONTINUE_SHA}" ] \
  || fail "prepare did not use the fixed verified local issue branch"

# A DAG v2 attempt always prepares its IID-local branch on the frozen
# aggregate base. Fresh starts there directly; continue first restores the
# published consumer tree and then mixed-resets to the same parent so the next
# business commit replaces, rather than appends to, the previous attempt.
DAG_PLAN_SHA=abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd
DAG_WORK_BRANCH=issue/14-dag-abcdefabcdefabcd
DAG_FRESH_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=14 EXECUTION_ID=1 ISSUE_MODE=fresh \
  BRANCH=main CONFIG_BRANCH=main WORK_BRANCH="${DAG_WORK_BRANCH}" \
  DEPENDENCY_CONTRACT_VERSION=2 \
  DEPENDENCY_PLAN_SHA256="${DAG_PLAN_SHA}" \
  DEPENDENCY_BASE_SHA="${PINNED_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${PINNED_SHA}" AUTO_MERGE=false \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "DAG v2 fresh preparation failed"
[ "$(sed -n '1p' <<<"${DAG_FRESH_OUTPUT}")" = fresh ] \
  || fail "DAG v2 fresh preparation returned the wrong mode"
DAG_WORKTREE="${REPO_PATH}/.req_executor/.worktrees/issue-14"
[ "$(git -C "${DAG_WORKTREE}" rev-parse HEAD)" = "${PINNED_SHA}" ] \
  || fail "DAG v2 fresh preparation did not use its frozen aggregate parent"

git -C "${AUTHOR_REPO}" switch -q -C "${DAG_WORK_BRANCH}" "${PINNED_SHA}"
printf 'dag-c1\n' >"${AUTHOR_REPO}/dag-c.txt"
git -C "${AUTHOR_REPO}" add dag-c.txt
git -C "${AUTHOR_REPO}" commit -qm dag-c1
DAG_C1_SHA="$(git -C "${AUTHOR_REPO}" rev-parse HEAD)"
git -C "${AUTHOR_REPO}" push -q -u origin "${DAG_WORK_BRANCH}"
DAG_CONTINUE_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=14 EXECUTION_ID=2 ISSUE_MODE=continue \
  BRANCH=main CONFIG_BRANCH=main WORK_BRANCH="${DAG_WORK_BRANCH}" \
  DEPENDENCY_CONTRACT_VERSION=2 \
  DEPENDENCY_PLAN_SHA256="${DAG_PLAN_SHA}" \
  DEPENDENCY_BASE_SHA="${PINNED_SHA}" \
  EXPECTED_WORK_BRANCH_SHA="${DAG_C1_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${PINNED_SHA}" AUTO_MERGE=false \
  CONTINUE_BASE_REQUIRED=true CONTINUE_BASE_SHA="${DAG_C1_SHA}" \
  CONTINUE_BASE_REF="refs/remotes/origin/${DAG_WORK_BRANCH}" \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "DAG v2 continue preparation failed"
[ "$(sed -n '1p' <<<"${DAG_CONTINUE_OUTPUT}")" = continue ] \
  || fail "DAG v2 continue unexpectedly downgraded"
[ "$(git -C "${DAG_WORKTREE}" rev-parse HEAD)" = "${PINNED_SHA}" ] \
  || fail "DAG v2 continue did not reset to its frozen aggregate parent"
[ "$(cat "${DAG_WORKTREE}/dag-c.txt")" = dag-c1 ] \
  || fail "DAG v2 continue lost the published consumer tree"
[ "$(git -C "${DAG_WORKTREE}" status --porcelain -- dag-c.txt)" = \
    '?? dag-c.txt' ] \
  || fail "DAG v2 continue did not convert the prior tree into a replacement diff"

# A shared tail continue must resume C's published tree without appending a
# second C commit. Preparation leaves the C tree in place but mixed-resets the
# local issue branch/index to frozen A, so the next commit replaces C1 as A's
# single direct child while the independent remote lease can still name C1.
git -C "${AUTHOR_REPO}" switch -q -C issue/9+13 "${PINNED_SHA}"
printf 'shared-c1\n' >"${AUTHOR_REPO}/shared-c.txt"
git -C "${AUTHOR_REPO}" add shared-c.txt
git -C "${AUTHOR_REPO}" commit -qm shared-c1
SHARED_C1_SHA="$(git -C "${AUTHOR_REPO}" rev-parse HEAD)"
git -C "${AUTHOR_REPO}" push -q -u origin issue/9+13
SHARED_CONTINUE_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=13 EXECUTION_ID=2 ISSUE_MODE=continue \
  BRANCH=main CONFIG_BRANCH=main WORK_BRANCH=issue/9+13 \
  SHARED_BRANCH_ROLE=tail DEPENDENCY_BASE_SHA="${PINNED_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${PINNED_SHA}" \
  CONTINUE_BASE_REQUIRED=true CONTINUE_BASE_SHA="${SHARED_C1_SHA}" \
  CONTINUE_BASE_REF=refs/remotes/origin/issue/9+13 \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh"
)" || fail "shared tail continue preparation failed"
[ "$(sed -n '1p' <<<"${SHARED_CONTINUE_OUTPUT}")" = continue ] \
  || fail "shared tail continue unexpectedly downgraded"
SHARED_CONTINUE_WORKTREE="${REPO_PATH}/.req_executor/.worktrees/issue-13"
[ "$(git -C "${SHARED_CONTINUE_WORKTREE}" rev-parse HEAD)" = "${PINNED_SHA}" ] \
  || fail "shared tail continue did not reset its commit parent to frozen A"
[ "$(cat "${SHARED_CONTINUE_WORKTREE}/shared-c.txt")" = shared-c1 ] \
  || fail "shared tail continue lost the published C worktree content"
[ "$(git -C "${SHARED_CONTINUE_WORKTREE}" status --porcelain -- shared-c.txt)" = \
    '?? shared-c.txt' ] \
  || fail "published C content was not converted into a replacement worktree diff"

# A remote resume ref is part of the preflight identity too. If another actor
# moves it after preflight, preparation must not work from the still-reachable
# old object and later force-push over the newer canonical C history.
git -C "${REPO_PATH}" update-ref refs/remotes/origin/issue/7 \
  "${VERIFIED_CONTINUE_SHA}"
git --git-dir="${ORIGIN_REPO}" update-ref refs/heads/issue/7 \
  "${UNVERIFIED_CONTINUE_SHA}"
set +e
CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=7 EXECUTION_ID=2 ISSUE_MODE=continue \
  BRANCH=main CONFIG_BRANCH=main CONTINUE_BASE_REQUIRED=true \
  CONTINUE_BASE_SHA="${VERIFIED_CONTINUE_SHA}" \
  CONTINUE_BASE_REF=refs/remotes/origin/issue/7 \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh" \
    >"${TEST_ROOT}/moved-continue.out" \
    2>"${TEST_ROOT}/moved-continue.err"
MOVED_CONTINUE_RC=$?
set -e
[ "${MOVED_CONTINUE_RC}" -ne 0 ] \
  || fail "moved remote continue ref was silently overwritten"
grep -Fq 'continue source ref disappeared or moved after dependency preflight' \
  "${TEST_ROOT}/moved-continue.err" \
  || fail "moved remote continue ref did not return the named safety error"
[ ! -e "${REPO_PATH}/.req_executor/.worktrees/issue-7" ] \
  || fail "moved remote continue ref created a worktree"

# If the exact preflighted commit disappears before preparation, continue must
# fail instead of silently downgrading to a fresh main checkout.
set +e
CONFIG_DIR="${CONFIG_DIR}" PROJECT=project GROUP=group \
  GITLAB_HOST=gitlab.test.invalid GITLAB_API_PROTOCOL=https \
  GITLAB_TOKEN=dependency-test-token REPO_PARENT_PATH="${REPO_PARENT}" \
  ISSUE_IID=3 EXECUTION_ID=1 ISSUE_MODE=continue \
  BRANCH=main CONFIG_BRANCH=main CONTINUE_BASE_REQUIRED=true \
  CONTINUE_BASE_SHA=ffffffffffffffffffffffffffffffffffffffff \
  CONTINUE_BASE_REF=refs/remotes/origin/issue/3 \
    bash "${FIXTURE_SCRIPTS}/prepare_attempt.sh" \
    >"${TEST_ROOT}/missing-continue.out" \
    2>"${TEST_ROOT}/missing-continue.err"
MISSING_CONTINUE_RC=$?
set -e
[ "${MISSING_CONTINUE_RC}" -ne 0 ] \
  || fail "disappearing required continue ref downgraded to a fresh checkout"
[ ! -e "${REPO_PATH}/.req_executor/.worktrees/issue-3" ] \
  || fail "disappearing required continue ref created a fresh worktree"

echo "ok dependency checkout pins code SHA and isolates Claude config"
