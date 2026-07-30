# CLAUDE.md

面向 Claude Code 的仓库级说明。根目录 [`AGENTS.md`](AGENTS.md) 是同一套规则的 Codex 侧版本，
其中的仓库硬规则（禁止 `rm`、本机配置安全、**jq 1.5 兼容基线**、SKILL_VERSION bump）对 Claude
同样生效。本分支（`orchestra`）的绝大多数改动由 Codex 完成，AGENTS.md 是那侧的记忆，两边不要写岔。

## 这个仓库是什么

**不是应用仓库**，而是一组 **OpenClaw agent 的部署工件集合**。这里没有 build、没有包管理清单、
没有统一测试入口；每个 agent 自包含在一个 `workspace-<name>/` 目录里，部署方式是把该目录整体同步
到 runner。

每个 workspace 的固定形态：

```text
workspace-<name>/
  SOUL.md / AGENTS.md / USER.md   ← agent 的 prompt 契约（运行时真正加载的）
  CLAUDE.md                       ← 只给 Claude Code 开发者看，运行时不加载
  IDENTITY.md / HEARTBEAT.md / TOOLS.md / openclaw-workspace-state.json  ← OpenClaw 模板/运行时文件
  config/                         ← 部署期 pin（tracked）+ ignored 的 *.local.env
  skills/<skill_name>/
    SKILL.md                      ← 运行契约，含 [SKILL_VERSION=...]
    scripts/*.sh                  ← 确定性逻辑都在这里，LLM 只调顶层 wrapper
    references/*.md               ← trigger / state / 标签生命周期等详尽契约
    tests/*.sh                    ← 独立可执行的 shell 测试（多数用 fake glab）
  docs/
```

**关键事实**：生产 agent 加载的是 `SOUL.md` / `AGENTS.md` / `USER.md` / `SKILL.md`，**不加载
`CLAUDE.md`**。要改 agent 的运行行为，改前四者，改 CLAUDE.md 不会有任何效果。

## workspace 地图

| workspace | 角色 | 状态 |
|---|---|---|
| `req_dispatcher` | 需求接入编排器：判动作 → 调 git_issuer 建单 → 路由 → 提交受驱动 batch → I3 回调 → 推结果给用户 | 主线，活跃 |
| `req_executor` | Issue 执行器：GitLab 发现、共享 round-robin 调度、worktree、acpx 跑 Issue、push/MR/标签/汇总、回投 I3 | 主线，活跃 |
| `git_issuer` | 自由文本 → GitLab issue（CREATE/CHANGE/CANCEL/SUPERSEDE），回调 req_dispatcher；只用 `glab` | 稳定，改动少 |
| `acpx_auto_tester` | 面向 ifp/hulat 项目的定时 Issue campaign（UI 账号池、model tier、Wiki 归档） | 独立链路 |
| `emcp` | `acpx_auto_tester` 的分叉副本 | **本分支上是旧快照**（见下） |
| `acpx_auto_tester_test` | 只有 OpenClaw 模板文件的空壳，无 skill | untracked 残留 |

`workspace-emcp/` 在 `orchestra` 分支上仍是 `acpx_auto_tester` 的近似副本（SKILL_VERSION 已同步，
差异集中在 prompt 契约、几个 reference 与 `dispatch_*`，且 emcp 没有 `post_result_note.sh`）。
**emcp 的迭代 DAG 引擎重写在 `emcp` 分支上**——那边已把 CLAUDE.md/SOUL/AGENTS/references 整体改写为
迭代 DAG 模型（iteration_state / 临时分支 / 迭代 MR / env_slot）。在 `orchestra` 上看到的 emcp
描述的是旧 acpx 模型，不要据此判断 emcp 的现状，也不要在 `orchestra` 上给 emcp 补 DAG 相关改动。

## 需求流水线（req 三件套）

跑在同一台蓝区服务器（下称 **104**）上；接收绿区企微输入的智伴跑在另一台（下称 **114**）。
两台的具体地址见 [`AGENTS.md`](AGENTS.md)。两台 OpenClaw 互不相通，只有 104 → 114 的反向网关
放行用于推结果。排查"找不到 agent"时先确认改配置和发消息是不是同一台。

```text
114 智伴
      ↓
req_dispatcher (用户入口 agent:req_dispatcher:intake-<origin_sha256>)
      ├─ 建单 ──→ git_issuer ──→ GitLab issue ──→ 回调 dispatcher
      └─ 执行 ──→ submit_executor_batch.sh (durable I1 intent)
                      ↓  RUN_DRIVEN_ISSUE_BATCH
                 req_executor (调度 + worktree + acpx + push/MR/标签)
                      ↓  逐 Issue I3 回调
                 req_dispatcher main → handle_executor_batch_event.sh → 逐项通知
                      ↓  notify_user.sh（反向网关）
                 114 接收 agent → 企微
```

