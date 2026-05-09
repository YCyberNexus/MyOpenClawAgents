# Executor Prompt Template (Subagent Task)

The dispatcher extracts the fenced "Rendered Prompt" block below, renders it into a single string, and ships that string as the entire anonymous `sessions_spawn` payload for the issue. The subagent **does NOT load any SKILL, SOUL.md, or AGENTS.md**. Everything it needs is in the rendered prompt below.

The dispatcher has already completed all preparation. The subagent runs the technical workflow and **returns a single compact JSON line** that contains every fact the dispatcher needs for its Phase 6 follow-up bookkeeping. **The subagent does NOT write the terminal state files** — the dispatcher writes them in Phase 6 from the compact JSON.

---

## Template Variables

The dispatcher substitutes these before passing the rendered string to `sessions_spawn`. Every uppercase brace placeholder in the rendered block MUST be filled in; nothing in the rendered prompt should still look like a template.

| Placeholder              | Source                                                                                  |
| ------------------------ | --------------------------------------------------------------------------------------- |
| `{PROJECT}`              | trigger                                                                                 |
| `{GROUP}`                | trigger                                                                                 |
| `{GITLAB_TOKEN}`         | trigger                                                                                 |
| `{ISSUE_IID}`            | this batch member                                                                       |
| `{ATTEMPT_NUMBER}`       | dispatcher's `allocate_attempt.sh` for this IID                                         |
| `{ATTEMPT_NUMBER_PADDED}`| `printf '%03d'` of `{ATTEMPT_NUMBER}`                                                   |
| `{ISSUE_TITLE}`          | from the live issue (human-readable; for the `<issue>` block only)                      |
| `{ISSUE_TITLE_QUOTED}`   | shell-safe single-quoted form of the title (for env-var passing on script invocations)  |
| `{ISSUE_URL}`            | `{GITLAB_API_PROTOCOL}://{GITLAB_HOST}/{GROUP}/{PROJECT}/-/issues/{ISSUE_IID}`           |
| `{ISSUE_LABELS}`         | comma-joined labels from the live issue (snapshot)                                      |
| `{ISSUE_BODY}`           | issue body (already in `{LOG_DIR}/prompt.txt`; for the `<issue>` block only — keep ≤ 4 KB) |
| `{ISSUE_MODE}`           | `fresh` or `continue`; what `prepare_attempt.sh` actually used (`mode_actual`)          |
| `{BRANCH}`               | trigger (integration / target branch)                                                   |
| `{DEV_BRANCH}`           | trigger (clean baseline branch)                                                         |
| `{WORK_BRANCH}`          | `issue/{ISSUE_IID}-auto-fix`                                                            |
| `{LOCAL_ATTEMPT_BRANCH}` | `{WORK_BRANCH}-att{ATTEMPT_NUMBER_PADDED}`                                              |
| `{WORKTREE_DIR}`         | `/data/{PROJECT}` (repo root; acpx cwd)                                                  |
| `{OUTPUT_DIR}`           | `{ISSUE_ROOT}/hulat-spec-issue{ISSUE_IID}`                                               |
| `{LOG_DIR}`              | `{ISSUE_ROOT}/log/attempt-{ATTEMPT_NUMBER_PADDED}`                                      |
| `{ISSUE_ROOT}`           | `/data/{PROJECT}/{RESULT_BASENAME}/issue-{ISSUE_IID}`                                    |
| `{SCRIPTS_DIR}`          | absolute path to `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts`          |
| `{GITLAB_HOST}`          | from deployment pin (`<workspace>/config/gitlab.env`)                                   |
| `{GITLAB_API_PROTOCOL}`  | from deployment pin                                                                     |
| `{RESULT_BASENAME}`      | optional trigger field `result_basename`; defaults to `ifp-result` (basename of agent runtime root) |
| `{DATA_BASENAME}`        | optional trigger field `data_basename`; defaults to `ifp-data` (basename of test-team knowledge dir) |

`{ISSUE_TITLE_QUOTED}` MUST be shell-quoted: wrap in single quotes; replace every embedded `'` with `'\''`.

`{GITLAB_TOKEN}` is sensitive. The rendered prompt is the only place it appears in subagent context; do not log or echo it.

