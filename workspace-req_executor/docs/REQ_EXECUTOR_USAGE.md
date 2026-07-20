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
merge_target_branch=<auto_merge=true 时必填的 MR 目标分支>
```

根据 selector 类型再提供 `iid`、`iids`、`iid_min/iid_max` 或 `label`，可选处理基准分支
`branch`；启用 `auto_merge=true` 时必须同时提供非空的 `merge_target_branch`。dispatcher 在
生成 I1 前完成目标回退：明确的合并目标优先；未指定合并目标时回退到 `branch`；两者都未指定时
使用 `master`。executor 不从自由文本重新推断该策略，并会拒绝缺少目标分支的自动合并 I1。
`auto_merge=false` 时，MR 创建成功后以 `pr` 作为稳定完成态。`auto_merge=true` 时，固定外层
执行器先执行精确 MR GET、带预期 SHA 的 PUT 和精确 GET；只有后一次 GET 观察到匹配 MR 的
`state=merged`，才原子写入 `finish`。Phase 6 不延后这次首次标签写入，但会在提交 durable
终态和发送成功回调前，再次独立、有界地核验相同 MR 身份、分支和 SHA。单凭
`mr_result.json` marker 或回调字段永远不能授权 `finish` 或成功终态。
`force_rerun_pr=true` 表示用户明确要求重跑，并同时覆盖已有 `pr` 与 `finish` 两种稳定完成态；
字段名保留 `pr` 只是为了兼容既有 I1 schema。

### Issue 依赖分支

若 issueC 需要在 issueA 的实现之上继续开发，请在 issueC 描述中单独写一行：

```text
依赖 Issue #<issueA 的 IID>
```

例如 issueA 的 IID 是 `41`：

```text
依赖 Issue #41
```

兼容写法包括 `依赖于 #41`、`依赖于 Issue #41`、`前置 Issue: #41`、
`Depends on #41`、`Blocked by #41`、`dependency: #41` 与
`depends_on: 41`。声明必须位于独立行的行首，可带 Markdown 列表、标题或粗体前缀；正文中的
普通提及不会被误判。目前只允许一个同项目直接依赖，多个不同依赖、非法 IID 和自依赖会失败关闭。

issueA 处理时不会假设未来存在反向依赖：它先按普通 Issue 使用 `issue/<A IID>`，提交一次并创建
只关闭 A 的普通 MR。只有轮到 issueC、解析到 C 正文中的声明后，executor 才建立 `A -> C` 绑定；
A 与 C 可以位于同一批次，也可以位于不同批次。冻结范围不完整不会阻塞一个没有依赖声明的 A。

当前版本只支持两个节点的一对一关系 `A -> C`：A 不能再依赖其他 Issue，A 不能有第二个依赖者，
C 也不能再被其他 Issue 依赖。扇出、三节点以上链、环、自依赖、多个直接依赖和重叠持久化绑定都会
失败关闭。调度器仍可用当前冻结范围提前发现明显的非法拓扑，但范围外的已完成 A 会由 C 的直接声明
和 A 的 durable state 校验，不再仅因“不在当前冻结范围”而拒绝。

对 `A -> C`，唯一远端工作分支冻结为：

```text
issue/<A IID>+<C IID>
```

例如 A=`41`、C=`43`，A 完成时先存在 `issue/41`；C 被处理时，executor 将 A 的同一个提交迁移到
`issue/41+43`，此后 A、C 的 canonical work branch 都绑定为该组合分支。A 的本地 attempt 分支仍是
`issue/41-attNNN`，C 的本地 attempt 分支仍是 `issue/43-attNNN`，因此两个 worktree 不会尝试检出
同一个本地分支。一次正常 fresh 流程的最终提交历史严格为
`target -> commit(A) -> commit(C)`；独立 issueB 继续使用 `issue/<B IID>`，可以和 A 并行。

A 完成普通流程后，C 会等待 A 具有稳定的 `pr` 或 `finish` 标签，且没有 `continue`、`doing`、
`retry`、blocked、failed 或 timeout 工作流标签；当前 campaign 中也不能仍有 A 的
`pending_subagents` claim。若 A 来自当前 campaign，`completed_iids` 可作为完成证据；若 A 来自更早
campaign，则迁移器改用更强的 durable 校验：A 的 mode-600 私有 `done` 状态、`issue/A` 的完整远端
SHA、提交身份和唯一开放普通 MR 必须全部一致。

