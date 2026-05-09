# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not** an application repo — it is the **deployment artifact for an OpenClaw agent** named `acpx_auto_tester`. It contains the agent's prompt contracts (`SOUL.md`, `AGENTS.md`, `USER.md`), one SKILL (`gitlab_issue_campaign_dispatcher`), and the bash scripts that SKILL invokes. There is no build, no test runner, no package manifest. Changes here are deployed by syncing this workspace to the runner.

The agent itself runs at `/data/...` on the OpenClaw runner; nothing in this repo executes locally during development. When editing scripts, sanity-check with `bash -n scripts/foo.sh` (it appears in the allowed permissions and is the only "test" command in use).

## Single-skill, async-callback execution model

The agent has **one thick orchestrator session + one anonymous subagent run per IID**. There is exactly **one SKILL** in this workspace (the orchestrator). The subagent NEVER loads a SKILL — it receives a fully-rendered self-contained fixed-format prompt as the entire `sessions_spawn` payload and emits ONE compact JSON line on its last turn. The runtime captures that line and forwards it to the orchestrator inside `RUN_CHILD_COMPLETION_CALLBACK`.

The split: the orchestrator does ALL preparation (Phases 1–4) and ALL terminal bookkeeping (Phase 6); the subagent does only the technical work it's asked to do (Step 0–9 in the prompt's `<instructions>` block). The orchestrator owns every state-file write — the subagent does not touch state files. The orchestrator-subagent boundary is **async-callback**: `sessions_spawn` returns a launch ack within seconds; the runtime later wakes the orchestrator with `RUN_CHILD_COMPLETION_CALLBACK` carrying the subagent's terminal compact JSON.

**Orchestrator (`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/`)** stays alive across scheduler ticks (`agent:acpx_auto_tester:main`). It runs different phases on each of its two trigger commands:

### Path A: scheduled wake-up (`RUN_SCHEDULED_ISSUE_CAMPAIGN`)

| Phase | What |
| ----- | ---- |
| 1 Parse        | bootstrap, flock, load + override `campaign_state.json` from trigger; **stuck-pending eviction** (synthesizes Phase 6 blocked replies for any pending entries past `stuck_after_minutes`) |
| 2 Reconcile    | mandatory `reconcile.sh` against GitLab; correct disk cache from evidence file (no evidence = tick failed) |
| 3 Eligibility  | if `pending_subagents` is still non-empty after eviction → return `waiting_for_callbacks` and exit. Otherwise: tick-level prep (`ensure_labels.sh`, `clone_or_pull.sh`); validate `max_concurrent_subagents=1`; form one serial IID under launch quota |
| 4 Per-IID Prep | for the single IID: `allocate_attempt.sh` → load UI account from `<workspace>/config/ui_accounts.env` → `prepare_attempt.sh` (switches `${REPO_PATH}` to the per-attempt local branch; the test team's `hulat/`, `.claude/`, `ifp-data/` are already in the branch checkout) → reads issue title/url/labels/body via `glab` → `set_issue_label.sh` transitions entry labels (`todo` / `retry` / `new` / `continue` / `blocked` plus matched trigger labels) to `doing` → `build_prompt.sh` (writes `${LOG_DIR}/prompt.txt` with UI account injected) → initializes `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` (status=in_progress) → writes `pending_subagents[iid]` placeholder → renders [`references/executor_prompt.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) with per-IID values |
| 5 Async Spawn  | single **anonymous** `sessions_spawn` call (NO session name passed — runtime returns `runId` + `childSessionKey` like `agent:acpx_auto_tester:subagent:<uuid>`). Records the launch ack into `pending_subagents[iid]`. Returns `waiting_for_callbacks` and exits. **Phase 6 does NOT run on this path** (except inline-synthesized blocked for launch failures). |

### Path B: callback wake-up (`RUN_CHILD_COMPLETION_CALLBACK`)

The runtime delivers ONE callback per subagent termination, carrying the subagent's terminal compact JSON in `worker_result_json`.

| Phase | What |
| ----- | ---- |
| 1 Parse     | bootstrap, flock, load `campaign_state.json` (no trigger override on callback path) |
| 2 Reconcile | narrow reconcile against GitLab (single-IID range when feasible) |
| 6 Follow-up | parse + validate the callback's compact JSON → match to `pending_subagents[reply.iid]` (Phase 6 validation rule 2; reply.attempt_number must equal pending entry's) → synchronize live labels (`done` + `pr`, `blocked`, or `failed`) → write **terminal** `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}` → drain pending entry → classify into `completed_iids` / `blocked_iids` / `failed_iids` (promote `blocked → failed` if `retry_count > blocked_retry_limit`) → optional notify_channel → return |