一次执行请求的 Issue 选择器有五种：单 IID、离散 IID 列表、IID 闭区间、OPEN 未完成、OPEN 指定标签；
dispatcher 只做 intake 期的 OPEN 判定，**snapshot 查询/过滤/冻结全在 executor**。
`RUN_SINGLE_ISSUE` 只作为部署升级期的兼容 shim 保留，主路径是 `RUN_DRIVEN_ISSUE_BATCH`。

executor 侧当前已落地、且容易被误当成"还没有"的能力：

- **自动合并**：仅当用户明确要求时携带 auto-merge 意图；服务端校验通过后 Issue 终态直接到 `finish`。
  共享依赖分支拒绝自动合并，停在 `pr`。
- **共享依赖分支**：同项目内一对一依赖，**依赖关系写在依赖方 Issue 的正文里**；两张 Issue 晚绑定到
  同一分支，已有的普通分支可迁移过去，迁移可重放。
- **exact-SHA MR 校验** 与 **per-Issue callback outbox**：终态结果按 Issue 逐条投递，不做批量汇总投递。
- **运行时控制**：`/slot <正整数>` 调所有 batch session 共享的并行仓库数上限，
  `/repo-slot <正整数>` 调每个仓库的 Issue 并发上限（默认 1），
  `/timeout-executor <时长>` 调后续 attempt 的 acpx 上限（默认 `EXECUTOR_ACPX_TIMEOUT_SECONDS=3600`）。
  三者都只走各自固定 wrapper，**不改配置文件、不手写 scheduler JSON**。

**执行身份（execution identity）**：attempt 级的文件系统隔离已被取消。worktree、output 目录和本地
Git 分支现在**按 Issue 固定**；每次运行只拿一个随机不透明的 `execution_id` + 独立 log 目录 + 不可变
execution-state 文件。`execution_id` 是 stale-callback 的围栏，**不是"第几次重跑"的计数**，不要拿它
推断次数或拼路径。执行日志在暂存时与业务改动一起提交到对应 `WORK_BRANCH`（普通任务为
`issue/<iid>`）；push 后生成的 `worker_result.json`、MR 恢复标记等终态文件再以 log-only 子提交追加到
同一 `WORK_BRANCH`，不再创建独立日志分支。

**Issue 评论的方向已经反过来了**（`27c73f5`）：attempt 总结不再发回 issue 讨论区，只落成本地文件
（`summary_posted=false` 是保留的兼容字段）；反过来，Issue 正文与全部非系统评论会被渲染进
`${LOG_DIR}/prompt.txt`，且会过滤掉执行器自己写过的历史总结与证据链接。这样"用户在评论里补需求"
才会被后续执行看到。注意这**不包括** `post_result_note.sh` —— 它发的是给 114 轮询用的结构化
`req_result` note，是另一条链路，仍然保留，由 opt-in 的 `result_note_enabled`（默认 `false`）控制。
Wiki 证据上传只有 `acpx_auto_tester` / `emcp` 还留着，`req_executor` 侧是空操作。

跨切面约定（三个 workspace 一致）：

- **薄控制器**：LLM 只调顶层 wrapper、只读严格 JSON，不拆内部链、不手写 JSON state、不猜 acceptance。
- **No-Fallback**：脚本非零 → 读错误、分类、持久化、停止。不内联重写逻辑、不换"更简单的命令"。
- **GitLab 只走 `glab`**，禁止 curl/wget/HTTP 库/SDK。
- **jq 1.5 兼容**：见下节，这是全仓库硬约束，不限于 req 三件套。
- **per-exec**：OpenClaw 每个 Bash tool call 都是新 shell，`cd`/`export` 不跨调用存活；每次调用必须
  在同一个 exec 内 `cd <SKILL_DIR> && source <env> && <最小 env> bash scripts/<wrapper>.sh`。
- **timeout 分层**：`/timeout-executor` 只改 executor 后续 attempt 的 acpx 上限（在途 attempt 保留
  启动时固定的值），dispatcher 由 executor scheduler state 派生外层预算；OpenClaw 全局
  `runTimeoutSeconds` 独立、不被命令联动。

## jq 1.5 兼容基线

仓库里**所有** shell 脚本、jq filter、测试、以及文档里写的 jq 示例都必须能在 jq 1.5 上跑。禁止使用
1.6+ 才有的选项 / 语法 / builtin，包括 `?//`、`$ENV`、`walk`、`halt`、`halt_error`、`isempty`、
`utf8bytelength`、`strflocaltime`，以及 SQL 风格的 `INDEX` / `JOIN` / `IN`。

