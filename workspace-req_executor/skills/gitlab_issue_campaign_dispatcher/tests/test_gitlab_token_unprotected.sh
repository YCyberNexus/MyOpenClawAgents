#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"

fail() {
  echo "test_gitlab_token_unprotected.sh: $*" >&2
  exit 1
}

for removed_helper in git_askpass.sh git_network_auth.sh redaction_utils.sh; do
  [ ! -e "${SKILL_DIR}/scripts/${removed_helper}" ] \
    || fail "GitLab token protection helper still exists: ${removed_helper}"
done

if rg -n \
    'trusted_git_|redact_sensitive|append_redacted|run_redacted|GIT_ASKPASS|credential\.helper' \
    "${SKILL_DIR}/scripts" >/dev/null; then
  fail "executor scripts still contain GitLab token protection wrappers"
fi

if rg -n -- '-u (GITLAB_TOKEN|GLAB_TOKEN|GITLAB_PRIVATE_TOKEN|PRIVATE_TOKEN|WIKI_GITLAB_TOKEN)' \
    "${SKILL_DIR}/scripts" \
    "${REPO_ROOT}/workspace-req_dispatcher/skills/requirement_dispatch/scripts" \
    >/dev/null; then
  fail "a child-process boundary still removes GitLab token environment variables"
fi

grep -Fq 'oauth2:${GITLAB_TOKEN}@' "${SKILL_DIR}/scripts/clone_or_pull.sh" \
  || fail "clone_or_pull.sh does not use the deployment token directly"

echo "ok GitLab token flows without confidentiality wrappers"