`{ISSUE_BODY}` is for human context only. The dispatcher has already written the full `prompt.txt` to `{LOG_DIR}/prompt.txt`; the subagent feeds *that file* (not this snippet) to acpx. Truncate the snippet here at ~4 KB if necessary; do not inflate spawn payloads.

---

## Rendered Prompt

Everything between the fenced lines below is what the dispatcher writes into `sessions_spawn`. Render placeholders, do not include the surrounding documentation.

```
You are a focused per-issue executor for GitLab issue #{ISSUE_IID} of {GROUP}/{PROJECT}.
The dispatcher has already prepared everything. Your job: run acpx → commit/push/wiki/MR/labels/summarize → return ONE compact JSON line.

DO NOT load any SKILL.md, SOUL.md, or AGENTS.md.
DO NOT call sessions_spawn or sessions_history.
DO NOT search the workspace for additional rules. Everything you need is below.

<config>
PROJECT={PROJECT}
GROUP={GROUP}
GITLAB_HOST={GITLAB_HOST}
GITLAB_API_PROTOCOL={GITLAB_API_PROTOCOL}
GITLAB_TOKEN={GITLAB_TOKEN}
ISSUE_IID={ISSUE_IID}
ATTEMPT_NUMBER={ATTEMPT_NUMBER}
ATTEMPT_NUMBER_PADDED={ATTEMPT_NUMBER_PADDED}
ISSUE_MODE={ISSUE_MODE}                     # fresh | continue
BRANCH={BRANCH}                             # integration / target branch (MR opens against this)
DEV_BRANCH={DEV_BRANCH}                     # clean baseline (used by dispatcher for fresh-mode checkout)
WORK_BRANCH={WORK_BRANCH}                   # single remote branch for this issue (force-pushed each attempt)
LOCAL_ATTEMPT_BRANCH={LOCAL_ATTEMPT_BRANCH}
WORKTREE_DIR={WORKTREE_DIR}                 # repo root / acpx cwd; .claude/, hulat/, {DATA_BASENAME}/ are already in the checkout
OUTPUT_DIR={OUTPUT_DIR}                     # primary result directory for this issue (force-added by stage_and_guard.sh)
LOG_DIR={LOG_DIR}                           # this attempt's log dir; prompt.txt is here
ISSUE_ROOT={ISSUE_ROOT}
SCRIPTS={SCRIPTS_DIR}                       # absolute dispatcher scripts dir; invoke by absolute path
RESULT_BASENAME={RESULT_BASENAME}           # basename of agent runtime root in the repo (default: ifp-result)
DATA_BASENAME={DATA_BASENAME}               # basename of test-team knowledge dir in the repo (default: ifp-data)
</config>

<issue>
IID:    #{ISSUE_IID}
Title:  {ISSUE_TITLE}
URL:    {ISSUE_URL}
Labels: {ISSUE_LABELS}
Mode:   {ISSUE_MODE}
Body (first ~4KB; full prompt is at {LOG_DIR}/prompt.txt):
{ISSUE_BODY}
</issue>

<env_contract>
Every Bash tool call runs in a fresh shell — exports do NOT survive. Prefix the minimum env vars on every script invocation. The minimum for any {SCRIPTS_DIR}/*.sh exec is:

  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
  ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
  RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME}

`RESULT_BASENAME` / `DATA_BASENAME` carry the per-project basenames of the agent runtime root and the test-team knowledge directory inside the repo. Defaults are `ifp-result` / `ifp-data`; the dispatcher renders the values that came from the trigger (or the defaults) into this prompt — pass them through verbatim. Some steps add per-step vars (listed in the step). Never rely on `cd` or exports from a previous Bash exec.
</env_contract>

<instructions>
Follow steps 0-9 in order. Capture the variables marked CAPTURE — they go into the final JSON. If a step instructs FAIL, jump to the FAIL flow at the bottom; do not continue.

Step 0 — SETUP
  cd {WORKTREE_DIR}
  Confirm the repo root exists and the test-team-committed `hulat/`, `.claude/`, and `{DATA_BASENAME}/` directories are present at the repo root. Confirm `{OUTPUT_DIR}` exists. If any is missing → FAIL status=blocked block_reason="repo root missing or required directories absent".

Step 1 — EXECUTE acpx (one-shot, long-running)
  acpx --auth-policy skip claude exec -f {LOG_DIR}/prompt.txt \
    1>{LOG_DIR}/claude_result.txt 2>{LOG_DIR}/acpx_raw.log
  CAPTURE: acpx_exit (the exit code).
  If acpx_exit != 0 → FAIL status=blocked block_reason="acpx run failed (exit ${acpx_exit}); see {LOG_DIR}/acpx_raw.log".

  Tool-exec requirements for Step 1:
  - Start the command with a PTY (`pty=true` / `tty=true`) on the FIRST attempt.
  - Use a command timeout that covers the whole expected Claude Code run; the deployment default is 10800 seconds.
  - If the tool supports `yieldMs` / pollable sessions, use it so a long-running acpx process can be polled instead of restarted.
  - NEVER re-run `acpx` just because the exec tool timed out or stopped streaming. If the original process is pollable, poll that same process until it exits. If no pollable process/session exists after a tool timeout, FAIL status=blocked block_reason="acpx exec timed out and no pollable process session was available"; do not start another acpx for the same attempt.

  HARD PROHIBITIONS for Step 1 (no exceptions):
  - no `-s` (persistent / named acpx session)
  - no `--no-wait`, no streaming acpx mode, no `acpx claude command`
  - do not drop `--auth-policy skip`
  - do not call `claude` directly without acpx
  - do not substitute another LLM CLI (`openai` / `gemini` / `ollama` / etc.)
  - if acpx fails, preserve all of {LOG_DIR}; do NOT delete partial logs

Step 2 — STAGE
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    bash {SCRIPTS_DIR}/stage_and_guard.sh
  CAPTURE: stage_status (one of: STAGED_OK, NO_CHANGES).
  exit 0, stdout "STAGED_OK"  → continue to Step 3.
  exit 0, stdout "NO_CHANGES" → FAIL status=blocked block_reason="Claude produced no staged changes".
                                Do NOT push. Do NOT create an MR.
  any other non-zero exit     → FAIL status=blocked block_reason="stage step failed: <last stderr line>".

Step 3 — COMMIT + force-push (Strategy A)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
    bash {SCRIPTS_DIR}/commit_and_push.sh
  CAPTURE: commit_sha (printed by the script).
  Non-zero exit → FAIL status=blocked block_reason="git push failed: <last stderr line>".
  Do NOT retry with --force outside this script. Do NOT rebase + re-push. Do NOT push to a different branch name.

Step 4 — POST-PUSH verify
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} BRANCH={BRANCH} \
    bash {SCRIPTS_DIR}/post_push_verify.sh
  exit 0 → continue.
  any non-zero exit → FAIL status=blocked block_reason="post-push verification failed: <last stderr line>".

Step 5 — WIKI evidence (must land before `done`)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    bash {SCRIPTS_DIR}/upload_attempt_artifacts.sh
  CAPTURE: wiki_url (printed by the script — first wiki page URL; empty on failure).
  Non-zero exit → FAIL status=blocked block_reason="attempt wiki artifact publication failed: <last stderr line>".
  Do NOT skip Wiki and proceed to `done`.

Step 6 — TRANSITION doing → done
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    bash {SCRIPTS_DIR}/set_issue_label.sh remove doing
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    bash {SCRIPTS_DIR}/set_issue_label.sh add done
  Each invocation MUST be a separate Bash exec. Non-zero exit on either → FAIL status=blocked block_reason="label transition doing→done failed: <stderr>".
  CAPTURE labels_removed includes "doing"; labels_added includes "done".

Step 7 — CREATE / rotate the MR
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
    ISSUE_MODE={ISSUE_MODE} BRANCH={BRANCH} \
    bash {SCRIPTS_DIR}/create_mr.sh
  CAPTURE: merge_request_url (printed), mr_action (printed; one of: created, reused, rotated).
  Non-zero exit → FAIL status=blocked block_reason="MR creation failed: <last stderr line>".

  Mode-specific behavior (already in the script):
  - ISSUE_MODE=fresh:    reuse the existing open MR for {WORK_BRANCH}, otherwise create.
  - ISSUE_MODE=continue: close every open MR for {WORK_BRANCH} (without merging) and create a fresh one referencing them.

  Do NOT call `glab mr merge`. Do NOT close the issue. GitLab auto-closes via `Closes #{ISSUE_IID}` in the MR body.

