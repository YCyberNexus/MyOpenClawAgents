# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are NOT generated from trigger inputs and they are NOT touched by the agent at runtime.

## `gitlab.env`

Pins the GitLab host the agent talks to. Required fields:

- `GITLAB_HOST` — host (with port if non-default) of the pinned GitLab instance. Exported by `scripts/glab_auth.sh`; `glab` reads it natively from the env var, so `glab api` / `glab mr` / `glab issue` calls **must NOT pass `--hostname`** (only `glab auth login` / `glab auth status` inside `glab_auth.sh` take that flag). Example: `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

### Why pin?

The agent runs unattended for long stretches. Re-parsing the host out of `${GITLAB_ADDRESS}` on every tick is fragile — variable corruption, accidental whitespace, or a bad `sed` regex would silently make the agent talk to the wrong place. By pinning at deployment time:

- the agent uses a single, fixed `GITLAB_HOST` on every call to `glab`
- the trigger's `gitlab_address` becomes a **verification** input — if it doesn't resolve to the pinned host, `scripts/glab_auth.sh` aborts with **exit 13** (stderr: `trigger gitlab_address (...) does not match deployment pin (...)`) and the orchestrator records a `block_reason` to that effect. (Exit codes: `10` pin file missing, `11` required field missing, `12` bad `GITLAB_API_PROTOCOL`, `13` trigger/pin host or protocol mismatch.)
- token rotation still works: `gitlab_token` from the trigger is forwarded to `glab auth login --token ...` against the pinned host on every tick

### Setup

1. Edit `gitlab.env` on the runner with the correct host and protocol.
2. Run `glab auth login --hostname <host> --token <token> --api-protocol <proto>` once manually to validate; you should see `glab auth status --hostname <host>` succeed.
3. After this, the agent is free to run scheduled ticks.

### Multiple GitLab hosts?

This workspace assumes a single GitLab deployment per runner. If you ever need to point a different runner at a different GitLab, change `gitlab.env` on that runner. Do not try to make the agent multi-tenant by reading the host from trigger inputs — that defeats the whole point of pinning.

## `campaign_defaults.env` (driven single-issue test pin)

Pins every campaign field that the **driven** `RUN_SINGLE_ISSUE_TEST` entry point needs but does NOT receive from its trigger. On the driven path, `req_dispatcher` sends only the I1 trigger inputs — `project`, `iid`, `correlation_id`, `dispatcher_callback_target`, and optional `group` — and `dispatch_single_issue.sh` (the driven entry script) sources this file to synthesize a campaign env equivalent to a `RUN_SCHEDULED_ISSUE_CAMPAIGN` over `issue_iids=[iid]`. **Trigger inputs do not override these values on the driven path.**

Like `gitlab.env`, this file is `source`d (and may be loaded under `set -a`), so it must stay pure `KEY=value` lines — no shell logic, no command substitution, no conditionals.

### Why these are pinned (and not on the trigger)

The driven path tests exactly **one** issue per trigger and must stay deterministic regardless of who drives it. Pinning the campaign shape here keeps `req_dispatcher` a thin driver (it only knows which issue to test, not how the executor is configured) and keeps the executor's behavior identical to its scheduled path. In particular the driven single test is **fixed at `quota=1` / `concurrency=1`**: one IID is dispatched, one subagent runs, and the UI-account pool (when configured) divides into a single slot — there is no cross-IID batching on this path.

### Fields

| Field | Pinned value | Meaning |
| --- | --- | --- |
| `BRANCH` | `master` | Integration / MR target branch; MRs are opened against it (see CLAUDE.md §Two-branch model). |
| `DEV_BRANCH` | `dev` | Clean baseline + shared-config source branch; fresh-mode attempts reset the per-issue worktree to `origin/${DEV_BRANCH}`. Set equal to `BRANCH` to disable. |
| `HOURLY_ISSUE_QUOTA` | `1` | Per-tick launch quota. Pinned to 1 — the driven path tests exactly one issue per trigger. |
| `MAX_CONCURRENT_SUBAGENTS` | `1` | Batch-size + in-flight-subagent cap. Pinned to 1 — the single driven IID is the only thing in flight (no cross-IID parallelism). |
| `MAX_ACCOUNTS_PER_ISSUE` | `14` | Cap on UI accounts handed to one IID after the pool is divided by concurrency. Matches the dispatcher default. |
| `UI_ACCOUNTS_RELPATH` | *(empty)* | Relpath (under the project checkout root) of the UI-account pool file. Empty = UI accounts opt-out: the dispatcher skips the entire UI-account flow and the rendered prompt omits its `# UI test accounts` section. Pin a relpath (e.g. `ifp-data/ifp-common/ifp_users.json`) to opt in. See the UI-account section below. |
| `ACPX_TIMEOUT_SECONDS` | `18000` | acpx exec wall-clock cap for one attempt; on overrun the attempt is parked as terminal `timeout` (never auto-retried). |
| `RUN_TIMEOUT_SECONDS` | `18120` | Subagent runtime cap forwarded to `sessions_spawn` as `runTimeoutSeconds`; kept just above `ACPX_TIMEOUT_SECONDS` (acpx cap + 120) so the runtime never kills the subagent before acpx's own timeout flow runs. |
| `RESULT_BASENAME` | `ifp-result` | Basename of the agent runtime root inside the checkout; `env_paths.sh` derives `RESULT_ROOT=${REPO_PATH}/${RESULT_BASENAME}`. |
| `DATA_BASENAME` | `ifp-data` | Basename of the test team's knowledge-base directory; `env_paths.sh` derives `DATA_DIR=${REPO_PATH}/${DATA_BASENAME}`. |
| `REPO_PARENT_PATH` | `/data` | Absolute parent under which the project is cloned; the final clone target is `${REPO_PARENT_PATH}/${PROJECT}`. |

