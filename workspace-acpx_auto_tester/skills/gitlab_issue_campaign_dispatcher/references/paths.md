# Path Layout

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline. The same `env_paths.sh` is used by both the dispatcher (always derives dispatcher-level paths) and the subagent (also derives per-issue + attempt-level paths when `ISSUE_IID` and `ATTEMPT_NUMBER` are set).

## Disk layout

Workspace-level overview lives in [`AGENTS.md`](../../../AGENTS.md) §Disk State Layout.

```
/data/${PROJECT}/                                         ← main git repo (host of worktrees)
/data/openclaw_work/${PROJECT}/                           ← all agent-owned files (OUTSIDE the repo)
    openclaw_state/
        campaign_state.json                               ← campaign-level cache (NOT source of truth)
        campaign.lock                                     ← flock target
    openclaw_log/
        dispatcher/
            reconcile-<ts>.json                           ← reconciliation evidence files
    issues/
        issue-<iid>/                                      ← per-issue subtree, written by dispatcher prep + subagent
            state.json                                    (cross-attempt)
            attempt_state.json                            (current attempt; overwritten each attempt)
            worktree/                                     ← acpx cwd; replaced every attempt
                hulat → ${HULAT_DIR}                      (symlink, .git/info/exclude'd)
                .claude/                                  (copy of ${HULAT_DIR}/ifp-hulat/.claude, .git/info/exclude'd)
                ...repo files...
            log/
                attempt-001/                              ← preserved logs per attempt
                    prompt.txt
                    claude_result.txt
                    acpx_raw.log
                    git_status.txt
                    git_diff.patch
                    wiki_artifacts.md
                    wiki_artifact_links.md
                    wiki_artifact_responses.jsonl
                attempt-002/
                    ...
            summary.md                                    (latest summary; mirror of GitLab issue comment)
    locks/
        repo.lock                                         (flock target for prepare_attempt.sh)
```

## Variables exported by env_paths.sh

### Dispatcher-level (always exported when env_paths.sh is sourced)

| Variable                | Value                                                | Purpose                                                          |
| ----------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `REPO_PATH`             | `/data/${PROJECT}`                                   | main git repo, hosts worktrees. Agent never edits its working tree. |
| `WORK_ROOT`             | `/data/openclaw_work/${PROJECT}`                     | all agent-owned files. **Outside** the repo.                     |
| `STATE_DIR`             | `${WORK_ROOT}/openclaw_state`                        | campaign-level state ONLY.                                       |
| `CAMPAIGN_STATE_FILE`   | `${STATE_DIR}/campaign_state.json`                   | campaign progress cache.                                         |
| `LOG_ROOT`              | `${WORK_ROOT}/openclaw_log`                          | log subtree root.                                                |
| `DISPATCHER_LOG_DIR`    | `${LOG_ROOT}/dispatcher`                             | `reconcile-<ts>.json` evidence files.                            |
| `ISSUES_ROOT`           | `${WORK_ROOT}/issues`                                | per-issue subtrees.                                              |
| `LOCK_FILE`             | `${STATE_DIR}/campaign.lock`                         | flock target.                                                    |

To find a specific issue's state file from dispatcher code, use the helper:

```bash
ISSUE_STATE="$(issue_state_file_for "${IID}")"
# → /data/openclaw_work/${PROJECT}/issues/issue-${IID}/state.json
```

### Per-issue + attempt-level (exported only when `ISSUE_IID` is in env)

When `ISSUE_IID` is set, `env_paths.sh` requires `ATTEMPT_NUMBER` and additionally exports:

| Variable                  | Value                                                            | Notes                                                          |
| ------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------- |
| `ISSUE_ROOT`              | `${ISSUES_ROOT}/issue-${ISSUE_IID}`                              | this issue's full subtree                                      |
| `ISSUE_STATE_FILE`        | `${ISSUE_ROOT}/state.json`                                       | cross-attempt per-issue state                                  |
| `WORK_BRANCH`             | `issue/${ISSUE_IID}-auto-fix`                                    | the SINGLE remote branch (Strategy A)                          |
| `ATTEMPT_NUMBER_PADDED`   | e.g. "001"                                                       | zero-padded for labels, MR titles, comments, local branches    |
| `ATTEMPT_DIR`             | `${ISSUE_ROOT}`                                                  | compatibility alias; no per-attempt subdirectory exists        |
| `WORKTREE_DIR`            | `${ATTEMPT_DIR}/worktree`                                        | acpx cwd (created by `prepare_attempt.sh`)                     |
| `ISSUE_LOG_ROOT`          | `${ATTEMPT_DIR}/log`                                             | parent of per-attempt log directories                          |
| `LOG_DIR`                 | `${ISSUE_LOG_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}`             | current-attempt log files; preserved after the attempt          |
| `ATTEMPT_STATE_FILE`      | `${ATTEMPT_DIR}/attempt_state.json`                              | current-attempt metadata; overwritten each attempt             |
| `SUMMARY_FILE`            | `${ATTEMPT_DIR}/summary.md`                                      | latest mirror of GitLab issue summary comment                  |
| `LOCAL_ATTEMPT_BRANCH`    | `${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}`                     | per-attempt local branch (force-pushed to `${WORK_BRANCH}`)    |