GitLab 不提供修改 MR `source_branch` 或原子重命名分支的接口，所以这里的“改名”由可恢复事务实现：
先写入 `branch_migration.status=pending` 检查点，以空期望 lease 在同一 A SHA 创建
`issue/A+C`，关闭 A 的旧 MR，创建同时包含 `Closes #A` 与 `Closes #C` 的替代 MR，再以精确 A SHA
lease 删除 `issue/A`，最后把 A 的 durable state 改写为共享 head。任一网络步骤中断都会保留检查点
并在后续 tick 幂等重放；不会重新运行 A、重新提交 A 或创建第二个替代 MR。稳定状态只有一个开放
组合 MR，但 GitLab 历史中会保留一个已关闭的 A 普通 MR IID 和一个开放的替代 MR IID。

迁移完成后，远端 `issue/A+C` 的完整 SHA 必须仍等于 A 的唯一提交，A 的状态绑定相同成员、共享
分支角色和替代 MR。C 的 fresh attempt 固定该 A SHA，并把它同时作为
`DEPENDENCY_BASE_SHA` 与 `EXPECTED_WORK_BRANCH_SHA`。提交前要求 C 的新提交恰好只有一个父提交且
父提交就是 A SHA；推送使用显式
`--force-with-lease=refs/heads/issue/A+C:<A SHA>`。远端移动、消失或父提交不一致都会失败关闭。
迁移器首次创建共享 ref 时使用空期望 lease，要求服务端更新瞬间该 ref 仍不存在。提交后 wrapper
固定新 commit 的完整 SHA，按该不可变 SHA 校验单父链、推送并回读精确远端 ref，不再信任随后
可能移动的本地 attempt ref 或 `HEAD`。

迁移器创建组合分支唯一开放的替代 MR，描述同时包含 `Closes #A` 与 `Closes #C`。C 推送后不会
关闭或新建 MR，而是核对 A durable state 中记录的替代 MR URL/IID，并复用它；来源分支、目标分支
和当前 source SHA 仍由固定脚本向 GitLab 精确验证。迁移器创建的 64 位十六进制 `intent_id` 会写入私有状态和
MR 描述，C 继承同一标识；MR 作者还必须是当前服务账号，且两条 `Closes` 必须完整存在。共享分支
当前强制 `auto_merge=false`；任一成员请求
自动合并都会以 `shared_branch_auto_merge_unsupported` 失败关闭。A、C 的 MR 目标分支一旦冻结也
不能改变。

迁移 A 时先使用 `branch_migration.status=pending` 检查点；C 在 push 并核对远端 SHA 后、进入 MR
阶段前使用 `mr_finalization.status=pending` 检查点。若 MR 创建、回读、标签写入或 callback 在此后
中断，当前 claim 会继续保留；迁移重放或 heartbeat 只针对已经固定的 SHA 恢复/核验 MR，然后把
状态提升为 `completed` 或 `verified_open`，不会再次运行 acpx、暂存、提交或推送。恢复只复用来源
分支、目标分支、所有权 intent 和 source SHA 全部一致的唯一开放替代 MR。
若精确 MR 身份已知但上次观察为 unknown，固定脚本会保留只读 identity evidence，再由 Phase 6
同时执行精确 IID GET 与来源分支开放 MR 唯一性查询后实时判定；关闭、移动、改目标或外来 MR
不能授权成功或替代 MR，GitLab 暂不可用才保留 claim。所有历史按页读取；同源分支存在多条历史、
分页被截断或重复时写入 `shared_mr_history_conflict` evidence，立即终态
`failed-dispatcher` 并生成 scheduler handoff，绝不创建替代 MR。
Phase 6 与 C 的依赖门禁都会重新实时读取 GitLab；`pr` 标签和 C 放行都不能仅凭 callback 中的 URL、
历史 `verified_open` 状态或未验证 marker 决定。

等待期间 C 不分配 attempt、不创建 pending placeholder、不添加 blocked 标签，也不占用 agent-wide
scheduler 执行槽。查询或解析 timeout 使用非终态 deferred 原因并在后续 tick 重试；确定性的非法
拓扑会先落盘 blocked 状态，再向 driven scheduler 返回精确 skip handoff。共享组、成员顺序、依赖
声明或目标分支一旦冻结，后续正文变更不能重写历史。`continue` 只恢复与 durable state 完全一致的
远端或 IID 本地 attempt ref，并再次固定其 SHA；旧格式、缺失、部分写入、分支移动或依赖 tuple
不匹配都会失败关闭。已发布的共享 head A 不允许走普通 `continue`，避免生成 A2；C 的
`continue` 会从冻结的 A SHA 重新形成替代提交，并用旧 C SHA 做 lease，因此最终历史仍严格只有
`commit(A) -> commit(C)`，不会变成 `A -> C1 -> C2`。

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
业务脚本访问该用户本来就能访问的文件或进程。仅应在同一信任域内使用共享依赖分支。

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

