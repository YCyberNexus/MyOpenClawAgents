# Continue Mode — Reviewer Contract and Prompt Construction

This page documents how human reviewers and the agent cooperate when an issue's earlier "done" was wrong (Claude Code returned without actually finishing the work). Both halves of the agent (the dispatcher's prep and the subagent's post-acpx flow) follow the rules below — `scripts/prepare_attempt.sh` and `scripts/build_prompt.sh` are run by the dispatcher; `scripts/create_mr.sh` is run by the subagent.

## Reviewer's responsibility (the human side)

When you find an issue whose MR was created but the work is incomplete or wrong, the agent will not detect this on its own. Do these three things, in this order:

1. **Read the latest auto-posted attempt summary on the issue.** The agent posts a short marked comment for successful `done` attempts with `<!-- acpx_auto_tester:attempt-summary v2 ... -->`; failure summaries stay local under `${ISSUE_ROOT}/summary.md`. Posted summaries tell you the attempt status, commit SHA when available, MR URL when available, changed-file count / preview, and the runner evidence path for full logs and diffs. For successful push-ready attempts, the agent also posts `<!-- acpx_auto_tester:attempt-wiki-artifacts v1 ... -->` before MR creation with links to the Wiki pages for prompt/result logs and optional report. Continue mode also recognizes legacy pre-rename markers from earlier runs.
2. **Leave a comment on the issue describing what to do on the next run.** The comment is freeform — write whatever the next Claude Code run needs. Include file paths, env requirements, acceptance criteria, or "do not do X" cautions.
3. **Flip the issue's label from `done` / `pr` to `continue`.** The agent triggers continue mode on the `continue` label. It also tolerates the legacy misspelling `contiune`, but new human action should use `continue`.

The next dispatcher tick will pick the issue up and re-run.

## What the agent does on its side

In continue mode:

