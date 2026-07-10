# OpenClaw 子代理派发兼容性设计

## 背景

`workspace-acpx_auto_tester` 与 `workspace-req_executor` 当前把每个 issue 的外层执行提示通过 `sessions_spawn` 派发给匿名子代理。现有技能契约使用 `payload=`，并逐次传入 `timeoutSeconds=30` 与 `runTimeoutSeconds=<run_timeout_seconds>`。

本机安装的 OpenClaw 与 `10.64.5.104` 服务器版本一致，均为 `OpenClaw 2026.6.11 (e085fa1)`。该版本的实际工具定义表明：

- `sessions_spawn` 的任务正文必填参数是 `task`；
- `timeoutSeconds` 与 `runTimeoutSeconds` 都禁止逐次传入；
- 子代理运行上限只能通过 `agents.defaults.subagents.runTimeoutSeconds` 做全局配置；
- `label`、`runtime`、`mode`、`cleanup` 与 `context` 是兼容参数。

因此当前派发会在工具参数校验阶段失败，子代理不会启动；相同参数的三次启动重试只会重复同一个确定性错误。

## 目标

1. 让 `workspace-acpx_auto_tester` 与 `workspace-req_executor` 使用 OpenClaw 2026.6.11 支持的 `sessions_spawn` 参数。
2. 从触发器、状态、脚本、派发信封和文档中彻底删除 `run_timeout_seconds`。
3. 保留 `acpx_timeout_seconds` 作为 `run_acpx_attempt.sh` 的内部墙钟上限。
4. 在不强制设置全局子代理运行上限的前提下，继续提供稳定的 stuck 驱逐默认值。
5. 保持 `workspace-req_dispatcher` 当前合法的 `openclaw agent --timeout` 调用不变，只修订陈旧的跨工作区说明。
6. 为三个工作区增加能阻止旧契约回归的自动化检查，并按仓库规则更新对应技能版本。

## 非目标

- 不修改 `10.64.5.104` 的 OpenClaw 配置文件。
- 不强制要求 `agents.defaults.subagents.runTimeoutSeconds` 存在或为正数。
- 不重命名内部文件 `spawn_payload.txt`、字段 `payload_path` 或其他不属于工具参数的 payload 概念。
- 不改变子代理完成回调、GitLab 状态机、`acpx_timeout_seconds` 超时停放及部分成果推送逻辑。
- 不删除 `workspace-req_dispatcher` 的 CLI `--timeout`，因为 OpenClaw 2026.6.11 的 `openclaw agent` 明确支持该参数。

## 派发接口

两个直接派发子代理的工作区统一使用以下调用形状：

```text
sessions_spawn(
  task=payload,
  label=entry.child_label,
  runtime="subagent",
  mode="run",
  cleanup="keep",
  context="isolated"
)
```

其中局部变量 `payload` 仍表示从 `entry.payload_path` 读取的 `spawn_payload.txt` 完整文本；它只作为 `task` 的值，不再作为参数名。

仍保留以下启动行为：

- 每个 IID 匿名派发，不设置 session name 或 `taskName`；
- 严格串行调用 `sessions_spawn`；
- 有效启动确认必须同时包含非空 `runId` 与 `childSessionKey`；
- 无效启动最多重试三次，相邻两次固定等待两秒，且每次使用完全相同的兼容参数；
- 三次失败后继续走既有 `launch_failed`／`blocked-dispatcher` 状态处理。

## 超时与 stuck 语义

### 删除 `run_timeout_seconds`

`run_timeout_seconds` 将从以下所有界面删除：

- scheduled trigger 与单 issue 合成 trigger；
- trigger 解析、默认值及交叉校验；
- `campaign_state.json` 初始结构和持久化结构；
- `dispatch_prepare_tick.sh` 输出信封；
- `RUN_SINGLE_ISSUE` 的环境变量与配置读取；
- `SKILL.md`、`SOUL.md`、`CLAUDE.md`、参考文档、使用文档与状态机说明。

新触发器继续传入 `run_timeout_seconds` 时，新增的遗留字段校验会返回明确输入错误；当前解析器会容忍一般未知字段，因此不能依赖通用未知字段校验。加载旧 `campaign_state.json` 时，迁移逻辑删除遗留的 `.run_timeout_seconds`，避免旧值继续被误认为有效配置。

### 保留 `acpx_timeout_seconds`

`acpx_timeout_seconds` 继续控制 `run_acpx_attempt.sh` 内部的 GNU `timeout`，默认值仍为 `18000` 秒。`ACPX_EXIT=124`、`ACPX_EXIT=137`、缺失 `ACPX_EXIT=` 以及死亡回调的终态分类保持现有规则。

### `stuck_after_minutes` 默认值

由于不再存在逐次子代理上限，未显式提供 `stuck_after_minutes` 时按内部 acpx 预算计算：

```text
ceil((acpx_timeout_seconds + 120) / 60) + 30
```

