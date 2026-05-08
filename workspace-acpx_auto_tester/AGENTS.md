# acpx_auto_tester Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry, executed as **one thick orchestrator session + one anonymous subagent run per IID**, in an **async-callback model** (see [`skills/gitlab_issue_campaign_dispatcher/SKILL.md`](skills/gitlab_issue_campaign_dispatcher/SKILL.md) §Dispatcher Algorithm). There is exactly ONE skill in this workspace (the orchestrator); the subagent never loads a skill — it receives a fully-rendered self-contained fixed-format prompt as its `sessions_spawn` payload and emits one compact JSON line on its last turn. The runtime captures that line and forwards it to the orchestrator inside `RUN_CHILD_COMPLETION_CALLBACK`.

The repo follows a **two-branch model**: a clean baseline branch (typically `dev`, passed as `dev_branch=`) from which fresh worktrees are checked out, and an integration branch (typically `master`, passed as `branch=`) that accumulates spec output via merge requests. Each issue's spec output is required to live under `hulat-spec-issue<iid>/` at the worktree root, so MRs into `master` never collide on file paths.

## Agent Identity

- Agent name: `acpx_auto_tester`
- Orchestrator session: `agent:acpx_auto_tester:main`

## Execution Model (async-callback, two execution paths)

This workspace has exactly one skill: `skills/gitlab_issue_campaign_dispatcher/`.

The orchestrator handles two trigger commands and runs different phases on each:

### Path A: scheduled wake-up (`RUN_SCHEDULED_ISSUE_CAMPAIGN`)

| Phase | What |
| ----- | ---- |
| 1 Parse        | bootstrap, flock, load + override `campaign_state.json`. Stuck-pending eviction (synthesizes Phase 6 blocked replies for any pending entries past `stuck_after_minutes`). |
| 2 Reconcile    | mandatory `reconcile.sh` against GitLab; correct disk cache from evidence file. |
| 3 Eligibility  | If `pending_subagents` is still non-empty after eviction → return `waiting_for_callbacks` and exit. Otherwise: tick-level prep (clone/pull, ensure_labels), form bounded batch under `min(max_concurrent_subagents, hourly_issue_quota, eligible_iids)`. |
| 4 Per-IID Prep | allocate_attempt → load_ui_accounts → prepare_attempt → build_prompt → label `doing` → init `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}` (in_progress) → write `pending_subagents[iid]` placeholder → render fixed-format prompt. |
| 5 Async Spawn  | single parallel **anonymous** `sessions_spawn` tool-call block (NO session name passed); record each launch ack's `runId` + `childSessionKey` into `pending_subagents[iid]`; persist; return `waiting_for_callbacks`. **Phase 6 does NOT run on this path** (except inline-synthesized blocked for launch failures). |

### Path B: callback wake-up (`RUN_CHILD_COMPLETION_CALLBACK`)

The runtime delivers ONE callback per subagent termination. Each callback wakes the same orchestrator session with the subagent's terminal compact JSON in `worker_result_json`.

| Phase | What |
| ----- | ---- |
| 1 Parse     | bootstrap, flock, load `campaign_state.json` (no trigger override on callback path). |
| 2 Reconcile | narrow reconcile against GitLab (single-IID range when feasible). |
| 6 Follow-up | parse + validate the callback's compact JSON → match to `pending_subagents[reply.iid]` (Phase 6 validation rule 2; reply.attempt_number must equal pending entry's) → write **terminal** `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}` → drain pending entry → classify into `completed_iids` / `blocked_iids` / `failed_iids` (promote `blocked → failed` if retry exhausted) → optional notify_channel → return. The callback path does NOT spawn a replacement subagent — the next scheduled wake-up forms the next batch. |

### Subagent

The subagent (one anonymous run per IID per spawn) receives the rendered fixed-format prompt and runs only the technical workflow (Steps 0–9 in the prompt's `<instructions>` block):

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

1. **`RUN_CHILD_COMPLETION_CALLBACK` delivery (required).**
   This workspace uses the async-callback strategy: `sessions_spawn` returns a launch ack (`runId` + `childSessionKey`) within seconds, and the runtime later wakes the orchestrator with `RUN_CHILD_COMPLETION_CALLBACK` carrying the subagent's terminal compact JSON in `worker_result_json` (per [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md) §Callback trigger and [`references/state_schema.md`](skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) §Compact Subagent Reply). If the deployment cannot deliver `RUN_CHILD_COMPLETION_CALLBACK`, the orchestrator records that as a tick-level deployment incompatibility and aborts. Stuck-pending eviction (`stuck_after_minutes`, default 90) is a backstop, not a substitute.

   **Spawns MUST be anonymous (no session name passed).** Earlier deployments tripped `errorCode=thread_required` on channels (e.g. webchat) when the orchestrator passed `mode="session"` with a deterministic name. The orchestrator matches each callback's compact JSON back to its dispatched IID by parsing the `iid` field (Phase 6 validation rule 2), not by runtime session-key label.

2. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). The value SHOULD match the integer the orchestrator receives in the trigger so the platform layer mirrors the prompt-layer contract. If the deployment uses a fixed value, set it to the maximum `max_concurrent_subagents` operators expect to send via trigger; the orchestrator's smaller per-tick value then becomes the binding constraint.

