# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are NOT generated from trigger inputs and they are NOT touched by the agent at runtime.

## `gitlab.env`

Pins the GitLab host the agent talks to. Required fields:

- `GITLAB_HOST` — host (with port if non-default) of the pinned GitLab instance. Exported by `scripts/glab_auth.sh`; `glab` reads it natively from the env var, so `glab api` / `glab mr` / `glab issue` calls **must NOT pass `--hostname`** (only `glab auth login` / `glab auth status` inside `glab_auth.sh` take that flag). Example: `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

### Why pin?

The agent runs unattended for long stretches. Re-parsing the host out of `${GITLAB_ADDRESS}` on every tick is fragile — variable corruption, accidental whitespace, or a bad `sed` regex would silently make the agent talk to the wrong place. By pinning at deployment time:

- the agent uses a single, fixed `GITLAB_HOST` on every call to `glab`
- the trigger's `gitlab_address` becomes a **verification** input — if it doesn't resolve to the pinned host, the agent aborts the affected operation with `block_reason="trigger gitlab_address does not match deployed gitlab.env"`
- token rotation still works: `gitlab_token` from the trigger is forwarded to `glab auth login --token ...` against the pinned host on every tick

### Setup

1. Edit `gitlab.env` on the runner with the correct host and protocol.
2. Run `glab auth login --hostname <host> --token <token> --api-protocol <proto>` once manually to validate; you should see `glab auth status --hostname <host>` succeed.
3. After this, the agent is free to run scheduled ticks.

### Multiple GitLab hosts?

This workspace assumes a single GitLab deployment per runner. If you ever need to point a different runner at a different GitLab, change `gitlab.env` on that runner. Do not try to make the agent multi-tenant by reading the host from trigger inputs — that defeats the whole point of pinning.

## `ui_accounts.env`

Pins the pool of UI test accounts the dispatcher draws from when allocating credentials to issue subagents.

Per the test team's confirmed behavior, the system under test logs out an account when the same credentials log in twice. Each subagent therefore receives a distinct slot of UI accounts (one per robot test file) — sharing an account between concurrent subagents (or between concurrent robot files within a subagent) would let them kick each other out. The pool size acts as the hard upper bound on `max_concurrent_subagents` (the pool is divided into exactly that many slots): a tick whose `max_concurrent_subagents` exceeds the pool aborts with `"ui_account_pool_too_small"`.

### Format

One account per line, `username:password`. Lines starting with `#` and blank lines are ignored. Example (40-account pool for 4 concurrent subagents — slot sizes auto-computed as `10,10,10,10`):

```
F100001:123456
F100002:123456
...
F100040:123456
```

### Sizing rule

The pool must contain at least `max_concurrent_subagents` valid accounts (each in-flight subagent must hold ≥ 1 distinct credential). Per-IID slot sizes are derived automatically as `floor(pool_size / max_concurrent_subagents)` with the integer remainder front-loaded onto the first slots — so a 40-account pool with `max_concurrent_subagents=4` gives slot sizes `10,10,10,10`, while `max_concurrent_subagents=3` gives `14,13,13`. The dispatcher checks pool sizing every tick via `scripts/load_ui_accounts.sh`; if `MAX_CONCURRENT_SUBAGENTS > POOL_SIZE` the script exits 13 and the dispatcher aborts the tick with `"ui_account_pool_too_small: pool=<size> max_concurrent_subagents=<value>"`. Operationally the pool should be sized for the **maximum number of robot test files any single issue runs concurrently times the desired concurrency cap**, since that determines how many distinct credentials the worst-case slot must hold.

### How it flows through the agent

1. Dispatcher reads `<workspace>/config/ui_accounts.env` via `scripts/load_ui_accounts.sh` at the top of every batch, passing `MAX_CONCURRENT_SUBAGENTS`. The script prints the full pool on stdout and the metadata `POOL_SIZE=<n>` / `SLOT_SIZES=<csv>` on stderr.
2. Dispatcher slices the stdout into per-IID blocks using `SLOT_SIZES`: the `k`-th IID of the batch (k=0..batch_size-1) gets `SLOT_SIZES[k]` accounts starting at offset `sum(SLOT_SIZES[0..k-1])`. When `batch_size < max_concurrent_subagents`, only the first `batch_size` slots are consumed; the remaining accounts stay unused for the tick.
3. For each IID, the dispatcher invokes `scripts/build_prompt.sh` with that IID's `UI_ACCOUNTS='[{"u":"<user>","p":"<pass>"},...]'` — a JSON array of all accounts allocated to this IID. The script renders them as a numbered list in the `# Working environment` section of the Claude Code prompt at `${LOG_DIR}/prompt.txt` with an explicit override note. The credentials are NOT injected into the rendered subagent prompt — they live in the Claude Code prompt only, where Claude Code reads them.
4. After each callback drains the corresponding pending subagent, that subagent's account block implicitly returns to the pool — the dispatcher does not persist allocations across batches; the next batch re-allocates from the head of the file (the single-batch-in-flight invariant guarantees `pending_subagents` is empty before the next batch forms).

### Setup

1. Create the accounts on the system under test (e.g. `F100001`–`F100040` for a 40-account pool sized to support 4 concurrent subagents × 10 robot files each).
2. Edit `ui_accounts.env` with the credentials.
3. Make sure there are at least `max_concurrent_subagents` valid non-comment account lines (and ideally enough that each slot covers the worst-case robot-file count).
4. Re-run the scheduled tick.
