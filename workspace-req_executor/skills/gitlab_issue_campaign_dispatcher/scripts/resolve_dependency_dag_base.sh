#!/usr/bin/env bash
# Resolve an immutable dependency baseline for one DAG-v2 consumer.
#
# This helper is deliberately non-destructive. It verifies
# dispatcher-authenticated source snapshots against exact local origin refs,
# consults private per-Issue state only for the richer executor-state snapshot
# shape, performs transitive reduction, and (when necessary) writes only new,
# unreachable Git tree/commit objects for a deterministic aggregate base. It
# never creates, updates, or deletes a ref or Merge Request.
#
# Required environment:
#   REPO_PATH
#   ISSUES_ROOT
#   DAG_CONSUMER_IID
#   DAG_TARGET_BRANCH
#   DAG_SOURCE_SNAPSHOTS_JSON
#
# DAG_SOURCE_SNAPSHOTS_JSON is the ordered, dispatcher-verified direct-input
# vector. The dispatcher remains responsible for the fresh GitLab reads. This
# helper requires the explicit verified=true assertion and binds it to the
# locally fetched exact branch/SHA. Ordinary historical sources may use the
# GitLab-authoritative label/branch shape:
#
# {
#   "iid": 9,
#   "identity_source": "gitlab_pr_label_branch",
#   "work_branch": "issue/9",
#   "commit_sha": "<exact fetched issue/9 tip>",
#   "work_branch_sha": "<same exact tip>",
#   "verified": true
# }
#
# Content-addressed DAG sources use the richer executor-state shape:
#
# [
#   {
#     "iid": 11,
#     "execution_id": 4,
#     "work_branch": "issue/11",
#     "commit_sha": "<business object id>",
#     "work_branch_sha": "<exact remote branch tip>",
#     "verified": true,
#     "mr": {
#       "iid": 123,
#       "url": "https://gitlab.example/group/project/-/merge_requests/123",
#       "state": "opened",
#       "source_branch": "issue/11",
#       "target_branch": "main",
#       "sha": "<business SHA when already merged, otherwise branch-tip SHA>"
#     }
#   }
# ]
#
# Success stdout is one compact JSON object:
# {
#   "version": 2,
#   "status": "ready",
#   "consumer_iid": 42,
#   "work_branch": "issue/42-dag-<first 16 chars of plan_sha256>",
#   "target_branch": "main",
#   "declared_inputs": [...],
#   "effective_inputs": [...],
#   "closure_iids": [11],
#   "aggregate_base_sha": "<full object id>",
#   "plan_sha256": "<64 lowercase hex>"
# }
#
# Deterministic dependency conflicts emit status=failed with
# reason=dependency_merge_conflict and exit 6. Other post-parse identity or Git
# failures also emit a stable failed envelope and exit 5. Invalid caller input
# exits 2 without exposing raw subordinate-tool diagnostics. Frozen v2 source
# plans are walked to a maximum depth of 32 and 200 unique IIDs; reachability
# back to the consumer is dependency_cycle, while a corrupt source-plan
# recursion stack is dependency_source_plan_invalid.

set -euo pipefail

: "${REPO_PATH:?}" "${ISSUES_ROOT:?}" "${DAG_CONSUMER_IID:?}" \
  "${DAG_TARGET_BRANCH:?}" "${DAG_SOURCE_SNAPSHOTS_JSON:?}"

DAG_WORK_BRANCH=""
DECLARED_INPUTS_JSON='[]'
EFFECTIVE_INPUTS_JSON='[]'
PLAN_SHA256=""
INPUT_IDENTITY_SHA256=""
TRUSTED_MERGE_GIT_DIR=""
CLOSURE_IIDS_JSON='[]'

fail_input() {
  printf 'resolve_dependency_dag_base: %s\n' "$1" >&2
  exit 2
}

private_file_mode() {
  if stat -f '%Lp' "$1" 2>/dev/null; then
    :
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

private_file_owner() {
  if stat -f '%u' "$1" 2>/dev/null; then
    :
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

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

verify_terminal_log_child() {
  local business_sha="$1" branch_tip_sha="$2" source_iid="$3"
  local source_execution_id="$4" parent_line diff_paths changed_path
  local allowed_prefix

  parent_line="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
    rev-list --parents -n 1 "${branch_tip_sha}" 2>/dev/null)" || return 1
  [ "${parent_line}" = "${branch_tip_sha} ${business_sha}" ] || return 1
  diff_paths="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
    -c core.quotePath=true diff --name-only --no-renames \
    "${business_sha}" "${branch_tip_sha}" -- 2>/dev/null)" || return 1
  [ -n "${diff_paths}" ] || return 1
  allowed_prefix=".req_executor/issue-${source_iid}/log/execution-${source_execution_id}/"
  while IFS= read -r changed_path; do
    case "${changed_path}" in
      "${allowed_prefix}"*) ;;
      *) return 1 ;;
    esac
  done <<<"${diff_paths}"
}

