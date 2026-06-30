# Workspace Config

本目录是 **部署期 pin（deployment-time pins）**：在每台部署 `req_dispatcher` 的 runner 上编辑一次。它们**不**由 trigger 输入生成，agent 运行时也**不**改写它们。

## `dispatcher.env`

| 字段 | 必填 | 说明 |
|------|------|------|
| `GIT_ISSUER_AGENT` | 是 | 下游目标 agent 名。`req_dispatcher` 跨 agent 异步派发给它，由它"需求→issue"并打执行器入口标签。默认 `git_issuer`。 |
| `STATE_ROOT` | 是 | 运行时 state 根目录。`pending.json` / `ledger.jsonl` / 锁 / 序号 / 日志都在 `${STATE_ROOT}/_dispatcher/` 下。必须是 server 上 agent 可写的持久目录。 |
| `STUCK_AFTER_MINUTES` | 是 | stuck/timeout 兜底阈值（分钟）。pending 超过该时长仍没等到回调 → 合成失败并 drain，避免 pending 永久泄漏。应略大于 git_issuer 单次建 issue 预期最大耗时 + 余量。 |
| `OPS_NOTIFY_CHANNEL` | 否 | 失败通知 channel = **企业微信群机器人 webhook URL**（http/https）。留空则不通知。消费方 `scripts/ops_notify.sh`（best-effort，发送失败不阻断失败路径；要换通知形态改该脚本）。 |
| `DEFAULT_ENTRY_LABEL` | 否 | 仅当将来需要 `req_dispatcher` 向 git_issuer 显式指定执行器入口标签时用。默认空＝由 git_issuer 自决。 |
| `ROUTING_FILE` | 是 | 多 project 路由表文件路径（见下「`routing.env`」）。git_issuer 回调透传回 project 后据此选目标 `req_executor` agent。消费方 `scripts/route_project.sh`。默认相对 SKILL_DIR 的 `../../config/routing.env`，也可改绝对路径。 |
| `ZHIBAN_GATEWAY_URL` | 否 | 114 OpenClaw 网关 URL。用户结果推送机制已对齐为 104 反向网关调用 114 智伴；本字段与 `ZHIBAN_GATEWAY_TOKEN` / `ZHIBAN_AGENT` 任一留空＝`scripts/notify_user.sh` no-op（仅记 ledger 留痕、不静默丢）。 |
| `ZHIBAN_GATEWAY_TOKEN` | 否 | 114 OpenClaw 网关 token。仅由 `notify_user.sh` 用于 `openclaw agent run` 投递结果信封；不要写入日志。 |
| `ZHIBAN_AGENT` | 否 | 114 上接收结果信封的智伴 agent 名。智伴负责根据信封里的 `origin` 完成企微最后一跳。 |
| `DISPATCHER_CALLBACK_TARGET` | 否（**待对齐**） | 结果回调目标：spawn `req_executor` 的 `RUN_SINGLE_ISSUE` 时作为 `dispatcher_callback_target`（I1）传下去，执行器 Phase 6 据此把结果回调（I2）投回 req_dispatcher。确切形态 = req_dispatcher 的 agent/session 标识，与跨 agent 回调原语一同**待对齐**（设计稿 §9.1）。留空＝该字段为空，执行器侧回调 no-op。 |
| 跨 agent 原语连接参数 | 待定 | 形态类 `sessions_spawn`、可指定目标 agent、异步回调。具体工具名与参数待与 OpenClaw 维护者/同事对齐，见 `skills/requirement_dispatch/references/trigger_command.md` 占位块。 |

## `routing.env`（多 project 路由表）

git_issuer 回调把 `project`（group/project）透传回来后，req_dispatcher 据本表选目标 `req_executor` 部署 agent，再 spawn `<executor> RUN_SINGLE_ISSUE`。**一开始就做多 project 路由**：每个 project 对应一个独立的 `req_executor` 部署（GitLab token / branch 在各自 executor 侧 pin，req_dispatcher 永不持有 token）。消费方 `scripts/route_project.sh`。

行格式：每行一条 `PROJECT=AGENT`。

| 段 | 含义 |
|----|------|
| `PROJECT` | git_issuer 回调里的 `group/project`（含 `/`，故本文件**不能**被 shell `source`，由 `route_project.sh` 逐行手解）。 |
| `AGENT` | 该 project 对应的 `req_executor` 部署 agent 名。 |

匹配规则：对 `PROJECT` **整体精确相等**（无前缀 / 正则 / 大小写折叠，避免误投）；`#` 起头行与空行忽略；`PROJECT = AGENT`（等号两侧带空格）也容忍；重复键按首行（first-match wins）。

**no-route 语义**：查不到 = **明确失败**（设计稿 §4.4「不臆造、不默认乱投」）。`route_project.sh` 对未命中输出 `__NO_ROUTE__` 并 `exit 0`（命中则输出 agent 名 `exit 0`），由 SKILL 判为 no-route：推用户「该 project 未接入执行器」+ 记 ledger + ops 通知 + drain。要接入新 project，就在 `routing.env` 加一行并部署对应 executor。

**配置写错的退出码**：某行无 `=`、`PROJECT`/`AGENT` 为空、或 `ROUTING_FILE` 指向的文件缺失 = 部署期配置写错，`route_project.sh` `exit 2`，orchestrator 走 No-Fallback（分类 / 记录 / 停），**不**当成 no-route 处理。

## 为什么 group / project 不在这里

`req_dispatcher` 是**全公司共用**的需求接入链路。不同员工/团队的需求会落到不同的 GitLab project。把 project 写死在 config 里会让这个 agent 变成单租户、违背"共用接入点"的目标。

因此：**114 只发自由文本需求，project 信息夹在文本里**；`req_dispatcher` 整段原样透传给 git_issuer，由 **git_issuer 自己从文本解析 project**。`req_dispatcher` 不解析自然语言、不碰 GitLab。

## 部署校验清单

1. `STATE_ROOT` 指向的目录在 runner 上存在且 agent 可写。
2. `GIT_ISSUER_AGENT` 指向的下游 agent 已在同一 OpenClaw 上线、可被跨 agent 原语调用。
3. 跨 agent 调用原语的连接参数已按对齐结果填好（见 `references/trigger_command.md`）。
4. `ROUTING_FILE` 指向的 `routing.env` 存在且可读；本链路要服务的每个 project 都在表里有 `PROJECT=AGENT` 行，且对应的 `req_executor` 部署已在同一 OpenClaw 上线（主动编排下由 req_dispatcher spawn `RUN_SINGLE_ISSUE` 即时驱动，不再依赖独立 cron 被动捞起）。表里没有的 project 会被判 no-route。
5. `ZHIBAN_GATEWAY_URL` / `ZHIBAN_GATEWAY_TOKEN` / `ZHIBAN_AGENT` 按 114 智伴部署值填好；未填时 `notify_user.sh` 只留痕、不推送用户结果。
6. （**待对齐**）`DISPATCHER_CALLBACK_TARGET` 在对齐 executor 结果回调原语后填好；未填时执行器结果回调字段为空。

## 与 acpx 工作区的差异

`req_dispatcher` **不**像 `acpx_auto_tester` 那样 pin GitLab host / UI 账号池——它根本不碰 GitLab。本目录只放上面这些派发相关的 pin。