默认 `acpx_timeout_seconds=18000` 时结果仍为 `332` 分钟。显式 `stuck_after_minutes` 继续覆盖派生默认值，现有最小值和整数校验保持不变。

### 可选全局配置

部署可以不设置 `agents.defaults.subagents.runTimeoutSeconds`，也可以将其设为 `0`；代码不做强制校验。若运维选择设置正数，文档建议至少满足：

```text
agents.defaults.subagents.runTimeoutSeconds >= acpx_timeout_seconds + 120
```

该建议只用于避免外层子代理先于内部 acpx 超时流程终止，不成为运行时阻断条件。

## 工作区改动边界

### `workspace-acpx_auto_tester`

- 修正 `SKILL.md` 的工具调用、重试约束和长描述。
- 修正 `CLAUDE.md`、`SOUL.md`、参考文档、脚本注释、使用文档及状态机中的旧参数说明。
- 删除脚本和状态结构中的 `run_timeout_seconds`。
- 增加静态派发契约测试与 timeout/stuck 迁移测试。
- 将主技能版本更新为 `SKILL_VERSION=2026-07-10.1`。

### `workspace-req_executor`

- 完成与 `workspace-acpx_auto_tester` 相同的派发与 timeout 状态迁移。
- 从 `dispatch_single_issue.sh` 删除 `RUN_TIMEOUT_SECONDS` 读取及 `run_timeout_seconds=` 合成逻辑。
- 更新 `REQ_EXECUTOR_USAGE.md`、部署配置说明及相关参考文档。
- 扩展现有 shell 测试，覆盖正确工具参数、禁止逐次 timeout 参数、单 issue 不再合成旧字段以及旧状态迁移。
- 将主技能版本更新为 `SKILL_VERSION=2026-07-10.1`。

### `workspace-req_dispatcher`

- 保持 `run_agent_turn.sh` 与 `openclaw agent --timeout` 不变。
- 给已经被 CLI 实现取代的历史设计／计划加明确的“已取代”说明，避免继续把 `sessions_spawn` 当作命名下游 agent 调用原语。
- 在当前跨工作区设计和部署检查中说明：`req_executor` 内部使用 `task` 派发，不接受逐次 timeout 参数；全局上限为可选配置。
- 增加文档契约检查，并复跑现有 CLI timeout 与 executor queue 测试。
- 将主技能版本更新为 `SKILL_VERSION=2026-07-10.1`。

## 错误处理与兼容性

- 旧触发器中的 `run_timeout_seconds` 会变成显式输入错误，不再被静默接受。
- 旧状态文件中的同名字段会在加载时被删除，不要求人工编辑状态文件。
- 如果全局子代理上限过短，运行时仍可能提前结束子代理；方案明确选择不在派发前阻断这种部署。死亡回调和 stuck 驱逐继续提供恢复边界。
- 如果没有全局子代理上限，内部 `acpx_timeout_seconds` 仍会结束 acpx 命令，子代理随后按既有步骤处理部分成果和终态。
- `req_dispatcher` 的同步 CLI 调用与子代理工具是两套接口；CLI `--timeout` 不受本次删除影响。

## 测试设计

先增加失败测试并确认它们能捕获当前旧契约，再实施最小修复。

1. `workspace-acpx_auto_tester`：
   - 断言直接调用示例使用 `task=payload`；
   - 断言不存在 `sessions_spawn(payload=...)`、`timeoutSeconds=` 或 `runTimeoutSeconds=`；
   - 断言信封与状态结构不再包含 `run_timeout_seconds`；
   - 断言 stuck 默认值随 `acpx_timeout_seconds` 按新公式派生；
   - 断言旧状态迁移会删除遗留字段。
2. `workspace-req_executor`：
   - 执行与 acpx 工作区相同的派发契约检查；
   - 断言 `RUN_SINGLE_ISSUE` 不再读取或合成 `run_timeout_seconds`；
   - 复跑 prompt、callback、状态及本地配置安全测试。
3. `workspace-req_dispatcher`：
   - 断言运行时技能不声明或调用 `sessions_spawn`；
   - 复跑 `openclaw agent --timeout`、executor queue 派发和启动重试测试；
   - 断言当前部署说明准确区分 CLI timeout 与子代理全局 timeout。
4. 最后对三个工作区执行全量 shell 测试，并用仓库级 `rg` 检查所有活跃契约中是否仍有旧参数赋值。

## 部署说明

代码部署后，运维无需为了兼容性强制修改 OpenClaw 全局配置。若希望给子代理增加外层运行上限，可在对应 runner 上执行：

```bash
openclaw config set agents.defaults.subagents.runTimeoutSeconds 18120 --strict-json
openclaw config validate
```

该值只是默认 `acpx_timeout_seconds=18000` 时的建议值，不由本次代码自动写入，也不进入任何 tracked 蓝区配置文件。
