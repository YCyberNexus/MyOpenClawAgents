# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not** an application repo — it is the **deployment artifact for an OpenClaw agent** named `acpx_auto_tester`. It contains the agent's prompt contracts (`SOUL.md`, `AGENTS.md`, `USER.md`), one SKILL (`gitlab_issue_campaign_dispatcher`), and the bash scripts that SKILL invokes. There is no build, no test runner, no package manifest. Changes here are deployed by syncing this workspace to the runner.

The agent itself runs at `/data/...` on the OpenClaw runner; nothing in this repo executes locally during development. When editing scripts, sanity-check with `bash -n scripts/foo.sh` (it appears in the allowed permissions and is the only "test" command in use).

## Single-skill, six-phase execution model (SKILL_VERSION 2026-05-06.6)

The agent has **one thick orchestrator session + one dedicated subagent session per GitLab issue**, structured as **6 phases per scheduled tick**. There is exactly **one SKILL** in this workspace (the orchestrator). The subagent NEVER loads a SKILL — it receives a fully-rendered self-contained fixed-format prompt as the entire `sessions_spawn` payload and runs only the technical workflow, returning ONE compact JSON line.

The split: the orchestrator does ALL preparation (Phases 1–4) and ALL terminal bookkeeping (Phase 6); the subagent does only the technical work it's asked to do (Step 0–9 in the prompt's `<instructions>` block). The orchestrator owns every state-file write — the subagent does not touch state files.

**Orchestrator (`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/`)** stays alive across scheduler ticks (`agent:acpx_auto_tester:main`). Per tick it runs 6 phases:

| Phase | What |
| ----- | ---- |
| 1 Parse        | bootstrap, flock, load + override `campaign_state.json` from trigger |
| 2 Reconcile    | mandatory `reconcile.sh` against GitLab; correct disk cache from evidence file (no evidence = tick failed) |
| 3 Eligibility  | tick-level prep (`ensure_labels.sh`, `clone_or_pull.sh`); form bounded batch under `max_concurrent_subagents` / quota / time budget |
| 4 Per-IID Prep | for each batch member: `allocate_attempt.sh` → load UI account from `<workspace>/config/ui_accounts.env` → `prepare_attempt.sh` (replaces worktree, sets up `hulat` symlink + `.claude` runtime) → reads issue title/url/labels/body via `glab` → `set_issue_label.sh` transitions to `doing` → `build_prompt.sh` (writes `${LOG_DIR}/prompt.txt` with UI account injected) → initializes `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` (status=in_progress) → renders [`references/executor_prompt.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md) with per-IID values |
| 5 Concurrent Spawn | single parallel `sessions_spawn` tool-call block; one subagent per IID; synchronously waits for every subagent's terminal compact JSON reply |
| 6 Follow-up    | for each compact reply: validate per [`references/state_schema.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) §Compact Subagent Reply → write **terminal** `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` from the reply → drain `active_issue_iids` → classify into `completed_iids` / `blocked_iids` / `failed_iids` (promote `blocked → failed` if `retry_count > blocked_retry_limit`) → optional notify_channel → loop back to Phase 4 if quota and time budget remain |

**Subagent (logical name `issue-<project>-<iid>`; runtime session name may be anonymous on channels that do not support thread-bound named sessions, in which case the orchestrator matches replies back by the `iid` field of the compact JSON)** receives the rendered fixed-format prompt and runs Steps 0–9 from the prompt's `<instructions>` block:

1. SETUP: `cd ${WORKTREE_DIR}` and one-shot `acpx --auth-policy skip claude exec -f ${LOG_DIR}/prompt.txt`.
2. `stage_and_guard.sh` (worktree leak guard).
3. `commit_and_push.sh` (Strategy A force-push to single fixed `${WORK_BRANCH}`).
4. `post_push_verify.sh` (remote-branch leak guard).
5. `upload_attempt_artifacts.sh` (publish prompt/result/optional report.html to project Wiki, link from issue).
6. `set_issue_label.sh` `doing → done`.
7. `create_mr.sh` (mode-dependent: fresh = reuse single MR; continue = close prior open MRs and create a fresh one).
7b. `set_issue_label.sh add pr` after MR creation succeeds.
8. `summarize_attempt.sh` posts a per-attempt summary as a GitLab issue note.
9. **Emit ONE compact JSON line** on the LAST line of its turn, carrying every fact the orchestrator's Phase 6 needs (`iid`, `attempt_number`, `status`, `mode_actual`, `work_branch`, `local_branch`, `commit_sha`, `merge_request_url`, `mr_action`, `wiki_url`, `labels_added`, `labels_removed`, `summary_posted`, `block_reason`, `log_dir`, `skill_version`).

The subagent invokes scripts at `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts/<name>.sh` by absolute path (the orchestrator renders `{SCRIPTS_DIR}` into the prompt). It does NOT load any SKILL, NOT read `SOUL.md` / `AGENTS.md`, NOT call `sessions_spawn` / `sessions_history`, NOT write any state file. Its compact JSON reply is the single artifact the orchestrator reads from it.

