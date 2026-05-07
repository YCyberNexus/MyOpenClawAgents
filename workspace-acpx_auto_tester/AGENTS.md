# acpx_auto_tester Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry, executed as **one thick orchestrator session + one dedicated subagent session per issue**, structured as **6 phases per scheduled tick** (see [`skills/gitlab_issue_campaign_dispatcher/SKILL.md`](skills/gitlab_issue_campaign_dispatcher/SKILL.md) §Dispatcher Algorithm). There is exactly ONE skill in this workspace (the orchestrator); the subagent never loads a skill — it receives a fully-rendered self-contained fixed-format prompt as its `sessions_spawn` payload and returns one compact JSON line.

The repo follows a **two-branch model**: a clean baseline branch (typically `dev`, passed as `dev_branch=`) from which fresh worktrees are checked out, and an integration branch (typically `master`, passed as `branch=`) that accumulates spec output via merge requests. Each issue's spec output is required to live under `hulat-spec-issue<iid>/` at the worktree root, so MRs into `master` never collide on file paths.

## Agent Identity

- Agent name: `acpx_auto_tester`
- Orchestrator session: `agent:acpx_auto_tester:main`

## Execution Model (six phases per tick)

This workspace has exactly one skill: `skills/gitlab_issue_campaign_dispatcher/`.

| Phase | Owner        | What |
| ----- | ------------ | ---- |
| 1 Parse        | orchestrator | bootstrap, flock, load + override `campaign_state.json` |
| 2 Reconcile    | orchestrator | mandatory `reconcile.sh` against GitLab; correct disk cache from evidence file |
| 3 Eligibility  | orchestrator | tick-level prep (clone/pull, ensure_labels), form bounded batch under `max_concurrent_subagents` / quota / time budget |
| 4 Per-IID Prep | orchestrator | allocate_attempt → load_ui_accounts → prepare_attempt → build_prompt → label `doing` → init `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}` (in_progress) → render fixed-format prompt |
| 5 Concurrent Spawn | orchestrator | single parallel `sessions_spawn` block; one subagent per IID; synchronous wait for terminal compact JSON reply |
| 6 Follow-up    | orchestrator | parse + validate compact reply → write **terminal** `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` → drain `active_issue_iids` → classify into `completed_iids` / `blocked_iids` / `failed_iids` (promote `blocked → failed` if retry exhausted) → optional notify_channel → loop to Phase 4 if quota and time budget remain |

The subagent (one dedicated session per IID, name `issue-<project>-<iid>`) receives the rendered fixed-format prompt and runs only the technical workflow (Steps 0–9 in the prompt's `<instructions>` block):

- Step 1: one-shot `acpx --auth-policy skip claude exec -f ${LOG_DIR}/prompt.txt` from inside `${WORKTREE_DIR}`
- Step 2: `stage_and_guard.sh` (leak guard for the worktree)
- Step 3: `commit_and_push.sh` (Strategy A — force-push the per-attempt local branch to the single fixed `${WORK_BRANCH}`)
- Step 4: `post_push_verify.sh` (leak guard for the remote branch)
- Step 5: `upload_attempt_artifacts.sh` (publish prompt/result/optional report.html to project Wiki and link from issue)
- Step 6: `set_issue_label.sh` to transition `doing → done`
- Step 7: `create_mr.sh` (mode-dependent rotation: fresh = reuse single MR; continue = close prior open MRs and create a fresh one referencing them)
- Step 7b: `set_issue_label.sh add pr` after MR creation succeeds
- Step 8: `summarize_attempt.sh` posts a per-attempt summary back to the issue
- Step 9: emit ONE compact JSON line per [`references/state_schema.md`](skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) §Compact Subagent Reply, then stop

The subagent invokes scripts at `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts/<name>.sh` by absolute path (the orchestrator renders `{SCRIPTS_DIR}` into the prompt). **The subagent NEVER loads this SKILL, NEVER reads SOUL.md / AGENTS.md, NEVER calls sessions_spawn / sessions_history, NEVER writes any state file.** All terminal state-file writes are owned by the orchestrator's Phase 6, fed by the compact JSON reply.

## Required Capabilities and Concurrency Limit

Capability list and the per-tick concurrency contract are defined canonically in [`SOUL.md`](SOUL.md) §Tooling Expectations and §Subagent Concurrency Policy. This file does not restate them.

### Enforcement layers (deployment-side)

The Subagent Concurrency Policy in SOUL.md is prompt-level — the model can still violate it. Enforcement of the per-tick concurrency cap must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **Blocking dedicated-session spawn support (required).**
   This workspace uses the synchronous batch strategy: every `sessions_spawn` must block until the subagent returns a terminal compact JSON reply (per [`skills/gitlab_issue_campaign_dispatcher/references/state_schema.md`](skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) §Compact Subagent Reply). A runtime response containing only `accepted`, `runId`, `childSessionKey`, a thread id, a session id, or an anonymous `agent:<name>:subagent:<uuid>` key is only a launch acknowledgement and does not satisfy the contract. If the active OpenClaw channel cannot wait for child sessions, the deployment is incompatible with this strategy; the orchestrator must fail the affected work instead of switching to `mode=run` or any other push-based fallback.

2. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). The value SHOULD match the integer the orchestrator receives in the trigger so the platform layer mirrors the prompt-layer contract. If the deployment uses a fixed value, set it to the maximum `max_concurrent_subagents` operators expect to send via trigger; the orchestrator's smaller per-tick value then becomes the binding constraint.

