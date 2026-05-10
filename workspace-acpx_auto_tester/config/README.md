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

The system under test logs out an account when the same credentials log in twice. This repo-root execution model is serial (`max_concurrent_subagents=1`), but the dispatcher still allocates one account per spawned IID from this pool.

### Format

One account per line, `username:password`. Lines starting with `#` and blank lines are ignored. Example:

```
F100001:123456
F100002:123456
F100003:123456
F100004:123456
```

### Sizing rule

The pool must contain at least one valid account. The dispatcher checks this every tick; if it cannot allocate an account for the serial batch, the tick is aborted.

### How it flows through the agent

1. Dispatcher sources `<workspace>/config/ui_accounts.env` via `scripts/load_ui_accounts.sh` at the top of every batch.
2. Dispatcher allocates one account for the serial IID batch (the first entry from the pool, in file order).
3. For each IID, the dispatcher invokes `scripts/build_prompt.sh` with `UI_ACCOUNT=<user>` `UI_PASSWORD=<pass>` in env. The script appends them to the `# Working environment` section of the Claude Code prompt at `${LOG_DIR}/prompt.txt` with an explicit override note: any account named in the issue body should be replaced by the allocated one. The credentials are NOT injected into the rendered subagent prompt — they live in the Claude Code prompt only, where Claude Code reads them.
4. After the callback drains the pending subagent, the account implicitly returns to the pool — the dispatcher does not persist allocations; the next batch re-allocates from the head of the file. A push-based `accepted` / `runId` acknowledgement is not terminal completion and must not release the pending entry.

### Setup

1. Create the accounts on the system under test (e.g. `F100001`–`F100004`).
2. Edit `ui_accounts.env` with the credentials.
3. Make sure there is at least one valid non-comment account line.
4. Re-run the scheduled tick.
