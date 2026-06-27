#!/usr/bin/env bash
# post_result_note.sh — best-effort 测试结果回报 (result_notify_loop.md, option A).
#
# 在 Phase 6 终态由 dispatch_followup.sh 调用（仅当 campaign_state.result_note_enabled
# 为 true，且 final_status ∈ {done,failed,timeout}）。读 issue 上由 git_issuer 写的
# req_origin 标记（G1b），若存在则在该 issue 上发一条结构化 req_result note（G9），供
# 114 轮询/webhook 拿到后投递给发起需求的企微用户。
#
# 设计为 best-effort：调用方用 `set +e` 隔离并忽略其退出码，所以本脚本失败绝不
# 影响 Phase 6。它**只**做 glab 读/发 note，不写任何 state 文件、不打标签、不碰 MR。
#
# 仅当 issue 上确有 req_origin 标记时才发 req_result——避免给非本链路 issue 刷通知；
# git_issuer 尚未写 origin 时也自然 no-op。
#
# 入参（env）：
#   PROJECT, GROUP, GITLAB_TOKEN        (env_paths.sh → glab_auth.sh 鉴权 + PROJECT_URI)
#   REPO_PARENT_PATH / RESULT_BASENAME / DATA_BASENAME  (env_paths.sh，随调用方透传)
#   IID                                  目标 issue IID（正整数）
#   FINAL_STATUS                         done | failed | timeout
# 可选：
#   MR_URL                               成功时的 MR URL
#   BLOCK_REASON                         失败/超时原因
#   ATTEMPT_NUMBER                       用于幂等（同一 attempt 不重复发）
set -euo pipefail

# 与其它自包含 glab 脚本一致：source env_paths.sh 即完成 glab 鉴权并导出 PROJECT_URI。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${PROJECT_URI:?run scripts/glab_auth.sh first}"
: "${IID:?post_result_note: IID required}"
: "${FINAL_STATUS:?post_result_note: FINAL_STATUS required}"
case "${IID}" in *[!0-9]*|"") echo "post_result_note: IID must be a positive integer, got: ${IID}" >&2; exit 2 ;; esac
case "${FINAL_STATUS}" in
  done|failed|timeout) ;;
  *) echo "post_result_note: FINAL_STATUS must be done|failed|timeout, got: ${FINAL_STATUS}" >&2; exit 2 ;;
esac
MR_URL="${MR_URL:-}"
WIKI_URL="${WIKI_URL:-}"
BLOCK_REASON="${BLOCK_REASON:-}"
ATTEMPT_NUMBER="${ATTEMPT_NUMBER:-}"

# 1) G1b — 读 issue notes，取最后一条 req_origin 标记里的 JSON 负载。
NOTES_JSON="$(glab api --paginate "projects/${PROJECT_URI}/issues/${IID}/notes?sort=asc&order_by=created_at")"

ORIGIN_NODE="$(printf '%s' "${NOTES_JSON}" | jq -c '
  [ .[] | select(.system == false) | .body
    | (capture("req_origin v1 *(?<j>\\{.*\\}) *-->")?).j
    | select(. != null)
    | (fromjson? // empty) ]
  | last // null')"

# 仅当确有可解析的 req_origin 才回报；否则 no-op（非本链路 issue / git_issuer 未写）。
if [ "${ORIGIN_NODE}" = "null" ] || [ -z "${ORIGIN_NODE}" ]; then
  echo "post_result_note: no parseable req_origin marker on #${IID}; skip" >&2
  exit 0
fi

# 幂等：同一 attempt 已发过 req_result 就跳过（跨 attempt 不去重——续测成功该再报一次）。
if [ -n "${ATTEMPT_NUMBER}" ]; then
  if printf '%s' "${NOTES_JSON}" | jq -e --arg a "${ATTEMPT_NUMBER}" '
      any(.[]; (.system == false)
        and (.body | test("req_result v1 [^>]*\"attempt\":" + $a + "[,}]")))' >/dev/null 2>&1; then
    echo "post_result_note: req_result for #${IID} attempt=${ATTEMPT_NUMBER} already present; skip" >&2
    exit 0
  fi
fi

# 2) 拼 req_result note：第一行隐藏标记（114 解析）+ 一行人读摘要。
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ATTEMPT_JSON="null"
case "${ATTEMPT_NUMBER}" in ''|*[!0-9]*) ATTEMPT_JSON="null" ;; *) ATTEMPT_JSON="${ATTEMPT_NUMBER}" ;; esac

RESULT_PAYLOAD="$(jq -nc \
  --argjson iid "${IID}" \
  --arg status "${FINAL_STATUS}" \
  --arg mr_url "${MR_URL}" \
  --arg wiki_url "${WIKI_URL}" \
  --arg reason "${BLOCK_REASON}" \
  --argjson attempt "${ATTEMPT_JSON}" \
  --arg ts "${TS}" \
  --argjson origin "${ORIGIN_NODE}" '
  {iid:$iid, status:$status, attempt:$attempt,
   mr_url:($mr_url|select(.!="")//null),
   wiki_url:($wiki_url|select(.!="")//null),
   reason:($reason|select(.!="")//null),
   ts:$ts, origin:$origin}')"

BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT
{
  printf '<!-- req_result v1 %s -->\n' "${RESULT_PAYLOAD}"
  case "${FINAL_STATUS}" in
    done)
      printf '✅ 自动测试完成：issue #%s。' "${IID}"
      [ -n "${MR_URL}" ] && printf 'MR：%s' "${MR_URL}"
      printf '\n'
      ;;
    failed)
      printf '❌ 自动测试未通过：issue #%s。' "${IID}"
      [ -n "${BLOCK_REASON}" ] && printf '原因：%s' "${BLOCK_REASON}"
      printf '\n'
      ;;
    timeout)
      printf '⏱️ 自动测试超时未完成：issue #%s（已停放待人工处理）。\n' "${IID}"
      ;;
  esac
} > "${BODY_FILE}"

# 3) G9 — 发 note（-F body=@file 避免多行/JSON 的引号问题）。
glab api --method POST "projects/${PROJECT_URI}/issues/${IID}/notes" -F "body=@${BODY_FILE}" >/dev/null
echo "post_result_note: req_result posted iid=${IID} status=${FINAL_STATUS} attempt=${ATTEMPT_NUMBER:-?}" >&2