**Subagent (anonymous runtime session; the orchestrator matches replies back by the `iid` field of the compact JSON)** receives the rendered fixed-format prompt and runs Steps 0–9 from the prompt's `<instructions>` block:

1. SETUP: `cd ${WORKTREE_DIR}` and one-shot `acpx --auth-policy skip claude exec -f ${LOG_DIR}/prompt.txt`.
2. `stage_and_guard.sh` (repo-root staged-path leak guard).
3. `commit_and_push.sh` (Strategy A force-push to single fixed `${WORK_BRANCH}`).
4. `post_push_verify.sh` (remote-branch leak guard).
5. `upload_attempt_artifacts.sh` (publish prompt/result/optional report.html to project Wiki, link from issue).
6. `set_issue_label.sh` `doing → done`.
7. `create_mr.sh` (mode-dependent: fresh = reuse single MR; continue = close prior open MRs and create a fresh one).
7b. `set_issue_label.sh add pr` after MR creation succeeds.
8. `summarize_attempt.sh` posts a per-attempt summary as a GitLab issue note.
9. **Emit ONE compact JSON line** on the LAST line of its turn, carrying every fact the orchestrator's Phase 6 needs (`iid`, `attempt_number`, `status`, `mode_actual`, `work_branch`, `local_branch`, `commit_sha`, `merge_request_url`, `mr_action`, `wiki_url`, `labels_added`, `labels_removed`, `summary_posted`, `block_reason`, `log_dir`).

On any subagent FAIL path, remove `doing` and add `blocked` before summarizing and returning the compact JSON. Phase 6 re-applies the final label state idempotently when the callback arrives.

The subagent invokes scripts at `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts/<name>.sh` by absolute path (the orchestrator renders `{SCRIPTS_DIR}` into the prompt). It does NOT load any SKILL, NOT read `SOUL.md` / `AGENTS.md`, NOT call `sessions_spawn` / `sessions_history`, NOT write any state file. Its compact JSON reply is the single artifact the orchestrator reads from it.

Spawn is **anonymous + async-callback**: `sessions_spawn` is called WITHOUT any session-name parameter, with `timeoutSeconds=30` (launch-ack wait — the harness default of ~10s has been observed to time out before the runtime returns the ack and leave only a `childSessionKey` placeholder with no `runId`, i.e. an orphan-pending IID with no real subagent behind it) and `runTimeoutSeconds=3600` (subagent runtime cap). It returns within seconds with `runId` + `childSessionKey` (a launch ack — recorded into `pending_subagents[iid]`). The terminal compact JSON arrives later inside `RUN_CHILD_COMPLETION_CALLBACK`. The orchestrator routes each callback's JSON back to its dispatched IID by the `iid` field of the JSON, NOT by the runtime session-key label. The "same IID never runs twice" guarantee comes from the orchestrator's `active_issue_iids` + `pending_subagents` bookkeeping (Phase 4 step 5 persists the IID before spawn; Phase 6 drains it on callback). Fire-and-forget WITHOUT callback delivery is forbidden — that is a deployment incompatibility and the orchestrator aborts. Stuck-pending eviction (`stuck_after_minutes`, default 90) is a backstop for when callbacks fail to arrive, not a substitute for the callback contract.

## Concurrency and UI-account allocation

`max_concurrent_subagents` (trigger field, default 1) is retained for schema compatibility but must be exactly `1`. All attempts share the main repo checkout, so cross-IID parallelism is disabled; a trigger value greater than 1 is a tick-level configuration error.

Because the system under test logs out an account when it logs in twice, the dispatcher MUST still allocate a UI account from the pool pinned at `workspace-acpx_auto_tester/config/ui_accounts.env`. Pool-too-small is a tick-level failure. The UI account is injected into the **Claude Code prompt** (`${LOG_DIR}/prompt.txt`) by `build_prompt.sh`; the subagent never sees the credentials directly.

Scheduled wake-up batch shape: pick at most one IID → run per-IID prep → spawn one anonymous run → record the launch acknowledgement → return `waiting_for_callbacks`. Terminal replies arrive later through `RUN_CHILD_COMPLETION_CALLBACK`; the next scheduled wake-up forms another batch only after `pending_subagents` is empty or evicted. No mid-batch top-up.

## Source of truth

