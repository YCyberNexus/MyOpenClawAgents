# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not** an application repo — it is the **deployment artifact for an OpenClaw agent** named `acpx_auto_tester_temporal`. It contains the agent's prompt contracts (`SOUL.md`, `AGENTS.md`, `USER.md`), one SKILL (`gitlab_issue_campaign_dispatcher`), and the bash scripts that SKILL invokes. There is no build, no test runner, no package manifest. Changes here are deployed by syncing this workspace to the runner.

The agent itself runs on the OpenClaw runner with repo clone parents defaulting to `/data` unless trigger `repo_path` overrides that parent; nothing in this repo executes locally during development. **Do NOT attempt to run this agent or `acpx claude` locally on this machine** — the agent and acpx toolchain only work on the server. When editing scripts, sanity-check with `bash -n scripts/foo.sh` (it appears in the allowed permissions and is the only "test" command in use).

## Single-skill, async-callback execution model

The agent has **one thick orchestrator session + one anonymous subagent run per IID** (multiple IIDs may be in flight concurrently up to `max_concurrent_subagents`). There is exactly **one SKILL** in this workspace (the orchestrator). The subagent NEVER loads a SKILL — it receives a fully-rendered self-contained fixed-format prompt as the entire `sessions_spawn` payload, runs Steps 0–10, and emits ONE compact JSON line on its last turn. The runtime captures that line and forwards it to the orchestrator inside `RUN_CHILD_COMPLETION_CALLBACK`. The orchestrator owns every state-file write; the subagent never touches state files. Full algorithm + spawn shape: workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md §Dispatcher Algorithm + §Concurrency Policy.

Cross-IID parallelism uses **per-issue linked git worktrees** (shared across every attempt of the same IID): `prepare_attempt.sh` creates `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/` via `git worktree add -B` on attempt 1 and force-switches the checked-out branch in place on attempt N>1 after preserving `${RESULT_BASENAME}/issue-<iid>/`. `continue` restores that subtree into the active worktree for resume; all non-continue entry labels reset from the clean baseline and keep the preserved files outside the active worktree. The parent checkout at `${REPO_PATH}` is never mutated by an attempt — only `git fetch` runs against it under `${RESULT_ROOT}/_dispatcher/locks/repo.lock`. N concurrent attempts (one per distinct IID) share one clone of the repo and one fetched object database without colliding on a single working tree; same-IID attempts never run concurrently (single-batch invariant), so reusing one worktree per IID is safe.

**Orchestrator (`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/`)** stays alive across scheduler ticks (`agent:acpx_auto_tester_temporal:main`). It runs different phases on each of its two trigger commands:

### Path A: scheduled wake-up (`RUN_SCHEDULED_ISSUE_CAMPAIGN`)

