# Path Layout (Dispatcher)

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline.

| Variable                | Value                                               | Owner / purpose                                          |
| ----------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| `REPO_PATH`             | `/data/${PROJECT}`                                  | git clone target ONLY. Agent never writes under here.    |
| `WORK_ROOT`             | `/data/openclaw_work/${PROJECT}`                    | All agent-owned files live here. **Outside the repo.**   |
| `STATE_DIR`             | `${WORK_ROOT}/openclaw_state`                       | Campaign + per-issue state JSON.                         |
| `ISSUE_STATE_DIR`       | `${STATE_DIR}/issues`                               | `issue-<iid>.json` files.                                |
| `CAMPAIGN_STATE_FILE`   | `${STATE_DIR}/campaign_state.json`                  | Campaign progress cache (NOT source of truth).           |
| `LOG_ROOT`              | `${WORK_ROOT}/openclaw_log`                         | Top of the log subtree.                                  |
| `DISPATCHER_LOG_DIR`    | `${LOG_ROOT}/dispatcher`                            | `reconcile-<ts>.json` evidence files.                    |
| `LOCK_FILE`             | `${STATE_DIR}/campaign.lock`                        | flock target for the campaign.                           |

## Hard rules

1. `REPO_PATH` is for git only. Never write `openclaw_state/`, `openclaw_log/`, prompts, results, locks, or anything else under `REPO_PATH`.
2. `WORK_ROOT` is OUTSIDE the repo working tree. This is what physically prevents `git add` from sweeping agent artifacts into a commit.
3. `hulat_dir` from the trigger command is **a string passed through to Claude Code**. It is NOT a directory the dispatcher or executor itself reads/writes. Never use `hulat_dir` as `REPO_PATH`, `WORK_ROOT`, or any agent working directory.
4. If an old deployment ever wrote state/log under `REPO_PATH` or `${HULAT_DIR}`, ignore those locations entirely. Only read/write under `WORK_ROOT`.
