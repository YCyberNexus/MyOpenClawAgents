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

## Required Capabilities and Concurrency Limit

Capability list and the per-tick concurrency contract are defined canonically in [`SOUL.md`](SOUL.md) §Tooling Expectations and §Subagent Concurrency Policy. This file does not restate them.

### Enforcement layers (deployment-side)

The Subagent Concurrency Policy in SOUL.md is prompt-level — the model can still violate it. Enforcement of the per-tick concurrency cap must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). The value SHOULD match the integer the dispatcher receives in the trigger so the platform layer mirrors the prompt-layer contract. If the deployment uses a fixed value, set it to the maximum `max_concurrent_subagents` operators expect to send via trigger; the dispatcher's smaller per-tick value then becomes the binding constraint.

2. **Per-IID session-name uniqueness (always-on, structural).**
   Issue sessions are named `issue-<project>-<iid>`. Two concurrent attempts for the same IID would collide on session name; the second `sessions_spawn` is either deduplicated by OpenClaw or runs in the same session (forbidden by the Single-Issue Rule). This makes "same IID twice in parallel" structurally impossible without any extra slot file. Cross-IID parallelism is bounded only by (1) and (3).

3. **SOUL.md prompt rules.** The weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) is available and configured before relying on (3) alone. The previously documented `spawn_slot.json` fallback is no longer applicable in the multi-slot model.

## Session Naming

Dedicated issue session pattern: `issue-<project>-<iid>` (e.g. `issue-px_ifp_hulat-1`). Detailed session policy lives in [`SOUL.md`](SOUL.md) §Session Policy.

## Deployment Pin: GitLab Host

The agent's GitLab host is pinned at `<workspace>/config/gitlab.env`. Required fields:

- `GITLAB_HOST` — value passed to `glab --hostname`. Examples: `gitlab.com`, `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

Behavioral rules (verification against trigger, token rotation, abort-on-mismatch) live in [`SOUL.md`](SOUL.md) §GitLab Host Pinning. Setup steps and rationale are in [`config/README.md`](config/README.md).

## Disk State Layout

Full tree, variable table, and hard rules live in [`skills/gitlab_single_issue_executor/references/paths.md`](skills/gitlab_single_issue_executor/references/paths.md). Workspace-level invariants:

- `/data/${PROJECT}/` — main git repo (hosts worktrees; agent never edits its working tree directly).
- `/data/openclaw_work/${PROJECT}/` — all agent-owned files (campaign state, logs, per-issue worktrees, summaries). **Outside the repo** so `git add` cannot sweep agent artifacts into a commit.
- Per-issue subtree: `${WORK_ROOT}/issues/issue-<iid>/` (state.json, worktree/, log/attempt-NNN/, attempt_state.json, summary.md). Every retry replaces `worktree/` and writes a new `log/attempt-NNN/`; historical attempt logs are preserved.
- `hulat_dir` is shared, read-only, single source. Each attempt symlinks it as `_hulat` inside the worktree and copies `${HULAT_DIR}/ifp-hulat/.claude` to `${WORKTREE_DIR}/.claude` for Claude Code's local runtime config. Both are git-excluded and rejected by leak guards.

Claude Code invocation contract and Wiki-evidence publication contract live in the executor SKILL ([`skills/gitlab_single_issue_executor/SKILL.md`](skills/gitlab_single_issue_executor/SKILL.md) §Claude Code Execution Contract and Step 12 of the algorithm).