| Phase | What |
| ----- | ---- |
| 1 Parse        | bootstrap, flock, load + override `campaign_state.json` from trigger; **stuck-pending eviction** (synthesizes Phase 6 blocked replies for any pending entries past `stuck_after_minutes`) |
| 2 Reconcile    | mandatory `reconcile.sh` against GitLab; correct disk cache from evidence file (no evidence = tick failed) |
| 3 Eligibility  | if `pending_subagents` is still non-empty after eviction → return `waiting_for_callbacks` and exit. Otherwise: tick-level prep (`ensure_labels.sh`, `clone_or_pull.sh`); validate `max_concurrent_subagents ≥ 1` (and `≤ ui_pool_size` when `ui_accounts_relpath` is configured — otherwise no upper bound applies); form a batch of up to that many IIDs under launch quota |
| 4 Per-IID Prep | for each IID in the batch: `allocate_attempt.sh` → load that IID's UI account slot from `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}` (no default; opt in via trigger `ui_accounts_relpath`, carry-forward persisted; relpath resolved under the project checkout root, NOT under `${REPO_PATH}/${DATA_BASENAME}/`; when unconfigured the entire UI-account flow is skipped and the rendered Claude Code prompt omits its `# UI test accounts` section) → `prepare_attempt.sh` (creates the shared per-issue linked worktree at `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/` via `git worktree add -B` on attempt 1, or in-place force-switches the checked-out branch to BASE_REF on attempt N>1 after preserving same-IID `${RESULT_BASENAME}/issue-<iid>/` files; only `continue` restores those files into the active worktree, while every non-continue entry label resets from the clean baseline; the test team's `hulat/`, `.claude/`, `ifp-data/` come from the base branch checkout) → reads issue title/url/labels/body via `glab` → `set_issue_label.sh` transitions entry labels (`todo` / `retry` / `new` / `continue` / `blocked` plus matched trigger labels) to `doing` → `build_prompt.sh` (writes `${LOG_DIR}/prompt.txt` with UI account injected) → initializes `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` (status=in_progress) → writes `pending_subagents[iid]` placeholder → renders [`references/executor_prompt.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) with per-IID values |
| 5 Async Spawn  | one **anonymous** `sessions_spawn` call per surviving IID (NO session name passed — runtime returns `runId` + `childSessionKey` like `agent:acpx_auto_tester_temporal:subagent:<uuid>`). Launch failures retry the identical payload up to 3 total attempts with 2-second fixed backoff; only a valid ack is recorded into `pending_subagents[iid]`. Returns `waiting_for_callbacks` and exits. **Phase 6 does NOT run on this path** (except inline-synthesized blocked for launch failures, which do not increment `retry_count`). |

### Path B: callback wake-up (`RUN_CHILD_COMPLETION_CALLBACK`)

The runtime delivers ONE callback per subagent termination, carrying the subagent's terminal compact JSON in `worker_result_json`.

| Phase | What |
| ----- | ---- |
| 1 Parse     | bootstrap, flock, load `campaign_state.json` (no trigger override on callback path) |
| 2 Reconcile | narrow reconcile against GitLab (single-IID range when feasible) |
| 6 Follow-up | parse + validate the callback's compact JSON → match to `pending_subagents[reply.iid]` (Phase 6 validation rule 2; reply.attempt_number must equal pending entry's) → synchronize live labels (`done` + `pr`, `blocked`, or `failed`) → write **terminal** `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}` → drain pending entry → classify into `completed_iids` / `blocked_iids` / `failed_iids` (promote `blocked → failed` if `retry_count > blocked_retry_limit`) → best-effort `subagents kill --target <child_session_key>` for terminal `done` / `blocked` / `failed` when `kill_subagent_on_terminal=true` (default; blocked/failed cleanup first requires local evidence under `${LOG_DIR}` / `${ISSUE_ROOT}`) → optional notify_channel → return |

**Subagent (anonymous runtime session; the orchestrator matches replies back by the `iid` field of the compact JSON)** receives the rendered fixed-format prompt and runs Steps 0–10 from the prompt's `<instructions>` block:

1. SETUP: call `bash ${SCRIPTS_DIR}/run_acpx_attempt.sh` with the standard per-issue env. The script `cd`s into `${WORKTREE_DIR}` (the shared per-issue linked worktree for this IID) and owns the fixed `acpx --auth-policy skip claude exec -f ${LOG_DIR}/prompt.txt` invocation. Current acpx releases expose `claude exec` as a one-shot command with no saved-session flag, so attempts of the same IID do NOT share Claude-Code session memory. Cross-attempt continuity for `continue` comes from three layers: (a) the self-contained rendered prompt (incl. prior attempt summaries auto-posted as GitLab notes and reviewer comments); (b) the committed `origin/${WORK_BRANCH}` contents or latest local prior-attempt branch that continue/resume attempts check out; and (c) the shared per-issue worktree's `${RESULT_BASENAME}/issue-<iid>/` subtree, which `prepare_attempt.sh` snapshots and restores around in-place branch switches. Non-continue entry labels (`todo`, `retry`, `new`, `blocked`, trigger require_labels) are reset runs: the prior subtree is archived, not restored into the active worktree. See `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md` and `references/continue_mode.md` for the externalized continuity contract.
2. `stage_and_guard.sh` (stage repo-root changes; force-add the issue's `${OUTPUT_DIR}`; emit STAGED_OK / NO_CHANGES — no path-based reject).
3. `commit_and_push.sh` (Strategy A force-push to single fixed `${WORK_BRANCH}`).
4. `post_push_verify.sh` (post-push fetch sanity — no path-based reject).
5. `upload_attempt_artifacts.sh` (publish prompt/result/optional report.html to project Wiki, link from issue).
6. `set_issue_label.sh` `doing → done`.
7. `create_mr.sh` (both modes rotate: close every prior open MR for `${WORK_BRANCH}` then create a fresh one — `mr_action="rotated"` when a prior MR was closed, `"created"` otherwise; the legacy fresh-mode reuse path is retired).
8. `set_issue_label.sh add pr` after MR creation succeeds.
9. `summarize_attempt.sh` writes a local per-attempt summary; successful `done` attempts also post it as a GitLab issue note, while failure summaries stay local.
10. **Emit ONE compact JSON line** on the LAST line of its turn, carrying every fact the orchestrator's Phase 6 needs (`iid`, `attempt_number`, `status`, `mode_actual`, `work_branch`, `local_branch`, `commit_sha`, `merge_request_url`, `mr_action`, `wiki_url`, `labels_added`, `labels_removed`, `summary_posted`, `block_reason`, `log_dir`).

On any subagent FAIL path, remove `doing` and add `blocked` before summarizing and returning the compact JSON. For non-timeout acpx failures, the subagent first tries `stage_and_guard.sh` → `commit_and_push.sh` → `post_push_verify.sh` so committable partial work reaches `${WORK_BRANCH}` even though the issue remains `blocked` and no Wiki/MR/`pr` is produced. Phase 6 re-applies the final label state idempotently when the callback arrives.

The subagent invokes scripts at `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts/<name>.sh` by absolute path (the orchestrator renders `{SCRIPTS_DIR}` into the prompt). It does NOT load any SKILL, NOT read `SOUL.md` / `AGENTS.md`, NOT call `sessions_spawn` / `sessions_history`, NOT write any state file. Its compact JSON reply is the single artifact the orchestrator reads from it.

Spawn is **anonymous + async-callback**: `sessions_spawn` is called WITHOUT any session-name parameter, with `timeoutSeconds=30` (launch-ack wait — the harness default of ~10s has been observed to time out before the runtime returns the ack and leave only a `childSessionKey` placeholder with no `runId`, i.e. an orphan-pending IID with no real subagent behind it) and `runTimeoutSeconds=run_timeout_seconds` (subagent runtime cap; default 18120s = `acpx_timeout_seconds + 120`). Any launch failure shape (`status:"error"`, gateway timeout, missing `runId`/`childSessionKey`, tool/runtime error) retries the identical spawn payload up to 3 total attempts with a 2-second fixed backoff. A valid launch returns within seconds with `runId` + `childSessionKey` and is recorded into `pending_subagents[iid]`; retry exhaustion synthesizes a blocked reply without incrementing `retry_count`. The terminal compact JSON arrives later inside `RUN_CHILD_COMPLETION_CALLBACK`. The orchestrator routes each callback's JSON back to its dispatched IID by the `iid` field of the JSON, NOT by the runtime session-key label. The "same IID never runs twice" guarantee comes from the orchestrator's `active_issue_iids` + `pending_subagents` bookkeeping (Phase 4 step 5 persists the IID before spawn; Phase 6 drains it on callback). Fire-and-forget WITHOUT callback delivery is forbidden — that is a deployment incompatibility and the orchestrator aborts. Stuck-pending eviction (`stuck_after_minutes`, defaulting to `ceil(run_timeout_seconds / 60) + 30`) is a backstop for when callbacks fail to arrive, not a substitute for the callback contract.

## Concurrency and UI-account allocation

`max_concurrent_subagents` (trigger field, default 1) caps both the per-tick batch size and the maximum number of in-flight subagents. `max_accounts_per_issue` (trigger field, default 14) caps how many UI accounts one IID/subagent receives after the pool is divided by concurrency. Per-attempt worktrees give each subagent its own working tree, so cross-IID parallelism is enabled. When the deployment configures the UI account pool via trigger field `ui_accounts_relpath` (no default; carry-forward persisted; the relpath is resolved under the project checkout root, so the pool file may live under any repo subdirectory, not only under `${REPO_PATH}/${DATA_BASENAME}/`), the pool size read from `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}` is the hard upper bound on `max_concurrent_subagents`: the system under test logs out an account when it logs in twice, so each in-flight subagent must hold a distinct credential. When the field is unconfigured the dispatcher skips the pool load entirely and only the `≥ 1` lower bound on `max_concurrent_subagents` applies. A `max_concurrent_subagents` trigger value below 1 aborts with `"invalid_max_concurrent_subagents: must be >= 1"`; a value above the pool aborts with `"ui_account_pool_too_small: pool=<size> max_concurrent_subagents=<value>"`. A `max_accounts_per_issue` value below 1 or non-integer aborts with `"invalid_max_accounts_per_issue: must be >= 1"`.

The dispatcher divides the pool into exactly `max_concurrent_subagents` raw slots — raw slot size = `floor(pool_size / max_concurrent_subagents)` with the integer remainder front-loaded onto the first slots, then each slot is capped by `max_accounts_per_issue` (e.g. default cap 14: `pool=50, max=4 → 13,13,12,12`; `pool=40, max=1 → 14`; `pool=3, max=2 → 2,1`). There is **no `accounts_per_issue` trigger field**; per-IID account counts are derived automatically. The dispatcher binds the `k`-th capped slot to the `k`-th IID of the batch and injects that slot's credentials into THAT IID's **Claude Code prompt** (`${LOG_DIR}/prompt.txt`) via `build_prompt.sh`; the subagent never sees the credentials directly. The pool is consulted fresh at every batch — `pending_subagents` is empty when a new batch forms (single-batch-in-flight invariant), so the next batch's accounts always come from the pool head.

Scheduled wake-up batch shape: pick up to `max_concurrent_subagents` IIDs → run per-IID prep sequentially (each gets its own worktree, attempt number, UI account) → spawn one anonymous run per IID with per-IID 3-attempt launch retry → record each valid launch acknowledgement → return `waiting_for_callbacks`. Terminal replies arrive later through `RUN_CHILD_COMPLETION_CALLBACK`; the next scheduled wake-up forms another batch only after `pending_subagents` is empty or evicted. No mid-batch top-up.

## Source of truth

GitLab live labels are the source of truth for per-issue workflow state. Disk state (`ifp-result/_dispatcher/campaign_state.json`, `ifp-result/issue-<iid>/state.json`, `ifp-result/issue-<iid>/attempt_state.json`) is only the dispatcher's progress cache. Every tick MUST run `scripts/reconcile.sh` and write a `reconcile-<ts>.json` evidence file before any "already done / skip / early-return" decision. **No evidence file = the tick is failed.**

Key reconciled signals: `is_closed_on_gitlab` (closed = hard terminal skip, never schedule), `has_done_pr` (both `done` and `pr` labels present = completed), `needs_continue` (opened + has `continue` or legacy `contiune` = reviewer wants resume; wins over cached done state), `user_reopened` (opened + missing `done`+`pr` + no `failed`/`blocked`/`continue`/`contiune`).

Disk cache is corrected to match GitLab — never the other way around.

## Disk state layout

```
${REPO_PATH}/                                  ← parent checkout (default /data/${PROJECT}; repo_path=/data/ifp1 gives /data/ifp1/${PROJECT})
    .claude/                                   ← in master+dev (test-team maintained)
    hulat/                                     ← in master+dev (was the legacy ${HULAT_DIR})
    ifp-data/                                  ← in master+dev (knowledge base)
    ifp-result/                                ← agent runtime root
        _dispatcher/
            campaign_state.json                ← dispatcher cache (NOT source of truth)
            campaign.lock                      ← flock target
            log/reconcile-<ts>.json            ← reconciliation evidence files
            locks/repo.lock                    ← flock target for clone_or_pull / prepare_attempt
        issues/                                ← parent of per-issue persistent subtrees
            issue-<iid>/                       ← per-issue subtree (lives OUTSIDE the worktree)
                state.json                     ← cross-attempt per-issue state
                attempt_state.json             ← current attempt; overwritten each attempt
                summary.md
        .worktrees/                            ← per-issue linked git worktrees (one per IID, shared across attempts)
            issue-<iid>/                       ← ${WORKTREE_DIR}; acpx cwd; created on attempt 1 via `git worktree add -B`,
                                                 reused on attempt N>1 via in-place force-checkout to BASE_REF (untracked
                                                 files Claude wrote in the previous attempt survive into the next one)
                .claude/ hulat/ ifp-data/      ← from base branch checkout
                ifp-result/issue-<iid>/hulat-spec-issue<iid>/   ← Claude Code's spec output (legacy path kept; force-added; lands in MR); shared across attempts
                ifp-result/issue-<iid>/log/attempt-NNN/         ← ${LOG_DIR}; attempt-scoped inside the shared worktree;
                                                                 prompt.txt + claude_result.txt force-added (land in MR);
                                                                 the rest stay locally ignored and removed with the worktree
