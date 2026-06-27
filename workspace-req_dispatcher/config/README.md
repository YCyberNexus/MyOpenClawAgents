# Workspace Config

本目录是 **部署期 pin（deployment-time pins）**：在每台部署 `req_dispatcher` 的 runner 上编辑一次。它们**不**由 trigger 输入生成，agent 运行时也**不**改写它们。

## `dispatcher.env`

| 字段 | 必填 | 说明 |
|------|------|------|
| `GIT_ISSUER_AGENT` | 是 | 下游目标 agent 名。`req_dispatcher` 跨 agent 异步派发给它，由它"需求→issue"并打 acpx 入口标签。默认 `git_issuer`。 |
| `STATE_ROOT` | 是 | 运行时 state 根目录。`pending.json` / `ledger.jsonl` / 锁 / 序号 / 日志都在 `${STATE_ROOT}/_dispatcher/` 下。必须是 server 上 agent 可写的持久目录。 |
| `STUCK_AFTER_MINUTES` | 是 | stuck/timeout 兜底阈值（分钟）。pending 超过该时长仍没等到回调 → 合成失败并 drain，避免 pending 永久泄漏。应略大于 git_issuer 单次建 issue 预期最大耗时 + 余量。 |
| `OPS_NOTIFY_CHANNEL` | 否 | 失败通知 channel = **企业微信群机器人 webhook URL**（http/https）。留空则不通知。消费方 `scripts/ops_notify.sh`（best-effort，发送失败不阻断失败路径；要换通知形态改该脚本）。 |
| `DEFAULT_ENTRY_LABEL` | 否 | 仅当将来需要 `req_dispatcher` 向 git_issuer 显式指定 acpx 入口标签时用。默认空＝由 git_issuer 自决。 |
| 跨 agent 原语连接参数 | 待定 | 形态类 `sessions_spawn`、可指定目标 agent、异步回调。具体工具名与参数待与 OpenClaw 维护者/同事对齐，见 `skills/requirement_dispatch/references/trigger_command.md` 占位块。 |

## 为什么 group / project 不在这里

`req_dispatcher` 是**全公司共用**的需求接入链路。不同员工/团队的需求会落到不同的 GitLab project。把 project 写死在 config 里会让这个 agent 变成单租户、违背"共用接入点"的目标。

因此：**114 只发自由文本需求，project 信息夹在文本里**；`req_dispatcher` 整段原样透传给 git_issuer，由 **git_issuer 自己从文本解析 project**。`req_dispatcher` 不解析自然语言、不碰 GitLab。

## 部署校验清单

1. `STATE_ROOT` 指向的目录在 runner 上存在且 agent 可写。
2. `GIT_ISSUER_AGENT` 指向的下游 agent 已在同一 OpenClaw 上线、可被跨 agent 原语调用。
3. 跨 agent 调用原语的连接参数已按对齐结果填好（见 `references/trigger_command.md`）。
4. （衔接依赖，非本 agent 职责）目标 project 必须有对应的 `acpx_auto_tester` campaign 在 cron 上跑，否则 issue 建好却无人测——详见 `AGENTS.md` 的 acpx 衔接说明。

## 与 acpx 工作区的差异

`req_dispatcher` **不**像 `acpx_auto_tester` 那样 pin GitLab host / UI 账号池——它根本不碰 GitLab。本目录只放上面这些派发相关的 pin。
