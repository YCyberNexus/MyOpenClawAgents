# req_executor Usage

`req_executor` takes GitLab issue content as the Claude Code task prompt. It does not require project material directories, runtime basename fields, or UI account-pool fields.

## Driven Single Issue

`req_dispatcher` sends:

```text
RUN_SINGLE_ISSUE
project=<group>/<project>
iid=<iid>
correlation_id=<id>
dispatcher_callback_target=<target>
executor_agent=req_executor
callback_nonce=<64 个小写 hex>
```

Optional:

```text
group=<group>
branch=<target-branch>
```

也可以用 `issue_url=<GitLab Issue URL>` 代替 `project+iid`；若两种形式同时提供，二者必须一致。`correlation_id` 可省略，此时 shim 会生成稳定的内容寻址 correlation/batch ID。

`dispatcher_callback_target` 与 `executor_agent` 必须精确匹配部署 pin，`callback_nonce` 必须为 64 个小写 hex。nonce 仅存于私有 I1/request/outbox，不进入公开 acceptance 或八字段 Issue 结果。`dispatch_single_issue.sh` 校验 trigger、生成稳定 ID 并委托共享 driven wrapper。共享 driven 调度链从 executor 自身的进程环境或 `config/gitlab.env` 加载 `GITLAB_TOKEN`，把它直接写入内部 scheduled trigger 与子任务 prompt，并读取 `config/campaign_defaults.env` / ignored `config/campaign_defaults.local.env` 的 clone 与 scheduler 配置。single shim 进入 agent-wide driven scheduler，不再合成独立的单并发 scheduled campaign。

## Driven Batch I1 与公开 acceptance

批量入口为：

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<stable-id>
correlation_id=<stable-id>
project=<group>/<project>
selector_type=single|iid_list|range|open_unfinished|open_label
dispatcher_callback_target=<target>
executor_agent=req_executor
callback_nonce=<64 个小写 hex>
force_rerun_pr=true|false
auto_merge=true|false
branch=<可选处理基准分支>
merge_target_branch=<可选 MR 目标分支>
```

根据 selector 类型再提供 `iid`、`iids`、`iid_min/iid_max` 或 `label`，可选处理基准分支
`branch`。明确的请求分支优先；请求未指定时，executor 逐个读取 Issue 描述中的版本化基准分支
marker 或唯一严格分支声明，再回退到仓库 `origin/HEAD`。明确的合并目标优先；未指定时，MR 目标
跟随最终处理基准。因此 `auto_merge=true` 的 I1 可以暂时不带 `merge_target_branch`，但 executor
必须在工作树准备前解析并冻结具体目标；非法或互相冲突的 Issue 声明会 fail closed。
`auto_merge=false` 时，MR 创建成功后以 `pr` 作为稳定完成态。`auto_merge=true` 时，固定外层
执行器先执行精确 MR GET，对 GitLab 的临时 merge-readiness 状态做有界只读复核，再执行带预期
SHA 的唯一 PUT 和精确 GET；只有后一次 GET 观察到匹配 MR 的
`state=merged`，才原子写入 `finish`。Phase 6 不延后这次首次标签写入，但会在提交 durable
终态和发送成功回调前，再次独立、有界地核验相同 MR 身份、分支和 SHA。单凭
`mr_result.json` marker 或回调字段永远不能授权 `finish` 或成功终态。
`force_rerun_pr=true` 表示用户明确要求重跑，并同时覆盖已有 `pr` 与 `finish` 两种稳定完成态；
字段名保留 `pr` 只是为了兼容既有 I1 schema。

### Issue 依赖 DAG v2

若 issueC 需要在一个或多个已完成 Issue 的实现之上继续开发，请让其描述中的某一行以声明开头：

```text
依赖 Issue #41
依赖 Issue #41,#42
```

兼容写法包括 `依赖于 #41`、`依赖于 Issue #41`、`前置 Issue: #41`、
`Depends on #41`、`Blocked by #41`、`dependency: #41` 与
`depends_on: 41`。多依赖接受英文逗号、中文逗号及逗号两侧空格，例如 `#41, #42`。声明必须从原始
Markdown 的行首开始，可带列表、标题或粗体前缀；合法 IID 列表后允许以空白继续书写 `page-name`
等其他内容，不要求声明占满整行。声明按出现顺序稳定去重，最多 8 个；超过上限、非法 IID 和自依赖
会失败关闭。

