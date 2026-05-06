# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are NOT generated from trigger inputs and they are NOT touched by the agent at runtime.

## `gitlab.env`

Pins the GitLab host the agent talks to. Required fields:

- `GITLAB_HOST` — value passed to `glab --hostname`. Example: `gitlab-b.pxsemic.tech:30000`.
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

Pins the pool of UI test accounts the dispatcher draws from when allocating credentials to concurrent subagents.

The system under test logs out an account when the same credentials log in twice. With `max_concurrent_subagents > 1` the dispatcher MUST hand each concurrent subagent a distinct account, otherwise two subagents racing on the same account will continuously kick each other out.

### Format

One account per line, `username:password`. Lines starting with `#` and blank lines are ignored. Example:

```
F100001:123456
F100002:123456
F100003:123456
F100004:123456
```

### Sizing rule

The pool size MUST be `>= max_concurrent_subagents` for the deployment. The dispatcher checks this every tick: if the next batch's size exceeds the pool size, the tick is aborted (No-Fallback Policy — the dispatcher will never share an account between two in-flight subagents).

### How it flows through the agent

1. Dispatcher sources `<workspace>/config/ui_accounts.env` via `scripts/load_ui_accounts.sh` at the top of every batch.
2. Dispatcher allocates one account per IID in the batch (first N entries from the pool, in file order) and passes them through the executor trigger as `ui_account=<user>` and `ui_password=<pass>`.
3. Executor forwards the values into `scripts/build_prompt.sh`, which appends them to the `# Working environment` section of the Claude Code prompt with an explicit override note: any account named in the issue body should be replaced by the allocated one.
4. After the batch returns the accounts implicitly return to the pool — the dispatcher does not persist allocations; the next batch re-allocates from the head of the file. Per-batch waiting (the existing concurrency contract) is what makes this safe.

### Setup

1. Create the accounts on the system under test (e.g. `F100001`–`F100004`).
2. Edit `ui_accounts.env` with the credentials.
3. Make sure the line count is `>= max_concurrent_subagents` set in your trigger.
4. Re-run the scheduled tick.