`ATTEMPT_NUMBER` itself comes from the dispatcher: `scripts/allocate_attempt.sh` increments `attempts_total` in the per-issue state file and prints the new number. The dispatcher passes that number through to all later prep scripts AND embeds it into the rendered subagent prompt — `env_paths.sh` refuses to load if `ATTEMPT_NUMBER` is missing while `ISSUE_IID` is set.

## Hard rules

1. `REPO_PATH`'s **working tree** is never edited. The agent uses `git worktree add` to create the issue worktree at `${WORKTREE_DIR}`, replacing it at the start of each attempt.
2. All agent-owned files (logs, prompts, state, summaries) live under `${ISSUE_ROOT}` for per-issue work, and under `${STATE_DIR}` / `${LOG_ROOT}` for campaign-level work. None of them go inside `${WORKTREE_DIR}`. The only local-only non-repo content allowed in the worktree is the `hulat` symlink and `.claude` runtime config; leak guards (`stage_and_guard.sh`, `post_push_verify.sh`) keep both out of commits.
3. **`hulat_dir` is shared, read-only, single source.** Each attempt creates a symlink at `${WORKTREE_DIR}/hulat` pointing to `${HULAT_DIR}`. `hulat` is excluded from the worktree's git via `.git/info/exclude` and explicitly rejected by both leak guards. Do NOT modify anything under `${HULAT_DIR}` from inside an attempt.
4. Claude Code runtime config is the only copied Hulat material: `${HULAT_DIR}/ifp-hulat/.claude` is copied to `${WORKTREE_DIR}/.claude` before `acpx` runs. `.claude` is local-only, excluded from git, and rejected by both leak guards.
5. There is no `${ISSUE_ROOT}/attempts/` directory. Each attempt replaces `${WORKTREE_DIR}`, recreates only its own `${LOG_DIR}` (`log/attempt-NNN/`), overwrites `${ATTEMPT_STATE_FILE}`, and updates `${SUMMARY_FILE}`. Historical logs are preserved under `${ISSUE_LOG_ROOT}/attempt-NNN/`; historical summaries are preserved as GitLab issue notes.
6. Strategy A: there is exactly ONE remote branch per issue (`${WORK_BRANCH}`). Each attempt force-pushes to it. Local per-attempt branches (`${LOCAL_ATTEMPT_BRANCH}`) are kept in `${REPO_PATH}/.git` for audit.
7. Claude Code is invoked one-shot per attempt with `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` from inside `${WORKTREE_DIR}`. Persistent / named acpx sessions (`-s`) are forbidden — they do not terminate cleanly under the non-interactive scheduler. Cross-attempt continuity comes from the prompt itself (past attempt summaries + reviewer comments in continue mode), not from any shared Claude session.
8. Two-branch model. `${BRANCH}` (typically `master`) is the **integration / target** branch — MRs are opened against it; spec output accumulates here. `${DEV_BRANCH}` (typically `dev`) is the **clean baseline** — fresh-mode worktrees check out from `origin/${DEV_BRANCH}` so Claude's worktree does NOT contain past issues' spec output. Continue mode bases on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${DEV_BRANCH}`.
9. The OLD per-issue location `${STATE_DIR}/issues/issue-<iid>.json` is gone. The new path is `${ISSUES_ROOT}/issue-<iid>/state.json`. Old files, if any, should be migrated by the operator (the agent does not auto-migrate).

## Core artifacts in `${LOG_DIR}`

By the end of each Claude run, these MUST exist:

- `prompt.txt`           — the prompt fed to `acpx claude exec -f`
- `claude_result.txt`    — stdout from acpx
- `acpx_raw.log`         — stderr from acpx
- `git_status.txt`       — `git status --porcelain` after the Claude run
- `git_diff.patch`       — `git diff` after the Claude run

After post-push verification succeeds and before MR creation, these are auto-created:

- `wiki_artifacts.md` — issue note body linking project Wiki pages for attempt evidence
- `wiki_artifact_links.md` — generated list of Wiki links used in the issue note
- `wiki_artifact_responses.jsonl` — raw `projects/:id/wikis` create/update responses

When a new MR is created (rather than an existing fresh-mode MR being reused), this is also auto-created:

- `mr_description.md` — body of the merge request

These files NEVER go into the work branch — they live under this attempt's `${LOG_DIR}`.

`scripts/upload_attempt_artifacts.sh` publishes the required `prompt.txt` and `claude_result.txt`, plus the first `report.html` found anywhere under `${WORKTREE_DIR}` when present, to project Wiki pages under `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/`. If no `report.html` exists under the worktree, no report Wiki page is published.