新依赖使用 DAG v2。每个 Issue 独立拥有 worktree、远端工作分支、私有状态和 MR；consumer 只读取
已完成 predecessor 的不可变 artifact，不会迁移、删除或改写 predecessor 分支，不会关闭或替换其 MR，
也不会把 predecessor 私有状态改成共享 head。因此同一 predecessor 可以供多个 consumer 使用
（fan-out），已完成 consumer 也可以继续成为后续层级的 predecessor。支持单输入、2–8 个多输入以及
多级依赖；自依赖和环仍失败关闭。

每个 DAG v2 consumer 的分支由完整计划摘要内容寻址：

```text
issue/<consumer IID>-dag-<plan_sha256 前 16 位>
```

完整 64 位小写 `plan_sha256` 才是权威身份，短后缀只用于可读分支名。每个 consumer 从自己的分支创建
或重用自己的 MR，不重用 predecessor MR。一个典型图可以同时包含 `#9 -> #12/#13`、
`#9+#13 -> #14`、`#13+#14 -> #15` 和 `#15 -> #16`。

consumer 会等待所有可达 predecessor 都具有稳定的 `pr` 或 `finish`，且没有 `continue`、`doing`、
`retry`、blocked、failed 或 timeout 标签。GitLab 实时标签是完成状态的权威来源：对已有的普通
Issue，只要 live Issue 为稳定 `pr`（兼容 `finish`）且本次 fetch 后存在精确的
`refs/remotes/origin/issue/<iid>`，就直接冻结该分支当前 SHA 并放行；不要求该 Issue 曾进入当前
batch，也不要求本机存在对应的 execution ID、`state.json` 或 `pending_subagents` 历史缓存。缓存中的
残留 pending claim 不能推翻 live `pr`；同一 tick 明确选择 predecessor 重跑时仍由独立 fence 阻止
consumer 抢跑。

普通 GitLab-authoritative snapshot 记录 `identity_source:"gitlab_pr_label_branch"`、IID、
`issue/<iid>` 和相等的 `commit_sha` / `work_branch_sha`。只有没有普通 `issue/<iid>` ref 的
content-addressed DAG predecessor 才继续校验 mode-600 私有 `done` 状态、execution ID、完整 work
branch/commit SHA，以及唯一 MR 的 IID、URL、`opened|merged` 状态、source、target 和 SHA。

predecessor snapshot 同时冻结业务 `commit_sha=B` 与远端实际
`work_branch_sha=L`。两者不同时，`L` 必须恰好是 `B` 的单父直接子提交，且全部 diff 都位于该次
execution 的日志目录；打开的 MR SHA 绑定 `L`，已合并 MR 可记录 `B` 或 `L`。计划摘要绑定两者，
但传递约简和聚合只使用业务提交 `B`。该 B/L 拆分只适用于 executor-state snapshot；普通
GitLab-authoritative snapshot 明确以 `issue/<iid>` 当前分支 tip 作为基线，因此其中 `B=L`。

planner 先做传递约简：若某个声明输入的精确提交已经是另一声明输入提交的祖先，就从 effective frontier
删除前者。例如 `#14` 声明依赖 `#9,#13` 且 `#13` 已包含 `#9` 时，`declared_inputs` 仍保留两项，
`effective_inputs` 只保留 `#13`，基线直接使用 `#13` 的 SHA。多个互不可比 frontier 按声明顺序使用
确定性的 `merge-tree` / `commit-tree` 聚合。内容冲突返回 `dependency_merge_conflict` 并阻塞
consumer；系统不自动选择 ours/theirs，也不改变任何 predecessor artifact、分支、MR 或状态。同一组
输入重放会得到相同 aggregate SHA 和 `plan_sha256`。

