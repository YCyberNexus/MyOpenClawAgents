# Path Layout (Executor)

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline.

## Disk layout (SKILL_VERSION 2026-04-29.5+)

```
/data/${PROJECT}/                                         ← main git repo (host of worktrees)
/data/openclaw_work/${PROJECT}/
    openclaw_state/
        campaign_state.json                               (dispatcher's only state file)
        campaign.lock
    openclaw_log/
        dispatcher/
            reconcile-<ts>.json                           (dispatcher-global)
    issues/
        issue-${ISSUE_IID}/                               ← per-issue, owned by executor
            (Claude session root for acpx --cwd)
            state.json                                    (cross-attempt)
            worktree/                                     ← Claude Code's cwd; replaced every attempt
                _hulat → ${HULAT_DIR}                     (symlink, .git/info/exclude'd)
                .claude/                                  (copy of ${HULAT_DIR}/ifp-hulat/.claude, .git/info/exclude'd)
                ...repo files...
            log/
                attempt-001/                             ← logs for attempt 001, preserved
                    prompt.txt
                    claude_result.txt
                    acpx_raw.log
                    git_status.txt
                    git_diff.patch
                    wiki_artifacts.md                    (GitLab issue note body with Wiki links)
                    wiki_artifact_links.md               (generated list of Wiki links)
                    wiki_artifact_responses.jsonl        (raw GitLab Wiki API responses)
                attempt-002/                             ← logs for attempt 002, preserved
                    ...
            attempt_state.json                            (current attempt; overwritten every attempt)
            summary.md                                    (latest summary; mirror of GitLab issue comment)
```

## Variables exported by env_paths.sh

### Issue-level (always exported)

| Variable             | Value                                              | Notes                                                    |
| -------------------- | -------------------------------------------------- | -------------------------------------------------------- |
| `REPO_PATH`          | `/data/${PROJECT}`                                 | main git repo, hosts worktrees. Don't edit its working tree. |
| `WORK_ROOT`          | `/data/openclaw_work/${PROJECT}`                   | agent scratch root (outside repo)                        |
| `ISSUE_ROOT`         | `${WORK_ROOT}/issues/issue-${ISSUE_IID}`           | this issue's full subtree                                |
| `ISSUE_STATE_FILE`   | `${ISSUE_ROOT}/state.json`                         | cross-attempt per-issue state                            |
| `WORK_BRANCH`        | `issue/${ISSUE_IID}-auto-fix`                      | the SINGLE remote branch (Strategy A)                    |
| `CLAUDE_SESSION_NAME` | `issue-${PROJECT}-${ISSUE_IID}`                    | persistent Claude Code session name for this IID         |
| `CLAUDE_SESSION_DIR` | `${ISSUE_ROOT}`                                    | acpx `--cwd` / session root; persists across attempts    |

### Attempt-level (set from `ATTEMPT_NUMBER` env var, which the trigger supplies; env_paths.sh does NOT auto-allocate)

| Variable                  | Value                                                            | Notes                                                          |
| ------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------- |
| `ATTEMPT_NUMBER`          | integer                                                          | 1-based                                                        |
| `ATTEMPT_NUMBER_PADDED`   | e.g. "001"                                                       | zero-padded for labels, MR titles, comments, and local branches |
| `ATTEMPT_DIR`             | `${ISSUE_ROOT}`                                                  | compatibility alias; no per-attempt subdirectory exists        |
| `WORKTREE_DIR`            | `${ATTEMPT_DIR}/worktree`                                        | Claude Code's cwd (created by `prepare_attempt.sh`)            |
| `ISSUE_LOG_ROOT`          | `${ATTEMPT_DIR}/log`                                             | parent of per-attempt log directories                          |
| `LOG_DIR`                 | `${ISSUE_LOG_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}`             | current-attempt log files; preserved after the attempt          |
| `ATTEMPT_STATE_FILE`      | `${ATTEMPT_DIR}/attempt_state.json`                              | current-attempt metadata; overwritten each attempt             |
| `SUMMARY_FILE`            | `${ATTEMPT_DIR}/summary.md`                                      | latest mirror of GitLab issue summary comment                  |
| `LOCAL_ATTEMPT_BRANCH`    | `${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}`                     | per-attempt local branch (force-pushed to `${WORK_BRANCH}`)    |

