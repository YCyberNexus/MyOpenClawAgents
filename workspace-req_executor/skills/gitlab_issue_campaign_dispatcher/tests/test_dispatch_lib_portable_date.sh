#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-lib-portable-date.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/fake-bin"
DATE_CALL_LOG="${TEST_ROOT}/date-calls.log"
mkdir -p "${FAKE_BIN}"
: >"${DATE_CALL_LOG}"

fail() {
  echo "test_dispatch_lib_portable_date.sh: $*" >&2
  exit 1
}

# Simulate GNU `date -d` failing after writing misleading stdout, while the
# native BSD/macOS parser succeeds. A failed probe's stdout must never leak
# into the epoch returned to timeout/retry arithmetic.
cat >"${FAKE_BIN}/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DATE_CALL_LOG:?}"
if [ "${1:-}" = -u ] && [ "${2:-}" = -d ]; then
  printf '%s\n' 'gnu-probe-stdout-noise'
  printf '%s\n' 'synthetic GNU parse failure' >&2
  exit 1
fi
if [ "${1:-}" = -j ] && [ "${2:-}" = -u ] && [ "${3:-}" = -f ]; then
  if [ "${5:-}" = '2026-07-21T00:00:00Z' ]; then
    printf '%s\n' 1784592000
    exit 0
  fi
  printf '%s\n' 'bsd-probe-stdout-noise'
  printf '%s\n' 'synthetic BSD parse failure' >&2
  exit 1
fi
exit 64
EOF
chmod +x "${FAKE_BIN}/date"
export DATE_CALL_LOG

dispatch_libs=(
  "${REPO_ROOT}/workspace-emcp/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh"
  "${REPO_ROOT}/workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh"
  "${REPO_ROOT}/workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh"
)

for dispatch_lib in "${dispatch_libs[@]}"; do
  [ -f "${dispatch_lib}" ] || fail "missing dispatcher library: ${dispatch_lib}"
  (
    export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign-state.json"
    export DISPATCHER_LOG_DIR="${TEST_ROOT}/logs"
    export PROJECT_URI='group%2Frepo'
    export ISSUES_ROOT="${TEST_ROOT}/issues"
    source "${dispatch_lib}"

    parsed="$(PATH="${FAKE_BIN}:/usr/bin:/bin" \
      iso_to_epoch '2026-07-21T00:00:00Z')"
    [ "${parsed}" = 1784592000 ] \
      || fail "BSD fallback leaked probe output or returned the wrong epoch: ${dispatch_lib}: ${parsed}"

    invalid="$(PATH="${FAKE_BIN}:/usr/bin:/bin" iso_to_epoch 'not-a-timestamp')"
    [ "${invalid}" = 0 ] \
      || fail "failed date probes leaked stdout: ${dispatch_lib}: ${invalid}"

    : >"${DATE_CALL_LOG}"
    [ "$(PATH="${FAKE_BIN}:/usr/bin:/bin" iso_to_epoch '')" = 0 ] \
      || fail "empty timestamps must return zero: ${dispatch_lib}"
    [ "$(PATH="${FAKE_BIN}:/usr/bin:/bin" iso_to_epoch null)" = 0 ] \
      || fail "null timestamps must return zero: ${dispatch_lib}"
    [ ! -s "${DATE_CALL_LOG}" ] \
      || fail "empty/null timestamps unexpectedly invoked date: ${dispatch_lib}"

    native="$(PATH='/usr/bin:/bin' iso_to_epoch '2026-07-21T00:00:00Z')"
    [ "${native}" = 1784592000 ] \
      || fail "host-native date parser returned the wrong epoch: ${dispatch_lib}: ${native}"
  )
done

echo "ok dispatcher ISO timestamp parsing is GNU/BSD portable and probe-safe"
