# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are not generated from ordinary issue triggers. Runtime `/slot`, `/repo-slot`, and `/timeout-executor` controls persist their values in scheduler state and do not edit these files.

Local clone-parent and scheduler overrides go in ignored `campaign_defaults.local.env`: executor scripts load `campaign_defaults.env` first, then `campaign_defaults.local.env` when present. An explicit process environment value for a scheduler field takes precedence over both files. A local `EXECUTOR_SCHEDULER_ROOT` must be strictly below the normalized `${HOME}` or `${TMPDIR:-/tmp}` directory; the base directory itself and paths outside those roots are rejected. Do not commit personal machine paths or extra workstation-only credentials to tracked config.

## `gitlab.env`

Pins the GitLab host the agent talks to. Required fields:

- `GITLAB_HOST` — host (with port if non-default) of the pinned GitLab instance. Exported by `scripts/glab_auth.sh`; `glab` reads it natively from the env var, so `glab api` / `glab mr` / `glab issue` calls **must NOT pass `--hostname`** (only `glab auth login` / `glab auth status` inside `glab_auth.sh` take that flag). Example: `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).
- `GITLAB_TOKEN` — req_executor's deployment token fallback. A process environment `GITLAB_TOKEN` wins when present; otherwise scripts use this value from `gitlab.env`.

### Why pin?

The agent runs unattended for long stretches. Re-parsing the host out of `${GITLAB_ADDRESS}` on every tick is fragile — variable corruption, accidental whitespace, or a bad `sed` regex would silently make the agent talk to the wrong place. By pinning at deployment time:

- the agent uses a single, fixed `GITLAB_HOST` on every call to `glab`
- the trigger's `gitlab_address` becomes a **verification** input — if it doesn't resolve to the pinned host, `scripts/glab_auth.sh` aborts with **exit 13** (stderr: `trigger gitlab_address (...) does not match deployment pin (...)`) and the orchestrator records a `block_reason` to that effect. (Exit codes: `10` pin file missing, `11` required field missing, `12` bad `GITLAB_API_PROTOCOL`, `13` trigger/pin host or protocol mismatch.)
- token selection order is: explicit `GITLAB_TOKEN` environment value first, then `GITLAB_TOKEN` in this file.

### Setup

1. Edit `gitlab.env` on the runner with the correct host, protocol, and req_executor token.
2. Run `glab auth login --hostname <host> --token <token> --api-protocol <proto>` once manually to validate; you should see `glab auth status --hostname <host>` succeed.
3. After this, the agent is free to run scheduled ticks.

### Multiple GitLab hosts?

This workspace assumes a single GitLab deployment per runner. If you ever need to point a different runner at a different GitLab, change `gitlab.env` on that runner. Do not try to make the agent multi-tenant by reading the host from trigger inputs — that defeats the whole point of pinning.

## `campaign_defaults.env`

Pins the clone parent used by the **driven** `RUN_SINGLE_ISSUE` entry point and the agent-wide driven-batch scheduler settings. On the single-issue driven path, the I1 schema includes `project`, `iid`, `correlation_id`, pinned routing identity, `callback_nonce`, and optional `group` / `branch`.

Like `gitlab.env`, this file is `source`d (and may be loaded under `set -a`), so it must stay pure `KEY=value` lines — no shell logic, no command substitution, no conditionals.

### Why these values are pinned

The runner has to know where to clone repositories before it can read issue content or repository-local guidance. The driven-batch scheduler also needs one agent-level state root outside all clones, one parallel-repository ceiling, one per-repository Issue ceiling, and one initial acpx timeout for future attempts. Repository-local concurrency defaults to serial; distinct repositories may run in parallel. Everything else is either supplied by the issue/wiki, supplied by req_dispatcher as an optional `branch`, inferred by the wrapper (an Issue base-branch declaration before `origin/HEAD` when the request omits `branch`), or handled by Claude Code/OpenClaw defaults.

### Fields

| Field | Pinned value | Meaning |
| --- | --- | --- |
| `REPO_PARENT_PATH` | `/data` | Absolute parent under which the project is cloned; the final clone target is `${REPO_PARENT_PATH}/${PROJECT}`. Use ignored `campaign_defaults.local.env` to override this for local testing. |
| `EXECUTOR_SCHEDULER_ROOT` | `/data/req_executor/_scheduler` | Absolute agent-level root for scheduler state, lock, batch records, and callback inbox/outbox. |
| `EXECUTOR_MAX_CONCURRENCY` | `10` | Positive integer initialization default for parallel GitLab repositories, shared across all driven batches; `/slot` persists the later runtime ceiling in scheduler state. |
| `EXECUTOR_MAX_ISSUES_PER_REPOSITORY` | `1` | Positive integer initialization default for concurrent Issues within each GitLab repository; `/repo-slot` persists the later runtime ceiling. |
| `EXECUTOR_ACPX_TIMEOUT_SECONDS` | `3600` | Initialization default for the per-attempt acpx wall-clock cap. `/timeout-executor` persists later values from 60 through 18000 seconds for future attempts. |
| `EXECUTOR_RUNNING_LEASE_SECONDS` | `21600` | Backstop before tick checks a running claim for a lost callback; the project-side ACPX deadline is still authoritative. |
| `DRIVEN_LEGACY_LOCK_COMPAT_SECONDS` | `86400` | Persisted rollout window in which new wrappers acquire both old and new callback/launch lock paths. Set to `0` only after all pre-upgrade executor processes have stopped; expired windows migrate old locks out of hot directories without replacing canonical lock inodes. |
| `EXECUTOR_AGENT` | `req_executor` | Exact executor identity accepted in authenticated I1/I3 routing. |
| `DISPATCHER_CALLBACK_TARGET` | `agent:req_dispatcher:main` | Exact callback task; trigger data cannot redirect Issue results elsewhere. |

`scheduler_env.sh` accepts workstation overrides for scheduler fields and the two route pins from ignored `campaign_defaults.local.env` or the process environment. An explicit process value wins for the scheduler root and deployment pins and must be supplied consistently to intake, tick, import, and delivery. `EXECUTOR_MAX_CONCURRENCY`, `EXECUTOR_MAX_ISSUES_PER_REPOSITORY`, and `EXECUTOR_ACPX_TIMEOUT_SECONDS` supply initialization values only while scheduler state has no corresponding runtime value; use `/slot`, `/repo-slot`, and `/timeout-executor` for later changes. Scheduler roots must be strictly nested below `/data`, normalized `${HOME}`, or normalized `${TMPDIR:-/tmp}`; this keeps the blue-zone default valid while limiting workstation overrides to the user's home or temporary tree. The script rejects paths equal to those allowed roots, paths outside them, relative/unsafe paths, invalid concurrency, and acpx timeouts outside 60 through 18000 seconds before creating state.

`campaign_defaults.env` does not define branch, per-project quota, runtime basename, project data directory, account-pool, GitLab token, or a dependency-only Claude adapter. It defines scheduler initialization values only; `GITLAB_TOKEN` continues to use the process-environment-then-`gitlab.env` selection order above. Ordinary and dependency attempts use the same built-in `acpx ... claude exec` path.

## OpenClaw subagent timeout

OpenClaw 2026.6.11 rejects per-call `timeoutSeconds` and
`runTimeoutSeconds` fields on `sessions_spawn`. The optional outer limit is a
global runtime setting:

```bash
openclaw config get agents.defaults.subagents.runTimeoutSeconds
openclaw config validate
```

The gateway hot-applies valid `agents.*` changes. Run these commands as the
same service account and with the same OpenClaw profile/config path used by the
gateway; otherwise they may inspect a different `~/.openclaw/openclaw.json`.
The value is global across all agents. When positive, choose at least the
largest allowed `acpx_timeout_seconds + 2400`; the additional budget covers
the fixed stage/push/MR/label/summary caps inside `run_executor_attempt.sh`.
Because `/timeout-executor` allows up to 18000 seconds, keep the global value at
least `20400` even though the tracked attempt default is now 3600 seconds.
The runtime command never reads or writes this OpenClaw setting. It only
persists the executor acpx value; req_dispatcher derives its future agent,
exec-tool, legacy-reclaim, and stuck-eviction budgets from scheduler state.

The absence of a timeout parameter in the `sessions_spawn` tool call is
expected and does not mean the global timeout was dropped.

## Post-acpx slot recovery

`run_executor_attempt.sh` keeps acpx and all deterministic finalization in one
long Bash call and writes `${LOG_DIR}/worker_result.json` atomically before it
returns. That file is provisional until the wrapper completes archive/state
persistence and publishes private `${LOG_DIR}/attempt_finalized.json` last;
the marker binds its SHA-256, Issue, execution, branch, and business commit.
The periodic executor tick processes only that finalized result under the
exact job/generation/token-digest fence and emits `cleanup_actions[]` for the
stale native child if OpenClaw never schedules the outer model's final turn.

`run_acpx_attempt.sh` also writes exact-schema `${LOG_DIR}/acpx_terminal.json`
as soon as the inner process exits. If no durable final result appears after
the wrapper's bounded post-acpx budget, the tick reclaims the matching child.
The watchdog defaults to `EXECUTOR_POST_ACPX_GRACE_SECONDS=2400`. This is a
runtime/local-test override only: set it in the process environment or ignored
`campaign_defaults.local.env`; do not add workstation values to tracked
`campaign_defaults.env`. Values below 60 are rejected.

If logs report that an outer `GITLAB_TOKEN` differs from the deployment pin,
remember that the process environment wins by contract. Update or unset the
stale token in the OpenClaw service environment if `config/gitlab.env` should
provide the fallback.

## Runtime Layout

`req_executor` stores its own state under the fixed in-repo directory `${REPO_PATH}/.req_executor/`. This directory is not configurable through trigger fields or tracked config. `clone_or_pull.sh` adds `/.req_executor/` and `logs/` to the local `.git/info/exclude`. When business changes exist, `stage_and_guard.sh` force-adds the current issue's output directory and complete staging-time `${LOG_DIR}` into the same Issue-branch commit; a log-only run still returns `NO_CHANGES` for business-change classification. After the terminal `worker_result.json` is written, `archive_execution_logs.sh` appends the complete directory as the one log-only child on that same `WORK_BRANCH`. Single-Issue state keeps the reviewed business `commit_sha` separate from the exact remote `work_branch_sha` log child. No separate remote log branch is created. Unrelated `logs/` paths remain outside the commit index.

Deployments upgrading to the `attempt_finalized.json` contract must drain
active jobs started by an older wrapper before switching the heartbeat. New
ticks deliberately do not infer authority from an unlatched legacy
`worker_result.json`.

Driven-batch scheduling state is agent-wide rather than repository-local. By default, `scheduler_env.sh` initializes the following layout without replacing an existing valid `scheduler_state.json`:

```text
/data/req_executor/_scheduler/
  scheduler_state.json
  scheduler.lock
  batches/
  callback_inbox/
  callback_outbox/
  callback_archive/
  callback_locks/
  launch_actions/
  launch_action_archive/
  launch_action_locks/
  launch_failed_receipts/
