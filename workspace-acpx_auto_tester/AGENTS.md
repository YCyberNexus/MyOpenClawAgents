# acpx_auto_tester_test Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry, executed as **one thick orchestrator session + one anonymous subagent run per IID**, in an **async-callback model** (see [`skills/gitlab_issue_campaign_dispatcher/SKILL.md`](skills/gitlab_issue_campaign_dispatcher/SKILL.md) §Dispatcher Algorithm). There is exactly ONE skill in this workspace (the orchestrator); the subagent never loads a skill — it receives a fully-rendered self-contained fixed-format prompt as its `sessions_spawn` payload and emits one compact JSON line on its last turn. The runtime captures that line and forwards it to the orchestrator inside `RUN_CHILD_COMPLETION_CALLBACK`.

The repo follows a **two-branch model**: a clean baseline branch (typically `dev`, passed as `dev_branch=`) from which fresh attempts are checked out, and an integration branch (typically `master`, passed as `branch=`) that accumulates spec output via per-issue immutable attempt branches (no MR on benchmark-test). The parent checkout lives at `${REPO_PATH}` (default `/data/${PROJECT}`; trigger `repo_path` overrides the parent, so `repo_path=/data/ifp1` gives `/data/ifp1/${PROJECT}`); each subagent runs Claude Code from inside the shared per-issue linked git worktree at `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/` rather than the parent itself. One worktree per IID is reused across every attempt of that IID — `prepare_attempt.sh` creates it on attempt 1 and force-switches the checked-out branch in place on attempt N>1; every attempt resets from the clean baseline and quarantines same-IID runtime residue before recreating empty current output/log directories (continue / resume is disabled on benchmark-test). After every base checkout, tracked shared config paths (`.claude/`, `hulat/`, and `${DATA_BASENAME}/`) are refreshed from latest `origin/${DEV_BRANCH}`. Same-IID attempts never run concurrently, so reuse is safe. Cross-IID parallelism is still safe because different IIDs always get different worktree paths. Each issue's spec output is required to live under the worktree-relative path `${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/`, so per-issue output never collides on file paths (each IID writes into a distinct subdirectory).

## Agent Identity

- Agent name: `acpx_auto_tester_test`
- Orchestrator session: `agent:acpx_auto_tester_test:main`

## Execution Model (async-callback, two execution paths)

This workspace has exactly one skill: `skills/gitlab_issue_campaign_dispatcher/`.

The orchestrator handles two trigger commands:

- `RUN_SCHEDULED_ISSUE_CAMPAIGN` (scheduled wake-up) — Phases 1–5: parse + reconcile + per-IID prep + serial anonymous `sessions_spawn`, then returns `waiting_for_callbacks`.
- `RUN_CHILD_COMPLETION_CALLBACK` (callback wake-up) — Phase 6 for ONE IID: validate the subagent's compact JSON reply (in `worker_result_json`), sync live labels, write terminal `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}`, drain `pending_subagents[iid]`, classify into `completed / blocked / failed / timeout_iids`, and best-effort clean up the terminal child runtime session when enabled. The callback path NEVER spawns a replacement subagent.

Full Phase-by-Phase step list with env-var contract per script: [`skills/gitlab_issue_campaign_dispatcher/SKILL.md`](skills/gitlab_issue_campaign_dispatcher/SKILL.md) §Dispatcher Algorithm.

The subagent (one anonymous run per IID per spawn) reads ONLY the rendered fixed-format prompt and runs the Steps in `<instructions>` (acpx → collect metrics → stage → commit/push → post-push verify → wiki → doing→done → summarize → emit compact JSON; benchmark-test has no MR / `pr` — `done` is the terminal success label). It NEVER loads this SKILL, reads SOUL.md/AGENTS.md, calls `sessions_spawn` / `sessions_history`, or writes any state file. The compact JSON line on its last turn is the orchestrator's only signal. Workflow + per-step env-var contract: [`references/executor_prompt.md`](skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) `<instructions>`. Compact JSON schema: [`references/state_schema.md`](skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) §Compact Subagent Reply.

## Required Capabilities and Concurrency Limit

