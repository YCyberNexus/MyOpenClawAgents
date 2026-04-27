# Path Layout (Executor)

All paths are derived in `scripts/env_paths.sh`. SOURCE that script — do NOT redefine paths inline.

| Variable             | Value                                               | Owner / purpose                                              |
| -------------------- | --------------------------------------------------- | ------------------------------------------------------------ |
| `REPO_PATH`          | `/data/${PROJECT}`                                  | git clone target ONLY. Executor never writes agent files here. |
| `WORK_ROOT`          | `/data/openclaw_work/${PROJECT}`                    | All agent-owned files live here. **Outside the repo.**       |
| `LOG_DIR`            | `${WORK_ROOT}/openclaw_log/issue-${ISSUE_IID}`      | Per-issue logs (`prompt.txt`, `claude_result.txt`, etc.).    |
| `STATE_DIR`          | `${WORK_ROOT}/openclaw_state`                       | Campaign + per-issue state JSON.                             |
| `ISSUE_STATE_DIR`    | `${STATE_DIR}/issues`                               | `issue-<iid>.json` files.                                    |
| `ISSUE_STATE_FILE`   | `${ISSUE_STATE_DIR}/issue-${ISSUE_IID}.json`        | This issue's state file.                                     |
| `WORK_BRANCH`        | `issue/${ISSUE_IID}-auto-fix`                       | The branch the executor pushes.                              |

## Hard rules

1. `REPO_PATH` is for git only. The executor MUST NEVER write `openclaw_log/`, `openclaw_state/`, `prompt.txt`, `claude_result.txt`, `acpx_raw.log`, `git_status.txt`, `git_diff.patch`, or any other agent-owned file under `REPO_PATH`. If any such file is found under `REPO_PATH`, it is a bug and must not be committed.
2. All agent-owned files live under `WORK_ROOT = /data/openclaw_work/${PROJECT}/`, which is OUTSIDE the repo working tree. This makes it physically impossible for `git add` to pick them up by accident.
3. `hulat_dir` is task context for Claude Code only. The executor MUST NOT clone the repo into `${HULAT_DIR}`, write any `openclaw_*/` under `${HULAT_DIR}`, or `cd` into `${HULAT_DIR}` for git/acpx commands.
4. `hulat_dir` is only a string embedded into the Claude Code prompt so the downstream Claude run knows where the hulat materials live. It is not a directory the executor itself reads/writes.

## Required artifacts in `LOG_DIR`

By the end of the executor run, these MUST exist under `${LOG_DIR}`:

- `prompt.txt`           — the prompt fed to `acpx claude exec -f`
- `claude_result.txt`    — stdout from acpx
- `acpx_raw.log`         — stderr from acpx
- `git_status.txt`       — `git status --porcelain` after Claude run
- `git_diff.patch`       — `git diff` after Claude run
- `mr_description.md`    — body of the merge request (auto-generated if absent)

These NEVER go into the git work branch — they live only under `WORK_ROOT`.
