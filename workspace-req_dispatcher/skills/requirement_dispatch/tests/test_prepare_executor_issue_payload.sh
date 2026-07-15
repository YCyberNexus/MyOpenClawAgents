#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

issue_url_input="$(
  GITLAB_HOST='GITLAB-B.PXSEMIC.TECH:30000' \
  MESSAGE='请处理 http://gitlab-b.pxsemic.tech:30000/claw_gitlab/ifp_ui_testing_2/-/issues/42，目标分支：release/2026.07。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${issue_url_input}")" != "success" ]; then
  echo "expected issue URL input to succeed" >&2
  printf '%s\n' "${issue_url_input}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${issue_url_input}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected project extracted from GitLab issue URL" >&2
  printf '%s\n' "${issue_url_input}" >&2
  exit 1
fi

if [ "$(jq -r '.iid' <<<"${issue_url_input}")" != "42" ]; then
  echo "expected iid extracted from GitLab issue URL" >&2
  printf '%s\n' "${issue_url_input}" >&2
  exit 1
fi

if [ "$(jq -r '.issue_url' <<<"${issue_url_input}")" != "http://gitlab-b.pxsemic.tech:30000/claw_gitlab/ifp_ui_testing_2/-/issues/42" ]; then
  echo "expected normalized issue_url without trailing punctuation" >&2
  printf '%s\n' "${issue_url_input}" >&2
  exit 1
fi

if ! jq -e '
  .target_branch == "release/2026.07"
  and .merge_target_branch == "release/2026.07"
  and .auto_merge == false
' <<<"${issue_url_input}" >/dev/null; then
  echo "expected a legacy target-branch phrase to set the MR target without automatic merge" >&2
  printf '%s\n' "${issue_url_input}" >&2
  exit 1
fi

subgroup_issue_url_input="$(
  WIKI_GITLAB_HOST='gitlab.example.com' \
  MESSAGE='请处理 https://gitlab.example.com/platform/agents/runtime/dispatcher/-/issues/42。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
' <<<"${subgroup_issue_url_input}" >/dev/null; then
  echo "expected an issue URL to preserve every project segment before /-/" >&2
  printf '%s\n' "${subgroup_issue_url_input}" >&2
  exit 1
fi

quoted_glab_api_input="$(
  MESSAGE='请执行 `glab api projects/platform%2Fagents%2Fruntime%2Fdispatcher/issues/42`，并处理 issue #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
' <<<"${quoted_glab_api_input}" >/dev/null; then
  echo "expected a code-quoted standalone glab api command to remain explicit" >&2
  printf '%s\n' "${quoted_glab_api_input}" >&2
  exit 1
fi

configured_host_root_url_input="$(
  GITLAB_HOST='code.internal.example:8443' \
  MESSAGE='请处理 https://code.internal.example:8443/platform/agents/runtime/dispatcher.git/?view=files 的 issue #43。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:43}
' <<<"${configured_host_root_url_input}" >/dev/null; then
  echo "expected a configured GitLab repository root URL to preserve and normalize every subgroup" >&2
  printf '%s\n' "${configured_host_root_url_input}" >&2
  exit 1
fi

branch_equals_input="$(
  MESSAGE='branch=sex，请处理 GitLab ai-infra/veqp_server_v3 issue #312。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.target_branch' <<<"${branch_equals_input}")" != "sex" ]; then
  echo "expected branch= syntax to set target_branch sex" >&2
  printf '%s\n' "${branch_equals_input}" >&2
  exit 1
fi

target_branch_equals_input="$(
  MESSAGE='target_branch=release/2026.08，请处理 GitLab ai-infra/veqp_server_v3 issue #312。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .target_branch == "release/2026.08"
  and .merge_target_branch == "release/2026.08"
  and .auto_merge == false
' <<<"${target_branch_equals_input}" >/dev/null; then
  echo "expected legacy target_branch= syntax to set the MR target without automatic merge" >&2
  printf '%s\n' "${target_branch_equals_input}" >&2
  exit 1
fi

target_branch_without_colon_input="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，目标分支 release/2026.08。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .target_branch == "release/2026.08"
  and .merge_target_branch == "release/2026.08"
  and .auto_merge == false
' <<<"${target_branch_without_colon_input}" >/dev/null; then
  echo "expected legacy target-branch wording without a colon to set the MR target without automatic merge" >&2
  printf '%s\n' "${target_branch_without_colon_input}" >&2
  exit 1
fi

merge_to_input="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，合到 release/2026.09。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.target_branch' <<<"${merge_to_input}")" != "release/2026.09" ]; then
  echo "expected merge wording to set target_branch release/2026.09" >&2
  printf '%s\n' "${merge_to_input}" >&2
  exit 1
fi

natural_base_branch="$(
  MESSAGE='请基于“sex”分支开发，处理 GitLab ai-infra/veqp_server_v3 issue #312。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${natural_base_branch}")" != "success" ]; then
  echo "expected natural base-branch input to succeed" >&2
  printf '%s\n' "${natural_base_branch}" >&2
  exit 1
fi

if [ "$(jq -r '.target_branch' <<<"${natural_base_branch}")" != "sex" ]; then
  echo "expected natural base-branch wording to set target_branch sex" >&2
  printf '%s\n' "${natural_base_branch}" >&2
  exit 1
fi

project_hash_input="$(
  MESSAGE='[来自114] 用户wuyun请求：请执行 GitLab ai-infra/veqp_server_v3 issue #312。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${project_hash_input}")" != "success" ]; then
  echo "expected project + issue number input to succeed" >&2
  printf '%s\n' "${project_hash_input}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${project_hash_input}")" != "ai-infra/veqp_server_v3" ]; then
  echo "expected explicit project to be preserved" >&2
  printf '%s\n' "${project_hash_input}" >&2
  exit 1
fi

if [ "$(jq -r '.iid' <<<"${project_hash_input}")" != "312" ]; then
  echo "expected issue number to be extracted from #312" >&2
  printf '%s\n' "${project_hash_input}" >&2
  exit 1
fi

