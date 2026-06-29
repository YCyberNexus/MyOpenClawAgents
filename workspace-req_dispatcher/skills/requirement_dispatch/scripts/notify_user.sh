#!/usr/bin/env bash
# notify_user.sh — best-effort 把测试结果/失败结论推回企微发起人（origin）。
#
# 由 orchestrator 在 executor 回调路径终态（result：done/failed/timeout 推结论）或
# git_issuer 回调失败 / 路由查不到 / executor spawn 耗尽等失败路径（failure）调用，
# 在 drain/ledger 写入之后执行。这是 req_dispatcher 首次主动给用户推「实质结论」
# （受理 ack 之外）——见设计稿 §4.3/§4.5。
#
# 与薄派发器红线不冲突：本脚本只经出站通道把一句人读文案投回 origin，**不碰 GitLab、
# 不建 issue、不打标签、不解析需求**。出站通道（企微回投 / 经 114）属待对齐项（设计稿
# §9.2），当前为显式 gated 占位：通道未配置则记 ledger 留痕、配置后落 user_notify.jsonl，
# 真正的跨通道 send 原语待对齐后替换（见下方 TODO）。
#
# best-effort 语义（仿 ops_notify.sh / acpx post_result_note.sh）：推送是终态锦上添花，
# 绝不能让回调路径因「推用户」再失败、也绝不静默丢结论（结论由 pending/ledger 兜底）：
#   - USER_NOTIFY_CHANNEL 为空 → 不推，但**记一条 ledger 留痕**（user_notify_skipped），
#     exit 0（config：留空则不推用户；留痕保证「漏推」可审计、不静默丢）。
#   - 通道已配置 → 拼文案 + 落 ${LOG_DIR}/user_notify.jsonl，exit 0（占位实现；
#     真正出站 send 待对齐）。
#   - 缺 EVENT（必填未给）→ exit 1（调用方 bug，与兄弟脚本 :? 惯例一致）。
#   - 仅「部署配置形态错误」（EVENT 非法）→ exit 2，让运维知道配错了
#     （这不属 best-effort 范畴，是调用点/部署期写错）。
#
# 入参（env）：
#   EVENT               必填：result | failure
#   USER_NOTIFY_CHANNEL 出站通道标识（待对齐形态）；空＝不推、仅 ledger 留痕。
#                       来自 config/dispatcher.env（调用方 source 后透传）。
# 可选：
#   STATUS              done | failed | timeout（result 事件据此选文案；其它值按通用文案）
#   IID                 issue IID（拼入文案）
#   MR_URL              done 文案的 MR 链接
#   WIKI_URL            failed 文案的证据链接
#   REASON              failed 文案的原因摘要 / failure 事件的失败说明
#   ORIGIN_JSON         origin 元数据（channel/user/conversation）紧凑 JSON；原样留痕，
#                       供出站通道对齐后据此定向投递。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${EVENT:?notify_user: EVENT required}"
case "${EVENT}" in
  result|failure) ;;
  *) echo "notify_user: EVENT must be result|failure, got: ${EVENT}" >&2; exit 2 ;;
esac

CHANNEL="${USER_NOTIFY_CHANNEL:-}"
STATUS="${STATUS:-}"
IID="${IID:-}"
MR_URL="${MR_URL:-}"
WIKI_URL="${WIKI_URL:-}"
REASON="${REASON:-}"
ORIGIN_JSON="${ORIGIN_JSON:-}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# IID 前缀：有则用 "#<iid>"，无则退化为通用「测试」。文案与设计稿 §4.3 逐字一致。
issue_ref="测试"
[ -n "${IID}" ] && issue_ref="#${IID}"

# 拼人读文案（CONTENT）。result 事件按 STATUS 三态映射；failure 事件给通用失败说明。
if [ "${EVENT}" = "result" ]; then
  case "${STATUS}" in
    done)    CONTENT="${issue_ref} 测试完成，MR：${MR_URL}" ;;
    failed)
      CONTENT="${issue_ref} 测试未通过：${REASON:-未说明原因}"
      # 失败路径通常不发 Wiki（WIKI_URL 常为空）——仅当确有证据链接才追加，避免「证据见 」尾随空。
      [ -n "${WIKI_URL}" ] && CONTENT="${CONTENT}，证据见 ${WIKI_URL}"
      ;;
    timeout) CONTENT="${issue_ref} 测试超时未完成，已停放待人工处理" ;;
    # result 事件理应带 done/failed/timeout 之一；缺/异常 STATUS 不致命（best-effort），
    # 退化为通用结论 + 留痕，绝不静默丢。
    *)       CONTENT="${issue_ref} 测试已结束（status=${STATUS:-?}）" ;;
  esac
