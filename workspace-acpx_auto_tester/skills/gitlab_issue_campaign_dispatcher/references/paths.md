# Path Layout

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline. The same `env_paths.sh` is used by both the dispatcher (always derives dispatcher-level paths) and the subagent (also derives per-issue + attempt-level paths when `ISSUE_IID` and `ATTEMPT_NUMBER` are set).

## Disk layout

Workspace-level overview lives in [`AGENTS.md`](../../../AGENTS.md) §Disk State Layout.

The cloned project repo IS the agent's entire workspace. The test team commits `.claude/`, `hulat/`, and `${DATA_BASENAME}/` to the project's master + dev branches, so a fresh `git clone` already contains everything Claude Code needs at runtime; `prepare_attempt.sh` also refreshes those tracked shared config paths from latest `origin/${DEV_BRANCH}` before every attempt. Each IID gets ONE shared linked git worktree at `${RESULT_ROOT}/.worktrees/issue-<iid>/` (= `${WORKTREE_DIR}`); every attempt of that IID runs inside it (the path has no `-att-<NNN>` suffix). `prepare_attempt.sh` creates the worktree on attempt 1 via `git worktree add -B` and force-switches the checked-out branch in place on attempt N>1 after snapshotting `${RESULT_BASENAME}/issue-<iid>/`. Continue-mode runs restore that subtree into the active worktree for resume. Every non-continue entry path (`todo`, `retry`, `new`, `blocked`, trigger `require_labels`) archives the snapshot under `${WORKTREES_ROOT}/.preserved-attempts/` and quarantines any active same-IID runtime subtree that survived checkout before recreating empty current output/log directories, leaving the active worktree reset to the clean baseline. Same-IID attempts never run concurrently (the dispatcher's `pending_subagents` bookkeeping is the structural guarantee), so reusing one worktree per IID is safe. The parent checkout at `${REPO_PATH}` is shared by all worktrees as the object DB and `git fetch` target but is never mutated by an attempt. By default `${REPO_PARENT_PATH}=/data` and `${REPO_PATH}=/data/${PROJECT}`; the optional trigger field `repo_path` can set a different absolute clone parent, with the final repo root derived as `${repo_path}/${PROJECT}`. Runtime state/logs and each issue's committed output directory live under `${RESULT_ROOT}/`; the dispatcher's `.git/info/exclude` keeps untracked runtime files (including the entire `.worktrees/` subtree) out of `git add -A`, and `stage_and_guard.sh` force-adds only the current issue's output directory inside its worktree. There is no path-based reject — anything that ends up in the staged/MR diff is allowed through.

**Repo path override.** `repo_path` is forwarded to dispatcher scripts as `REPO_PARENT_PATH`. When omitted, `env_paths.sh` uses parent `/data` exactly as older deployments did. For example, `project=A` with `repo_path=/data/ifp1` derives final `${REPO_PATH}` as `/data/ifp1/A`. Non-default deployments must pass the same `repo_path` on every scheduled trigger and callback because the campaign state file itself lives under the derived path and cannot be discovered from disk before `env_paths.sh` runs. The value must be an absolute parent directory; `/`, dot segments, whitespace, and shell-unsafe characters outside `[A-Za-z0-9_./-]` are rejected.

**Per-project basename overrides.** The directory names `ifp-result` and `ifp-data` are defaults; they can be replaced per-project via the `result_basename` / `data_basename` trigger fields (carry-forward into `campaign_state.json`; see `trigger_command.md`). When set, `env_paths.sh` exports `RESULT_ROOT=${REPO_PATH}/${RESULT_BASENAME}` and `DATA_DIR=${REPO_PATH}/${DATA_BASENAME}`, and every downstream rule below — including `.git/info/exclude`, the executor prompt, and continue-mode template — picks up the override automatically. The path examples in this document use the defaults for readability.

```
${REPO_PATH}/                                            ← parent checkout (default /data/${PROJECT})
    .claude/                                             (in master+dev, test-team owned)
    hulat/                                               (in master+dev, test-team owned; was the legacy ${HULAT_DIR})
    ifp-data/                                            (in master+dev, test-team owned; knowledge base)
    ifp-result/                                          ← ${RESULT_ROOT}; agent runtime root
        _dispatcher/                                     ← campaign-level state + logs + locks
            campaign_state.json                          ← campaign-level cache (NOT source of truth)
            campaign.lock                                ← flock target for the orchestrator
            log/
                reconcile-<ts>.json                      ← reconciliation evidence files
            locks/
                repo.lock                                ← flock target for clone_or_pull / prepare_attempt
        issues/                                          ← ${ISSUES_ROOT}; parent of per-issue persistent subtrees
            issue-<iid>/                                 ← per-issue subtree (lives OUTSIDE worktree, so state survives worktree teardown)
                state.json                               (cross-attempt)
                attempt_state.json                       (current attempt; overwritten each attempt)
                summary.md                               (latest summary; mirror of GitLab issue comment)
        .worktrees/                                      ← ${WORKTREES_ROOT}; per-issue linked worktrees (one per IID)
            issue-<iid>/                                 ← ${WORKTREE_DIR}; acpx cwd; created on attempt 1 via
                                                            `git worktree add -B`, reused on attempt N>1 via in-place
                                                            `git checkout -B ${LOCAL_ATTEMPT_BRANCH} ${BASE_REF} --force`
                                                            (continue restores same-IID files; all other entry paths reset)
                .claude/ hulat/ ${DATA_BASENAME}/        (tracked config refreshed from origin/${DEV_BRANCH} every attempt)
                ${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/   ← ${OUTPUT_DIR}; Claude Code output (committed; lands in MR; shared across attempts of this IID)
                ${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/         ← ${LOG_DIR}; STILL attempt-scoped inside the shared worktree
                    prompt.txt                                          ← force-added by stage_and_guard.sh (lands in MR)
                    claude_result.txt                                   ← force-added by stage_and_guard.sh (lands in MR)
                    acpx_raw.log                                        ← locally ignored; removed with worktree
                    git_status.txt                                      ← locally ignored; removed with worktree
                    git_diff.patch                                      ← locally ignored; removed with worktree
                    wiki_artifacts.md                                   ← locally ignored; removed with worktree
                    wiki_artifact_links.md                              ← locally ignored; removed with worktree
                    wiki_artifact_responses.jsonl                       ← locally ignored; removed with worktree
                    mr_description.md                                   ← locally ignored; removed with worktree
```

The first-time clone bootstrap order (handled by `scripts/clone_or_pull.sh`):

1. `git clone -b ${BRANCH}` into `${REPO_PATH}` (uses a tmpfs lock at `/tmp/acpx_auto_tester_ifp.clone.${PROJECT}.lock` since the in-repo lock dir does not exist yet).
2. `mkdir -p` the dispatcher subtree (`_dispatcher/`, `_dispatcher/log/`, `_dispatcher/locks/`) and `${RESULT_ROOT}/`.
3. Acquire the in-repo flock at `${RESULT_ROOT}/_dispatcher/locks/repo.lock` and run `git fetch --prune` + `git worktree prune` (the prune is only for legacy linked-worktree metadata).
4. Idempotently append `/<basename RESULT_ROOT>/` (e.g. `/${RESULT_BASENAME}/`) to `${REPO_PATH}/.git/info/exclude`. This is the agent's local-only equivalent of a `.gitignore` rule; `.git/info/exclude` is never committed/pushed, so per-project runtime-root names (`ifp-result/`, `<project>-result/`, …) are handled here without requiring the test team to maintain a tracked `.gitignore` rule on master + dev. The current issue's `${OUTPUT_DIR}` is force-added by `stage_and_guard.sh` (which bypasses `.gitignore` and `info/exclude` alike), so the single committable path stays committable.

Subsequent ticks skip step 1, run steps 2–4 (steps 2 and 4 are idempotent), and go straight through step 3.

## Variables exported by env_paths.sh

### Dispatcher-level (always exported when env_paths.sh is sourced)

| Variable                | Value                                                | Purpose                                                          |
| ----------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `REPO_PARENT_PATH`      | `/data` (default) or trigger `repo_path`             | Parent directory under which the project repo is cloned.        |
| `REPO_PATH`             | `${REPO_PARENT_PATH}/${PROJECT}`                     | The cloned project repo (parent checkout; shared object DB / `git fetch` target). NOT acpx cwd — that is `${WORKTREE_DIR}`. |
| `HULAT_DIR`             | `${REPO_PATH}/hulat`                                 | Derived (NOT a trigger input). Test-team-committed.             |
| `RESULT_BASENAME`       | `ifp-result` (default) or trigger override           | Basename of the agent runtime root. Override via trigger field `result_basename`. |
| `DATA_BASENAME`         | `ifp-data` (default) or trigger override             | Basename of the test-team knowledge dir. Override via trigger field `data_basename`. |
| `RESULT_ROOT`           | `${REPO_PATH}/${RESULT_BASENAME}`                    | Agent runtime workspace + issue output root.                    |
| `DATA_DIR`              | `${REPO_PATH}/${DATA_BASENAME}`                      | Test-team-committed knowledge directory (agent never writes here, but the prompt names this path). |
| `WORK_ROOT`             | `${RESULT_ROOT}/_dispatcher`                         | Campaign-level agent state.                                     |
| `STATE_DIR`             | `${WORK_ROOT}`                                       | Campaign state file lives directly here (no further nesting).   |
| `CAMPAIGN_STATE_FILE`   | `${STATE_DIR}/campaign_state.json`                   | Campaign progress cache.                                         |
| `LOG_ROOT`              | `${WORK_ROOT}/log`                                   | Dispatcher log subtree root.                                    |
| `DISPATCHER_LOG_DIR`    | `${LOG_ROOT}`                                        | `reconcile-<ts>.json` evidence files. Same dir as LOG_ROOT.     |
| `ISSUES_ROOT`           | `${RESULT_ROOT}/issues`                              | Parent of `issue-<iid>/` subtrees (groups them under one folder so they don't visually mix with `_dispatcher/` and `.worktrees/`). |
| `LOCK_FILE`             | `${STATE_DIR}/campaign.lock`                         | flock target.                                                    |
| `WORKTREES_ROOT`        | `${RESULT_ROOT}/.worktrees`                          | Parent of every per-issue linked worktree (one per IID).        |

To find a specific issue's state file from dispatcher code, use the helper:

```bash
ISSUE_STATE="$(issue_state_file_for "${IID}")"
# → ${RESULT_ROOT}/issues/issue-${IID}/state.json
# (or ${REPO_PARENT_PATH}/${PROJECT}/${RESULT_BASENAME}/issues/issue-${IID}/state.json when repo_path is set)
```

### Per-issue + attempt-level (exported only when `ISSUE_IID` is in env)

When `ISSUE_IID` is set, `env_paths.sh` requires `ATTEMPT_NUMBER` and additionally exports:

| Variable                  | Value                                                                                | Notes                                                          |
| ------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| `ISSUE_ROOT`              | `${ISSUES_ROOT}/issue-${ISSUE_IID}`                                                  | this issue's full subtree (under parent `${RESULT_ROOT}`, NOT inside the worktree) |
| `ISSUE_STATE_FILE`        | `${ISSUE_ROOT}/state.json`                                                           | cross-attempt per-issue state                                  |
| `WORK_BRANCH`             | `issue/${ISSUE_IID}-auto-fix`                                                        | the SINGLE remote branch (Strategy A)                          |
| `ATTEMPT_NUMBER_PADDED`   | e.g. "001"                                                                           | zero-padded for labels, MR titles, comments, local branches    |
| `ATTEMPT_DIR`             | `${ISSUE_ROOT}`                                                                      | compatibility alias; per-attempt state and summary live directly under ISSUE_ROOT (logs moved into LOG_DIR inside the worktree) |
| `WORKTREE_DIR`            | `${WORKTREES_ROOT}/issue-${ISSUE_IID}`                                               | acpx cwd; SHARED per-issue linked git worktree (one per IID, reused across attempts; created/maintained by `prepare_attempt.sh`) |
| `OUTPUT_DIR`              | `${WORKTREE_DIR}/${RESULT_BASENAME}/issue-${ISSUE_IID}/hulat-spec-issue${ISSUE_IID}` | only committable spec result directory; lives INSIDE the shared worktree (shared across attempts of this IID) |
| `LOG_DIR`                 | `${WORKTREE_DIR}/${RESULT_BASENAME}/issue-${ISSUE_IID}/log/attempt-${ATTEMPT_NUMBER_PADDED}` | current-attempt log files INSIDE the shared worktree (still attempt-scoped so successive attempts don't overwrite each other); `prompt.txt` + `claude_result.txt` force-added into the MR diff, other files locally ignored and removed with the worktree |
| `ATTEMPT_STATE_FILE`      | `${ATTEMPT_DIR}/attempt_state.json`                                                  | current-attempt metadata; overwritten each attempt             |
| `SUMMARY_FILE`            | `${ATTEMPT_DIR}/summary.md`                                                          | latest local attempt summary; successful done attempts also post it as a GitLab issue comment |
| `LOCAL_ATTEMPT_BRANCH`    | `${WORK_BRANCH}-att${ATTEMPT_NUMBER_PADDED}`                                         | per-attempt local branch (force-pushed to `${WORK_BRANCH}`)    |

`ATTEMPT_NUMBER` itself comes from the dispatcher: `scripts/allocate_attempt.sh` increments `attempts_total` in the per-issue state file and prints the new number. The dispatcher passes that number through to all later prep scripts AND embeds it into the rendered subagent prompt — `env_paths.sh` refuses to load if `ATTEMPT_NUMBER` is missing while `ISSUE_IID` is set.

## Hard rules

1. **Each IID runs in its own SHARED linked git worktree at `${WORKTREE_DIR}=${WORKTREES_ROOT}/issue-${ISSUE_IID}/`** (no `-att-<NNN>` suffix). `prepare_attempt.sh` creates it on attempt 1 via `git worktree add -B ${LOCAL_ATTEMPT_BRANCH} ${WORKTREE_DIR} ${BASE_REF}`; on attempt N>1 it force-switches the checked-out branch via `git -C ${WORKTREE_DIR} checkout -B ${LOCAL_ATTEMPT_BRANCH} ${BASE_REF} --force`. `BASE_REF` is `origin/${WORK_BRANCH}` or the latest local prior-attempt branch only for live `continue` / `contiune` labels; every non-continue entry path intentionally uses `origin/${DEV_BRANCH}` for a clean reset. After every base checkout, `prepare_attempt.sh` refreshes tracked shared config paths (`.claude/`, `hulat/`, and `${DATA_BASENAME}/`) from the latest just-fetched `origin/${DEV_BRANCH}`, so continue-mode runs keep their same-IID work branch context but still use current test-team runner/materials config. Before an in-place branch switch, `prepare_attempt.sh` snapshots `${RESULT_BASENAME}/issue-${ISSUE_IID}/` from the shared worktree. Continue mode restores that snapshot after checkout so prior same-IID output/log files are visible; fresh reset mode archives the snapshot and then quarantines any active same-IID runtime subtree that survived checkout, so the files are not deleted but are not visible to the reset run. The parent checkout at `${REPO_PATH}` is never mutated by an attempt — only `git fetch` runs against it (under `${RESULT_ROOT}/_dispatcher/locks/repo.lock`). Same-IID attempts never run concurrently (single-batch invariant), so the shared per-issue worktree is safe; cross-IID parallelism stays safe because different IIDs use different worktree paths. `max_concurrent_subagents` has a hard lower bound of `1`; values below 1 abort the tick. When `ui_accounts_relpath` is configured (no default — trigger field, carry-forward persisted; the relpath is resolved under `${REPO_PATH}`, NOT under `${REPO_PATH}/${DATA_BASENAME}/`), `max_concurrent_subagents` is ALSO bounded above by the UI account pool size read from `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}`, and values above the pool abort the tick. When `ui_accounts_relpath` is unconfigured, the pool load is skipped and only the lower bound applies.
2. **Agent runtime files live under `${RESULT_ROOT}` (= `${REPO_PATH}/${RESULT_BASENAME}/`).** The dispatcher subtree (`_dispatcher/...`), per-issue cross-attempt subtree (`issue-<iid>/state.json`, `issue-<iid>/attempt_state.json`, `issue-<iid>/summary.md`), and `.worktrees/` are runtime/audit data. They are kept out of normal `git add -A` by `clone_or_pull.sh`'s entry in `.git/info/exclude` (which excludes the entire `${RESULT_BASENAME}/` subtree, including `.worktrees/`), but no script will refuse to push them if they make it into the diff some other way (e.g. tracked on the base branch). Inside the per-issue worktree the same exclude also covers `${LOG_DIR}` (under `${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/`); `stage_and_guard.sh` force-adds the current issue's `${OUTPUT_DIR}` plus `${LOG_DIR}/prompt.txt` and `${LOG_DIR}/claude_result.txt` so those three paths survive the exclude and land in the MR. The remaining log files (acpx_raw.log, git_status.txt, git_diff.patch, wiki_*.md / .jsonl, mr_description.md) stay locally ignored and disappear with the worktree.
3. **`hulat/`, `.claude/`, and `${DATA_BASENAME}/` are shared repository content.** They are committed to master + dev by the test team. `prepare_attempt.sh` refreshes their tracked contents from the latest `origin/${DEV_BRANCH}` before every acpx run — including continue mode — so the agent does NOT symlink `hulat/` and does NOT copy `.claude/`. They may be changed when an issue genuinely requires it; avoid unrelated edits.
4. **Per-issue spec output goes to `${OUTPUT_DIR}` only.** `build_prompt.sh` injects this rule into the Claude Code prompt. Multiple MRs into master never collide because each issue writes into a distinct `${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/` subdirectory (relative path inside the worktree).
5. There is no `${ISSUE_ROOT}/attempts/` directory. Each attempt recreates only its own `${LOG_DIR}` (`${WORKTREE_DIR}/${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/`), overwrites `${ATTEMPT_STATE_FILE}`, and updates `${SUMMARY_FILE}`. `LOG_DIR` lives INSIDE the per-issue worktree; `prompt.txt` and `claude_result.txt` survive in the work-branch / MR history because `stage_and_guard.sh` force-adds them. Cross-attempt history is preserved both on the work branch and in the shared worktree snapshot path: continue mode restores `${RESULT_BASENAME}/issue-<iid>/` from the previous in-place worktree state before recreating only the current attempt's log directory, while reset mode archives the snapshot and active same-IID runtime residue under `.preserved-attempts` before recreating empty current output/log directories. Historical summaries are preserved as GitLab issue notes.
6. Strategy A: there is exactly ONE remote branch per issue (`${WORK_BRANCH}`). Each attempt force-pushes to it from inside the shared per-issue worktree. Local per-attempt branches (`${LOCAL_ATTEMPT_BRANCH}`) are kept in `${REPO_PATH}/.git` for audit.
7. Claude Code is invoked only through `scripts/run_acpx_attempt.sh`. That script `cd`s into `${WORKTREE_DIR}` (the shared per-issue worktree for this IID, NOT the parent checkout) and runs `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"`, sets `TASK_OUTPUT_DIR=${OUTPUT_DIR}`, and writes stdout/stderr to `${LOG_DIR}/claude_result.txt` / `${LOG_DIR}/acpx_raw.log`. Current acpx releases expose `claude exec` as a one-shot command with no saved-session flag, so attempts of the same IID do not share Claude-Code session memory at the acpx level. Continue-mode continuity comes from three sources: the rendered prompt (past attempt summaries + reviewer comments), the contents checked out from `origin/${WORK_BRANCH}` or the latest local prior-attempt branch plus refreshed shared config paths from `origin/${DEV_BRANCH}`, and the restored `${RESULT_BASENAME}/issue-<iid>/` subtree. Non-continue reset runs deliberately omit that restored subtree and quarantine same-IID runtime residue before recreating the current output/log directories. The `-f` flag points to `${LOG_DIR}/prompt.txt` via absolute path.
8. Two-branch model. `${BRANCH}` (typically `master`) is the **integration / target** branch — MRs are opened against it; spec output accumulates here. `${DEV_BRANCH}` (typically `dev`) is the **clean baseline** — fresh-mode checkouts reset to `origin/${DEV_BRANCH}` so Claude does NOT see past issues' spec output. Continue mode bases on `origin/${WORK_BRANCH}` (the resumable WIP branch), not `${DEV_BRANCH}`, but still refreshes `.claude/`, `hulat/`, and `${DATA_BASENAME}/` from latest `origin/${DEV_BRANCH}` before running.
9. **No path-based leak rejection.** `stage_and_guard.sh` and `post_push_verify.sh` no longer reject anything by path. They still serve their bookkeeping roles — staging, NO_CHANGES detection, evidence files, post-push fetch — but every file present in the staged or MR diff goes through. `.git/info/exclude` (set by `clone_or_pull.sh`) keeps untracked `${RESULT_BASENAME}/` runtime files out of `git add -A`, and the current issue's `${OUTPUT_DIR}` is force-added so it survives that exclude.
10. **One-time migration from the old out-of-repo layout.** Some deployments still have a `/data/openclaw_work/${PROJECT}/...` subtree from before the agent moved into `${RESULT_ROOT}/`. Operators should either move it once during deployment:
    - `mv /data/openclaw_work/<project>/openclaw_state/campaign_state.json ${RESULT_ROOT}/_dispatcher/campaign_state.json`
    - `mv /data/openclaw_work/<project>/openclaw_log/dispatcher/* ${RESULT_ROOT}/_dispatcher/log/`
    - `mv /data/openclaw_work/<project>/issues/* ${RESULT_ROOT}/`
    
    Or simply delete the old subtree and let reconciliation rebuild state from live GitLab labels.

## Core artifacts in `${LOG_DIR}`

`${LOG_DIR}` lives INSIDE the shared per-issue worktree at `${WORKTREE_DIR}/${RESULT_BASENAME}/issue-<iid>/log/attempt-NNN/` (still attempt-scoped so attempts don't overwrite each other). By the end of each Claude run, these MUST exist:

- `prompt.txt`           — the prompt fed to `acpx claude exec -f` (**force-added by `stage_and_guard.sh`; lands in the work-branch commit and the MR diff**)
- `claude_result.txt`    — stdout from acpx (**force-added by `stage_and_guard.sh`; lands in the work-branch commit and the MR diff**)
- `acpx_raw.log`         — stderr from acpx (locally ignored; removed with the worktree)
- `git_status.txt`       — `git status --porcelain` after the Claude run (locally ignored; removed with the worktree)
- `git_diff.patch`       — `git diff` after the Claude run (locally ignored; removed with the worktree)

After post-push verification succeeds and before MR creation, these are auto-created (all locally ignored; removed with the worktree):

- `wiki_artifacts.md` — issue note body linking project Wiki pages for attempt evidence
- `wiki_artifact_links.md` — generated list of Wiki links used in the issue note
- `wiki_artifact_responses.jsonl` — raw `projects/:id/wikis` create/update responses

Every attempt that reaches Step 7 also auto-creates (locally ignored; removed with the worktree):

- `mr_description.md` — body of the merge request (rebuilt fresh on every attempt; both fresh and continue modes now close any prior open MR for `${WORK_BRANCH}` and create a new one, so `mr_description.md` is always regenerated)

Only `prompt.txt` and `claude_result.txt` end up on the work branch; the other LOG_DIR files exist for in-flight debugging on the runner and are discarded with the worktree by housekeeping.

`scripts/upload_attempt_artifacts.sh` publishes the required `prompt.txt` and `claude_result.txt`, plus the first `report.html` found under `${OUTPUT_DIR}`, to project Wiki pages under `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/`. If no `report.html` exists under the output directory, no report Wiki page is published.