权威 `dependency_plan` 固定 `version:2`、consumer IID、目标分支、`declared_inputs`、
`effective_inputs`、`aggregate_base_sha`、完整 `plan_sha256` 和派生 `work_branch`。执行态同时保存
`dependency_contract_version:2` 与 `dependency_plan_sha256`。旧的标量
`dependency_iid/dependency_branch/dependency_base_sha` tuple 只作为兼容投影存在，不表示完整 DAG。

fresh attempt 将 `aggregate_base_sha` 同时固定为 `DEPENDENCY_BASE_SHA` 和
`EXPECTED_COMMIT_PARENT_SHA`，业务提交必须且只能有这一个父提交。continue 使用旧 consumer tip 作为
push lease，但 mixed-reset 到同一个冻结基线并保留工作树差异，因此替换 consumer 提交而不是形成
`base -> C1 -> C2`。正文依赖、目标分支、predecessor artifact、基线、计划摘要或远端身份在冻结后
发生变化，都失败关闭。

DAG v2 每个 Issue 独立创建 MR，并强制 `auto_merge=false`，成功停在 `pr`。自动合并单个 DAG 节点会
绕过拓扑调度及冻结父提交合同，因此即使 batch 请求启用了自动合并也不会降级执行。普通无依赖 Issue
仍保留原有 server-verified auto-merge 流程。

已有 `issue/<head>+<tail>` shared pair 和 version-1 fan-in durable state 仅用于滚动升级兼容。固定
wrapper 仍可按旧的 head/tail、branch migration、replacement MR 与 recovery checkpoint 合同完成
已经在途的工作；新依赖声明一律创建 DAG v2 计划，不再新建或扩展 legacy shared group。

等待期间 C 不分配 attempt、不创建 pending placeholder、不添加 blocked 标签，也不占用 agent-wide
scheduler 执行槽。查询或解析 timeout 使用非终态 deferred 原因并在后续 tick 重试；确定性的非法
拓扑、环、artifact 身份或合并冲突会先落盘 blocked 状态，再向 driven scheduler 返回精确 skip
handoff。`continue` 只恢复与 durable contract 完全一致的远端或 IID 本地 attempt ref；缺失、部分
写入、分支移动、版本或 plan digest 不匹配都会失败关闭。

业务代码来自已固定的基线 SHA，但直接执行控制路径（任意层级的 `.claude/`、`CLAUDE.md`、
`CLAUDE.local.md`、`.mcp.json` 与 `.acpxrc.json`）仍只从原始可信处理分支刷新。物化依赖提交时
显式禁用 Git hook、fsmonitor、外部 attributes 与子模块递归，并在 checkout 前拒绝会启动外部
clean/smudge/process 命令的 `filter` attributes。固定 wrapper 的 fetch 使用完整
`refs/heads/*:refs/remotes/origin/*` 或单分支 refspec 并清空 refmap；提交图、祖先和物化校验还设置
`GIT_NO_REPLACE_OBJECTS=1`，避免仓库配置的 fetch 映射或 `refs/replace` 改写 A/C 父链判断。

