# Path Layout (Executor)

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline.

## Disk layout (SKILL_VERSION 2026-04-25.1+)

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
            state.json                                    (cross-attempt)
            attempts/
                attempt-001/
                    worktree/                             ← Claude Code's cwd
                        _hulat → ${HULAT_DIR}             (symlink, .git/info/exclude'd)
                        .claude/                          (copy of ${HULAT_DIR}/ifp-hulat/.claude, .git/info/exclude'd)
                        ...repo files...
                    log/
                        prompt.txt
                        claude_result.txt
                        acpx_raw.log
                        git_status.txt
                        git_diff.patch
                    attempt_state.json                    (per-attempt)
                    summary.md                            (mirror of GitLab issue comment)
                attempt-002/
                    ...
```

## Variables exported by env_paths.sh

### Issue-level (always exported)

| Variable             | Value                                              | Notes                                                    |
| -------------------- | -------------------------------------------------- | -------------------------------------------------------- |
| `REPO_PATH`          | `/data/${PROJECT}`                                 | main git repo, hosts worktrees. Don't edit its working tree. |
| `WORK_ROOT`          | `/data/openclaw_work/${PROJECT}`                   | agent scratch root (outside repo)                        |
| `ISSUE_ROOT`         | `${WORK_ROOT}/issues/issue-${ISSUE_IID}`           | this issue's full subtree                                |
| `ISSUE_STATE_FILE`   | `${ISSUE_ROOT}/state.json`                         | cross-attempt per-issue state                            |
| `ATTEMPTS_DIR`       | `${ISSUE_ROOT}/attempts`                           | parent of all attempt-NNN dirs                           |
| `WORK_BRANCH`        | `issue/${ISSUE_IID}-auto-fix`                      | the SINGLE remote branch (Strategy A)                    |

### Attempt-level (set from `ATTEMPT_NUMBER` env var, which the trigger supplies; env_paths.sh does NOT auto-allocate)

| Variable                  | Value                                                            | Notes                                                          |
| ------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------- |
| `ATTEMPT_NUMBER`          | integer                                                          | 1-based                                                        |
| `ATTEMPT_NUMBER_PADDED`   | e.g. "001"                                                       | zero-padded for paths                                          |
| `ATTEMPT_DIR`             | `${ATTEMPTS_DIR}/attempt-${ATTEMPT_NUMBER_PADDED}`               |                                                                |
| `WORKTREE_DIR`            | `${ATTEMPT_DIR}/worktree`                                        | Claude Code's cwd (created by `prepare_attempt.sh`)            |
| `LOG_DIR`                 | `${ATTEMPT_DIR}/log`                                             | per-attempt log files                                          |
| `ATTEMPT_STATE_FILE`      | `${ATTEMPT_DIR}/attempt_state.json`                              | per-attempt metadata                                           |
| `SUMMARY_FILE`            | `${ATTEMPT_DIR}/summary.md`                                      | mirror of GitLab issue comment                                 |
| `LOCAL_ATTEMPT_BRANCH`    | `${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}`                     | per-attempt local branch (force-pushed to `${WORK_BRANCH}`)    |

## Hard rules

1. `REPO_PATH`'s **working tree** is never edited. The agent uses `git worktree add` to spin off a separate working tree (`${WORKTREE_DIR}`) per attempt.
2. All agent-owned files (logs, prompts, state, summaries) live under `${ISSUE_ROOT}`. None of them go inside `${WORKTREE_DIR}`. The only local-only non-repo content allowed in the worktree is the `_hulat` symlink and `.claude` runtime config described below; leak guards (`stage_and_guard.sh`, `post_push_verify.sh`) keep both out of commits.
3. **`hulat_dir` is shared, read-only, single source.** Each attempt creates a symlink at `${WORKTREE_DIR}/_hulat` pointing to `${HULAT_DIR}`. `_hulat` is excluded from the worktree's git via `.git/info/exclude` and explicitly rejected by both leak guards. Do NOT modify anything under `${HULAT_DIR}` from inside an attempt.
4. Claude Code runtime config is the only copied Hulat material: `${HULAT_DIR}/ifp-hulat/.claude` is copied to `${WORKTREE_DIR}/.claude` before `acpx` runs. `.claude` is local-only, excluded from git, and rejected by both leak guards.
5. Per-attempt isolation is **physical** — each attempt has its own worktree, its own logs, its own summary. Past attempts are preserved on disk for audit; never delete them.
6. Strategy A: there is exactly ONE remote branch per issue (`${WORK_BRANCH}`). Each attempt force-pushes to it. Local per-attempt branches (`${LOCAL_ATTEMPT_BRANCH}`) are kept in `${REPO_PATH}/.git` for audit.
7. Two-branch model. `${BRANCH}` (typically `master`) is the **integration / target** branch — MRs are opened against it; spec output accumulates here. `${DEV_BRANCH}` (typically `dev`) is the **clean baseline** — fresh-mode worktrees check out from `origin/${DEV_BRANCH}` so Claude's worktree does NOT contain past issues' spec output. Continue mode bases on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${DEV_BRANCH}`.

## Required artifacts in `${LOG_DIR}`

By the end of each attempt, these MUST exist:

- `prompt.txt`           — the prompt fed to `acpx claude exec -f`
- `claude_result.txt`    — stdout from acpx
- `acpx_raw.log`         — stderr from acpx
- `git_status.txt`       — `git status --porcelain` after the Claude run
- `git_diff.patch`       — `git diff` after the Claude run
- (auto-created) `mr_description.md` — body of the merge request

These files NEVER go into the work branch — they live under `${ATTEMPT_DIR}`.