Capability list and the per-tick concurrency contract are defined canonically in [`SOUL.md`](SOUL.md) §Tooling Expectations and §Subagent Concurrency Policy. This file does not restate them.

### Enforcement layers (deployment-side)

The Subagent Concurrency Policy in SOUL.md is prompt-level — the model can still violate it. Enforcement of the per-tick concurrency cap must therefore live below the prompt. Use whichever of the following the deployment can deliver, in priority order:

1. **`RUN_CHILD_COMPLETION_CALLBACK` delivery (required).**
   This workspace uses the async-callback strategy: `sessions_spawn` returns a launch ack (`runId` + `childSessionKey`) within seconds, and the runtime later wakes the orchestrator with `RUN_CHILD_COMPLETION_CALLBACK` carrying the subagent's terminal compact JSON in `worker_result_json` (per [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md) §Callback trigger and [`references/state_schema.md`](skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) §Compact Subagent Reply). Launch ack failures are retried in the same tick with the identical payload up to 3 total attempts before the IID is synthesized as `blocked`; these launch-side failures do not increment `retry_count`. If the deployment cannot deliver `RUN_CHILD_COMPLETION_CALLBACK`, the orchestrator records that as a tick-level deployment incompatibility and aborts. Stuck-pending eviction (`stuck_after_minutes`, defaulting to `ceil(run_timeout_seconds / 60) + 30`) is a backstop, not a substitute.

   **Spawns MUST be anonymous (no session name passed).** Earlier deployments tripped `errorCode=thread_required` on channels (e.g. webchat) when the orchestrator passed `mode="session"` with a deterministic name. The orchestrator matches each callback's compact JSON back to its dispatched IID by parsing the `iid` field (Phase 6 validation rule 2), not by runtime session-key label.

2. **OpenClaw platform-level concurrency knob (preferred).**
   The OpenClaw runtime should cap concurrent `sessions_spawn` from this parent session at `max_concurrent_subagents`. The exact field name depends on the OpenClaw version in use — operators must consult the OpenClaw maintainer to pin down the correct setting (likely candidates: `max_concurrent_subagents`, `max_parallel_sessions`, `spawn_concurrency`). This must mirror the prompt-layer contract; the actual upper bound is constrained by `max_concurrent_subagents ≤ ui_account_pool_size` because the pool is divided into exactly `max_concurrent_subagents` slots and each in-flight subagent must hold its own slot of distinct UI accounts (one per robot file), capped by `max_accounts_per_issue` (default 14). Per-IID slot sizes are derived automatically (see [`skills/gitlab_issue_campaign_dispatcher/SKILL.md`](skills/gitlab_issue_campaign_dispatcher/SKILL.md) §UI Account Allocation Policy).

3. **`active_issue_iids` + `pending_subagents` bookkeeping (always-on, structural).**
   The orchestrator persists every dispatched IID into `campaign_state.json.active_issue_iids` AND a corresponding `pending_subagents[iid]` entry BEFORE issuing `sessions_spawn` (Phase 4 step 5 placeholder write) and refuses to spawn a subagent for any IID already present. After the matching `RUN_CHILD_COMPLETION_CALLBACK` arrives and Phase 6 writes terminal state files, the IID is drained from both structures. Stuck-pending eviction at the top of the next scheduled wake-up handles entries whose callback never arrives. This combined bookkeeping is the structural "same IID never runs twice" guarantee, and it works with anonymous runtime session keys (which is now the only mode). Callbacks are matched to dispatched IIDs by the `iid` field of the compact JSON (Phase 6 validation), not by runtime session-key labels. Cross-IID parallelism IS allowed (each IID runs in its own per-issue worktree); same-IID parallelism is what the bookkeeping prevents — and it is also what makes the shared per-issue worktree safe.

4. **SOUL.md prompt rules.** The weakest layer; they must not be the only layer.

Operators are expected to confirm with the OpenClaw maintainer that (1) and (2) are available and configured before relying on (4) alone.

## Session Naming