依赖 attempt 还要求 executor 进程提供两个工作站/服务器本地值：
`CLAUDE_CODE_EXECUTABLE` 必须是仓库外的绝对可执行路径，且实际 `--help` 支持
`--safe-mode`；`CLAUDE_AGENT_ACP_ROOT` 必须是仓库外预安装的
`@agentclientprotocol/claude-agent-acp` `0.37.0` 包根目录。wrapper 会显式使用固定 adapter、空 MCP
配置、`CLAUDE_CODE_SAFE_MODE=1`、`--approve-all` 与
`--non-interactive-permissions deny`，从而不让依赖提交中的 `.acpxrc.json`、`.npmrc`、Claude
memory、hook、MCP 或 plugin 改写模型启动链。任一能力或固定包校验失败时，依赖 attempt 在 acpx
启动前失败关闭。这两个值只能放入 executor 进程环境或 ignored 本地 env，不能写入 tracked
蓝区配置。executor 的 `PATH` 还必须只包含绝对目录；wrapper 会在加载路径/鉴权 bootstrap 前拒绝
相对项、目标仓库或 worktree 内目录，随后从剩余的仓库外路径固定解析实际 `timeout` 与 `acpx`
可执行文件。

该功能沿用 req_executor 现有的同 UID 仓库执行信任模型，并不把依赖业务代码变成安全沙箱。也就是
说，固定 adapter、安全模式和空 MCP 配置会收窄模型启动入口，但不能阻止同一系统用户有权执行的
业务脚本访问该用户本来就能访问的文件或进程。仅应在同一信任域内使用依赖 DAG。

`iid_list` 的 `iids` 必须是至少两个升序去重的逗号分隔正整数，例如 `1,4,5`。I1 字段用于
项目、selector、处理及合并策略与回调路由；executor 按进程环境优先、tracked
`config/gitlab.env` 回退的顺序加载 `GITLAB_TOKEN`，完成 OPEN Issue 查询，并在内部执行链和
子任务 prompt 中直接传递该值。私有仓库网络 Git 操作使用普通 `git`，`origin` 为
`${GITLAB_API_PROTOCOL}://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GROUP}/${PROJECT}.git`
形式的直接认证 URL，Git 子进程继承 executor 当前环境。Issue 列表使用 GraphQL cursor 完整
扫描，重复 IID、异常游标或扫描预算耗尽都会失败关闭；只有连续两次规范化结果一致才冻结不可变
snapshot。

`run_driven_issue_batch.sh` 与 `dispatch_single_issue.sh` 的 rich envelope 只用于 runtime 编排。先处理 `cleanup_actions`，再按数组原序串行完成 `reconcile_actions`、`spawn_grants` 及逐条 `sessions_spawn` ack；之后 Path C/E 必须调用固定 `emit_driven_batch_acceptance.sh`，并把它的唯一一行 JSON 原样返回。公开 acceptance 字段集合固定为：

```text
status,batch_id,matched_count,snapshot_digest,scheduler_status
```

不得用 rich envelope、`chat_summary` 或手工构造的 JSON 替代这五字段 acceptance。

## Durable scheduler、周期 tick 与 I3

默认部署值为 `EXECUTOR_MAX_CONCURRENCY=10`、`EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1`、`EXECUTOR_ACPX_TIMEOUT_SECONDS=3600` 和 `EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`。可向 req_dispatcher 或 req_executor 发送 `/slot <正整数>` 调整共享并行仓库数上限，发送 `/repo-slot <正整数>` 调整每个仓库的 Issue 并发上限，或发送 `/timeout-executor <时长>` 调整后续 attempt 的 acpx 上限。仓库内默认串行，不同仓库可并行。超时命令支持裸秒数、`Ns`、`Nm` 与 `Nh`，范围为 60 到 18000 秒，例如 `/timeout-executor 1h`。新值仅影响后续启动的 attempt，在途任务保留启动时预算。req_dispatcher 从同一 scheduler state 为后续调用派生 `acpx+3600` 的 executor turn、`acpx+3900` 的 exec 工具、`acpx+4200` 的旧队列回收和 `ceil((acpx+4200)/60)+20` 的 stuck 驱逐；旧 FIFO active/pending 固化创建时预算，调低新值不会追溯驱逐。OpenClaw 全局 timeout 独立保持部署值，不受命令影响。三个运行时值都持久化到共享 scheduler state。在线调低并发不会取消已启动任务：`/slot` 暂停新仓库进入并等待活跃仓库数回落，`/repo-slot` 由下一 tick 退回尚未启动的多余 reservation 并等待已启动 Issue 自然回落。scheduler 持久保存不可变 snapshot、游标与 active jobs，并在多个 runnable batch 间严格 round-robin。单个批次包含 100+ Issue 时，wrapper 每次只返回本 tick 所需的有限 grant/reconcile action，不把完整 IID 列表展开到聊天上下文。

