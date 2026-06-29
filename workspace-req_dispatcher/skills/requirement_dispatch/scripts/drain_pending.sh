#!/usr/bin/env bash
# 回调路径：按 RUN_ID 匹配 + drain + 写 ledger。
# 入参（env）：
#   RUN_ID(必，主匹配键), OUTCOME(必: success|failed|launch_failed),
#   STAGE?(git_issuer|executor，标该终态属哪段),
#   PROJECT?, IID?(正整数；executor 段沿用，等价 ISSUE_IID), ISSUE_URL?,
#   STATUS?(executor 回调终态: done|failed|timeout), MR_URL?, REASON?
#   ISSUE_IID? (git_issuer 段的 IID 别名；IID 优先)
# 语义：ledger 为 at-least-once 审计——崩溃窗口或迟到/重复回调可能为同一 run_id 写多条
#   终态行（见 references/state_schema.md）。RUN_ID 不在 pending 也照常写 ledger（was_pending=false），
#   这是预期的（迟到/重复/已被 stuck 驱逐），非错误。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${RUN_ID:?RUN_ID required}"
: "${OUTCOME:?OUTCOME required}"
STAGE="${STAGE:-}"
PROJECT="${PROJECT:-}"
# IID 与历史 ISSUE_IID 同义：IID 优先，回落到 ISSUE_IID。
IID="${IID:-${ISSUE_IID:-}}"
ISSUE_URL="${ISSUE_URL:-}"
STATUS="${STATUS:-}"
MR_URL="${MR_URL:-}"
REASON="${REASON:-}"
# STAGE 给定时必须合法。
if [ -n "${STAGE}" ]; then
  case "${STAGE}" in
    git_issuer|executor) ;;
    *) echo "STAGE must be one of: git_issuer|executor (got: ${STAGE})" >&2; exit 1 ;;
  esac
fi
# STATUS 给定时必须是执行器回调终态枚举。
if [ -n "${STATUS}" ]; then
  case "${STATUS}" in
    done|failed|timeout) ;;
    *) echo "STATUS must be one of: done|failed|timeout (got: ${STATUS})" >&2; exit 1 ;;
  esac
fi
DRAINED_AT="$(date -u +%s)"
[[ "${DRAINED_AT}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${DRAINED_AT}" >&2; exit 1; }

exec 9>"${LOCK_FILE}"
flock 9
present="$(jq -r --arg rid "${RUN_ID}" 'if .pending[$rid] then "yes" else "no" end' "${PENDING_FILE}")" \
  || { echo "jq read failed on ${PENDING_FILE} (corrupt?)" >&2; exit 1; }
# 追加 ledger（即便 pending 已不在也记，便于审计重复/迟到回调）。
# issue_iid 为整数时按数字写（git_issuer/executor IID 是正整数、无前导零），否则当字符串/空处理。
jq -nc --arg rid "${RUN_ID}" --arg oc "${OUTCOME}" \
   --arg stage "${STAGE}" --arg proj "${PROJECT}" \
   --arg iid "${IID}" --arg url "${ISSUE_URL}" \
   --arg status "${STATUS}" --arg mr "${MR_URL}" --arg rsn "${REASON}" \
   --argjson ts "${DRAINED_AT}" --arg present "${present}" \
   '{run_id:$rid, outcome:$oc,
     stage:($stage|select(.!="")//null),
     project:($proj|select(.!="")//null),
     issue_iid:(if $iid=="" then null else ($iid|tonumber? // $iid) end),
     issue_url:($url|select(.!="")//null),
     status:($status|select(.!="")//null),
     mr_url:($mr|select(.!="")//null),
     reason:($rsn|select(.!="")//null),
     drained_at:$ts, was_pending:($present=="yes")}' \
   >> "${LEDGER_FILE}"
tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
jq --arg rid "${RUN_ID}" 'del(.pending[$rid])' "${PENDING_FILE}" > "${tmp}"
mv "${tmp}" "${PENDING_FILE}"
flock -u 9
printf 'drained run_id=%s outcome=%s stage=%s was_pending=%s\n' "${RUN_ID}" "${OUTCOME}" "${STAGE:-}" "${present}"
