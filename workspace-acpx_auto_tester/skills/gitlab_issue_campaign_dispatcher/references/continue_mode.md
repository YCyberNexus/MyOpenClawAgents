# Continue Mode — Reviewer Contract and Prompt Construction

This page documents how human reviewers and the agent cooperate when an issue's earlier "done" was wrong (Claude Code returned without actually finishing the work). Both halves of the agent (the dispatcher's prep and the subagent's post-acpx flow) follow the rules below — `scripts/prepare_attempt.sh` and `scripts/build_prompt.sh` are run by the dispatcher; `scripts/create_mr.sh` is run by the subagent.

## Reviewer's responsibility (the human side)

When you find an issue whose MR was created but the work is incomplete or wrong, the agent will not detect this on its own. Do these three things, in this order:

1. **Read the latest auto-posted attempt summary on the issue.** The agent posts a short comment after every attempt with the marker `<!-- acpx_auto_tester:attempt-summary v2 ... -->`. This tells you the attempt status, commit SHA when available, MR URL when available, changed-file count / preview, and the runner evidence path for full logs and diffs. For successful push-ready attempts, the agent also posts `<!-- acpx_auto_tester:attempt-wiki-artifacts v1 ... -->` before MR creation with links to the Wiki pages for prompt/result logs and optional report. Continue mode also recognizes legacy pre-rename markers from earlier runs.
2. **Leave a comment on the issue describing what to do on the next run.** The comment is freeform — write whatever the next Claude Code run needs. Include file paths, env requirements, acceptance criteria, or "do not do X" cautions.
3. **Flip the issue's label from `done` / `pr` to `continue`.** The agent only triggers continue mode on the `continue` label.

The next dispatcher tick will pick the issue up and re-run.

## What the agent does on its side

In continue mode:

1. **Dispatcher prep:** Resolves a fresh attempt number (monotonically increasing) via `scripts/allocate_attempt.sh` and runs `ISSUE_MODE=continue scripts/prepare_attempt.sh` to replace the git worktree at `${WORKTREE_DIR}` based on `origin/${WORK_BRANCH}` (the existing work-in-progress branch). Local `worktree/`, `attempt_state.json`, and `summary.md` are updated in place. Logs are written under `log/attempt-NNN/` and preserved; prior attempt summaries remain available as GitLab issue notes.
2. **Dispatcher prep:** Reads the issue (`E1` in `glab_commands.md`) for title, description, current labels.
3. **Dispatcher prep:** Runs `scripts/build_prompt.sh` which reads the issue notes (`E1b`) and **partitions them in two buckets**:
   - **Past attempt summaries** — notes whose body contains `<!-- acpx_auto_tester:attempt-summary ` or the legacy pre-rename summary marker. These were posted by the agent itself after previous attempts and contain compact status, commit / MR pointers, changed-file preview, and the runner evidence path.
   - **Reviewer comments** — every other non-system note except auto-posted Wiki artifact notes (`<!-- acpx_auto_tester:attempt-wiki-artifacts ... -->`) and legacy pre-rename Wiki artifact notes. This is where humans write supplemental instructions.
4. **Dispatcher prep:** `build_prompt.sh` writes the Claude Code prompt at `${LOG_DIR}/prompt.txt` with both buckets, in chronological order, in distinct sections (see template below).
5. **Subagent:** Runs Claude Code via the same one-shot invocation used in fresh mode: `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` from `${WORKTREE_DIR}`. Same No-Fallback Policy applies. Cross-attempt continuity comes from the prompt's "Past attempt summaries" section, not from a persistent Claude session.
6. **Subagent:** After the attempt finishes (terminal status, any of done / no_changes / blocked / failed), `scripts/summarize_attempt.sh` posts a new summary comment to the issue, marked with `<!-- acpx_auto_tester:attempt-summary v2 attempt=NNN -->`. This becomes input for the next continue-mode run, if any.
7. **Subagent — MR rotation.** Continue mode does NOT reuse the previous attempt's merge request. Instead, `scripts/create_mr.sh`:
   - looks up all open MRs currently pointing at `${WORK_BRANCH}` (E6)
   - closes them without merging (E10) — the integration branch is untouched, the closed MRs remain in GitLab as historical record
   - creates a fresh MR for the new attempt with description that begins `Closes #<iid>` and includes `Supersedes !<old_mr_iid>` references so reviewers can trace the chain
   This means each continue cycle produces a distinct MR in GitLab. Reviewers see one MR per attempt. Only the latest MR is open; older ones are closed but still visible.

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
- Worktree (your cwd):        <worktree>
- Hulat materials:            <worktree>/hulat   (committed in <branch>/<dev-branch>, test-team owned, READ-ONLY)
- Claude runtime config:      <worktree>/.claude (committed in <branch>/<dev-branch>, test-team owned, READ-ONLY)
- Knowledge base:             <worktree>/ifp_data (committed in <branch>/<dev-branch>, test-team owned, READ-ONLY)
- Agent runtime workspace:    <worktree>/ifp_result (gitignored on <branch>/<dev-branch>; do NOT touch)
- Working branch (local):     attempt-local branch in this worktree, will be force-pushed to origin/<work-branch>
- Integration branch:         <branch>

# Rules
- Work only on this issue.
- Modify content under <worktree> only. Do NOT write outside the worktree.
- `hulat/`, `.claude/`, and `ifp_data/` are committed by the test team and are READ-ONLY references for you. Do NOT edit them.
- Do NOT touch the `ifp_result/` subtree. It is the agent runtime's workspace (gitignored); writing into it has no effect and pollutes the audit trail.
- Do not ask the user any questions. Make the best reasonable decisions.
- When you finish, summarize briefly what you did differently from the prior run.
```

In fresh mode the prompt looks similar but omits the "Past attempt summaries" and "Reviewer comments" sections and uses a fresh-mode preamble.

## What if there are no reviewer comments?

If continue mode is requested but `E1b` returns zero non-system notes that are not auto-summaries, the reviewer flipped the label without leaving guidance. In that case the dispatcher's `build_prompt.sh`:

- Builds the prompt with the reviewer-comments section saying `(no reviewer comments — please review the prior attempt summaries above plus the existing diff and decide whether the work is acceptable as-is)`.
- Continues normally; the dispatcher records `no_reviewer_comments=true` in the current-attempt state for operator awareness.

The agent MUST NOT block, abort, or refuse to run just because reviewer comments are missing.

## What if there are no prior attempt summaries either?

This is unusual — it means continue mode triggered on an issue that has no `acpx_auto_tester:attempt-summary` or legacy pre-rename summary notes from past attempts. Typical causes:

- The label was flipped to `continue` before any prior attempt actually ran.
- All prior attempts ran on an older deployment that never posted summaries.

In this case the prompt's "Past attempt summaries" section says `(no prior attempt summaries found — this is unusual; treat the issue branch's existing commits as authoritative for prior work)`. The agent still runs.

`mode_downgraded_from`: if continue mode was requested but `prepare_attempt.sh` could not find `origin/${WORK_BRANCH}` on the remote, it downgrades to fresh mode. The dispatcher records `mode_downgraded_from="continue"` and `mode_actual="fresh"` in `${ATTEMPT_STATE_FILE}` so the operator can see the downgrade happened. This is the only documented exception to the No-Fallback Policy for continue mode.