3. **`active_issue_iids` + `pending_subagents` bookkeeping (always-on, structural).**
   The orchestrator persists every dispatched IID into `campaign_state.json.active_issue_iids` AND a corresponding `pending_subagents[iid]` entry BEFORE issuing `sessions_spawn` (Phase 4 step 5 placeholder write) and refuses to spawn a subagent for any IID already present. After the matching `RUN_CHILD_COMPLETION_CALLBACK` arrives and Phase 6 writes terminal state files, the IID is drained from both structures. Stuck-pending eviction at the top of the next scheduled wake-up handles entries whose callback never arrives. This combined bookkeeping is the structural "same IID never runs twice" guarantee, and it works with anonymous runtime session keys (which is now the only mode). Callbacks are matched to dispatched IIDs by the `iid` field of the compact JSON (Phase 6 validation), not by runtime session-key labels. Cross-IID parallelism is bounded by (2) and (4); (3) only constrains same-IID.

4. **SOUL.md prompt rules.** The weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) and (2) are available and configured before relying on (4) alone.

## Session Naming

Logical issue subagent name: `issue-<project>-<iid>` (e.g. `issue-px_ifp_hulat-1`). Used for `active_issue_sessions` bookkeeping and human-readable logging only. **The runtime session name is always anonymous** — the orchestrator does not pass any name to `sessions_spawn`. The runtime returns its own auto-generated key (e.g. `agent:acpx_auto_tester:subagent:<uuid>`) which the orchestrator records into `pending_subagents[iid].child_session_key` for audit and stuck-pending detection. Callbacks are matched back to dispatched IIDs by the `iid` field of the compact JSON, not by the runtime session-key label. Detailed session policy lives in [`SOUL.md`](SOUL.md) §Session Policy.

## Deployment Pin: GitLab Host

The agent's GitLab host is pinned at `<workspace>/config/gitlab.env`. Required fields:

- `GITLAB_HOST` — host (with port if non-default) of the pinned GitLab instance. Exported by `scripts/glab_auth.sh`; `glab` reads it natively from the env var. Examples: `gitlab.com`, `gitlab-b.pxsemic.tech:30000`. **Do NOT pass `--hostname` to `glab api` / `glab mr` / `glab issue`** — only `glab auth login` / `glab auth status` inside `scripts/glab_auth.sh` accept `--hostname`, and even there `glab` rejects `host:port` values for some subcommands. See [`SOUL.md`](SOUL.md) §GitLab Access.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

Behavioral rules (verification against trigger, token rotation, abort-on-mismatch) live in [`SOUL.md`](SOUL.md) §GitLab Host Pinning. Setup steps and rationale are in [`config/README.md`](config/README.md).

## Disk State Layout

Full tree, variable table, and hard rules live in [`skills/gitlab_issue_campaign_dispatcher/references/paths.md`](skills/gitlab_issue_campaign_dispatcher/references/paths.md). Workspace-level invariants:

- `/data/${PROJECT}/` — the cloned project repo (hosts linked worktrees; agent never edits its main working tree directly). The test team commits `.claude/`, `hulat/`, and `ifp-data/` to master+dev so a fresh clone already contains everything Claude Code needs at runtime.
- `/data/${PROJECT}/ifp-result/` — agent runtime workspace, INSIDE the cloned repo. Gitignored on master+dev so the main worktree's `git status` stays clean. Holds:
  - `_dispatcher/` — campaign-level state (`campaign_state.json`, `campaign.lock`), dispatcher logs (`log/reconcile-<ts>.json`), and locks (`locks/repo.lock`).
  - `issue-<iid>/` — per-issue subtree (`state.json`, `attempt_state.json`, `worktree/` linked git worktree, `log/attempt-NNN/`, `summary.md`). Every retry replaces `worktree/` and writes a new `log/attempt-NNN/`; historical attempt logs are preserved.
- `hulat/`, `.claude/`, `ifp-data/` are READ-ONLY references inside every worktree (committed by the test team). The agent does NOT symlink `hulat/` and does NOT copy `.claude/` any more — both are simply present in the worktree's branch checkout. Leak guards no longer special-case these directories.
- The `hulat_dir` trigger field is no longer used. The dispatcher derives `HULAT_DIR=${REPO_PATH}/hulat`. Old triggers that still pass `hulat_dir=...` are silently accepted (the override never reaches a script).

Claude Code invocation contract and Wiki-evidence publication contract live in [`skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`](skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) and in the SKILL's §Dispatcher Algorithm.
