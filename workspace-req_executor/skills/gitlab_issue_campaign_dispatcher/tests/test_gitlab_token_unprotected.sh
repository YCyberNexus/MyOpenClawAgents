#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fail() {
  echo "test_gitlab_token_unprotected.sh: $*" >&2
  exit 1
}

for removed_helper in git_askpass.sh git_network_auth.sh redaction_utils.sh; do
  [ ! -e "${SKILL_DIR}/scripts/${removed_helper}" ] \
    || fail "GitLab token protection helper still exists: ${removed_helper}"
done

if rg -n \
    'trusted_git_|redact_sensitive|append_redacted|run_redacted' \
    "${SKILL_DIR}/scripts" >/dev/null; then
  fail "executor scripts still contain legacy GitLab token protection wrappers"
fi

GUARD_SCRIPT="${SKILL_DIR}/scripts/git_network_guard.sh"
[ -f "${GUARD_SCRIPT}" ] || fail "Git transport guard is missing"
grep -Fq 'GIT_ASKPASS=/usr/bin/false' "${GUARD_SCRIPT}" \
  || fail "Git transport guard does not disable interactive askpass"
grep -Fq -- '-c credential.helper=' "${GUARD_SCRIPT}" \
  || fail "Git transport guard does not disable configured credential helpers"
grep -Fq 'git_network_guard_clone' "${SKILL_DIR}/scripts/clone_or_pull.sh" \
  || fail "clone_or_pull.sh bypasses the guarded clone wrapper"
grep -Fq 'git_network_guard_run' "${SKILL_DIR}/scripts/clone_or_pull.sh" \
  || fail "clone_or_pull.sh bypasses the guarded fetch wrapper"

grep -Fq 'env -u GITLAB_TOKEN' "${SKILL_DIR}/scripts/run_acpx_attempt.sh" \
  || fail "inner acpx boundary does not remove the primary GitLab token"
grep -Fq -- '-u WIKI_GITLAB_TOKEN' "${SKILL_DIR}/scripts/run_acpx_attempt.sh" \
  || fail "inner acpx boundary does not remove alternate GitLab tokens"
grep -Fq 'PATH="${safety_bin}:${PATH}"' "${SKILL_DIR}/scripts/run_acpx_attempt.sh" \
  || fail "inner acpx boundary does not install the Git/glab safety wrappers"

grep -Fq 'oauth2:${GITLAB_TOKEN}@' "${SKILL_DIR}/scripts/clone_or_pull.sh" \
  || fail "clone_or_pull.sh does not use the deployment token directly"

echo "ok outer fixed Git uses the credential while the inner acpx boundary is stripped"