```

`clone_or_pull.sh` appends `/<basename RESULT_ROOT>/` (e.g. `/ifp-result/`) to `${REPO_PATH}/.git/info/exclude` once per clone. `.git/info/exclude` is local-only (never committed/pushed) AND it's repository-wide (covers every linked worktree), so the entire `ifp-result/` subtree — including `.worktrees/` — is invisible to `git status` / `git add -A` in both the parent checkout and inside the per-issue worktree. `stage_and_guard.sh` bypasses that exclude with `git add -f` for two things inside the worktree: the current issue's `${OUTPUT_DIR}` (relative path `ifp-result/issue-<iid>/hulat-spec-issue<iid>/`) and the two reviewer-facing log files `${LOG_DIR}/prompt.txt` + `${LOG_DIR}/claude_result.txt` (relative path `ifp-result/issue-<iid>/log/attempt-NNN/`). Every other file under `${LOG_DIR}` (`acpx_raw.log`, `git_status.txt`, `git_diff.patch`, `wiki_*.md` / `.jsonl`, `mr_description.md`) stays locally ignored and never lands in the MR. There is no path-based reject in either `stage_and_guard.sh` or `post_push_verify.sh`: any file Claude produced or that ships with the base branch is allowed through to the issue MR.

Per-issue worktrees are NOT auto-cleaned and now live across the entire lifetime of an issue. `prepare_attempt.sh` creates the per-issue worktree on attempt 1 and reuses it for every subsequent attempt; on attempt N>1 it does an in-place `git checkout -B ${LOCAL_ATTEMPT_BRANCH} ${BASE_REF} --force` after snapshotting `${RESULT_BASENAME}/issue-<iid>/`. `continue` restores that subtree so prior attempt output/log files remain visible; every non-continue entry label archives it under `.preserved-attempts` and resets the active worktree from the clean baseline. Legacy per-attempt paths at `${WORKTREES_ROOT}/issue-<iid>-att-<NNN>/` are archived under `.preserved-legacy` after salvage rather than deleted. Operators may manually reclaim disk outside the automated agent workflow after verifying the paths; per-issue state (`state.json`, `attempt_state.json`, `summary.md`) under `ifp-result/issues/issue-<iid>/` survives worktree teardown, but anything under `${LOG_DIR}` that wasn't force-added (acpx_raw.log, wiki bookkeeping, etc.) is gone with the worktree. The force-added `prompt.txt` and `claude_result.txt` survive on `${WORK_BRANCH}` and in the MR diff.

The clone parent defaults to `/data`; trigger `repo_path` overrides that parent, and the final clone target is `${repo_path}/${PROJECT}`. Non-default deployments must pass `repo_path` on every scheduled trigger and callback. The directory names `ifp-result` and `ifp-data` are defaults. They can be overridden per project by the trigger fields `result_basename` / `data_basename` (carry-forward semantics — once set, persisted in `campaign_state.json` until the trigger replaces them). When overridden, every layer adapts automatically: `env_paths.sh` derives `RESULT_ROOT` / `DATA_DIR` from the basenames, `clone_or_pull.sh` writes the right name into `.git/info/exclude`, and `build_prompt.sh` substitutes the values into the executor prompt. Path examples in this document keep the `ifp-*` defaults for readability; see `references/trigger_command.md` for the override contract.

## Two-branch model

- `branch` (typically `master`) — **integration / target** branch. MRs are opened against it. Each issue's spec output lives under `ifp-result/issue-<iid>/hulat-spec-issue<iid>/` so MRs into master never collide.
- `dev_branch` (typically `dev`) — **clean baseline**. Fresh-mode attempts reset their per-issue worktree to `origin/${dev_branch}` so Claude Code does not see past issues' spec accumulation on tracked files. Untracked scratch left in the shared worktree by a prior attempt is NOT touched by the reset (that is intentional — `acpx claude exec` resumes from it). Set `dev_branch=<same-as-branch>` to disable.
- `WORK_BRANCH=issue/<iid>-auto-fix` — the SINGLE remote branch per issue. Each attempt **force-pushes** to it (Strategy A) from inside the shared per-issue worktree. Local per-attempt branches `${WORK_BRANCH}-att<NNN>` are kept in `${REPO_PATH}/.git` for audit.
- Continue mode resets the per-issue worktree to `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${dev_branch}`. If `origin/${WORK_BRANCH}` is missing, `prepare_attempt.sh` downgrades to fresh mode and records `mode_downgraded_from="continue"` — the only documented exception to the no-fallback policy.

## Strict no-fallback policy

Both halves MUST follow the prescribed method exactly. When it fails, fail the affected unit of work — do **not** improvise. This rule is stronger than typical "be careful" guidance:

- If a script in `scripts/` exits non-zero, **read stdout/stderr, classify, persist state, stop**. Do not rewrite its logic inline, do not "do it manually", do not substitute a "simpler" command.
- All GitLab access is via `glab` CLI through the commands listed in the SKILL's `references/glab_commands.md` (G1–G13). **No `curl` / `wget` / `requests` / `python-gitlab` / `@gitbeaker` / any HTTP library.** Not even as a "just this once" fallback.
- The Claude Code invocation contract is `bash ${SCRIPTS_DIR}/run_acpx_attempt.sh` with the standard per-issue env. That script is the only place that constructs the `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` command, and it runs from `cwd=${WORKTREE_DIR}` (the shared per-issue linked worktree for this IID, NOT the parent checkout). Current acpx releases expose `claude exec` as a one-shot command with no saved-session flag — there is no `-s` / session persistence inside acpx, so attempts of the same IID run independently at the acpx level. Cross-attempt continuity is externalized via (a) the rendered prompt, prior attempt summaries (auto-posted GitLab notes for successful `done` attempts), and reviewer comments; (b) the `origin/${WORK_BRANCH}` contents that continue-mode resets check out (including the force-added `log/attempt-NNN/prompt.txt` + `claude_result.txt`); AND (c) any untracked files Claude Code left in the shared per-issue worktree that the in-place branch switch in `prepare_attempt.sh` preserves. See `references/executor_prompt.md` and `references/continue_mode.md`. Start the script with PTY on the first attempt, use a timeout that covers the expected run, and if the exec tool yields a pollable process, poll the same process until it exits. Do not re-run the script after a tool timeout — if no pollable process is available, FAIL `status=blocked` with `block_reason="acpx exec timed out and no pollable process session was available"`. No direct `acpx` call from the subagent, no `--no-wait`, no streaming mode, no calling `claude` directly without acpx, no other LLM as substitute.
- If `git push` is rejected, mark `blocked` — do **not** add extra `git push --force` outside `commit_and_push.sh`, do not rebase and re-push.
- `glab mr merge` is forbidden — MRs stay open until a human merges them. The subagent never closes the issue itself either; GitLab auto-closes via `Closes #<iid>` in the MR body.
- If a per-IID dispatcher prep step fails (clone_or_pull, prepare_attempt, build_prompt, label transitions), mark that IID `blocked` and end the serial batch. Do NOT spawn an IID with partial setup. Do NOT retry the failed prep inline.
- If `sessions_spawn` launch fails, retry the SAME payload up to 3 total attempts with 2-second fixed backoff. If all attempts fail, synthesize `blocked` for that IID, preserve the last raw error in `block_reason`, do not add it to `pending_subagents`, and do not increment `retry_count`.