GitLab live labels are the source of truth for per-issue workflow state. Disk state (`ifp-result/_dispatcher/campaign_state.json`, `ifp-result/issue-<iid>/state.json`, `ifp-result/issue-<iid>/attempt_state.json`) is only the dispatcher's progress cache. Every tick MUST run `scripts/reconcile.sh` and write a `reconcile-<ts>.json` evidence file before any "already done / skip / early-return" decision. **No evidence file = the tick is failed.**

Key reconciled signals: `is_closed_on_gitlab` (closed = hard terminal skip, never schedule), `has_done_pr` (both `done` and `pr` labels present = completed), `needs_continue` (opened + has `continue` or legacy `contiune` = reviewer wants resume; wins over cached done state), `user_reopened` (opened + missing `done`+`pr` + no `failed`/`blocked`/`continue`/`contiune`).

Disk cache is corrected to match GitLab — never the other way around.

## Disk state layout

```
/data/${PROJECT}/                              ← ${REPO_PATH}; the cloned project repo
    .claude/                                   ← in master+dev (test-team owned, READ-ONLY)
    hulat/                                     ← in master+dev (was the legacy ${HULAT_DIR}; READ-ONLY)
    ifp-data/                                  ← in master+dev (knowledge base, READ-ONLY)
    ifp-result/                                ← agent runtime workspace + issue output root
        _dispatcher/
            campaign_state.json                ← dispatcher cache (NOT source of truth)
            campaign.lock                      ← flock target
            log/reconcile-<ts>.json            ← reconciliation evidence files
            locks/repo.lock                    ← flock target for clone_or_pull / prepare_attempt
        issue-<iid>/
            state.json                         ← cross-attempt per-issue state
            attempt_state.json                 ← current attempt; overwritten each attempt
            hulat-spec-issue<iid>/             ← Claude Code's spec output (committed; lands in MR)
            log/attempt-NNN/                   ← preserved logs per attempt
            summary.md
```

`clone_or_pull.sh` appends `/<basename RESULT_ROOT>/` (e.g. `/ifp-result/`) to `${REPO_PATH}/.git/info/exclude` once per clone. `.git/info/exclude` is local-only (never committed/pushed), so per-project runtime-root names are handled by the agent without requiring the test team to maintain a `.gitignore` rule on master + dev. `stage_and_guard.sh` force-adds only the current issue's `${OUTPUT_DIR}` (`ifp-result/issue-<iid>/hulat-spec-issue<iid>/`), bypassing both `.gitignore` and `info/exclude`. `stage_and_guard.sh` (exit 3) and `post_push_verify.sh` (exit 4) reject protected paths: `ifp-result/_dispatcher/`, any non-output path under `ifp-result/issue-*`, and `.claude/`, `hulat/`, `ifp-data/`. If either guard trips, mark `blocked` — do **not** `git rm` the leaked paths and retry.

## Two-branch model

- `branch` (typically `master`) — **integration / target** branch. MRs are opened against it. Each issue's spec output lives under `ifp-result/issue-<iid>/hulat-spec-issue<iid>/` so MRs into master never collide.
- `dev_branch` (typically `dev`) — **clean baseline**. Fresh-mode attempts reset the main repo checkout to `origin/${dev_branch}` so Claude Code does not see past issues' spec accumulation. Set `dev_branch=<same-as-branch>` to disable.
- `WORK_BRANCH=issue/<iid>-auto-fix` — the SINGLE remote branch per issue. Each attempt **force-pushes** to it (Strategy A). Local per-attempt branches `${WORK_BRANCH}-att<NNN>` are kept for audit.
- Continue mode bases the checkout on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${dev_branch}`. If `origin/${WORK_BRANCH}` is missing, `prepare_attempt.sh` downgrades to fresh mode and records `mode_downgraded_from="continue"` — the only documented exception to the no-fallback policy.

## Strict no-fallback policy

Both halves MUST follow the prescribed method exactly. When it fails, fail the affected unit of work — do **not** improvise. This rule is stronger than typical "be careful" guidance:

- If a script in `scripts/` exits non-zero, **read stdout/stderr, classify, persist state, stop**. Do not rewrite its logic inline, do not "do it manually", do not substitute a "simpler" command.
- All GitLab access is via `glab` CLI through the commands listed in the SKILL's `references/glab_commands.md` (G1–G13). **No `curl` / `wget` / `requests` / `python-gitlab` / `@gitbeaker` / any HTTP library.** Not even as a "just this once" fallback.
- The Claude Code invocation contract is exactly `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` from `cwd=${WORKTREE_DIR}`, one-shot. No `-s` (persistent session), no `--no-wait`, no streaming mode, no calling `claude` directly without acpx, no other LLM as substitute.
- If `git push` is rejected, mark `blocked` — do **not** add extra `git push --force` outside `commit_and_push.sh`, do not rebase and re-push.
- `glab mr merge` is forbidden — MRs stay open until a human merges them. The subagent never closes the issue itself either; GitLab auto-closes via `Closes #<iid>` in the MR body.
- If a per-IID dispatcher prep step fails (clone_or_pull, prepare_attempt, build_prompt, label transitions), mark that IID `blocked` and end the serial batch. Do NOT spawn an IID with partial setup. Do NOT retry the failed prep inline.

