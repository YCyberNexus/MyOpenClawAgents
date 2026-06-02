# 在 `temporal dev` 上部署运行 acpx_auto_tester（Temporal 版）

本文档说明如何把 `dictionary-update-temporal` 分支的 **Temporal 版调度器**部署到一台
**已部署 `temporal dev`（即 `temporal server start-dev`）的服务器**上运行，并以
`ifp_ui_testing` campaign 为完整示例。

> 适用分支：`dictionary-update-temporal`
> Temporal 包位置：`workspace-acpx_auto_tester/temporal/`（Python 包名 `acpx_temporal`）

---

## 目录

1. [背景：这套东西分两层](#1-背景这套东西分两层)
2. [前置条件](#2-前置条件)
3. [旧 trigger 字段 → Temporal `CampaignInput` 映射](#3-旧-trigger-字段--temporal-campaigninput-映射)
4. [完整部署步骤](#4-完整部署步骤)
5. [让 dev server 和 worker 常驻（systemd）](#5-让-dev-server-和-worker-常驻systemd)
6. [日常运维](#6-日常运维)
7. [验证与故障排查](#7-验证与故障排查)
8. [附：`CampaignInput` 字段速查](#8-附campaigninput-字段速查)

---

## 1. 背景：这套东西分两层

Temporal 版用 `CampaignWorkflow` + `IssueAttemptWorkflow` 取代了旧的 bash + JSON + flock
调度器，但**真正干活的 bash 叶子脚本被保留**——每个 activity 通过
`asyncio.create_subprocess_exec` shell-out 到
`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/scripts/` 下的脚本。

因此「跑起来」分两层：

| 层 | 需要什么 |
| --- | --- |
| **Temporal 编排层**（worker 在 poll、schedule 在 tick） | Python ≥ 3.11 + `temporalio`/`pydantic` + 一个 Temporal 服务（这里是 `temporal dev`） |
| **真正执行**（reconcile / clone / acpx / push / MR） | `acpx` + Claude Code、`glab`、`git`、`jq`、GNU `timeout`、目标仓库、`GITLAB_TOKEN` |

> 本文假设这台机器**就是已验证过的 acpx runner**（工具链都装好且能跑），只补 Temporal 层。

---

## 2. 前置条件

### 2.1 必须确认的环境

一行自检：

```bash
for c in jq git glab acpx timeout python3 temporal; do
  command -v "$c" >/dev/null && echo "OK $c" || echo "MISSING $c"
done
python3 -c 'import sys; assert sys.version_info>=(3,11); print("OK python",sys.version.split()[0])'
```

### 2.2 GitLab host 是钉死的

GitLab 地址在 `workspace-acpx_auto_tester/config/gitlab.env` 里固定，**trigger / 输入无法覆盖**：

```
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http          # 注意是 http，端口 30000
```

服务器必须能访问 `http://gitlab-b.pxsemic.tech:30000`，`GITLAB_TOKEN` 必须是该实例上、
对目标项目有 `api` + `write_repository` 权限的 token。

### 2.3 TLS 是可选的（连 dev server 的关键）

`worker.py` / `client.py` 的连接逻辑已改为 **TLS opt-in**：

- 同时设 `TEMPORAL_TLS_CERT` + `TEMPORAL_TLS_KEY` → 走 Temporal Cloud mTLS；
- 两个都不设 → **明文**连本地 `temporal dev`；
- 只设其一 → 启动即 `SystemExit`（防止把 Cloud 部署静默降级成明文）。

> 这是 commit `f700c72` 引入的。**runner 上 checkout 的分支必须包含它**，否则 worker
> 一连 dev server 就会因为缺 TLS 证书而退出。

---

## 3. 旧 trigger 字段 → Temporal `CampaignInput` 映射

旧 `RUN_SCHEDULED_ISSUE_CAMPAIGN` trigger 的字段不是一对一搬进 Temporal，有改名、转 env、丢弃三类。

| 旧 trigger 字段 | Temporal 去向 | 说明 |
| --- | --- | --- |
| `group` / `project` / `branch` / `dev_branch` | `CampaignInput` 同名 | 直接搬 |
| `issue_min_iid` / `issue_max_iid` | 同名 | 直接搬 |
| `hourly_issue_quota` / `max_runtime_minutes` | 同名 | 直接搬 |
| `blocked_retry_limit` / `blocked_cooldown_ticks` | 同名 | 直接搬 |
| `max_concurrent_subagents` | 同名 | 直接搬 |
| `result_basename` / `data_basename` | 同名 | 直接搬 |
| `ui_accounts_relpath` | 同名 | 直接搬，解析在 checkout 根 `${REPO_PATH}/` 下 |
| `acpx_timeout_seconds` | 同名 | 派生 `run_timeout_seconds`/`stuck_after_minutes`，**自动算，别手填** |
| **`repo_path`** | **`repo_parent_path`**（改名） | ⚠️ 它是**父目录**：最终 checkout = `${repo_path}/${project}` |
| **`gitlab_token`** | **worker 进程 env `GITLAB_TOKEN`**（不进 JSON） | 密钥不入 workflow 历史 |
| `non_interactive` | 丢弃 | Temporal 本就非交互 |
| `session_mode=per_issue` | 丢弃 | 模型天然每 IID 一个 `IssueAttemptWorkflow` |
| `scheduling_mode=quota_carryover` | 丢弃 | 无此旋钮；每 tick 放行 `min(max_concurrent_subagents, hourly_issue_quota)` |
| `blocked_policy=skip_and_retry` | 丢弃 | 由 `blocked_retry_limit` + `blocked_cooldown_ticks` 内建实现 |

> **最容易踩的两个坑**：
> 1. `repo_path` → `repo_parent_path`，且是父目录（最终路径要拼上 `/${project}`）。
> 2. `gitlab_token` 不写进 input JSON，放 worker 的环境变量。

---

## 4. 完整部署步骤

以下命令以 `ifp_ui_testing` campaign 为例，配置对应这份旧 trigger：

```
group=claw_gitlab  project=ifp_ui_testing  branch=master  dev_branch=dev
issue_min_iid=420  issue_max_iid=523  hourly_issue_quota=2  max_concurrent_subagents=2
max_runtime_minutes=55  blocked_retry_limit=10  blocked_cooldown_ticks=5
result_basename=ifp-result  data_basename=ifp-data
repo_path=/data/ifp_ui_testing_mulit
ui_accounts_relpath=ifp-data/ifp-common/ifp_users.json
acpx_timeout_seconds=3600
gitlab_token=<TOKEN>
```

> 最终 checkout = `/data/ifp_ui_testing_mulit/ifp_ui_testing`
> UI 池 = `/data/ifp_ui_testing_mulit/ifp_ui_testing/ifp-data/ifp-common/ifp_users.json`

### 步骤 1 — 部署含 TLS 修复的分支

```bash
# runner 上
cd /opt/acpx/MyOpenClawAgents          # 换成你放仓库的路径
git fetch origin
git checkout dictionary-update-temporal
git pull --ff-only origin dictionary-update-temporal
git log --oneline -3                    # 确认含 TLS 可选的 commit
```

### 步骤 2 — 安装 Temporal 包（editable）

```bash
python3 -m venv /opt/acpx/venv
source /opt/acpx/venv/bin/activate
pip install -e /opt/acpx/MyOpenClawAgents/workspace-acpx_auto_tester/temporal
acpx-temporal-worker --help && acpx-temporal-client --help
```

> **必须 `-e`**：worker 靠源码树相对路径定位被保留的 bash 脚本目录；非 editable 安装会复制进
> site-packages 导致找不到脚本（除非另设 `ACPX_SCRIPTS_DIR`）。装完别移动/删除仓库目录。

### 步骤 3 — 启动并持久化 dev server

```bash
sudo mkdir -p /var/lib/temporal && sudo chown "$(id -un)":"$(id -gn)" /var/lib/temporal
temporal server start-dev --db-filename /var/lib/temporal/dev.db
# gRPC localhost:7233 | Web UI http://localhost:8233 | namespace default(自动注册)
```

> `temporal dev` 默认内存态，**重启即丢 schedule**。`--db-filename` 让状态落到 SQLite 文件，
> 重启后 schedule/历史都还在。常驻方式见第 5 节。

### 步骤 4 — 写本次 campaign 的 input JSON

```bash
sudo mkdir -p /etc/acpx
sudo tee /etc/acpx/campaign-input-ifp_ui_testing.json >/dev/null <<'JSON'
{
  "project": "ifp_ui_testing",
  "group": "claw_gitlab",
  "branch": "master",
  "dev_branch": "dev",
  "issue_min_iid": 420,
  "issue_max_iid": 523,
  "hourly_issue_quota": 2,
  "max_runtime_minutes": 55,
  "blocked_retry_limit": 10,
  "blocked_cooldown_ticks": 5,
  "repo_parent_path": "/data/ifp_ui_testing_mulit",
  "result_basename": "ifp-result",
  "data_basename": "ifp-data",
  "ui_accounts_relpath": "ifp-data/ifp-common/ifp_users.json",
  "max_concurrent_subagents": 2,
  "acpx_timeout_seconds": 3600
}
JSON
```

### 步骤 5 — 启动 worker（前台验证）

```bash
source /opt/acpx/venv/bin/activate
export TEMPORAL_ADDRESS="localhost:7233"
export TEMPORAL_NAMESPACE="default"
unset  TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY        # 明文连 dev server
export NODE_ID="$(hostname)"
export GITLAB_TOKEN="<TOKEN>"                     # ← 旧 trigger 的 gitlab_token 放这里
python -m acpx_temporal.worker --task-queue "acpx-worktree-${NODE_ID}"
```

日志出现 `tls=False` 和 `worker ready, polling…` 即编排层连通。**记下队列名
`acpx-worktree-${NODE_ID}`**，下一步必须一致。

### 步骤 6 — 创建 schedule 并触发

另开一个 shell（同 venv、同 `NODE_ID`）：

```bash
source /opt/acpx/venv/bin/activate
export TEMPORAL_ADDRESS="localhost:7233" TEMPORAL_NAMESPACE="default" NODE_ID="$(hostname)"
unset TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY

acpx-temporal-client create-schedule \
  --schedule-id "campaign:ifp_ui_testing" \
  --task-queue  "acpx-worktree-${NODE_ID}" \
  --interval    1h \
  --input-file  /etc/acpx/campaign-input-ifp_ui_testing.json

# 立刻先跑一轮（不等 1h）
temporal schedule trigger --schedule-id campaign:ifp_ui_testing --namespace default
```

> `--interval` 按 `hourly_issue_quota` 的「每小时」语义给 `1h`，也可用 `55m` 对齐
> `max_runtime_minutes`。schedule 只需建一次（落盘在 `dev.db`）。

---

## 5. 让 dev server 和 worker 常驻（systemd）

把密钥放进独立的 `EnvironmentFile`，避免写进 unit。**`NODE_ID` 用一个固定字符串**
（systemd 不展开 `$(hostname)`），并保证 `PATH` 含 acpx/glab/git/jq 所在目录。

```bash
sudo tee /etc/acpx/worker.env >/dev/null <<'ENV'
TEMPORAL_ADDRESS=localhost:7233
TEMPORAL_NAMESPACE=default
NODE_ID=runner-01
GITLAB_TOKEN=<TOKEN>
HOME=/home/acpx
PATH=/opt/acpx/venv/bin:/usr/local/bin:/usr/bin:/bin
ENV
sudo chmod 600 /etc/acpx/worker.env
```

```ini
# /etc/systemd/system/temporal-dev.service
[Unit]
Description=Temporal dev server (persistent)
After=network.target

[Service]
User=acpx
Environment=HOME=/home/acpx
ExecStart=/usr/local/bin/temporal server start-dev --db-filename /var/lib/temporal/dev.db
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/acpx-worker.service
[Unit]
Description=acpx_auto_tester Temporal worker
After=temporal-dev.service
Requires=temporal-dev.service

[Service]
User=acpx
EnvironmentFile=/etc/acpx/worker.env
ExecStart=/opt/acpx/venv/bin/acpx-temporal-worker --task-queue acpx-worktree-runner-01
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now temporal-dev acpx-worker
sudo systemctl status acpx-worker --no-pager
journalctl -u acpx-worker -f          # 看 tls=False / worker ready
```

> `temporal` / `acpx-temporal-worker` 的路径用 `which` 查到的真实值替换。
> **三处队列名必须一致**：`worker.env` 的 `NODE_ID` → unit `ExecStart` 的
> `acpx-worktree-runner-01` → schedule 的 `--task-queue`。

---

## 6. 日常运维

```bash
# 暂停 / 恢复
acpx-temporal-client pause-schedule  --schedule-id campaign:ifp_ui_testing
acpx-temporal-client resume-schedule --schedule-id campaign:ifp_ui_testing

# 改 IID 范围（signal 给在跑的 workflow，不必重建 schedule）
acpx-temporal-client update-scope --schedule-id campaign:ifp_ui_testing \
  --issue-min-iid 420 --issue-max-iid 460

# 可选：附加 IID 白名单（在范围之上再过滤）
acpx-temporal-client update-scope --schedule-id campaign:ifp_ui_testing \
  --issue-min-iid 420 --issue-max-iid 523 --issue-iids 420,425,430

# 删除 schedule
acpx-temporal-client delete-schedule --schedule-id campaign:ifp_ui_testing

# 单跑一个 IID 调试（一次性 IssueAttemptWorkflow）
acpx-temporal-client start-attempt \
  --task-queue "acpx-worktree-runner-01" \
  --workflow-id "issue:ifp_ui_testing:420" \
  --input-file /etc/acpx/attempt-420.json
```

---

## 7. 验证与故障排查

### 7.1 分层验证顺序

在 Web UI `http://localhost:8233` 看 workflow 历史，按 activity 顺序确认每层：

1. `reconcile_gitlab` 过 → `glab` / token / 到 GitLab 的网络都正常
2. `clone_or_pull_repo` 过 → 仓库 clone 到 `/data/ifp_ui_testing_mulit/ifp_ui_testing`
3. `run_claude_code_attempt` → `acpx` 真正开始执行

### 7.2 常见卡点

| 现象 | 原因 / 解决 |
| --- | --- |
| worker 启动报缺 `TEMPORAL_TLS_CERT` | runner 上不是含 TLS 可选 commit 的 checkout → 回步骤 1 |
| workflow 一直 pending，无 activity 跑 | schedule 的 `--task-queue` 与 worker 不一致 → 对齐 `NODE_ID` |
| `ui_account_pool_too_small: pool=N max_concurrent_subagents=M` | UI 池账号数 < `max_concurrent_subagents` → 加账号或调小并发 |
| `invalid_ui_accounts_relpath` | 路径含 `.`/`..`/空格或非 `[A-Za-z0-9_./-]` 字符 |
| `reconcile_gitlab` 红 | token 权限不足 / 到 `gitlab-b.pxsemic.tech:30000`(http) 网络不通 |
| systemd 下 glab/acpx 找不到 | `worker.env` 的 `PATH` / `HOME` 没覆盖到工具链与配置目录 |
| 重启后 schedule 消失 | dev server 没带 `--db-filename`，跑在内存态 |
| `temporalio` 装不上 | PyPI 不可达，或冷门发行版（musl/Alpine）缺预编译 wheel 需本地编译 |

### 7.3 UI 账号池约束

当配置了 `ui_accounts_relpath` 时，池大小是 `max_concurrent_subagents` 的**硬上界**
（被测系统重复登录会踢掉账号，每个并发 subagent 必须持有不同凭据）。池按并发数切分、
每片再被 `max_accounts_per_issue`（默认 14）封顶。例：池 3 人、并发 2 →
分配为 `2,1`（余数前置到第一片）。

---

## 8. 附：`CampaignInput` 字段速查

> 定义见 `workspace-acpx_auto_tester/temporal/shared/types.py` 的 `CampaignInput`。

### 必填（无默认，缺则 workflow 启动即失败）

`project`、`group`、`branch`、`dev_branch`、`issue_min_iid`、`issue_max_iid`、
`hourly_issue_quota`、`max_runtime_minutes`、`blocked_retry_limit`、`blocked_cooldown_ticks`

### 可选（有默认）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `repo_parent_path` | `/data` | clone 父目录；最终 `${repo_parent_path}/${project}` |
| `result_basename` | `ifp-result` | 运行时根目录名 |
| `data_basename` | `ifp-data` | 知识库目录名 |
| `ui_accounts_relpath` | `""`（不启用） | UI 账号池相对路径，解析在 `${REPO_PATH}/` 下 |
| `max_concurrent_subagents` | `1` | 每 tick 批量 + 最大在飞数；配置 UI 池时 ≤ 池大小 |
| `max_accounts_per_issue` | `14` | 每 IID 分到的账号数上限 |
| `acpx_timeout_seconds` | `18000` | 单次 acpx 墙钟封顶（秒） |
| `run_timeout_seconds` | 派生 = `acpx_timeout_seconds + 120` | **别手填** |
| `stuck_after_minutes` | 派生 = `ceil(run_timeout_seconds/60) + 30` | 兜底逐出阈值，**别手填** |
| `kill_subagent_on_terminal` | `true` | 终态后清理子会话 |
| `issue_iids_whitelist` | `[]` | 范围之上的 IID 白名单 |
| `require_labels` | `[]` | live-label 包含过滤 |
| `require_labels_match` | `or` | `or` / `and` 组合 |

> 本例中 `acpx_timeout_seconds=3600` 自动派生出 `run_timeout_seconds=3720`、
> `stuck_after_minutes=92`。
