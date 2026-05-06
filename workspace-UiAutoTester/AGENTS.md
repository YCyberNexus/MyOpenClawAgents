# acpx_auto_tester Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry.

The repo follows a **two-branch model**: a clean baseline branch (typically `dev`, passed as `dev_branch=`) from which fresh worktrees are checked out, and an integration branch (typically `master`, passed as `branch=`) that accumulates spec output via merge requests. Each issue's spec output is required to live under `hulat-spec-issue<iid>/` at the worktree root, so MRs into `master` never collide on file paths.

## Agent Identity

- Agent name: `acpx_auto_tester`
- Dispatcher session: `agent:acpx_auto_tester:main`

## Execution Model

This workspace is intentionally split into two skills:

1. `gitlab_issue_campaign_dispatcher`
   - scheduler-facing main agent
   - reads and updates campaign state
   - manages per-tick quota
   - handles backlog carryover
   - skips blocked issues temporarily and retries them later
   - performs GitLab repo sync, preflight/claim checks, issue directory creation, worktree preparation, `hulat` symlink setup, `.claude` copy, prompt generation, and handoff manifest creation
   - creates or resumes one dedicated prepared-worker session per issue

2. `gitlab_single_issue_executor`
   - prepared single-issue worker
   - runs only inside a dedicated issue session after the dispatcher has prepared the environment
   - must never be reused for another issue
   - must not clone, pull, create directories, prepare worktrees, copy `.claude`, or build prompts
   - receives `RUN_PREPARED_ISSUE_WORKER` plus a handoff and directly executes the prepared prompt, publishes evidence, pushes, and opens/rotates the MR

## Required Capabilities and Concurrency Limit

Capability list and the per-tick concurrency contract are defined canonically in [`SOUL.md`](SOUL.md) §Tooling Expectations and §Subagent Concurrency Policy. This file does not restate them.

### Enforcement layers (deployment-side)

The Subagent Concurrency Policy in SOUL.md is prompt-level — the model can still violate it. Enforcement of the per-tick concurrency cap must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **Blocking dedicated-session spawn support (required).**
   This workspace uses the e712962c synchronous batch strategy: every `sessions_spawn` must block until the prepared worker returns a terminal compact reply. A runtime response containing only `accepted`, `runId`, `childSessionKey`, a thread id, a session id, or an anonymous `agent:<name>:subagent:<uuid>` key is only a launch acknowledgement and does not satisfy the contract. If the active OpenClaw channel cannot wait for child sessions, the deployment is incompatible with this strategy; the dispatcher must fail the affected work instead of switching to `mode=run` or any other push-based fallback.

2. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). The value SHOULD match the integer the dispatcher receives in the trigger so the platform layer mirrors the prompt-layer contract. If the deployment uses a fixed value, set it to the maximum `max_concurrent_subagents` operators expect to send via trigger; the dispatcher's smaller per-tick value then becomes the binding constraint.

3. **Per-IID session-name uniqueness (always-on, structural).**
   Issue sessions are named `issue-<project>-<iid>`. Two concurrent attempts for the same IID would collide on session name; the second blocking dedicated-session `sessions_spawn` is either deduplicated by OpenClaw or runs in the same session (forbidden by the Single-Issue Rule). This guarantee does not apply to push-based anonymous subagent keys. Cross-IID parallelism is bounded only by (2) and (4).

4. **SOUL.md prompt rules.** The weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) and (2) are available and configured before relying on (4) alone. The previously documented `spawn_slot.json` fallback is no longer applicable in the multi-slot model.

## Session Naming

Dedicated issue session pattern: `issue-<project>-<iid>` (e.g. `issue-px_ifp_hulat-1`). Detailed session policy lives in [`SOUL.md`](SOUL.md) §Session Policy.

## Deployment Pin: GitLab Host

The agent's GitLab host is pinned at `<workspace>/config/gitlab.env`. Required fields:

- `GITLAB_HOST` — value passed to `glab --hostname`. Examples: `gitlab.com`, `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

Behavioral rules (verification against trigger, token rotation, abort-on-mismatch) live in [`SOUL.md`](SOUL.md) §GitLab Host Pinning. Setup steps and rationale are in [`config/README.md`](config/README.md).

## Disk State Layout

Full tree, variable table, and hard rules live in [`skills/gitlab_single_issue_executor/references/paths.md`](skills/gitlab_single_issue_executor/references/paths.md). Workspace-level invariants:

- `/data/${PROJECT}/` — main git repo, cloned/fetched only by the dispatcher/main agent. It hosts worktrees; no agent edits its working tree directly.
- `/data/openclaw_work/${PROJECT}/` — all agent-owned files (campaign state, claims, logs, per-issue worktrees, summaries, handoffs). **Outside the repo** so `git add` cannot sweep agent artifacts into a commit.
- Per-issue subtree: `${WORK_ROOT}/issues/issue-<iid>/` (state.json, worktree/, log/attempt-NNN/, attempt_state.json, summary.md). Every retry replaces `worktree/` and writes a new `log/attempt-NNN/`; historical attempt logs are preserved.
- `handoff.json` at `${ISSUE_ROOT}/handoff.json` records the prepared worker contract for the latest attempt. `${LOG_DIR}/subagent_task.md` is the self-contained worker prompt; it tells the worker not to reload skills or references.
- `hulat_dir` is shared, read-only, single source. The dispatcher symlinks it as `hulat` inside the worktree and copies `${HULAT_DIR}/ifp-hulat/.claude` to `${WORKTREE_DIR}/.claude` for Claude Code's local runtime config. Both are git-excluded and rejected by leak guards.

Prepared worker invocation and Wiki-evidence publication contracts live in the prepared-worker skill ([`skills/gitlab_single_issue_executor/SKILL.md`](skills/gitlab_single_issue_executor/SKILL.md)). Environment preparation lives in the dispatcher skill and scripts.
