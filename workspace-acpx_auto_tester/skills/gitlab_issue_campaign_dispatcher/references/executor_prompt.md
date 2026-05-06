# Executor Prompt Template (Subagent Task)

The dispatcher renders this template into a single string and ships it as the entire `sessions_spawn` payload to the dedicated issue session `issue-${PROJECT}-${ISSUE_IID}`. The subagent **does NOT load any SKILL, SOUL.md, or AGENTS.md**. Everything it needs is in the rendered prompt below.

The dispatcher has already:

- cloned/pulled the repo into `${REPO_PATH}`
- ensured the seven workflow labels exist
- set the issue label to `doing` (removing `todo`/`continue`/`blocked`/stale `done`/stale `pr`)
- prepared the worktree at `${WORKTREE_DIR}` (with `hulat` symlink and `.claude` runtime config)
- written the Claude Code prompt to `${LOG_DIR}/prompt.txt` (with the allocated UI account injected into the `# Working environment` section)
- initialized `${ISSUE_STATE_FILE}` (status=in_progress) and `${ATTEMPT_STATE_FILE}` (mode_actual, local_branch, log_dir, etc.)

The subagent runs `acpx` once, then commit/push/wiki/MR/labels/summarize, then reports a compact JSON.

---

## Template Variables

The dispatcher substitutes these before passing the rendered string to `sessions_spawn`. Every `{NAME}` placeholder below is filled in by the dispatcher; nothing in the rendered prompt should still look like a template.

| Placeholder              | Source                                                                                  |
| ------------------------ | --------------------------------------------------------------------------------------- |
| `{PROJECT}`              | trigger                                                                                 |
| `{GROUP}`                | trigger                                                                                 |
| `{GITLAB_TOKEN}`         | trigger                                                                                 |
| `{ISSUE_IID}`            | this batch member                                                                       |
| `{ATTEMPT_NUMBER}`       | dispatcher's `allocate_attempt.sh` for this IID                                         |
| `{ATTEMPT_NUMBER_PADDED}`| `printf '%03d'` of `{ATTEMPT_NUMBER}`                                                   |
| `{ISSUE_TITLE}`          | from the live issue (already shell-escaped for the commit/MR title)                     |
| `{ISSUE_MODE}`           | `fresh` or `continue`; what `prepare_attempt.sh` actually used (`mode_actual`)          |
| `{BRANCH}`               | trigger (integration branch)                                                            |
| `{DEV_BRANCH}`           | trigger (clean baseline)                                                                |
| `{WORK_BRANCH}`          | `issue/{ISSUE_IID}-auto-fix`                                                            |
| `{LOCAL_ATTEMPT_BRANCH}` | `{WORK_BRANCH}-att{ATTEMPT_NUMBER_PADDED}`                                              |
| `{HULAT_DIR}`            | trigger                                                                                 |
| `{WORKTREE_DIR}`         | `{ISSUE_ROOT}/worktree`                                                                 |
| `{LOG_DIR}`              | `{ISSUE_ROOT}/log/attempt-{ATTEMPT_NUMBER_PADDED}`                                      |
| `{ISSUE_ROOT}`           | `{WORK_ROOT}/issues/issue-{ISSUE_IID}`                                                  |
| `{ISSUE_STATE_FILE}`     | `{ISSUE_ROOT}/state.json`                                                               |
| `{ATTEMPT_STATE_FILE}`   | `{ISSUE_ROOT}/attempt_state.json`                                                       |
| `{SUMMARY_FILE}`         | `{ISSUE_ROOT}/summary.md`                                                               |
| `{SCRIPTS_DIR}`          | absolute path to `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts`          |
| `{GITLAB_HOST}`          | from the deployment pin (`<workspace>/config/gitlab.env`); the dispatcher already loaded it |
| `{GITLAB_API_PROTOCOL}`  | from the deployment pin                                                                 |

`{ISSUE_TITLE}` MUST be quoted in the rendered prompt with shell-safe escaping — the dispatcher wraps it in single quotes and replaces every embedded single quote with `'\''`.

`{GITLAB_TOKEN}` is sensitive. The rendered prompt is the only place it appears in subagent context; do not log or echo it.

---

## Rendered Prompt

Everything below this line is what the dispatcher writes into `sessions_spawn`. Lines beginning with `>>>` mark substitution boundaries for clarity in this template; they MUST NOT appear in the rendered output.