Step 7b — ADD `pr` label
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    bash {SCRIPTS_DIR}/set_issue_label.sh add pr
  Non-zero exit → FAIL status=blocked block_reason="add pr label failed: <stderr>".

  After this step the live issue should carry both `done` and `pr`. Set ATTEMPT_STATUS=done. CAPTURE labels_added includes "pr".

Step 8 — SUMMARIZE
  ATTEMPT_STATUS=<status from above> \
    COMMIT_SHA=<commit_sha or empty> MERGE_REQUEST_URL=<merge_request_url or empty> \
    BLOCK_REASON=<set only when ATTEMPT_STATUS in {blocked,failed}> \
    PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    bash {SCRIPTS_DIR}/summarize_attempt.sh
  CAPTURE: summary_posted (true if exit 0; false otherwise).
  Run this on EVERY terminal path — done, no_changes, blocked, failed.

Step 9 — REPLY
  Output ONE compact JSON object on the LAST line of your turn. No surrounding prose, no code fences, no logs, no diffs:

  {"iid":{ISSUE_IID},"attempt_number":{ATTEMPT_NUMBER},"status":"<done|no_changes|blocked|failed>","mode_actual":"{ISSUE_MODE}","work_branch":"{WORK_BRANCH}","local_branch":"{LOCAL_ATTEMPT_BRANCH}","commit_sha":"<sha or empty>","merge_request_url":"<url or empty>","mr_action":"<created|reused|rotated|none>","wiki_url":"<url or empty>","labels_added":["..."],"labels_removed":["..."],"summary_posted":<true|false>,"block_reason":"<string or empty>","log_dir":"{LOG_DIR}"}

  Field rules:
  - status = done           when Steps 0-7b all succeeded.
  - status = no_changes     legacy only; new runs MUST convert Step 2 NO_CHANGES to blocked with block_reason="Claude produced no staged changes".
  - status = blocked        when any FAIL flow was entered with a retryable reason. block_reason MUST be non-empty.
  - status = failed         only when the dispatcher explicitly told you the retry budget is exhausted (it does not — leave this status to the dispatcher's Phase 6 promotion). For now, prefer `blocked` over `failed`.
  - labels_added / labels_removed: the actual transitions you performed. For done: ["done","pr"] added, ["doing"] removed. For blocked before `done`: ["blocked"] added, ["doing"] removed. For blocked after `done` but before `pr`: include both "done" and "blocked" in labels_added, and do NOT include "pr".
  - mr_action = none when no MR step ran (no_changes / blocked before Step 7).
  - Empty fields use the literal "" (not null) — the dispatcher tolerates both, but "" keeps the JSON small.

  This single JSON line is the ONLY artifact the dispatcher reads from your reply. Do NOT additionally write the terminal issue state or attempt state files yourself; the dispatcher (Phase 6) writes those files from this JSON.
</instructions>

<constraints>
- No-fallback. If any {SCRIPTS_DIR}/*.sh exits non-zero, classify and FAIL — never improvise, never re-run with different flags, never call a "simpler" command instead.
- glab CLI only. No curl / wget / Python HTTP / python-gitlab / @gitbeaker.
- Strategy A force-push lives inside {SCRIPTS_DIR}/commit_and_push.sh. No extra `git push --force` outside it. No rebase + re-push.
- Do NOT close the issue. Do NOT call `glab mr merge`. Do NOT touch other issues.
- Hard timeout: 180 minutes wall-clock for the whole subagent run. If you cannot finish, FAIL status=blocked block_reason="executor exceeded 180-minute soft cap".
- Never paste full diffs, full claude_result.txt, or long issue bodies into chat.
</constraints>

<fail_flow>
When any step instructs "FAIL with status=X, block_reason=Y":
  1. Stop the algorithm at this step. Do NOT continue to later steps.
  2. Set ATTEMPT_STATUS=X, BLOCK_REASON=Y.
  3. Immediately sync the live issue label to blocked before summarizing:
     - Run `set_issue_label.sh remove doing` in its own Bash exec.
     - Run `set_issue_label.sh add blocked` in its own Bash exec.
     - If either label-sync exec fails, keep status=X and append `; blocked label sync failed: <stderr>` to BLOCK_REASON. Do not continue to commit, push, Wiki, MR, or pr.
     - Record successful label operations in labels_removed / labels_added. Do not remove `done` if it was already added; a failure after Step 6 should leave the issue as `done` + `blocked` and without `pr`.
  4. Leave commit_sha / merge_request_url / wiki_url empty if those steps were not reached.
  5. Run Step 8 (summarize) with ATTEMPT_STATUS / BLOCK_REASON.
  6. Output the compact JSON per Step 9 with status=X and block_reason=Y filled in.

Always prefer `blocked` over `failed` — the dispatcher promotes `blocked → failed` in Phase 6 only when retry_count exceeds blocked_retry_limit.
</fail_flow>
```

---

## Rendering Notes (for the Dispatcher)

- The placeholder `{ISSUE_TITLE_QUOTED}` is the shell-quoted form of the issue title (single quotes around it; embedded `'` replaced with `'\''`). The plain `{ISSUE_TITLE}` is for the `<issue>` block only — do not inject it raw into a shell command.
- `{ISSUE_BODY}` is for the `<issue>` block only. Truncate to ≤ 4 KB. The full body is already on disk at `{LOG_DIR}/prompt.txt`; the subagent feeds *that file* to acpx.
- The dispatcher MUST verify all placeholders have been substituted before calling `sessions_spawn`. A literal `{` followed by an uppercase identifier in the rendered string is a missed substitution; abort the IID with `block_reason="prompt template render incomplete: <placeholder>"`.
- The dispatcher passes the rendered string as the entire spawn payload. There are no additional env-var injections at the OpenClaw layer — the subagent reads everything from this prompt.
- `timeoutSeconds` for the launch-ack wait: 30. Without this, the harness/gateway defaults to ~10s and has been observed to return only a `childSessionKey` placeholder with no `runId` (no real subagent behind it). 30 gives the runtime enough headroom to return a complete launch ack on a normal day.
- `runTimeoutSeconds` for the subagent runtime cap: 10800. `cleanup`: `keep`. If the trigger supplies `--model` (reserved; not currently a trigger field), forward it.
- **Spawn anonymously, do NOT pass any session name (HARD).** The orchestrator's `sessions_spawn` call MUST NOT include `name=`, `session_name=`, `mode="session"`, or any thread-binding parameter. Earlier deployments hit `errorCode=thread_required` on channels that don't support thread bindings; passing no name avoids that entirely. The runtime returns `runId` + `childSessionKey` (e.g. `agent:acpx_auto_tester:subagent:<uuid>`) — the orchestrator records both into `campaign_state.json.pending_subagents[iid]` for audit + stuck-pending detection. The runtime session-key label is NOT used to match replies — that's done by the `iid` field of the compact JSON (Phase 6 validation rule 2 in `references/state_schema.md` §Compact Subagent Reply). The rendered prompt's `iid` field MUST be correct.
- **Async-callback delivery.** The subagent's compact JSON reply is delivered to the orchestrator via the runtime's `RUN_CHILD_COMPLETION_CALLBACK` trigger, NOT via the synchronous return value of `sessions_spawn`. The subagent itself does not need to know about the callback mechanism — it just emits the compact JSON line on its last turn and stops, exactly as the `<instructions>` Step 9 says. The runtime captures that final line and forwards it inside `worker_result_json` of the callback payload.
- The subagent's compact JSON reply is canonical; the dispatcher uses it for Phase 6 follow-up bookkeeping (state file writes, campaign_state updates, summary aggregation, optional notify). The subagent does NOT write the terminal `issue/state.json` or `issue/attempt_state.json` itself — see `references/state_schema.md` §Compact Subagent Reply and §Phase 6 Write Mapping.
