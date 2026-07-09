# req_dispatcher User Contract

把本工作区用作 WebUI/智伴 prompt 在 104 侧的统一接入点。114 把用户在企微上发的需求转发到这里，WebUI 也可以直接输入自然语言。`req_dispatcher` 会先判断用户意图：只要分析/拆分/创建/变更 issue，就调用蓝区 `git_issuer`；明确要求处理既有 issue，就调用 `req_executor`；明确要求"建 issue 并处理"，才会先建单再执行。它不再因为消息里有 wiki URL 或需求正文就自动进入执行链。本 agent 不写 GitLab（不建 issue、不打标签、不写 note、不跑 issue）。

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

- 发的就是**一段文本消息**，不是结构化字段。消息可以要求创建 issue，也可以要求处理既有 issue。
- 建单入口支持 GitLab wiki URL，例如 `http://<gitlab>/<group>/<project>/-/wikis/<slug>`；也支持能确定 project 的自由文本，目标 project 必须能从 `group/project`、GitLab 仓库/Wiki URL，或 `glab api projects/<encoded-group%2Fproject>/...` 片段中确定性提取。无法确定 project 时，会在调用 git_issuer 前直接返回失败说明。
- 执行入口必须包含 GitLab issue URL，或同时包含 `group/project` 与 issue IID（例如 `issue #312`）。缺 project 或缺 IID 时不会调用 executor，会要求补充。
- 需要指定 MR 目标分支时，可在同一条自然语言消息里明确写 `branch=release/xxx`、`target_branch=release/xxx`、`目标分支：release/xxx` 或 `合到 release/xxx`；只有执行动作会把它作为 executor 的 `branch=` 透传。建单动作会从给 git_issuer 的需求正文中剥离该路由指令。
- 若需把处理结果推回**发起需求的具体企微用户**，`req_dispatcher` 会先从 OpenClaw 网关/运行时来源元数据捕获 origin（如 source agent/session、deliver origin），再 fallback 到需求文本里的 `[origin] channel=... user=... conversation=... reply_agent=...` 行。其中 `reply_agent` 是 114 上接收终态结果的 agent 名；只有捕获到合法 origin object 时才允许出站推 114，`reply_agent` 缺省时才退回部署期默认 `DEFAULT_REPLY_AGENT`。手动 WebUI 入口通常没有 origin，结果只落 ledger/log 留痕，不给 114 或企微发消息。
- `--deliver` 把本 agent 的回复投回企微侧。本 agent 同步只回一条**最小受理 ack**；处理结论稍后由本 agent 经反向网关推 114 接收 agent，再由该 agent 投回企微（不在 ack 里）。

## 你会收到什么

- **同步：来自 req_dispatcher 的最小 ack**，例如：
  > 需求已受理，正在创建 issue。

  或：

  > issue 已加入执行队列，处理结果稍后通知。

  （只建单请求同步返回 issue 创建结果；执行请求的处理结论稍后异步返回。）
- **异步：来自 req_dispatcher 的终态结论**（只有执行动作才有；受理 ack 之外的实质通知，仅终态推一次）：
  - 处理完成 → "#<iid> 已处理完成，MR：<mr_url>"
  - 处理未通过 → "#<iid> 处理未通过：<reason>"
  - 处理超时 → "#<iid> 处理超时未完成，已停放待人工处理"
  - 流程性失败（建 issue 失败 / 默认执行器未配置 / 启动执行失败）→ 对应失败说明。

> ack 文案已固定；终态结论的推送机制已对齐为反向网关推 114 接收 agent。部署期需填 `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`；仅当 `origin` 是合法 object 时才出站推送，目标 agent 优先取 `origin.reply_agent`，没有时才用默认 `DEFAULT_REPLY_AGENT`。`origin` 为空/null、网关 pin 缺失或目标 agent 缺失时结论只落 ledger/log 留痕。`REPLY_NOTIFY_TIMEOUT_SECONDS` 控制该 best-effort 推送的超时。

## 预期行为

