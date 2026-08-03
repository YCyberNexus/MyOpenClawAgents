#!/usr/bin/env bash
# Run one complete per-Issue executor execution in a single Bash tool call.
#
# The OpenClaw outer subagent used to call run_acpx_attempt.sh and then rely on
# another model turn to start staging. A long synchronous acpx tool call can
# return without that next turn being scheduled, leaving the native subagent
# (and therefore a global subagent slot) alive until somebody talks to it.
# This wrapper keeps the whole deterministic path in one process:
#
#   acpx -> stage -> commit/push -> verify -> labels -> MR -> summary
#        -> persist worker result -> append terminal logs to WORK_BRANCH
#
# The compact worker result is written atomically to
# ${LOG_DIR}/worker_result.json, but becomes heartbeat-consumable only after
# ${LOG_DIR}/attempt_finalized.json is published last with its exact SHA-256.
# Git receives the staging-time LOG_DIR in the business commit and the complete
# terminal LOG_DIR in a log-only child on that same Issue branch. Single-Issue
# state keeps the business commit distinct from that exact remote tip. No
# second class of remote branch is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    return 1
  fi
}

# Reject an invalid caller identity before env_paths.sh can create or migrate
# any runtime directories.  The work branch itself is the canonical source of
# ordinary/shared membership for this invocation; the execution-state file is
# deliberately not involved in this derivation.
: "${PROJECT:?}" "${GROUP:?}" "${ISSUE_IID:?}" "${EXECUTION_ID:?}"
: "${ISSUE_MODE:?run_executor_attempt.sh: ISSUE_MODE must be set}"
: "${BRANCH:?run_executor_attempt.sh: BRANCH must be set}"

if ! [[ "${ISSUE_IID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "run_executor_attempt.sh: ISSUE_IID must be a positive integer without leading zeros" >&2
  exit 2
fi

AUTO_MERGE="${AUTO_MERGE:-false}"
MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH:-${BRANCH}}"
DEPENDENCY_CONTRACT_VERSION="${DEPENDENCY_CONTRACT_VERSION:-}"
DEPENDENCY_PLAN_SHA256="${DEPENDENCY_PLAN_SHA256:-}"
DEPENDENCY_IID="${DEPENDENCY_IID:-}"
DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH:-}"
DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA:-}"
EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA:-}"
EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA:-}"
WORK_BRANCH="${WORK_BRANCH:-issue/${ISSUE_IID}}"
BRANCH_MEMBERS_JSON=""
SHARED_BRANCH_ROLE=""

