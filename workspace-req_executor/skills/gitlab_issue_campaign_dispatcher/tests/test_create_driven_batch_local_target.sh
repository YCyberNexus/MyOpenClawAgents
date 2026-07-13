#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREATE_BATCH="${SKILL_DIR}/scripts/create_driven_batch.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-create-local-target.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GLAB="${BIN_DIR}/glab"
GLAB_LOG="${TEST_ROOT}/glab.log"
mkdir -p "${CONFIG_DIR}" "${BIN_DIR}"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=tracked-token-must-not-reach-local
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
EOF
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<'EOF'
GITLAB_HOST=local-file.example:9443
GITLAB_API_PROTOCOL=https
REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true
REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=local-file.example:9443
EOF

cat >"${FAKE_GLAB}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${GITLAB_HOST:-}" = "${FAKE_EXPECTED_HOST:?}" ] || exit 81
[ "${GITLAB_API_PROTOCOL:-}" = "${FAKE_EXPECTED_PROTOCOL:?}" ] || exit 82
printf '%s\t%s\t%s\n' \
  "${GITLAB_HOST}" "${GITLAB_API_PROTOCOL}" "${1:-}" \
  >>"${FAKE_GLAB_LOG:?}"
case "${1:-}" in
  auth)
    exit 0
    ;;
  api)
    [ "${2:-}" = graphql ] || exit 83
    printf '%s\n' '{"data":{"project":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
    ;;
  *)
    exit 84
    ;;
esac
EOF
chmod +x "${FAKE_GLAB}"

run_batch() {
  local batch_id="$1" expected_host="$2" expected_protocol="$3"
  shift 3
  env \
    -u GITLAB_HOST -u GITLAB_API_PROTOCOL -u GITLAB_ADDRESS \
    -u REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE \
    -u REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS \
    CONFIG_DIR="${CONFIG_DIR}" GLAB_BIN="${FAKE_GLAB}" \
    GITLAB_TOKEN=local-test-token \
    FAKE_GLAB_LOG="${GLAB_LOG}" \
    FAKE_EXPECTED_HOST="${expected_host}" \
    FAKE_EXPECTED_PROTOCOL="${expected_protocol}" \
    "$@" \
    "${BASH}" "${CREATE_BATCH}" <<EOF
RUN_DRIVEN_ISSUE_BATCH
batch_id=${batch_id}
correlation_id=correlation-${batch_id}
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
}

: >"${GLAB_LOG}"
process_out="$(run_batch process-target localhost:8081 http \
  GITLAB_HOST=localhost:8081 GITLAB_API_PROTOCOL=http \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=localhost:8081)"
jq -e '
  .status == "success"
  and .batch_id == "process-target"
  and .matched_count == 0
  and .scheduler_status == "completed"
' <<<"${process_out}" >/dev/null || {
  echo "process-local GitLab target did not complete batch intake" >&2
  exit 1
}
if grep -Fq 'gitlab-b.pxsemic.tech:30000' "${GLAB_LOG}"; then
  echo "create_driven_batch touched the tracked host before the process override" >&2
  exit 1
fi

: >"${GLAB_LOG}"
local_file_out="$(run_batch local-file-target \
  local-file.example:9443 https)"
jq -e '
  .status == "success"
  and .batch_id == "local-file-target"
  and .matched_count == 0
  and .scheduler_status == "completed"
' <<<"${local_file_out}" >/dev/null || {
  echo "ignored local GitLab target did not complete batch intake" >&2
  exit 1
}
if grep -Fq 'gitlab-b.pxsemic.tech:30000' "${GLAB_LOG}"; then
  echo "create_driven_batch touched the tracked host before the local-file override" >&2
  exit 1
fi

: >"${GLAB_LOG}"
set +e
run_batch tracked-host gitlab-b.pxsemic.tech:30000 http \
  GITLAB_HOST=gitlab-b.pxsemic.tech:30000 GITLAB_API_PROTOCOL=http \
  REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true \
  REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=gitlab-b.pxsemic.tech:30000 \
  >"${TEST_ROOT}/tracked-host.out" 2>"${TEST_ROOT}/tracked-host.err"
tracked_rc=$?
set -e
[ "${tracked_rc}" -eq 14 ] || {
  echo "create_driven_batch did not fail closed on the tracked host" >&2
  exit 1
}
[ ! -s "${GLAB_LOG}" ] || {
  echo "create_driven_batch called glab for the tracked host in local-test mode" >&2
  exit 1
}

echo "ok driven batch chooses process/local GitLab targets before glab"