默认部署值为 `EXECUTOR_MAX_CONCURRENCY=3`、`EXECUTOR_ACPX_TIMEOUT_SECONDS=3600` 和 `EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`。可向 req_dispatcher 或 req_executor 发送 `/slot <正整数>` 调整共享物理并发，或发送 `/timeout-executor <时长>` 调整后续 attempt 的 acpx 上限。超时命令支持裸秒数、`Ns`、`Nm` 与 `Nh`，范围为 60 到 18000 秒，例如 `/timeout-executor 1h`。新值仅影响后续启动的 attempt，在途任务保留启动时预算。req_dispatcher 从同一 scheduler state 为后续调用派生 `acpx+3600` 的 executor turn、`acpx+3900` 的 exec 工具、`acpx+4200` 的旧队列回收和 `ceil((acpx+4200)/60)+20` 的 stuck 驱逐；旧 FIFO active/pending 固化创建时预算，调低新值不会追溯驱逐。OpenClaw 全局 timeout 独立保持部署值，不受命令影响。两类运行时值都持久化到共享 scheduler state。在线调低 slot 到小于当前 active 数时不会取消任务，而是停止新 reservation，等待 active 数自然降到新上限。scheduler 持久保存不可变 snapshot、游标与 active jobs，并在多个 runnable batch 间严格 round-robin。单个批次包含 100+ Issue 时，wrapper 每次只返回本 tick 所需的有限 grant/reconcile action，不把完整 IID 列表展开到聊天上下文。

超时控制命令使用 `/timeout-executor`，避免被 OpenClaw 内置命令的前缀路由识别；旧名称 `/acpx-timeout` 和 `/executor-timeout` 均不再接受。

部署周期触发固定为：

```text
RUN_EXECUTOR_BATCH_TICK
```

建议每分钟在 executor main session 唤醒一次。tick 会先对账 durable terminal counts，再检查运行任务的 `${LOG_DIR}/worker_result.json`。若 OpenClaw 在长工具调用返回后没有调度外层模型的最终回复，tick 会在当前 claim fence 下直接完成 Phase 6，并通过 `cleanup_actions` 回收仍占用 slot 的 child；随后扫描项目 durable intent、导入 terminal handoff、投递 callback outbox，并恢复未完成的 post-spawn coordinator。`run_acpx_attempt.sh` 会在 acpx 结束时先写 `${LOG_DIR}/acpx_terminal.json`；若完整结果在默认 2400 秒宽限期后仍未出现，tick 仅回收身份完全匹配的 child。之后 tick 用 scheduler active job 与未完成 launch coordinator 构造保护集，在项目锁内清除不受保护且没有任何运行标识的旧 placeholder。项目预检发现 running Issue 已有 `pr`、`finish` 或已关闭时，tick 会立即按当前 claim fence 重新核验 GitLab 并生成 `skipped` handoff，不再等待运行租约；超过运行租约且确已越过项目 ACPX 截止时间的丢回调任务仍由 timeout 路径兜底。最后才按严格 round-robin 补满空槽。单次 agent 级 topup 事务最多处理 256 个候选和 32 轮 skip 补位，具有 90 秒阶段 deadline，单个项目 wrapper 另有 75 秒墙钟上限；达到任一上限后立即释放锁，未处理的 reserved job 留到下一 tick。进程重启或聊天 turn 中断后，下一次 tick 从 durable state 继续。完成批次、已确认 outbox 和完成的 launch action 会退出热索引并保留在按 ID 可定位的冷记录中，周期成本只随活动工作量增长。

整个 topup/skip-finalize 事务由 agent 级 nonblocking tick 锁串行化；重叠唤醒立即返回 `idle`，不会使用旧的 pending 快照终结刚创建的新任务。
锁内所有子进程、scheduler 子锁和 launch-coordinator 双锁都只使用阶段剩余时间；超时后保留 durable
reserved 状态并由下一 tick 恢复。旧版迁移产生的 `legacy_running` 没有 secret claim token，遇到依赖
延期时只报告 `legacy_running_recovery_required`，不会放宽 CAS 或直接改写为 `retry_wait`。

