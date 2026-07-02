#!/usr/bin/env bash
# route_project.sh — 多 project 路由：把 git_issuer 返回的 PROJECT 映射到目标 req_executor agent 名。
#
# 由 orchestrator 在 git_issuer 返回 success 后调用：拿到 project 后查覆盖路由或默认执行器，得到
# 目标 executor agent 名，再据此通过 run_agent_turn.sh 调用 `<executor> RUN_SINGLE_ISSUE`。req_dispatcher
# 不解析需求 project（那是 git_issuer 的活），它只在拿到透传回来的 project 后做一次路由决策。
#
# 路由来源 = DEFAULT_EXECUTOR_AGENT + 可选 ROUTING_FILE（config/routing.env）。默认执行器覆盖所有
# 形态合法的 GitLab project；路由表只用于少数 project 需要专属 executor 的覆盖项。每行 `PROJECT=AGENT`：
#   - PROJECT 是 git_issuer 返回的 group/project（含 `/`，故不能用 shell `source` 解析，逐行手解）。
#   - AGENT 是该 project 对应的专属 executor agent 名；未覆盖的合法 project 走 DEFAULT_EXECUTOR_AGENT。
# `#` 起头行与空行忽略。匹配 = **对 PROJECT 整体精确相等**（不做前缀/正则/大小写折叠），避免误投。
#
# 退出码：
#   - 命中覆盖项 → stdout 打印覆盖 executor agent 名、exit 0。
#   - 未命中但 DEFAULT_EXECUTOR_AGENT 已配置 → stdout 打印默认 executor agent 名、exit 0。
#   - 未命中且 DEFAULT_EXECUTOR_AGENT 为空 → stdout 打印 `__NO_ROUTE__`、exit 0。
#   - PROJECT 不是 `<group>/<project>`、ROUTING_FILE 指向但文件不存在、或行格式非法 → exit 2
#            （部署期配置写错，非运行时正常分支；让 orchestrator 走 No-Fallback：分类/记录/停）。
#
# 入参（env）：
#   PROJECT       必填：要路由的 group/project（git_issuer 返回透传）。
#   ROUTING_FILE  可选：覆盖路由表文件路径（config/routing.env；调用方 source_dispatcher_env.sh 后透传）。
#   DEFAULT_EXECUTOR_AGENT 可选：默认 executor agent。配置后所有合法 PROJECT 都可路由。
set -euo pipefail

: "${PROJECT:?route_project: PROJECT required}"
ROUTING_FILE="${ROUTING_FILE:-}"
DEFAULT_EXECUTOR_AGENT="${DEFAULT_EXECUTOR_AGENT:-}"

case "${PROJECT}" in
  */*) ;;
  *) echo "route_project: PROJECT must be <group>/<project>, got: ${PROJECT}" >&2; exit 2 ;;
esac
PROJECT_GROUP="${PROJECT%/*}"
PROJECT_SLUG="${PROJECT##*/}"
if [ -z "${PROJECT_GROUP}" ] || [ -z "${PROJECT_SLUG}" ]; then
  echo "route_project: PROJECT must be <group>/<project>, got: ${PROJECT}" >&2
  exit 2
fi

if [ -z "${ROUTING_FILE}" ]; then
  if [ -n "${DEFAULT_EXECUTOR_AGENT}" ]; then
    printf '%s\n' "${DEFAULT_EXECUTOR_AGENT}"
    exit 0
  fi
  printf '%s\n' "__NO_ROUTE__"
  exit 0
fi

# 文件缺失 = 部署期配置形态错，显式失败（不静默当成 no-route/default）。
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
  val="${val%"${val##*[![:space:]]}"}"
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

# 未命中：优先走默认 executor。只有未配置默认时才输出 no-route 哨兵。
if [ -n "${DEFAULT_EXECUTOR_AGENT}" ]; then
  printf '%s\n' "${DEFAULT_EXECUTOR_AGENT}"
  exit 0
fi

printf '%s\n' "__NO_ROUTE__"
exit 0
