# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are NOT generated from trigger inputs and they are NOT touched by the agent at runtime.

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

Pins the clone parent used by the **driven** `RUN_SINGLE_ISSUE` entry point and the agent-wide driven-batch scheduler settings. On the single-issue driven path, `req_dispatcher` sends only the I1 trigger inputs: `project`, `iid`, `correlation_id`, `dispatcher_callback_target`, and optional `group` / `branch`.

Like `gitlab.env`, this file is `source`d (and may be loaded under `set -a`), so it must stay pure `KEY=value` lines — no shell logic, no command substitution, no conditionals.

### Why these values are pinned

The runner has to know where to clone repositories before it can read issue content or repository-local guidance. The driven-batch scheduler also needs one agent-level state root outside all clones and one physical concurrency ceiling shared by every project. Everything else is either supplied by the issue/wiki, supplied by req_dispatcher as an optional `branch`, inferred by the wrapper (`branch` from `origin/HEAD` when omitted), or handled by Claude Code/OpenClaw defaults.

### Fields

| Field | Pinned value | Meaning |
| --- | --- | --- |
| `REPO_PARENT_PATH` | `/data` | Absolute parent under which the project is cloned; the final clone target is `${REPO_PARENT_PATH}/${PROJECT}`. Use ignored `campaign_defaults.local.env` to override this for local testing. |
| `EXECUTOR_SCHEDULER_ROOT` | `/data/req_executor/_scheduler` | Absolute agent-level root for scheduler state, lock, batch records, and callback inbox/outbox. |
| `EXECUTOR_MAX_CONCURRENCY` | `3` | Positive integer physical concurrency limit shared across all driven batches. |

`scheduler_env.sh` accepts workstation overrides for the two scheduler fields from ignored `campaign_defaults.local.env` or the process environment. Scheduler roots must be strictly nested below `/data`, normalized `${HOME}`, or normalized `${TMPDIR:-/tmp}`; this keeps the blue-zone default valid while limiting workstation overrides to the user's home or temporary tree. The script rejects paths equal to those allowed roots, paths outside them, relative/unsafe paths, and non-positive/non-integer concurrency values before creating state.

Do not put branch, per-project quota, timeout, token, runtime basename, project data directory, or account-pool fields in `campaign_defaults.env`.

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
provide the fallback; never print either token while diagnosing.

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
```

There is no UI-account pool configuration in this workspace. The issue body is passed to Claude Code as the task prompt; credentials, account pools, or project-specific data directories must be described by the issue itself if they are relevant.

## 受驱动批次部署与恢复

- tracked 蓝区默认保持 `EXECUTOR_MAX_CONCURRENCY=3` 和 `EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`。不得为了工作站测试修改 tracked `campaign_defaults.env` 中的 `/data` 默认值、GitLab host/protocol 或 token 注入契约。
- 工作站覆盖只能放在进程环境或 ignored `campaign_defaults.local.env`。对 scheduler 字段，显式进程环境优先于 local env，local env 优先于 tracked defaults；不要提交本机绝对路径、临时 session、测试 endpoint 或额外凭据。
- `dispatcher_callback_target` 是 `RUN_DRIVEN_ISSUE_BATCH` 与 `RUN_SINGLE_ISSUE` 兼容 shim 的必填 I1 字段。executor 从自身进程环境或 `config/gitlab.env` 加载 GitLab 凭据；req_dispatcher 的 I1 不携带 token。
- 默认 3 个物理槽位由所有 driven batch 共享。scheduler 持久保存 snapshot 游标与 round-robin 游标；即使单批包含 100+ Issue，也只按严格轮转逐步发放 grant，不把 IID 列表或全部 runtime action 展开到聊天上下文。
- 部署周期触发固定为 `RUN_EXECUTOR_BATCH_TICK`，建议每分钟在 executor main session 唤醒一次。tick 先恢复 durable handoff/outbox 和未完成协调阶段，再按严格 round-robin 补满空槽；它不依赖此前聊天 turn 的内存。
- 升级时先让 req_dispatcher 排空旧 FIFO。旧 active/queue 非空期间，新 batch 保持 `waiting_for_legacy_drain`，不得与旧 single active 重叠启动；旧队列清空后再由周期 tick 推进新 scheduler。
- 回滚时先停止新的 batch 入口和周期 `RUN_EXECUTOR_BATCH_TICK`。可以在停用前排空，也可以原样保留 `${EXECUTOR_SCHEDULER_ROOT}` 下的 scheduler state、batch snapshot、handoff 与 callback outbox，等待恢复后继续；不得删除这些 durable runtime 记录。