emit_failure() {
  local reason="$1" source_iid="${2:-}" exit_code="${3:-5}"
  jq -nc \
    --arg reason "${reason}" \
    --arg source_iid "${source_iid}" \
    --argjson consumer_iid "${DAG_CONSUMER_IID}" \
    --arg work_branch "${DAG_WORK_BRANCH}" \
    --arg target_branch "${DAG_TARGET_BRANCH}" \
    --argjson declared_inputs "${DECLARED_INPUTS_JSON}" \
    --argjson effective_inputs "${EFFECTIVE_INPUTS_JSON}" \
    --arg plan_sha256 "${PLAN_SHA256}" '{
      version:2,
      status:"failed",
      reason:$reason,
      consumer_iid:$consumer_iid,
      work_branch:(if $work_branch == "" then null else $work_branch end),
      target_branch:$target_branch,
      declared_inputs:$declared_inputs,
      effective_inputs:$effective_inputs,
      plan_sha256:(if $plan_sha256 == "" then null else $plan_sha256 end),
      source_iid:(if $source_iid == "" then null else ($source_iid | tonumber) end)
    }'
  exit "${exit_code}"
}

prepare_trusted_merge_git_dir() {
  local control_dir object_format trusted_mode trusted_owner
  local config_file config_mode config_owner

  control_dir="${ISSUES_ROOT%/}/../_dispatcher"
  if [ -L "${control_dir}" ]; then
    return 1
  fi
  if [ ! -d "${control_dir}" ]; then
    (umask 077; mkdir -p "${control_dir}") || return 1
  fi
  TRUSTED_MERGE_GIT_DIR="${control_dir}/dag-merge.git"
  if [ -L "${TRUSTED_MERGE_GIT_DIR}" ]; then
    return 1
  fi
  object_format="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
    rev-parse --show-object-format 2>/dev/null)" || return 1
  case "${object_format}" in
    sha1|sha256) ;;
    *) return 1 ;;
  esac
  if [ ! -e "${TRUSTED_MERGE_GIT_DIR}" ]; then
    (
      umask 077
      env -i \
        PATH="${PATH}" \
        HOME=/nonexistent \
        LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_GLOBAL=/dev/null \
        git -c init.templateDir= init --bare -q \
          "--object-format=${object_format}" "${TRUSTED_MERGE_GIT_DIR}"
    ) || return 1
  fi
  [ -d "${TRUSTED_MERGE_GIT_DIR}" ] || return 1
  trusted_mode="$(private_file_mode "${TRUSTED_MERGE_GIT_DIR}" \
    2>/dev/null || true)"
  trusted_owner="$(private_file_owner "${TRUSTED_MERGE_GIT_DIR}" \
    2>/dev/null || true)"
  [ "${trusted_owner}" = "$(id -u)" ] || return 1
  case "${trusted_mode}" in
    700) ;;
    750|755)
      chmod 700 "${TRUSTED_MERGE_GIT_DIR}" || return 1
      ;;
    *) return 1 ;;
  esac
  config_file="${TRUSTED_MERGE_GIT_DIR}/config"
  [ -f "${config_file}" ] && [ ! -L "${config_file}" ] || return 1
  config_mode="$(private_file_mode "${config_file}" 2>/dev/null || true)"
  config_owner="$(private_file_owner "${config_file}" 2>/dev/null || true)"
  [ "${config_owner}" = "$(id -u)" ] || return 1
  case "${config_mode}" in
    600) ;;
    640|644)
      chmod 600 "${config_file}" || return 1
      ;;
    *) return 1 ;;
  esac
  if env -i \
      PATH="${PATH}" \
      HOME=/nonexistent \
      LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_SYSTEM=/dev/null \
      GIT_CONFIG_GLOBAL=/dev/null \
      git --git-dir="${TRUSTED_MERGE_GIT_DIR}" config --no-includes --local \
        --get-regexp \
        '^(alias\.|core\.(attributesfile|fsmonitor)$|diff\.|filter\.|include\.|includeif\.|merge\.|protocol\.)' \
        >/dev/null 2>&1; then
    return 1
  fi
  [ ! -s "${TRUSTED_MERGE_GIT_DIR}/info/attributes" ] || return 1
}

for required_command in git jq awk stat wc id tr; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || fail_input "${required_command} is required"
done
if ! command -v sha256sum >/dev/null 2>&1 \
    && ! command -v shasum >/dev/null 2>&1; then
  fail_input "a SHA-256 command is required"
fi

[[ "${DAG_CONSUMER_IID}" =~ ^[1-9][0-9]*$ ]] \
  && [ "${DAG_CONSUMER_IID}" -le 2147483647 ] \
  || fail_input "DAG_CONSUMER_IID must be a positive GitLab IID"
[ -d "${REPO_PATH}/.git" ] || fail_input "REPO_PATH is not a Git repository"
[ -d "${ISSUES_ROOT}" ] && [ ! -L "${ISSUES_ROOT}" ] \
  || fail_input "ISSUES_ROOT must be a trusted directory"
GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" check-ref-format \
  --branch "${DAG_TARGET_BRANCH}" >/dev/null 2>&1 \
  || fail_input "DAG_TARGET_BRANCH is invalid"