If you find yourself reaching for a tool, command, flag, or workflow that is not explicitly listed in the SKILL, in the rendered subagent prompt, in `scripts/`, or in `references/`, that is the signal to **stop and fail** — not to try harder.

## Per-exec environment contract

OpenClaw runs each Bash tool call in a **fresh shell**. Exports do NOT survive to the next exec. Every `scripts/*.sh` self-bootstraps by sourcing `env_paths.sh` at its top, but `env_paths.sh` requires the minimum trigger inputs in env at every call.

`env_paths.sh` is **layered**: it always derives dispatcher-level paths, and additionally derives per-issue + attempt-level paths when `ISSUE_IID` is set (then `ATTEMPT_NUMBER` is also required).

- Dispatcher minimum: `PROJECT`, `GROUP`, `GITLAB_TOKEN`. Some scripts add `IID` / `MIN_IID` / `MAX_IID` / `BRANCH` / `BATCH_SIZE`.
- Per-issue prep + subagent minimum: above + `ISSUE_IID`, `ATTEMPT_NUMBER`. Some scripts add `BRANCH` / `DEV_BRANCH` / `ISSUE_MODE` / `ISSUE_TITLE` / `UI_ACCOUNT` / `UI_PASSWORD`. `HULAT_DIR` is derived inside `env_paths.sh` as `${REPO_PATH}/hulat` and does NOT need to be passed.

Always prefix Bash invocations with the minimum vars on the same line — never rely on prior exports. The recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
ISSUE_IID=14 ATTEMPT_NUMBER=3 BRANCH=master DEV_BRANCH=dev \
ISSUE_MODE=fresh \
bash scripts/<script>.sh
```

The subagent does NOT compute its own attempt number — `env_paths.sh` refuses to load without `ATTEMPT_NUMBER`. The dispatcher allocates once via `allocate_attempt.sh` and embeds the value in the rendered prompt. This prevents double-counting on session restart.

## Working directory

Every script path in the SKILL is relative to that skill's own directory. Before any `bash scripts/...` invocation in the dispatcher, `cd "${SKILL_DIR}"` once per session. Do NOT prepend `./` or `../`; do NOT `find`/`ls` for scripts. The subagent uses absolute paths via the rendered `{SCRIPTS_DIR}` placeholder, so the working-directory rule only affects the dispatcher session.

## Deployment-pinned config

The runner has these files at `workspace-acpx_auto_tester/config/`:

- `gitlab.env` — `GITLAB_HOST` and `GITLAB_API_PROTOCOL`. The host is **never** derived from the trigger's `gitlab_address`; that field is verification-only. Token rotation works because `gitlab_token` from the trigger is forwarded to `glab auth login` against the pinned host.
- `ui_accounts.env` — pool of UI test accounts, one `username:password` per line. Pool size MUST be at least 1.

These are deployment-time pins, edited once on each runner. Not generated from triggers, not modified at runtime.

## Sanity-checking shell changes

`bash -n scripts/foo.sh` is the only quick check used in this workspace. Run it after editing any script.

## Where to look for full details

- Workspace contracts: `workspace-acpx_auto_tester/SOUL.md` (subagent concurrency policy, no-fallback, GitLab access, host pinning, per-exec env contract, working directory, source of truth).
- Dispatcher algorithm + spawn payload: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md` (§Dispatcher Algorithm, §UI Account Allocation Policy, §Source-of-Truth Policy, §Concurrency Policy).
- The subagent's prompt template: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md` — the dispatcher renders this and ships it as the spawn payload.
- Trigger schema, state schemas, allowed glab commands (G1–G13), label lifecycle, continue-mode template: that skill's `references/`.

When in doubt about a path / schema / command / transition, READ the matching reference file. Do NOT reconstruct content from memory — these contracts are deliberately exhaustive and the agent's correctness depends on following them literally.
