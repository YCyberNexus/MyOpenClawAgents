#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-legacy-i2-auth.XXXXXX")"
CALLBACK_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
CALLBACK_NONCE_SHA256="$({
  printf '%s' "${CALLBACK_NONCE}"
} | if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi)"

initialize_state() {
  local state_root="$1"
  local auth_mode="$2"
  local pending_project="${3:-group/project}"

  STATE_ROOT="${state_root}" "${BASH}" -c '
    source "$1"
    ensure_state_dirs
  ' _ "${SKILL_DIR}/scripts/env_paths.sh"

  if [ "${auth_mode}" = nonce_v1 ]; then
    jq -cn \
      --arg nonce "${CALLBACK_NONCE}" \
      --arg nonce_sha256 "${CALLBACK_NONCE_SHA256}" '{
        next_id:2,
        active:{
          queue_id:"execq-1",
          correlation_id:"reqd-1",
          run_id:"executor-execq-1",
          project:"group/project",
          iid:42,
          executor_agent:"req_executor",
          callback_nonce:$nonce,
          driven_callback_auth_mode:"nonce_v1",
          driven_callback_nonce_sha256:$nonce_sha256,
          launch_state:"launched"
        },
        queue:[]
      }' >"${state_root}/_dispatcher/executor_queue.json"
    jq -cn \
      --arg project "${pending_project}" \
      --arg nonce_sha256 "${CALLBACK_NONCE_SHA256}" '{
        pending:{
          "executor-execq-1":{
            run_id:"executor-execq-1",
            stage:"executor",
            origin:null,
            project:$project,
            iid:42,
            correlation_id:"reqd-1",
            callback_auth_mode:"nonce_v1",
            callback_nonce_sha256:$nonce_sha256,
            child_session_key:null,
            spawned_at:1,
            req_digest:"request"
          }
        }
      }' >"${state_root}/_dispatcher/pending.json"
  elif [ "${auth_mode}" = legacy_pre_upgrade ]; then
    jq -cn '{
      next_id:2,
      active:{
        queue_id:"execq-1",
        correlation_id:"reqd-1",
        run_id:"executor-execq-1",
        project:"group/project",
        iid:42,
        executor_agent:"req_executor",
        driven_callback_auth_mode:"legacy_pre_upgrade",
        driven_callback_nonce_sha256:null,
        launch_state:"launched"
      },
      queue:[]
    }' >"${state_root}/_dispatcher/executor_queue.json"
    jq -cn --arg project "${pending_project}" '{
      pending:{
        "executor-execq-1":{
          run_id:"executor-execq-1",
          stage:"executor",
          origin:null,
          project:$project,
          iid:42,
          correlation_id:"reqd-1",
          callback_auth_mode:"legacy_pre_upgrade",
          callback_nonce_sha256:null,
          child_session_key:null,
          spawned_at:1,
          req_digest:"request"
        }
      }
    }' >"${state_root}/_dispatcher/pending.json"
  else
    jq -cn '{
      next_id:2,
      active:{
        queue_id:"execq-1",
        correlation_id:"reqd-1",
        run_id:"executor-execq-1",
        project:"group/project",
        iid:42,
        executor_agent:"req_executor"
      },
      queue:[]
    }' >"${state_root}/_dispatcher/executor_queue.json"
    jq -cn '{
      pending:{
        "executor-execq-1":{
          run_id:"executor-execq-1",
          stage:"executor",
          origin:null,
          project:"group/project",
          iid:42,
          correlation_id:"reqd-1",
          child_session_key:null,
          spawned_at:1,
          req_digest:"request"
        }
      }
    }' >"${state_root}/_dispatcher/pending.json"
  fi
}

state_snapshot() {
  local state_root="$1"
  {
    jq -cS . "${state_root}/_dispatcher/executor_queue.json"
    jq -cS . "${state_root}/_dispatcher/pending.json"
    sed -n '1,$p' "${state_root}/_dispatcher/ledger.jsonl"
  }
}