Spawn must be **synchronous**: the orchestrator's `sessions_spawn` blocks until the subagent returns the terminal compact JSON. Push-only acknowledgements (`accepted` / `runId` / child-session ids WITHOUT compact JSON) do **not** satisfy the contract — treat them as spawn failure. There is no fire-and-forget mode. Anonymous synchronous subagents (e.g., `mode="run"` on channels that reject thread-bound named sessions) ARE acceptable as long as they synchronously return the compact JSON; the orchestrator routes each reply back to its dispatched IID by the `iid` field of the JSON, not by the runtime session-key label. The "same IID never runs twice" guarantee comes from the orchestrator's `active_issue_iids` bookkeeping (Phase 4 step 5 persists the IID before spawn, Phase 6 drains it after the reply).

## Concurrency and UI-account allocation

`max_concurrent_subagents` (trigger field, default 1) caps the dispatcher to that many parallel subagents. Two attempts for the **same** IID never run concurrently regardless of this value — only different IIDs parallelize. Default 1 must behave exactly like the legacy strictly-serial model.

Because the system under test logs out an account when it logs in twice, the dispatcher MUST hand each concurrent subagent a distinct UI account from the pool pinned at `workspace-acpx_auto_tester/config/ui_accounts.env`. Pool-too-small is a tick-level failure — never share an account, never shrink the batch. The UI account is injected into the **Claude Code prompt** (`${LOG_DIR}/prompt.txt`) by `build_prompt.sh`; the subagent never sees the credentials directly.

Bounded-batch loop (per tick): pick `min(max_concurrent_subagents, remaining_quota, eligible_iids)` IIDs → run all per-IID prep → spawn the surviving batch in **one parallel tool-call block** → wait for all terminal replies → re-read each per-issue state → form the next batch. No mid-batch top-up. Time budget is checked between batches, not within a batch.

## Source of truth

GitLab live labels are the source of truth for per-issue workflow state. Disk state (`campaign_state.json`, `issues/issue-<iid>/state.json`, `issues/issue-<iid>/attempt_state.json`) is only the dispatcher's progress cache. Every tick MUST run `scripts/reconcile.sh` and write a `reconcile-<ts>.json` evidence file before any "already done / skip / early-return" decision. **No evidence file = the tick is failed.**

Key reconciled signals: `is_closed_on_gitlab` (closed = hard terminal skip, never schedule), `has_done_pr` (both `done` and `pr` labels present = completed), `needs_continue` (opened + has `continue` = reviewer wants resume; wins over cached done state), `user_reopened` (opened + missing `done`+`pr` + no `failed`/`blocked`/`continue`).

Disk cache is corrected to match GitLab — never the other way around.

## Disk state layout

```
/data/${PROJECT}/                              ← main git repo (host of git worktrees)
/data/openclaw_work/${PROJECT}/                ← all agent-owned files (OUTSIDE the repo)
    openclaw_state/campaign_state.json         ← dispatcher cache (NOT source of truth)
    openclaw_state/campaign.lock               ← flock target
    openclaw_log/dispatcher/reconcile-<ts>.json
    issues/issue-<iid>/
        state.json                             ← cross-attempt per-issue state
        attempt_state.json                     ← current attempt; overwritten each attempt
        worktree/                              ← acpx cwd; replaced every attempt
            hulat -> ${HULAT_DIR}              ← symlink, .git/info/exclude'd
            .claude/                           ← copy of ${HULAT_DIR}/ifp-hulat/.claude
        log/attempt-NNN/                       ← preserved logs per attempt
        summary.md
    locks/repo.lock                            ← flock target for prepare_attempt.sh
```

`${WORK_ROOT}` is intentionally outside the repo so `git add` cannot sweep agent artifacts into commits. `stage_and_guard.sh` (exit 3) and `post_push_verify.sh` (exit 4) are leak guards — they reject `openclaw_log/`, `openclaw_state/`, `hulat`, `.claude` in staged tree or remote branch. If either trips, mark `blocked` — do **not** `git rm` the leaked paths and retry.

## Two-branch model

