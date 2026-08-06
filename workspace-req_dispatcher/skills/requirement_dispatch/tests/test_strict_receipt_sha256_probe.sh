#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
EXECUTOR_STOP="${SKILL_DIR}/../../../workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/stop_repository_mission.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/strict-receipt-sha256.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
EXPECTED_DIGEST="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
FALLBACK_DIGEST="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
mkdir -p "${FAKE_BIN}"

# shellcheck source=../scripts/_executor_batch_outbox_lib.sh
source "${SKILL_DIR}/scripts/_executor_batch_outbox_lib.sh"
EXECUTOR_SHA_FUNCTION="$(sed -n '/^sha256_text() {/,/^}/p' "${EXECUTOR_STOP}")"
[ -n "${EXECUTOR_SHA_FUNCTION}" ] || {
  echo "could not extract executor mission-stop SHA helper" >&2
  exit 1
}

cat >"${FAKE_BIN}/sha256sum" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
case "${FAKE_SHA_MODE:?}" in
  failed_with_stdout)
    printf '%064d  -\n' 0
    exit 17
    ;;
  successful_garbage)
    printf '%s\n' 'diagnostic-that-is-not-a-digest'
    exit 0
    ;;
  *) exit 18 ;;
esac
EOF
cat >"${FAKE_BIN}/shasum" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -a ] && [ "${2:-}" = 256 ]
cat >/dev/null
printf '%s  -\n' 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
EOF
chmod +x "${FAKE_BIN}/sha256sum" "${FAKE_BIN}/shasum"

run_executor_sha() {
  local mode="$1"
  printf '%s' abc | env \
    PATH="${FAKE_BIN}:${PATH}" \
    FAKE_SHA_MODE="${mode}" \
    EXECUTOR_SHA_FUNCTION="${EXECUTOR_SHA_FUNCTION}" \
    bash -c 'set -euo pipefail; eval "${EXECUTOR_SHA_FUNCTION}"; sha256_text'
}

for mode in failed_with_stdout successful_garbage; do
  dispatcher_digest="$(printf '%s' abc | env \
    PATH="${FAKE_BIN}:${PATH}" FAKE_SHA_MODE="${mode}" \
    bash -c 'set -euo pipefail; source "$1"; executor_batch_sha256' \
      bash "${SKILL_DIR}/scripts/_executor_batch_outbox_lib.sh")"
  [ "${dispatcher_digest}" = "${FALLBACK_DIGEST}" ] || {
    echo "dispatcher accepted misleading sha256sum output for ${mode}" >&2
    exit 1
  }
  [ "$(run_executor_sha "${mode}")" = "${FALLBACK_DIGEST}" ] || {
    echo "executor accepted misleading sha256sum output for ${mode}" >&2
    exit 1
  }
done

[ "$(printf '%s' abc | executor_batch_sha256)" = "${EXPECTED_DIGEST}" ] || {
  echo "host SHA-256 implementation returned an unexpected digest" >&2
  exit 1
}

if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/shasum ]; then
  NATIVE_BIN="${TEST_ROOT}/native-bin"
  mkdir -p "${NATIVE_BIN}"
  cat >"${NATIVE_BIN}/shasum" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/shasum "$@"
EOF
  chmod +x "${NATIVE_BIN}/shasum"
  native_digest="$(printf '%s' abc | env \
    PATH="${NATIVE_BIN}:/bin" \
    EXECUTOR_SHA_FUNCTION="${EXECUTOR_SHA_FUNCTION}" \
    bash -c 'set -euo pipefail; eval "${EXECUTOR_SHA_FUNCTION}"; sha256_text')"
  [ "${native_digest}" = "${EXPECTED_DIGEST}" ] || {
    echo "native macOS shasum output was rejected or misparsed" >&2
    exit 1
  }
fi

echo "ok strict receipt SHA probes reject misleading output and support GNU/macOS formats"
