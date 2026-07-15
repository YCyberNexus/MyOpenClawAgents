# req_dispatcher User Contract

## 114 / WebUI 如何调用

直接发送自然语言需求。req_dispatcher 先判断动作：

- 分析、拆分、创建或变更 Issue：只调用 git_issuer；
- 执行既有 Issue：进入受驱动 batch；
- 明确“建单并执行”：建单成功后进入受驱动 batch；
- project/selector 不完整：要求补充，不调用 executor。

共享执行槽位可直接调整：

```text
/slot 5
```

该命令修改默认 `req_executor` 的共享物理并发上限，所有 batch session 共同生效，不是每个
session 各自设置。在线调低时不会取消已有任务；如果当前 active 数高于新上限，会停止发放新
槽位并等待自然回落。

acpx 超时默认为 1 小时，可在 1 分钟到 5 小时之间在线调整：

```text
/timeout-executor 1h
```

也支持 `/timeout-executor 90m` 或 `/timeout-executor 3600`。新值只影响后续启动的
attempt，已在运行的任务不会被中途改时。executor turn、exec 工具、旧队列回收与
stuck 驱逐会按新值自动派生；旧 FIFO active/pending 保留创建时预算，不会因调低新值被
提前回收。OpenClaw 全局 timeout 保持部署值，不会被该命令修改。

命令使用 `/timeout-executor` 是为了避开 OpenClaw 内置命令的前缀路由；旧名称
`/acpx-timeout` 和 `/executor-timeout` 均不再接受。

执行请求必须给出完整 `group/project` 或 GitLab Issue/repository URL，并使用以下一种 selector：

- 单 Issue：`处理 group/project 的 #42`；
- 离散 IID 列表：`处理 group/project 的 #1、#4、#5`；
- IID 闭区间：`处理 group/project 的 #100 到 #250`；
- OPEN 未完成：`处理 group/project 中未完成的 Issue`；
- OPEN 指定标签：`处理 group/project 中 label 为 smoke 的 Issue`。

同一仓库的一组明确 IID 会排序去重后作为一个 `iid_list` batch 执行。用“或/or”表达备选 IID、
把离散 IID 与范围或其他 selector 混用，或给范围附加非 OPEN 状态/label 条件时，必须要求用户
拆分或澄清，不能静默选取第一个条件。

五类 selector 都只纳入创建 batch 时为 OPEN 的 Issue，CLOSED 始终不处理。未完成模式排除
`pr,timeout,blocked,blocked-*,failed,failed-*`；指定标签模式不额外排除这些标签。

只有明确“重跑/重新处理/重新执行”才覆盖 `pr` 完成态；CLOSED Issue 不会重新打开。可在同一
消息中指定 `branch=release/x`、`target_branch=release/x`、`目标分支：release/x`、
`合到 release/x` 或“基于 release/x 分支开发”。

origin 优先来自 OpenClaw 运行时元数据；正文 `[origin] ...` 只是兼容 fallback。只有合法
origin object 才向 114/企微推送，手动 WebUI 入口通常只留审计。

## 同步回复

只返回最小结论，例如：

> 需求已受理，正在创建 Issue。

> 批次已受理，处理结果将逐条通知。

> 批次已持久化，正在等待旧执行队列排空。

> 执行请求信息不足，请补充完整 project 与 selector。

`waiting_for_legacy_drain` 与临时网络失败不会丢请求；dispatcher 周期 tick 会复用同一 batch
重试，不要求用户重发。

## 异步结果

每个匹配 Issue 只生成一个 durable terminal notification intent：

- done：`#<iid> 已处理完成，MR：<mr_url>`；
- failed：`#<iid> 处理未通过：<reason>`；
- timeout：`#<iid> 处理超时未完成，已停放待人工处理`；
- skipped：该 Issue 在实时预检时已 CLOSED、普通处理遇到 `pr` 或无需再执行；
- zero-match：`无匹配 OPEN Issue`，整个 batch 只通知一次。

不会发送额外批次进度或聚合汇总。通知通道失败时 intent 保留；duplicate I3 或周期 tick 会
继续投递，但不会重复计数。若成功日志已经写入而 `delivered_at` 尚未提交就中断，下次从
durable 日志修复，不再调用通知通道。

## 恢复与兼容

- I1 在调用 executor 前先持久化；ack 丢失后同 batch/correlation/payload 重投。
- 每个新 I1 使用独立 callback nonce；明文只留在私有 intent/I1，mirror 只保存摘要。I3 必须同时
  通过 nonce 摘要、完整 project 与 executor 身份校验；纯 I3 只兼容明确的部署前 legacy mirror。
- dispatcher mirror 不保存 IID snapshot，数百/数千 Issue 不会展开进旧 FIFO。
- 升级前旧 FIFO 继续排空；它非空时新 batch 不发送。
- 旧 `RUN_SINGLE_ISSUE` 在 executor 内转为 single batch，后续结果也走 I3；dispatcher bridge
  会在 terminal 或 zero-match 后清旧 active 并推进下一条。
- I3 accepted/duplicate 都带原 event_id；重复事件不会重复通知。

## 职责边界

dispatcher 不查询 GitLab Issue、不展开 IID、不自行跑 Issue。GitLab snapshot、并发槽位、
worktree、MR 和 retry 均由 req_executor 管理。

GitLab project 支持多层 subgroup path。多个裸路径候选会要求澄清；重跑动作允许放在 Issue
宾语之后，但否定措辞及 label/branch 值不会触发重跑。

配置见 [`config/dispatcher.env`](config/dispatcher.env) 与
[`config/README.md`](config/README.md)。关键部署项包括
`DEFAULT_EXECUTOR_AGENT,ROUTING_FILE,DISPATCHER_CALLBACK_TARGET,STATE_ROOT` 与用户通知 gateway
pin。`DISPATCHER_CALLBACK_TARGET` 为空时执行请求会在落 intent 前拒绝。
