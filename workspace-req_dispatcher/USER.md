# req_dispatcher User Contract

把本工作区用作"企微需求 → 自动处理"链路在 104 侧的统一接入点。114 把用户在企微上发的需求转发到这里；本 agent 主动驱动整条链：派发给 `git_issuer` 建 issue → 按 project 路由选目标 `req_executor` 部署、spawn 其单次 issue 执行入口即时执行 → 收执行结果回调 → 把结论推回发起需求的企微用户。本 agent 仍不碰 GitLab（不持 token、不调 glab、不解析 project）。

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
- 若需把处理结果推回**发起需求的具体企微用户**，需在需求文本里携带 origin 元数据（channel/user/conversation）——确切约定待对齐（见 trigger_command.md §origin）。缺省时结果信封里的 `origin` 为 `null`，智伴侧可能无法定向投递；`ZHIBAN_*` 未配置时才退化为留痕。
- `--deliver` 把本 agent 的回复投回企微侧。本 agent 同步只回一条**最小受理 ack**；处理结论稍后由本 agent 经反向网关推 114 智伴，再由智伴投回企微（不在 ack 里）。

## 你会收到什么

- **同步：来自 req_dispatcher 的最小受理 ack**，例如：
  > 需求已受理，正在创建 issue 并自动处理，结果稍后通知。

  （ack 同步返回；issue 由 git_issuer 异步创建、随后自动处理，IID/URL/结论均不在 ack 里。）
- **异步：来自 req_dispatcher 的终态结论**（受理 ack 之外的实质通知，仅终态推一次）：
  - 处理完成 → "#<iid> 已处理完成，MR：<mr_url>"
  - 处理未通过 → "#<iid> 处理未通过：<reason>"（有详情链接时追加"，详情见 <wiki_url>"）
  - 处理超时 → "#<iid> 处理超时未完成，已停放待人工处理"
  - 流程性失败（建 issue 失败 / 该 project 未接入执行器 / 启动执行失败）→ 对应失败说明。

> ⚠️ ack 文案已固定；终态结论的推送机制已对齐为反向网关推 114 智伴。部署期需填 `ZHIBAN_GATEWAY_URL` / `ZHIBAN_GATEWAY_TOKEN` / `ZHIBAN_AGENT`；三项任一为空时结论只落 ledger/log 留痕。origin 编码约定仍需与 114 对齐。

## 预期行为

- 同一个编排器 session 承接接入消息、git_issuer 回调、executor 回调三类唤醒。
- 每条需求 → 两段异步 spawn（先 git_issuer 建 issue，回调成功后按路由起 req_executor 单次 issue 执行）→ 各一条 pending（各自 `run_id`）→ 各自回调 drain → 终态推用户一次。
- 多条需求可并发在飞，互不干扰。
- 失败（spawn 耗尽重试 / git_issuer 报失败 / 路由未接入 / 执行 failed/timeout / 超时无回调）**不静默丢**：记 `ledger.jsonl` + 推用户对应说明 + 可选 ops 通知。**不自动重试**——重试请重发需求。
- req_dispatcher 现在**会**把处理结论推回企微发起人（终态一次），但仍**不**做处理进度播报、**不**碰 GitLab。

## 配置

部署期配置见 [`config/dispatcher.env`](config/dispatcher.env) 与 [`config/README.md`](config/README.md)。关键：`GIT_ISSUER_AGENT`、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、`ROUTING_FILE`（多 project 路由表）、`ZHIBAN_GATEWAY_URL` / `ZHIBAN_GATEWAY_TOKEN` / `ZHIBAN_AGENT`（用户结果推送 pin）；待对齐占位 `DISPATCHER_CALLBACK_TARGET`（结果回调目标）。多 project 路由表本体 [`config/routing.env`](config/routing.env)。**group/project 不在配置里**（随需求文本传入）；**GitLab token 不在配置里**（归执行器侧）。

## 依赖与对齐项

- 两段跨 agent 调用原语 + 两类回调字段 + executor spawn(I1)/结果回调(I2) 信封：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)（待对齐）。
- origin 约定、`correlation_id` 生成：同上 + [`config/README.md`](config/README.md)（待对齐占位）。
- 用户结果推送 pin：`ZHIBAN_GATEWAY_URL` / `ZHIBAN_GATEWAY_TOKEN` / `ZHIBAN_AGENT`，机制已对齐为反向网关推 114 智伴；部署期填值。
- git_issuer 对接文档（跨团队，待与同事对齐）：创建契约 [`docs/integration/gitissuer_contract.md`](docs/integration/gitissuer_contract.md)、变更请求契约 [`docs/integration/gitissuer_change_request.md`](docs/integration/gitissuer_change_request.md)。
- req_executor 衔接前提（目标 project 需有路由 + 对应 req_executor 部署可被 spawn）：[`AGENTS.md`](AGENTS.md) §req_executor 衔接依赖；主动编排设计稿 [`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)。