If you find yourself reaching for a tool, command, flag, or workflow that is not explicitly listed in the SKILL, in the rendered subagent prompt, in `scripts/`, or in `references/`, that is the signal to **stop and fail** — not to try harder.

## Per-exec environment contract

OpenClaw runs each Bash tool call in a **fresh shell**. Exports do NOT survive to the next exec. Every `scripts/*.sh` self-bootstraps by sourcing `env_paths.sh` at its top, but `env_paths.sh` requires the minimum trigger inputs in env at every call.

`env_paths.sh` is **layered**: it always derives dispatcher-level paths, and additionally derives per-issue + attempt-level paths when `ISSUE_IID` is set (then `ATTEMPT_NUMBER` is also required).

- Dispatcher minimum: `PROJECT`, `GROUP`, `GITLAB_TOKEN` (plus `REPO_PARENT_PATH` when trigger `repo_path` is non-default). Some scripts add `IID` / `MIN_IID` / `MAX_IID` / `BRANCH` / `MAX_CONCURRENT_SUBAGENTS` / `MAX_ACCOUNTS_PER_ISSUE`.
- Per-issue prep + subagent minimum: above + `ISSUE_IID`, `ATTEMPT_NUMBER`. Some scripts add `BRANCH` / `DEV_BRANCH` / `ISSUE_MODE` / `ISSUE_TITLE` / `UI_ACCOUNTS`. `HULAT_DIR` is derived inside `env_paths.sh` as `${REPO_PATH}/hulat` and does NOT need to be passed.

