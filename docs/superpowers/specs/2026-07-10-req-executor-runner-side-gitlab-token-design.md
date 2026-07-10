# req_executor GitLab token runner 侧解析设计

## 背景

`req_executor` 当前把 `GITLAB_TOKEN` 写进每个 Issue 的外层
`spawn_payload.txt`，再由编排模型读取该文件并作为 `sessions_spawn.task`
交给子代理。子代理随后从 prompt 中复制 token，拼进每次 Bash 工具调用：

```text
dispatch_single_issue.sh
  -> dispatch_prepare_tick.sh
  -> spawn_payload.txt（包含明文 token）
  -> 编排模型读取并调用 sessions_spawn
  -> 子代理模型复制 token 到 Bash 参数
  -> run_acpx_attempt.sh
  -> acpx / Claude Code / glab
```

这条链路要求两层模型准确复制一段不透明凭据。已有测试只验证 token 在
`dispatch_single_issue.sh`、`env_paths.sh`、`glab_auth.sh` 和模板渲染阶段没有被
覆盖，没有覆盖模型生成 Bash 工具参数的边界。

本次排查使用完全虚构的 token 做了三组不泄密探针：

1. 小型 `sessions_spawn` 复制探针的 SHA-256 与输入一致。
2. `acpx -> Claude Code Bash` 环境继承探针的 SHA-256 与输入一致。
3. 使用当前完整 `req_executor` 外层 prompt 时，子代理实际 Bash 参数把完整值
   改写成“前缀 + Unicode 省略号 + 后缀”。

因此框架和 `acpx` 没有统一加密 token；根因是完整 prompt 一边声明 token
敏感，一边要求模型反复抄写，触发了模型的主动脱敏。`glab auth status` 显示的
星号本身只是 UI 遮蔽，但本次完整 prompt 探针证明实际工具参数也已被改写。

## 目标

- 外层 `sessions_spawn` payload 不包含 GitLab token 或 token 占位符。
- 子代理不读取、不复制、不打印 GitLab token。
- `req_executor` 的 shell wrapper 在 runner 侧自行解析 token。
- 保持现有来源顺序：进程环境 `GITLAB_TOKEN` 优先，
  `config/gitlab.env` 作为部署 pin 兜底。
- `run_acpx_attempt.sh` 启动 `acpx` 时，真实 token 仍通过进程环境继承给
  Claude Code，使 Issue 内任务可以正常调用 `glab`。
- 保持蓝区 host、协议、`/data` clone 根、回调目标和持久状态根不变。

## 非目标

- 不修改或轮换仓库中的部署 token 值。
- 不改变 `req_dispatcher` 与 `git_issuer` 的凭据边界。
- 不改变 `workspace-acpx_auto_tester` 或 `workspace-emcp` 的 campaign 行为。
- 不引入新的密钥服务、加解密格式或 OpenClaw 配置项。
- 不改变显式进程环境 token 覆盖部署 pin 的既有契约。

## 方案比较

### 方案 A：每个 wrapper 在 runner 侧自行解析 token（采用）

从外层 executor prompt 删除 `{GITLAB_TOKEN}` 和所有
`GITLAB_TOKEN=<值>` Bash 前缀。每个现有 wrapper 已经会 source
`env_paths.sh`；由 `env_paths.sh` 在当前 Bash 进程中从环境或
`config/gitlab.env` 解析并 export token。`run_acpx_attempt.sh` 再把该环境原样
继承给 `acpx`。

优点：直接删除错误边界，不新增密钥载体，改动集中，兼容现有部署来源顺序。
缺点：必须补齐 `env_paths.sh` 在 host/protocol 已存在但 token 缺失时的兜底。

### 方案 B：新增统一凭据执行包装器

新增一个只在 runner 侧加载 pin、再 `exec` 目标脚本的包装器，prompt 只调用该
包装器。

优点：凭据入口更显式。缺点：所有命令都要增加一层参数转发，错误处理和测试面
更大；现有 wrapper 已具备自举能力，新增层没有必要。

### 方案 C：识别脱敏形态后回退配置 pin

继续把 token 放进 prompt，但当值包含省略号、星号或其他遮蔽特征时忽略它，
改读配置 pin。

优点：表面改动最小。缺点：脱敏形态不稳定，可能误判合法环境值，也继续把真实
凭据暴露给模型，不能消除根因，因此不采用。

## 详细设计

### 1. 外层 spawn payload 无密钥

`references/executor_prompt.md` 的 rendered block 将：

- 删除 `{GITLAB_TOKEN}` 模板变量。
- 删除 `<config>` 中的 token 行。
- 删除每个 Bash 示例中的 `GITLAB_TOKEN={GITLAB_TOKEN}` 前缀。
- 在 `<env_contract>` 明确说明：GitLab 凭据由目标脚本在 runner 侧解析；模型
  不得读取或传递 token。

