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

## UI account pool: `${DATA_BASENAME}/ifp-common/ifp_users.json`

Pins the pool of UI test accounts the dispatcher draws from when allocating credentials to issue subagents. This file is committed/maintained by the test team inside the cloned project repo, not edited in this agent workspace.

Per the test team's confirmed behavior, the system under test logs out an account when the same credentials log in twice. Each subagent therefore receives a distinct slot of UI accounts (one per robot test file) — sharing an account between concurrent subagents (or between concurrent robot files within a subagent) would let them kick each other out. The pool size acts as the hard upper bound on `max_concurrent_subagents` (the pool is divided into exactly that many slots): a tick whose `max_concurrent_subagents` exceeds the pool aborts with `"ui_account_pool_too_small"`.

### Format

The dispatcher reads `${REPO_PATH}/${DATA_BASENAME}/ifp-common/ifp_users.json`, where `REPO_PATH` is the final project checkout path and `DATA_BASENAME` defaults to `ifp-data`.

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

1. Dispatcher runs `clone_or_pull.sh` first, then reads `${REPO_PATH}/${DATA_BASENAME}/ifp-common/ifp_users.json` via `scripts/load_ui_accounts.sh`, passing `MAX_CONCURRENT_SUBAGENTS` and `MAX_ACCOUNTS_PER_ISSUE` (default `14`). The script prints the full pool on stdout as `username:password` lines and the metadata `POOL_SIZE=<n>` / capped `SLOT_SIZES=<csv>` on stderr.
2. Dispatcher slices the stdout into per-IID blocks using `SLOT_SIZES`: the `k`-th IID of the batch (k=0..batch_size-1) gets `SLOT_SIZES[k]` accounts starting at offset `sum(SLOT_SIZES[0..k-1])`. When `batch_size < max_concurrent_subagents`, only the first `batch_size` slots are consumed; the remaining accounts stay unused for the tick. If `max_accounts_per_issue` caps a raw slot, the surplus accounts also stay unused for the tick.
3. For each IID, the dispatcher invokes `scripts/build_prompt.sh` with that IID's `UI_ACCOUNTS='[{"u":"<user>","p":"<pass>"},...]'` — a JSON array of all accounts allocated to this IID. The script renders them as a numbered list in the `# Working environment` section of the Claude Code prompt at `${LOG_DIR}/prompt.txt` with an explicit override note. The credentials are NOT injected into the rendered subagent prompt — they live in the Claude Code prompt only, where Claude Code reads them.
4. After each callback drains the corresponding pending subagent, that subagent's account block implicitly returns to the pool — the dispatcher does not persist allocations across batches; the next batch re-allocates from the head of the file (the single-batch-in-flight invariant guarantees `pending_subagents` is empty before the next batch forms).

### Setup

1. Create the accounts on the system under test (e.g. `F100001`–`F100040` for a 40-account pool sized to support 4 concurrent subagents × 10 robot files each, or a larger pool if you want spare accounts while keeping `max_accounts_per_issue` capped).
2. Ask the test team to commit/update `${DATA_BASENAME}/ifp-common/ifp_users.json` on the project branch the dispatcher clones.
3. Make sure there are at least `max_concurrent_subagents` valid JSON account entries, and set `max_accounts_per_issue` high enough to cover the worst-case robot-file count for one issue.
4. Re-run the scheduled tick.

`config/ui_accounts.env` is kept only as a legacy placeholder. The dispatcher no longer reads it.