if ! jq -e '.selector == {type:"single",iid:312} and .force_rerun_pr == false' <<<"${project_hash_input}" >/dev/null; then
  echo "expected legacy single-IID input to expose a compatible single selector" >&2
  printf '%s\n' "${project_hash_input}" >&2
  exit 1
fi

encoded_subgroup_api_input="$(
  MESSAGE='请执行 glab api projects/platform%2Fagents%2Fruntime%2Fdispatcher/issues/42，并处理 issue #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
' <<<"${encoded_subgroup_api_input}" >/dev/null; then
  echo "expected an encoded API locator to preserve every subgroup segment" >&2
  printf '%s\n' "${encoded_subgroup_api_input}" >&2
  exit 1
fi

trusted_api_url_input="$(
  GITLAB_HOST='gitlab.example.com' \
  MESSAGE='请处理 https://gitlab.example.com/api/v4/projects/platform%2Fagents%2Fruntime%2Fdispatcher/issues/42 的 issue #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
' <<<"${trusted_api_url_input}" >/dev/null; then
  echo "expected an API URL on the configured GitLab host to yield a project" >&2
  printf '%s\n' "${trusted_api_url_input}" >&2
  exit 1
fi

for untrusted_api_url in \
  'https://evil.example/api/v4/projects/internal%2Fsensitive/issues/42' \
  'https://evil.example/projects/internal%2Fsensitive/issues/42'
do
  untrusted_api_url_input="$(
    GITLAB_HOST='gitlab.example.com' \
    MESSAGE="请处理 ${untrusted_api_url} 的 issue #42" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and .project == null
  ' <<<"${untrusted_api_url_input}" >/dev/null; then
    echo "expected an encoded project inside an untrusted URL to be ignored: ${untrusted_api_url}" >&2
    printf '%s\n' "${untrusted_api_url_input}" >&2
    exit 1
  fi
done

for non_explicit_api_locator in \
  '请处理 projects/internal%2Fsensitive/issues/42 的 issue #42' \
  '请处理 notglab api projects/internal%2Fsensitive/issues/42 的 issue #42'
do
  non_explicit_api_input="$(
    MESSAGE="${non_explicit_api_locator}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '.status == "failed" and .project == null' \
      <<<"${non_explicit_api_input}" >/dev/null; then
    echo "expected only an explicit standalone glab api context to yield an encoded project" >&2
    printf '%s\n' "${non_explicit_api_input}" >&2
    exit 1
  fi
done

range_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 的 issue #100 到 #250' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"range",iid_min:100,iid_max:250} and .iid == null' <<<"${range_json}" >/dev/null; then
  echo "expected an IID range to produce a range selector and null legacy iid" >&2
  printf '%s\n' "${range_json}" >&2
  exit 1
fi

for unsupported_range_message in \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且状态为 failed' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且状态为 timeout' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且状态为 blocked' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且状态为 pr' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且状态为 done' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且状态为 closed' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且 status=FAILED'
do
  unsupported_range_json="$(
    MESSAGE="${unsupported_range_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("single/iid_list/range/open_unfinished/open_label"))
    and (.reason | contains("拆"))
  ' <<<"${unsupported_range_json}" >/dev/null; then
    echo "expected a range plus unsupported status condition to fail closed: ${unsupported_range_message}" >&2
    printf '%s\n' "${unsupported_range_json}" >&2
    exit 1
  fi
done

for conflicting_range_status_message in \
  '处理 ai-infra/veqp_server_v3 的 issue 1 到 3，状态 OPEN，状态 CLOSED' \
  '处理 ai-infra/veqp_server_v3 的 issue 1 到 3，状态 CLOSED，状态 OPEN'
do
  conflicting_range_status_json="$(
    MESSAGE="${conflicting_range_status_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("single/iid_list/range/open_unfinished/open_label"))
  ' <<<"${conflicting_range_status_json}" >/dev/null; then
    echo "expected every range status condition to participate in validation: ${conflicting_range_status_message}" >&2
    printf '%s\n' "${conflicting_range_status_json}" >&2
    exit 1
  fi
done

open_range_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，且 status=OPEN' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .selector == {type:"range",iid_min:10,iid_max:20}
' <<<"${open_range_json}" >/dev/null; then
  echo "expected an explicit OPEN range condition to remain a supported range selector" >&2
  printf '%s\n' "${open_range_json}" >&2
  exit 1
fi

for ambiguous_selector_message in \
  '处理 ai-infra/veqp_server_v3 的 issue #10 到 #20，并处理 #30' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 到 20 以及 30'
do
  ambiguous_selector_json="$(
    MESSAGE="${ambiguous_selector_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("多个不同 issue selector"))
  ' <<<"${ambiguous_selector_json}" >/dev/null; then
    echo "expected conflicting selector evidence to fail: ${ambiguous_selector_message}" >&2
    printf '%s\n' "${ambiguous_selector_json}" >&2
    exit 1
  fi
done

for discrete_iid_message in \
  '处理 ai-infra/veqp_server_v3 的 issue #1,#4,#5' \
  '处理 ai-infra/veqp_server_v3 的 issue #10 和 #20' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 和 20' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 跟 20' \
  '处理 ai-infra/veqp_server_v3 的 issue 10、20' \
  '处理 ai-infra/veqp_server_v3 的 issue #10，并处理 20，并再次确认 30' \
  '处理 ai-infra/veqp_server_v3 的 issue #20、#10、#20'
do
  discrete_iid_json="$(
    MESSAGE="${discrete_iid_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  expected_iids='[10,20]'
  case "${discrete_iid_message}" in
    *'#1,#4,#5'*) expected_iids='[1,4,5]' ;;
    *'确认 30'*) expected_iids='[10,20,30]' ;;
  esac
  if ! jq -e --argjson expected_iids "${expected_iids}" '
    .status == "success"
    and .iid == null
    and .issue_url == null
    and .selector == {type:"iid_list",iids:$expected_iids}
  ' <<<"${discrete_iid_json}" >/dev/null; then
    echo "expected a discrete IID expression to produce one canonical iid_list: ${discrete_iid_message}" >&2
    printf '%s\n' "${discrete_iid_json}" >&2
    exit 1
  fi
done

