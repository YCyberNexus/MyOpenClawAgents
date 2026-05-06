# Continue Mode — Reviewer Contract and Prompt Construction

This page documents how human reviewers and the executor cooperate when an issue's earlier "done" was wrong (Claude Code returned without actually finishing the work).

## Reviewer's responsibility (the human side)

When you find an issue whose MR was created but the work is incomplete or wrong, the agent will not detect this on its own. Do these three things, in this order:

1. **Read the latest auto-posted attempt summary on the issue.** The agent posts a short comment after every attempt with the marker `<!-- cctester:attempt-summary v2 ... -->`. This tells you the attempt status, commit SHA when available, MR URL when available, changed-file count / preview, and the runner evidence path for full logs and diffs. For successful push-ready attempts, the agent also posts `<!-- cctester:attempt-wiki-artifacts v1 ... -->` before MR creation with links to the Wiki pages for prompt/result logs and optional report.
2. **Leave a comment on the issue describing what to do on the next run.** The comment is freeform — write whatever the next Claude Code run needs. Include any specific shell commands, file paths, env requirements, or "do not do X" cautions. A typical comment:

   > Previous run did not actually execute the test. Please:
   > 1. Confirm `tests/login.robot` exists in the repo.
   > 2. Run `uv run robot --variable HEADLESS:True login.robot` and capture the report.
   > 3. If the report is green, commit the report file under `reports/` and update the existing MR.

3. **Flip the issue's label from `done` / `pr` to `continue`.** The agent only triggers continue mode on the `continue` label.

That's it. The next dispatcher tick will pick the issue up and re-run.

## What the executor does on its side

In continue mode the executor:

1. Resolves a fresh attempt number (monotonically increasing) and replaces the git worktree at `${WORKTREE_DIR}` based on `origin/${WORK_BRANCH}` (the existing work-in-progress branch). Local `worktree/`, `attempt_state.json`, and `summary.md` are updated in place. Logs are written under `log/attempt-NNN/` and preserved; prior attempt summaries remain available as GitLab issue notes.
2. Reads the issue (`E1` in `glab_commands.md`) for title, description, current labels.
3. Reads the issue notes (`E1b`) and **partitions them in two buckets**:
   - **Past attempt summaries** — notes whose body contains `<!-- cctester:attempt-summary `. These were posted by the agent itself after previous attempts and contain compact status, commit / MR pointers, changed-file preview, and the runner evidence path.
   - **Reviewer comments** — every other non-system note except auto-posted Wiki artifact notes (`<!-- cctester:attempt-wiki-artifacts ... -->`). This is where humans write supplemental instructions.
4. Builds the Claude Code prompt with both buckets, in chronological order, in distinct sections (see template below).
5. Runs `acpx claude exec -f` exactly as in fresh mode. Same No-Fallback Policy applies.
6. After the attempt finishes (terminal status, any of done / no_changes / blocked / failed), `scripts/summarize_attempt.sh` posts a new summary comment to the issue, marked with `<!-- cctester:attempt-summary v2 attempt=NNN -->`. This becomes input for the next continue-mode run, if any.
7. **MR rotation.** Continue mode does NOT reuse the previous attempt's merge request. Instead, `scripts/create_mr.sh`:
   - looks up all open MRs currently pointing at `${WORK_BRANCH}` (E6)
   - closes them without merging (E10) — the integration branch is untouched, the closed MRs remain in GitLab as historical record
   - creates a fresh MR for the new attempt with description that begins `Closes #<iid>` and includes `Supersedes !<old_mr_iid>` references so reviewers can trace the chain
   This means each continue cycle produces a distinct MR in GitLab. Reviewers see one MR per attempt. Only the latest MR is open; older ones are closed but still visible.

The executor does NOT try to extract specific commands out of reviewer comments and run them itself in bash. The comments are passed to Claude Code, and Claude Code is what actually runs them — through its normal tool use, exactly like in a fresh run.

## Prompt template (continue mode)

`scripts/build_prompt.sh` produces `${LOG_DIR}/prompt.txt` with at minimum these sections, in this exact order:

```text
This is a CONTINUE-MODE re-run of GitLab issue #<iid>.

A prior run on this issue produced a merge request and was marked `done` + `pr`,
but a human reviewer has determined the work was incomplete or incorrect.
You are running inside a fresh git worktree at <worktree>, branched from
`origin/<work-branch>` (the work-in-progress branch from the prior run).
Read what's already there, then continue or correct it according to the
past-attempt summaries and reviewer guidance below.

# Issue
Title: <issue title>

Description:
<issue description verbatim>

# Past attempt summaries (auto-posted by cctester)
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
- Worktree (your cwd):        <worktree>
- Hulat materials (symlink):  <worktree>/hulat → <hulat_dir>
- Claude runtime config:      <worktree>/.claude (copied from <hulat_dir>/ifp-hulat/.claude; local-only)
- Working branch (local):     attempt-local branch in this worktree, will be force-pushed to origin/<work-branch>
- Integration branch:         <branch>

# Rules
- Work only on this issue.
- Modify content under <worktree> only. Do NOT write outside the worktree.
- Read configuration from <worktree>/hulat (the symlink); do not modify hulat materials — they are shared, read-only.
- Treat <worktree>/.claude as local Claude Code runtime config. Do not modify it or include it in issue output.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did differently from the prior run.
```

In fresh mode the prompt looks similar but omits the "Past attempt summaries" and "Reviewer comments" sections and uses a fresh-mode preamble.

## What if there are no reviewer comments?

If continue mode is requested but `E1b` returns zero non-system notes that are not auto-summaries, the reviewer flipped the label without leaving guidance. In that case the executor:

- Builds the prompt with the reviewer-comments section saying `(no reviewer comments — please review the prior attempt summaries above plus the existing diff and decide whether the work is acceptable as-is)`.
- Continues normally.
- Records `no_reviewer_comments=true` in the current-attempt state for operator awareness.

The executor MUST NOT block, abort, or refuse to run just because reviewer comments are missing.

## What if there are no prior attempt summaries either?

This is unusual — it means continue mode triggered on an issue that has no `cctester:attempt-summary` notes from past attempts. Typical causes:

- The label was flipped to `continue` before any prior attempt actually ran.
- All prior attempts ran on a deployment that predates SKILL_VERSION 2026-04-25.1 and never posted summaries.

In this case the prompt's "Past attempt summaries" section says `(no prior attempt summaries found — this is unusual; treat the issue branch's existing commits as authoritative for prior work)`. The executor still runs.

## What goes in SKILL.md vs here

- SKILL.md keeps the **abstract rules**: continue mode is detected from labels, prompt MUST include both buckets of notes, prompt construction is delegated here.
- This reference is the place to look for **what the prompt actually contains** and **what reviewers must do**.
- Specific shell commands like `uv run robot --variable HEADLESS:True login.robot` are NOT pinned anywhere in this skill. They live in the GitLab issue's reviewer comment, per issue, per run. That is by design.