jq 1.5 的 `join(...)` 只接受字符串元素——拼数字或混合类型数组前必须先 `map(tostring)`。

**`label` 是 jq 关键字**（`label $out | ...`），不能拿来当 `--arg` 变量名：jq 1.5 会把
`--arg label ... '{label:$label}'` 解析失败。踩过一次（`23dea86`），后果不是显式报错就完事——
GitLab 标签其实已经写进去了，只是响应校验挂掉，把重跑的 Issue 误判成 `blocked-dispatcher`。
变量统一改成 `selector_label` 这类非关键字名。另一次全仓库统一兼容是 `8f661ba`。

改动 jq 相关逻辑时**必须用真正的 jq 1.5 跑一遍**，本机较新的 jq 通过不算数；也**不要**提议
升级蓝区 jq 来绕开问题。

## 本机开发规则

1. **一律用 `/opt/homebrew/bin/bash`**。本机 `/bin/bash` 是 3.2.57，会对项目脚本误报语法错误。
   `bash -n` 和跑测试都要用绝对路径的 Homebrew bash。
2. **jq 已被 pin 成 1.5**：`jq` 和 `/opt/homebrew/bin/jq` 都软链到 `~/.local/bin/jq-1.5`，
   本机默认命中的就是基线版本。**不要为了让某条 filter 跑通去升级或绕开它**——那会让本机
   验证失去意义。
3. **不要在本机启动 agent，也不要跑 `acpx`**。agent 和 acpx 工具链只在服务器上可用。本机只做
   shell 静态检查和临时 `STATE_ROOT` / fake `glab` 的功能测试。
4. **不在本仓库运行 `rm`**（含 `-f` / `-r` / `-rf`）。需要清理时让用户手动做，或用非破坏性的归档/移动。
5. **配置安全**：tracked 文件里的蓝区默认值（GitLab host/protocol、token 注入契约、`/data` 下的
   clone root、callback target、state root）必须保持原样。本机路径、临时 session、测试 GitLab
   endpoint 只放 ignored 的 `*.local.env` 或进程环境。提交前确认这些没泄漏进 tracked config。
   req 三件套各自带了 `config/*.example`（`dispatcher.local.env.example` /
   `campaign_defaults.local.env.example` / `gitlab.env.example`）作为本机覆盖的模板。
6. **workspace 自包含**：改某个 agent 时从 `workspace-<name>/` 启动 Claude Code，并先读那个
   workspace 自己的 `CLAUDE.md` + `SOUL.md`。新增 agent 也建成 `workspace-<name>/`，不要退回根目录。
7. **别跨 workspace 顺手改**：改 A 时不要动 B 已有的工作树改动（几个 workspace 经常同时是脏的）。
   本分支长期同时挂着 Codex 的在制品改动，收工前用 `git status` 确认自己只碰了该碰的文件。

## 验证

没有统一 test runner，测试就是一批可独立执行的 shell 脚本：

```bash
# 语法检查（改任何脚本后）
/opt/homebrew/bin/bash -n workspace-<name>/skills/<skill>/scripts/<file>.sh

# 跑单个测试
/opt/homebrew/bin/bash workspace-<name>/skills/<skill>/tests/<test>.sh

# 跑某个 workspace 的全部测试
for t in workspace-req_dispatcher/skills/requirement_dispatch/tests/test_*.sh; do
  /opt/homebrew/bin/bash "$t" || echo "FAIL $t"
done
```

测试规模（改脚本时按这个量级预期回归成本）：`req_executor` 67 个、`req_dispatcher` 43 个、
`git_issuer` 4 个。

改 `req_dispatcher` 脚本至少要过 `test_driven_batch_simulated_flow.sh` 和
`test_executor_batch_recovery_contract.sh`，并回归 event/notification、旧 queue、`run_agent_turn`
相关测试。

改 `req_executor` 脚本按触及面挑主回归：

| 触及的东西 | 至少要过 |
|---|---|
| 调度 / claim / 并发 | `test_executor_batch_tick.sh`、`test_executor_tick_lock_concurrency.sh`、`test_driven_scheduler_fairness.sh` |
| attempt 执行链 | `test_run_executor_attempt.sh`、`test_native_subagent_completion.sh` |
| 执行身份 / 日志随分支提交 | `test_execution_identity_migration.sh`、`test_archive_execution_logs.sh`、`test_stage_and_guard_ignores_logs.sh` |
| 依赖 / 共享分支 | `test_shared_dependency_branch.sh`、`test_migrate_shared_dependency_head.sh`、`test_recover_shared_mr_finalization.sh` |
| MR / 合并 / 标签 | `test_phase6_auto_merge.sh`、`test_merge_mr.sh`、`test_set_issue_label_finish_guard.sh` |
| 运行时控制命令 | `test_set_executor_slots.sh`、`test_set_executor_repo_slots.sh`、`test_repository_configurable_scheduler.sh`、`test_set_executor_acpx_timeout.sh`、`test_executor_concurrency_override.sh` |
| GitLab token / 网络守卫 | `test_gitlab_token_source_order.sh`、`test_git_network_guard_all_callers.sh`、`test_glab_auth_local_fail_closed.sh` |