1. **Dispatcher prep:** Resolves a fresh attempt number (monotonically increasing) via `scripts/allocate_attempt.sh` and runs `ISSUE_MODE=continue scripts/prepare_attempt.sh` only when the live issue label requests `continue` / `contiune`. Every non-continue entry path (`todo`, `retry`, `new`, `blocked`, and trigger `require_labels`) is a reset signal and runs in fresh mode instead. The shared per-issue worktree at `${WORKTREE_DIR}=${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-${ISSUE_IID}/` (path has NO `-att-<NNN>` suffix) is created on attempt 1; for continue/resume attempts the script does an in-place `git checkout -B ${LOCAL_ATTEMPT_BRANCH} <base> --force` inside the existing worktree, where `<base>` is `origin/${WORK_BRANCH}` when it exists or the latest local prior-attempt branch otherwise. Before that checkout, `prepare_attempt.sh` snapshots `${RESULT_BASENAME}/issue-<iid>/` from the shared worktree and restores it afterward, so tracked output/log files from the previous attempt are not deleted just because they are absent from the selected base ref. Fresh reset runs also snapshot that subtree before switching to `origin/${DEV_BRANCH}`, but archive it under `${WORKTREES_ROOT}/.preserved-attempts/` rather than restoring it, then quarantine any active same-IID runtime subtree that survived checkout before recreating empty current output/log directories. Old files are not physically deleted and do not contaminate the reset run. If this IID's prior attempts ran on a pre-shared-scheme deployment (`${WORKTREES_ROOT}/issue-<iid>-att-<NNN>/` or the very-old `${RESULT_ROOT}/issue-<iid>/worktree/`), `prepare_attempt.sh` rsync's their untracked content into the new shared worktree with `--ignore-existing` before archiving the legacy paths under `${WORKTREES_ROOT}/.preserved-legacy/` — cross-attempt continuity therefore holds even across the worktree-scheme migration, and old attempt directories are not physically deleted. Local `attempt_state.json` and `summary.md` are updated in place under `${ISSUE_ROOT}` (outside the worktree, so they survive worktree teardown). Per-attempt logs are written at `${WORKTREE_DIR}/${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/` INSIDE the shared worktree (still attempt-scoped so successive attempts don't overwrite each other); `prompt.txt` and `claude_result.txt` are force-added by `stage_and_guard.sh` and therefore preserved on `${WORK_BRANCH}`, so a later continue-mode attempt sees prior attempts' `log/attempt-001/`, `log/attempt-002/`, ... reappear in the worktree after the reset. The remaining log files (`acpx_raw.log`, `git_status.txt`, `git_diff.patch`, `wiki_*`, `mr_description.md`) stay locally ignored and disappear only if the worktree itself is removed. Prior attempt summaries also remain available as GitLab issue notes.
2. **Dispatcher prep:** Reads the issue (`G1` in `glab_commands.md`) for title, description, current labels.
3. **Dispatcher prep:** Runs `scripts/build_prompt.sh` which reads the issue notes (`G1b`) and **partitions them in two buckets**:
   - **Past attempt summaries** — notes whose body contains `<!-- acpx_auto_tester:attempt-summary ` or the legacy pre-rename summary marker. These are posted by the agent for successful prior attempts and contain compact status, commit / MR pointers, changed-file preview, and the runner evidence path. Failure summaries are local-only and are not injected into continue-mode prompts unless a human copies relevant guidance into a reviewer comment.
   - **Reviewer comments** — every other non-system note except auto-posted Wiki artifact notes (`<!-- acpx_auto_tester:attempt-wiki-artifacts ... -->`) and legacy pre-rename Wiki artifact notes. This is where humans write supplemental instructions.
4. **Dispatcher prep:** `build_prompt.sh` writes the Claude Code prompt at `${LOG_DIR}/prompt.txt` with both buckets, in chronological order, in distinct sections (see template below).
5. **Subagent:** Runs Claude Code via the same script-owned one-shot invocation used in all modes: `scripts/run_acpx_attempt.sh` `cd`s into `${WORKTREE_DIR}` (the shared per-issue worktree) and runs `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"`. Same No-Fallback Policy applies. Continue-mode continuity comes from three sources: the checked-out `origin/${WORK_BRANCH}` contents, the prompt's "Past attempt summaries" and "Reviewer comments" sections, and the restored same-IID runtime subtree. Fresh-mode runs deliberately quarantine same-IID runtime residue before the new acpx invocation.
6. **Subagent:** After the attempt finishes (terminal status, any of done / blocked / failed; legacy no_changes is normalized to blocked), `scripts/summarize_attempt.sh` always writes `${SUMMARY_FILE}` locally. Successful `done` attempts also post that summary as a marked GitLab issue comment (`<!-- acpx_auto_tester:attempt-summary v2 attempt=NNN -->`) for future continue-mode context. Failure paths keep evidence local only and do not publish Wiki evidence.
7. **Subagent — MR rotation.** Continue mode does NOT reuse the previous attempt's merge request — and neither does fresh mode any more. Both modes now share the same rotation policy in `scripts/create_mr.sh`:
   - looks up all open MRs currently pointing at `${WORK_BRANCH}` (G6)
   - closes them without merging (G10) — the integration branch is untouched, the closed MRs remain in GitLab as historical record
   - creates a fresh MR for the new attempt with description that begins `Closes #<iid>` and includes `Supersedes !<old_mr_iid>` references so reviewers can trace the chain
   Every attempt — fresh or continue — therefore produces a distinct MR in GitLab. Reviewers see one MR per attempt. Only the latest MR is open; older ones are closed but still visible.

## Prompt template (continue mode)

`scripts/build_prompt.sh` produces `${LOG_DIR}/prompt.txt` with at minimum these sections, in this exact order:

```text
This is a CONTINUE-MODE re-run of GitLab issue #<iid>.

A prior attempt on this issue already ran, and a human reviewer requested
resume by applying the `continue` label. You are running inside the shared
per-issue git worktree at <worktree-dir> (reused across every attempt of
this IID). The dispatcher has prepared the worktree from the latest available
same-IID work branch or local prior-attempt branch, and it restores prior
files under <RESULT_BASENAME>/issue-<iid>/ so you can inspect them and
continue. Read what's already there, then continue or correct it according
to the past-attempt summaries and reviewer guidance below.

# Issue
Title: <issue title>

Description:
<issue description verbatim>

# Past attempt summaries (auto-posted by acpx_auto_tester)
<summary 1 body — full markdown including the marker comments>
<summary 2 body>
...

# Reviewer comments (everything else, chronological)
<reviewer note 1>
---
<reviewer note 2>
---
...

# Working environment
- Repository cwd:             <worktree-dir> (shared per-issue linked git worktree)
- Output directory:           <worktree-dir>/<RESULT_BASENAME>/issue-<iid>/hulat-spec-issue<iid>
- Hulat materials:            <worktree-dir>/hulat   (committed in <branch>/<dev-branch>, available in this worktree)
- Claude runtime config:      <worktree-dir>/.claude (committed in <branch>/<dev-branch>, available in this worktree)
- Knowledge base:             <worktree-dir>/<DATA_BASENAME> (committed in <branch>/<dev-branch>, available in this worktree)
- Working branch (local):     attempt-local branch in this worktree, will be force-pushed to origin/<work-branch>
- Integration branch:         <branch>

`<RESULT_BASENAME>` and `<DATA_BASENAME>` default to `ifp-result` / `ifp-data` and are overridden per-project by the `result_basename` / `data_basename` trigger fields (see `trigger_command.md`); `build_prompt.sh` substitutes the live values when rendering this template.

# Rules
- Work only on this issue.
- Place spec / report / artifact output under the output directory only.
- Modify content under <worktree-dir> only. Do NOT write outside this worktree.
- Treat `hulat/`, `.claude/`, and `<DATA_BASENAME>/` as shared repository content. Change them only when the issue genuinely requires it, and mention those changes in your final summary.
- The dispatcher's runtime state and other issues' subtrees live in the parent checkout's `<RESULT_BASENAME>/` and are NOT visible from inside this worktree — keep changes under your output directory unless a fix genuinely requires modifying the test team's shared content above.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did differently from the prior run.
```

In fresh mode the prompt looks similar but omits the "Past attempt summaries" and "Reviewer comments" sections and uses a fresh-mode preamble.

## What if there are no reviewer comments?

If continue mode is requested but `G1b` returns zero non-system notes that are not auto-summaries, the reviewer flipped the label without leaving guidance. In that case the dispatcher's `build_prompt.sh`:

- Builds the prompt with the reviewer-comments section saying `(no reviewer comments — please review the prior attempt summaries above plus the existing diff and decide whether the work is acceptable as-is)`.
- Continues normally; the dispatcher records `no_reviewer_comments=true` in the current-attempt state for operator awareness.

The agent MUST NOT block, abort, or refuse to run just because reviewer comments are missing.

## What if there are no prior attempt summaries either?

This is unusual — it means continue mode triggered on an issue that has no `acpx_auto_tester:attempt-summary` or legacy pre-rename summary notes from past attempts. Typical causes:

- The label was flipped to `continue` before any prior attempt actually ran.
- All prior attempts ran on an older deployment that never posted summaries.

In this case the prompt's "Past attempt summaries" section says `(no prior attempt summaries found — this is unusual; treat the issue branch's existing commits as authoritative for prior work)`. The agent still runs.

`mode_downgraded_from`: if continue mode was requested but `prepare_attempt.sh` could not find `origin/${WORK_BRANCH}` on the remote, it downgrades to fresh mode. The dispatcher records `mode_downgraded_from="continue"` and `mode_actual="fresh"` in `${ATTEMPT_STATE_FILE}` so the operator can see the downgrade happened. This is the only documented exception to the No-Fallback Policy for continue mode.
