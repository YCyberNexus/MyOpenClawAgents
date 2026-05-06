# Path Layout (Prepared Worker)

All paths are derived in `scripts/env_paths.sh`; the dispatcher prepares them before worker spawn. With `PREPARED_WORKER=1`, `env_paths.sh` fails if required directories are missing.

## Disk Layout

```
/data/${PROJECT}/                                         <- main git repo, cloned/fetched by dispatcher only
/data/openclaw_work/${PROJECT}/
    openclaw_state/
        campaign_state.json
        campaign.lock
        claims.json
    openclaw_log/
        dispatcher/
            reconcile-<ts>.json
    issues/
        issue-${ISSUE_IID}/
            state.json
            handoff.json                                  <- dispatcher-created prepared worker contract
            worktree/                                     <- dispatcher-created git worktree
                hulat -> ${HULAT_DIR}
                .claude/
                ...repo files...
            log/
                attempt-001/
                    prompt.txt                            <- dispatcher-created
                    subagent_task.md                      <- dispatcher-created self-contained command
                    claude_result.txt
                    acpx_raw.log
                    git_status.txt
                    git_diff.patch
                    wiki_artifacts.md
                    wiki_artifact_links.md
                    wiki_artifact_responses.jsonl
            attempt_state.json
            summary.md
```

## Variables

| Variable | Value | Notes |
| --- | --- | --- |
| `REPO_PATH` | `/data/${PROJECT}` | Main repo; worker must not clone/fetch or edit its working tree. |
| `WORK_ROOT` | `/data/openclaw_work/${PROJECT}` | Agent scratch root outside the repo. |
| `ISSUE_ROOT` | `${WORK_ROOT}/issues/issue-${ISSUE_IID}` | Prepared issue subtree. |
| `ISSUE_STATE_FILE` | `${ISSUE_ROOT}/state.json` | Cross-attempt issue state. |
| `WORK_BRANCH` | `issue/${ISSUE_IID}-auto-fix` | Single remote branch per issue. |
| `ATTEMPT_NUMBER_PADDED` | e.g. `001` | Derived from dispatcher-allocated `ATTEMPT_NUMBER`. |
| `ATTEMPT_DIR` | `${ISSUE_ROOT}` | Compatibility alias. |
| `WORKTREE_DIR` | `${ATTEMPT_DIR}/worktree` | Claude Code cwd, prepared by dispatcher. |
| `LOG_DIR` | `${ATTEMPT_DIR}/log/attempt-${ATTEMPT_NUMBER_PADDED}` | Current attempt logs, prepared by dispatcher. |
| `ATTEMPT_STATE_FILE` | `${ATTEMPT_DIR}/attempt_state.json` | Current attempt metadata. |
| `SUMMARY_FILE` | `${ATTEMPT_DIR}/summary.md` | Latest summary mirror. |
| `LOCAL_ATTEMPT_BRANCH` | `${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}` | Local branch force-pushed to `${WORK_BRANCH}`. |

## Hard Rules

1. The dispatcher owns repo sync, worktree replacement, `hulat` symlink creation, `.claude` copy, prompt generation, `handoff.json`, and `subagent_task.md`.
2. The prepared worker must not create or repair missing preparation artifacts. Missing prepared paths are `blocked`.
3. All agent-owned logs/state/summaries live under `${ISSUE_ROOT}`, never inside `${WORKTREE_DIR}`.
4. The only local-only worktree content allowed is `hulat` and `.claude`; both are git-excluded and rejected by leak guards.
5. Strategy A remains: one remote branch per issue (`${WORK_BRANCH}`), force-updated from per-attempt local branches.
6. Claude Code is invoked one-shot with the dispatcher-created `${LOG_DIR}/prompt.txt`; persistent/named acpx sessions are forbidden.
7. Fresh worktrees are based on `origin/${DEV_BRANCH}`; continue worktrees are based on `origin/${WORK_BRANCH}` when present, otherwise dispatcher preparation may downgrade to fresh.