每个 Issue 的终态逐项发送，不发送一条代替明细的聚合结果。callback transport 固定为：

```text
RUN_DRIVEN_BATCH_RESULT_ACK_ONLY
callback_envelope={"batch_acceptance":<strict 5-field acceptance>,"callback_nonce":"<64 hex>","executor_agent":"req_executor","worker_result_json":<strict 8-field I3 JSON>}
ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。
```

dispatcher 对同一 `event_id` 返回 `accepted` 或 `duplicate` 都表示该 I3 已确认；executor 只有收到匹配 event ID 的 ack 才把对应 outbox item 标记为 delivered。发送失败保留相同 event ID 重试，不重复生成 Issue 结果。
ack stdout 必须整体是唯一严格 JSON，或整体恰为单个 `json`/无语言 Markdown 围栏且 body 为
唯一严格 JSON。围栏外字符、中文总结、解释、双围栏、前后缀或多个 JSON 都按
`malformed_or_ambiguous_ack` 保留 outbox 并重试。dispatcher 仍接受旧
`RUN_DRIVEN_BATCH_RESULT` 输入 marker，但新 outbox 不再发送它。新 marker 缺失、伪造或追加
第三行也会在 durable apply 前失败关闭。

callback `openclaw` 子进程继承 executor 当前环境，包括按既定优先级选中的 `GITLAB_TOKEN`；`callback_envelope` 的字段集合仍按上述 I3 业务 schema 生成。

每次 outbox drain 默认最多实际投递 3 条；失败项持久保存 `next_attempt_at`，按 30 秒起步、最长 3600 秒的指数退避继续重试。可用进程环境 `DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK`、`DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS`、`DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS` 调整。预算耗尽或存在 100+ 失败积压时，同一 executor tick 仍继续 post-spawn recovery 和 reservation，不会让回调网络超时长期占住调度循环。

## 本地覆盖、升级与回滚

- 本地 `REPO_PARENT_PATH`、`EXECUTOR_SCHEDULER_ROOT`、初始 `EXECUTOR_MAX_CONCURRENCY`、初始 `EXECUTOR_ACPX_TIMEOUT_SECONDS`、`EXECUTOR_RUNNING_LEASE_SECONDS`、`EXECUTOR_AGENT` 或 `DISPATCHER_CALLBACK_TARGET` 只能通过进程环境或 ignored `config/campaign_defaults.local.env` 覆盖；显式 scheduler 进程环境优先，并须在 intake、tick、import、delivery 使用同一组值。`/slot` 和 `/timeout-executor` 写入的共享运行时值优先于初始配置。tracked 配置继续保留蓝区 GitLab host/protocol、token 注入、callback 和 `/data` 默认，不写本机路径或测试 endpoint。
- I1 schema 滚动升级必须先暂停新的执行请求，排空或停止旧 executor，部署并验证新版 executor 后，最后升级 dispatcher。旧 executor 的严格 I1 白名单不认识 `auto_merge` 与 `merge_target_branch`；新版 dispatcher 即使对普通请求也固定发送 `auto_merge=false`，所以任何新版 I1 都不得投递到旧 executor，自动合并请求也不得尝试降级执行。回滚时先停新入口与双方 tick，先回滚 dispatcher 或继续保留新版 executor；只有确认不会再发送新字段后才能回滚 executor。未完成自动合并 intent 保留在 durable state，等待兼容版本恢复。
- 升级时先排空 req_dispatcher 的旧 FIFO。旧 active/queue 非空期间，新 batch 只保持 `waiting_for_legacy_drain`，不与旧 single active 重叠；清空后由 `RUN_EXECUTOR_BATCH_TICK` 推进新 scheduler。
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
  .worktrees/issue-<iid>/
    .req_executor/issue-<iid>/output/
    .req_executor/issue-<iid>/log/attempt-NNN/
```

The outer subagent calls `run_executor_attempt.sh` exactly once. That fixed
wrapper owns the full attempt and persists `${LOG_DIR}/worker_result.json`.
Inside it, `run_acpx_attempt.sh` runs from `${WORKTREE_DIR}` and invokes:

```bash
acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"
```

The acpx invocation logic is intentionally centralized in that script. It
also writes `${LOG_DIR}/acpx_terminal.json` before returning to the wrapper.
