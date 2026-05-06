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
   - launches one prepared-worker child subagent per issue and records the runtime launch acknowledgement

2. `gitlab_single_issue_executor`
   - prepared single-issue worker
   - runs only inside a runtime-created child subagent after the dispatcher has prepared the environment
   - must handle exactly one issue and then return compact JSON for the runtime callback
   - must not clone, pull, create directories, prepare worktrees, copy `.claude`, or build prompts
   - receives `RUN_PREPARED_ISSUE_WORKER` plus a handoff and directly executes the prepared prompt, publishes evidence, pushes, and opens/rotates the MR

Role selection is trigger-driven:

- `RUN_SCHEDULED_ISSUE_CAMPAIGN` means this session is the dispatcher and may use `sessions_spawn`.
- `RUN_PREPARED_ISSUE_WORKER` means this session is already the prepared worker. It MUST NOT call `sessions_spawn`, `sessions_history`, or any dispatcher skill. It runs only the prepared command from `${LOG_DIR}/subagent_task.md` / `scripts/run_prepared_worker.sh` and returns compact JSON.
- `RUN_CHILD_COMPLETION_CALLBACK` means the OpenClaw runtime is waking the dispatcher with a completed child result. The dispatcher reconciles, re-reads the issue state, updates campaign state, drains the matching active slot, and returns compact JSON. It MUST NOT rerun prepared-worker logic inline.

## Required Capabilities and Concurrency Limit

Capability list and the per-tick concurrency contract are defined canonically in [`SOUL.md`](SOUL.md) §Tooling Expectations and §Subagent Concurrency Policy. This file does not restate them.

### Enforcement layers (deployment-side)

The Subagent Concurrency Policy in SOUL.md is prompt-level — the model can still violate it. Enforcement of the per-tick concurrency cap must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **Asynchronous child completion callback support (required).**
   This workspace uses an async callback strategy: `sessions_spawn` may launch an anonymous child subagent and return a launch acknowledgement (`accepted`, `runId`, `childSessionKey`, thread id, or anonymous `agent:<name>:subagent:<uuid>`). That acknowledgement only means launched, not completed. The OpenClaw runtime MUST later wake `agent:acpx_auto_tester:main` with `RUN_CHILD_COMPLETION_CALLBACK` carrying the child key, `issue_iid`, `attempt_number`, and the prepared worker's terminal compact reply (`done`, `blocked`, `failed`, or `no_changes`). If the runtime cannot deliver parent callbacks, the deployment is incompatible with this strategy.

2. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). The value SHOULD match the integer the dispatcher receives in the trigger so the platform layer mirrors the prompt-layer contract. If the deployment uses a fixed value, set it to the maximum `max_concurrent_subagents` operators expect to send via trigger; the dispatcher's smaller per-tick value then becomes the binding constraint.

3. **Per-IID active-state uniqueness (always-on, structural).**
   Anonymous child keys do not provide per-IID uniqueness. The dispatcher MUST enforce same-IID serialism with GitLab preflight/claims plus `campaign_state.json.active_issue_iids`. A callback for an IID/attempt that is no longer active is idempotent: reconcile GitLab, ignore the stale child result for scheduling, and do not launch a duplicate attempt.
   An `active_issue_sessions` value that is still the logical key `issue-<project>-<iid>` is only a pending-launch placeholder. It does not prove a child exists and must not cause the dispatcher to wait for callbacks.

4. **SOUL.md prompt rules.** The weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) and (2) are available and configured before relying on (4) alone. The previously documented blocking dedicated-session strategy and `spawn_slot.json` fallback are no longer applicable in this async-callback model.

### Spawn Error Handling

Any `sessions_spawn` response with `status="error"` is terminal for that launch attempt. In particular, `errorCode="spawn_failed"`, gateway timeout text, or backend-unavailable text MUST NOT be retried in a loop. The dispatcher records the affected IID as blocked with the raw spawn error and moves on or ends the tick according to quota policy. A successful launch acknowledgement with `accepted` plus `childSessionKey` / `runId` is NOT terminal completion; it is recorded as an active child and must be completed by `RUN_CHILD_COMPLETION_CALLBACK`.

## Child Identity

Anonymous child keys such as `agent:acpx_auto_tester:subagent:<uuid>` are allowed. The dispatcher still uses a logical issue key `issue-<project>-<iid>` in disk state and logs for human correlation, but it does not require the runtime child session to use that name. Detailed child policy lives in [`SOUL.md`](SOUL.md) §Child Subagent Policy.

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