超时控制命令使用 `/timeout-executor`，避免被 OpenClaw 内置命令的前缀路由识别；旧名称 `/acpx-timeout` 和 `/executor-timeout` 均不再接受。

部署周期触发固定为：

```text
RUN_EXECUTOR_BATCH_TICK
```

建议每分钟在 executor main session 唤醒一次。tick 会先对账 durable terminal counts，再同时检查运行任务的 `${LOG_DIR}/worker_result.json` 与最后发布的私有 `${LOG_DIR}/attempt_finalized.json`。只有 marker 的 Issue、execution、工作分支、业务 commit 和 `worker_result` SHA-256 全部匹配，结果才可消费；归档/状态尚未收尾时不会提前 Phase 6 或回收 child。若进程在推送日志子提交后崩溃，当前 claim 下的恢复路径只会在严格证明 `B -> L` 为该 execution 的直接 log-only 子提交后修复 `work_branch_sha` 并补齐 marker。若 OpenClaw 在长工具调用返回后没有调度外层模型的最终回复，tick 会在当前 claim fence 下直接完成 Phase 6，并通过 `cleanup_actions` 回收仍占用 slot 的 child；随后扫描项目 durable intent、导入 terminal handoff、投递 callback outbox，并恢复未完成的 post-spawn coordinator。`run_acpx_attempt.sh` 会在 acpx 结束时先写 `${LOG_DIR}/acpx_terminal.json`；若完整结果在默认 2400 秒宽限期后仍未出现，tick 仅回收身份完全匹配的 child。之后 tick 用 scheduler active job 与未完成 launch coordinator 构造保护集，在项目锁内清除不受保护且没有任何运行标识的旧 placeholder。项目预检发现 running Issue 已有 `pr`、`finish` 或已关闭时，tick 会立即按当前 claim fence 重新核验 GitLab 并生成 `skipped` handoff，不再等待运行租约；超过运行租约且确已越过项目 ACPX 截止时间的丢回调任务仍由 timeout 路径兜底。最后才按严格 round-robin 补满空槽。单次 agent 级 topup 事务最多处理 256 个候选和 32 轮 skip 补位，具有 90 秒阶段 deadline，单个项目 wrapper 另有 75 秒墙钟上限；达到任一上限后立即释放锁，未处理的 reserved job 留到下一 tick。进程重启或聊天 turn 中断后，下一次 tick 从 durable state 继续。完成批次、已确认 outbox 和完成的 launch action 会退出热索引并保留在按 ID 可定位的冷记录中，周期成本只随活动工作量增长。

整个 topup/skip-finalize 事务由 agent 级 nonblocking tick 锁串行化；重叠唤醒立即返回 `idle`，不会使用旧的 pending 快照终结刚创建的新任务。
锁内所有子进程、scheduler 子锁和 launch-coordinator 双锁都只使用阶段剩余时间；超时后保留 durable
reserved 状态并由下一 tick 恢复。旧版迁移产生的 `legacy_running` 没有 secret claim token，遇到依赖
延期时只报告 `legacy_running_recovery_required`，不会放宽 CAS 或直接改写为 `retry_wait`。

从未生成 `attempt_finalized.json` 的旧 wrapper 升级到该合同时，必须先 drain 旧版本 active jobs，
再切换周期 tick；新 heartbeat 不会把无 marker 的旧 `worker_result.json` 猜测为已完成。

每个 Issue 的终态逐项发送，不发送一条代替明细的聚合结果。callback transport 固定为：

