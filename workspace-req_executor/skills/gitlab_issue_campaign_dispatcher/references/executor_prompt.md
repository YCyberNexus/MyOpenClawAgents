# Executor Prompt Template (Subagent Task)

The dispatcher extracts the sentinel-bounded rendered block below and writes it
to a private mode-600 execution-scoped payload file. The anonymous `sessions_spawn` task
is a separate secret-free bootstrap that validates the manifest before reading
this payload. The outer subagent does not load workspace instruction files.

The complete technical execution now runs through one fixed wrapper. This is a
correctness boundary, not only a prompt simplification: a long synchronous acpx
tool call can return without OpenClaw scheduling another model turn. Keeping
acpx and all deterministic finalization in one Bash process removes that gap.
The wrapper also persists its final compact result to
`${LOG_DIR}/worker_result.json`, allowing the periodic executor tick to recover
the result and release a stuck native subagent slot.

GitLab credentials are never rendered into this payload. Fixed scripts resolve
credentials from the private process/deployment environment, and
`run_acpx_attempt.sh` strips them from the inner acpx process.

## Template Variables

| Placeholder | Source |
| --- | --- |
| `{PROJECT}` | trigger project slug |
| `{GROUP}` | trigger GitLab group |
| `{ISSUE_IID}` | current IID |
| `{EXECUTION_ID}` | random opaque execution identity |
| `{ISSUE_MODE}` | `fresh` or `continue` |
| `{BRANCH}` | resolved processing base branch |
| `{BRANCH_QUOTED}` | shell-safe single-quoted processing base branch |
| `{CONFIG_BRANCH}` | trusted branch supplying `.claude/` runtime config |
| `{DEPENDENCY_IID}` | prerequisite IID, or empty when none applies |
| `{DEPENDENCY_BRANCH}` | shared `issue/A+C` branch for C, legacy ordinary dependency branch, or empty |
| `{DEPENDENCY_BASE_SHA}` | immutable prerequisite commit used by fresh checkout, or empty |
| `{AUTO_MERGE}` | `true` only when the user explicitly requested automatic merge |
| `{MERGE_TARGET_BRANCH}` | resolved merge-request target branch |
| `{MERGE_TARGET_BRANCH_QUOTED}` | shell-safe single-quoted merge-request target branch |
| `{WORK_BRANCH}` | fixed `issue/<iid>` branch or frozen shared `issue/A+C` branch |
| `{WORK_BRANCH_QUOTED}` | shell-safe single-quoted work branch |
| `{EXPECTED_WORK_BRANCH_SHA}` | exact old shared-branch tip used only for the explicit push lease, or empty for a new/ordinary branch |
| `{EXPECTED_COMMIT_PARENT_SHA}` | exact commit required as the new shared commit's only parent, or empty for an ordinary branch |
| `{LOCAL_ISSUE_BRANCH}` | fixed issue-local branch |
| `{REPO_PATH}` | parent checkout |
| `{WORKTREE_DIR}` | shared per-IID linked worktree |
| `{OUTPUT_DIR}` | issue output directory inside the worktree |
| `{LOG_DIR}` | execution-scoped log directory inside the worktree |
| `{ISSUE_ROOT}` | parent checkout's durable per-Issue state directory |
| `{SCRIPTS_DIR}` | absolute dispatcher scripts directory |
| `{GITLAB_HOST}` | deployment pin |
| `{GITLAB_API_PROTOCOL}` | deployment pin |
| `{ACPX_TIMEOUT_SECONDS}` | inner acpx wall-clock cap |
| `{ACPX_TIMEOUT_MINUTES}` | floor of the acpx cap in minutes |

`{BRANCH_QUOTED}`, `{WORK_BRANCH_QUOTED}`, and
`{MERGE_TARGET_BRANCH_QUOTED}` must be shell quoted. The
Issue title/body/URL/labels are deliberately absent from this outer payload;
only the inner acpx prompt reads the private Issue snapshot. The raw
`{BRANCH}` and `{MERGE_TARGET_BRANCH}` forms are context values inside
`<config>` only and must never be inserted into a shell command.

## Rendered Prompt