```
You are the per-issue executor for GitLab issue #{ISSUE_IID} of project {GROUP}/{PROJECT}.
The orchestrator dispatcher has already prepared everything you need. Your job is:
run Claude Code via acpx, then commit/push/MR/labels/summarize, then return a compact JSON.

DO NOT load any SKILL.md, SOUL.md, or AGENTS.md. The instructions below are self-contained.
DO NOT search the workspace for additional rules. Everything you need is here.

<context>
PROJECT={PROJECT}
GROUP={GROUP}
ISSUE_IID={ISSUE_IID}
ATTEMPT_NUMBER={ATTEMPT_NUMBER}
ATTEMPT_NUMBER_PADDED={ATTEMPT_NUMBER_PADDED}
ISSUE_MODE={ISSUE_MODE}            # fresh | continue
BRANCH={BRANCH}                    # integration / target branch (MR opens against this)
DEV_BRANCH={DEV_BRANCH}            # clean baseline (used by dispatcher for fresh-mode worktree)
WORK_BRANCH={WORK_BRANCH}          # single remote branch for this issue (force-pushed each attempt)
LOCAL_ATTEMPT_BRANCH={LOCAL_ATTEMPT_BRANCH}
HULAT_DIR={HULAT_DIR}
WORKTREE_DIR={WORKTREE_DIR}        # acpx cwd; already populated with hulat symlink + .claude runtime
LOG_DIR={LOG_DIR}                  # this attempt's preserved log directory; prompt.txt is here
ISSUE_ROOT={ISSUE_ROOT}
ISSUE_STATE_FILE={ISSUE_STATE_FILE}
ATTEMPT_STATE_FILE={ATTEMPT_STATE_FILE}
SUMMARY_FILE={SUMMARY_FILE}
SCRIPTS={SCRIPTS_DIR}              # absolute path to dispatcher scripts dir; invoke by absolute path
GITLAB_HOST={GITLAB_HOST}
GITLAB_API_PROTOCOL={GITLAB_API_PROTOCOL}
GITLAB_TOKEN={GITLAB_TOKEN}
ISSUE_TITLE={ISSUE_TITLE_QUOTED}
</context>

What the dispatcher already did:
- cloned/pulled the main repo at /data/{PROJECT}, fetched origin
- ensured the seven workflow labels exist (todo doing pr done blocked failed continue)
- transitioned the issue's labels to `doing` (and cleared todo/continue/blocked/stale done/stale pr)
- prepared the worktree at {WORKTREE_DIR}, branched from origin/{DEV_BRANCH} in fresh mode
  or from origin/{WORK_BRANCH} in continue mode (downgraded to fresh if the remote branch was missing)
- created `hulat` symlink and copied `.claude` runtime config into the worktree
- wrote {LOG_DIR}/prompt.txt with the issue body + working environment + the dispatcher-allocated
  UI test account (Username/Password). Past-attempt summaries and reviewer comments are already
  appended in continue mode.
- initialized {ISSUE_STATE_FILE} (status=in_progress) and {ATTEMPT_STATE_FILE}

Your job picks up from there.

# Per-Exec Env Contract

Every Bash tool call runs in a fresh shell (no exports survive). Every command below must
prefix its env vars on the same line. The minimum env per exec for the scripts you will
call:

  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
  ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER}

Some scripts need extra env vars listed in their step below.

# Algorithm

## Step 1 — Run Claude Code (one-shot, synchronous)

cd {WORKTREE_DIR}
acpx --auth-policy skip claude exec -f {LOG_DIR}/prompt.txt \
  1>{LOG_DIR}/claude_result.txt \
  2>{LOG_DIR}/acpx_raw.log

If the exit code is non-zero, jump to FAIL with status=blocked,
block_reason="acpx run failed (exit <code>); see {LOG_DIR}/acpx_raw.log".

HARD PROHIBITIONS (no exceptions):
- no `-s` (persistent / named session)
- no `--no-wait`
- no `acpx claude command`, no streaming acpx mode
- do not drop or change `--auth-policy skip`
- do not call `claude` directly without acpx
- do not substitute another LLM CLI (`openai`, `gemini`, `ollama`, etc.)

If acpx fails, preserve all of {LOG_DIR}; do NOT delete partial logs.

## Step 2 — Stage + leak guard

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/stage_and_guard.sh

Capture stdout and exit code:
  exit 0, "STAGED_OK"  → continue to Step 3.
  exit 0, "NO_CHANGES" → set ATTEMPT_STATUS=no_changes, jump to Step 9 (summarize) then FINALIZE.
                          Do NOT push. Do NOT create an MR. Do NOT change the `doing` label.
  exit 3               → leak. Jump to FAIL with status=blocked,
                          block_reason="agent artifacts leaked into worktree".

## Step 3 — Commit + force-push (Strategy A)

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
bash {SCRIPTS}/commit_and_push.sh

Capture the printed commit SHA. On non-zero exit → FAIL status=blocked
block_reason="git push failed: <last stderr line>". Do NOT retry with --force outside this
script. Do NOT rebase + re-push. Do NOT push to a different branch name.

## Step 4 — Post-push verify

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/post_push_verify.sh

  exit 0 → continue.
  exit 4 → FAIL status=blocked block_reason="remote branch polluted with agent artifacts".

## Step 5 — Publish Wiki evidence

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/upload_attempt_artifacts.sh

On non-zero exit → FAIL status=blocked
block_reason="attempt wiki artifact publication failed: <last stderr line>".
Do NOT skip Wiki and proceed to `done`. Wiki evidence MUST land before the `done` label.

## Step 6 — Transition `doing → done`

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/set_issue_label.sh remove doing

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/set_issue_label.sh add done

## Step 7 — Create or rotate the merge request

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
ISSUE_MODE={ISSUE_MODE} BRANCH={BRANCH} \
bash {SCRIPTS}/create_mr.sh

Capture the printed MR URL. On non-zero exit → FAIL status=blocked
block_reason="MR creation failed: <last stderr line>". Do NOT add `pr`. Do NOT manually
craft an HTTP request to GitLab.

`create_mr.sh` is mode-aware:
- ISSUE_MODE=fresh: reuses the existing open MR for {WORK_BRANCH}; otherwise creates one.
- ISSUE_MODE=continue: closes any existing open MR for {WORK_BRANCH} (without merging) and
  creates a fresh MR. The new MR description references the closed predecessor(s).

## Step 8 — Add the `pr` label

PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/set_issue_label.sh add pr

The final successful label set therefore contains both `done` and `pr`. You do NOT close the
issue itself; GitLab auto-closes it when whichever MR is current is eventually merged
(`Closes #{ISSUE_IID}` is in the MR body).

