#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

issue_url_input="$(
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

if [ "$(jq -r '.target_branch' <<<"${issue_url_input}")" != "release/2026.07" ]; then
  echo "expected target_branch extracted from execution request" >&2
  printf '%s\n' "${issue_url_input}" >&2
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

if [ "$(jq -r '.target_branch' <<<"${target_branch_equals_input}")" != "release/2026.08" ]; then
  echo "expected target_branch= syntax to set target_branch release/2026.08" >&2
  printf '%s\n' "${target_branch_equals_input}" >&2
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

range_json="$(
  MESSAGE='处理 ai-infra/veqp_server_v3 的 issue #100 到 #250' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"range",iid_min:100,iid_max:250} and .iid == null' <<<"${range_json}" >/dev/null; then
  echo "expected an IID range to produce a range selector and null legacy iid" >&2
  printf '%s\n' "${range_json}" >&2
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

rerun_json="$(
  MESSAGE='重新执行 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' \
  bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh"
)"

if ! jq -e '.status == "success" and .selector == {type:"open_label",label:"pr"} and .force_rerun_pr == true' <<<"${rerun_json}" >/dev/null; then
  echo "expected explicit rerun wording to force rerunning pr-labelled issues" >&2
  printf '%s\n' "${rerun_json}" >&2
  exit 1
fi

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

echo "ok prepare_executor_issue_payload extracts existing issue execution input"