Always prefix Bash invocations with the minimum vars on the same line — never rely on prior exports. The recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
REPO_PARENT_PATH=/data \
ISSUE_IID=14 ATTEMPT_NUMBER=3 BRANCH=master DEV_BRANCH=dev \
ISSUE_MODE=fresh \
bash scripts/<script>.sh
```

The subagent does NOT compute its own attempt number — `env_paths.sh` refuses to load without `ATTEMPT_NUMBER`. The dispatcher allocates once via `allocate_attempt.sh` and embeds the value in the rendered prompt. This prevents double-counting on session restart.

## Working directory

Every script path in the SKILL is relative to that skill's own directory. Before any `bash scripts/...` invocation in the dispatcher, `cd "${SKILL_DIR}"` once per session. Do NOT prepend `./` or `../`; do NOT `find`/`ls` for scripts. The subagent uses absolute paths via the rendered `{SCRIPTS_DIR}` placeholder, so the working-directory rule only affects the dispatcher session.

## Deployment-pinned config

The runner has this deployment-time pin at `workspace-acpx_auto_tester/config/`:

- `gitlab.env` — `GITLAB_HOST` and `GITLAB_API_PROTOCOL`. The host is **never** derived from the trigger's `gitlab_address`; that field is verification-only. Token rotation works because `gitlab_token` from the trigger is forwarded to `glab auth login` against the pinned host.

UI test accounts are not configured in this workspace anymore. They are **opt-in** per project via the trigger field `ui_accounts_relpath` (no default; carry-forward persisted in `campaign_state.json`; the relpath is resolved under the project checkout root at `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}`, NOT under `${REPO_PATH}/${DATA_BASENAME}/`). When configured, the test-team-owned pool file at that path is read after the project repo is cloned/pulled. When the field is unconfigured the dispatcher skips the entire UI-account flow and the rendered Claude Code prompt omits its `# UI test accounts` section.

