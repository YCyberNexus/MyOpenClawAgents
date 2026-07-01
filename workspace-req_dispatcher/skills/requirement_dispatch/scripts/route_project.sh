#!/usr/bin/env bash
# route_project.sh — 多 project 路由：把 git_issuer 回调的 PROJECT 映射到目标 req_executor agent 名。
#
# 由 orchestrator 在 git_issuer 回调 success 路径调用：拿到 project 后查路由表，得到该 project
# 对应的 req_executor 部署 agent 名，再据此 spawn `<executor> RUN_SINGLE_ISSUE`（见 SKILL.md
# git_issuer 回调路径）。req_dispatcher 不解析需求 project（那是 git_issuer 的活），它只在拿到
# 透传回来的 project 后做一次"精确表查"。
#
# 路由表来源 = ROUTING_FILE（config/routing.env）。每行 `PROJECT=AGENT`：
#   - PROJECT 是 git_issuer 回调里的 group/project（含 `/`，故不能用 shell `source` 解析，逐行手解）。
#   - AGENT 是该 project 对应的 req_executor 部署 agent 名（每 project 一份独立部署，token/branch 各自 pin）。
# `#` 起头行与空行忽略。匹配 = **对 PROJECT 整体精确相等**（不做前缀/正则/大小写折叠），避免误投。
#
# 退出码（与设计稿 §4.4「查不到 = 明确失败，不臆造、不默认乱投」一致）：
#   - 命中  → stdout 打印 agent 名、exit 0。
#   - 未命中→ stdout 打印 `__NO_ROUTE__`、exit 0（由 SKILL 判为 no-route 失败：推用户「该 project
#            未接入执行器」+ ledger + ops 通知 + drain；脚本本身不是错误，故不写非零）。
#   - ROUTING_FILE 未给 / 文件不存在 / 行格式非法（无 `=` 或 PROJECT/AGENT 为空）→ exit 2
#            （部署期配置写错，非运行时正常分支；让 orchestrator 走 No-Fallback：分类/记录/停）。
#
# 入参（env）：
#   PROJECT       必填：要路由的 group/project（git_issuer 回调透传）。
#   ROUTING_FILE  必填：路由表文件路径（config/routing.env；调用方 source_dispatcher_env.sh 后透传）。
set -euo pipefail

: "${PROJECT:?route_project: PROJECT required}"
: "${ROUTING_FILE:?route_project: ROUTING_FILE required (config/routing.env)}"

# 文件缺失 = 部署期未放路由表：配置形态错，显式失败（不静默当成 no-route）。
if [ ! -f "${ROUTING_FILE}" ]; then
  echo "route_project: ROUTING_FILE not found: ${ROUTING_FILE}" >&2
  exit 2
fi

# 全表扫描（不在命中时短路）：先把每行都做格式校验，任一行非法就 exit 2，让部署期表里写错的
# 行总能被暴露——而不是"恰好今天的 project 在错行之前命中所以没报错、换个 project 才炸"。
# 命中按 first-match wins（重复键取首个命中行的值）。
MATCH=""
LINENO_=0
while IFS= read -r line || [ -n "${line}" ]; do
  LINENO_=$((LINENO_ + 1))
  # 去掉行首尾空白，便于忽略缩进/空行。
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  # 跳过空行与注释行。
  [ -z "${trimmed}" ] && continue
  case "${trimmed}" in \#*) continue ;; esac
  # 必须含 `=`：否则路由表格式写错（部署期 bug）。
  case "${trimmed}" in
    *=*) ;;
    *) echo "route_project: malformed line ${LINENO_} (no '='): ${trimmed}" >&2; exit 2 ;;
  esac
  key="${trimmed%%=*}"
  val="${trimmed#*=}"
  # 同样裁剪 key/val 的内侧空白（容忍 `a = b` 写法）。
  key="${key%"${key##*[![:space:]]}"}"
  val="${val#"${val%%[![:space:]]*}"}"
  # PROJECT 或 AGENT 任一为空 = 格式非法。
  if [ -z "${key}" ] || [ -z "${val}" ]; then
    echo "route_project: malformed line ${LINENO_} (empty project or agent): ${trimmed}" >&2
    exit 2
  fi
  # 整体精确相等才算命中；记首个命中，但不 break——继续扫完以暴露后续错行。
  if [ -z "${MATCH}" ] && [ "${key}" = "${PROJECT}" ]; then
    MATCH="${val}"
  fi
done < "${ROUTING_FILE}"

if [ -n "${MATCH}" ]; then
  printf '%s\n' "${MATCH}"
  exit 0
fi

# 未命中：明确输出哨兵，交 SKILL 判 no-route（非脚本错误）。
printf '%s\n' "__NO_ROUTE__"
exit 0
