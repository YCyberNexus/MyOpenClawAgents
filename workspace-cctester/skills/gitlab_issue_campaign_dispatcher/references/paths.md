# Path Layout (Dispatcher)

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline.

## Disk layout (SKILL_VERSION 2026-04-29.2+)

```
/data/${PROJECT}/                                  ← main git repo (hosts worktrees; agent never edits its working tree directly)
/data/openclaw_work/${PROJECT}/                    ← all agent-owned files, OUTSIDE the repo
    openclaw_state/
        campaign_state.json                        ← campaign-level cache (NOT source of truth)
        campaign.lock                              ← flock target
    openclaw_log/
        dispatcher/
            reconcile-<ts>.json                    ← reconciliation evidence files
    issues/
        issue-<iid>/                               ← per-issue subtree, owned by executor
            state.json
            worktree/                              ← git worktree, Claude Code's cwd; replaced every attempt
            log/
                attempt-001/                       ← logs for attempt 001, preserved
                attempt-002/                       ← logs for attempt 002, preserved
            attempt_state.json                     ← current attempt state; overwritten every attempt
            summary.md                             ← latest summary mirror
```

## Variables

| Variable                | Value                                                | Owner / purpose                                                  |
| ----------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `REPO_PATH`             | `/data/${PROJECT}`                                   | main git repo, hosts worktrees. Agent never edits its working tree. |
| `WORK_ROOT`             | `/data/openclaw_work/${PROJECT}`                     | all agent-owned files. **Outside** the repo.                     |
| `STATE_DIR`             | `${WORK_ROOT}/openclaw_state`                        | campaign-level state ONLY. No more per-issue files here.         |
| `CAMPAIGN_STATE_FILE`   | `${STATE_DIR}/campaign_state.json`                   | campaign progress cache.                                         |
| `LOG_ROOT`              | `${WORK_ROOT}/openclaw_log`                          | log subtree root.                                                |
| `DISPATCHER_LOG_DIR`    | `${LOG_ROOT}/dispatcher`                             | `reconcile-<ts>.json` evidence files.                            |
| `ISSUES_ROOT`           | `${WORK_ROOT}/issues`                                | per-issue subtrees managed by the executor.                      |
| `LOCK_FILE`             | `${STATE_DIR}/campaign.lock`                         | flock target.                                                    |

To find a specific issue's state file, use the helper:

```bash
ISSUE_STATE="$(issue_state_file_for "${IID}")"
# → /data/openclaw_work/${PROJECT}/issues/issue-${IID}/state.json
```

## Hard rules

1. `REPO_PATH` is a git repo — only `git fetch`, `git worktree`, `git remote` operations on it. Never write any agent file under `REPO_PATH`. Never modify its working tree directly (the executor uses `git worktree` to spin off the issue worktree).
2. `WORK_ROOT` is outside the repo. This is what physically prevents `git add` from sweeping agent artifacts into a commit.
3. `hulat_dir` is **read-only configuration** that the executor symlinks into the issue worktree as `hulat`. The executor also copies the required Claude Code runtime config from `${HULAT_DIR}/ifp-hulat/.claude` to that worktree as local-only `.claude` before invoking `acpx`. The dispatcher never touches it.
4. Per-issue state files live at `${ISSUES_ROOT}/issue-<iid>/state.json` (use `issue_state_file_for` helper). The OLD location `${STATE_DIR}/issues/issue-<iid>.json` is gone — do NOT read or write there.
5. `reconcile-<ts>.json` evidence files stay at `${DISPATCHER_LOG_DIR}/`. They are dispatcher-global, NOT per-issue.