```
# REQ_EXECUTOR_EXECUTOR_PROMPT_V1
You are the focused outer executor for GitLab issue #{ISSUE_IID} of {GROUP}/{PROJECT}.

The dispatcher already prepared the worktree, prompt, branches, and private
runtime state. Run exactly one fixed wrapper. That wrapper owns setup, the
one-shot run_acpx_attempt.sh invocation, staging, commit/push, post-push
verification, label transitions, MR creation or exact shared-MR reuse, summary, and durable compact
result persistence. Do not perform any of those steps yourself.

DO NOT load any SKILL.md, SOUL.md, AGENTS.md, or other workspace rules.
DO NOT call sessions_spawn, sessions_history, subagents, or acpx directly.
DO NOT run rm, git, glab, or any dispatcher helper individually.
DO NOT rerun the wrapper, even if the tool times out, disconnects, or returns
without a compact result. The executor heartbeat owns recovery.

<config>
PROJECT={PROJECT}
GROUP={GROUP}
GITLAB_HOST={GITLAB_HOST}
GITLAB_API_PROTOCOL={GITLAB_API_PROTOCOL}
ISSUE_IID={ISSUE_IID}
EXECUTION_ID={EXECUTION_ID}
ISSUE_MODE={ISSUE_MODE}
BRANCH={BRANCH}
CONFIG_BRANCH={CONFIG_BRANCH}
DEPENDENCY_IID={DEPENDENCY_IID}
DEPENDENCY_BRANCH={DEPENDENCY_BRANCH}
DEPENDENCY_BASE_SHA={DEPENDENCY_BASE_SHA}
AUTO_MERGE={AUTO_MERGE}
MERGE_TARGET_BRANCH={MERGE_TARGET_BRANCH}
WORK_BRANCH={WORK_BRANCH}
EXPECTED_WORK_BRANCH_SHA={EXPECTED_WORK_BRANCH_SHA}
EXPECTED_COMMIT_PARENT_SHA={EXPECTED_COMMIT_PARENT_SHA}
LOCAL_ISSUE_BRANCH={LOCAL_ISSUE_BRANCH}
REPO_PATH={REPO_PATH}
WORKTREE_DIR={WORKTREE_DIR}
OUTPUT_DIR={OUTPUT_DIR}
LOG_DIR={LOG_DIR}
ISSUE_ROOT={ISSUE_ROOT}
SCRIPTS={SCRIPTS_DIR}
ACPX_TIMEOUT_SECONDS={ACPX_TIMEOUT_SECONDS}
</config>

<instructions>
1. Make one Bash tool call with a PTY. Use a tool command timeout of at least
   `{ACPX_TIMEOUT_SECONDS} + 2400` seconds so the wrapper's internal acpx and
   post-acpx caps fire first. Invoke exactly:

   PROJECT={PROJECT} GROUP={GROUP} \
     ISSUE_IID={ISSUE_IID} EXECUTION_ID={EXECUTION_ID} \
     REPO_PARENT_PATH= REPO_PATH={REPO_PATH} \
     ISSUE_MODE={ISSUE_MODE} BRANCH={BRANCH_QUOTED} \
     WORK_BRANCH={WORK_BRANCH_QUOTED} \
     EXPECTED_WORK_BRANCH_SHA={EXPECTED_WORK_BRANCH_SHA} \
     EXPECTED_COMMIT_PARENT_SHA={EXPECTED_COMMIT_PARENT_SHA} \
     DEPENDENCY_IID={DEPENDENCY_IID} \
     DEPENDENCY_BRANCH={DEPENDENCY_BRANCH} \
     DEPENDENCY_BASE_SHA={DEPENDENCY_BASE_SHA} \
     AUTO_MERGE={AUTO_MERGE} MERGE_TARGET_BRANCH={MERGE_TARGET_BRANCH_QUOTED} \
     ACPX_TIMEOUT_SECONDS={ACPX_TIMEOUT_SECONDS} \
     bash {SCRIPTS_DIR}/run_executor_attempt.sh

2. Wait for that same tool call to finish. Never start a second wrapper or
   acpx process. The wrapper may print `ACPX_EXIT=<n>` before its final line.

3. If the tool's last non-empty stdout line is a compact JSON object, output
   that exact line as your entire final answer. Do not rewrite, summarize, or
   surround it with prose or a code fence. It has exactly the worker-result
   fields required by the parent.

4. If the tool returns without a compact JSON last line, output no invented
   result and do not call another tool. The heartbeat will inspect the durable
   acpx marker/result files, classify the interruption, and reclaim the slot.
</instructions>

<constraints>
- The fixed wrapper is the only execution path. It is intentionally one long
  synchronous Bash call so OpenClaw does not need another model turn between
  acpx completion and post-acpx finalization.
- `run_acpx_attempt.sh` remains the only owner of the exact
  `acpx --auth-policy skip claude exec -f` invocation.
- The wrapper applies bounded timeouts to every post-acpx Git/GitLab step,
  atomically writes `{LOG_DIR}/worker_result.json`, archives the complete
  terminal directory on append-only branch
  `req-executor-logs/issue-{ISSUE_IID}/execution-{EXECUTION_ID}` without
  moving the business branch, and only then prints the compact result.
- The whole outer run remains bounded by the deployment's global subagent
  timeout; the periodic heartbeat additionally reclaims post-acpx stalls.
- Never paste logs, diffs, prompt contents, or credentials into the reply.
</constraints>
# REQ_EXECUTOR_EXECUTOR_PROMPT_V1_END
```

## Rendering Notes

- The dispatcher must substitute every uppercase placeholder before hashing and
  publishing the payload. A missed placeholder aborts preparation.
- The runtime receives only the secret-free bootstrap. The verified private
  payload invokes the fixed wrapper and contains no GitLab token.
- The subagent's normal completion is still a protected OpenClaw native event.
  If the outer model fails to emit its final line, the heartbeat instead reads
  the wrapper's durable result under the same claim fence, runs Phase 6, then
  requests best-effort native child cleanup.