3. **Per-IID session-name uniqueness (always-on, structural).**
   Issue sessions are named `issue-<project>-<iid>`. Two concurrent attempts for the same IID would collide on session name; the second blocking dedicated-session `sessions_spawn` is either deduplicated by OpenClaw or runs in the same session (forbidden by the One-Subagent-Per-IID Rule). This guarantee does not apply to push-based anonymous subagent keys. Cross-IID parallelism is bounded only by (2) and (4).

4. **SOUL.md prompt rules.** The weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) and (2) are available and configured before relying on (4) alone.

## Session Naming

Dedicated issue session pattern: `issue-<project>-<iid>` (e.g. `issue-px_ifp_hulat-1`). Detailed session policy lives in [`SOUL.md`](SOUL.md) §Session Policy.

## Deployment Pin: GitLab Host

The agent's GitLab host is pinned at `<workspace>/config/gitlab.env`. Required fields:

- `GITLAB_HOST` — value passed to `glab --hostname`. Examples: `gitlab.com`, `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

Behavioral rules (verification against trigger, token rotation, abort-on-mismatch) live in [`SOUL.md`](SOUL.md) §GitLab Host Pinning. Setup steps and rationale are in [`config/README.md`](config/README.md).

## Disk State Layout

Full tree, variable table, and hard rules live in [`skills/gitlab_issue_campaign_dispatcher/references/paths.md`](skills/gitlab_issue_campaign_dispatcher/references/paths.md). Workspace-level invariants:

- `/data/${PROJECT}/` — main git repo (hosts worktrees; agent never edits its working tree directly).
- `/data/openclaw_work/${PROJECT}/` — all agent-owned files (campaign state, logs, per-issue worktrees, summaries). **Outside the repo** so `git add` cannot sweep agent artifacts into a commit.
- Per-issue subtree: `${WORK_ROOT}/issues/issue-<iid>/` (state.json, attempt_state.json, worktree/, log/attempt-NNN/, summary.md). Every retry replaces `worktree/` and writes a new `log/attempt-NNN/`; historical attempt logs are preserved.
- `hulat_dir` is shared, read-only, single source. Each attempt symlinks it as `hulat` inside the worktree and copies `${HULAT_DIR}/ifp-hulat/.claude` to `${WORKTREE_DIR}/.claude` for Claude Code's local runtime config. Both are git-excluded and rejected by leak guards.

Claude Code invocation contract and Wiki-evidence publication contract live in [`skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`](skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) and in the SKILL's §Dispatcher Algorithm.