`dispatch_prepare_tick.sh` 将不再设置 `TPL_GITLAB_TOKEN`。模板测试确保 rendered
block 不再包含 token 占位符或赋值指令；运行时生成 `spawn_payload.txt` 前再把
rendered payload 与当前真实 token 做精确包含比较。若 payload 意外包含真实
token，准备阶段应失败而不是继续派发。这样既阻止泄漏，也不会因为 Issue 正文
正常讨论 `GITLAB_TOKEN` 这个变量名而误报。

外层调度器自身仍可在 shell 内持有 `GITLAB_TOKEN`，用于 clone、reconcile、
Issue 读取和模板准备。变化仅发生在“runner shell -> LLM prompt”边界。

### 2. `env_paths.sh` 独立解析 token

当前 token 兜底嵌套在“host 或 protocol 缺失”条件内。调整为两个独立阶段：

1. 若进程环境已有非空 `GITLAB_TOKEN`，原样保留。
2. 若 token 缺失，只读取 `config/gitlab.env` 的 `GITLAB_TOKEN` 并 export。
3. token 仍为空时，以明确的配置错误退出。
4. host/protocol 缺失时继续调用现有 `glab_auth.sh`；已有值时不额外改写。

这样即使子代理运行环境已经带有 host/protocol，也能从 runner pin 获取 token；
同时不改变显式环境变量优先级。

### 3. `run_acpx_attempt.sh` 的继承关系

`run_acpx_attempt.sh` 继续在顶部 source `env_paths.sh`。无需给 `acpx` 命令新增
命令行参数，也不写临时 token 文件：Bash 的 export 属性会让解析后的
`GITLAB_TOKEN` 被 `timeout -> acpx -> claude-agent-acp -> Claude Code Bash`
继承。

凭据不会出现在：

- `spawn_payload.txt`
- OpenClaw 子代理 transcript
- 模型生成的 Bash 参数
- `acpx_command.txt`

### 4. 错误处理

- 环境和 pin 都没有 token：wrapper 在启动 `acpx` 前退出，错误明确指出
  `GITLAB_TOKEN` 缺失。
- 配置 token 无效：保留 `glab_auth.sh` 的非零失败语义，不尝试 curl、
  `WIKI_GITLAB_TOKEN` 或遮蔽值回退。
- prompt 重新出现 `GITLAB_TOKEN`：`dispatch_prepare_tick.sh` 将本 IID 记为
  `prep_blocked`，防止密钥再次进入 LLM 上下文。
- 显式环境 token 存在：即使外观类似遮蔽值也保持优先，现有部署注入契约不变；
  修复依靠“不把 token 交给模型”，而不是猜测 token 形态。

## 测试设计

遵循测试先行，先观察以下回归测试在现有实现上失败：

1. `test_executor_prompt_generic_issue.sh`
   - rendered block 不含 `{GITLAB_TOKEN}`。
   - rendered block 不含 `GITLAB_TOKEN=`。
   - runner 侧解析说明存在。
2. `test_gitlab_token_source_order.sh`
   - 环境 token 仍覆盖配置 pin。
   - 未提供环境 token 时读取配置 pin。
   - host/protocol 已在环境中但 token 缺失时，仍读取配置 pin。
   - 只有 `WIKI_GITLAB_TOKEN` 时仍失败。
3. 新增 spawn payload 回归覆盖
   - 使用虚构 token 渲染 payload。
   - payload 不包含虚构 token；模板的执行契约不包含 `GITLAB_TOKEN` 赋值。
   - 外层 dispatcher 自己的 fake `glab` 仍收到虚构 token，证明只切断 LLM
     边界，没有破坏调度器 GitLab 调用。
4. `run_acpx_attempt_env_test.sh`
   - fake `acpx` 观察到由 `env_paths.sh` runner 侧解析出的 token。

完成定向测试后运行 `workspace-req_executor` 全部 shell 测试，并检查：

- 仅 `workspace-req_executor` 和本设计/计划文档发生预期变更。
- tracked 蓝区配置值没有变化。
- diff 不含工作站路径、临时 session、探针 token 或测试 GitLab endpoint。

## 文件范围

预计修改：

- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/dispatcher_wrappers.md`
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh`
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/env_paths.sh`
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_executor_prompt_generic_issue.sh`
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_gitlab_token_source_order.sh`
- 必要的新回归测试文件
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`

按仓库规则，`workspace-req_executor` 技能版本从当前
`SKILL_VERSION=2026-07-10.1` 升级为 `SKILL_VERSION=2026-07-10.2`。

## 安全与兼容性结论

本设计没有改变 token 的存储值、加密形态或部署注入顺序。它只删除了不可靠且
不必要的 LLM 传密钥路径，让凭据始终在 runner 的 shell 进程内解析和继承。
这既修复当前 GitLab auth 失败，也减少凭据进入模型上下文和 transcript 的暴露面。