```text
RUN_DRIVEN_BATCH_RESULT_ACK_ONLY
callback_envelope={"batch_acceptance":<strict 5-field acceptance>,"callback_nonce":"<64 hex>","executor_agent":"req_executor","worker_result_json":<strict 8-field I3 JSON>}
ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。
```

dispatcher 对同一 `event_id` 返回 `accepted` 或 `duplicate` 都表示该 I3 已确认；executor 只有收到匹配 event ID 的 ack 才把对应 outbox item 标记为 delivered。发送失败保留相同 event ID 重试，不重复生成 Issue 结果。
callback transport 在目标 session 锁内记录调用前 transcript 游标，并只读取本轮新增的成功
`exec` toolResult；其中必须只有一个 compact JSON 或单个 fence JSON object。模型最终中文总结、
解释或 Markdown 不参与 ack。找不到唯一工具回执、双 JSON 或 malformed 输出都按
`malformed_or_ambiguous_ack` 保留 outbox 并重试。dispatcher 仍接受旧
`RUN_DRIVEN_BATCH_RESULT` 输入 marker，但新 outbox 不再发送它。新 marker 缺失、伪造或追加
第三行也会在 durable apply 前失败关闭。

callback `openclaw` 子进程继承 executor 当前环境，包括按既定优先级选中的 `GITLAB_TOKEN`；`callback_envelope` 的字段集合仍按上述 I3 业务 schema 生成。

每次 outbox drain 默认最多实际投递 3 条；失败项持久保存 `next_attempt_at`，按 30 秒起步、最长 3600 秒的指数退避继续重试。可用进程环境 `DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK`、`DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS`、`DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS` 调整。预算耗尽或存在 100+ 失败积压时，同一 executor tick 仍继续 post-spawn recovery 和 reservation，不会让回调网络超时长期占住调度循环。

## 本地覆盖、升级与回滚

- 本地 `REPO_PARENT_PATH`、`EXECUTOR_SCHEDULER_ROOT`、初始 `EXECUTOR_MAX_CONCURRENCY`、初始 `EXECUTOR_MAX_ISSUES_PER_REPOSITORY`、初始 `EXECUTOR_ACPX_TIMEOUT_SECONDS`、`EXECUTOR_RUNNING_LEASE_SECONDS`、`EXECUTOR_AGENT` 或 `DISPATCHER_CALLBACK_TARGET` 只能通过进程环境或 ignored `config/campaign_defaults.local.env` 覆盖；显式 scheduler 进程环境优先，并须在 intake、tick、import、delivery 使用同一组值。`/slot`、`/repo-slot` 和 `/timeout-executor` 写入的共享运行时值优先于初始配置。tracked 配置继续保留蓝区 GitLab host/protocol、token 注入、callback 和 `/data` 默认，不写本机路径或测试 endpoint。
- I1 schema 滚动升级必须先暂停新的执行请求，排空或停止旧 executor，部署并验证新版 executor 后，最后升级 dispatcher。旧 executor 的严格 I1 白名单不认识 `auto_merge` 与 `merge_target_branch`；新版 dispatcher 即使对普通请求也固定发送 `auto_merge=false`，所以任何新版 I1 都不得投递到旧 executor，自动合并请求也不得尝试降级执行。回滚时先停新入口与双方 tick，先回滚 dispatcher 或继续保留新版 executor；只有确认不会再发送新字段后才能回滚 executor。未完成自动合并 intent 保留在 durable state，等待兼容版本恢复。
- 升级时先排空 req_dispatcher 的旧 FIFO。旧 active/queue 非空期间，新 batch 只保持 `waiting_for_legacy_drain`，不与旧 single active 重叠；清空后由 `RUN_EXECUTOR_BATCH_TICK` 推进新 scheduler。
- 从顺序执行次数升级到随机 `execution_id` 时，也必须先用旧版本排空项目的
  `pending_subagents`、`driven_handoff_intents` 和 executor scheduler 中的旧版
  `launch_actions`。新版本不会根据旧次数推导身份：项目侧返回
  `legacy_execution_identity_drain_required`；scheduler tick 返回
  `legacy_execution_schema`/`drain_required` 并暂停新 spawn，同时保持旧 action
  原字节不变。项目完全静默后，新版本才会在持有 `campaign.lock` 时执行一次
  旧次数字段清理。