### Token injection — 待对齐

`GITLAB_TOKEN` is **not** pinned in this file, and the driven trigger (I1) does not carry one either. How the token reaches `dispatch_single_issue.sh` on the driven path is a deployment-integration decision still **待对齐** — see the explicit `待对齐` comment block at the bottom of `campaign_defaults.env` for the candidate options (pin in-file / out-of-band env injection / runner-local secret file). Until that is aligned, the driven entry script reads `GITLAB_TOKEN` from the environment (as the scheduled path already does) and fails loudly when it is absent.

## UI account pool: `${UI_ACCOUNTS_RELPATH}` (optional — no default)

Pins the pool of UI test accounts the dispatcher draws from when allocating credentials to issue subagents. This file is committed/maintained by the test team inside the cloned project repo, not edited in this agent workspace.

UI accounts are **opt-in**. When a deployment does not configure `ui_accounts_relpath` (trigger field, carry-forward persisted; no default), the dispatcher skips the entire pool flow: no file is read, `ui_account_pool_size` is `0` for every tick, every IID gets `ui_account_count = 0`, and the rendered Claude Code prompt omits its `# UI test accounts` section. The rest of this document covers what happens when the field IS configured.

Per the test team's confirmed behavior, the system under test logs out an account when the same credentials log in twice. Each subagent therefore receives a distinct slot of UI accounts (one per robot test file) — sharing an account between concurrent subagents (or between concurrent robot files within a subagent) would let them kick each other out. When the pool is configured, the pool size acts as the hard upper bound on `max_concurrent_subagents` (the pool is divided into exactly that many slots): a tick whose `max_concurrent_subagents` exceeds the pool aborts with `"ui_account_pool_too_small"`.

### Format

When configured, the dispatcher reads `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}`, where `REPO_PATH` is the final project checkout path and `UI_ACCOUNTS_RELPATH` is the trigger-supplied (or carry-forward persisted) value of `ui_accounts_relpath`. **There is no default.** The relpath is resolved **directly under `${REPO_PATH}`**, NOT under `${REPO_PATH}/${DATA_BASENAME}/`, so the pool file may live under any repo subdirectory — typically under the data dir (e.g. `ifp-data/ifp-common/ifp_users.json` or `pts-data/pts-common/pts_users.json`), but a deployment could also point it at `qa-config/users.json` or any other tracked path. See [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](../skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md) for the full trigger contract. **Schema migration:** before SKILL_VERSION 2026-05-27.1 this field was resolved under `${REPO_PATH}/${DATA_BASENAME}/` — a deployment with a persisted carry-forward like `ifp-common/ifp_users.json` must re-send the trigger once with the basename prefixed (e.g. `ui_accounts_relpath=ifp-data/ifp-common/ifp_users.json`).

