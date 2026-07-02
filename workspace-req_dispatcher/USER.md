# req_dispatcher User Contract

把本工作区用作"企微需求 → 自动处理"链路在 104 侧的统一接入点。114 把用户在企微上发的需求转发到这里；本 agent 主动驱动整条链：调用蓝区 `git_issuer` 建 issue → 按 project 选择目标 `req_executor` 部署（合法 `group/project` 默认走 `DEFAULT_EXECUTOR_AGENT`，覆盖项见 `routing.env`）→ 调用其单次 issue 执行入口即时执行 → 收执行结果回调 → 把结论推回发起需求的企微用户。本 agent 仍不碰 GitLab（不持 token、不调 glab、不解析 project）。

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
- 若需把处理结果推回**发起需求的具体企微用户**，需在需求文本里携带 origin 元数据（`channel`/`user`/`conversation`/`reply_agent`；推荐行格式见 trigger_command.md §origin）。其中 `reply_agent` 是 114 上接收终态结果的 agent 名；缺省时退回部署期默认 `DEFAULT_REPLY_AGENT`，两者都没有则结果只落 ledger/log 留痕，无法定向投递。
- `--deliver` 把本 agent 的回复投回企微侧。本 agent 同步只回一条**最小受理 ack**；处理结论稍后由本 agent 经反向网关推 114 接收 agent，再由该 agent 投回企微（不在 ack 里）。

## 你会收到什么

- **同步：来自 req_dispatcher 的最小受理 ack**，例如：
  > 需求已受理，正在创建 issue 并自动处理，结果稍后通知。

  （ack 同步返回；issue 创建与执行器启动由 req_dispatcher 编排，处理结论稍后异步返回。）
- **异步：来自 req_dispatcher 的终态结论**（受理 ack 之外的实质通知，仅终态推一次）：
  - 处理完成 → "#<iid> 已处理完成，MR：<mr_url>"
  - 处理未通过 → "#<iid> 处理未通过：<reason>"（有详情链接时追加"，详情见 <wiki_url>"）
  - 处理超时 → "#<iid> 处理超时未完成，已停放待人工处理"
  - 流程性失败（建 issue 失败 / 默认执行器未配置 / 启动执行失败）→ 对应失败说明。

> ack 文案已固定；终态结论的推送机制已对齐为反向网关推 114 接收 agent。部署期需填 `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`；目标 agent 优先取 `origin.reply_agent`，没有时才用默认 `DEFAULT_REPLY_AGENT`。网关 pin 或目标 agent 缺失时结论只落 ledger/log 留痕。`REPLY_NOTIFY_TIMEOUT_SECONDS` 控制该 best-effort 推送的超时。

## 预期行为

- 同一个编排器 session 承接接入消息和 executor 回调两类唤醒。
- 每条需求 → `run_agent_turn.sh` 调蓝区 git_issuer 建 issue → 按路由起 req_executor 单次 issue 执行 → 记录 executor pending → executor 回调 drain → 终态推用户一次。
- 多条需求可并发在飞，互不干扰。
- 失败（下游调用耗尽重试 / git_issuer 报失败 / 默认执行器未配置 / 执行 failed/timeout / 超时无回调）**不静默丢**：记 `ledger.jsonl` + 推用户对应说明 + 可选 ops 通知。**不自动重试业务**——重试请重发需求。
- req_dispatcher 现在**会**把处理结论推回企微发起人（终态一次），但仍**不**做处理进度播报、**不**碰 GitLab。

## 配置

部署期配置见 [`config/dispatcher.env`](config/dispatcher.env) 与 [`config/README.md`](config/README.md)。关键：`GIT_ISSUER_AGENT`、`DEFAULT_EXECUTOR_AGENT`、`DOWNSTREAM_AGENT_TIMEOUT_SECONDS`、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、`ROUTING_FILE`（project 覆盖路由表）、`REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS`（用户结果推送 pin，其中 `DEFAULT_REPLY_AGENT` 只是缺少 `origin.reply_agent` 时的默认目标）、`DISPATCHER_CALLBACK_TARGET`（结果回调目标）。覆盖路由表本体 [`config/routing.env`](config/routing.env)。**group/project 不在配置里**（随需求文本传入）；**GitLab token 不在配置里**（归执行器侧）。

## 依赖与对齐项

- `run_agent_turn.sh` 调用契约 + executor RUN_SINGLE_ISSUE(I1)/结果回调(I2) 信封：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。
- origin 约定、`correlation_id` 生成：同上 + [`config/README.md`](config/README.md)（origin 需能携带 `reply_agent`）。
- 用户结果推送 pin：`REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / 默认 `DEFAULT_REPLY_AGENT`，机制已对齐为反向网关推 114 接收 agent；目标 agent 优先来自 `origin.reply_agent`。
- git_issuer 对接文档（跨团队，待与同事对齐）：创建契约 [`docs/integration/gitissuer_contract.md`](docs/integration/gitissuer_contract.md)、变更请求契约 [`docs/integration/gitissuer_change_request.md`](docs/integration/gitissuer_change_request.md)。
- req_executor 衔接前提（默认执行器部署可处理蓝区目标 GitLab project，专属覆盖按需配置）：[`AGENTS.md`](AGENTS.md) §req_executor 衔接依赖；主动编排设计稿 [`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)。
