# Path Layout (Dispatcher)

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline.

## Disk layout

Workspace-level overview lives in [`AGENTS.md`](../../../AGENTS.md) §Disk State Layout. Full per-issue tree is in [`../../gitlab_single_issue_executor/references/paths.md`](../../gitlab_single_issue_executor/references/paths.md). Dispatcher-relevant slice:

```
/data/openclaw_work/${PROJECT}/
    openclaw_state/
        campaign_state.json                        ← campaign-level cache (NOT source of truth)
        campaign.lock                              ← flock target
        claims.json                                ← short-lived preflight claims
    openclaw_log/
        dispatcher/
            reconcile-<ts>.json                    ← reconciliation evidence files
    issues/
        issue-<iid>/
            state.json                             ← per-issue cache, prepared by dispatcher/finalized by worker
            handoff.json                           ← prepared worker handoff
            worktree/                              ← dispatcher-created git worktree
            log/attempt-NNN/
                prompt.txt                         ← dispatcher-created Claude prompt
                subagent_task.md                   ← self-contained worker command
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
| `ISSUES_ROOT`           | `${WORK_ROOT}/issues`                                | per-issue subtrees prepared by the dispatcher.                    |
| `LOCK_FILE`             | `${STATE_DIR}/campaign.lock`                         | flock target.                                                    |

To find a specific issue's state file, use the helper:

```bash
ISSUE_STATE="$(issue_state_file_for "${IID}")"
# → /data/openclaw_work/${PROJECT}/issues/issue-${IID}/state.json
```

## Hard rules (dispatcher-specific)

Workspace-wide invariants (REPO_PATH untouched, WORK_ROOT outside repo, hulat_dir shared read-only) live in [`AGENTS.md`](../../../AGENTS.md) §Disk State Layout. Dispatcher-specific:

1. Per-issue state files live at `${ISSUES_ROOT}/issue-<iid>/state.json` (use `issue_state_file_for` helper). The OLD location `${STATE_DIR}/issues/issue-<iid>.json` is gone — do NOT read or write there.
2. `reconcile-<ts>.json` evidence files stay at `${DISPATCHER_LOG_DIR}/`. They are dispatcher-global, NOT per-issue.
3. The dispatcher is the only role that touches `hulat_dir`, and only to create `${WORKTREE_DIR}/hulat` and copy `${HULAT_DIR}/ifp-hulat/.claude` into the prepared worktree. The worker treats both as already prepared and local-only.
4. The dispatcher writes `${ISSUE_ROOT}/handoff.json` and `${LOG_DIR}/subagent_task.md` before spawning the worker. The worker must not rebuild either file.