for alternative_iid_message in \
  '处理 ai-infra/veqp_server_v3 的 issue 10 或 20' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 or 20' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 OR 20'
do
  alternative_iid_json="$(
    MESSAGE="${alternative_iid_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and .selector == null
    and (.reason | contains("或/or"))
  ' <<<"${alternative_iid_json}" >/dev/null; then
    echo "expected an alternative multi-IID expression to fail closed: ${alternative_iid_message}" >&2
    printf '%s\n' "${alternative_iid_json}" >&2
    exit 1
  fi
done

for mixed_typed_selector_message in \
  '处理 ai-infra/veqp_server_v3 中未完成且 label 为 pr 的 issue' \
  '处理 ai-infra/veqp_server_v3 中 label 为 pr 且未完成的 issue' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 到 20，且 label 为 pr' \
  '处理 ai-infra/veqp_server_v3 的 issue 10，且处理未完成的 issue' \
  '处理 ai-infra/veqp_server_v3 的 issue 10，且 label 为 pr' \
  '处理 ai-infra/veqp_server_v3 的 issue 10 到 20，且处理未完成的 issue'
do
  mixed_typed_selector_json="$(
    MESSAGE="${mixed_typed_selector_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and .selector == null
    and (.reason | contains("多个不同 issue selector"))
  ' <<<"${mixed_typed_selector_json}" >/dev/null; then
    echo "expected mixed typed selectors to fail without priority truncation: ${mixed_typed_selector_message}" >&2
    printf '%s\n' "${mixed_typed_selector_json}" >&2
    exit 1
  fi
done

repeated_range_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 的 issue 10 到 20，并再次确认 issue #10 至 #20' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .selector == {type:"range",iid_min:10,iid_max:20}
' <<<"${repeated_range_json}" >/dev/null; then
  echo "expected equivalent repeated range selectors to deduplicate" >&2
  printf '%s\n' "${repeated_range_json}" >&2
  exit 1
fi

repeated_label_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 中 label 为 pr 的 issue，并再次确认 label=pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .selector == {type:"open_label",label:"pr"}
' <<<"${repeated_label_json}" >/dev/null; then
  echo "expected equivalent repeated label selectors to deduplicate" >&2
  printf '%s\n' "${repeated_label_json}" >&2
  exit 1
fi

multiple_label_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 中 label=foo 和 label=bar' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and .selector == null
  and (.reason | contains("多个不同 issue selector"))
' <<<"${multiple_label_json}" >/dev/null; then
  echo "expected multiple label selector expressions joined by prose to fail closed" >&2
  printf '%s\n' "${multiple_label_json}" >&2
  exit 1
fi

repeated_unfinished_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 中未完成的 issue，并再次确认未完成的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .selector == {type:"open_unfinished"}
' <<<"${repeated_unfinished_json}" >/dev/null; then
  echo "expected equivalent repeated unfinished selectors to deduplicate" >&2
  printf '%s\n' "${repeated_unfinished_json}" >&2
  exit 1
fi

for open_modifier_message in \
  '处理 ai-infra/veqp_server_v3 的 issue 10，且状态为 OPEN' \
  '处理 ai-infra/veqp_server_v3 中 label 为 pr 的 issue，且状态为打开'
do
  open_modifier_json="$(
    MESSAGE="${open_modifier_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '.status == "success" and .selector != null' \
      <<<"${open_modifier_json}" >/dev/null; then
    echo "expected an OPEN modifier not to create a second selector: ${open_modifier_message}" >&2
    printf '%s\n' "${open_modifier_json}" >&2
    exit 1
  fi
done

if grep -F 'after = substr(remaining, RSTART + RLENGTH)' \
  "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh" >/dev/null; then
  echo "expected selector evidence scanning not to slice a multibyte tail with awk substr" >&2
  exit 1
fi

selector_context_numbers_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 的 issue #10，branch=release/2026.07，相关文件 src/v20/module.py，使用版本 20' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/veqp_server_v3"
  and .selector == {type:"single",iid:10}
  and .target_branch == "release/2026.07"
' <<<"${selector_context_numbers_json}" >/dev/null; then
  echo "expected branch, file-path, and prose version numbers not to become IID evidence" >&2
  printf '%s\n' "${selector_context_numbers_json}" >&2
  exit 1
fi

repeated_iid_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 的 issue #10，并再次确认 #10' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .selector == {type:"single",iid:10}
' <<<"${repeated_iid_json}" >/dev/null; then
  echo "expected repeated references to the same IID to deduplicate" >&2
  printf '%s\n' "${repeated_iid_json}" >&2
  exit 1
fi

url_and_conflicting_iid_json="$(
  GITLAB_HOST='gitlab.example.com' \
  MESSAGE='处理 https://gitlab.example.com/ai-infra/veqp_server_v3/-/issues/42，并处理 #43' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .issue_url == null
  and .selector == {type:"iid_list",iids:[42,43]}
' <<<"${url_and_conflicting_iid_json}" >/dev/null; then
  echo "expected an issue URL and a different hash IID in one project to form an iid_list" >&2
  printf '%s\n' "${url_and_conflicting_iid_json}" >&2
  exit 1
fi

url_and_bare_conflicting_iid_json="$(
  GITLAB_HOST='gitlab.example.com' \
  MESSAGE='处理 https://gitlab.example.com/ai-infra/veqp_server_v3/-/issues/42，并处理 43' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .issue_url == null
  and .selector == {type:"iid_list",iids:[42,43]}
' <<<"${url_and_bare_conflicting_iid_json}" >/dev/null; then
  echo "expected an issue URL and a different bare IID in one project to form an iid_list" >&2
  printf '%s\n' "${url_and_bare_conflicting_iid_json}" >&2
  exit 1
fi

multiple_issue_urls_json="$(
  GITLAB_HOST='gitlab.example.com' \
  MESSAGE='处理 https://gitlab.example.com/ai-infra/veqp_server_v3/-/issues/42 和 https://gitlab.example.com/ai-infra/veqp_server_v3/-/issues/43' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .issue_url == null
  and .selector == {type:"iid_list",iids:[42,43]}