if ! DECLARED_INPUTS_JSON="$(printf '%s' "${DAG_SOURCE_SNAPSHOTS_JSON}" \
    | jq -cSe \
      --arg target_branch "${DAG_TARGET_BRANCH}" \
      --argjson consumer_iid "${DAG_CONSUMER_IID}" '
      def full_oid:
        type == "string"
        and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$");
      def clean_string:
        type == "string" and length > 0
        and (explode | all(. >= 32 and . != 127));
      def label_branch_source:
        . as $source
        | type == "object"
        and (keys | sort) == ([
          "commit_sha","identity_source","iid","verified",
          "work_branch","work_branch_sha"
        ] | sort)
        and .identity_source == "gitlab_pr_label_branch"
        and (.iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and .work_branch == ("issue/" + ($source.iid | tostring))
        and (.commit_sha | full_oid)
        and (.work_branch_sha | full_oid)
        and ((.commit_sha | ascii_downcase)
          == (.work_branch_sha | ascii_downcase))
        and .verified == true;
      def executor_source($target):
        . as $source
        | type == "object"
        and (keys | sort) ==
          ([
            "commit_sha","execution_id","iid","mr","verified",
            "work_branch","work_branch_sha"
          ] | sort)
        and (.iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and (.execution_id | type == "number" and . == floor
          and . > 0 and . <= 281474976710655)
        and (
          .work_branch == ("issue/" + ($source.iid | tostring))
          or (.work_branch | test(
            "^issue/" + ($source.iid | tostring)
            + "-dag-[0-9a-f]{16}$"))
        )
        and (.commit_sha | full_oid)
        and (.work_branch_sha | full_oid)
        and .verified == true
        and (.mr | type == "object")
        and (.mr | keys | sort) ==
          (["iid","sha","source_branch","state","target_branch","url"] | sort)
        and (.mr.iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and (.mr.url | clean_string)
        and (.mr.url | test(
          "^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
        and (.mr as $mr
          | $mr.url | test(
            "/-/merge_requests/" + ($mr.iid | tostring) + "/?$"))
        and (.mr.state == "opened" or .mr.state == "merged")
        and .mr.source_branch == .work_branch
        and .mr.target_branch == $target
        and (.mr.sha | full_oid)
        and (
          if .mr.state == "opened" then
            ((.mr.sha | ascii_downcase)
              == (.work_branch_sha | ascii_downcase))
          else
            ((.mr.sha | ascii_downcase)
              == (.commit_sha | ascii_downcase))
            or ((.mr.sha | ascii_downcase)
              == (.work_branch_sha | ascii_downcase))
          end
        );
      if type == "array"
        and length >= 1 and length <= 8
        and ([.[].iid] | length == (unique | length))
        and all(.[]; label_branch_source or executor_source($target_branch))
      then map(
        .commit_sha = (.commit_sha | ascii_downcase)
        | .work_branch_sha = (.work_branch_sha | ascii_downcase)
        | if has("mr") then
            .mr.sha = (.mr.sha | ascii_downcase)
          else . end
      )
      else error("invalid DAG source snapshots")
      end
    ' 2>/dev/null)"; then
  fail_input "DAG_SOURCE_SNAPSHOTS_JSON is invalid"
fi

direct_self_index="$(printf '%s' "${DECLARED_INPUTS_JSON}" \
  | jq -r --argjson consumer_iid "${DAG_CONSUMER_IID}" \
    'map(.iid) | index($consumer_iid)')"
if [ "${direct_self_index}" != null ]; then
  emit_failure "dependency_cycle" "${DAG_CONSUMER_IID}"
fi

mapfile -t DECLARED_IIDS < <(
  printf '%s' "${DECLARED_INPUTS_JSON}" | jq -r '.[].iid'
)
mapfile -t DECLARED_SHAS < <(
  printf '%s' "${DECLARED_INPUTS_JSON}" | jq -r '.[].commit_sha'
)
DECLARED_COUNT="${#DECLARED_IIDS[@]}"

for ((source_index = 0; source_index < DECLARED_COUNT; source_index++)); do
  source_iid="${DECLARED_IIDS[source_index]}"
  source_sha="${DECLARED_SHAS[source_index]}"
  source_snapshot="$(printf '%s' "${DECLARED_INPUTS_JSON}" \
    | jq -c --argjson index "${source_index}" '.[$index]')"
  source_identity_source="$(printf '%s' "${source_snapshot}" \
    | jq -r '.identity_source // "executor_state"')"
  source_execution_id="$(printf '%s' "${source_snapshot}" \
    | jq -r '.execution_id // empty')"
  source_branch="$(printf '%s' "${source_snapshot}" | jq -r '.work_branch')"
  source_work_branch_sha="$(printf '%s' "${source_snapshot}" \
    | jq -r '.work_branch_sha')"
  source_mr_iid="$(printf '%s' "${source_snapshot}" | jq -r '.mr.iid // empty')"
  source_mr_url="$(printf '%s' "${source_snapshot}" | jq -r '.mr.url // empty')"
  source_state_dir="${ISSUES_ROOT}/issue-${source_iid}"
  source_state_file="${source_state_dir}/state.json"

  source_state_safe=false
  source_state_verified=false
  if [ "${source_identity_source}" = gitlab_pr_label_branch ]; then
    source_state_verified=true
  elif [ -d "${source_state_dir}" ] && [ ! -L "${source_state_dir}" ] \
      && [ -f "${source_state_file}" ] && [ ! -L "${source_state_file}" ] \
      && [ "$(private_file_mode "${source_state_file}" 2>/dev/null || true)" = 600 ] \
      && [ "$(private_file_owner "${source_state_file}" 2>/dev/null || true)" = "$(id -u)" ]; then
    source_state_bytes="$(wc -c <"${source_state_file}" 2>/dev/null \
      | tr -d '[:space:]' || true)"
    if [[ "${source_state_bytes}" =~ ^[1-9][0-9]*$ ]] \
        && [ "${source_state_bytes}" -le 65536 ]; then
      source_state_safe=true
      if jq -e \
          --argjson iid "${source_iid}" \
          --argjson execution_id "${source_execution_id}" \
          --arg work_branch "${source_branch}" \
          --arg commit_sha "${source_sha}" \
          --arg work_branch_sha "${source_work_branch_sha}" \
          --argjson mr_iid "${source_mr_iid}" \
          --arg mr_url "${source_mr_url}" \
          --arg target_branch "${DAG_TARGET_BRANCH}" '
          type == "object"
          and .iid == $iid
          and .status == "done"
          and .latest_execution_id == $execution_id
          and .dependency_pinned_execution_id == $execution_id
          and .work_branch == $work_branch
          and .branch_members == [$iid]
          and (.shared_branch_role // null) == null
          and (
            if $work_branch == ("issue/" + ($iid | tostring)) then
              (.dependency_contract_version // null) == null
              and (.dependency_plan_sha256 // null) == null
            else
              .dependency_contract_version == 2
              and (.dependency_plan_sha256 | type == "string")
              and (.dependency_plan_sha256 | test("^[0-9a-f]{64}$"))
              and (.dependency_plan | type == "object")
              and .dependency_plan.plan_sha256 == .dependency_plan_sha256
              and .dependency_plan.consumer_iid == $iid
              and .dependency_plan.target_branch == $target_branch
              and .dependency_plan.work_branch == $work_branch
              and $work_branch == (
                "issue/" + ($iid | tostring) + "-dag-"
                + .dependency_plan_sha256[0:16])
            end
          )
          and .dependency_history_verified == true
          and (.commit_sha | type == "string")
          and ((.commit_sha | ascii_downcase) == ($commit_sha | ascii_downcase))
          and (.work_branch_sha | type == "string")
          and ((.work_branch_sha | ascii_downcase)
            == ($work_branch_sha | ascii_downcase))
          and .merge_request_url == $mr_url
          and ($mr_url | test(
            "/-/merge_requests/" + ($mr_iid | tostring) + "/?$"))
        ' "${source_state_file}" >/dev/null 2>&1; then
        source_state_verified=true
      fi
    fi
  fi
  if [ "${source_state_verified}" != true ]; then
    if [ "${source_state_safe}" = true ]; then
      emit_failure "dependency_source_state_identity_mismatch" "${source_iid}"
    fi
    emit_failure "dependency_source_state_unsafe" "${source_iid}"
  fi

  if [ "${source_identity_source}" = executor_state ] \
      && [ "${source_work_branch_sha}" != "${source_sha}" ]; then
    if ! verify_terminal_log_child \
          "${source_sha}" "${source_work_branch_sha}" \
          "${source_iid}" "${source_execution_id}"; then
      emit_failure "dependency_source_state_identity_mismatch" "${source_iid}"
    fi
  fi
  remote_source_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
    rev-parse --verify "refs/remotes/origin/${source_branch}^{commit}" \
    2>/dev/null || true)"
  if [ -z "${remote_source_sha}" ] \
      || [ "${remote_source_sha,,}" != "${source_work_branch_sha,,}" ]; then
    emit_failure "dependency_source_branch_missing_or_moved" "${source_iid}"
  fi
  if ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
      cat-file -e "${source_sha}^{commit}" 2>/dev/null; then
    emit_failure "dependency_source_commit_unavailable" "${source_iid}"
  fi
done

# A completed DAG-v2 source can itself depend on other completed artifacts.
# Walk that frozen closure as a final defense against an indirect dependency on
# the current consumer. The traversal is bounded so corrupt private state
# cannot turn one dispatcher tick into unbounded filesystem or Git work.
FROZEN_PLAN_JSON=""

validate_frozen_dependency_plan() {
  local plan_json="$1" expected_iid="$2" expected_branch="$3"
  local expected_target="$4" root_source_iid="$5"
  local canonical_json calculated_sha plan_sha aggregate_sha
  local effective_count effective_sha declared_sha ancestry_rc

  if ! FROZEN_PLAN_JSON="$(printf '%s' "${plan_json}" | jq -cSe \
      --argjson expected_iid "${expected_iid}" \
      --arg expected_branch "${expected_branch}" \
      --arg expected_target "${expected_target}" '
      def full_oid:
        type == "string"
        and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
      def clean_string:
        type == "string" and length > 0
        and (explode | all(. >= 32 and . != 127));
      def label_branch_source:
        . as $source
        | type == "object"
        and (keys | sort) == ([
          "commit_sha","identity_source","iid","verified",
          "work_branch","work_branch_sha"
        ] | sort)
        and .identity_source == "gitlab_pr_label_branch"
        and (.iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and .work_branch == ("issue/" + ($source.iid | tostring))
        and (.commit_sha | full_oid)
        and .commit_sha == .work_branch_sha
        and .verified == true;
      def executor_source($target):
        . as $source
        | type == "object"
        and (keys | sort) ==
          ([
            "commit_sha","execution_id","iid","mr","verified",
            "work_branch","work_branch_sha"
          ] | sort)
        and (.iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and (.execution_id | type == "number" and . == floor
          and . > 0 and . <= 281474976710655)
        and (
          .work_branch == ("issue/" + ($source.iid | tostring))
          or (.work_branch | test(
            "^issue/" + ($source.iid | tostring)
            + "-dag-[0-9a-f]{16}$"))
        )
        and (.commit_sha | full_oid)
        and (.work_branch_sha | full_oid)
        and .verified == true
        and (.mr | type == "object")
        and (.mr | keys | sort) ==
          (["iid","sha","source_branch","state","target_branch","url"] | sort)
        and (.mr.iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and (.mr.url | clean_string)
        and (.mr.url | test(
          "^https?://[^[:space:]]+/-/merge_requests/[1-9][0-9]*/?$"))
        and (.mr as $mr
          | $mr.url | test(
            "/-/merge_requests/" + ($mr.iid | tostring) + "/?$"))
        and (.mr.state == "opened" or .mr.state == "merged")
        and .mr.source_branch == .work_branch
        and .mr.target_branch == $target
        and (.mr.sha | full_oid)
        and (
          if .mr.state == "opened" then
            .mr.sha == .work_branch_sha
          else
            .mr.sha == .commit_sha or .mr.sha == .work_branch_sha
          end
        );
      def source_snapshot($target):
        label_branch_source or executor_source($target);
      . as $plan
      | ($plan.effective_inputs | map(.iid)) as $effective_iids
      | if type == "object"
        and (keys | sort) == ([
          "aggregate_base_sha","consumer_iid","declared_inputs",
          "effective_inputs","plan_sha256","target_branch","version",
          "work_branch"
        ] | sort)
        and .version == 2
        and .consumer_iid == $expected_iid
        and (.consumer_iid | type == "number" and . == floor
          and . > 0 and . <= 2147483647)
        and .target_branch == $expected_target
        and (.target_branch | clean_string)
        and (.declared_inputs | type == "array"
          and length >= 1 and length <= 8)
        and ([.declared_inputs[].iid] | length == (unique | length))
        and all(.declared_inputs[]; source_snapshot($plan.target_branch))
        and (.effective_inputs | type == "array"
          and length >= 1 and length <= 8)
        and ([.effective_inputs[].iid] | length == (unique | length))
        and all(.effective_inputs[];
          . as $effective
          | any($plan.declared_inputs[]; . == $effective))
        and ([
          $plan.declared_inputs[].iid
          | . as $declared_iid
          | select($effective_iids | index($declared_iid) != null)
        ] == $effective_iids)
        and (.aggregate_base_sha | full_oid)
        and (.plan_sha256 | type == "string"
          and test("^[0-9a-f]{64}$"))
        and .work_branch == $expected_branch
        and .work_branch == (
          "issue/" + (.consumer_iid | tostring) + "-dag-"
          + .plan_sha256[0:16])
      then . else error("invalid frozen dependency plan") end
    ' 2>/dev/null)"; then
    emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  fi

  canonical_json="$(printf '%s' "${FROZEN_PLAN_JSON}" | jq -cS '{
    version:.version,
    algorithm:"ordered-frontier-merge-v1",
    consumer_iid:.consumer_iid,
    target_branch:.target_branch,
    declared_inputs:.declared_inputs,
    effective_inputs:.effective_inputs,
    aggregate_base_sha:.aggregate_base_sha
  }')"
  calculated_sha="$(sha256_text "${canonical_json}")" \
    || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  plan_sha="$(printf '%s' "${FROZEN_PLAN_JSON}" | jq -r '.plan_sha256')"
  [ "${calculated_sha}" = "${plan_sha}" ] \
    || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"

  aggregate_sha="$(printf '%s' "${FROZEN_PLAN_JSON}" \
    | jq -r '.aggregate_base_sha')"
  if ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
      cat-file -e "${aggregate_sha}^{commit}" 2>/dev/null; then
    emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  fi
  effective_count="$(printf '%s' "${FROZEN_PLAN_JSON}" \
    | jq -r '.effective_inputs | length')"
  if [ "${effective_count}" -eq 1 ]; then
    effective_sha="$(printf '%s' "${FROZEN_PLAN_JSON}" \
      | jq -r '.effective_inputs[0].commit_sha')"
    [ "${aggregate_sha}" = "${effective_sha}" ] \
      || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  fi
  while IFS= read -r declared_sha; do
    set +e
    GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" merge-base \
      --is-ancestor "${declared_sha}" "${aggregate_sha}" >/dev/null 2>&1
    ancestry_rc=$?
    set -e
    [ "${ancestry_rc}" -eq 0 ] \
      || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  done < <(printf '%s' "${FROZEN_PLAN_JSON}" \
    | jq -r '.declared_inputs[].commit_sha')
}

declare -A CLOSURE_ACTIVE
declare -A CLOSURE_VISITED_IDENTITY
CLOSURE_NODE_COUNT=0

walk_frozen_source_snapshot() {
  local snapshot_json="$1" depth="$2" root_source_iid="$3"
  local closure_iid closure_identity_source closure_execution_id
  local closure_branch closure_sha
  local closure_work_branch_sha closure_mr_iid closure_mr_url closure_target
  local snapshot_identity state_dir state_file state_bytes remote_sha
  local plan_json child_snapshot

  closure_iid="$(printf '%s' "${snapshot_json}" | jq -r '.iid')"
  if [ "${closure_iid}" = "${DAG_CONSUMER_IID}" ]; then
    emit_failure "dependency_cycle" "${root_source_iid}"
  fi
  [ "${depth}" -le 32 ] \
    || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"

  # MR state may legitimately advance from opened to merged between two
  # independently frozen paths. Artifact identity is every exact field except
  # that observation state; differing execution/branch/SHA/MR identity remains
  # invalid.
  snapshot_identity="$(printf '%s' "${snapshot_json}" \
    | jq -cS 'del(.mr.state)')"
  if [ "${CLOSURE_ACTIVE[${closure_iid}]+set}" = set ]; then
    emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  fi
  if [ "${CLOSURE_VISITED_IDENTITY[${closure_iid}]+set}" = set ]; then
    [ "${CLOSURE_VISITED_IDENTITY[${closure_iid}]}" = "${snapshot_identity}" ] \
      || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
    return
  fi

  CLOSURE_NODE_COUNT="$((CLOSURE_NODE_COUNT + 1))"
  [ "${CLOSURE_NODE_COUNT}" -le 200 ] \
    || emit_failure "dependency_source_plan_invalid" "${root_source_iid}"

  closure_identity_source="$(printf '%s' "${snapshot_json}" \
    | jq -r '.identity_source // "executor_state"')"
  closure_execution_id="$(printf '%s' "${snapshot_json}" \
    | jq -r '.execution_id // empty')"
  closure_branch="$(printf '%s' "${snapshot_json}" | jq -r '.work_branch')"
  closure_sha="$(printf '%s' "${snapshot_json}" | jq -r '.commit_sha')"
  closure_work_branch_sha="$(printf '%s' "${snapshot_json}" \
    | jq -r '.work_branch_sha')"
  closure_mr_iid="$(printf '%s' "${snapshot_json}" \
    | jq -r '.mr.iid // empty')"
  closure_mr_url="$(printf '%s' "${snapshot_json}" \
    | jq -r '.mr.url // empty')"
  closure_target="$(printf '%s' "${snapshot_json}" \
    | jq -r '.mr.target_branch // empty')"
  state_dir="${ISSUES_ROOT}/issue-${closure_iid}"
  state_file="${state_dir}/state.json"

  closure_state_verified=false
  if [ "${closure_identity_source}" = gitlab_pr_label_branch ]; then
    closure_state_verified=true
  elif [ -d "${state_dir}" ] && [ ! -L "${state_dir}" ] \
      && [ -f "${state_file}" ] && [ ! -L "${state_file}" ] \
      && [ "$(private_file_mode "${state_file}" 2>/dev/null || true)" = 600 ] \
      && [ "$(private_file_owner "${state_file}" 2>/dev/null || true)" = "$(id -u)" ]; then
    state_bytes="$(wc -c <"${state_file}" 2>/dev/null \
      | tr -d '[:space:]' || true)"
    if [[ "${state_bytes}" =~ ^[1-9][0-9]*$ ]] \
        && [ "${state_bytes}" -le 65536 ] \
        && jq -e \
          --argjson iid "${closure_iid}" \
          --argjson execution_id "${closure_execution_id}" \
          --arg branch "${closure_branch}" \
          --arg sha "${closure_sha}" \
          --arg work_branch_sha "${closure_work_branch_sha}" \
          --argjson mr_iid "${closure_mr_iid}" \
          --arg mr_url "${closure_mr_url}" \
          --arg target "${closure_target}" '
          type == "object"
          and .iid == $iid
          and .status == "done"
          and .latest_execution_id == $execution_id
          and .dependency_pinned_execution_id == $execution_id
          and .work_branch == $branch
          and .branch_members == [$iid]
          and (.shared_branch_role // null) == null
          and .dependency_history_verified == true
          and ((.commit_sha | ascii_downcase) == ($sha | ascii_downcase))
          and (.work_branch_sha | type == "string"
            and test("^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"))
          and ((.work_branch_sha | ascii_downcase)
            == ($work_branch_sha | ascii_downcase))
          and .merge_request_url == $mr_url
          and ($mr_url | test(
            "/-/merge_requests/" + ($mr_iid | tostring) + "/?$"))
          and (
            if $branch == ("issue/" + ($iid | tostring)) then
              (.dependency_contract_version // null) == null
              and (.dependency_plan_sha256 // null) == null
              and (.dependency_plan // null) == null
            else
              .dependency_contract_version == 2
              and (.dependency_plan_sha256 | type == "string"
                and test("^[0-9a-f]{64}$"))
              and (.dependency_plan | type == "object")
              and .dependency_plan.plan_sha256 == .dependency_plan_sha256
              and .dependency_plan.consumer_iid == $iid
              and .dependency_plan.target_branch == $target
              and .dependency_plan.work_branch == $branch
              and $branch == (
                "issue/" + ($iid | tostring) + "-dag-"
                + .dependency_plan_sha256[0:16])
            end
          )
        ' "${state_file}" >/dev/null 2>&1; then
      closure_state_verified=true
    fi
  fi
  if [ "${closure_state_verified}" != true ]; then
    emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  fi

  if [ "${closure_identity_source}" = executor_state ] \
      && [ "${closure_work_branch_sha}" != "${closure_sha}" ]; then
    if ! verify_terminal_log_child \
          "${closure_sha}" "${closure_work_branch_sha}" \
          "${closure_iid}" "${closure_execution_id}"; then
      emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
    fi
  fi
  remote_sha="$(GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
    rev-parse --verify "refs/remotes/origin/${closure_branch}^{commit}" \
    2>/dev/null || true)"
  if [ -z "${remote_sha}" ] \
      || [ "${remote_sha,,}" != "${closure_work_branch_sha,,}" ] \
      || ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
        cat-file -e "${closure_sha}^{commit}" 2>/dev/null; then
    emit_failure "dependency_source_plan_invalid" "${root_source_iid}"
  fi

  CLOSURE_ACTIVE["${closure_iid}"]=true
  if [ "${closure_identity_source}" = executor_state ] \
      && [ "${closure_branch}" != "issue/${closure_iid}" ]; then
    plan_json="$(jq -cS '.dependency_plan' "${state_file}")"
    validate_frozen_dependency_plan \
      "${plan_json}" "${closure_iid}" "${closure_branch}" \
      "${closure_target}" "${root_source_iid}"
    plan_json="${FROZEN_PLAN_JSON}"
    while IFS= read -r child_snapshot; do
      walk_frozen_source_snapshot \
        "${child_snapshot}" "$((depth + 1))" "${root_source_iid}"
    done < <(printf '%s' "${plan_json}" | jq -c '.declared_inputs[]')
  fi
  unset 'CLOSURE_ACTIVE['"${closure_iid}"']'
  CLOSURE_VISITED_IDENTITY["${closure_iid}"]="${snapshot_identity}"
}

for ((source_index = 0; source_index < DECLARED_COUNT; source_index++)); do
  source_snapshot="$(printf '%s' "${DECLARED_INPUTS_JSON}" \
    | jq -c --argjson index "${source_index}" '.[$index]')"
  walk_frozen_source_snapshot \
    "${source_snapshot}" 1 "${DECLARED_IIDS[source_index]}"
done
for closure_iid in "${!CLOSURE_VISITED_IDENTITY[@]}"; do
  CLOSURE_IIDS_JSON="$(printf '%s' "${CLOSURE_IIDS_JSON}" | jq -c \
    --argjson iid "${closure_iid}" '. + [$iid]')"
done
CLOSURE_IIDS_JSON="$(printf '%s' "${CLOSURE_IIDS_JSON}" \
  | jq -c 'unique | sort')"

# Transitive reduction keeps the declaration order while removing:
#   1. later duplicate commit identities; and
#   2. any commit already contained by another declared input.
# The full declared vector remains in the output and plan hash for provenance.
declare -a KEEP_INPUT
for ((source_index = 0; source_index < DECLARED_COUNT; source_index++)); do
  KEEP_INPUT[source_index]=true
done
for ((source_index = 0; source_index < DECLARED_COUNT; source_index++)); do
  source_sha="${DECLARED_SHAS[source_index]}"
  for ((other_index = 0; other_index < DECLARED_COUNT; other_index++)); do
    [ "${source_index}" -ne "${other_index}" ] || continue
    other_sha="${DECLARED_SHAS[other_index]}"
    if [ "${source_sha,,}" = "${other_sha,,}" ]; then
      if [ "${other_index}" -lt "${source_index}" ]; then
        KEEP_INPUT[source_index]=false
        break
      fi
      continue
    fi
    set +e
    GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" merge-base \
      --is-ancestor "${source_sha}" "${other_sha}" >/dev/null 2>&1
    ancestry_rc=$?
    set -e
    case "${ancestry_rc}" in
      0)
        KEEP_INPUT[source_index]=false
        break
        ;;
      1) ;;
      *) emit_failure "dependency_ancestry_check_failed" \
           "${DECLARED_IIDS[source_index]}" ;;
    esac
  done
done

for ((source_index = 0; source_index < DECLARED_COUNT; source_index++)); do
  [ "${KEEP_INPUT[source_index]}" = true ] || continue
  effective_input="$(printf '%s' "${DECLARED_INPUTS_JSON}" \
    | jq -c --argjson index "${source_index}" '.[$index]')"
  EFFECTIVE_INPUTS_JSON="$(jq -cn \
    --argjson current "${EFFECTIVE_INPUTS_JSON}" \
    --argjson item "${effective_input}" '$current + [$item]')"
done
EFFECTIVE_COUNT="$(printf '%s' "${EFFECTIVE_INPUTS_JSON}" | jq -r 'length')"
[ "${EFFECTIVE_COUNT}" -ge 1 ] \
  || emit_failure "dependency_aggregate_verification_failed"

INPUT_IDENTITY_CANONICAL_JSON="$(jq -cnS \
  --argjson consumer_iid "${DAG_CONSUMER_IID}" \
  --arg target_branch "${DAG_TARGET_BRANCH}" \
  --argjson effective_inputs "${EFFECTIVE_INPUTS_JSON}" '{
    version:2,
    algorithm:"ordered-frontier-merge-v1",
    consumer_iid:$consumer_iid,
    target_branch:$target_branch,
    effective_inputs:$effective_inputs
  }')"
INPUT_IDENTITY_SHA256="$(sha256_text "${INPUT_IDENTITY_CANONICAL_JSON}")" \
  || emit_failure "dependency_plan_hash_failed"
[[ "${INPUT_IDENTITY_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
  || emit_failure "dependency_plan_hash_failed"

mapfile -t EFFECTIVE_IIDS < <(
  printf '%s' "${EFFECTIVE_INPUTS_JSON}" | jq -r '.[].iid'
)
mapfile -t EFFECTIVE_SHAS < <(
  printf '%s' "${EFFECTIVE_INPUTS_JSON}" | jq -r '.[].commit_sha'
)

AGGREGATE_BASE_SHA="${EFFECTIVE_SHAS[0]}"
if [ "${EFFECTIVE_COUNT}" -gt 1 ]; then
  prepare_trusted_merge_git_dir \
    || emit_failure "dependency_merge_environment_unsafe"
  for ((merge_index = 1; merge_index < EFFECTIVE_COUNT; merge_index++)); do
    next_iid="${EFFECTIVE_IIDS[merge_index]}"
    next_sha="${EFFECTIVE_SHAS[merge_index]}"
    set +e
    merge_output="$(
      env -i \
        PATH="${PATH}" \
        HOME=/nonexistent \
        LC_ALL=C \
        GIT_DIR="${TRUSTED_MERGE_GIT_DIR}" \
        GIT_OBJECT_DIRECTORY="${REPO_PATH}/.git/objects" \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_ATTR_NOSYSTEM=1 \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_GLOBAL=/dev/null \
        git \
          -c core.attributesFile=/dev/null \
          -c core.hooksPath=/dev/null \
          -c core.fsmonitor=false \
          -c merge.renormalize=false \
          -c submodule.recurse=false \
          merge-tree --write-tree \
          "${AGGREGATE_BASE_SHA}" "${next_sha}" 2>/dev/null
    )"
    merge_rc=$?
    set -e
    if [ "${merge_rc}" -eq 1 ]; then
      emit_failure "dependency_merge_conflict" "${next_iid}" 6
    elif [ "${merge_rc}" -ne 0 ]; then
      emit_failure "dependency_merge_failed" "${next_iid}"
    fi
    aggregate_tree_sha="$(printf '%s\n' "${merge_output}" \
      | awk 'NR == 1 {print $1}')"
    if ! [[ "${aggregate_tree_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
        || ! GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" \
          cat-file -e "${aggregate_tree_sha}^{tree}" 2>/dev/null; then
      emit_failure "dependency_merge_failed" "${next_iid}"
    fi
    aggregate_message="$(printf '%s\n\n%s\n%s\n%s\n' \
      'req_executor dependency DAG base v2' \
      "consumer-iid: ${DAG_CONSUMER_IID}" \
      "input-identity-sha256: ${INPUT_IDENTITY_SHA256}" \
      "merge-step: ${merge_index}:${next_iid}")"
    set +e
    next_aggregate_sha="$(
      env -i \
        PATH="${PATH}" \
        HOME=/nonexistent \
        LC_ALL=C \
        GIT_DIR="${TRUSTED_MERGE_GIT_DIR}" \
        GIT_OBJECT_DIRECTORY="${REPO_PATH}/.git/objects" \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_ATTR_NOSYSTEM=1 \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_AUTHOR_NAME=req-executor \
        GIT_AUTHOR_EMAIL=req-executor@localhost \
        GIT_AUTHOR_DATE=2000-01-01T00:00:00Z \
        GIT_COMMITTER_NAME=req-executor \
        GIT_COMMITTER_EMAIL=req-executor@localhost \
        GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
        git \
          -c core.attributesFile=/dev/null \
          -c core.hooksPath=/dev/null \
          -c commit.gpgSign=false \
          commit-tree "${aggregate_tree_sha}" \
          -p "${AGGREGATE_BASE_SHA}" -p "${next_sha}" \
        <<<"${aggregate_message}" 2>/dev/null
    )"
    commit_tree_rc=$?
    set -e
    if [ "${commit_tree_rc}" -ne 0 ] \
        || ! [[ "${next_aggregate_sha}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
      emit_failure "dependency_merge_failed" "${next_iid}"
    fi
    AGGREGATE_BASE_SHA="${next_aggregate_sha}"
  done
fi

for source_sha in "${DECLARED_SHAS[@]}"; do
  set +e
  GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" merge-base \
    --is-ancestor "${source_sha}" "${AGGREGATE_BASE_SHA}" >/dev/null 2>&1
  aggregate_ancestry_rc=$?
  set -e
  [ "${aggregate_ancestry_rc}" -eq 0 ] \
    || emit_failure "dependency_aggregate_verification_failed"
done

PLAN_CANONICAL_JSON="$(jq -cnS \
  --argjson consumer_iid "${DAG_CONSUMER_IID}" \
  --arg target_branch "${DAG_TARGET_BRANCH}" \
  --argjson declared_inputs "${DECLARED_INPUTS_JSON}" \
  --argjson effective_inputs "${EFFECTIVE_INPUTS_JSON}" \
  --arg aggregate_base_sha "${AGGREGATE_BASE_SHA}" '{
    version:2,
    algorithm:"ordered-frontier-merge-v1",
    consumer_iid:$consumer_iid,
    target_branch:$target_branch,
    declared_inputs:$declared_inputs,
    effective_inputs:$effective_inputs,
    aggregate_base_sha:$aggregate_base_sha
  }')"
PLAN_SHA256="$(sha256_text "${PLAN_CANONICAL_JSON}")" \
  || emit_failure "dependency_plan_hash_failed"
[[ "${PLAN_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
  || emit_failure "dependency_plan_hash_failed"
DAG_WORK_BRANCH="issue/${DAG_CONSUMER_IID}-dag-${PLAN_SHA256:0:16}"
GIT_NO_REPLACE_OBJECTS=1 git -C "${REPO_PATH}" check-ref-format \
  --branch "${DAG_WORK_BRANCH}" >/dev/null 2>&1 \
  || emit_failure "dependency_plan_branch_invalid"

jq -nc \
  --argjson consumer_iid "${DAG_CONSUMER_IID}" \
  --arg work_branch "${DAG_WORK_BRANCH}" \
  --arg target_branch "${DAG_TARGET_BRANCH}" \
  --argjson declared_inputs "${DECLARED_INPUTS_JSON}" \
  --argjson effective_inputs "${EFFECTIVE_INPUTS_JSON}" \
  --arg aggregate_base_sha "${AGGREGATE_BASE_SHA}" \
  --arg plan_sha256 "${PLAN_SHA256}" \
  --argjson closure_iids "${CLOSURE_IIDS_JSON}" '{
    version:2,
    status:"ready",
    consumer_iid:$consumer_iid,
    work_branch:$work_branch,
    target_branch:$target_branch,
    declared_inputs:$declared_inputs,
    effective_inputs:$effective_inputs,
    closure_iids:$closure_iids,
    aggregate_base_sha:$aggregate_base_sha,
    plan_sha256:$plan_sha256
  }'
