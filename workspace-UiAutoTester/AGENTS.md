# UiAutoTester Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry.

## Agent Identity

- Agent name: `UiAutoTester`
- Dispatcher session: `agent:UiAutoTester:main`

## Execution Model

This workspace is intentionally split into two skills:

1. `gitlab_issue_campaign_dispatcher`
   - lightweight scheduler-facing dispatcher
   - reads and updates campaign state
   - manages per-tick quota
   - handles backlog carryover
   - skips blocked issues temporarily and retries them later
   - creates or resumes one dedicated session per issue

2. `gitlab_single_issue_executor`
   - heavy single-issue executor
   - runs only inside a dedicated issue session
   - must never be reused for another issue

## Required Capabilities

The agent configuration should allow:
- `read`
- `write`
- `edit`
- `exec`
- `sessions_history`
- `sessions_spawn`

## Runtime Limit

Hard limits this agent's runtime configuration must enforce:

- Maximum active subagents: **1**
- Maximum active child sessions: **1**
- All subagent execution must be sequential.
- The agent may use `sessions_spawn` only after the previous child session has completed.
- Parallel subagent execution is forbidden.

### Behavioral commitments (mirror of SOUL.md)

The same constraint, restated as model-facing rules so the two documents do not drift:

This agent MUST NOT:
- start multiple subagents in parallel
- use fan-out execution
- use worker pools
- spawn multiple child sessions in one step
- process multiple issues concurrently
- call `sessions_spawn` for more than one child session at a time

If there are multiple tasks, issues, or test jobs, this agent MUST process them strictly one by one:
1. Start exactly one subagent.
2. Wait for the result.
3. Record the result.
4. Only then start the next subagent.

### Enforcement

The behavioral commitments above are prompt-level — the model can still violate them. Enforcement of "max 1 subagent" must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should refuse a second concurrent `sessions_spawn` from the same parent session for this agent. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`, or a per-capability `serialize: true` modifier on `sessions_spawn`). Once known, the value MUST be set to `1` for `agent:UiAutoTester:main`.

2. **Workspace-level spawn-slot fallback (if platform knob is unavailable or not yet configured).**
   The dispatcher writes a `spawn_slot.json` under `${STATE_DIR}` before each `sessions_spawn` and clears it only after the spawned session returns. The executor verifies on entry that the slot's `active_iid` matches its own `${ISSUE_IID}`; if not, it refuses to run and returns `status=blocked` with `block_reason="spawn slot held by IID <X>"`. This makes a violation deterministically observable and inert — the second/third executor still launches but does no work.

3. **SOUL.md / AGENTS.md prompt rules.**
   The "Subagent Concurrency Policy (READ FIRST — HARD RULE)" in SOUL.md and the behavioral commitments above. These are the weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer which of (1) is available before relying on (3) alone.

## Session Naming Recommendation

Dedicated issue session pattern:
- `issue-<project>-<iid>`

Examples:
- `issue-px_ifp_hulat-1`
- `issue-px_ifp_hulat-2`

## Deployment Pin: GitLab Host

The GitLab host this agent talks to is pinned at deployment time, NOT derived from trigger inputs on every tick. The pin lives at:

```
<workspace>/config/gitlab.env
```

Required fields:

- `GITLAB_HOST` — value passed to `glab --hostname`. Examples: `gitlab.com`, `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

The trigger's `gitlab_address` is verified against this pin on every tick. A mismatch is treated as a hard error (the affected operation is blocked / the tick aborts) — the agent will NEVER silently switch hosts. The trigger's `gitlab_token` is forwarded to `glab auth login` against the pinned host on every tick, so token rotation continues to work.

See `<workspace>/config/README.md` for setup steps and rationale.

## Disk State Layout

- campaign state:
  - `/data/<project>/openclaw_state/campaign_state.json`
- issue state:
  - `/data/<project>/openclaw_state/issues/issue-<iid>.json`
- logs:
  - `/data/<project>/openclaw_log/issue-<iid>/`