' <<<"${multiple_issue_urls_json}" >/dev/null; then
  echo "expected multiple distinct issue URLs in one project to form an iid_list" >&2
  printf '%s\n' "${multiple_issue_urls_json}" >&2
  exit 1
fi

same_iid_across_locators_json="$(
  GITLAB_HOST='gitlab.example.com' \
  MESSAGE='处理 https://gitlab.example.com/ai-infra/veqp_server_v3/-/issues/42，并再次确认 issue #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "ai-infra/veqp_server_v3"
  and .selector == {type:"single",iid:42}
' <<<"${same_iid_across_locators_json}" >/dev/null; then
  echo "expected equivalent URL and text IID evidence to deduplicate" >&2
  printf '%s\n' "${same_iid_across_locators_json}" >&2
  exit 1
fi

unfinished_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 中未完成的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_unfinished"} and .iid == null' <<<"${unfinished_json}" >/dev/null; then
  echo "expected unfinished wording to produce an open_unfinished selector" >&2
  printf '%s\n' "${unfinished_json}" >&2
  exit 1
fi

label_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .iid == null and .force_rerun_pr == false' <<<"${label_json}" >/dev/null; then
  echo "expected label wording to produce an open_label selector without forcing rerun" >&2
  printf '%s\n' "${label_json}" >&2
  exit 1
fi

for open_label_message in \
  '处理 ai-infra/veqp_server_v3 中标签为 foo 的 OPEN Issue' \
  '处理 ai-infra/veqp_server_v3 中带标签 foo 的 OPEN Issue'
do
  open_label_json="$(
    MESSAGE="${open_label_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "success"
    and .selector == {type:"open_label",label:"foo"}
  ' <<<"${open_label_json}" >/dev/null; then
    echo "expected OPEN issue wording to preserve only the label value: ${open_label_message}" >&2
    printf '%s\n' "${open_label_json}" >&2
    exit 1
  fi
done

empty_locale_json="$(
  env -i \
    PATH="${PATH}" \
    HOME="${HOME:-/tmp}" \
    LANG= \
    LC_ALL= \
    LC_CTYPE= \
    MESSAGE='处理 ai-infra/veqp_server_v3 中带标签 回归 的 OPEN Issue，目标分支 feature/utf8。' \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/veqp_server_v3"
  and .selector == {type:"open_label",label:"回归"}
  and .target_branch == "feature/utf8"
' <<<"${empty_locale_json}" >/dev/null; then
  echo "expected Chinese parsing to remain correct when the parent process has no locale" >&2
  printf '%s\n' "${empty_locale_json}" >&2
  exit 1
fi

rerun_json="$(
  MESSAGE='重新执行 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == true' <<<"${rerun_json}" >/dev/null; then
  echo "expected explicit rerun wording to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${rerun_json}" >&2
  exit 1
fi

negated_rerun_json="$(
  MESSAGE='不要重跑 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == false' <<<"${negated_rerun_json}" >/dev/null; then
  echo "expected negated rerun wording not to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${negated_rerun_json}" >&2
  exit 1
fi

unneeded_rerun_json="$(
  MESSAGE='无需重新执行 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == false' <<<"${unneeded_rerun_json}" >/dev/null; then
  echo "expected unnecessary rerun wording not to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${unneeded_rerun_json}" >&2
  exit 1
fi

cannot_rerun_json="$(
  MESSAGE='不能重跑 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == false' <<<"${cannot_rerun_json}" >/dev/null; then
  echo "expected cannot-rerun wording not to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${cannot_rerun_json}" >&2
  exit 1
fi

disallowed_rerun_json="$(
  MESSAGE='不允许重新执行 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == false' <<<"${disallowed_rerun_json}" >/dev/null; then
  echo "expected disallowed rerun wording not to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${disallowed_rerun_json}" >&2
  exit 1
fi

rerun_label_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 中 label 为 重跑 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"重跑"} and .force_rerun_pr == false' <<<"${rerun_label_json}" >/dev/null; then
  echo "expected rerun text inside a label selector not to become an action" >&2
  printf '%s\n' "${rerun_label_json}" >&2
  exit 1
fi

explicit_rerun_json="$(
  MESSAGE='请重跑 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == true' <<<"${explicit_rerun_json}" >/dev/null; then
  echo "expected an explicit positive rerun command to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${explicit_rerun_json}" >&2
  exit 1
fi

needed_rerun_json="$(
  MESSAGE='需要重新执行 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == true' <<<"${needed_rerun_json}" >/dev/null; then
  echo "expected an explicit needed-rerun command to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${needed_rerun_json}" >&2
  exit 1
fi

object_before_rerun_json="$(
  MESSAGE='请把 platform/agents/runtime/dispatcher 的 #42 重新执行一下' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
  and .force_rerun_pr == true
' <<<"${object_before_rerun_json}" >/dev/null; then
  echo "expected object-before-action wording to preserve subgroup path and force rerun" >&2
  printf '%s\n' "${object_before_rerun_json}" >&2
  exit 1
fi

object_before_please_rerun_json="$(
  MESSAGE='platform/agents/runtime/dispatcher 的 issue #42 请重跑' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .force_rerun_pr == true
' <<<"${object_before_please_rerun_json}" >/dev/null; then
  echo "expected trailing please-rerun wording to force rerun" >&2
  printf '%s\n' "${object_before_please_rerun_json}" >&2
  exit 1
fi

trailing_negated_rerun_json="$(
  MESSAGE='请把 platform/agents/runtime/dispatcher 的 #42 不要重跑' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .force_rerun_pr == false
' <<<"${trailing_negated_rerun_json}" >/dev/null; then
  echo "expected a trailing negation window to suppress rerun" >&2
  printf '%s\n' "${trailing_negated_rerun_json}" >&2
  exit 1
fi

trailing_unneeded_rerun_json="$(
  MESSAGE='platform/agents/runtime/dispatcher 的 #42 无需重新执行' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .force_rerun_pr == false
' <<<"${trailing_unneeded_rerun_json}" >/dev/null; then
  echo "expected trailing unnecessary wording to suppress rerun" >&2
  printf '%s\n' "${trailing_unneeded_rerun_json}" >&2
  exit 1
