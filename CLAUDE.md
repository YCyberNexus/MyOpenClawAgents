# CLAUDE.md

面向 Claude Code 的仓库级说明。根目录 [`AGENTS.md`](AGENTS.md) 是同一套规则的 Codex 侧版本，
其中的仓库硬规则（禁止 `rm`、本机配置安全、SKILL_VERSION bump）对 Claude 同样生效。

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

`workspace-emcp/` 在 `orchestra` 分支上与 `acpx_auto_tester` 几乎逐行相同（只差 Phase 6 的
`post_result_note` 一段），且落后一个版本。**emcp 的迭代 DAG 引擎重写在 `emcp` 分支上**——在
`orchestra` 上看到的 emcp CLAUDE.md/SKILL.md 描述的是旧 acpx 模型，不要据此判断 emcp 的现状。

## 需求流水线（req 三件套）

跑在同一台蓝区服务器（下称 **104**）上；接收绿区企微输入的智伴跑在另一台（下称 **114**）。
两台的具体地址见 [`AGENTS.md`](AGENTS.md)。两台 OpenClaw 互不相通，只有 104 → 114 的反向网关
放行用于推结果。排查"找不到 agent"时先确认改配置和发消息是不是同一台。

```text
114 智伴 / WebUI prompt
      ↓
req_dispatcher (agent:req_dispatcher:main)
      ├─ 建单 ──→ git_issuer ──→ GitLab issue ──→ 回调 dispatcher
      └─ 执行 ──→ submit_executor_batch.sh (durable I1 intent)
                      ↓  RUN_DRIVEN_ISSUE_BATCH
                 req_executor (调度 + worktree + acpx + push/MR/标签)
                      ↓  逐 Issue I3 回调
                 handle_executor_batch_event.sh → 逐项通知
                      ↓  notify_user.sh（反向网关）
                 114 接收 agent → 企微
```

跨切面约定（三个 workspace 一致）：

- **薄控制器**：LLM 只调顶层 wrapper、只读严格 JSON，不拆内部链、不手写 JSON state、不猜 acceptance。
- **No-Fallback**：脚本非零 → 读错误、分类、持久化、停止。不内联重写逻辑、不换"更简单的命令"。
- **GitLab 只走 `glab`**，禁止 curl/wget/HTTP 库/SDK。
- **per-exec**：OpenClaw 每个 Bash tool call 都是新 shell，`cd`/`export` 不跨调用存活；每次调用必须
  在同一个 exec 内 `cd <SKILL_DIR> && source <env> && <最小 env> bash scripts/<wrapper>.sh`。
- **timeout 分层**：`/timeout-executor` 只改 executor 后续 attempt 的 acpx 上限，dispatcher 由
  executor scheduler state 派生外层预算；OpenClaw 全局 `runTimeoutSeconds` 独立、不被命令联动。

## 本机开发规则

1. **一律用 `/opt/homebrew/bin/bash`**。本机 `/bin/bash` 是 3.2.57，会对项目脚本误报语法错误。
   `bash -n` 和跑测试都要用绝对路径的 Homebrew bash。
2. **不要在本机启动 agent，也不要跑 `acpx`**。agent 和 acpx 工具链只在服务器上可用。本机只做
   shell 静态检查和临时 `STATE_ROOT` / fake `glab` 的功能测试。
3. **不在本仓库运行 `rm`**（含 `-f` / `-r` / `-rf`）。需要清理时让用户手动做，或用非破坏性的归档/移动。
4. **配置安全**：tracked 文件里的蓝区默认值（GitLab host/protocol、token 注入契约、`/data` 下的
   clone root、callback target、state root）必须保持原样。本机路径、临时 session、测试 GitLab
   endpoint 只放 ignored 的 `*.local.env` 或进程环境。提交前确认这些没泄漏进 tracked config。
5. **workspace 自包含**：改某个 agent 时从 `workspace-<name>/` 启动 Claude Code，并先读那个
   workspace 自己的 `CLAUDE.md` + `SOUL.md`。新增 agent 也建成 `workspace-<name>/`，不要退回根目录。
6. **别跨 workspace 顺手改**：改 A 时不要动 B 已有的工作树改动（几个 workspace 经常同时是脏的）。

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

改 `req_dispatcher` 脚本至少要过 `test_driven_batch_simulated_flow.sh` 和
`test_executor_batch_recovery_contract.sh`，并回归 event/notification、旧 queue、`run_agent_turn`
相关测试。

## Code review 循环

非平凡改动**必须**在收尾前走只读 review：用 `Agent(subagent_type="code-reviewer")` 审当次未提交的
diff（在 prompt 里写明 diff 范围），修完 Critical/Important 再复审，**最多三轮**；三轮后仍有问题就
把报告交给用户决定，不要继续自行改。reviewer 不得修改工作树、index、HEAD 或分支。

`req_dispatcher` / `req_executor` / `acpx_auto_tester` 三个 workspace 有 Stop hook
(`.claude/hooks/require-workspace-review.sh`) 强制这条：本轮对话产生的未提交改动会 block 收尾，
hook 的提示里会给出清除用的 `printf %s '<hash>' > <sentinel>` 命令原文。

## SKILL_VERSION bump

**只有 `workspace-*/` 下的改动**需要 bump，根目录 / `docs/` / `packaging/` 的改动不需要。改了哪个
workspace 就 bump 哪个，在**同一次编辑/提交**里完成：

| workspace | 版本位置 |
|---|---|
| `req_dispatcher` | `skills/requirement_dispatch/SKILL.md` |
| `req_executor` | `skills/gitlab_issue_campaign_dispatcher/SKILL.md` |
| `git_issuer` | `skills/git_issue_intake/SKILL.md` |
| `acpx_auto_tester` | `skills/gitlab_issue_campaign_dispatcher/SKILL.md` |
| `emcp` | `skills/gitlab_issue_campaign_dispatcher/SKILL.md` |

版本 token 在 SKILL.md 第 3 行 `description:` 字段开头，格式 `[SKILL_VERSION=YYYY-MM-DD.N]`：
日期不是今天 → 换成 `<今天>.1`；已经是今天 → `N` 加一。

## 职责边界

被测项目（hulat/ifp）的 harness 问题——robot 用例生成、docker 执行、资源路径——属于**被测项目和
test-team**，不是 dispatcher/executor agent 的 bug。遇到这类现象不要提议改 agent。

## 提交

commit 的标题和正文都写中文，`Co-Authored-By:` trailer 保持英文原样、只写 `Claude` 不带模型版本号。

## 索引

- 三区网络模型、服务器地址、Codex 侧规则：[`AGENTS.md`](AGENTS.md)
- 蓝区基础服务规划：[`docs/blue-zone-infrastructure/`](docs/blue-zone-infrastructure/)
- 本机 GitLab / OpenClaw smoke 环境：[`docs/local-gitlab-openclaw-smoke.md`](docs/local-gitlab-openclaw-smoke.md)
- RHEL7 离线安装包（源码在 `packaging/`，zip 只作为 GitHub Release 附件）：
  [`docs/openclaw-rhel7-offline-release.md`](docs/openclaw-rhel7-offline-release.md)
- 各 agent 的详细契约：`workspace-<name>/CLAUDE.md` → `SOUL.md` → `skills/*/SKILL.md` → `references/`

拿不准路径 / schema / 命令 / 状态转移时，**去读对应的 reference 文件**，不要凭记忆重建——这些契约
是刻意写详尽的，agent 的正确性依赖于逐字遵守。