assert_rejected_unchanged() {
  local label="$1"
  local state_root="$2"
  shift 2
  local before after rc

  before="$(state_snapshot "${state_root}")"
  set +e
  STATE_ROOT="${state_root}" "$@" \
    >"${TEST_ROOT}/${label}.out" 2>"${TEST_ROOT}/${label}.err"
  rc=$?
  set -e
  after="$(state_snapshot "${state_root}")"
  if [ "${rc}" -eq 0 ] || [ "${after}" != "${before}" ]; then
    echo "legacy I2 authorization did not fail closed: ${label}" >&2
    exit 1
  fi
}

NONCE_FIND_ROOT="${TEST_ROOT}/nonce-find"
initialize_state "${NONCE_FIND_ROOT}" nonce_v1
assert_rejected_unchanged nonce-find "${NONCE_FIND_ROOT}" \
  env RUN_ID=executor-execq-1 "${BASH}" "${SKILL_DIR}/scripts/find_pending.sh"

NONCE_DRAIN_ROOT="${TEST_ROOT}/nonce-drain"
initialize_state "${NONCE_DRAIN_ROOT}" nonce_v1
assert_rejected_unchanged nonce-drain "${NONCE_DRAIN_ROOT}" \
  env RUN_ID=executor-execq-1 OUTCOME=success STAGE=executor \
    PROJECT=group/project IID=42 STATUS=done \
    "${BASH}" "${SKILL_DIR}/scripts/drain_pending.sh"

NONCE_FINISH_ROOT="${TEST_ROOT}/nonce-finish"
initialize_state "${NONCE_FINISH_ROOT}" nonce_v1
assert_rejected_unchanged nonce-finish "${NONCE_FINISH_ROOT}" \
  env CORRELATION_ID=reqd-1 PROJECT=group/project IID=42 \
    "${BASH}" "${SKILL_DIR}/scripts/finish_executor_queue_active.sh"

IDENTITY_FIND_ROOT="${TEST_ROOT}/identity-find"
initialize_state "${IDENTITY_FIND_ROOT}" legacy_pre_upgrade group/other
assert_rejected_unchanged identity-find "${IDENTITY_FIND_ROOT}" \
  env RUN_ID=executor-execq-1 "${BASH}" "${SKILL_DIR}/scripts/find_pending.sh"

IDENTITY_DRAIN_ROOT="${TEST_ROOT}/identity-drain"
initialize_state "${IDENTITY_DRAIN_ROOT}" legacy_pre_upgrade group/other
assert_rejected_unchanged identity-drain "${IDENTITY_DRAIN_ROOT}" \
  env RUN_ID=executor-execq-1 OUTCOME=success STAGE=executor \
    PROJECT=group/project IID=42 STATUS=done \
    "${BASH}" "${SKILL_DIR}/scripts/drain_pending.sh"

IDENTITY_FINISH_ROOT="${TEST_ROOT}/identity-finish"
initialize_state "${IDENTITY_FINISH_ROOT}" legacy_pre_upgrade
assert_rejected_unchanged identity-finish "${IDENTITY_FINISH_ROOT}" \
  env CORRELATION_ID=reqd-1 PROJECT=group/other IID=42 \
    "${BASH}" "${SKILL_DIR}/scripts/finish_executor_queue_active.sh"

LAUNCHING_FIND_ROOT="${TEST_ROOT}/launching-find"
initialize_state "${LAUNCHING_FIND_ROOT}" legacy_pre_upgrade
jq '.active.launch_state = "launching"' \
  "${LAUNCHING_FIND_ROOT}/_dispatcher/executor_queue.json" \
  >"${LAUNCHING_FIND_ROOT}/executor_queue.next.json"
mv "${LAUNCHING_FIND_ROOT}/executor_queue.next.json" \
  "${LAUNCHING_FIND_ROOT}/_dispatcher/executor_queue.json"
assert_rejected_unchanged launching-find "${LAUNCHING_FIND_ROOT}" \
  env RUN_ID=executor-execq-1 "${BASH}" "${SKILL_DIR}/scripts/find_pending.sh"

LAUNCHING_DRAIN_ROOT="${TEST_ROOT}/launching-drain"
initialize_state "${LAUNCHING_DRAIN_ROOT}" legacy_pre_upgrade
jq '.active.launch_state = "launching"' \
  "${LAUNCHING_DRAIN_ROOT}/_dispatcher/executor_queue.json" \
  >"${LAUNCHING_DRAIN_ROOT}/executor_queue.next.json"