## Hard rules

1. `REPO_PATH`'s **working tree** is never edited. The agent uses `git worktree add` to create the issue worktree at `${WORKTREE_DIR}`, replacing it at the start of each attempt.
2. All agent-owned files (logs, prompts, state, summaries) live under `${ISSUE_ROOT}`. None of them go inside `${WORKTREE_DIR}`. The only local-only non-repo content allowed in the worktree is the `_hulat` symlink and `.claude` runtime config described below; leak guards (`stage_and_guard.sh`, `post_push_verify.sh`) keep both out of commits.
3. **`hulat_dir` is shared, read-only, single source.** Each attempt creates a symlink at `${WORKTREE_DIR}/_hulat` pointing to `${HULAT_DIR}`. `_hulat` is excluded from the worktree's git via `.git/info/exclude` and explicitly rejected by both leak guards. Do NOT modify anything under `${HULAT_DIR}` from inside an attempt.
4. Claude Code runtime config is the only copied Hulat material: `${HULAT_DIR}/ifp-hulat/.claude` is copied to `${WORKTREE_DIR}/.claude` before `acpx` runs. `.claude` is local-only, excluded from git, and rejected by both leak guards.
5. There is no `${ISSUE_ROOT}/attempts/` directory. Each attempt replaces `${WORKTREE_DIR}`, recreates only its own `${LOG_DIR}` (`log/attempt-NNN/`), overwrites `${ATTEMPT_STATE_FILE}`, and updates `${SUMMARY_FILE}`. Historical logs are preserved under `${ISSUE_LOG_ROOT}/attempt-NNN/`; historical summaries are preserved as GitLab issue notes.
6. Strategy A: there is exactly ONE remote branch per issue (`${WORK_BRANCH}`). Each attempt force-pushes to it. Local per-attempt branches (`${LOCAL_ATTEMPT_BRANCH}`) are kept in `${REPO_PATH}/.git` for audit.
7. Claude Code session state is persistent per issue: create/use `${CLAUDE_SESSION_NAME}` under `${CLAUDE_SESSION_DIR}` and invoke Claude with `acpx --cwd "${CLAUDE_SESSION_DIR}" claude -s "${CLAUDE_SESSION_NAME}" ...`. Do not use the default acpx/Claude session or a session shared with another IID.
8. Two-branch model. `${BRANCH}` (typically `master`) is the **integration / target** branch — MRs are opened against it; spec output accumulates here. `${DEV_BRANCH}` (typically `dev`) is the **clean baseline** — fresh-mode worktrees check out from `origin/${DEV_BRANCH}` so Claude's worktree does NOT contain past issues' spec output. Continue mode bases on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${DEV_BRANCH}`.

## Core artifacts in `${LOG_DIR}`

By the end of each Claude run, these MUST exist:

- `prompt.txt`           — the prompt fed to the per-issue Claude session
- `claude_result.txt`    — stdout from acpx
- `acpx_raw.log`         — stderr from acpx
- `git_status.txt`       — `git status --porcelain` after the Claude run
- `git_diff.patch`       — `git diff` after the Claude run

When the per-issue Claude session is first created, the executor also writes `claude_session_new.txt` and `acpx_session_new.log` in that attempt's `${LOG_DIR}`.

After post-push verification succeeds and before MR creation, these are auto-created:

- `wiki_artifacts.md` — issue note body linking project Wiki pages for attempt evidence
- `wiki_artifact_links.md` — generated list of Wiki links used in the issue note
- `wiki_artifact_responses.jsonl` — raw `projects/:id/wikis` create/update responses

When a new MR is created (rather than an existing fresh-mode MR being reused), this is also auto-created:

- `mr_description.md` — body of the merge request

These files NEVER go into the work branch — they live under this attempt's `${LOG_DIR}`.

`scripts/upload_attempt_artifacts.sh` publishes the required `prompt.txt` and `claude_result.txt`, plus the first `report.html` found anywhere under `${WORKTREE_DIR}` when present, to project Wiki pages under `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/`. If no `report.html` exists under the worktree, no report Wiki page is published.