- `branch` (typically `master`) — **integration / target** branch. MRs are opened against it. Each issue's spec output lives under `hulat-spec-issue<iid>/` so MRs into master never collide.
- `dev_branch` (typically `dev`) — **clean baseline**. Fresh-mode worktrees check out from `origin/${dev_branch}` so Claude Code does not see past issues' spec accumulation. Set `dev_branch=<same-as-branch>` to disable.
- `WORK_BRANCH=issue/<iid>-auto-fix` — the SINGLE remote branch per issue. Each attempt **force-pushes** to it (Strategy A). Local per-attempt branches `${WORK_BRANCH}-att<NNN>` are kept for audit.
- Continue mode bases the worktree on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${dev_branch}`. If `origin/${WORK_BRANCH}` is missing, `prepare_attempt.sh` downgrades to fresh mode and records `mode_downgraded_from="continue"` — the only documented exception to the no-fallback policy.

## Strict no-fallback policy

Both halves MUST follow the prescribed method exactly. When it fails, fail the affected unit of work — do **not** improvise. This rule is stronger than typical "be careful" guidance:

- If a script in `scripts/` exits non-zero, **read stdout/stderr, classify, persist state, stop**. Do not rewrite its logic inline, do not "do it manually", do not substitute a "simpler" command.
- All GitLab access is via `glab` CLI through the commands listed in the SKILL's `references/glab_commands.md` (G1–G13). **No `curl` / `wget` / `requests` / `python-gitlab` / `@gitbeaker` / any HTTP library.** Not even as a "just this once" fallback.
- The Claude Code invocation contract is exactly `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` from `cwd=${WORKTREE_DIR}`, one-shot. No `-s` (persistent session), no `--no-wait`, no streaming mode, no calling `claude` directly without acpx, no other LLM as substitute.
- If `git push` is rejected, mark `blocked` — do **not** add extra `git push --force` outside `commit_and_push.sh`, do not rebase and re-push.
- `glab mr merge` is forbidden — MRs stay open until a human merges them. The subagent never closes the issue itself either; GitLab auto-closes via `Closes #<iid>` in the MR body.
- If a per-IID dispatcher prep step fails (clone_or_pull, prepare_attempt, build_prompt, label transitions), mark that IID `blocked` and continue with OTHER batch members whose prep succeeded. Do NOT spawn an IID with partial setup. Do NOT retry the failed prep inline.

If you find yourself reaching for a tool, command, flag, or workflow that is not explicitly listed in the SKILL, in the rendered subagent prompt, in `scripts/`, or in `references/`, that is the signal to **stop and fail** — not to try harder.

## Per-exec environment contract

OpenClaw runs each Bash tool call in a **fresh shell**. Exports do NOT survive to the next exec. Every `scripts/*.sh` self-bootstraps by sourcing `env_paths.sh` at its top, but `env_paths.sh` requires the minimum trigger inputs in env at every call.

`env_paths.sh` is **layered**: it always derives dispatcher-level paths, and additionally derives per-issue + attempt-level paths when `ISSUE_IID` is set (then `ATTEMPT_NUMBER` is also required).

- Dispatcher minimum: `PROJECT`, `GROUP`, `GITLAB_TOKEN`. Some scripts add `IID` / `MIN_IID` / `MAX_IID` / `BRANCH` / `BATCH_SIZE`.
- Per-issue prep + subagent minimum: above + `ISSUE_IID`, `ATTEMPT_NUMBER`. Some scripts add `BRANCH` / `DEV_BRANCH` / `HULAT_DIR` / `ISSUE_MODE` / `ISSUE_TITLE` / `UI_ACCOUNT` / `UI_PASSWORD`.

Always prefix Bash invocations with the minimum vars on the same line — never rely on prior exports. The recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
ISSUE_IID=14 ATTEMPT_NUMBER=3 BRANCH=master DEV_BRANCH=dev HULAT_DIR=/data/openclaw/bu_data/px_hulat \
ISSUE_MODE=fresh \
bash scripts/<script>.sh
```

The subagent does NOT compute its own attempt number — `env_paths.sh` refuses to load without `ATTEMPT_NUMBER`. The dispatcher allocates once via `allocate_attempt.sh` and embeds the value in the rendered prompt. This prevents double-counting on session restart.

## Working directory

Every script path in the SKILL is relative to that skill's own directory. Before any `bash scripts/...` invocation in the dispatcher, `cd "${SKILL_DIR}"` once per session. Do NOT prepend `./` or `../`; do NOT `find`/`ls` for scripts. The subagent uses absolute paths via the rendered `{SCRIPTS_DIR}` placeholder, so the working-directory rule only affects the dispatcher session.

## Deployment-pinned config

The runner has these files at `workspace-acpx_auto_tester/config/`:

- `gitlab.env` — `GITLAB_HOST` and `GITLAB_API_PROTOCOL`. The host is **never** derived from the trigger's `gitlab_address`; that field is verification-only. Token rotation works because `gitlab_token` from the trigger is forwarded to `glab auth login` against the pinned host.
- `ui_accounts.env` — pool of UI test accounts, one `username:password` per line. Pool size MUST be `>= max_concurrent_subagents`.

These are deployment-time pins, edited once on each runner. Not generated from triggers, not modified at runtime.

## Sanity-checking shell changes

`bash -n scripts/foo.sh` is the only quick check used in this workspace. Run it after editing any script.

## Where to look for full details

- Workspace contracts: `workspace-acpx_auto_tester/SOUL.md` (subagent concurrency policy, no-fallback, GitLab access, host pinning, per-exec env contract, working directory, source of truth).
- Dispatcher algorithm + spawn payload: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md` (§Dispatcher Algorithm, §UI Account Allocation Policy, §Source-of-Truth Policy, §Concurrency Policy).
- The subagent's prompt template: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md` — the dispatcher renders this and ships it as the spawn payload.
- Trigger schema, state schemas, allowed glab commands (G1–G13), label lifecycle, continue-mode template: that skill's `references/`.

When in doubt about a path / schema / command / transition, READ the matching reference file. Do NOT reconstruct content from memory — these contracts are deliberately exhaustive and the agent's correctness depends on following them literally.
