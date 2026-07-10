#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREATE_BATCH="${SKILL_DIR}/scripts/create_driven_batch.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-create-batch.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/_scheduler"
BIN_DIR="${TEST_ROOT}/bin"
FAKE_GLAB="${BIN_DIR}/glab"
API_LOG="${TEST_ROOT}/glab-api.log"
mkdir -p "${CONFIG_DIR}" "${BIN_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF

cat >"${FAKE_GLAB}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  auth)
    if [ "${2:-}" = login ]; then
      token=""
      shift 2
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --token ]; then
          shift
          token="${1:-}"
        fi
        [ "$#" -gt 0 ] && shift
      done
      [ "${token}" = "executor-owned-token" ] || {
        echo "fake glab received an unexpected auth token" >&2
        exit 89
      }
    fi
    exit 0
    ;;
  api)
    endpoint="${2:-}"
    printf '%s\n' "${endpoint}" >>"${FAKE_GLAB_API_LOG:?}"
    if [[ ! "${endpoint}" =~ ^projects/group%2Frepo/issues\?state=opened\&per_page=100\&page=([0-9]+)$ ]]; then
      echo "unexpected GitLab API endpoint: ${endpoint}" >&2
      exit 90
    fi
    page="${BASH_REMATCH[1]}"
    case "${FAKE_GLAB_MODE:-success}:${page}" in
      fail_page_2:2)
        echo "simulated page 2 failure" >&2
        exit 91
        ;;
      malformed_page_2:2)
        printf '%s\n' '{"not":"an array"}'
        ;;
      *:1)
        printf '%s\n' '[
          {"iid":4,"state":"opened","labels":["smoke","timeout"]},
          {"iid":2,"state":"opened","labels":["pr"]},
          {"iid":1,"state":"opened","labels":[]}
        ]'
        ;;
      *:2)
        printf '%s\n' '[
          {"iid":4,"state":"opened","labels":["smoke","timeout"]},
          {"iid":3,"state":"opened","labels":["blocked-cc"]},
          {"iid":5,"state":"closed","labels":["smoke"]}
        ]'
        ;;
      *:3)
        printf '%s\n' '[]'
        ;;
      *)
        echo "unexpected pagination past the empty page: ${page}" >&2
        exit 92
        ;;
    esac
    ;;
  *)
    echo "unexpected fake glab command: $*" >&2
    exit 93
    ;;
esac
EOF
chmod +x "${FAKE_GLAB}"

run_batch() {
  local batch_id="$1"
  local selector_lines="$2"
  local mode="${3:-success}"

  FAKE_GLAB_API_LOG="${API_LOG}" \
    FAKE_GLAB_MODE="${mode}" \
    GLAB_BIN="${FAKE_GLAB}" \
    GITLAB_TOKEN="executor-owned-token" \
    CONFIG_DIR="${CONFIG_DIR}" \
    bash "${CREATE_BATCH}" <<EOF
RUN_DRIVEN_ISSUE_BATCH
batch_id=${batch_id}
correlation_id=correlation-${batch_id}
project=group/repo
${selector_lines}
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
EOF
}

unfinished_out="$(run_batch unfinished 'selector_type=open_unfinished')"
label_out="$(run_batch label $'selector_type=open_label\nlabel=smoke')"
range_out="$(run_batch range $'selector_type=range\niid_min=2\niid_max=4')"
single_out="$(run_batch single $'selector_type=single\niid=2')"

BATCH_ROOT="${SCHEDULER_ROOT}/batches"
jq -e '.iids == [1]' "${BATCH_ROOT}/unfinished/snapshot.json" >/dev/null
jq -e '.iids == [4]' "${BATCH_ROOT}/label/snapshot.json" >/dev/null
jq -e '.iids == [2,3,4]' "${BATCH_ROOT}/range/snapshot.json" >/dev/null
jq -e '.iids == [2]' "${BATCH_ROOT}/single/snapshot.json" >/dev/null

for batch_id in unfinished label range single; do
  for filename in request.json snapshot.json state.json; do
    [ -f "${BATCH_ROOT}/${batch_id}/${filename}" ] || {
      echo "expected persisted ${filename} for ${batch_id}" >&2
      exit 1
    }
  done
  jq -e \
    --arg batch_id "${batch_id}" \
    '.batch_id == $batch_id
      and .matched_count >= 1
      and (.request_digest | type == "string" and length == 64)
      and (.snapshot_digest | type == "string" and length == 64)
      and .status == "queued"' \
    "${BATCH_ROOT}/${batch_id}/state.json" >/dev/null