## Code review 循环

非平凡改动**必须**在收尾前走只读 review：用 `Agent(subagent_type="code-reviewer")` 审当次未提交的
diff（在 prompt 里写明 diff 范围），修完 Critical/Important 再复审，**最多三轮**；三轮后仍有问题就
把报告交给用户决定，不要继续自行改。reviewer 不得修改工作树、index、HEAD 或分支。

`req_dispatcher` / `req_executor` / `acpx_auto_tester` / `emcp` 四个 workspace 有 Stop hook
(`.claude/hooks/require-workspace-review.sh`) 强制这条：本轮对话产生的未提交改动会 block 收尾，
hook 的提示里会给出清除用的 `printf %s '<hash>' > <sentinel>` 命令原文。根目录和 `docs/` 不挂 hook，
但同样适用这条规则。

## SKILL_VERSION bump

**只有 `workspace-*/` 下的改动**需要 bump，根目录（含本文件、`AGENTS.md`）和 `docs/` 的改动不需要。
改了哪个 workspace 就 bump 哪个，在**同一次编辑/提交**里完成：

| workspace | 版本位置 |
|---|---|
| `req_dispatcher` | `skills/requirement_dispatch/SKILL.md` |
| `req_executor` | `skills/gitlab_issue_campaign_dispatcher/SKILL.md` |
| `git_issuer` | `skills/git_issue_intake/SKILL.md` |
| `acpx_auto_tester` | `skills/gitlab_issue_campaign_dispatcher/SKILL.md` |
| `emcp` | `skills/gitlab_issue_campaign_dispatcher/SKILL.md` |

版本 token 在 SKILL.md 第 3 行 `description:` 字段开头，格式 `[SKILL_VERSION=YYYY-MM-DD.N]`：
日期不是今天 → 换成 `<今天>.1`；已经是今天 → `N` 加一。改 workspace 里的**任何**东西都要 bump——
脚本、测试、prompt 契约、reference、config、文档都算。

改动如果同时落在多个 workspace，就每个 workspace 各 bump 各的；只改根目录 / `docs/` 时一个都别动。

## 职责边界

被测项目（hulat/ifp）的 harness 问题——robot 用例生成、docker 执行、资源路径——属于**被测项目和
test-team**，不是 dispatcher/executor agent 的 bug。遇到这类现象不要提议改 agent。

## 提交

commit 的标题和正文都写中文，`Co-Authored-By:` trailer 保持英文原样、只写 `Claude` 不带模型版本号。

## 索引

- 三区网络模型、服务器地址、jq 1.5 基线、Codex 侧规则：[`AGENTS.md`](AGENTS.md)
- 蓝区基础服务规划、104↔114 通信契约与时序：
  [`docs/blue-zone-infrastructure/`](docs/blue-zone-infrastructure/)
- req 三件套流程图（drawio 源文件）：
  [`docs/req_dispatcher_executor_flow.drawio`](docs/req_dispatcher_executor_flow.drawio)
- 本机 GitLab / OpenClaw smoke 环境：[`docs/local-gitlab-openclaw-smoke.md`](docs/local-gitlab-openclaw-smoke.md)
- RHEL7 离线安装包：[`docs/openclaw-rhel7-offline-release.md`](docs/openclaw-rhel7-offline-release.md)
  ——注意 `packaging/` 目录已在 `edb315b` 从仓库删除，该文档末尾"源码位于 `packaging/`"是过期表述；
  zip 只作为 GitHub Release 附件存在（根目录那个 120MB 的 zip 是 ignored 的本地残留）。
- req 三件套迁移 Temporal 的架构设计（**设计草案，未实施**，不描述现状）：
  [`docs/req-pipeline-langgraph-migration.md`](docs/req-pipeline-langgraph-migration.md)
  ——结论是 Temporal 主导控制面（durable timer / 重试上限 / workflow id 互斥 / Signal / 取消），
  LangGraph 降级为 P3 可选的 review 决策子图；文件名仍是历史的 `langgraph` 前缀。
- 各 agent 的详细契约：`workspace-<name>/CLAUDE.md` → `SOUL.md` → `skills/*/SKILL.md` → `references/`

拿不准路径 / schema / 命令 / 状态转移时，**去读对应的 reference 文件**，不要凭记忆重建——这些契约
是刻意写详尽的，agent 的正确性依赖于逐字遵守。
