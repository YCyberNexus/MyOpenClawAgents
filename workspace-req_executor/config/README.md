# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are not generated from ordinary issue triggers. Runtime `/slot` control persists its value in scheduler state and does not edit these files.

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

The runner has to know where to clone repositories before it can read issue content or repository-local guidance. The driven-batch scheduler also needs one agent-level state root outside all clones and one physical concurrency ceiling shared by every project. Everything else is either supplied by the issue/wiki, supplied by req_dispatcher as an optional `branch`, inferred by the wrapper (`branch` from `origin/HEAD` when omitted), or handled by Claude Code/OpenClaw defaults.

### Fields

| Field | Pinned value | Meaning |
| --- | --- | --- |
| `REPO_PARENT_PATH` | `/data` | Absolute parent under which the project is cloned; the final clone target is `${REPO_PARENT_PATH}/${PROJECT}`. Use ignored `campaign_defaults.local.env` to override this for local testing. |
| `EXECUTOR_SCHEDULER_ROOT` | `/data/req_executor/_scheduler` | Absolute agent-level root for scheduler state, lock, batch records, and callback inbox/outbox. |
| `EXECUTOR_MAX_CONCURRENCY` | `3` | Positive integer initialization default shared across all driven batches; `/slot` persists the later runtime ceiling in scheduler state. |
| `EXECUTOR_RUNNING_LEASE_SECONDS` | `21600` | Backstop before tick checks a running claim for a lost callback; the project-side ACPX deadline is still authoritative. |
| `DRIVEN_LEGACY_LOCK_COMPAT_SECONDS` | `86400` | Persisted rollout window in which new wrappers acquire both old and new callback/launch lock paths. Set to `0` only after all pre-upgrade executor processes have stopped; expired windows migrate old locks out of hot directories without replacing canonical lock inodes. |
| `EXECUTOR_AGENT` | `req_executor` | Exact executor identity accepted in authenticated I1/I3 routing. |
| `DISPATCHER_CALLBACK_TARGET` | `agent:req_dispatcher:main` | Exact callback task; trigger data cannot redirect Issue results elsewhere. |

`scheduler_env.sh` accepts workstation overrides for scheduler fields and the two route pins from ignored `campaign_defaults.local.env` or the process environment. An explicit process value wins for the scheduler root and deployment pins and must be supplied consistently to intake, tick, import, and delivery. `EXECUTOR_MAX_CONCURRENCY` supplies the initial ceiling only while scheduler state has no runtime `max_concurrency`; use `/slot` for later changes. Scheduler roots must be strictly nested below `/data`, normalized `${HOME}`, or normalized `${TMPDIR:-/tmp}`; this keeps the blue-zone default valid while limiting workstation overrides to the user's home or temporary tree. The script rejects paths equal to those allowed roots, paths outside them, relative/unsafe paths, and non-positive/non-integer concurrency values before creating state.

`campaign_defaults.env` does not define branch, per-project quota, timeout, runtime basename, project data directory, account-pool, or GitLab token fields. `GITLAB_TOKEN` continues to use the process-environment-then-`gitlab.env` selection order above.

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
largest deployed `acpx_timeout_seconds + 120`; for a 36000-second acpx budget,
use at least `36120`.

The absence of a timeout parameter in the `sessions_spawn` tool call is
expected and does not mean the global timeout was dropped.

If logs report that an outer `GITLAB_TOKEN` differs from the deployment pin,
remember that the process environment wins by contract. Update or unset the
stale token in the OpenClaw service environment if `config/gitlab.env` should
provide the fallback.

## Runtime Layout

`req_executor` stores its own state under the fixed in-repo directory `${REPO_PATH}/.req_executor/`. This directory is not configurable through trigger fields or tracked config. `clone_or_pull.sh` adds `/.req_executor/` and `logs/` to the local `.git/info/exclude`; `stage_and_guard.sh` force-adds only the current issue's output directory and removes `${LOG_DIR}` plus any `logs/` path from the commit index.

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