done

jq -e \
  '.status == "success"
    and .batch_id == "unfinished"
    and .matched_count == 1
    and (.snapshot_digest | length == 64)
    and .scheduler_status == "queued"
    and (has("iids") | not)' \
  <<<"${unfinished_out}" >/dev/null
jq -e '.matched_count == 1 and .scheduler_status == "queued"' <<<"${label_out}" >/dev/null
jq -e '.matched_count == 3 and .scheduler_status == "queued"' <<<"${range_out}" >/dev/null
jq -e '.matched_count == 1 and .scheduler_status == "queued"' <<<"${single_out}" >/dev/null

api_calls_before_replay="$(wc -l <"${API_LOG}" | tr -d ' ')"
snapshot_before_replay="$(<"${BATCH_ROOT}/label/snapshot.json")"
label_replay_out="$(run_batch label $'selector_type=open_label\nlabel=smoke')"
api_calls_after_replay="$(wc -l <"${API_LOG}" | tr -d ' ')"

[ "${api_calls_after_replay}" = "${api_calls_before_replay}" ] || {
  echo "idempotent replay unexpectedly queried GitLab" >&2
  exit 1
}
jq -e \
  --arg digest "$(jq -r '.snapshot_digest' <<<"${label_out}")" \
  '.snapshot_digest == $digest and .matched_count == 1' \
  <<<"${label_replay_out}" >/dev/null
[ "$(<"${BATCH_ROOT}/label/snapshot.json")" = "${snapshot_before_replay}" ] || {
  echo "idempotent replay mutated immutable snapshot.json" >&2
  exit 1
}

if run_batch label $'selector_type=open_label\nlabel=other' >"${TEST_ROOT}/conflict.out" 2>"${TEST_ROOT}/conflict.err"; then
  echo "expected changed request for an existing batch ID to fail" >&2
  exit 1
fi
[ "$(<"${BATCH_ROOT}/label/snapshot.json")" = "${snapshot_before_replay}" ] || {
  echo "conflicting replay mutated immutable snapshot.json" >&2
  exit 1
}

if run_batch failed-page-2 'selector_type=open_unfinished' fail_page_2 \
  >"${TEST_ROOT}/failed-page-2.out" 2>"${TEST_ROOT}/failed-page-2.err"; then
  echo "expected a GitLab pagination failure to fail batch intake" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/failed-page-2/snapshot.json" ] || {
  echo "pagination failure left a runnable partial snapshot" >&2
  exit 1
}

if run_batch malformed-page-2 'selector_type=open_unfinished' malformed_page_2 \
  >"${TEST_ROOT}/malformed-page-2.out" 2>"${TEST_ROOT}/malformed-page-2.err"; then
  echo "expected a non-array GitLab page to fail batch intake" >&2
  exit 1
fi
[ ! -e "${BATCH_ROOT}/malformed-page-2/snapshot.json" ] || {
  echo "malformed pagination left a runnable partial snapshot" >&2
  exit 1
}

FAILED_INTAKE="${SCHEDULER_ROOT}/failed-intake"
[ -d "${FAILED_INTAKE}" ] || {
  echo "expected failed intake evidence directory" >&2
  exit 1
}
failed_evidence_count="$(find "${FAILED_INTAKE}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "${failed_evidence_count}" -ge 2 ] || {
  echo "expected pagination failures to retain intake evidence" >&2
  exit 1
}
if find "${FAILED_INTAKE}" -name snapshot.json -print -quit | grep -q .; then
  echo "failed intake evidence must not contain runnable snapshot.json" >&2
  exit 1
fi

if FAKE_GLAB_API_LOG="${API_LOG}" \
  GLAB_BIN="${FAKE_GLAB}" \
  GITLAB_TOKEN="executor-owned-token" \
  CONFIG_DIR="${CONFIG_DIR}" \
  bash "${CREATE_BATCH}" >"${TEST_ROOT}/token-field.out" 2>"${TEST_ROOT}/token-field.err" <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=token-field
correlation_id=correlation-token-field
project=group/repo
selector_type=single
iid=1
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
gitlab_token=must-not-be-accepted
EOF
then
  echo "expected token material in the trigger to be rejected" >&2
  exit 1
fi

jq -e '
  .batch_order == ["unfinished","label","range","single"]
  and (.batch_order | length) == (.batch_order | unique | length)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

echo 'ok create driven batch snapshot'
