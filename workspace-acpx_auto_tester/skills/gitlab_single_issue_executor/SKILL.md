---
name: gitlab_single_issue_executor
description: "[SKILL_VERSION=2026-05-06.3] Execute a dispatcher-prepared GitLab issue handoff in one runtime-created child subagent. The worker must not clone/pull, prepare directories/worktrees, copy .claude, link hulat, or build prompts. It receives RUN_PREPARED_ISSUE_WORKER with a handoff file, runs the prepared Claude prompt, stages/guards, commits, pushes, publishes Wiki evidence, changes doing to done, creates or rotates the MR, adds pr, updates state, and returns compact JSON for the parent callback."
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Prepared Issue Worker Skill

**SKILL_VERSION: 2026-05-06.3**

The worker MUST include `"skill_version": "2026-05-06.3"` in its compact chat summary. Normal workers should not read this file at runtime; the dispatcher sends a self-contained `RUN_PREPARED_ISSUE_WORKER` payload and writes `${LOG_DIR}/subagent_task.md`.

If the current message starts with `RUN_PREPARED_ISSUE_WORKER`, this session is already the prepared child worker. Do not call `sessions_spawn`, `sessions_history`, or any dispatcher workflow. Run the prepared worker command only.

## Companion Files

- `scripts/run_prepared_worker.sh` — the preferred single command for prepared workers. It consumes `${ISSUE_ROOT}/handoff.json`, runs acpx, handles label transitions, calls the publication scripts, updates state, and returns compact JSON.
- `scripts/env_paths.sh` — derives paths from trigger env. With `PREPARED_WORKER=1`, it fails if dispatcher-created directories are missing instead of creating them.
- `scripts/ensure_labels.sh`, `scripts/set_issue_label.sh` — workflow labels.
- `scripts/stage_and_guard.sh`, `scripts/commit_and_push.sh`, `scripts/post_push_verify.sh` — git staging, force-push Strategy A, and remote leak verification.
- `scripts/upload_attempt_artifacts.sh`, `scripts/create_mr.sh`, `scripts/summarize_attempt.sh` — Wiki evidence, MR create/rotate, and issue summary.
- `scripts/clone_or_pull.sh`, `scripts/prepare_attempt.sh`, `scripts/build_prompt.sh` are deprecated fail-fast wrappers. Those operations are dispatcher-owned.
- `references/paths.md`, `references/state_schema.md`, `references/glab_commands.md`, `references/label_lifecycle.md`, `references/continue_mode.md` document the prepared-worker contract.

## Hard Boundary

The worker starts only after the dispatcher has prepared the environment.

Forbidden in this role:

- call `sessions_spawn` or `sessions_history`
- run `RUN_SCHEDULED_ISSUE_CAMPAIGN` / dispatcher scheduling logic
- clone, pull, fetch, prune, or set up `/data/${PROJECT}`
- create issue directories or attempt log directories
- remove/recreate `${WORKTREE_DIR}`
- create the `hulat` symlink
- copy `${HULAT_DIR}/ifp-hulat/.claude`
- build or rewrite `${LOG_DIR}/prompt.txt`
- read SKILL.md or reference files before starting work

If any prepared artifact is missing, return `blocked` with the missing path. Do not repair preparation inside the worker.

## Inputs

Required worker payload (`RUN_PREPARED_ISSUE_WORKER`):

- `handoff_file=${ISSUE_ROOT}/handoff.json`
- `project`, `group`, `issue_iid`, `attempt_number`
- `branch`, `dev_branch`, `hulat_dir`
- `gitlab_token`
- optional `blocked_retry_limit`

Required handoff v1 fields:

- `handoff_version`, `project`, `group`, `iid`, `attempt_number`
- `issue_title`, `issue_mode_requested`, `issue_mode_actual`
- `worktree_dir`, `log_dir`, `prompt_file`
- `work_branch`, `local_branch`
- `issue_state_file`, `attempt_state_file`, `created_at`

The handoff intentionally does not persist `gitlab_token`.

## Execution Contract

For normal execution, run exactly the self-contained command from `${LOG_DIR}/subagent_task.md`. It resolves to:

```bash
cd "<workspace>/skills/gitlab_single_issue_executor"
PROJECT=<project> GROUP=<group> ISSUE_IID=<iid> ATTEMPT_NUMBER=<n> \
BRANCH=<branch> DEV_BRANCH=<dev_branch> HULAT_DIR=<hulat_dir> \
GITLAB_TOKEN=<token> HANDOFF_FILE=<handoff_file> PREPARED_WORKER=1 \
bash scripts/run_prepared_worker.sh
```

`scripts/run_prepared_worker.sh` then performs the allowed worker flow:

1. Validate the handoff and dispatcher-created paths.
2. Ensure labels exist; transition entry labels to `doing`.
3. Run one-shot Claude Code from `${WORKTREE_DIR}`:
   ```bash
   acpx --auth-policy skip claude exec -f "${PROMPT_FILE}" \
     1>"${LOG_DIR}/claude_result.txt" \
     2>"${LOG_DIR}/acpx_raw.log"
   ```
4. Stage and guard the diff.
5. Commit and push the local attempt branch to `${WORK_BRANCH}`.
6. Verify the remote branch contains no agent artifacts, `hulat`, or `.claude`.
7. Publish prompt/result/report evidence to the project Wiki and link it from the issue.
8. Change `doing` to `done`.
9. Create or rotate the MR; add `pr` after MR creation succeeds.
10. Post the attempt summary, finalize state, and return compact JSON.

Persistent/named acpx sessions (`-s`), `--no-wait`, direct `claude`, non-Claude LLM CLIs, manual repo edits by the worker, and alternative push/MR workflows are forbidden.

## Failure Mapping

- Missing handoff, missing worktree, missing prompt, or missing prepared directories -> `blocked`.
- acpx failure -> `blocked` or `failed` if retry limit is exceeded.
- `stage_and_guard.sh` leak -> `blocked`.
- no staged changes -> `no_changes`, summary only, no push/MR.
- commit/push rejection, post-push verification failure, Wiki publication failure, MR creation failure, or label transition failure -> `blocked` or `failed` if retry limit is exceeded.

Detailed evidence stays in `${LOG_DIR}`. Chat output is only compact JSON.

## Chat Output

Return a single compact JSON summary, for example:

```json
{
  "skill_version": "2026-05-06.3",
  "iid": 14,
  "status": "done",
  "work_branch": "issue/14-auto-fix",
  "commit_sha": "abc1234...",
  "merge_request_url": "http://gitlab.example.com/..."
}
```
