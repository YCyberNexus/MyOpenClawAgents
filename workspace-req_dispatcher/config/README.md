# Workspace Config

本目录是 **部署期 pin（deployment-time pins）**：在每台部署 `req_dispatcher` 的 runner 上编辑一次。它们**不**由 trigger 输入生成，agent 运行时也**不**改写它们。

本机测试只写 `dispatcher.local.env`：标准入口 `skills/requirement_dispatch/scripts/source_dispatcher_env.sh` 会先加载 tracked `dispatcher.env`，再加载 ignored `dispatcher.local.env`（若存在）。不要为了本机路径、临时 session 或调试网关改 tracked `dispatcher.env`。

## `dispatcher.env`

| 字段 | 必填 | 说明 |
|------|------|------|
| `GIT_ISSUER_AGENT` | 是 | 下游目标 agent 名。`req_dispatcher` 通过 `run_agent_turn.sh` 调用它，由它完成"需求→issue"。默认 `git_issuer`。 |
| `STATE_ROOT` | 是 | 运行时 state 根目录。`pending.json` / `ledger.jsonl` / 锁 / 序号 / 日志都在 `${STATE_ROOT}/_dispatcher/` 下。必须是 server 上 agent 可写的持久目录。 |
| `STUCK_AFTER_MINUTES` | 是 | stuck/timeout 兜底阈值（分钟）。pending 超过该时长仍没等到回调 → 合成失败并 drain，避免 pending 永久泄漏。应略大于 git_issuer 单次建 issue 预期最大耗时 + 余量。 |
| `OPS_NOTIFY_CHANNEL` | 否 | 失败通知 channel = **企业微信群机器人 webhook URL**（http/https）。留空则不通知。消费方 `scripts/ops_notify.sh`（best-effort，发送失败不阻断失败路径；要换通知形态改该脚本）。 |
| `DEFAULT_ENTRY_LABEL` | 否 | 仅当将来需要 `req_dispatcher` 向 git_issuer 显式指定执行器入口标签时用。默认空＝由 git_issuer 自决。 |
| `DEFAULT_EXECUTOR_AGENT` | 是 | 默认执行器 agent。所有形态合法的 GitLab project（`group/project`）未命中覆盖路由时都路由到这里，默认 `req_executor`。 |
| `DOWNSTREAM_AGENT_TIMEOUT_SECONDS` | 否 | `scripts/run_agent_turn.sh` 调用下游 agent 时传给 `openclaw agent --timeout` 的秒数，默认 `600`。 |
| `ROUTING_FILE` | 否 | project 覆盖路由表文件路径（见下「`routing.env`」）。git_issuer 返回 project 后，先查本表；未命中则使用 `DEFAULT_EXECUTOR_AGENT`。消费方 `scripts/route_project.sh`。默认相对 SKILL_DIR 的 `../../config/routing.env`，也可改绝对路径。 |
| `REPLY_GATEWAY_URL` | 否 | 114 OpenClaw 网关 URL。用户结果推送机制已对齐为 104 反向网关调用 114 接收 agent；本字段或 `REPLY_GATEWAY_TOKEN` 为空，或 `origin.reply_agent` 与默认 `DEFAULT_REPLY_AGENT` 都为空时，`scripts/notify_user.sh` no-op（仅记 ledger 留痕、不静默丢）。 |
| `REPLY_GATEWAY_TOKEN` | 否 | 114 OpenClaw 网关 token。仅由 `notify_user.sh` 用于 `openclaw agent run` 投递结果信封；不要写入日志。 |
| `DEFAULT_REPLY_AGENT` | 否 | 114 上接收结果信封的默认 agent 名。`notify_user.sh` 优先使用 `origin.reply_agent`，该字段只在 origin 未提供 `reply_agent` 时兜底；接收 agent 负责根据信封里的 `origin` 完成企微最后一跳。 |
| `REPLY_NOTIFY_TIMEOUT_SECONDS` | 否 | 104 反向调用 114 接收 agent 的超时秒数，默认 `30`；必须为正整数，配置形态错误时 `notify_user.sh` 以 `2` 退出。实际投递超时只写 `user_notify_failed` 留痕并 `exit 0`，不阻断终态回调路径。 |
| `DISPATCHER_CALLBACK_TARGET` | 否 | 结果回调目标：调用 `req_executor` 的 `RUN_SINGLE_ISSUE` 时作为 `dispatcher_callback_target`（I1）传下去，执行器 Phase 6 据此把结果回调（I2）投回 req_dispatcher。支持 `agent:req_dispatcher:main` 这类 session key 或裸 agent 名；留空＝该字段为空，执行器侧回调 no-op。 |
| 跨 agent 调用契约 | 已定 | `scripts/run_agent_turn.sh` 包装 `openclaw agent --agent <target> --session-key <session> --message <payload> --timeout <seconds>`；CLI 使用 runner 已配置的 OpenClaw Gateway，不在本文件重复 pin 网关地址/token。 |