fi

trailing_forbidden_rerun_json="$(
  MESSAGE='请把 platform/agents/runtime/dispatcher 的 #42 不得重新执行' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .force_rerun_pr == false
' <<<"${trailing_forbidden_rerun_json}" >/dev/null; then
  echo "expected trailing forbidden wording to suppress rerun" >&2
  printf '%s\n' "${trailing_forbidden_rerun_json}" >&2
  exit 1
fi

for negated_message in \
  '请把 platform/agents/runtime/dispatcher 的 #42 暂不重跑' \
  '请把 platform/agents/runtime/dispatcher 的 #42 并非要重新执行' \
  '请把 platform/agents/runtime/dispatcher 的 #42 不建议重跑'
do
  conservative_negation_json="$(
    MESSAGE="${negated_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"

  if ! jq -e '
    .status == "success"
    and .project == "platform/agents/runtime/dispatcher"
    and .force_rerun_pr == false
  ' <<<"${conservative_negation_json}" >/dev/null; then
    echo "expected broader negative wording not to force rerun: ${negated_message}" >&2
    printf '%s\n' "${conservative_negation_json}" >&2
    exit 1
  fi
done

subgroup_selector_json="$(
  MESSAGE='处理 platform/agents/runtime/dispatcher 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"open_label",label:"pr"}
' <<<"${subgroup_selector_json}" >/dev/null; then
  echo "expected a bare subgroup project to stop safely at the selector boundary" >&2
  printf '%s\n' "${subgroup_selector_json}" >&2
  exit 1
fi

slash_label_selector_json="$(
  MESSAGE='处理 platform/agents/runtime/dispatcher 中 label 为 team/pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"open_label",label:"team/pr"}
' <<<"${slash_label_selector_json}" >/dev/null; then
  echo "expected a slash-containing label value not to become another project" >&2
  printf '%s\n' "${slash_label_selector_json}" >&2
  exit 1
fi

rerun_inside_label_value_json="$(
  MESSAGE='处理 platform/agents/runtime/dispatcher 中 label 为 pr-重新执行 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"open_label",label:"pr-重新执行"}
  and .force_rerun_pr == false
' <<<"${rerun_inside_label_value_json}" >/dev/null; then
  echo "expected rerun wording inside a label value not to become an action" >&2
  printf '%s\n' "${rerun_inside_label_value_json}" >&2
  exit 1
fi

rerun_inside_branch_value_json="$(
  MESSAGE='处理 platform/agents/runtime/dispatcher 的 #42，branch=feature/重新执行' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
  and .target_branch == "feature/重新执行"
  and .force_rerun_pr == false
' <<<"${rerun_inside_branch_value_json}" >/dev/null; then
  echo "expected rerun wording inside a branch value not to become an action" >&2
  printf '%s\n' "${rerun_inside_branch_value_json}" >&2
  exit 1
fi

natural_quoted_branch_json="$(
  MESSAGE='请基于‘feature/重新执行’分支处理 platform/agents/runtime/dispatcher 的 #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
  and .target_branch == "feature/重新执行"
  and .force_rerun_pr == false
' <<<"${natural_quoted_branch_json}" >/dev/null; then
  echo "expected a quoted natural-language branch to share extraction and stripping boundaries" >&2
  printf '%s\n' "${natural_quoted_branch_json}" >&2
  exit 1
fi

same_project_all_locators_json="$(
  GITLAB_HOST='code.internal.example' \
  MESSAGE='请处理 https://code.internal.example/platform/agents/runtime/dispatcher/-/issues/42，并参考 https://code.internal.example/platform/agents/runtime/dispatcher/、projects/platform%2Fagents%2Fruntime%2Fdispatcher/issues/42 与 platform/agents/runtime/dispatcher。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "success"
  and .project == "platform/agents/runtime/dispatcher"
  and .selector == {type:"single",iid:42}
' <<<"${same_project_all_locators_json}" >/dev/null; then
  echo "expected equivalent project locators to normalize and deduplicate" >&2
  printf '%s\n' "${same_project_all_locators_json}" >&2
  exit 1
fi

for mixed_project_message in \
  '请处理 https://gitlab.example.com/platform/agents/runtime/dispatcher/-/issues/42，同时参考 platform/agents/runtime/executor' \
  '请处理 https://gitlab.example.com/platform/agents/runtime/dispatcher 的 issue #42，同时参考 platform/agents/runtime/executor' \
  '请执行 glab api projects/platform%2Fagents%2Fruntime%2Fdispatcher/issues/42，同时参考 platform/agents/runtime/executor 的 issue #42'
do
  mixed_project_json="$(
    GITLAB_HOST='gitlab.example.com' \
    MESSAGE="${mixed_project_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("多个 GitLab project"))
  ' <<<"${mixed_project_json}" >/dev/null; then
    echo "expected every distinct locator source to participate in project ambiguity checks" >&2
    printf '%s\n' "${mixed_project_json}" >&2
    exit 1
  fi
done

ambiguous_project_json="$(
  MESSAGE='请处理 platform/agents/runtime/dispatcher 或 platform/agents/runtime/executor 的 issue #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '
  .status == "failed"
  and (.reason | contains("多个 GitLab project"))
' <<<"${ambiguous_project_json}" >/dev/null; then
  echo "expected multiple bare project paths to fail for clarification" >&2
  printf '%s\n' "${ambiguous_project_json}" >&2
  exit 1
fi

for file_reference_message in \
  '处理 ai-infra/veqp_server_v3 的 issue #42，请参考 docs/design/spec.md' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，相关文件 src/main/app.py' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，请参考 docs/spec.md' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，相关文件 src/app.py' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，请参考目录 docs/design' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，相关目录 src/main' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，请参考 config/settings.yaml' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，相关脚本 scripts/check.sh' \
  '处理 ai-infra/veqp_server_v3 的 issue #42，相关类型 lib/types.ts'
do
  file_reference_json="$(
    MESSAGE="${file_reference_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "success"
    and .project == "ai-infra/veqp_server_v3"
    and .selector == {type:"single",iid:42}
  ' <<<"${file_reference_json}" >/dev/null; then
    echo "expected an ordinary local file path not to become a project: ${file_reference_message}" >&2
    printf '%s\n' "${file_reference_json}" >&2
    exit 1
  fi