mv "${LAUNCHING_DRAIN_ROOT}/executor_queue.next.json" \
  "${LAUNCHING_DRAIN_ROOT}/_dispatcher/executor_queue.json"
assert_rejected_unchanged launching-drain "${LAUNCHING_DRAIN_ROOT}" \
  env RUN_ID=executor-execq-1 OUTCOME=success STAGE=executor \
    PROJECT=group/project IID=42 STATUS=done \
    "${BASH}" "${SKILL_DIR}/scripts/drain_pending.sh"

LAUNCHING_FINISH_ROOT="${TEST_ROOT}/launching-finish"
initialize_state "${LAUNCHING_FINISH_ROOT}" legacy_pre_upgrade
jq '.active.launch_state = "launching"' \
  "${LAUNCHING_FINISH_ROOT}/_dispatcher/executor_queue.json" \
  >"${LAUNCHING_FINISH_ROOT}/executor_queue.next.json"
mv "${LAUNCHING_FINISH_ROOT}/executor_queue.next.json" \
  "${LAUNCHING_FINISH_ROOT}/_dispatcher/executor_queue.json"
assert_rejected_unchanged launching-finish "${LAUNCHING_FINISH_ROOT}" \
  env CORRELATION_ID=reqd-1 PROJECT=group/project IID=42 \
    "${BASH}" "${SKILL_DIR}/scripts/finish_executor_queue_active.sh"

LEGACY_ROOT="${TEST_ROOT}/real-legacy"
initialize_state "${LEGACY_ROOT}" unmarked_legacy
legacy_entry="$(
  STATE_ROOT="${LEGACY_ROOT}" RUN_ID=executor-execq-1 \
    "${BASH}" "${SKILL_DIR}/scripts/find_pending.sh"
)"
if ! jq -e '
    .callback_auth_mode == "legacy_pre_upgrade"
    and .callback_nonce_sha256 == null
  ' <<<"${legacy_entry}" >/dev/null \
  || ! jq -e '
    .pending["executor-execq-1"].callback_auth_mode == "legacy_pre_upgrade"
    and .pending["executor-execq-1"].callback_nonce_sha256 == null
  ' "${LEGACY_ROOT}/_dispatcher/pending.json" >/dev/null \
  || ! jq -e '
    .active.driven_callback_auth_mode == "legacy_pre_upgrade"
    and .active.driven_callback_nonce_sha256 == null
    and (.active | has("callback_nonce") | not)
  ' "${LEGACY_ROOT}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "real pre-upgrade callback state was not explicitly marked legacy" >&2
  exit 1
fi

STATE_ROOT="${LEGACY_ROOT}" \
RUN_ID=executor-execq-1 \
OUTCOME=success \
STAGE=executor \
PROJECT=group/project \
IID=42 \
STATUS=done \
  "${BASH}" "${SKILL_DIR}/scripts/drain_pending.sh" >/dev/null
legacy_finish="$(
  STATE_ROOT="${LEGACY_ROOT}" \
  CORRELATION_ID=reqd-1 \
  PROJECT=group/project \
  IID=42 \
    "${BASH}" "${SKILL_DIR}/scripts/finish_executor_queue_active.sh"
)"
if ! jq -e '.status == "cleared"' <<<"${legacy_finish}" >/dev/null \
  || ! jq -e '.pending | length == 0' \
    "${LEGACY_ROOT}/_dispatcher/pending.json" >/dev/null \
  || ! jq -e '.active == null' \
    "${LEGACY_ROOT}/_dispatcher/executor_queue.json" >/dev/null \
  || ! jq -e '
    select(.run_id == "executor-execq-1"
      and .stage == "executor"
      and .was_pending == true)
  ' "${LEGACY_ROOT}/_dispatcher/ledger.jsonl" >/dev/null; then
  echo "explicit pre-upgrade legacy I2 callback did not complete normally" >&2
  exit 1
fi

echo "ok legacy I2 callbacks require explicit legacy identity"