- tracked 蓝区默认保持 `EXECUTOR_MAX_CONCURRENCY=3` 和 `EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`。不得为了工作站测试修改 tracked `campaign_defaults.env` 中的 `/data` 默认值、GitLab host/protocol 或 token 注入契约。
- 工作站覆盖只能放在进程环境或 ignored `campaign_defaults.local.env`。scheduler root 等部署字段由显式进程环境优先于 local env，local env 优先于 tracked defaults；并发字段仅用于尚无运行时值时的初始化，后续使用 `/slot`。不要提交本机绝对路径、临时 session、测试 endpoint 或额外凭据。
- `dispatcher_callback_target`、`executor_agent` 与 `callback_nonce` 是 `RUN_DRIVEN_ISSUE_BATCH` 与新发 `RUN_SINGLE_ISSUE` 的必填 I1 字段。前两者必须匹配部署 pin，nonce 必须为 64 个小写 hex，只进入私有 durable state 和认证回调信封。I1 定义项目、selector 与回调路由字段；executor 按进程环境优先、`config/gitlab.env` 回退的顺序加载 `GITLAB_TOKEN`，并将它直接用于内部 scheduled trigger 与子任务 prompt。
- 私有仓库的 clone、fetch、ls-remote、push 使用普通 `git`，`origin` 采用 `${GITLAB_API_PROTOCOL}://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GROUP}/${PROJECT}.git` 形式的直接认证 URL。Git 子进程与 callback `openclaw` 子进程继承 executor 当前环境，包括按上述优先级选中的 `GITLAB_TOKEN`。
- 只有升级前已存在于 mode `0700` scheduler 根、同时缺少 executor/nonce 的旧 request/outbox 才会被 executor 显式投影为 `legacy_pre_upgrade` 并沿 raw 八字段 I3 兼容投递。新 intake 缺少认证字段或携带 `callback_auth_mode=legacy_pre_upgrade` 都必须失败，不能由请求输入降级。
- lock layout 升级由 `${EXECUTOR_SCHEDULER_ROOT}/lock_layout_v2.json` 固定起点。默认 86400 秒兼容窗口内，新进程按旧路径→新路径的固定顺序同时加锁，避免尚在运行的旧 drainer/coordinator 与新进程分裂互斥域；窗口结束后同时锁住两侧再把旧 inode 移到独立锁目录，绝不覆盖 canonical 新锁。确认所有旧进程已停止时可通过进程环境或 local env 将窗口设为 `0` 提前收口。
- 初始默认 3 个物理槽位由所有 driven batch 共享，可用 `/slot <正整数>` 在线调整并持久化。缩容不取消已有任务，只暂停新 reservation 直到 active 数回落。scheduler 持久保存 snapshot 游标与 round-robin 游标；即使单批包含 100+ Issue，也只按严格轮转逐步发放 grant，不把 IID 列表或全部 runtime action 展开到聊天上下文。
- 部署周期触发固定为 `RUN_EXECUTOR_BATCH_TICK`，建议每分钟在 executor main session 唤醒一次。tick 对项目预检已经 `pr`/closed 的 running claim 立即执行同代 fence 与 GitLab 二次核验并生成 `skipped` handoff；对仍无完成证据且超过 lease/ACPX deadline 的丢回调任务继续走 timeout 兜底。tick 还会用 scheduler active job 与未完成 launch coordinator 保护集清理无任何运行标识的旧 driven placeholder，然后恢复 durable handoff/outbox 和未完成协调阶段，再按严格 round-robin 补满空槽；outbox 每 tick 默认最多投递 3 条，失败按持久时间退避，因此大量失败回调不会阻止 reservation；完成数据退出热扫描后仍保留冷归档，它不依赖此前聊天 turn 的内存。
- 升级时先让 req_dispatcher 排空旧 FIFO。旧 active/queue 非空期间，新 batch 保持 `waiting_for_legacy_drain`，不得与旧 single active 重叠启动；旧队列清空后再由周期 tick 推进新 scheduler。
- 回滚时先停止新的 batch 入口和周期 `RUN_EXECUTOR_BATCH_TICK`。可以在停用前排空，也可以原样保留 `${EXECUTOR_SCHEDULER_ROOT}` 下的 scheduler state、batch snapshot、handoff 与 callback outbox，等待恢复后继续；不得删除这些 durable runtime 记录。