else
  # failure 事件：建 issue 失败 / 路由未接入 / 启动测试失败等流程性失败统一推这句。
  CONTENT="${issue_ref} 流程未能完成：${REASON:-未知原因}"
fi

# 缺 jq → best-effort 跳过，不阻断回调路径。jq 虽是全脚本硬依赖（上游 drain/record 必先
# 用到、缺则在那里就先致命），这里仍自守，使 best-effort 不变量不依赖调用顺序假设。
if ! command -v jq >/dev/null 2>&1; then
  echo "notify_user: jq not found; skip (event=${EVENT} iid=${IID:-?})" >&2
  exit 0
fi

# 安全求值 origin：ORIGIN_JSON 由上游（114→orchestrator）透传，可能为空 / 合法 JSON /
# 畸形。best-effort 下绝不能因 origin 畸形而丢结论——空→null；合法 JSON→原样；
# 畸形→降级为 {raw:"<原文>"} 字符串包装并 warn，仍照常留痕。
if [ -z "${ORIGIN_JSON}" ]; then
  ORIGIN_ARG='null'
elif printf '%s' "${ORIGIN_JSON}" | jq empty >/dev/null 2>&1; then
  # 用 `jq empty`（仅按解析成败设退出码）判 ORIGIN_JSON 是否合法 JSON，而非 `jq -e .`
  # （后者按 filter 输出真值设退出码，会把合法的 false/null 标量误判为非法）。
  ORIGIN_ARG="${ORIGIN_JSON}"
else
  echo "notify_user: ORIGIN_JSON not valid JSON; wrapping as raw (event=${EVENT})" >&2
  ORIGIN_ARG="$(jq -nc --arg raw "${ORIGIN_JSON}" '{raw:$raw}')"
fi

# 通道未配置：不推，但写一条 ledger 留痕（user_notify_skipped），保证漏推可审计、不静默丢。
# ledger 为 append-only 审计（与 drain_pending.sh 一致），单行 JSON 原子追加，无需 flock。
if [ -z "${CHANNEL}" ]; then
  jq -nc --arg ev "${EVENT}" --arg st "${STATUS}" --arg iid "${IID}" \
     --arg content "${CONTENT}" --arg ts "${TS}" \
     --argjson origin "${ORIGIN_ARG}" \
     '{kind:"user_notify_skipped", event:$ev,
       status:($st|select(.!="")//null),
       iid:(if $iid=="" then null else ($iid|tonumber? // $iid) end),
       content:$content, origin:$origin, skipped_at:$ts,
       reason:"USER_NOTIFY_CHANNEL empty"}' \
     >> "${LEDGER_FILE}" \
     || { echo "notify_user: failed to write ledger (event=${EVENT})" >&2; exit 1; }
  echo "notify_user: USER_NOTIFY_CHANNEL empty; skip push, ledger 留痕 (event=${EVENT} iid=${IID:-?})" >&2
  exit 0
fi

# 通道已配置：落 user_notify.jsonl（占位实现）。真正的出站 send 待对齐后替换此处。
# TODO(待对齐): 企微回投 / 经 114 把 CONTENT 定向投回 ORIGIN_JSON 指向的发起人——
#   出站通道原语（工具名/参数/鉴权）属设计稿 §9.2 待对齐项，不臆造。对齐前以「落
#   user_notify.jsonl 留痕」代替真正推送：留痕保证结论不丢、且对齐后可回放补投。
NOTIFY_LOG="${LOG_DIR}/user_notify.jsonl"
jq -nc --arg ev "${EVENT}" --arg st "${STATUS}" --arg iid "${IID}" \
   --arg content "${CONTENT}" --arg ch "${CHANNEL}" --arg ts "${TS}" \
   --arg mr "${MR_URL}" --arg wiki "${WIKI_URL}" --arg rsn "${REASON}" \
   --argjson origin "${ORIGIN_ARG}" \
   '{kind:"user_notify", event:$ev,
     status:($st|select(.!="")//null),
     iid:(if $iid=="" then null else ($iid|tonumber? // $iid) end),
     content:$content, channel:$ch, origin:$origin,
     mr_url:($mr|select(.!="")//null),
     wiki_url:($wiki|select(.!="")//null),
     reason:($rsn|select(.!="")//null),
     notified_at:$ts}' \
   >> "${NOTIFY_LOG}" \
   || { echo "notify_user: failed to write ${NOTIFY_LOG} (event=${EVENT})" >&2; exit 1; }
echo "notify_user: queued push (event=${EVENT} status=${STATUS:-?} iid=${IID:-?}) -> ${NOTIFY_LOG}" >&2
exit 0
