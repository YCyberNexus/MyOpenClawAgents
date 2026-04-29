# UiAutoTester Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry.

The repo follows a **two-branch model**: a clean baseline branch (typically `dev`, passed as `dev_branch=`) from which fresh worktrees are checked out, and an integration branch (typically `master`, passed as `branch=`) that accumulates spec output via merge requests. Each issue's spec output is required to live under `hulat-spec-issue<iid>/` at the worktree root, so MRs into `master` never collide on file paths.

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

- Maximum active issue subagents: **`max_concurrent_subagents`** (trigger input, integer ≥ 1, default 1).
- Maximum active child sessions for the same `${ISSUE_IID}`: **1**, always — independent of `max_concurrent_subagents`.
- All same-IID work is sequential across attempts; only DIFFERENT IIDs may run in parallel.
- A batch of `sessions_spawn` calls is allowed only when each call targets a distinct IID and the total in-flight count stays ≤ `max_concurrent_subagents`.
- The dispatcher MUST wait for the WHOLE batch to return before forming the next batch (no fire-and-forget, no rolling pool).

### Behavioral commitments (mirror of SOUL.md)

The same constraint, restated as model-facing rules so the two documents do not drift:

This agent MUST NOT:
- exceed `max_concurrent_subagents` active issue subagents at once
- spawn two subagents for the same `${ISSUE_IID}` concurrently
- use fire-and-forget / `--no-wait` / background spawn modes for issue sessions
- start the next batch before the current batch has fully returned
- treat `hourly_issue_quota` as a parallelism / fan-out knob (it is a per-tick completion count)

If `max_concurrent_subagents=1`, the agent MUST behave exactly like the legacy strictly-serial model: pick one IID, spawn one session, wait, record, repeat.

If `max_concurrent_subagents>1`, the agent MUST process issues in bounded batches:
1. Pick up to `max_concurrent_subagents` distinct IIDs.
2. Allocate an attempt number for each (sequential `allocate_attempt.sh` calls — concurrent allocation would race on `attempts_total`).
3. Spawn the batch in a single tool-call block (parallel `sessions_spawn`).
4. Wait for every spawn to return.
5. Re-read each per-issue state file, update backlog / quota / `active_issue_iids`.
6. Only then form the next batch.

### Enforcement

The behavioral commitments above are prompt-level — the model can still violate them. Enforcement of the per-tick concurrency cap must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). The value SHOULD be set to the same integer that the dispatcher receives in the trigger so that the platform layer matches the prompt-layer contract. If the deployment uses a fixed value, it MUST be set to the maximum `max_concurrent_subagents` operators ever expect to send via trigger; the dispatcher's smaller per-tick value then becomes the binding constraint.

2. **Per-IID session-name uniqueness (always-on, structural).**
   Issue sessions are named `issue-<project>-<iid>`. Because the session name is derived from `${ISSUE_IID}`, two concurrent attempts for the same IID would collide on session name and the second `sessions_spawn` would either be deduplicated by OpenClaw or run in the same session (forbidden by Single-Issue Rule). This makes "same IID twice in parallel" structurally impossible without any extra slot file. Cross-IID parallelism is bounded only by (1) and (3).

3. **SOUL.md / AGENTS.md prompt rules.**
   The "Subagent Concurrency Policy (READ FIRST — HARD RULE)" in SOUL.md and the behavioral commitments above. These are the weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) is available and configured before relying on (3) alone. The previously documented `spawn_slot.json` fallback (single-slot file under `${STATE_DIR}`) is no longer applicable in the multi-slot model and has been removed; (2) replaces its same-IID guarantee, and (1) replaces its cross-IID guarantee.

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

## Disk State Layout (SKILL_VERSION 2026-04-25.1+)

```
/data/<project>/                              ← main git repo (host of worktrees)
/data/openclaw_work/<project>/
    openclaw_state/
        campaign_state.json                   ← campaign-level cache
        campaign.lock
    openclaw_log/
        dispatcher/
            reconcile-<ts>.json
    issues/
        issue-<iid>/
            state.json                        ← cross-attempt per-issue state
            attempts/
                attempt-001/
                    worktree/                 ← Claude Code's cwd (git worktree)
                        _hulat → <hulat_dir>  (symlink, .git/info/exclude'd)
                        .claude/              (copy of <hulat_dir>/ifp-hulat/.claude, .git/info/exclude'd)
                    log/
                    attempt_state.json
                    summary.md
                attempt-002/
                    ...
```

The previous flat layout (`/data/<project>/openclaw_state/issues/issue-<iid>.json`, `/data/<project>/openclaw_log/issue-<iid>/`) is gone. All per-issue artifacts now live under `/data/openclaw_work/<project>/issues/issue-<iid>/` and are isolated **per attempt**: every retry creates a new `attempt-NNN/` directory with its own worktree, log, state, and summary.

`hulat_dir` is shared across all issues / attempts via a symlink and remains read-only. The only copied Hulat material is Claude Code runtime config: each attempt copies `<hulat_dir>/ifp-hulat/.claude` to its worktree root as local-only `.claude/`, excluded from git and never pushed.