done

src_group_project_json="$(
  MESSAGE='处理 GitLab src/team 的 issue #42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "src/team"
  and .selector == {type:"single",iid:42}
' <<<"${src_group_project_json}" >/dev/null; then
  echo "expected an explicit src namespace project not to be mistaken for a local path" >&2
  printf '%s\n' "${src_group_project_json}" >&2
  exit 1
fi

for dot_segment_message in \
  '处理 group/../secret 的 issue #42' \
  '执行 glab api projects/group%2F..%2Fsecret/issues/42 的 issue #42' \
  '处理 https://gitlab.example.com/group/../secret/-/issues/42'
do
  dot_segment_json="$(
    GITLAB_HOST='gitlab.example.com' \
    MESSAGE="${dot_segment_message}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("project path"))
  ' <<<"${dot_segment_json}" >/dev/null; then
    echo "expected project dot segments to fail intake: ${dot_segment_message}" >&2
    printf '%s\n' "${dot_segment_json}" >&2
    exit 1
  fi
done

missing_iid="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 的 issue。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${missing_iid}")" != "failed" ]; then
  echo "expected execution request without iid to fail" >&2
  printf '%s\n' "${missing_iid}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${missing_iid}" | grep -q 'issue IID'; then
  echo "expected missing-iid reason to ask for issue IID or issue URL" >&2
  printf '%s\n' "${missing_iid}" >&2
  exit 1
fi

missing_project="$(
  MESSAGE='请处理 issue #312。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${missing_project}")" != "failed" ]; then
  echo "expected execution request without project to fail" >&2
  printf '%s\n' "${missing_project}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${missing_project}" | grep -q 'group/project'; then
  echo "expected missing-project reason to ask for group/project or issue URL" >&2
  printf '%s\n' "${missing_project}" >&2
  exit 1
fi

invalid_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=../bad。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${invalid_branch}")" != "failed" ]; then
  echo "expected invalid branch to fail" >&2
  printf '%s\n' "${invalid_branch}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${invalid_branch}" | grep -q 'safe Git ref'; then
  echo "expected invalid branch reason to mention safe Git ref" >&2
  printf '%s\n' "${invalid_branch}" >&2
  exit 1
fi

leading_dash_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=-c。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${leading_dash_branch}")" != "failed" ]; then
  echo "expected leading-dash branch to fail" >&2
  printf '%s\n' "${leading_dash_branch}" >&2
  exit 1
fi

semicolon_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=release;evil。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${semicolon_branch}")" != "failed" ]; then
  echo "expected semicolon branch to fail instead of truncating" >&2
  printf '%s\n' "${semicolon_branch}" >&2
  exit 1
fi

semicolon_space_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=release; evil。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${semicolon_space_branch}")" != "failed" ]; then
  echo "expected semicolon-space branch to fail instead of trimming semicolon" >&2
  printf '%s\n' "${semicolon_space_branch}" >&2
  exit 1
fi

semicolon_after_space_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=release ;evil。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${semicolon_after_space_branch}")" != "failed" ]; then
  echo "expected branch with spaced semicolon tail to fail instead of truncating" >&2
  printf '%s\n' "${semicolon_after_space_branch}" >&2
  exit 1
fi

bracket_tail_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，target_branch=feature [bad]。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${bracket_tail_branch}")" != "failed" ]; then
  echo "expected branch with bracket tail to fail instead of truncating" >&2
  printf '%s\n' "${bracket_tail_branch}" >&2
  exit 1
fi

space_branch="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，target_branch=feature space。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${space_branch}")" != "failed" ]; then
  echo "expected branch containing spaces to fail instead of truncating" >&2
  printf '%s\n' "${space_branch}" >&2
  exit 1
fi

space_project_url="$(
  GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
  MESSAGE='请处理 http://gitlab-b.pxsemic.tech:30000/claw_gitlab%20bad/ifp_ui_testing_2/-/issues/42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${space_project_url}")" != "failed" ]; then
  echo "expected decoded project path containing spaces to fail" >&2
  printf '%s\n' "${space_project_url}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${space_project_url}" | grep -q 'project path'; then
  echo "expected decoded-space project reason to mention project path" >&2
  printf '%s\n' "${space_project_url}" >&2
  exit 1
fi

bad_percent_url="$(
  GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
  MESSAGE='请处理 http://gitlab-b.pxsemic.tech:30000/claw_gitlab%GG/ifp_ui_testing_2/-/issues/42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${bad_percent_url}")" != "failed" ]; then
  echo "expected malformed percent encoding in project path to fail" >&2
  printf '%s\n' "${bad_percent_url}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${bad_percent_url}" | grep -q 'project path'; then
  echo "expected malformed-percent project reason to mention project path" >&2
  printf '%s\n' "${bad_percent_url}" >&2
  exit 1
fi

encoded_space_project="$(
  MESSAGE='请执行 glab api projects/ai-infra%20bad%2Fveqp_server_v3/issues/12 issue #12' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${encoded_space_project}")" != "failed" ]; then
  echo "expected decoded fallback project path containing spaces to fail" >&2
  printf '%s\n' "${encoded_space_project}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${encoded_space_project}" | grep -q 'project path'; then
  echo "expected decoded fallback project reason to mention project path" >&2
  printf '%s\n' "${encoded_space_project}" >&2
  exit 1
fi

non_gitlab_host_url="$(
  GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
  MESSAGE='请处理 http://docs.example.com/claw_gitlab/ifp_ui_testing_2/-/issues/42' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if [ "$(jq -r '.status' <<<"${non_gitlab_host_url}")" != "failed" ]; then
  echo "expected issue_url host without gitlab to fail" >&2
  printf '%s\n' "${non_gitlab_host_url}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${non_gitlab_host_url}" | grep -q 'GitLab host'; then
  echo "expected non-gitlab host reason to mention GitLab host" >&2
  printf '%s\n' "${non_gitlab_host_url}" >&2
  exit 1
