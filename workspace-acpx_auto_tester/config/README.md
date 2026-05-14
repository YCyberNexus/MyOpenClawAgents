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

Pins the UI test account all subagents share to log into the system under test. The test team has confirmed the system under test does NOT log out the older session on duplicate login, so a single account is sufficient regardless of `max_concurrent_subagents`.

### Format

Only the first valid entry is used. One account per line, `username:password`. Lines starting with `#` and blank lines are ignored. Example:

```
F100001:123456
```

### Sizing rule

A single account is sufficient. `scripts/load_ui_accounts.sh` reads the first valid entry and ignores the rest.

### How it flows through the agent

1. Dispatcher reads `<workspace>/config/ui_accounts.env` via `scripts/load_ui_accounts.sh` (no `BATCH_SIZE` or `ACCOUNTS_PER_ISSUE` needed).
2. The same account (`UI_ACCOUNT` / `UI_PASSWORD`) is passed to every IID's `scripts/build_prompt.sh` invocation.
3. `build_prompt.sh` appends the credentials to the `# Working environment` section of the Claude Code prompt at `${LOG_DIR}/prompt.txt`. The credentials are NOT injected into the rendered subagent prompt — they live in the Claude Code prompt only, where Claude Code reads them.

### Setup

1. Create the account on the system under test (e.g. `F100001`).
2. Edit `ui_accounts.env` with the credentials.
3. Make sure there is at least one valid non-comment account line.
4. Re-run the scheduled tick.