- 同一个编排器 session 承接接入消息、executor 回调、executor queue drain 三类唤醒。
- 只建单请求 → `run_agent_turn.sh` 调蓝区 git_issuer 建 issue → drain git_issuer 审计 stage → 返回 issue 创建结果，不进入 executor queue。
- 执行既有 issue 请求 → `prepare_executor_issue_payload.sh` 提取 project/iid → 按路由入 executor durable FIFO queue → 队首由 `drain_executor_queue.sh` 起 req_executor 单次 issue 执行 → 记录 executor pending → executor 回调 drain → 清 active → 继续 drain 下一条 → 终态推用户一次。
- 显式建单并执行请求 → 先按建单流程创建 issue；成功后才入 executor queue。
- 多条需求可并发接入并建 issue；executor 执行按队列 FIFO 推进，active 未完成时后续 issue 保持排队。
- 失败（下游调用耗尽重试 / git_issuer 报失败 / 默认执行器未配置 / 执行 failed/timeout / 超时无回调）**不静默丢**：记 `ledger.jsonl` + 推用户对应说明 + 可选 ops 通知。**不自动重试业务**——重试请重发需求。
- wiki URL 无法解析、wiki 读取失败、wiki 内容为空，或自由文本无法确定 GitLab project 时，不会调用 git_issuer 或 executor；会直接提示补充 `group/project` 或具体 GitLab/Wiki URL。
- req_dispatcher 现在**会**在智伴/114 入口带合法 origin 时把处理结论推回企微发起人（终态一次）；手动 WebUI 入口没有 origin 时不推 114/企微，只留本地审计。它仍**不**做处理进度播报、**不**碰 GitLab。

## 配置

部署期配置见 [`config/dispatcher.env`](config/dispatcher.env) 与 [`config/README.md`](config/README.md)。关键：`GIT_ISSUER_AGENT`、`DEFAULT_EXECUTOR_AGENT`、`DOWNSTREAM_AGENT_TIMEOUT_SECONDS`（git_issuer 等通用下游默认）、`EXECUTOR_AGENT_TIMEOUT_SECONDS`（executor 专用，默认 10800 秒）、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、`ROUTING_FILE`（project 覆盖路由表）、wiki 只读 pin `WIKI_GITLAB_HOST` / `WIKI_GITLAB_API_PROTOCOL` / `WIKI_GITLAB_TOKEN` / `WIKI_GLAB_BIN`、`REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS`（用户结果推送 pin，其中 `DEFAULT_REPLY_AGENT` 只是合法 origin object 缺少 `origin.reply_agent` 时的默认目标）、`DISPATCHER_CALLBACK_TARGET`（结果回调目标）、`EXECUTOR_QUEUE_*`（队列恢复与启动重试窗口）。覆盖路由表本体 [`config/routing.env`](config/routing.env)。部署侧还需要周期性唤醒 `RUN_EXECUTOR_QUEUE_DRAIN`，用于清理超时 active、恢复中断或补推进队列。**group/project 不写死在配置里**（wiki 入口从 URL 解析，自由文本入口从 `group/project`、GitLab 仓库/Wiki URL 或 `glab api projects/<encoded-group%2Fproject>/...` 片段提取）；**目标分支不写死在配置里**（只从入口消息里的明确分支指令提取）；**执行器 GitLab token 不在配置里**（归执行器侧）。

## 依赖与对齐项

- `run_agent_turn.sh` 调用契约 + executor RUN_SINGLE_ISSUE(I1)/结果回调(I2) 信封：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。
- origin 捕获、`correlation_id` 生成：同上 + [`config/README.md`](config/README.md)（origin 优先来自 OpenClaw 网关/运行时来源元数据，正文 `[origin]` 行是 fallback；最终需能携带或推导 `reply_agent`）。
- 用户结果推送 pin：`REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / 默认 `DEFAULT_REPLY_AGENT`，机制已对齐为反向网关推 114 接收 agent；仅合法 origin object 允许出站，目标 agent 优先来自 `origin.reply_agent`。
- git_issuer 对接文档（跨团队，待与同事对齐）：创建契约 [`docs/integration/gitissuer_contract.md`](docs/integration/gitissuer_contract.md)、变更请求契约 [`docs/integration/gitissuer_change_request.md`](docs/integration/gitissuer_change_request.md)。
- req_executor 衔接前提（默认执行器部署可处理蓝区目标 GitLab project，专属覆盖按需配置）：[`AGENTS.md`](AGENTS.md) §req_executor 衔接依赖；主动编排设计稿 [`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)。
