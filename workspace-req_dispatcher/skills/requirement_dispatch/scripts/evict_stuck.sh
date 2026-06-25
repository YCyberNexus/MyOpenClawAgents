#!/usr/bin/env bash
# 兜底：扫超时 pending → 合成 stuck_evicted 写 ledger + 从 pending 删除。
# 在接入路径开头调用，避免 pending 永久泄漏。
# 入参（env）：STUCK_AFTER_MINUTES(必，非负整数)
# 语义：ledger 为 at-least-once 审计（见 references/state_schema.md）。删除按"上面确定的同一批 key"
#   精确删除，保证 ledger 写入集合 == pending 删除集合。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${STUCK_AFTER_MINUTES:?STUCK_AFTER_MINUTES required}"
[[ "${STUCK_AFTER_MINUTES}" =~ ^[0-9]+$ ]] || { echo "STUCK_AFTER_MINUTES must be a non-negative integer: ${STUCK_AFTER_MINUTES}" >&2; exit 1; }
NOW="$(date -u +%s)"
[[ "${NOW}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${NOW}" >&2; exit 1; }
CUTOFF=$(( NOW - STUCK_AFTER_MINUTES * 60 ))

exec 9>"${LOCK_FILE}"
flock 9
# 找出过期 run_id（spawned_at < CUTOFF）。
# jq 失败（如 pending.json 损坏）必须可见，不可被 mapfile 静默吞成空数组。
expired_raw="$(jq -r --argjson cutoff "${CUTOFF}" \
  '.pending | to_entries[] | select(.value.spawned_at < $cutoff) | .key' "${PENDING_FILE}")" \
  || { echo "jq read failed on ${PENDING_FILE} (corrupt?)" >&2; exit 1; }

expired=()
[ -n "${expired_raw}" ] && mapfile -t expired <<< "${expired_raw}"

if [ "${#expired[@]}" -gt 0 ]; then
  for rid in "${expired[@]}"; do
    jq -nc --arg rid "${rid}" --argjson ts "${NOW}" \
       '{run_id:$rid, outcome:"stuck_evicted", issue_iid:null, issue_url:null,
         reason:"no callback before stuck_after_minutes", drained_at:$ts, was_pending:true}' \
       >> "${LEDGER_FILE}"
  done
  # 按已确定的同一批 key 精确删除（而非按 cutoff 二次过滤），ledger 集合 == 删除集合。
  keys_json="$(printf '%s\n' "${expired[@]}" | jq -R . | jq -s .)"
  tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
  trap 'rm -f "${tmp}"' EXIT
  jq --argjson ks "${keys_json}" 'reduce $ks[] as $k (.; del(.pending[$k]))' \
     "${PENDING_FILE}" > "${tmp}"
  mv "${tmp}" "${PENDING_FILE}"
fi
flock -u 9
printf 'evicted %d stuck pending\n' "${#expired[@]}"