The JSON must be a top-level array. Each entry must contain non-empty string `username` and `password` fields. `name` and any other fields are ignored. Example:

```json
[
  {
    "username": "F100001",
    "password": "123456",
    "name": "..."
  },
  {
    "username": "F100002",
    "password": "123456",
    "name": "..."
  }
]
```

### Sizing rule

The pool must contain at least `max_concurrent_subagents` valid accounts (each in-flight subagent must hold ≥ 1 distinct credential). Per-IID slot sizes are derived automatically as `floor(pool_size / max_concurrent_subagents)` with the integer remainder front-loaded onto the first slots, then capped by `max_accounts_per_issue` (trigger field, default `14`). So a 40-account pool with `max_concurrent_subagents=4` and default cap gives slot sizes `10,10,10,10`, `max_concurrent_subagents=3` gives `14,13,13`, and `max_concurrent_subagents=1` gives `14` instead of the full pool. The dispatcher checks pool sizing every tick via `scripts/load_ui_accounts.sh`; if `MAX_CONCURRENT_SUBAGENTS > POOL_SIZE` the script exits 13 and the dispatcher aborts the tick with `"ui_account_pool_too_small: pool=<size> max_concurrent_subagents=<value>"`; if `MAX_ACCOUNTS_PER_ISSUE` is not a positive integer, the script exits 15 and the dispatcher aborts with `"invalid_max_accounts_per_issue: must be >= 1"`. Operationally `max_accounts_per_issue` should be at least the maximum number of robot test files any single issue runs concurrently.

### How it flows through the agent

1. Dispatcher runs `clone_or_pull.sh` first, then — **only when `UI_ACCOUNTS_RELPATH` is configured** — reads `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}` via `scripts/load_ui_accounts.sh`, passing `MAX_CONCURRENT_SUBAGENTS`, `MAX_ACCOUNTS_PER_ISSUE` (default `14`), and `UI_ACCOUNTS_RELPATH`. The script prints the full pool on stdout as `username:password` lines and the metadata `POOL_SIZE=<n>` / capped `SLOT_SIZES=<csv>` on stderr. When `UI_ACCOUNTS_RELPATH` is unconfigured the dispatcher skips this step entirely and the remaining steps in this section do not apply.
2. Dispatcher slices the stdout into per-IID blocks using `SLOT_SIZES`: the `k`-th IID of the batch (k=0..batch_size-1) gets `SLOT_SIZES[k]` accounts starting at offset `sum(SLOT_SIZES[0..k-1])`. When `batch_size < max_concurrent_subagents`, only the first `batch_size` slots are consumed; the remaining accounts stay unused for the tick. If `max_accounts_per_issue` caps a raw slot, the surplus accounts also stay unused for the tick.
3. For each IID, the dispatcher invokes `scripts/build_prompt.sh` with that IID's `UI_ACCOUNTS='[{"u":"<user>","p":"<pass>"},...]'` — a JSON array of all accounts allocated to this IID. The script renders them as a numbered list in the `# Working environment` section of the Claude Code prompt at `${LOG_DIR}/prompt.txt` with an explicit override note. The credentials are NOT injected into the rendered subagent prompt — they live in the Claude Code prompt only, where Claude Code reads them.
4. After each callback drains the corresponding pending subagent, that subagent's account block implicitly returns to the pool — the dispatcher does not persist allocations across batches; the next batch re-allocates from the head of the file (the single-batch-in-flight invariant guarantees `pending_subagents` is empty before the next batch forms).

### Setup

1. Create the accounts on the system under test (e.g. `F100001`–`F100040` for a 40-account pool sized to support 4 concurrent subagents × 10 robot files each, or a larger pool if you want spare accounts while keeping `max_accounts_per_issue` capped).
2. Set `ui_accounts_relpath` on the next scheduled trigger (e.g. `ui_accounts_relpath=ifp-data/ifp-common/ifp_users.json`) and ask the test team to commit/update that file on the project branch the dispatcher clones. If the deployment does NOT use UI accounts, leave `ui_accounts_relpath` unset and skip the rest of this section.
3. Make sure there are at least `max_concurrent_subagents` valid JSON account entries, and set `max_accounts_per_issue` high enough to cover the worst-case robot-file count for one issue.
4. Re-run the scheduled tick.

`config/ui_accounts.env` is kept only as a legacy placeholder. The dispatcher no longer reads it.
