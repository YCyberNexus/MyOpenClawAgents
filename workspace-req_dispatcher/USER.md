# req_dispatcher User Contract

把本工作区用作"企微需求 → 自动测试"链路在 104 侧的统一接入点。114 把用户在企微上发的需求转发到这里；本 agent 派发给 `git_issuer` 建 issue，之后被动走 `acpx_auto_tester` 既有流程。

## 114 如何调用

经网关 `agent run` 指定本 agent（架构图"114 侧调用特定 agent"方式 A）：

```bash
openclaw --gateway-url ws://<104-host>:<port> \
         --gateway-token "<token>" \
         agent run "<用户需求原文>" \
         --agent req_dispatcher \
         --deliver
```

或等价 HTTP 桥接（方式 B）。要点：

- 发的就是**一段自由文本需求**，不是结构化字段。
- **目标 project 写在需求文本里**（如"在 project X 里……"）。req_dispatcher 不解析、整段透传，由 `git_issuer` 自己从文本解析 project。
- `--deliver` 把本 agent 的回复投回企微侧。本 agent 只回一条**最小受理 ack**。

## 你会收到什么

- **来自 req_dispatcher**：一条最小受理 ack，例如：
  > 需求已受理，正在创建 issue；进度与结果将由后续流程通知。

  （ack 是同步返回；issue 由 git_issuer 异步创建，IID/URL 不在 ack 里。）
- **来自 git_issuer / acpx**：实质通知（issue 已建、测试进度/结果）由它们各自的 channel 发——req_dispatcher 极简，不主动回这些状态。

> ⚠️ ack 文案与"`--deliver` 是否真把 ack 投回企微"待部署确认；确认后在此固化文案。

## 预期行为

- 同一个编排器 session 承接所有接入消息与回调。
- 每条需求 → 一次跨 agent 异步 spawn git_issuer → 一条 pending（主键 `run_id`）→ 回调 drain。
- 多条需求可并发在飞，互不干扰。
- 失败（spawn 耗尽重试 / git_issuer 报失败 / 超时无回调）**不静默丢**：记 `ledger.jsonl` + 可选 ops 通知。**不自动重试**——重试请重发需求。
- req_dispatcher **不**追踪测试结果、**不**给企微用户回测试结论。

## 配置

部署期配置见 [`config/dispatcher.env`](config/dispatcher.env) 与 [`config/README.md`](config/README.md)。关键：`GIT_ISSUER_AGENT`、`STATE_ROOT`、`STUCK_AFTER_MINUTES`。**group/project 不在配置里**（随需求文本传入）。

## 依赖与对齐项

- 跨 agent 调用原语 + 回调字段：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)（待对齐）。
- git_issuer I/O 契约：[`skills/requirement_dispatch/references/gitissuer_contract.md`](skills/requirement_dispatch/references/gitissuer_contract.md)（待与同事对齐）。
- acpx 衔接前提（目标 project 需有对应 acpx campaign 在跑）：[`AGENTS.md`](AGENTS.md) §acpx 衔接依赖。