fi

for attacker_host in \
  'gitlab.attacker.example' \
  'evil-gitlab.com' \
  'gitlab-b.pxsemic.tech.evil.example'
do
  attacker_host_json="$(
    GITLAB_HOST='gitlab-b.pxsemic.tech:30000' \
    MESSAGE="请处理 https://${attacker_host}/claw_gitlab/ifp_ui_testing_2/-/issues/42" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("GitLab host"))
  ' <<<"${attacker_host_json}" >/dev/null; then
    echo "expected lookalike GitLab host to fail exact host validation: ${attacker_host}" >&2
    printf '%s\n' "${attacker_host_json}" >&2
    exit 1
  fi
done

explicit_auto_merge_json="$(
  MESSAGE='请基于 develop 分支处理 GitLab ai-infra/veqp_server_v3 issue #312，执行完成后直接merge到release/2026.07分支。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "develop"
  and .auto_merge == true
  and .merge_target_branch == "release/2026.07"
' <<<"${explicit_auto_merge_json}" >/dev/null; then
  echo "expected an explicit automatic merge target to remain distinct from the base branch" >&2
  printf '%s\n' "${explicit_auto_merge_json}" >&2
  exit 1
fi

create_and_execute_auto_merge_json="$(
  GITLAB_HOST=gitlab.example.test \
  MESSAGE=$'请在 GitLab ai-infra/veqp_server_v3 创建 Issue 并执行，基于 develop 分支处理，完成后直接 merge 到 release/2026.07。\n创建结果 issue_url=https://gitlab.example.test/ai-infra/veqp_server_v3/-/issues/313' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .project == "ai-infra/veqp_server_v3"
  and .selector == {type:"single",iid:313}
  and .target_branch == "develop"
  and .auto_merge == true
  and .merge_target_branch == "release/2026.07"
' <<<"${create_and_execute_auto_merge_json}" >/dev/null; then
  echo "expected create_and_execute to preserve automatic-merge intent beside the new issue URL" >&2
  printf '%s\n' "${create_and_execute_auto_merge_json}" >&2
  exit 1
fi

target_branch_alias_auto_merge_json="$(
  MESSAGE='请基于 develop 分支开发并处理 GitLab ai-infra/veqp_server_v3 issue #312，target_branch=release，完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "develop"
  and .auto_merge == true
  and .merge_target_branch == "release"
' <<<"${target_branch_alias_auto_merge_json}" >/dev/null; then
  echo "expected target_branch= to remain the MR target beside an explicit processing base" >&2
  printf '%s\n' "${target_branch_alias_auto_merge_json}" >&2
  exit 1
fi

natural_target_auto_merge_json="$(
  MESSAGE='请基于 develop 分支开发并处理 GitLab ai-infra/veqp_server_v3 issue #312，目标分支：release，完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "develop"
  and .auto_merge == true
  and .merge_target_branch == "release"
' <<<"${natural_target_auto_merge_json}" >/dev/null; then
  echo "expected the Chinese target-branch phrase to remain the MR target beside an explicit processing base" >&2
  printf '%s\n' "${natural_target_auto_merge_json}" >&2
  exit 1
fi

base_fallback_auto_merge_json="$(
  MESSAGE='请基于 develop 分支处理 GitLab ai-infra/veqp_server_v3 issue #312，执行完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "develop"
  and .auto_merge == true
  and .merge_target_branch == "develop"
' <<<"${base_fallback_auto_merge_json}" >/dev/null; then
  echo "expected automatic merge without an explicit target to use the base branch" >&2
  printf '%s\n' "${base_fallback_auto_merge_json}" >&2
  exit 1
fi

master_fallback_auto_merge_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，执行完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "master"
  and .auto_merge == true
  and .merge_target_branch == "master"
' <<<"${master_fallback_auto_merge_json}" >/dev/null; then
  echo "expected automatic merge without either branch to default to master" >&2
  printf '%s\n' "${master_fallback_auto_merge_json}" >&2
  exit 1
fi

for merge_feature_discussion in \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，修复自动合并失败的问题。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，排查直接 merge 按钮为何失效。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，修复 auto_merge=true 解析失败的问题。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，文档中补充 auto_merge=true 示例。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，修复“完成后直接 merge”功能失效的问题。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，排查完成后直接 merge 按钮。'
do
  merge_feature_discussion_json="$(
    MESSAGE="${merge_feature_discussion}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '.status == "success" and .auto_merge == false' \
      <<<"${merge_feature_discussion_json}" >/dev/null; then
    echo "expected discussion of a merge feature not to enable automatic merge: ${merge_feature_discussion}" >&2
    printf '%s\n' "${merge_feature_discussion_json}" >&2
    exit 1
  fi
done

legacy_merge_target_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，合到 release/2026.07。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "release/2026.07"
  and .auto_merge == false
  and .merge_target_branch == "release/2026.07"
' <<<"${legacy_merge_target_json}" >/dev/null; then
  echo "expected a legacy merge-target phrase without completion intent to keep review-only behavior" >&2
  printf '%s\n' "${legacy_merge_target_json}" >&2
  exit 1
fi

negated_auto_merge_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，不要直接 merge 到 main。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '.status == "success" and .auto_merge == false' <<<"${negated_auto_merge_json}" >/dev/null; then
  echo "expected a negated automatic merge instruction not to enable automatic merge" >&2
  printf '%s\n' "${negated_auto_merge_json}" >&2
  exit 1
fi

single_character_negated_direct_merge_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，完成后不直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '.status == "success" and .auto_merge == false' \
    <<<"${single_character_negated_direct_merge_json}" >/dev/null; then
  echo "expected a single-character negation before direct merge to disable automatic merge" >&2
  printf '%s\n' "${single_character_negated_direct_merge_json}" >&2
  exit 1
fi

single_character_negated_auto_merge_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，不自动合并。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '.status == "success" and .auto_merge == false' \
    <<<"${single_character_negated_auto_merge_json}" >/dev/null; then
  echo "expected a single-character negation before automatic merge to disable automatic merge" >&2
  printf '%s\n' "${single_character_negated_auto_merge_json}" >&2
  exit 1