Logical issue subagent name: `issue-<project>-<iid>` (e.g. `issue-px_ifp_hulat-1`). Used for `active_issue_sessions` bookkeeping and human-readable logging only. **The runtime session name is always anonymous** — the orchestrator does not pass any name to `sessions_spawn`. The runtime returns its own auto-generated key (e.g. `agent:acpx_auto_tester_test:subagent:<uuid>`) which the orchestrator records into `pending_subagents[iid].child_session_key` for audit and stuck-pending detection. Callbacks are matched back to dispatched IIDs by the `iid` field of the compact JSON, not by the runtime session-key label. Detailed session policy lives in [`SOUL.md`](SOUL.md) §Session Policy.

Separately from session naming, the dispatcher MUST pass `label="#<iid>-att-<NNN>"` on every `sessions_spawn` so the OpenClaw Sessions UI LABEL column shows the IID and attempt number. `label=` is a cosmetic UI field, not a session-name field — it does NOT trigger `thread_required`. Full parameter-name resolution and 3-attempt identical-payload launch retry policy lives in [`skills/gitlab_issue_campaign_dispatcher/SKILL.md`](skills/gitlab_issue_campaign_dispatcher/SKILL.md) §Concurrency Policy "Session label for runtime UI".

## Deployment Pin: GitLab Host

The agent's GitLab host is pinned at `<workspace>/config/gitlab.env`. Required fields:

- `GITLAB_HOST` — host (with port if non-default) of the pinned GitLab instance. Exported by `scripts/glab_auth.sh`; `glab` reads it natively from the env var. Examples: `gitlab.com`, `gitlab-b.pxsemic.tech:30000`. **Do NOT pass `--hostname` to `glab api` / `glab mr` / `glab issue`** — only `glab auth login` / `glab auth status` inside `scripts/glab_auth.sh` accept `--hostname`, and even there `glab` rejects `host:port` values for some subcommands. See [`SOUL.md`](SOUL.md) §GitLab Access.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).

Behavioral rules (verification against trigger, token rotation, abort-on-mismatch) live in [`SOUL.md`](SOUL.md) §GitLab Host Pinning. Setup steps and rationale are in [`config/README.md`](config/README.md).

## Disk State Layout

Full tree, variable table, and hard rules live in [`skills/gitlab_issue_campaign_dispatcher/references/paths.md`](skills/gitlab_issue_campaign_dispatcher/references/paths.md). Workspace-level invariants:

- The cloned project repo IS the agent's workspace. The test team commits `.claude/`, `hulat/`, and `${DATA_BASENAME}/` to master+dev; `prepare_attempt.sh` refreshes those tracked config paths from latest `origin/${DEV_BRANCH}` before every acpx run.
- Agent runtime files live under `${REPO_PATH}/${RESULT_BASENAME}/` (default `ifp-result`): `_dispatcher/` (campaign state + logs + locks), `issues/issue-<iid>/` (per-issue persistent subtree — `state.json` / `attempt_state.json` / `summary.md` — outside every worktree), `.worktrees/issue-<iid>/` (shared per-issue linked git worktree, acpx cwd; reused across every attempt of that IID).
- Each issue's committed spec output is at the worktree-relative path `${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/` so per-issue output never collides on file paths (each IID writes into a distinct subdirectory). The per-attempt log dir lives alongside it at `${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/` (still attempt-scoped inside the shared per-issue worktree so successive attempts do not overwrite each other's evidence): `stage_and_guard.sh` force-adds the ENTIRE `${LOG_DIR}` from there (full benchmark archival: `acpx_raw.log`, `git_diff.patch`, `timing.txt`, `metrics.json`, `prompt.txt`, `claude_result.txt`) so every attempt's evidence lands on its immutable per-attempt branch `issue/<iid>-auto-fix-att<NNN>`.
- `${REPO_PATH}` defaults to `/data/${PROJECT}`; trigger `repo_path` can override the parent. `${RESULT_BASENAME}` / `${DATA_BASENAME}` default to `ifp-result` / `ifp-data`; trigger `result_basename` / `data_basename` override per project (carry-forward). Non-default `repo_path` MUST be passed on every scheduled trigger and callback because the dispatcher needs it to locate `campaign_state.json` before sourcing `env_paths.sh`. The dispatcher derives `HULAT_DIR=${REPO_PATH}/hulat`.

Claude Code invocation contract and Wiki-evidence publication contract live in [`references/executor_prompt.md`](skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) and in the SKILL's §Dispatcher Algorithm.