```

These scheduler directories are mode `0700` because batch requests and callback
outbox entries contain private callback nonces and active scheduler records can
contain claim tokens. They are runtime authentication state, not public logs.
Hot callback/action directories contain only active JSON. Stable per-event locks
live in their independent lock directories, delivered callbacks and completed
actions move to cold archives, and token-digest-only launch-failure receipts are
directly addressable by the SHA-256 of `job_id` instead of accumulating inside
`scheduler_state.json`.

There is no UI-account pool configuration in this workspace. The issue body is passed to Claude Code as the task prompt; credentials, account pools, or project-specific data directories must be described by the issue itself if they are relevant.

## 受驱动批次部署与恢复

- tracked 蓝区默认保持 `EXECUTOR_MAX_CONCURRENCY=10`、`EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1` 和 `EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`。不得为了工作站测试修改 tracked `campaign_defaults.env` 中的 `/data` 默认值、GitLab host/protocol 或 token 注入契约。
- 工作站覆盖只能放在进程环境或 ignored `campaign_defaults.local.env`。scheduler root 等部署字段由显式进程环境优先于 local env，local env 优先于 tracked defaults；并发与 acpx timeout 字段仅用于尚无运行时值时的初始化，后续使用 `/slot`、`/repo-slot` 与 `/timeout-executor`。不要提交本机绝对路径、临时 session、测试 endpoint 或额外凭据。
- `dispatcher_callback_target`、`executor_agent` 与 `callback_nonce` 是 `RUN_DRIVEN_ISSUE_BATCH` 与新发 `RUN_SINGLE_ISSUE` 的必填 I1 字段。前两者必须匹配部署 pin，nonce 必须为 64 个小写 hex，只进入私有 durable state 和认证回调信封。driven-batch I1 还固定保存可选处理基准 `branch`、布尔值 `auto_merge` 与可选 `merge_target_branch`；明确请求分支优先，请求未指定时 executor 按“Issue 版本化 marker/唯一严格声明 → `origin/HEAD`”逐条解析，未指定 MR 目标时使其跟随最终处理基准。解析出的具体值在准备工作树前冻结，非法或冲突声明 fail closed。I1 定义项目、selector、处理及合并策略与回调路由字段；executor 按进程环境优先、`config/gitlab.env` 回退的顺序加载 `GITLAB_TOKEN`，并将它直接用于内部 scheduled trigger 与子任务 prompt。
- I1 schema 滚动升级时先暂停新的执行请求，排空或停止旧 executor，部署并验证新版 executor，最后才升级 dispatcher。旧 executor 的严格字段白名单不接受 `auto_merge` 与 `merge_target_branch`；新版 dispatcher 对普通请求也会固定发送 `auto_merge=false`，所以新版 I1 和自动合并请求都不得发往旧 executor。回滚时先停止新入口与双方 tick，先回滚 dispatcher 或保留新版 executor，确认不再发送新字段后才可回滚 executor；未完成自动合并 intent 原样保留等待恢复。
- 私有仓库的 clone、fetch、ls-remote、push 使用普通 `git`，`origin` 采用 `${GITLAB_API_PROTOCOL}://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GROUP}/${PROJECT}.git` 形式的直接认证 URL。Git 子进程与 callback `openclaw` 子进程继承 executor 当前环境，包括按上述优先级选中的 `GITLAB_TOKEN`。
- 只有升级前已存在于 mode `0700` scheduler 根、同时缺少 executor/nonce 的旧 request/outbox 才会被 executor 显式投影为 `legacy_pre_upgrade` 并沿 raw 八字段 I3 兼容投递。新 intake 缺少认证字段或携带 `callback_auth_mode=legacy_pre_upgrade` 都必须失败，不能由请求输入降级。
- lock layout 升级由 `${EXECUTOR_SCHEDULER_ROOT}/lock_layout_v2.json` 固定起点。默认 86400 秒兼容窗口内，新进程按旧路径→新路径的固定顺序同时加锁，避免尚在运行的旧 drainer/coordinator 与新进程分裂互斥域；窗口结束后同时锁住两侧再把旧 inode 移到独立锁目录，绝不覆盖 canonical 新锁。确认所有旧进程已停止时可通过进程环境或 local env 将窗口设为 `0` 提前收口。
- 初始默认允许 10 个 GitLab 仓库并行，由所有 driven batch 共享，可用 `/slot <正整数>` 在线调整并持久化。每个仓库的 Issue 并发初始为 1，可用 `/repo-slot <正整数>` 独立调整；不同 IID 使用各自 worktree，同一 IID 仍严格去重。acpx timeout 初始默认 3600 秒，可用 `/timeout-executor <时长>` 在线调整并持久化，且只影响后续 attempt；req_dispatcher 会从该 scheduler state 派生后续 executor turn、exec 工具、旧队列回收和 stuck 驱逐预算，但不会修改 OpenClaw 全局 timeout。并发缩容不取消已启动任务；新 reservation 在相应边界等待自然回落，未启动的仓库内多余 reservation 由下一 tick 退回 pending。scheduler 持久保存 snapshot 游标与 round-robin 游标；即使单批包含 100+ Issue，也只按严格轮转逐步发放 grant，不把 IID 列表或全部 runtime action 展开到聊天上下文。
- 部署周期触发固定为 `RUN_EXECUTOR_BATCH_TICK`，建议每分钟在 executor main session 唤醒一次。tick 对项目预检已经 `pr`、`finish` 或 closed 的 running claim 立即执行同代 fence 与 GitLab 二次核验并生成 `skipped` handoff；`pr` 表示 MR 等待人工处理，`finish` 表示显式请求的自动合并已按精确 MR 身份、目标分支和 SHA 验证成功。对仍无完成证据且超过 lease/ACPX deadline 的丢回调任务继续走 timeout 兜底。tick 还会用 scheduler active job 与未完成 launch coordinator 保护集清理无任何运行标识的旧 driven placeholder，然后恢复 durable handoff/outbox 和未完成协调阶段，再按严格 round-robin 补满空槽；未确认的 spawn 只隔离其精确 `job_id`，不会阻塞其他仓库预约和补位；outbox 每 tick 默认最多投递 3 条，失败按持久时间退避，因此大量失败回调不会阻止 reservation；完成数据退出热扫描后仍保留冷归档，它不依赖此前聊天 turn 的内存。
- 升级时先让 req_dispatcher 排空旧 FIFO。旧 active/queue 非空期间，新 batch 保持 `waiting_for_legacy_drain`，不得与旧 single active 重叠启动；旧队列清空后再由周期 tick 推进新 scheduler。
- 回滚时先停止新的 batch 入口和周期 `RUN_EXECUTOR_BATCH_TICK`。可以在停用前排空，也可以原样保留 `${EXECUTOR_SCHEDULER_ROOT}` 下的 scheduler state、batch snapshot、handoff 与 callback outbox，等待恢复后继续；不得删除这些 durable runtime 记录。