fi

ambiguous_double_negation_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，不是不需要自动合并。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '.status == "success" and .auto_merge == false' \
    <<<"${ambiguous_double_negation_json}" >/dev/null; then
  echo "expected ambiguous double negation to fail closed for automatic merge" >&2
  printf '%s\n' "${ambiguous_double_negation_json}" >&2
  exit 1
fi

for mixed_auto_merge_instruction in \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，完成后直接 merge；但不要自动合并。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，不要自动合并；完成后直接 merge。' \
  '请处理 GitLab ai-infra/veqp_server_v3 issue #312，原计划完成后直接 merge，不过现在不自动合并。'
do
  mixed_auto_merge_json="$(
    MESSAGE="${mixed_auto_merge_instruction}" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '.status == "success" and .auto_merge == false' \
      <<<"${mixed_auto_merge_json}" >/dev/null; then
    echo "expected any explicit merge negation to disable automatic merge: ${mixed_auto_merge_instruction}" >&2
    printf '%s\n' "${mixed_auto_merge_json}" >&2
    exit 1
  fi
done

conflicting_merge_targets_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，target_branch=release/old，完成后直接 merge 到 release/new。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("conflicting merge target branches"))
' <<<"${conflicting_merge_targets_json}" >/dev/null; then
  echo "expected different explicitly named merge targets to fail closed" >&2
  printf '%s\n' "${conflicting_merge_targets_json}" >&2
  exit 1
fi

corrected_merge_target_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，目标分支 release，改为 main，完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("conflicting merge target branches"))
' <<<"${corrected_merge_target_json}" >/dev/null; then
  echo "expected an abbreviated correction to a merge target to fail closed" >&2
  printf '%s\n' "${corrected_merge_target_json}" >&2
  exit 1
fi

corrected_base_branch_json="$(
  MESSAGE='请基于 develop 分支处理 GitLab ai-infra/veqp_server_v3 issue #312，改为基于 main 分支，完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("conflicting processing branches"))
' <<<"${corrected_base_branch_json}" >/dev/null; then
  echo "expected different explicitly named processing branches to fail closed" >&2
  printf '%s\n' "${corrected_base_branch_json}" >&2
  exit 1
fi

abbreviated_corrected_base_branch_json="$(
  MESSAGE='请基于 develop 分支处理 GitLab ai-infra/veqp_server_v3 issue #312，改为 main 分支，完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("conflicting processing branches"))
' <<<"${abbreviated_corrected_base_branch_json}" >/dev/null; then
  echo "expected an abbreviated processing-branch correction to fail closed" >&2
  printf '%s\n' "${abbreviated_corrected_base_branch_json}" >&2
  exit 1
fi

duplicate_merge_target_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，target_branch=release，完成后直接 merge 到 release。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .auto_merge == true
  and .merge_target_branch == "release"
' <<<"${duplicate_merge_target_json}" >/dev/null; then
  echo "expected duplicate references to the same merge target to remain valid" >&2
  printf '%s\n' "${duplicate_merge_target_json}" >&2
  exit 1
fi

compact_branch_fields_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=develop target_branch=release 完成后merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "develop"
  and .merge_target_branch == "release"
  and .auto_merge == true
' <<<"${compact_branch_fields_json}" >/dev/null; then
  echo "expected adjacent recognized branch directives to remain unambiguous" >&2
  printf '%s\n' "${compact_branch_fields_json}" >&2
  exit 1
fi

semicolon_separated_merge_fields_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=develop；target_branch=release；完成后merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "develop"
  and .merge_target_branch == "release"
  and .auto_merge == true
' <<<"${semicolon_separated_merge_fields_json}" >/dev/null; then
  echo "expected semicolons followed by recognized directives to remain valid" >&2
  printf '%s\n' "${semicolon_separated_merge_fields_json}" >&2
  exit 1
fi

unsafe_backtick_base_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，branch=feature/`id`。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("safe Git ref"))
' <<<"${unsafe_backtick_base_json}" >/dev/null; then
  echo "expected a backtick-bearing base branch to fail closed" >&2
  printf '%s\n' "${unsafe_backtick_base_json}" >&2
  exit 1
fi

unsafe_backtick_merge_target_json="$(
  MESSAGE='请处理 GitLab ai-infra/veqp_server_v3 issue #312，执行完成后直接 merge 到 feature/`id`。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "failed"
  and (.reason | contains("safe Git ref"))
' <<<"${unsafe_backtick_merge_target_json}" >/dev/null; then
  echo "expected a backtick-bearing merge target branch to fail closed" >&2
  printf '%s\n' "${unsafe_backtick_merge_target_json}" >&2
  exit 1
fi

for unsafe_assignment_merge_target in \
  'target_branch=feature [bad]' \
  'target_branch=release;evil' \
  'target_branch=release; evil' \
  'target_branch=release ;evil'
do
  unsafe_assignment_merge_target_json="$(
    MESSAGE="请处理 GitLab ai-infra/veqp_server_v3 issue #312，${unsafe_assignment_merge_target}，完成后直接 merge。" \
    bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
  )"
  if ! jq -e '
    .status == "failed"
    and (.reason | contains("safe Git ref"))
  ' <<<"${unsafe_assignment_merge_target_json}" >/dev/null; then
    echo "expected an unsafe assignment-style merge target to fail closed: ${unsafe_assignment_merge_target}" >&2
    printf '%s\n' "${unsafe_assignment_merge_target_json}" >&2
    exit 1
  fi
done

common_branch_json="$(
  MESSAGE='请基于 feature/foo-1.2 分支处理 GitLab ai-infra/veqp_server_v3 issue #312，执行完成后直接 merge。' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"
if ! jq -e '
  .status == "success"
  and .target_branch == "feature/foo-1.2"
  and .auto_merge == true
  and .merge_target_branch == "feature/foo-1.2"
' <<<"${common_branch_json}" >/dev/null; then
  echo "expected common slash, dash, and dot branch characters to remain valid" >&2
  printf '%s\n' "${common_branch_json}" >&2
  exit 1
fi

echo "ok prepare_executor_issue_payload extracts existing issue execution input"
