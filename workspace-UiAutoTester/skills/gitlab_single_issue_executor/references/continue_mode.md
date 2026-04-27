# Continue Mode — Reviewer Contract and Prompt Construction

This page documents how human reviewers and the executor cooperate when an issue's earlier "done" was wrong (Claude Code returned without actually finishing the work).

## Reviewer's responsibility (the human side)

When you find an issue whose MR was created but the work is incomplete or wrong, the agent will not detect this on its own. Do these three things, in this order:

1. **Leave a comment on the issue describing what to do on the next run.**
   The comment is freeform — write whatever the next Claude Code run needs. Include any specific shell commands, file paths, env requirements, or "do not do X" cautions. A typical comment looks like:

   > Previous run did not actually execute the test. Please:
   > 1. Confirm `tests/login.robot` exists in the repo.
   > 2. Run `uv run robot --variable HEADLESS:True login.robot` and capture the report.
   > 3. If the report is green, commit the report file under `reports/` and update the existing MR.

   You can also paste failure logs, stack traces, screenshots — anything that helps Claude Code finish the job.

2. **Flip the issue's label from `done` to `continue`.**
   The agent only triggers continue mode on the `continue` label. Do not skip this step.

3. **(Optional) Leave the existing MR open.**
   In continue mode the executor reuses the same `issue/<iid>-auto-fix` branch, so the existing MR will pick up the new commits automatically. If you closed the previous MR by mistake, the executor will detect the branch is still present and continue on it.

That's it. The next dispatcher tick will pick up the issue and re-run.

## What the executor does on its side

In continue mode the executor:

1. Reads the issue (`E1` in `glab_commands.md`) for title, description, current labels.
2. Reads the issue notes / comments (`E1b`). It includes **all non-system notes** in chronological order; the latest reviewer comment is at the bottom. The executor does NOT filter or summarize them — Claude Code sees them verbatim.
3. Builds the Claude Code prompt using the template below.
4. Runs `acpx claude exec -f` exactly as in fresh mode (same No-Fallback Policy applies).

The executor does NOT try to extract specific commands out of the comments and run them itself in bash. That would be improvising outside the contract. The comments are passed to Claude Code, and Claude Code is the one that actually runs them — through its normal tool use, exactly the way it would in a fresh run.

## Prompt template (continue mode)

`scripts/build_prompt.sh` (or the equivalent inline construction in the executor) MUST produce `${LOG_DIR}/prompt.txt` containing at minimum these sections, in this exact order:

```text
This is a CONTINUE-MODE re-run of GitLab issue #<iid>. A prior run on this
same issue produced a merge request and was marked `done`, but a human
reviewer has determined the work was incomplete or incorrect. You are
restarting on the existing work branch `issue/<iid>-auto-fix`. The branch
already contains the prior run's commits.

Your first task: review what is already on this branch versus the
integration branch (`<branch>`). Then continue or correct the work
according to the reviewer's instructions below.

# Issue
Title: <issue title>

Description:
<issue description verbatim>

# Reviewer comments (chronological)
<note body 1>
---
<note body 2>
---
<note body N>

# Working environment
- Repo path: <REPO_PATH>
- Hulat materials: <HULAT_DIR>
- Working branch: <WORK_BRANCH>
- Integration branch: <BRANCH>

# Rules
- Work only on this issue.
- Modify content under <REPO_PATH> only. Never write outside the repo.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did differently from the
  prior run.
```

In fresh mode the prompt looks similar but omits the "Reviewer comments" section and the "CONTINUE-MODE re-run" preamble.

## What if there are no comments on the issue?

If the executor enters continue mode but `E1b` returns zero non-system notes, the reviewer made a mistake (flipped the label without leaving guidance). In that case the executor:

- Builds the prompt with the comments section saying `(no reviewer comments — please review the existing diff and decide whether the work is acceptable as-is)`.
- Continues normally.
- Records `mode_continue_no_comments=true` in the per-issue state for operator awareness.

The executor MUST NOT block, abort, or refuse to run just because comments are missing. The reviewer flipped the label intentionally; the agent honors that.

## What goes in SKILL.md vs here

- SKILL.md keeps only the **abstract rules**: continue mode is detected from labels, prompt MUST include comments, prompt construction is delegated here.
- This reference is the place to look for **what the prompt actually contains** and **what reviewers must do**.
- Specific shell commands like `uv run robot --variable HEADLESS:True login.robot` are NOT pinned anywhere in this skill. They live in the GitLab issue's reviewer comment, per issue, per run. That is by design.
