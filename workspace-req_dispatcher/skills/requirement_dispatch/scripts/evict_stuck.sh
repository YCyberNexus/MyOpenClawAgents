#!/usr/bin/env bash
# 兜底：扫超时 pending → 合成 stuck_evicted 写 ledger + 从 pending 删除。
# 若超时 pending 是当前 executor queue active，也在同一锁内清 active，避免 FIFO 永久卡住。
# executor 段若携带 origin，则解锁后 best-effort 推 timeout 给用户。
# 在接入路径开头调用，避免 pending 永久泄漏。覆盖两段（git_issuer/executor），不分 stage 一并扫。
# 新 pending 在创建时固定 stuck_after_minutes；部署前旧记录使用 390 分钟兼容预算。
# 语义：ledger 为 at-least-once 审计（见 references/state_schema.md）。删除按"上面确定的同一批 key"
#   精确删除，保证 ledger 写入集合 == pending 删除集合。stuck_evicted 行从对应 entry 读 .value.stage。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

LEGACY_STUCK_BUDGET_MINUTES="${LEGACY_STUCK_AFTER_MINUTES:-390}"
[[ "${LEGACY_STUCK_BUDGET_MINUTES}" =~ ^[0-9]+$ ]] \
  || { echo "LEGACY_STUCK_AFTER_MINUTES must be a non-negative integer: ${LEGACY_STUCK_BUDGET_MINUTES}" >&2; exit 1; }
NOW="$(date -u +%s)"
[[ "${NOW}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${NOW}" >&2; exit 1; }

exec 9>"${LOCK_FILE}"
flock 9
# 按每条 entry 创建时固定的预算找出过期项；后续 ledger/delete/notify 都基于同一快照。
# jq 失败（如 pending.json 损坏）必须可见，不可被 mapfile 静默吞成空数组。
expired_raw="$(jq -c \
  --argjson now "${NOW}" \
  --argjson legacy_stuck "${LEGACY_STUCK_BUDGET_MINUTES}" '
  def valid_budget: type == "number" and . == floor and . >= 0;
  if (.pending | type) == "object"
      and (.pending | to_entries
        | all((.value.stuck_after_minutes // $legacy_stuck) | valid_budget))
  then .pending | to_entries[]
    | select(.value.spawned_at
      < ($now - ((.value.stuck_after_minutes // $legacy_stuck) * 60)))
    | {run_id:.key,
       stage:(.value.stage // ""),
       project:(.value.project // null),
       iid:(.value.iid // null),
       correlation_id:(.value.correlation_id // null),
       origin:(.value.origin // null)}
  else error("pending contains an invalid stuck budget") end
  ' "${PENDING_FILE}")" \
  || { echo "jq read failed on ${PENDING_FILE} (corrupt?)" >&2; exit 1; }

expired=()
[ -n "${expired_raw}" ] && mapfile -t expired <<< "${expired_raw}"
notify_timeout_entries=()

if [ "${#expired[@]}" -gt 0 ]; then
  keys=()
  executor_refs=()
  for entry in "${expired[@]}"; do
    rid="$(jq -r '.run_id' <<<"${entry}")"
    stage="$(jq -r '.stage // ""' <<<"${entry}")"
    project="$(jq -r 'if .project == null then "" else .project end' <<<"${entry}")"
    iid="$(jq -r 'if .iid == null then "" else (.iid|tostring) end' <<<"${entry}")"
    keys+=("${rid}")
    if [ "${stage}" = "executor" ] && jq -e '.origin != null' <<<"${entry}" >/dev/null; then
      notify_timeout_entries+=("${entry}")
    fi
    if [ "${stage}" = "executor" ]; then
      executor_refs+=("$(jq -c '{run_id, correlation_id}' <<<"${entry}")")
    fi
    jq -nc --arg rid "${rid}" --arg stage "${stage}" \
       --arg project "${project}" --arg iid "${iid}" --argjson ts "${NOW}" \
       '{run_id:$rid, outcome:"stuck_evicted",
         stage:($stage|select(.!="")//null),
         project:($project|select(.!="")//null),
         issue_iid:(if $iid=="" then null else ($iid|tonumber? // $iid) end),
         issue_url:null, status:null, mr_url:null,
         reason:"no callback before stuck_after_minutes", drained_at:$ts, was_pending:true}' \
       >> "${LEDGER_FILE}"
  done
  # 按已确定的同一批 key 精确删除（而非按 cutoff 二次过滤），ledger 集合 == 删除集合。
  keys_json="$(printf '%s\n' "${keys[@]}" | jq -R . | jq -s .)"
  tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
  trap 'rm -f "${tmp}"' EXIT
  jq --argjson ks "${keys_json}" 'reduce $ks[] as $k (.; del(.pending[$k]))' \
     "${PENDING_FILE}" > "${tmp}"
  mv "${tmp}" "${PENDING_FILE}"

  if [ "${#executor_refs[@]}" -gt 0 ]; then
    refs_json="$(printf '%s\n' "${executor_refs[@]}" | jq -s .)"
    tmp_queue="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
    jq --argjson refs "${refs_json}" '
      (.active) as $active
      | if $active != null and any($refs[]; .run_id == ($active.run_id // "") or ((.correlation_id // null) != null and .correlation_id == ($active.correlation_id // null)))
        then .active = null
        else .
        end
    ' "${EXECUTOR_QUEUE_FILE}" > "${tmp_queue}"
    mv "${tmp_queue}" "${EXECUTOR_QUEUE_FILE}"
  fi
fi
flock -u 9

for entry in "${notify_timeout_entries[@]}"; do
  rid="$(jq -r '.run_id' <<<"${entry}")"
  iid="$(jq -r 'if .iid == null then "" else (.iid|tostring) end' <<<"${entry}")"
  origin_json="$(jq -c '.origin' <<<"${entry}")"
  if ! EVENT="result" STATUS="timeout" IID="${iid}" ORIGIN_JSON="${origin_json}" \
       NOTIFY_EVENT_ID="stuck:${rid}" \
       REASON="no callback before stuck_after_minutes" \
       bash "${SCRIPT_DIR}/notify_user.sh"; then
    echo "evict_stuck: notify_user timeout push failed for run_id=${rid} (non-fatal)" >&2
  fi
done

printf 'evicted %d stuck pending\n' "${#expired[@]}"