- 认证回调上线前已经存在于 executor 私有 scheduler 根、且同时缺少 `executor_agent` 与 `callback_nonce` 的旧 request/outbox，会在读取时一次性显式标记为 `legacy_pre_upgrade`，并用 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` 加 `worker_result_json=<严格八字段 I3>` 完成旧 mirror。dispatcher 仍接受旧 marker 以兼容已发出的在途消息。新 I1 始终强制 nonce、executor 与固定 target；触发输入不能请求或伪造 `legacy_pre_upgrade`。
- 新旧锁目录滚动升级默认保留 86400 秒兼容窗口（起点持久化在 scheduler 根的 `lock_layout_v2.json`）。窗口内新进程同时获取旧、新两条 callback/launch 锁；窗口后才在双锁保护下把旧锁移出热目录。只有确认所有旧 executor 进程已停止，才可用 `DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0` 提前结束窗口。
- 回滚时先停止新的 batch 入口和周期 tick。可先排空，也可保留 scheduler state、batch snapshot、handoff 与 callback outbox 等 durable 记录等待恢复；不得删除运行时 state/outbox，也不得用新 batch ID 替代未完成批次。

## Scheduled Trigger

Minimum scheduled trigger:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
group=<group>
project=<project>
gitlab_token=<token>
issue_min_iid=<min_iid>
issue_max_iid=<max_iid>
hourly_issue_quota=<quota>
max_runtime_minutes=<minutes>
blocked_retry_limit=<limit>
blocked_cooldown_ticks=<cooldown>
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
```

Common optional fields:

- `branch` (omitted means the remote default branch from `origin/HEAD`)
- `repo_path`
- `max_concurrent_subagents`
- `acpx_timeout_seconds`
- `stuck_after_minutes`
- `issue_iids`
- `require_labels`
- `require_labels_match`
- `result_note_enabled`
- `model_tiers`
- `continue_upgrade_threshold`

Do not send runtime basename, data directory, or UI account-pool fields.
Do not send the legacy `run_timeout_seconds` field. OpenClaw 2026.6.11 reads
the optional global `agents.defaults.subagents.runTimeoutSeconds` internally;
it is not visible in an individual `sessions_spawn` call.

## Runtime Layout

```text
${REPO_PATH}/.req_executor/
  _dispatcher/
  issues/issue-<iid>/
    executions/execution-<execution_id>.json
  .worktrees/issue-<iid>/
    .req_executor/issue-<iid>/output/
    .req_executor/issue-<iid>/log/execution-<execution_id>/
```

The outer subagent calls `run_executor_attempt.sh` exactly once. That fixed
wrapper owns the full execution, persists `${LOG_DIR}/worker_result.json`,
completes archive/state persistence, and publishes
`${LOG_DIR}/attempt_finalized.json` last.
Inside it, `run_acpx_attempt.sh` runs from `${WORKTREE_DIR}` and invokes:

```bash
acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"
```

The acpx invocation logic is intentionally centralized in that script. It
also writes `${LOG_DIR}/acpx_terminal.json` before returning to the wrapper.

`${WORKTREE_DIR}`、`${OUTPUT_DIR}` 与本地 `issue/<iid>` 分支均按 Issue 固定。
每次启动生成随机、不递增的 `execution_id`，并写入独立的状态文件与日志目录，用于拒绝
过期回调；它不表达该 Issue 已运行多少次，后续执行也不会覆盖前一次的运行证据。