## Bumping SKILL_VERSION on workspace edits

After any edit to a file under `workspace-acpx_auto_tester/` — including `SOUL.md`, `AGENTS.md`, `USER.md`, `config/`, and anything under `skills/gitlab_issue_campaign_dispatcher/` (the SKILL itself, its `scripts/`, its `references/`) — bump the `[SKILL_VERSION=...]` token at the start of line 3 of [`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md) (inside the `description:` field).

Version format is `YYYY-MM-DD.N`:

- `YYYY-MM-DD` is the current date (the date of the edit).
- `N` is the per-day sequence number. If the existing version's date is not today, replace the whole token with `<today>.1`. If the existing version's date is already today, increment `N` by 1.

Examples (assume today is 2026-05-11):

- Existing `[SKILL_VERSION=2026-05-08.2]` → new `[SKILL_VERSION=2026-05-11.1]`.
- Existing `[SKILL_VERSION=2026-05-11.1]` (already bumped earlier today) → new `[SKILL_VERSION=2026-05-11.2]`.

Bump the version in the SAME edit/commit that introduces the workspace change — do not leave it for a follow-up. Edits to files OUTSIDE `workspace-acpx_auto_tester/` (e.g. this `CLAUDE.md`, repo-root files, `.claude/`) do NOT trigger a bump.

## Sanity-checking shell changes

`bash -n scripts/foo.sh` is the only quick check used in this workspace. Run it after editing any script.

## Code review workflow

Every non-trivial code change MUST go through the review loop before the task is considered complete. The reviewer is a Claude Code `code-reviewer` subagent (`Agent(subagent_type="code-reviewer")`).

1. **Edit**: Main agent makes the code changes.
2. **Review**: Spawn `Agent(subagent_type="code-reviewer")` to review the changes. Always pass the diff scope in the agent prompt (e.g. "review the uncommitted changes in CLAUDE.md"). The subagent checks for correctness, security, performance, and best practices. The review output is returned inline in the session, visible to both the main agent and the user.
3. **Address**: Main agent applies the reviewer's feedback. If the reviewer found no actionable findings (no code changes recommended), the loop is done. Otherwise, proceed to step 4.
4. **Repeat**: Go back to step 2. **Maximum 3 review rounds total.** If after the 3rd review the reviewer still finds issues, stop the loop and present the review report to the user for manual decision. Do not continue modifying without user approval.

This applies to all edits under `workspace-acpx_auto_tester/` (scripts, references, SKILL.md, SOUL.md, AGENTS.md, USER.md, config/). Trivial changes (typos, version bumps, single-line fixes) can skip the loop at the main agent's discretion.

A project-local Stop hook ([`.claude/hooks/require-workspace-review.sh`](.claude/hooks/require-workspace-review.sh), registered in [`.claude/settings.json`](.claude/settings.json)) enforces this: when the turn tries to end with uncommitted changes under `workspace-acpx_auto_tester/`, it returns `decision:"block"` and feeds back the review instruction. After the loop completes (or the change is genuinely trivial), clear the block by writing the current diff fingerprint to `.claude/.review-done-sha` — the exact `printf %s '<hash>' > .claude/.review-done-sha` line is included in the hook's reason text.

## Where to look for full details

- Workspace contracts: `workspace-acpx_auto_tester/SOUL.md` (subagent concurrency policy, no-fallback, GitLab access, host pinning, per-exec env contract, working directory, source of truth).
- Dispatcher algorithm + spawn payload: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md` (§Dispatcher Algorithm, §UI Account Allocation Policy, §Source-of-Truth Policy, §Concurrency Policy).
- The subagent's prompt template: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md` — the dispatcher renders this and ships it as the spawn payload.
- Trigger schema, state schemas, allowed glab commands (G1–G13), label lifecycle, continue-mode template: that skill's `references/`.

When in doubt about a path / schema / command / transition, READ the matching reference file. Do NOT reconstruct content from memory — these contracts are deliberately exhaustive and the agent's correctness depends on following them literally.