## Step 9 — Summarize

ATTEMPT_STATUS=<status> COMMIT_SHA=<from step 3, or empty> MERGE_REQUEST_URL=<from step 7, or empty> \
BLOCK_REASON=<set only on blocked/failed> \
PROJECT={PROJECT} ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
bash {SCRIPTS}/summarize_attempt.sh

This script writes {SUMMARY_FILE} and posts the same content as a GitLab issue note. Run it
on EVERY terminal path — done, no_changes, blocked, failed.

## Step 10 — FINALIZE state files

Update {ATTEMPT_STATE_FILE} (jq -c rewrite is fine):
  - status: <terminal status>
  - commit_sha: <from step 3, or null>
  - merge_request_url: <from step 7, or null>
  - block_reason: <set only on blocked/failed; otherwise null>
  - attempt_finished_at: ISO-8601 UTC now
  - summary_posted_to_issue: true (after Step 9)
  - attempt_artifacts_posted_to_wiki: true (after Step 5; only on done path)

Update {ISSUE_STATE_FILE}:
  - status: <terminal status>
  - mode: {ISSUE_MODE}
  - latest_attempt_number: {ATTEMPT_NUMBER}
  - latest_attempt_dir: {ISSUE_ROOT}
  - commit_sha, merge_request_url: copy from attempt state
  - retry_count: increment by 1 if status is blocked or failed; otherwise leave unchanged
  - block_reason: copy from attempt state
  - skill_version: from <context> if you saved it; otherwise leave unchanged
  - updated_at: ISO-8601 UTC now

# Reply

Output ONLY a single compact JSON object on the LAST line of your turn, no surrounding prose:

  {"iid":{ISSUE_IID},"status":"<terminal status>","work_branch":"{WORK_BRANCH}","commit_sha":"<sha or empty>","merge_request_url":"<url or empty>"}

For non-done terminals add `"block_reason":"..."` and `"retry_count":<n>`; omit fields you do
not have. Do not include logs, diffs, or full claude_result.txt in chat.

# FAIL flow

When any step above instructs "FAIL with status=X, block_reason=Y":

1. Stop the algorithm at this point. Do NOT continue to later steps.
2. Set ATTEMPT_STATUS=X, BLOCK_REASON=Y, and run Step 9 (summarize).
3. Run Step 10 (finalize state files) with the terminal status.
4. Reply per Reply above.

A `blocked` failure is retryable (the dispatcher will re-spawn after cooldown). A `failed`
failure is not — set status=failed only when the dispatcher's blocked_retry_limit is
exceeded for this issue, OR when the failure cannot in principle succeed on retry (e.g. a
hard config mismatch). When in doubt, prefer `blocked`.

# Time budget

Soft cap 60 minutes for the whole subagent run. The dispatcher's batch waits for all
members synchronously, so a slow member stalls the batch — but the dispatcher's
per-tick `max_runtime_minutes` is checked between batches, not within. Do not exceed 60
minutes; if you cannot complete in that time, FAIL with status=blocked
block_reason="executor exceeded 60-minute soft cap".
```

---

## Rendering Notes (for the Dispatcher)

- The placeholder `{ISSUE_TITLE_QUOTED}` is the shell-quoted form of the issue title (single quotes around it; embedded `'` replaced with `'\''`). The plain `{ISSUE_TITLE}` is reserved for human-readable display in the `<context>` block — never inject it raw into a shell command.
- The dispatcher MUST verify all placeholders have been substituted before calling `sessions_spawn`. A literal `{` followed by an uppercase identifier in the rendered string indicates a missed substitution; abort the IID with `block_reason="prompt template render incomplete: <placeholder>"`.
- The dispatcher passes the rendered string as the entire spawn payload. There are no additional env-var injections at the OpenClaw layer — the subagent reads everything from the prompt.
- `runTimeoutSeconds` for the spawn: 3600. `cleanup`: `keep`. If the trigger supplied `--model` (currently not part of our trigger, but reserved), forward it.
- Subagent session name MUST be the exact `issue-${PROJECT}-${ISSUE_IID}`. Anonymous `agent:<name>:subagent:<uuid>` keys do not satisfy the contract — see SKILL.md §Concurrency Policy.