case "${DEPENDENCY_CONTRACT_VERSION}" in
  '')
    if [ -n "${DEPENDENCY_PLAN_SHA256}" ]; then
      echo "run_executor_attempt.sh: DEPENDENCY_PLAN_SHA256 requires DEPENDENCY_CONTRACT_VERSION=2" >&2
      exit 2
    fi
    if [ "${WORK_BRANCH}" = "issue/${ISSUE_IID}" ]; then
      BRANCH_MEMBERS_JSON="[${ISSUE_IID}]"
    elif [[ "${WORK_BRANCH}" =~ ^issue/([1-9][0-9]*)\+([1-9][0-9]*)$ ]]; then
      SHARED_HEAD_IID="${BASH_REMATCH[1]}"
      SHARED_TAIL_IID="${BASH_REMATCH[2]}"
      if [ "${SHARED_HEAD_IID}" = "${SHARED_TAIL_IID}" ]; then
        echo "run_executor_attempt.sh: shared WORK_BRANCH members must be distinct" >&2
        exit 2
      elif [ "${ISSUE_IID}" = "${SHARED_HEAD_IID}" ]; then
        SHARED_BRANCH_ROLE=head
      elif [ "${ISSUE_IID}" = "${SHARED_TAIL_IID}" ]; then
        SHARED_BRANCH_ROLE=tail
      else
        echo "run_executor_attempt.sh: current ISSUE_IID must belong to shared WORK_BRANCH" >&2
        exit 2
      fi
      BRANCH_MEMBERS_JSON="[${SHARED_HEAD_IID},${SHARED_TAIL_IID}]"
    else
      echo "run_executor_attempt.sh: WORK_BRANCH must be issue/<current IID> or a two-member issue/<head IID>+<tail IID> branch containing the current IID" >&2
      exit 2
    fi
    ;;
  2)
    if ! command -v sha256sum >/dev/null 2>&1 \
        && ! command -v shasum >/dev/null 2>&1; then
      echo "run_executor_attempt.sh: DAG v2 requires sha256sum or shasum" >&2
      exit 2
    fi
    if ! [[ "${DEPENDENCY_PLAN_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "run_executor_attempt.sh: DAG v2 DEPENDENCY_PLAN_SHA256 must be a lowercase SHA-256 digest" >&2
      exit 2
    fi
    DAG_WORK_BRANCH="issue/${ISSUE_IID}-dag-${DEPENDENCY_PLAN_SHA256:0:16}"
    if [ "${WORK_BRANCH}" != "${DAG_WORK_BRANCH}" ]; then
      echo "run_executor_attempt.sh: DAG v2 WORK_BRANCH must match ISSUE_IID and DEPENDENCY_PLAN_SHA256" >&2
      exit 2
    fi
    if [ -z "${DEPENDENCY_BASE_SHA}" ] \
        || ! [[ "${DEPENDENCY_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
      echo "run_executor_attempt.sh: DAG v2 requires a full DEPENDENCY_BASE_SHA" >&2
      exit 2
    fi
    if [ -z "${EXPECTED_COMMIT_PARENT_SHA}" ] \
        || ! [[ "${EXPECTED_COMMIT_PARENT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
        || [ "${DEPENDENCY_BASE_SHA,,}" != "${EXPECTED_COMMIT_PARENT_SHA,,}" ]; then
      echo "run_executor_attempt.sh: DAG v2 requires DEPENDENCY_BASE_SHA as EXPECTED_COMMIT_PARENT_SHA" >&2
      exit 2
    fi
    if [ "${AUTO_MERGE}" != false ]; then
      echo "run_executor_attempt.sh: DAG v2 forbids automatic merge" >&2
      exit 2
    fi
    if [ "${ISSUE_MODE}" = continue ] \
        && [ -z "${EXPECTED_WORK_BRANCH_SHA}" ]; then
      echo "run_executor_attempt.sh: DAG v2 continue requires EXPECTED_WORK_BRANCH_SHA" >&2
      exit 2
    fi
    BRANCH_MEMBERS_JSON="[${ISSUE_IID}]"
    ;;
  *)
    echo "run_executor_attempt.sh: DEPENDENCY_CONTRACT_VERSION must be empty or 2" >&2
    exit 2
    ;;
esac

if [ -n "${EXPECTED_WORK_BRANCH_SHA}" ] \
    && ! [[ "${EXPECTED_WORK_BRANCH_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "run_executor_attempt.sh: EXPECTED_WORK_BRANCH_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
if [ -n "${EXPECTED_COMMIT_PARENT_SHA}" ] \
    && ! [[ "${EXPECTED_COMMIT_PARENT_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "run_executor_attempt.sh: EXPECTED_COMMIT_PARENT_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi
if [ -n "${DEPENDENCY_BASE_SHA}" ] \
    && ! [[ "${DEPENDENCY_BASE_SHA}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "run_executor_attempt.sh: DEPENDENCY_BASE_SHA must be a full hexadecimal Git object ID" >&2
  exit 2
fi

case "${ISSUE_MODE}" in
  fresh|continue) ;;
  *)
    echo "run_executor_attempt.sh: ISSUE_MODE must be fresh or continue" >&2
    exit 2
    ;;
esac

# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "run_executor_attempt.sh: jq is required" >&2
  exit 2
fi

execution_state_file_mode() {
  local path="$1" mode
  if mode="$(stat -c '%a' "${path}" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  elif mode="$(stat -f '%Lp' "${path}" 2>/dev/null)" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "${mode}"
  else
    return 1
  fi
}

execution_state_file_owner() {
  local path="$1" owner
  if owner="$(stat -c '%u' "${path}" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  elif owner="$(stat -f '%u' "${path}" 2>/dev/null)" \
      && [[ "${owner}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${owner}"
  else
    return 1
  fi
}

create_private_temp_file() {
  local target="$1" tmp mode owner
  tmp="$(umask 077; mktemp "${target}.tmp.XXXXXX")" || return 1
  [ -f "${tmp}" ] && [ ! -L "${tmp}" ] || return 1
  chmod 600 "${tmp}" || return 1
  mode="$(execution_state_file_mode "${tmp}")" || return 1
  owner="$(execution_state_file_owner "${tmp}")" || return 1
  [ "${mode}" = 600 ] && [ "${owner}" = "$(id -u)" ] || return 1
  printf '%s\n' "${tmp}"
}

# Execution state is optional title context only. It never supplies business
# identity and does not authorize or reject any caller-provided input.
EXECUTION_STATE_ISSUE_TITLE=""
if [ -f "${EXECUTION_STATE_FILE}" ] && [ ! -L "${EXECUTION_STATE_FILE}" ]; then
  EXECUTION_STATE_ISSUE_TITLE="$(jq -er '
    if type == "object"
      and (.issue_title | type) == "string"
      and .issue_title != ""
    then .issue_title else empty end
  ' "${EXECUTION_STATE_FILE}" 2>/dev/null || true)"
fi
ISSUE_TITLE="${ISSUE_TITLE:-${EXECUTION_STATE_ISSUE_TITLE:-Issue #${ISSUE_IID}}}"

ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_SECONDS:-3600}"
case "${ACPX_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*)
    echo "run_executor_attempt.sh: ACPX_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "${ACPX_TIMEOUT_SECONDS}" -lt 60 ]; then
  echo "run_executor_attempt.sh: ACPX_TIMEOUT_SECONDS must be >= 60" >&2
  exit 2
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "run_executor_attempt.sh: GNU coreutils 'timeout' is required" >&2
  exit 2
fi
mkdir -p "${LOG_DIR}"

FINAL_STATUS=""
BLOCK_REASON=""
COMMIT_SHA=""
MERGE_REQUEST_URL=""
MERGE_REQUEST_IID=""
MR_ACTION="none"
SHARED_MR_INTENT_ID=""
SUMMARY_POSTED=false
LABELS_ADDED='[]'
LABELS_REMOVED='[]'
LAST_LABEL_PRESERVED=false
STEP_STDOUT=""
STEP_STDERR=""
STEP_RC=0

append_reason() {
  local detail="$1"
  [ -n "${detail}" ] || return 0
  if [ -z "${BLOCK_REASON}" ]; then
    BLOCK_REASON="${detail}"
  else
    BLOCK_REASON="${BLOCK_REASON}; ${detail}"
  fi
}

append_json_string() {
  local current="$1" value="$2"
  jq -c --arg value "${value}" '
    if index($value) == null then . + [$value] else . end
  ' <<<"${current}"
}

remove_json_string() {
  local current="$1" value="$2"
  jq -c --arg value "${value}" 'map(select(. != $value))' <<<"${current}"
}

last_error_line() {
  local text="$1" fallback="$2" line
  line="$(printf '%s\n' "${text}" | awk 'NF { last=$0 } END { print last }')"
  [ -n "${line}" ] || line="${fallback}"
  printf '%s' "${line}"
}

# Promote dependency history only after the frozen WORK_BRANCH is observably
# the exact pushed commit. Preparation and local checkout are proposals: they
# never replace the tuple bound to the last remotely recoverable branch.
persist_pushed_branch_identity() {
  local branch_tip_sha="${1:-${COMMIT_SHA}}"
  local preserve_commit_sha="${2:-false}"
  local canonical_commit remote_commit prior_state state_tmp now
  local prior_commit_sha
  local dependency_plan_json dependency_plan_canonical dependency_plan_hash
  case "${preserve_commit_sha}" in
    true|false) ;;
    *) return 1 ;;
  esac
  canonical_commit="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" rev-parse --verify \
    "${branch_tip_sha}^{commit}" 2>/dev/null)" || return 1
  remote_commit="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" rev-parse --verify \
    "refs/remotes/origin/${WORK_BRANCH}^{commit}" 2>/dev/null)" || return 1
  if [ "${canonical_commit,,}" != "${remote_commit,,}" ]; then
    return 1
  fi
  if [ -n "${DEPENDENCY_BASE_SHA}" ] \
      && ! GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
        merge-base --is-ancestor \
        "${DEPENDENCY_BASE_SHA}" "${remote_commit}" >/dev/null 2>&1; then
    return 1
  fi
  if [ -L "${ISSUE_STATE_FILE}" ]; then
    return 1
  fi
  prior_state='{}'
  if [ -f "${ISSUE_STATE_FILE}" ]; then
    prior_state="$(jq -ce \
      'if type == "object" then . else error("invalid issue state") end' \
      "${ISSUE_STATE_FILE}" 2>/dev/null)" || return 1
  fi
  if [ "${preserve_commit_sha}" = true ]; then
    prior_commit_sha="$(printf '%s' "${prior_state}" | jq -er '
      .commit_sha
      | select(type == "string"
          and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
      | ascii_downcase
    ' 2>/dev/null)" || return 1
    GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" merge-base \
      --is-ancestor "${prior_commit_sha}" "${remote_commit}" \
      >/dev/null 2>&1 || return 1
  fi
  dependency_plan_json='null'
  if [ "${DEPENDENCY_CONTRACT_VERSION}" = 2 ]; then
    dependency_plan_json="$(printf '%s' "${prior_state}" | jq -ce \
      --argjson iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
      --arg expected_work_branch_sha "${EXPECTED_WORK_BRANCH_SHA}" \
      --arg expected_commit_parent_sha "${EXPECTED_COMMIT_PARENT_SHA}" \
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
      --arg dependency_plan_sha256 "${DEPENDENCY_PLAN_SHA256}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      def positive_integer:
        type == "number" and . == floor and . > 0;
      def full_sha:
        type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$");
      def plan_sha:
        type == "string"
        and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
      def label_branch_input:
        . as $input
        | type == "object"
        and ((keys | sort) == ([
          "commit_sha", "identity_source", "iid", "verified",
          "work_branch", "work_branch_sha"
        ] | sort))
        and $input.identity_source == "gitlab_pr_label_branch"
        and ($input.iid | positive_integer and . <= 2147483647)
        and $input.work_branch == ("issue/" + ($input.iid | tostring))
        and ($input.commit_sha | plan_sha)
        and ($input.work_branch_sha | plan_sha)
        and $input.commit_sha == $input.work_branch_sha
        and $input.verified == true;
      def executor_input($target_branch):
        . as $input
        | type == "object"
        and ((keys | sort) == ([
          "commit_sha", "execution_id", "iid", "mr", "verified",
          "work_branch", "work_branch_sha"
        ] | sort))
        and ($input.iid | positive_integer and . <= 2147483647)
        and ($input.execution_id
          | positive_integer and . <= 281474976710655)
        and (
          $input.work_branch == ("issue/" + ($input.iid | tostring))
          or ($input.work_branch | test(
            "^issue/" + ($input.iid | tostring)
            + "-dag-[0-9a-f]{16}$"))
        )
        and ($input.commit_sha | plan_sha)
        and ($input.work_branch_sha | plan_sha)
        and $input.verified == true
        and ($input.mr | type == "object")
        and (($input.mr | keys | sort) == ([
          "iid", "sha", "source_branch", "state", "target_branch", "url"
        ] | sort))
        and ($input.mr.iid | positive_integer and . <= 2147483647)
        and ($input.mr.url | type == "string"
          and test("^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
        and ($input.mr.url | test(
          "/-/merge_requests/" + ($input.mr.iid | tostring) + "/?$"))
        and ($input.mr.state == "opened" or $input.mr.state == "merged")
        and $input.mr.source_branch == $input.work_branch
        and $input.mr.target_branch == $target_branch
        and ($input.mr.sha | plan_sha)
        and (
          if $input.mr.state == "opened" then
            $input.mr.sha == $input.work_branch_sha
          else
            $input.mr.sha == $input.commit_sha
            or $input.mr.sha == $input.work_branch_sha
          end
        );
      def valid_input($target_branch):
        label_branch_input or executor_input($target_branch);
      (if type == "object"
          and .preparing_execution_id == $execution_id
          and .proposed_dependency_contract_version == 2
          and .proposed_dependency_plan_sha256 == $dependency_plan_sha256
          and .proposed_work_branch == $work_branch
          and .proposed_branch_members == $branch_members
          and .proposed_shared_branch_role == null
          and (if $expected_work_branch_sha == "" then
            .proposed_expected_work_branch_sha == null
          else
            (.proposed_expected_work_branch_sha | full_sha)
            and ((.proposed_expected_work_branch_sha | ascii_downcase)
              == ($expected_work_branch_sha | ascii_downcase))
          end)
          and (.proposed_expected_commit_parent_sha | full_sha)
          and ((.proposed_expected_commit_parent_sha | ascii_downcase)
            == ($expected_commit_parent_sha | ascii_downcase))
          and (.proposed_dependency_base_sha | full_sha)
          and ((.proposed_dependency_base_sha | ascii_downcase)
            == ($dependency_base_sha | ascii_downcase))
        then .proposed_dependency_plan
        elif type == "object"
          and .dependency_pinned_execution_id == $execution_id
          and .dependency_contract_version == 2
          and .dependency_plan_sha256 == $dependency_plan_sha256
          and .work_branch == $work_branch
          and .branch_members == $branch_members
          and .shared_branch_role == null
          and (.dependency_base_sha | full_sha)
          and ((.dependency_base_sha | ascii_downcase)
            == ($dependency_base_sha | ascii_downcase))
        then .dependency_plan
        else null
        end) as $plan
      | ($plan.effective_inputs
        | if type == "array" then map(.iid) else [] end) as $effective_iids
      | if ($plan | type == "object")
        and (($plan | keys | sort) == ([
          "aggregate_base_sha", "consumer_iid", "declared_inputs",
          "effective_inputs", "plan_sha256", "target_branch", "version",
          "work_branch"
        ] | sort))
        and $plan.version == 2
        and $plan.consumer_iid == $iid
        and $plan.target_branch == $target_branch
        and $plan.work_branch == $work_branch
        and $plan.plan_sha256 == $dependency_plan_sha256
        and ($plan.aggregate_base_sha | plan_sha)
        and (($plan.aggregate_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
        and ($plan.declared_inputs | type == "array"
          and length >= 1 and length <= 8)
        and ([$plan.declared_inputs[].iid]
          | length == (unique | length))
        and ($plan.effective_inputs | type == "array"
          and length >= 1 and length <= 8)
        and ([$plan.effective_inputs[].iid]
          | length == (unique | length))
        and all($plan.declared_inputs[];
          valid_input($target_branch))
        and all($plan.effective_inputs[];
          valid_input($target_branch))
        and all($plan.effective_inputs[];
          . as $effective
          | any($plan.declared_inputs[]; . == $effective))
        and ([
          $plan.declared_inputs[].iid
          | . as $declared_iid
          | select($effective_iids | index($declared_iid) != null)
        ] == $effective_iids)
      then $plan
      else error("invalid DAG dependency plan identity")
      end
    ' 2>/dev/null)" || return 1
    dependency_plan_canonical="$(printf '%s' "${dependency_plan_json}" | jq -cS '{
      version:2,
      algorithm:"ordered-frontier-merge-v1",
      consumer_iid:.consumer_iid,
      target_branch:.target_branch,
      declared_inputs:.declared_inputs,
      effective_inputs:.effective_inputs,
      aggregate_base_sha:.aggregate_base_sha
    }' 2>/dev/null)" || return 1
    dependency_plan_hash="$(sha256_text "${dependency_plan_canonical}")" \
      || return 1
    if [ "${dependency_plan_hash}" != "${DEPENDENCY_PLAN_SHA256}" ]; then
      return 1
    fi
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_tmp="$(create_private_temp_file "${ISSUE_STATE_FILE}")" || return 1
  if ! (umask 077; printf '%s' "${prior_state}" | jq \
      --argjson iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
      --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
      --arg dependency_iid "${DEPENDENCY_IID}" \
      --arg dependency_branch "${DEPENDENCY_BRANCH}" \
      --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
      --arg dependency_contract_version "${DEPENDENCY_CONTRACT_VERSION}" \
      --arg dependency_plan_sha256 "${DEPENDENCY_PLAN_SHA256}" \
      --argjson dependency_plan "${dependency_plan_json}" \
      --arg work_branch_sha "${remote_commit}" \
      --argjson preserve_commit_sha "${preserve_commit_sha}" \
      --arg updated_at "${now}" '
      . + {
        iid:$iid,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:(if $shared_branch_role == "" then null else $shared_branch_role end),
        dependency_iid:(if $dependency_iid == "" then null else ($dependency_iid | tonumber) end),
        dependency_branch:(if $dependency_branch == "" then null else $dependency_branch end),
        dependency_base_sha:(if $dependency_base_sha == "" then null else $dependency_base_sha end),
        dependency_pinned_execution_id:$execution_id,
        commit_sha:(
          if $preserve_commit_sha then .commit_sha
          else $work_branch_sha
          end
        ),
        work_branch_sha:$work_branch_sha,
        dependency_history_verified:true,
        dependency_history_updated_at:$updated_at
      }
      | if $dependency_contract_version == "" then
          del(.dependency_contract_version,
              .dependency_plan_sha256,
              .dependency_plan)
        else
          .dependency_contract_version = ($dependency_contract_version | tonumber)
          | .dependency_plan_sha256 = $dependency_plan_sha256
          | .dependency_plan = $dependency_plan
        end
      | del(.proposed_config_branch,
            .proposed_work_branch,
            .proposed_branch_members,
            .proposed_shared_branch_role,
            .proposed_expected_work_branch_sha,
            .proposed_expected_commit_parent_sha,
            .proposed_dependency_iid,
            .proposed_dependency_branch,
            .proposed_dependency_base_sha,
            .proposed_dependency_contract_version,
            .proposed_dependency_plan_sha256,
            .proposed_dependency_plan,
            .preparing_execution_id)
    ' >"${state_tmp}"); then
    return 1
  fi
  chmod 600 "${state_tmp}" || return 1
  mv "${state_tmp}" "${ISSUE_STATE_FILE}"
}

# A shared branch has one cross-Issue MR identity. After the main execution
# path has pushed and verified the exact remote commit, invalidate any stale
# finalization and bind the MR work that is about to start to this fixed
# execution. Partial-work salvage never calls this function: it may preserve a
# pushed commit, but it is not authorized to start or checkpoint MR creation.
persist_shared_mr_pending_checkpoint() {
  [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] || return 0

  local prior_state state_tmp intent_id="" head_state_file="" state_bytes
  if [ ! -f "${ISSUE_STATE_FILE}" ] || [ -L "${ISSUE_STATE_FILE}" ] \
      || [ "$(execution_state_file_mode "${ISSUE_STATE_FILE}" 2>/dev/null || true)" != 600 ] \
      || [ "$(execution_state_file_owner "${ISSUE_STATE_FILE}" 2>/dev/null || true)" != "$(id -u)" ]; then
    return 1
  fi
  state_bytes="$(wc -c <"${ISSUE_STATE_FILE}" 2>/dev/null \
    | tr -d '[:space:]')"
  [[ "${state_bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${state_bytes}" -le 65536 ] || return 1
  prior_state="$(jq -ce \
    --argjson iid "${ISSUE_IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg work_branch "${WORK_BRANCH}" \
    --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
    --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
    --arg commit_sha "${COMMIT_SHA}" '
      if type == "object"
        and .iid == $iid
        and .work_branch == $work_branch
        and .branch_members == $branch_members
        and .shared_branch_role == $shared_branch_role
        and .dependency_pinned_execution_id == $execution_id
        and .dependency_history_verified == true
        and ((.work_branch_sha | ascii_downcase)
          == ($commit_sha | ascii_downcase))
      then . else error("pushed shared identity mismatch") end
    ' "${ISSUE_STATE_FILE}" 2>/dev/null)" || return 1

  # Reuse an exact same-execution intent after a process restart. Otherwise A
  # creates a fresh high-entropy ownership marker; C inherits A's verified
  # marker so both commits bind the same one MR.
  intent_id="$(jq -r \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg work_branch "${WORK_BRANCH}" \
    --arg commit_sha "${COMMIT_SHA}" '
    .mr_finalization // null
    | select(type == "object"
      and .status == "pending"
      and .source_execution_id == $execution_id
      and .work_branch == $work_branch
      and ((.commit_sha | ascii_downcase) == ($commit_sha | ascii_downcase))
      and (.intent_id | type == "string" and test("^[0-9a-f]{64}$")))
    | .intent_id
  ' <<<"${prior_state}" 2>/dev/null || true)"
  if [ -z "${intent_id}" ] && [ "${SHARED_BRANCH_ROLE}" = tail ]; then
    head_state_file="${ISSUES_ROOT}/issue-${DEPENDENCY_IID}/state.json"
    if [ ! -f "${head_state_file}" ] || [ -L "${head_state_file}" ] \
        || [ "$(execution_state_file_mode "${head_state_file}" 2>/dev/null || true)" != 600 ] \
        || [ "$(execution_state_file_owner "${head_state_file}" 2>/dev/null || true)" != "$(id -u)" ]; then
      return 1
    fi
    state_bytes="$(wc -c <"${head_state_file}" 2>/dev/null \
      | tr -d '[:space:]')"
    [[ "${state_bytes}" =~ ^[1-9][0-9]*$ ]] \
      && [ "${state_bytes}" -le 65536 ] || return 1
    intent_id="$(jq -er \
      --argjson head_iid "${DEPENDENCY_IID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --arg dependency_sha "${DEPENDENCY_BASE_SHA}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      if .iid == $head_iid
        and .status == "done"
        and .work_branch == $work_branch
        and .shared_branch_role == "head"
        and ((.commit_sha | ascii_downcase) == ($dependency_sha | ascii_downcase))
        and (.mr_finalization | type == "object")
        and .mr_finalization.status == "verified_open"
        and .mr_finalization.work_branch == $work_branch
        and .mr_finalization.shared_branch_role == "head"
        and ((.mr_finalization.commit_sha | ascii_downcase)
          == ($dependency_sha | ascii_downcase))
        and .mr_finalization.target_branch == $target_branch
        and (.mr_finalization.intent_id | type == "string"
          and test("^[0-9a-f]{64}$"))
      then .mr_finalization.intent_id else empty end
    ' "${head_state_file}" 2>/dev/null)" || return 1
  elif [ -z "${intent_id}" ]; then
    command -v od >/dev/null 2>&1 || return 1
    intent_id="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null \
      | tr -d '[:space:]')" || return 1
  fi
  [[ "${intent_id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  SHARED_MR_INTENT_ID="${intent_id}"

  state_tmp="$(create_private_temp_file "${ISSUE_STATE_FILE}")" || return 1
  if ! (umask 077; printf '%s' "${prior_state}" | jq \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
      --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
      --arg commit_sha "${COMMIT_SHA}" \
      --arg intent_id "${intent_id}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      .mr_finalization = {
        status:"pending",
        source_execution_id:$execution_id,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:$shared_branch_role,
        commit_sha:$commit_sha,
        intent_id:$intent_id,
        target_branch:$target_branch
      }
    ' >"${state_tmp}"); then
    return 1
  fi
  chmod 600 "${state_tmp}" || return 1
  mv "${state_tmp}" "${ISSUE_STATE_FILE}"
}

# A terminal log commit advances a shared source branch after the business
# commit and MR marker were created. Move the already-owned pending checkpoint
# to that exact child without minting a new intent.
advance_shared_mr_checkpoint() {
  local old_commit_sha="$1" new_commit_sha="$2"
  [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] || return 0

  local prior_state state_tmp
  [ -f "${ISSUE_STATE_FILE}" ] && [ ! -L "${ISSUE_STATE_FILE}" ] \
    && [ "$(execution_state_file_mode "${ISSUE_STATE_FILE}" 2>/dev/null || true)" = 600 ] \
    && [ "$(execution_state_file_owner "${ISSUE_STATE_FILE}" 2>/dev/null || true)" = "$(id -u)" ] \
    || return 1
  prior_state="$(jq -ce 'if type == "object" then . else error("invalid state") end' \
    "${ISSUE_STATE_FILE}" 2>/dev/null)" || return 1
  if ! printf '%s' "${prior_state}" | jq -e \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --argjson branch_members "${BRANCH_MEMBERS_JSON}" \
      --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
      --arg old_commit_sha "${old_commit_sha}" \
      --arg new_commit_sha "${new_commit_sha}" \
      --arg intent_id "${SHARED_MR_INTENT_ID}" \
      --arg target_branch "${MERGE_TARGET_BRANCH}" '
      .work_branch == $work_branch
      and .branch_members == $branch_members
      and .shared_branch_role == $shared_branch_role
      and ((.work_branch_sha | ascii_downcase)
        == ($new_commit_sha | ascii_downcase))
      and .mr_finalization == {
        status:"pending",
        source_execution_id:$execution_id,
        work_branch:$work_branch,
        branch_members:$branch_members,
        shared_branch_role:$shared_branch_role,
        commit_sha:$old_commit_sha,
        intent_id:$intent_id,
        target_branch:$target_branch
      }
    ' >/dev/null 2>&1; then
    return 1
  fi
  state_tmp="$(create_private_temp_file "${ISSUE_STATE_FILE}")" || return 1
  if ! (umask 077; printf '%s' "${prior_state}" | jq \
      --arg new_commit_sha "${new_commit_sha}" '
      .mr_finalization.commit_sha = $new_commit_sha
    ' >"${state_tmp}"); then
    return 1
  fi
  chmod 600 "${state_tmp}" || return 1
  mv "${state_tmp}" "${ISSUE_STATE_FILE}"
}

# Keep the private MR marker aligned with a same-branch terminal log commit.
# Missing markers are valid on pre-MR failure paths; an existing mismatched
# marker is not.
advance_mr_result_marker() {
  local old_commit_sha="$1" new_commit_sha="$2"
  local marker_file="${LOG_DIR}/mr_result.json" marker_tmp marker_bytes
  [ -e "${marker_file}" ] || return 0
  [ -f "${marker_file}" ] && [ ! -L "${marker_file}" ] \
    && [ "$(execution_state_file_mode "${marker_file}" 2>/dev/null || true)" = 600 ] \
    && [ "$(execution_state_file_owner "${marker_file}" 2>/dev/null || true)" = "$(id -u)" ] \
    || return 1
  marker_bytes="$(wc -c <"${marker_file}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${marker_bytes}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${marker_bytes}" -le 65536 ] || return 1
  if ! jq -e \
      --argjson issue_iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg source_branch "${WORK_BRANCH}" \
      --arg old_commit_sha "${old_commit_sha}" '
      type == "object"
      and .issue_iid == $issue_iid
      and .execution_id == $execution_id
      and .source_branch == $source_branch
      and ((.sha | ascii_downcase) == ($old_commit_sha | ascii_downcase))
    ' "${marker_file}" >/dev/null 2>&1; then
    return 1
  fi
  marker_tmp="$(create_private_temp_file "${marker_file}")" || return 1
  if ! (umask 077; jq --arg new_commit_sha "${new_commit_sha}" \
      '.sha = $new_commit_sha' "${marker_file}" >"${marker_tmp}"); then
    return 1
  fi
  chmod 600 "${marker_tmp}" || return 1
  mv "${marker_tmp}" "${marker_file}"
}

# Capture every fixed step in the issue-local log. Each post-acpx operation
# has its own hard cap so a wedged Git/glab call cannot indefinitely retain the
# native subagent slot. The heartbeat has a larger whole-finalization watchdog
# as a second line of defense.
run_bounded_step() {
  local name="$1" seconds="$2"
  shift 2
  local stdout_file="${LOG_DIR}/outer-${name}.stdout.log"
  local stderr_file="${LOG_DIR}/outer-${name}.stderr.log"
  set +e
  timeout --kill-after=30s "${seconds}s" "$@" \
    >"${stdout_file}" 2>"${stderr_file}"
  STEP_RC=$?
  set -e
  STEP_STDOUT="$(cat "${stdout_file}" 2>/dev/null || true)"
  STEP_STDERR="$(cat "${stderr_file}" 2>/dev/null || true)"
}

sync_label() {
  local op="$1" label="$2"
  LAST_LABEL_PRESERVED=false
  run_bounded_step "label-${op}-${label}" 120 \
    bash "${SCRIPT_DIR}/set_issue_label.sh" "${op}" "${label}"
  if [ "${STEP_RC}" -ne 0 ]; then
    return "${STEP_RC}"
  fi
  if printf '%s\n' "${STEP_STDOUT}" | grep -Eq '^preserve:(closed|finish|pr)$'; then
    LAST_LABEL_PRESERVED=true
    return 0
  fi
  if [ "${op}" = add ]; then
    LABELS_ADDED="$(append_json_string "${LABELS_ADDED}" "${label}")"
  else
    LABELS_REMOVED="$(append_json_string "${LABELS_REMOVED}" "${label}")"
  fi
}

sync_failure_labels() {
  local terminal_label="$1" error_text=""
  # Adding a workflow terminal label removes `doing` and every conflicting
  # workflow label in the same GitLab update. Keep the failure transition
  # atomic so an interrupted two-call sequence cannot leave `doing` behind.
  if ! sync_label add "${terminal_label}"; then
    error_text="$(last_error_line "${STEP_STDERR}" "add ${terminal_label} failed rc=${STEP_RC}")"
  elif [ "${LAST_LABEL_PRESERVED}" != true ]; then
    LABELS_REMOVED="$(append_json_string "${LABELS_REMOVED}" doing)"
  fi
  [ -z "${error_text}" ] || append_reason "${terminal_label} label sync failed: ${error_text}"
}

run_summary() {
  run_bounded_step summarize 180 env \
    ATTEMPT_STATUS="${FINAL_STATUS}" \
    SUMMARY_POST_TO_ISSUE=false \
    COMMIT_SHA="${COMMIT_SHA}" \
    MERGE_REQUEST_URL="${MERGE_REQUEST_URL}" \
    BLOCK_REASON="${BLOCK_REASON}" \
    ISSUE_MODE="${ISSUE_MODE}" \
    bash "${SCRIPT_DIR}/summarize_attempt.sh"
  if [ "${STEP_RC}" -eq 0 ] \
      && grep -Fq 'SUMMARY_POSTED=true' "${LOG_DIR}/outer-summarize.stderr.log"; then
    SUMMARY_POSTED=true
  else
    SUMMARY_POSTED=false
  fi
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "summary step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  fi
}

build_worker_result() {
  jq -cn \
    --argjson iid "${ISSUE_IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg status "${FINAL_STATUS}" \
    --arg mode_actual "${ISSUE_MODE}" \
    --arg work_branch "${WORK_BRANCH}" \
    --arg local_branch "${LOCAL_ISSUE_BRANCH}" \
    --arg commit_sha "${COMMIT_SHA}" \
    --arg merge_request_url "${MERGE_REQUEST_URL}" \
    --arg mr_action "${MR_ACTION}" \
    --argjson labels_added "${LABELS_ADDED}" \
    --argjson labels_removed "${LABELS_REMOVED}" \
    --argjson summary_posted "${SUMMARY_POSTED}" \
    --arg block_reason "${BLOCK_REASON}" \
    --arg log_dir "${LOG_DIR}" '{
      iid:$iid,
      execution_id:$execution_id,
      status:$status,
      mode_actual:$mode_actual,
      work_branch:$work_branch,
      local_branch:$local_branch,
      commit_sha:$commit_sha,
      merge_request_url:$merge_request_url,
      mr_action:$mr_action,
      wiki_url:"",
      labels_added:$labels_added,
      labels_removed:$labels_removed,
      summary_posted:$summary_posted,
      block_reason:$block_reason,
      log_dir:$log_dir
    }'
}

write_worker_result() {
  local result="$1"
  local result_file="${LOG_DIR}/worker_result.json"
  local result_tmp
  result_tmp="$(create_private_temp_file "${result_file}")" || {
    echo "run_executor_attempt.sh: failed to allocate private result file" >&2
    exit 3
  }
  if ! (
    printf '%s\n' "${result}" >"${result_tmp}"
    chmod 600 "${result_tmp}"
    mv "${result_tmp}" "${result_file}"
  ); then
    echo "run_executor_attempt.sh: failed to persist ${result_file}" >&2
    exit 3
  fi
}

write_attempt_finalized_marker() {
  local result_file="${LOG_DIR}/worker_result.json"
  local marker_file="${LOG_DIR}/attempt_finalized.json"
  local marker_tmp
  local result_sha256 completed_at_epoch
  [ -f "${result_file}" ] && [ ! -L "${result_file}" ] || {
    echo "run_executor_attempt.sh: worker result is unavailable for finalization" >&2
    exit 3
  }
  result_sha256="$(sha256_file "${result_file}")" || {
    echo "run_executor_attempt.sh: failed to hash ${result_file}" >&2
    exit 3
  }
  completed_at_epoch="$(date +%s)"
  marker_tmp="$(create_private_temp_file "${marker_file}")" || {
    echo "run_executor_attempt.sh: failed to allocate private finalization marker" >&2
    exit 3
  }
  if ! (
    jq -cn \
      --argjson iid "${ISSUE_IID}" \
      --argjson execution_id "${EXECUTION_ID}" \
      --arg work_branch "${WORK_BRANCH}" \
      --arg commit_sha "${COMMIT_SHA}" \
      --arg worker_result_sha256 "${result_sha256}" \
      --argjson completed_at_epoch "${completed_at_epoch}" '{
        version:1,
        iid:$iid,
        execution_id:$execution_id,
        work_branch:$work_branch,
        commit_sha:$commit_sha,
        worker_result_sha256:$worker_result_sha256,
        completed_at_epoch:$completed_at_epoch
      }' >"${marker_tmp}"
    chmod 600 "${marker_tmp}"
    mv "${marker_tmp}" "${marker_file}"
  ); then
    echo "run_executor_attempt.sh: failed to persist ${marker_file}" >&2
    exit 3
  fi
}

persist_and_print_result() {
  local result archive_output log_parent_commit log_commit_sha prior_commit_sha
  local archive_logs=true promote_log_commit=true preserve_business_commit=false
  result="$(build_worker_result)"
  write_worker_result "${result}"

  # A shared branch may advance only after its exact pending MR checkpoint was
  # installed. Before that point, a log-only commit would change the frozen
  # topology without a recoverable owner.
  if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] \
      && { [ -z "${COMMIT_SHA}" ] || [ -z "${SHARED_MR_INTENT_ID}" ]; }; then
    archive_logs=false
  fi
  if [ "${DEPENDENCY_CONTRACT_VERSION}" = 2 ] \
      && [ -z "${COMMIT_SHA}" ]; then
    archive_logs=false
  fi

  # A single-Issue branch has two distinct terminal identities: COMMIT_SHA is
  # the reviewed business artifact and the remote work-branch tip may advance
  # once to a direct log-only child. Dependency plans always freeze the former
  # while validating and binding the latter separately.
  if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 1 ] \
      && [ -n "${COMMIT_SHA}" ]; then
    promote_log_commit=false
  fi

  # An unresolved automatic merge is still fenced to the pre-archive source
  # SHA. Moving that open/unknown MR would destroy the only safe recovery
  # identity. Verified merged MRs are immutable and can safely retain their
  # business SHA while the source branch advances to its terminal log child.
  if [ "${AUTO_MERGE}" = true ] && [ "${MR_ACTION}" != none ]; then
    if [ -f "${LOG_DIR}/mr_result.json" ] && jq -e '
        .verified == true and .outcome == "merged"
        and .observed_state == "merged"
      ' "${LOG_DIR}/mr_result.json" >/dev/null 2>&1; then
      promote_log_commit=false
    else
      archive_logs=false
      echo "run_executor_attempt.sh: terminal log append deferred because automatic MR identity is unresolved" >&2
    fi
  fi

  if [ "${archive_logs}" = true ]; then
    prior_commit_sha="${COMMIT_SHA}"
    if ! archive_output="$(COMMIT_SHA="${COMMIT_SHA}" \
        bash "${SCRIPT_DIR}/archive_execution_logs.sh")"; then
      echo "run_executor_attempt.sh: terminal logs could not be persisted to ${WORK_BRANCH}" >&2
      exit 4
    fi
    log_parent_commit="$(awk -F= '$1 == "LOG_PARENT_COMMIT" {print $2}' \
      <<<"${archive_output}")"
    log_commit_sha="$(awk -F= '$1 == "LOG_COMMIT_SHA" {print $2}' \
      <<<"${archive_output}")"
    if ! [[ "${log_parent_commit}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
        || ! [[ "${log_commit_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
        || { [ -n "${prior_commit_sha}" ] \
          && [ "${log_parent_commit,,}" != "${prior_commit_sha,,}" ]; }; then
      echo "run_executor_attempt.sh: terminal log persistence returned an invalid branch identity" >&2
      exit 4
    fi
    [ "${promote_log_commit}" = true ] || preserve_business_commit=true
    if ! persist_pushed_branch_identity \
        "${log_commit_sha}" "${preserve_business_commit}"; then
      echo "run_executor_attempt.sh: terminal log branch identity could not be persisted" >&2
      exit 4
    fi
    if [ "${promote_log_commit}" = true ] \
        && [ "${log_commit_sha,,}" != "${prior_commit_sha,,}" ]; then
      if ! advance_shared_mr_checkpoint "${prior_commit_sha}" "${log_commit_sha}"; then
        echo "run_executor_attempt.sh: shared MR checkpoint did not advance to the terminal log commit" >&2
        exit 4
      fi
      if [ -n "${prior_commit_sha}" ] \
          && ! advance_mr_result_marker "${prior_commit_sha}" "${log_commit_sha}"; then
        echo "run_executor_attempt.sh: MR marker did not advance to the terminal log commit" >&2
        exit 4
      fi
      COMMIT_SHA="${log_commit_sha}"
      result="$(build_worker_result)"
      write_worker_result "${result}"
    fi
    printf '%s\n' "${archive_output}" >&2
  fi

  # This marker is intentionally written last and is not part of the remote
  # log commit. The scheduler must not consume worker_result.json or reclaim
  # the child until this exact result hash proves all terminal persistence has
  # completed.
  write_attempt_finalized_marker
  printf '%s\n' "${result}"
}

finish_blocked() {
  FINAL_STATUS=blocked
  sync_failure_labels blocked-cc
  run_summary
  persist_and_print_result
  exit 0
}

finish_timeout() {
  FINAL_STATUS=timeout
  MR_ACTION=none
  MERGE_REQUEST_URL=""
  sync_failure_labels timeout
  run_summary
  persist_and_print_result
  exit 0
}

stage_partial_work() {
  run_bounded_step stage 180 bash "${SCRIPT_DIR}/stage_and_guard.sh"
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "stage step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
    return 1
  fi
  case "$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')" in
    STAGED_OK) return 0 ;;
    NO_CHANGES)
      append_reason "no staged changes to push"
      return 1
      ;;
    *)
      append_reason "stage step returned an invalid marker"
      return 1
      ;;
  esac
}

commit_partial_work() {
  run_bounded_step commit-and-push 300 env \
    ISSUE_TITLE="${ISSUE_TITLE}" \
    DEPENDENCY_CONTRACT_VERSION="${DEPENDENCY_CONTRACT_VERSION}" \
    DEPENDENCY_PLAN_SHA256="${DEPENDENCY_PLAN_SHA256}" \
    DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA}" \
    AUTO_MERGE="${AUTO_MERGE}" \
    EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA}" \
    EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA}" \
    bash "${SCRIPT_DIR}/commit_and_push.sh"
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "commit_and_push step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
    return 1
  fi
  COMMIT_SHA="$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')"
  if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    append_reason "commit_and_push step returned an invalid commit SHA"
    COMMIT_SHA=""
    return 1
  fi
}

verify_partial_work() {
  run_bounded_step post-push-verify 180 env \
    BRANCH="${BRANCH}" \
    bash "${SCRIPT_DIR}/post_push_verify.sh"
  if [ "${STEP_RC}" -ne 0 ]; then
    append_reason "post-push verify failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
    return 1
  fi
}

# The bounded commit helper can be killed after the server accepted its push
# but before it printed the SHA. For any fixed-parent branch (a legacy shared
# tail or DAG v2), recover only when the current local HEAD is a new one-parent
# commit on the frozen parent and a fresh fetch proves the exact
# remote-tracking ref equals that HEAD.
recover_ambiguous_fixed_parent_push() {
  if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
      && [ "${DEPENDENCY_CONTRACT_VERSION}" != 2 ]; then
    return 1
  fi
  local candidate_sha parents_line remote_sha
  local -a candidate_parents
  candidate_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  [[ "${candidate_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
    || return 1
  [ "${candidate_sha,,}" != "${EXPECTED_COMMIT_PARENT_SHA,,}" ] || return 1
  parents_line="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-list --parents -n 1 "${candidate_sha}" 2>/dev/null)" || return 1
  read -r -a candidate_parents <<<"${parents_line}"
  [ "${#candidate_parents[@]}" -eq 2 ] \
    && [ "${candidate_parents[0],,}" = "${candidate_sha,,}" ] \
    && [ "${candidate_parents[1],,}" = "${EXPECTED_COMMIT_PARENT_SHA,,}" ] \
    || return 1

  run_bounded_step post-push-ambiguity-verify 180 env \
    BRANCH="${MERGE_TARGET_BRANCH}" \
    bash "${SCRIPT_DIR}/post_push_verify.sh"
  [ "${STEP_RC}" -eq 0 ] || return 1
  remote_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${WORKTREE_DIR}" \
    rev-parse --verify "refs/remotes/origin/${WORK_BRANCH}^{commit}" \
    2>/dev/null)" || return 1
  [ "${remote_sha,,}" = "${candidate_sha,,}" ] || return 1
  COMMIT_SHA="${candidate_sha}"
}

if [ ! -d "${WORKTREE_DIR}" ] || [ ! -d "${OUTPUT_DIR}" ]; then
  BLOCK_REASON="worktree or output directory missing"
  finish_blocked
fi

# Keep acpx and every following deterministic step inside this same Bash tool
# call. The command writes acpx_terminal.json before returning, which lets the
# heartbeat distinguish a post-acpx stall from a still-running inner session.
run_bounded_step acpx "$((ACPX_TIMEOUT_SECONDS + 120))" env \
  ACPX_TIMEOUT_SECONDS="${ACPX_TIMEOUT_SECONDS}" \
  bash "${SCRIPT_DIR}/run_acpx_attempt.sh"
printf '%s\n' "${STEP_STDOUT}"

ACPX_EXIT="$(printf '%s\n' "${STEP_STDOUT}" \
  | awk -F= '/^ACPX_EXIT=[0-9]+$/ { value=$2 } END { print value }')"
if [ -z "${ACPX_EXIT}" ]; then
  BLOCK_REASON="acpx exec exceeded ${ACPX_TIMEOUT_SECONDS}s wall-clock cap"
  if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
      && stage_partial_work && commit_partial_work; then
    if verify_partial_work; then
      persist_pushed_branch_identity \
        || append_reason "pushed branch dependency identity could not be persisted"
    fi
  fi
  finish_timeout
fi

case "${ACPX_EXIT}" in
  0) ;;
  124|137)
    BLOCK_REASON="acpx exec exceeded ${ACPX_TIMEOUT_SECONDS}s wall-clock cap"
    if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
        && stage_partial_work && commit_partial_work; then
      if verify_partial_work; then
        persist_pushed_branch_identity \
          || append_reason "pushed branch dependency identity could not be persisted"
      fi
    fi
    finish_timeout
    ;;
  *)
    BLOCK_REASON="acpx run failed (exit ${ACPX_EXIT}); see ${LOG_DIR}/acpx_raw.log"
    if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
        && stage_partial_work && commit_partial_work; then
      if verify_partial_work; then
        persist_pushed_branch_identity \
          || append_reason "pushed branch dependency identity could not be persisted"
      fi
    fi
    finish_blocked
    ;;
esac

run_bounded_step stage 180 bash "${SCRIPT_DIR}/stage_and_guard.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  BLOCK_REASON="stage step failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi
case "$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')" in
  STAGED_OK) ;;
  NO_CHANGES)
    BLOCK_REASON="Claude produced no staged changes"
    finish_blocked
    ;;
  *)
    BLOCK_REASON="stage step returned an invalid marker"
    finish_blocked
    ;;
esac

run_bounded_step commit-and-push 300 env \
  ISSUE_TITLE="${ISSUE_TITLE}" \
  DEPENDENCY_CONTRACT_VERSION="${DEPENDENCY_CONTRACT_VERSION}" \
  DEPENDENCY_PLAN_SHA256="${DEPENDENCY_PLAN_SHA256}" \
  DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA}" \
  AUTO_MERGE="${AUTO_MERGE}" \
  EXPECTED_WORK_BRANCH_SHA="${EXPECTED_WORK_BRANCH_SHA}" \
  EXPECTED_COMMIT_PARENT_SHA="${EXPECTED_COMMIT_PARENT_SHA}" \
  bash "${SCRIPT_DIR}/commit_and_push.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  COMMIT_PUSH_FAILURE="$(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  if recover_ambiguous_fixed_parent_push; then
    append_reason "commit_and_push returned an ambiguous failure, but the exact fixed-parent remote tip confirms the local commit"
  else
    BLOCK_REASON="git push failed: ${COMMIT_PUSH_FAILURE}"
    finish_blocked
  fi
fi
if [ -z "${COMMIT_SHA}" ]; then
  COMMIT_SHA="$(printf '%s\n' "${STEP_STDOUT}" | awk 'NF { last=$0 } END { print last }')"
fi
if ! [[ "${COMMIT_SHA}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  BLOCK_REASON="git push failed: commit_and_push returned an invalid commit SHA"
  COMMIT_SHA=""
  finish_blocked
fi

run_bounded_step post-push-verify 180 env \
  BRANCH="${MERGE_TARGET_BRANCH}" \
  bash "${SCRIPT_DIR}/post_push_verify.sh"
if [ "${STEP_RC}" -ne 0 ]; then
  BLOCK_REASON="post-push verification failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi
if ! persist_pushed_branch_identity; then
  BLOCK_REASON="post-push dependency identity verification or persistence failed"
  finish_blocked
fi
if ! persist_shared_mr_pending_checkpoint; then
  BLOCK_REASON="shared MR pending checkpoint persistence failed"
  finish_blocked
fi

if ! sync_label remove doing; then
  BLOCK_REASON="label transition doing->done failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi
if ! sync_label add done; then
  BLOCK_REASON="label transition doing->done failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  finish_blocked
fi

MR_FINALIZATION_TRY=1
MR_FINALIZATION_MAX_TRIES=1
[ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -ne 2 ] \
  || MR_FINALIZATION_MAX_TRIES=3
while :; do
  MR_STEP_NAME=create-mr
  SHARED_MR_RECOVERY=false
  if [ "${MR_FINALIZATION_TRY}" -gt 1 ]; then
    MR_STEP_NAME="create-mr-retry${MR_FINALIZATION_TRY}"
    SHARED_MR_RECOVERY=true
  fi
  run_bounded_step "${MR_STEP_NAME}" 300 env \
    ISSUE_TITLE="${ISSUE_TITLE}" \
    ISSUE_MODE="${ISSUE_MODE}" \
    BRANCH="${BRANCH}" \
    MERGE_TARGET_BRANCH="${MERGE_TARGET_BRANCH}" \
    AUTO_MERGE="${AUTO_MERGE}" \
    DEPENDENCY_IID="${DEPENDENCY_IID}" \
    DEPENDENCY_BRANCH="${DEPENDENCY_BRANCH}" \
    DEPENDENCY_BASE_SHA="${DEPENDENCY_BASE_SHA}" \
    DEPENDENCY_CONTRACT_VERSION="${DEPENDENCY_CONTRACT_VERSION}" \
    DEPENDENCY_PLAN_SHA256="${DEPENDENCY_PLAN_SHA256}" \
    COMMIT_SHA="${COMMIT_SHA}" \
    SHARED_MR_RECOVERY="${SHARED_MR_RECOVERY}" \
    bash "${SCRIPT_DIR}/create_mr.sh"
  [ "${STEP_RC}" -ne 0 ] || break
  [ "${MR_FINALIZATION_TRY}" -lt "${MR_FINALIZATION_MAX_TRIES}" ] || break
  case "${STEP_RC}" in
    1|5|6|7|124|137) ;;
    *) break ;;
  esac
  MR_FINALIZATION_TRY=$((MR_FINALIZATION_TRY + 1))
done
MERGE_REQUEST_URL="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '1p')"
MR_ACTION="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '2p')"
MERGE_REQUEST_IID="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '3p')"
MR_OUTCOME="$(printf '%s\n' "${STEP_STDOUT}" | sed -n '4p')"

MR_STDOUT_IDENTITY_VALID=false
case "${MR_ACTION}" in
  created|rotated|reused)
    if [[ "${MERGE_REQUEST_IID}" =~ ^[1-9][0-9]*$ ]]; then
      case "${MERGE_REQUEST_URL}" in
        http://*|https://*) MR_STDOUT_IDENTITY_VALID=true ;;
      esac
    fi
    ;;
esac

# create_mr.sh writes this marker before attempting the optional merge.  It is
# a recovery artifact, not part of the strict compact worker-result schema.
# Require exact execution/issue/branch/SHA identity before trusting it; in
# particular, only a verified merged marker can authorize `finish`.
MR_RESULT_FILE="${LOG_DIR}/mr_result.json"
MR_MARKER=""
MR_RESULT_MODE="$(execution_state_file_mode "${MR_RESULT_FILE}" 2>/dev/null || true)"
MR_RESULT_OWNER="$(execution_state_file_owner "${MR_RESULT_FILE}" 2>/dev/null || true)"
MR_RESULT_BYTES="$(wc -c <"${MR_RESULT_FILE}" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -f "${MR_RESULT_FILE}" ] && [ ! -L "${MR_RESULT_FILE}" ] \
    && [ "${MR_RESULT_MODE}" = 600 ] \
    && [ "${MR_RESULT_OWNER}" = "$(id -u)" ] \
    && [[ "${MR_RESULT_BYTES}" =~ ^[1-9][0-9]*$ ]] \
    && [ "${MR_RESULT_BYTES}" -le 65536 ]; then
  MR_MARKER="$(jq -ce \
    --argjson issue_iid "${ISSUE_IID}" \
    --argjson execution_id "${EXECUTION_ID}" \
    --arg source_branch "${WORK_BRANCH}" \
    --arg target_branch "${MERGE_TARGET_BRANCH}" \
    --arg sha "${COMMIT_SHA}" \
    --arg dependency_base_sha "${DEPENDENCY_BASE_SHA}" \
    --arg shared_branch_role "${SHARED_BRANCH_ROLE}" \
    --arg shared_mr_intent_id "${SHARED_MR_INTENT_ID}" \
    --argjson auto_merge "${AUTO_MERGE}" '
      if type == "object"
        and .version == 1
        and .issue_iid == $issue_iid
        and .execution_id == $execution_id
        and .source_branch == $source_branch
        and .target_branch == $target_branch
        and ((.sha | ascii_downcase) == ($sha | ascii_downcase))
        and ((.dependency_base_sha | ascii_downcase)
          == ($dependency_base_sha | ascii_downcase))
        and .auto_merge == $auto_merge
        and (.iid | type == "number" and . == floor and . > 0)
        and (.web_url | type == "string" and test("^https?://"))
        and (.mr_action == "created" or .mr_action == "rotated"
          or .mr_action == "reused")
        and (if $shared_branch_role == "head" then .mr_action == "created"
          elif $shared_branch_role == "tail" then .mr_action == "reused"
          else true end)
        and (if $shared_branch_role == "head" or $shared_branch_role == "tail"
          then .shared_mr_intent_id == $shared_mr_intent_id
            and (.shared_mr_intent_id | type == "string"
              and test("^[0-9a-f]{64}$"))
          else (has("shared_mr_intent_id") | not) end)
        and (.outcome == "merged" or .outcome == "opened" or .outcome == "unknown")
        and (.verified | type == "boolean")
        and (.observed_state | type == "string")
        and (.merge_attempted | type == "boolean")
        and (.merge_api_succeeded | type == "boolean")
        and (.reason | type == "string")
      then . else error("invalid MR result marker") end
    ' "${MR_RESULT_FILE}" 2>/dev/null || true)"
fi

if [ -n "${MR_MARKER}" ]; then
  MARKER_URL="$(jq -r '.web_url' <<<"${MR_MARKER}")"
  MARKER_ACTION="$(jq -r '.mr_action' <<<"${MR_MARKER}")"
  MARKER_IID="$(jq -r '.iid' <<<"${MR_MARKER}")"
  if [ "${MR_STDOUT_IDENTITY_VALID}" = true ] \
      && { [ "${MERGE_REQUEST_URL}" != "${MARKER_URL}" ] \
        || [ "${MR_ACTION}" != "${MARKER_ACTION}" ] \
        || [ "${MERGE_REQUEST_IID}" != "${MARKER_IID}" ]; }; then
    BLOCK_REASON="MR creation failed: stdout identity does not match durable marker"
    MERGE_REQUEST_URL=""
    MERGE_REQUEST_IID=""
    MR_ACTION=none
    finish_blocked
  fi
  MERGE_REQUEST_URL="${MARKER_URL}"
  MR_ACTION="${MARKER_ACTION}"
  MERGE_REQUEST_IID="${MARKER_IID}"
  MR_OUTCOME="$(jq -r '.outcome' <<<"${MR_MARKER}")"
elif [ "${MR_STDOUT_IDENTITY_VALID}" != true ]; then
  BLOCK_REASON="MR creation failed: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}; no recoverable MR identity")"
  MERGE_REQUEST_URL=""
  MERGE_REQUEST_IID=""
  MR_ACTION=none
  finish_blocked
else
  # The MR identity is recoverable from stdout, but without the exact marker
  # no observed state can authorize finish.
  MR_OUTCOME=unknown
fi

# Do not publish `pr` merely because a shared MR URL was observed. The exact
# opened marker is the release fence for C. If all bounded calls remain
# uncertain, persist the compact result without a completion-label mutation;
# Phase 6 retains this claim via the pending checkpoint and the heartbeat runs
# only MR finalization on a later tick.
if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ] \
    && { [ -z "${MR_MARKER}" ] \
      || ! jq -e '
        .verified == true
        and .outcome == "opened"
        and .observed_state == "opened"
        and .merge_attempted == false
        and .merge_api_succeeded == false
      ' <<<"${MR_MARKER}" >/dev/null; }; then
  FINAL_STATUS=done
  BLOCK_REASON=""
  run_summary
  persist_and_print_result
  exit 0
fi

# Shared completion labels are written only by claim-fenced Phase 6 after a
# fresh exact GitLab read. create_mr's marker is durable identity evidence, but
# the MR can still be closed, retargeted, or moved before callback processing.
if [ "$(jq -r 'length' <<<"${BRANCH_MEMBERS_JSON}")" -eq 2 ]; then
  FINAL_STATUS=done
  BLOCK_REASON=""
  run_summary
  persist_and_print_result
  exit 0
fi

DESIRED_COMPLETION_LABEL=pr
if [ "${AUTO_MERGE}" = true ] \
    && [ -n "${MR_MARKER}" ] \
    && jq -e '.verified == true and .outcome == "merged" and .observed_state == "merged"' \
      <<<"${MR_MARKER}" >/dev/null; then
  DESIRED_COMPLETION_LABEL=finish
fi

# The compact result intentionally stays success-shaped once the code, push,
# and MR creation completed so Phase 6 can independently reconcile the exact
# MR.

FINAL_STATUS=done
if ! sync_label add "${DESIRED_COMPLETION_LABEL}"; then
  # The MR already has a durable identity.  Do not turn an unavailable final
  # label write—or a verified merge—into blocked-cc.  The done worker result
  # keeps the existing strict schema and lets Phase 6 re-read the same exact MR
  # with merge_mr.sh verify mode before retrying the terminal label.
  BLOCK_REASON="add ${DESIRED_COMPLETION_LABEL} label failed after MR finalization: $(last_error_line "${STEP_STDERR}" "rc=${STEP_RC}")"
  run_summary
  persist_and_print_result
  exit 0
fi
LABELS_ADDED="$(remove_json_string "${LABELS_ADDED}" done)"
LABELS_REMOVED="$(append_json_string "${LABELS_REMOVED}" done)"

BLOCK_REASON=""
run_summary
persist_and_print_result
