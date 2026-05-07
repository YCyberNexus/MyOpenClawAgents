# Path Layout

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline. The same `env_paths.sh` is used by both the dispatcher (always derives dispatcher-level paths) and the subagent (also derives per-issue + attempt-level paths when `ISSUE_IID` and `ATTEMPT_NUMBER` are set).

## Disk layout

Workspace-level overview lives in [`AGENTS.md`](../../../AGENTS.md) §Disk State Layout.

The cloned project repo IS the agent's entire workspace. The test team commits `.claude/`, `hulat/`, and `ifp_data/` to the project's master + dev branches, so a fresh `git clone` already contains everything Claude Code needs at runtime. The agent's own state and per-issue worktrees live under `${REPO_PATH}/ifp_result/`, whose contents are gitignored on master + dev so the main worktree's `git status` stays clean.

```
/data/${PROJECT}/                                        ← ${REPO_PATH}; the cloned project repo
    .claude/                                             (in master+dev, test-team owned)
    hulat/                                               (in master+dev, test-team owned; was the legacy ${HULAT_DIR})
    ifp_data/                                            (in master+dev, test-team owned; knowledge base)
    ifp_result/                                          ← ${RESULT_ROOT}; gitignored content. Agent runtime workspace.
        _dispatcher/                                     ← campaign-level state + logs + locks
            campaign_state.json                          ← campaign-level cache (NOT source of truth)
            campaign.lock                                ← flock target for the orchestrator
            log/
                reconcile-<ts>.json                      ← reconciliation evidence files
            locks/
                repo.lock                                ← flock target for clone_or_pull / prepare_attempt
        issue-<iid>/                                     ← per-issue subtree
            state.json                                   (cross-attempt)
            attempt_state.json                           (current attempt; overwritten each attempt)
            worktree/                                    ← linked git worktree; acpx cwd. Replaced every attempt.
                .claude/                                 (already in the branch checkout; READ-ONLY)
                hulat/                                   (already in the branch checkout; READ-ONLY)
                ifp_data/                                (already in the branch checkout; READ-ONLY)
                ifp_result/                              (the branch's own placeholder; gitignored content)
                hulat-spec-issue<iid>/                   ← Claude Code's spec output for this issue (committed; lands in MR)
                ...other repo files...
            log/
                attempt-001/                             ← preserved logs per attempt
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
            summary.md                                   (latest summary; mirror of GitLab issue comment)
```

The first-time clone bootstrap order (handled by `scripts/clone_or_pull.sh`):

1. `git clone -b ${BRANCH}` into `${REPO_PATH}` (uses a tmpfs lock at `/tmp/acpx_auto_tester.clone.${PROJECT}.lock` since the in-repo lock dir does not exist yet).
2. `mkdir -p` the dispatcher subtree (`_dispatcher/`, `_dispatcher/log/`, `_dispatcher/locks/`) and `ifp_result/`.
3. Acquire the in-repo flock at `${RESULT_ROOT}/_dispatcher/locks/repo.lock` and run `git fetch --prune` + `git worktree prune`.

Subsequent ticks skip step 1 and go straight to step 3.

## Variables exported by env_paths.sh

### Dispatcher-level (always exported when env_paths.sh is sourced)

| Variable                | Value                                                | Purpose                                                          |
| ----------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `REPO_PATH`             | `/data/${PROJECT}`                                   | The cloned project repo. Hosts linked worktrees.                |
| `HULAT_DIR`             | `${REPO_PATH}/hulat`                                 | Derived (NOT a trigger input). Test-team-committed; READ-ONLY.  |
| `RESULT_ROOT`           | `${REPO_PATH}/ifp_result`                            | Agent runtime workspace root. Gitignored on master+dev.         |
| `WORK_ROOT`             | `${RESULT_ROOT}/_dispatcher`                         | Campaign-level agent state.                                     |
| `STATE_DIR`             | `${WORK_ROOT}`                                       | Campaign state file lives directly here (no further nesting).   |
| `CAMPAIGN_STATE_FILE`   | `${STATE_DIR}/campaign_state.json`                   | Campaign progress cache.                                         |
| `LOG_ROOT`              | `${WORK_ROOT}/log`                                   | Dispatcher log subtree root.                                    |
| `DISPATCHER_LOG_DIR`    | `${LOG_ROOT}`                                        | `reconcile-<ts>.json` evidence files. Same dir as LOG_ROOT.     |
| `ISSUES_ROOT`           | `${RESULT_ROOT}`                                     | Parent of `issue-<iid>/` subtrees.                              |
| `LOCK_FILE`             | `${STATE_DIR}/campaign.lock`                         | flock target.                                                    |

To find a specific issue's state file from dispatcher code, use the helper:

```bash
ISSUE_STATE="$(issue_state_file_for "${IID}")"
# → /data/${PROJECT}/ifp_result/issue-${IID}/state.json
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
| `WORKTREE_DIR`            | `${ATTEMPT_DIR}/worktree`                                        | acpx cwd (created by `prepare_attempt.sh`); a linked worktree   |
| `ISSUE_LOG_ROOT`          | `${ATTEMPT_DIR}/log`                                             | parent of per-attempt log directories                          |
| `LOG_DIR`                 | `${ISSUE_LOG_ROOT}/attempt-${ATTEMPT_NUMBER_PADDED}`             | current-attempt log files; preserved after the attempt          |
| `ATTEMPT_STATE_FILE`      | `${ATTEMPT_DIR}/attempt_state.json`                              | current-attempt metadata; overwritten each attempt             |
| `SUMMARY_FILE`            | `${ATTEMPT_DIR}/summary.md`                                      | latest mirror of GitLab issue summary comment                  |
| `LOCAL_ATTEMPT_BRANCH`    | `${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}`                     | per-attempt local branch (force-pushed to `${WORK_BRANCH}`)    |

`ATTEMPT_NUMBER` itself comes from the dispatcher: `scripts/allocate_attempt.sh` increments `attempts_total` in the per-issue state file and prints the new number. The dispatcher passes that number through to all later prep scripts AND embeds it into the rendered subagent prompt — `env_paths.sh` refuses to load if `ATTEMPT_NUMBER` is missing while `ISSUE_IID` is set.

## Hard rules

1. **`REPO_PATH`'s main working tree is never edited by the agent.** The agent uses `git worktree add` to create the issue worktree at `${WORKTREE_DIR}` (a linked worktree inside `${RESULT_ROOT}/issue-<iid>/`), replacing it at the start of each attempt. The main worktree at `${REPO_PATH}` remains on `${BRANCH}` and is touched only for `git fetch` / `git worktree add|remove|prune`.
2. **Agent runtime files live under `${RESULT_ROOT}` (= `${REPO_PATH}/ifp_result/`).** Both the dispatcher subtree (`_dispatcher/...`) and per-issue subtrees (`issue-<iid>/...`). The project's master + dev branches MUST gitignore the contents of `ifp_result/` so the main worktree's `git status` stays clean and a developer's `git add -A` cannot sweep agent artifacts into a commit. The presence of `ifp_result/` itself in the branch (as an empty placeholder) is fine; only its contents are ignored.
3. **`hulat/`, `.claude/`, and `ifp_data/` are READ-ONLY.** They are committed to master + dev by the test team. Each issue worktree's checkout already contains them — the agent does NOT symlink `hulat/` and does NOT copy `.claude/`. Treat them as configuration; the agent must not edit them. (Leak guards no longer special-case these directories — they are valid repo content.)
4. **Per-issue spec output goes to `${WORKTREE_DIR}/hulat-spec-issue<iid>/` only.** `build_prompt.sh` injects this rule into the Claude Code prompt. Multiple MRs into master never collide because each issue writes into a distinct subdirectory.
5. There is no `${ISSUE_ROOT}/attempts/` directory. Each attempt replaces `${WORKTREE_DIR}`, recreates only its own `${LOG_DIR}` (`log/attempt-NNN/`), overwrites `${ATTEMPT_STATE_FILE}`, and updates `${SUMMARY_FILE}`. Historical logs are preserved under `${ISSUE_LOG_ROOT}/attempt-NNN/`; historical summaries are preserved as GitLab issue notes.
6. Strategy A: there is exactly ONE remote branch per issue (`${WORK_BRANCH}`). Each attempt force-pushes to it. Local per-attempt branches (`${LOCAL_ATTEMPT_BRANCH}`) are kept in `${REPO_PATH}/.git` for audit.
7. Claude Code is invoked one-shot per attempt with `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` from inside `${WORKTREE_DIR}`. Persistent / named acpx sessions (`-s`) are forbidden — they do not terminate cleanly under the non-interactive scheduler. Cross-attempt continuity comes from the prompt itself (past attempt summaries + reviewer comments in continue mode), not from any shared Claude session.
8. Two-branch model. `${BRANCH}` (typically `master`) is the **integration / target** branch — MRs are opened against it; spec output accumulates here. `${DEV_BRANCH}` (typically `dev`) is the **clean baseline** — fresh-mode worktrees check out from `origin/${DEV_BRANCH}` so Claude's worktree does NOT contain past issues' spec output. Continue mode bases on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${DEV_BRANCH}`.
9. **Leak surface.** The leak guards (`stage_and_guard.sh`, `post_push_verify.sh`) reject staged paths matching `^ifp_result/_dispatcher/` (always) or `^ifp_result/issue-<N>/` where `<N> != ${ISSUE_IID}` (other-issue subtree). They do NOT reject `hulat/`, `.claude/`, or `ifp_data/` — those are tracked content owned by the test team. They do NOT reject the current issue's own `ifp_result/issue-<iid>/` if Claude somehow `git add -f`'d into it (rare in practice; `ifp_result/` is gitignored on every branch).
10. **One-time migration from the old out-of-repo layout.** Some deployments still have a `/data/openclaw_work/${PROJECT}/...` subtree from before the agent moved into `ifp_result/`. Operators should either move it once during deployment:
    - `mv /data/openclaw_work/<project>/openclaw_state/campaign_state.json /data/<project>/ifp_result/_dispatcher/campaign_state.json`
    - `mv /data/openclaw_work/<project>/openclaw_log/dispatcher/* /data/<project>/ifp_result/_dispatcher/log/`
    - `mv /data/openclaw_work/<project>/issues/* /data/<project>/ifp_result/`
    
    Or simply delete the old subtree and let reconciliation rebuild state from live GitLab labels.

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

`scripts/upload_attempt_artifacts.sh` publishes the required `prompt.txt` and `claude_result.txt`, plus the first `report.html` found anywhere under `${WORKTREE_DIR}` (excluding the test-team-committed `hulat/`, `.claude/`, `ifp_data/` and the gitignored `ifp_result/`), to project Wiki pages under `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/`. If no `report.html` exists under the worktree, no report Wiki page is published.
