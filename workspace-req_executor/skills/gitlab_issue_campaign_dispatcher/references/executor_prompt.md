# Executor Prompt Template (Subagent Task)

The dispatcher extracts the sentinel-bounded rendered block below and writes it
to private mode-600 `executor_payload.txt`. The anonymous `sessions_spawn` task
is a separate secret-free bootstrap that validates the manifest before reading
this payload. The outer subagent does not load workspace instruction files.

The complete technical attempt now runs through one fixed wrapper. This is a
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
| `{ATTEMPT_NUMBER}` | allocated attempt number |
| `{ATTEMPT_NUMBER_PADDED}` | zero-padded attempt number |
| `{ISSUE_TITLE}` | live issue title for context only |
| `{ISSUE_TITLE_QUOTED}` | shell-safe single-quoted issue title |
| `{ISSUE_URL}` | pinned GitLab issue URL |
| `{ISSUE_LABELS}` | live label snapshot |
| `{ISSUE_BODY}` | first approximately 4 KB; full prompt is already on disk |
| `{ISSUE_MODE}` | `fresh` or `continue` |
| `{BRANCH}` | resolved merge-request target branch |
| `{WORK_BRANCH}` | fixed issue branch |
| `{LOCAL_ATTEMPT_BRANCH}` | attempt-local branch |
| `{REPO_PATH}` | parent checkout |
| `{WORKTREE_DIR}` | shared per-IID linked worktree |
| `{OUTPUT_DIR}` | issue output directory inside the worktree |
| `{LOG_DIR}` | attempt log directory inside the worktree |
| `{ISSUE_ROOT}` | parent checkout's durable per-Issue state directory |
| `{SCRIPTS_DIR}` | absolute dispatcher scripts directory |
| `{GITLAB_HOST}` | deployment pin |
| `{GITLAB_API_PROTOCOL}` | deployment pin |
| `{ACPX_TIMEOUT_SECONDS}` | inner acpx wall-clock cap |
| `{ACPX_TIMEOUT_MINUTES}` | floor of the acpx cap in minutes |

`{ISSUE_TITLE_QUOTED}` must be shell quoted. `{ISSUE_BODY}` is context only;
the complete inner prompt is already at `{LOG_DIR}/prompt.txt`.

## Rendered Prompt

```
# REQ_EXECUTOR_EXECUTOR_PROMPT_V1
You are the focused outer executor for GitLab issue #{ISSUE_IID} of {GROUP}/{PROJECT}.

The dispatcher already prepared the worktree, prompt, branches, and private
runtime state. Run exactly one fixed wrapper. That wrapper owns setup, the
one-shot run_acpx_attempt.sh invocation, staging, commit/push, post-push
verification, label transitions, MR creation, summary, and durable compact
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
ATTEMPT_NUMBER={ATTEMPT_NUMBER}
ATTEMPT_NUMBER_PADDED={ATTEMPT_NUMBER_PADDED}
ISSUE_MODE={ISSUE_MODE}
BRANCH={BRANCH}
WORK_BRANCH={WORK_BRANCH}
LOCAL_ATTEMPT_BRANCH={LOCAL_ATTEMPT_BRANCH}
REPO_PATH={REPO_PATH}
WORKTREE_DIR={WORKTREE_DIR}
OUTPUT_DIR={OUTPUT_DIR}
LOG_DIR={LOG_DIR}
ISSUE_ROOT={ISSUE_ROOT}
SCRIPTS={SCRIPTS_DIR}
ACPX_TIMEOUT_SECONDS={ACPX_TIMEOUT_SECONDS}
</config>

<issue>
IID: #{ISSUE_IID}
Title: {ISSUE_TITLE}
URL: {ISSUE_URL}
Labels: {ISSUE_LABELS}
Mode: {ISSUE_MODE}
Body (first approximately 4 KB; full inner prompt is at {LOG_DIR}/prompt.txt):
{ISSUE_BODY}
</issue>

<instructions>
1. Make one Bash tool call with a PTY. Use a tool command timeout of at least
   `{ACPX_TIMEOUT_SECONDS} + 2400` seconds so the wrapper's internal acpx and
   post-acpx caps fire first. Invoke exactly:

   PROJECT={PROJECT} GROUP={GROUP} \
     ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
     REPO_PATH={REPO_PATH} \
     ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
     ISSUE_MODE={ISSUE_MODE} BRANCH={BRANCH} \
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
- The wrapper applies bounded timeouts to every post-acpx Git/GitLab step and
  atomically writes `{LOG_DIR}/worker_result.json` before printing it.
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