## `routing.env`（多 project 路由表）

git_issuer 返回 `project`（group/project）后，req_dispatcher 先查本表是否有专属 executor 覆盖项；未命中时统一路由到 `DEFAULT_EXECUTOR_AGENT`，再调用 `<executor> RUN_SINGLE_ISSUE`。消费方 `scripts/route_project.sh`。

行格式：每行一条 `PROJECT=AGENT`。

| 段 | 含义 |
|----|------|
| `PROJECT` | git_issuer 返回的 `group/project`（含 `/`，故本文件**不能**被 shell `source`，由 `route_project.sh` 逐行手解）。 |
| `AGENT` | 该 project 对应的专属 `req_executor` 部署 agent 名。 |

匹配规则：对 `PROJECT` **整体精确相等**（无前缀 / 正则 / 大小写折叠，避免误投）；`#` 起头行与空行忽略；`PROJECT = AGENT`（等号两侧带空格）也容忍；重复键按首行（first-match wins）。未命中且 `DEFAULT_EXECUTOR_AGENT` 非空时输出默认执行器。

**no-route 语义**：只有 `DEFAULT_EXECUTOR_AGENT` 未配置且覆盖表未命中时才输出 `__NO_ROUTE__` 并 `exit 0`。蓝区默认配置下，所有合法 `group/project` 都应路由到默认执行器。要让某个 project 走专属 executor，就在 `routing.env` 加覆盖行并部署对应 executor。

**配置写错的退出码**：某行无 `=`、`PROJECT`/`AGENT` 为空、或 `ROUTING_FILE` 指向的文件缺失 = 部署期配置写错，`route_project.sh` `exit 2`，orchestrator 走 No-Fallback（分类 / 记录 / 停），**不**当成 no-route 处理。

## 为什么 group / project 不在这里

`req_dispatcher` 是**全公司共用**的需求接入链路。不同员工/团队的需求会落到不同的 GitLab project。把 project 写死在 config 里会让这个 agent 变成单租户、违背"共用接入点"的目标。

因此：**114 只发自由文本需求，project 信息夹在文本里**；`req_dispatcher` 整段原样透传给 git_issuer，由 **git_issuer 自己从文本解析 project**。`req_dispatcher` 不解析自然语言、不碰 GitLab。

## 部署校验清单

1. `STATE_ROOT` 指向的目录在 runner 上存在且 agent 可写。
2. `GIT_ISSUER_AGENT` 指向的下游 agent 已在同一 OpenClaw 上线，可被 `run_agent_turn.sh` 通过 `openclaw agent` 调用。
3. 跨 agent 调用原语的连接参数已按对齐结果填好（见 `references/trigger_command.md`）。
4. `DEFAULT_EXECUTOR_AGENT` 指向的 req_executor 已在同一 OpenClaw 上线，且具备处理蓝区目标 GitLab project 的 token/branch pin。`ROUTING_FILE` 若配置则必须存在且可读；表里只写专属覆盖项，未命中默认执行器。
5. `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` 按 114 网关部署值填好；114 调用方在 origin 里带 `reply_agent`，或在本文件填默认 `DEFAULT_REPLY_AGENT` 兜底。缺少网关 pin 或目标 agent 时 `notify_user.sh` 只留痕、不推送用户结果。`REPLY_NOTIFY_TIMEOUT_SECONDS` 保持默认 `30` 或按网关预期延迟调整为正整数。
6. `DISPATCHER_CALLBACK_TARGET` 按 req_dispatcher 长期 session 配好；蓝区默认 `agent:req_dispatcher:main`。未填时执行器结果回调字段为空。

## 与 acpx 工作区的差异

`req_dispatcher` **不**像 `acpx_auto_tester` 那样 pin GitLab host / UI 账号池——它根本不碰 GitLab。本目录只放上面这些派发相关的 pin。
