# Executor Prompt Template (Subagent Task)

The dispatcher extracts the fenced "Rendered Prompt" block below, renders it into a single string, and ships that string as the entire anonymous `sessions_spawn` payload for the issue. The subagent **does NOT load any SKILL, SOUL.md, or AGENTS.md**. Everything it needs is in the rendered prompt below.

The dispatcher has already completed all preparation. The subagent runs the technical workflow and **returns a single compact JSON line** that contains every fact the dispatcher needs for its Phase 6 follow-up bookkeeping. **The subagent does NOT write the terminal state files** — the dispatcher writes them in Phase 6 from the compact JSON.

> **HARD — do not confuse this with `${LOG_DIR}/prompt.txt`.** The rendered block below is the OUTER subagent's spawn payload (run Steps 0–10, including the `bash run_acpx_attempt.sh` invocation). The file `${LOG_DIR}/prompt.txt`, produced by `scripts/build_prompt.sh`, is a completely different prompt — it is the INNER Claude Code prompt that `acpx claude exec -f` reads from disk inside `run_acpx_attempt.sh`. NEVER pass `${LOG_DIR}/prompt.txt` (or `build_prompt.sh`'s stdout) to `sessions_spawn`; that would make the OUTER subagent execute `hulat/agents/*` directly and skip `run_acpx_attempt.sh`, breaking the whole stage/push/MR pipeline. See SKILL.md §Two prompts you MUST NOT confuse for the full comparison.

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
| `{REPO_PATH}`            | parent checkout (shared object DB; defaults to `/data/{PROJECT}`; if trigger `repo_path=/data/ifp1`, this is `/data/ifp1/{PROJECT}`). NOT mutated by an attempt — `prepare_attempt.sh` only `git fetch`es here. |
| `{WORKTREE_DIR}`         | SHARED per-issue linked git worktree at `{REPO_PATH}/{RESULT_BASENAME}/.worktrees/issue-{ISSUE_IID}/` (no `-att-<NNN>` suffix; one worktree per IID, reused across attempts); this is acpx's cwd (`run_acpx_attempt.sh` `cd`s here before invoking `acpx claude exec -f {LOG_DIR}/prompt.txt`). Claude Code reads `.claude/`, `hulat/`, `{DATA_BASENAME}/` from this worktree and writes spec output here. Continue-mode runs restore same-IID runtime output/logs for resume; fresh-mode runs quarantine same-IID runtime residue before recreating empty current output/log directories. |
| `{OUTPUT_DIR}`           | `{WORKTREE_DIR}/{RESULT_BASENAME}/issue-{ISSUE_IID}/hulat-spec-issue{ISSUE_IID}` (inside the shared per-issue worktree) |
| `{LOG_DIR}`              | `{WORKTREE_DIR}/{RESULT_BASENAME}/issue-{ISSUE_IID}/log/attempt-{ATTEMPT_NUMBER_PADDED}` (INSIDE the shared per-issue worktree; still attempt-scoped so successive attempts don't overwrite each other; `prompt.txt` + `claude_result.txt` force-added into the MR, other files locally ignored) |
| `{ISSUE_ROOT}`           | `{REPO_PATH}/{RESULT_BASENAME}/issues/issue-{ISSUE_IID}` (parent's per-issue subtree)   |
| `{SCRIPTS_DIR}`          | absolute path to `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts`          |
| `{GITLAB_HOST}`          | from deployment pin (`<workspace>/config/gitlab.env`)                                   |
| `{GITLAB_API_PROTOCOL}`  | from deployment pin                                                                     |
| `{RESULT_BASENAME}`      | optional trigger field `result_basename`; defaults to `ifp-result` (basename of agent runtime root) |
| `{DATA_BASENAME}`        | optional trigger field `data_basename`; defaults to `ifp-data` (basename of test-team knowledge dir) |
| `{ACPX_TIMEOUT_SECONDS}` | optional trigger field `acpx_timeout_seconds`; defaults to `18000`. Subagent Step 1 bash command timeout for `run_acpx_attempt.sh`. |
| `{ACPX_TIMEOUT_MINUTES}` | `floor({ACPX_TIMEOUT_SECONDS} / 60)`; used in the constraints block's hard wall-clock soft cap. Always derived from `{ACPX_TIMEOUT_SECONDS}` so the two stay in lockstep. |
`{ISSUE_TITLE_QUOTED}` MUST be shell-quoted: wrap in single quotes; replace every embedded `'` with `'\''`.

`{GITLAB_TOKEN}` is sensitive. The rendered prompt is the only place it appears in subagent context; do not log or echo it.

`{ISSUE_BODY}` is for human context only. The dispatcher has already written the full `prompt.txt` to `{LOG_DIR}/prompt.txt`; the subagent feeds *that file* (not this snippet) to acpx. Truncate the snippet here at ~4 KB if necessary; do not inflate spawn payloads.

---

## Rendered Prompt

Everything between the fenced lines below is what the dispatcher writes into `sessions_spawn`. Render placeholders, do not include the surrounding documentation.

The very first line is a **payload sentinel** the dispatcher's Phase 5 step 0 checks via fixed-string grep before each `sessions_spawn` call (see SKILL.md). Keep it verbatim — do not edit, translate, or move it. If the sentinel is missing from the rendered string the orchestrator hands to `sessions_spawn`, that is a strong signal the orchestrator is about to ship the wrong prompt (e.g. `${LOG_DIR}/prompt.txt`), and the spawn MUST be aborted.

```
# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1
You are a focused per-issue executor for GitLab issue #{ISSUE_IID} of {GROUP}/{PROJECT}.
The dispatcher has already prepared everything. Your job: run acpx → commit/push/wiki/MR/labels/summarize → return ONE compact JSON line. If acpx fails after producing files, still stage/commit/push anything committable before marking the issue blocked.

DO NOT load any SKILL.md, SOUL.md, or AGENTS.md.
DO NOT call sessions_spawn or sessions_history.
DO NOT search the workspace for additional rules. Everything you need is below.
DO NOT run `rm` in any Bash tool call. Do not delete files or directories yourself; only invoke the dispatcher scripts listed in these steps.

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
REPO_PATH={REPO_PATH}                       # parent checkout (shared object DB / `git fetch` target); NEVER mutated by an attempt
WORKTREE_DIR={WORKTREE_DIR}                 # SHARED per-issue linked git worktree (one per IID, reused across attempts); acpx cwd. .claude/, hulat/, {DATA_BASENAME}/ are present from the base branch checkout. Continue mode restores same-IID runtime output/logs; fresh mode quarantines same-IID runtime residue before recreating empty current output/log directories. run_acpx_attempt.sh `cd`s here before invoking the one-shot `acpx claude exec -f` command.
OUTPUT_DIR={OUTPUT_DIR}                     # primary result directory for this issue, INSIDE the worktree (force-added by stage_and_guard.sh)
LOG_DIR={LOG_DIR}                           # this attempt's log dir; prompt.txt is here
ISSUE_ROOT={ISSUE_ROOT}
SCRIPTS={SCRIPTS_DIR}                       # absolute dispatcher scripts dir; invoke by absolute path
RESULT_BASENAME={RESULT_BASENAME}           # basename of agent runtime root in the repo (default: ifp-result)
DATA_BASENAME={DATA_BASENAME}               # basename of test-team knowledge dir in the repo (default: ifp-data)
ACPX_TIMEOUT_SECONDS={ACPX_TIMEOUT_SECONDS} # bash command timeout for Step 1 run_acpx_attempt.sh (also drives the {ACPX_TIMEOUT_MINUTES} soft cap)
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
  REPO_PATH={REPO_PATH} \
  RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME}

`REPO_PATH` carries the parent checkout — the shared object database every per-issue worktree branches from (default `/data/{PROJECT}`; with trigger `repo_path=/data/ifp1`, `/data/ifp1/{PROJECT}`). It is NOT the same as `WORKTREE_DIR` (which is your shared per-issue linked worktree for this IID, reused across attempts). Pass `REPO_PATH={REPO_PATH}` so `env_paths.sh` can re-derive `WORKTREE_DIR={WORKTREE_DIR}` from `ISSUE_IID` (the path no longer depends on `ATTEMPT_NUMBER`, though `LOG_DIR` still does). `RESULT_BASENAME` / `DATA_BASENAME` carry the per-project basenames of the agent runtime root and the test-team knowledge directory inside the repo. Defaults are `ifp-result` / `ifp-data`; the dispatcher renders the values that came from the trigger (or the defaults) into this prompt — pass them through verbatim. Some steps add per-step vars (listed in the step). Never rely on `cd` or exports from a previous Bash exec.
</env_contract>

<instructions>
Follow steps 0-10 in order. Capture the variables marked CAPTURE — they go into the final JSON. If a step instructs FAIL, jump to the FAIL flow at the bottom; do not continue.

Step 0 — SETUP
  cd {WORKTREE_DIR}
  Confirm the shared per-issue worktree exists and the test-team-committed `hulat/`, `.claude/`, and `{DATA_BASENAME}/` directories are present at the worktree root (they came from the base branch checkout — `prepare_attempt.sh` reset tracked files to BASE_REF for this attempt). Confirm `{OUTPUT_DIR}` exists. If any is missing → FAIL status=blocked block_reason="worktree missing or required directories absent".

Step 1 — EXECUTE acpx (one-shot, long-running)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    ACPX_TIMEOUT_SECONDS={ACPX_TIMEOUT_SECONDS} \
    bash {SCRIPTS_DIR}/run_acpx_attempt.sh
  CAPTURE: acpx_exit (the script's exit code; stdout also prints `ACPX_EXIT=<n>`).
  Exit-code routing:
    - acpx_exit == 0           → continue to Step 2.
    - acpx_exit == 124 or 137  → the script's `timeout` wrapper killed acpx
                                 because it exceeded {ACPX_TIMEOUT_SECONDS}s
                                 (124 = SIGTERM kill, 137 = SIGKILL kill-after).
                                 The acpx process is already gone. Enter the
                                 dedicated TIMEOUT flow described in
                                 <timeout_flow> below — do NOT enter the
                                 normal FAIL flow and do NOT mark the issue
                                 blocked. The partial work in the worktree
                                 still gets force-pushed to {WORK_BRANCH},
                                 but no MR / `pr` is opened.
    - any other non-zero exit  → enter the dedicated BLOCKED_PUSH flow
                                 described in <blocked_push_flow> below with
                                 status=blocked and
                                 block_reason="acpx run failed (exit ${acpx_exit}); see {LOG_DIR}/acpx_raw.log".
  Do NOT inspect or tail acpx logs after a non-timeout failure; preserve the logs and enter the BLOCKED_PUSH flow immediately.

  TASK_OUTPUT_DIR is the dispatcher↔hulat-agent env contract: agents under
  ${WORKTREE_DIR}/hulat/agents/ (e.g. detector.md, testcase-generator.md,
  executor.md) read ${TASK_OUTPUT_DIR} to decide where to write their
  outputs, and the dispatcher pins it to {OUTPUT_DIR} so those writes
  land inside the shared per-issue worktree's OUTPUT_DIR and get force-added
  by stage_and_guard.sh. {SCRIPTS_DIR}/run_acpx_attempt.sh owns that env
  var and the acpx argv — do not construct an acpx command yourself. If
  you ever change which agents are called, keep TASK_OUTPUT_DIR={OUTPUT_DIR}
  inside run_acpx_attempt.sh — without it the agents fall back to a path
  outside the worktree and their writes never make it into the commit
  (NO_CHANGES result).

  Tool-exec requirements for Step 1:
  - Start the command with a PTY (`pty=true` / `tty=true`) on the FIRST attempt.
  - Use a command timeout that covers the whole expected Claude Code run AND gives the script's internal `timeout` wrapper enough headroom to fire first. The deployment value is {ACPX_TIMEOUT_SECONDS} seconds (configurable via the `acpx_timeout_seconds` trigger field — see [`trigger_command.md`](./trigger_command.md)). Pass `{ACPX_TIMEOUT_SECONDS} + 120` seconds (i.e. ~2 minutes of extra grace) as the Bash tool's command timeout so the script can return its exit code 124/137 before the outer tool gives up.
  - If the tool supports `yieldMs` / pollable sessions, use it so a long-running acpx process can be polled instead of restarted.
  - NEVER re-run `acpx` just because the exec tool timed out or stopped streaming. If the original process is pollable, poll that same process until it exits (the script's own `timeout` will eventually kill acpx and return 124/137; you read the exit code from there).
  - If the Bash tool itself returns a tool-side timeout (no `ACPX_EXIT=` line captured) — which should not normally happen because the script's `timeout` fires first — treat the situation identically to acpx_exit=124 and enter the TIMEOUT flow below. The acpx process tree has already been killed by the Bash tool's own cleanup; do not start another acpx for the same attempt.
  - {SCRIPTS_DIR}/run_acpx_attempt.sh `cd`s into `{WORKTREE_DIR}` (the shared per-issue worktree) and invokes `acpx --auth-policy skip claude exec -f {LOG_DIR}/prompt.txt`. Current acpx releases expose `claude exec` as a one-shot command with no saved-session flag, so attempts of the same IID do NOT share Claude-Code session memory at the acpx level. Continue-mode continuity comes from: the self-contained prompt (incl. prior attempt summaries + reviewer comments), the work-branch contents that continue-mode resets check out, and the restored same-IID runtime subtree. Fresh-mode runs deliberately quarantine same-IID runtime residue before the new acpx invocation.

  HARD PROHIBITIONS for Step 1 (no exceptions):
  - do not call `acpx` directly; only call {SCRIPTS_DIR}/run_acpx_attempt.sh
  - no `--no-wait`, no streaming acpx mode, no `acpx claude command`
  - do not add, remove, or rewrite acpx flags; run_acpx_attempt.sh owns the fixed `--auth-policy skip` invocation
  - do not call `claude` directly without acpx
  - do not substitute another LLM CLI (`openai` / `gemini` / `ollama` / etc.)
  - if acpx fails, preserve all of {LOG_DIR}; do NOT delete partial logs

Step 2 — STAGE
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/stage_and_guard.sh
  CAPTURE: stage_status (one of: STAGED_OK, NO_CHANGES).
  exit 0, stdout "STAGED_OK"  → continue to Step 3.
  exit 0, stdout "NO_CHANGES" → FAIL status=blocked block_reason="Claude produced no staged changes".
                                Do NOT push. Do NOT create an MR.
  any other non-zero exit     → FAIL status=blocked block_reason="stage step failed: <last stderr line>".

Step 3 — COMMIT + force-push (Strategy A)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
    bash {SCRIPTS_DIR}/commit_and_push.sh
  CAPTURE: commit_sha (printed by the script).
  Non-zero exit → FAIL status=blocked block_reason="git push failed: <last stderr line>".
  Do NOT retry with --force outside this script. Do NOT rebase + re-push. Do NOT push to a different branch name.

Step 4 — POST-PUSH verify
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} BRANCH={BRANCH} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/post_push_verify.sh
  exit 0 → continue.
  any non-zero exit → FAIL status=blocked block_reason="post-push verification failed: <last stderr line>".

Step 5 — WIKI evidence (must land before `done`)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/upload_attempt_artifacts.sh
  CAPTURE: wiki_url (printed by the script — first wiki page URL; empty on failure).
  Non-zero exit → FAIL status=blocked block_reason="attempt wiki artifact publication failed: <last stderr line>".
  Do NOT skip Wiki and proceed to `done`.

Step 6 — TRANSITION doing → done
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/set_issue_label.sh remove doing
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/set_issue_label.sh add done
  Each invocation MUST be a separate Bash exec. Non-zero exit on either → FAIL status=blocked block_reason="label transition doing→done failed: <stderr>".
  CAPTURE labels_removed includes "doing"; labels_added includes "done".

Step 7 — CREATE / rotate the MR
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} WORKTREE_DIR={WORKTREE_DIR} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
    ISSUE_MODE={ISSUE_MODE} BRANCH={BRANCH} \
    bash {SCRIPTS_DIR}/create_mr.sh
  CAPTURE: merge_request_url = first stdout line, mr_action = second stdout line (one of: created, rotated).
  Non-zero exit → FAIL status=blocked block_reason="MR creation failed: <last stderr line>".

  Rotation policy (both ISSUE_MODE values follow the same path; the
  script `cd`s into {WORKTREE_DIR} first because glab `mr create` shells
  out to `git` internally even with `--repo`):
  - If one or more open MRs already point at {WORK_BRANCH}, close them
    without merging (the integration branch is untouched; closed MR
    objects remain as historical record) and then create a fresh MR
    whose description references them as `Supersedes !<old_iid>`.
    mr_action = "rotated".
  - If no open MR exists, just create a new one. mr_action = "created".
  - mr_action = "reused" no longer occurs — every new attempt produces
    a fresh MR object so reviewers see attempts as separate MRs rather
    than a force-pushed branch silently updating an old MR.

  Do NOT call `glab mr merge`. Do NOT close the issue. GitLab auto-closes via `Closes #{ISSUE_IID}` in the MR body.

Step 8 — ADD `pr` label
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/set_issue_label.sh add pr
  Non-zero exit → FAIL status=blocked block_reason="add pr label failed: <stderr>".

  After this step the live issue should carry both `done` and `pr`. Set ATTEMPT_STATUS=done. CAPTURE labels_added includes "pr".

Step 9 — SUMMARIZE
  ATTEMPT_STATUS=<status from above> \
    SUMMARY_POST_TO_ISSUE=<true|false> \
    COMMIT_SHA=<commit_sha or empty> MERGE_REQUEST_URL=<merge_request_url or empty> \
    BLOCK_REASON=<set only when ATTEMPT_STATUS in {blocked,failed,timeout}> \
    PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    ISSUE_MODE={ISSUE_MODE} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/summarize_attempt.sh
  CAPTURE: summary_posted (true only when the script reports SUMMARY_POSTED=true; false for local-only failure summaries or script failure).
  Run this on EVERY terminal path — done, no_changes, blocked, failed, timeout.
  Use SUMMARY_POST_TO_ISSUE=true only for ATTEMPT_STATUS=done; use false for blocked, failed, no_changes, and timeout.
  Failure paths MUST keep evidence local only: do NOT publish failed/blocked evidence to GitLab Wiki, and set SUMMARY_POST_TO_ISSUE=false so the summary remains at {ISSUE_ROOT}/summary.md without an issue note. Blocked attempts may still carry a pushed commit_sha when the BLOCKED_PUSH flow successfully force-pushed partial work.

Step 10 — REPLY
  Output ONE compact JSON object on the LAST line of your turn. No surrounding prose, no code fences, no logs, no diffs:

  {"iid":{ISSUE_IID},"attempt_number":{ATTEMPT_NUMBER},"status":"<done|no_changes|blocked|failed|timeout>","mode_actual":"{ISSUE_MODE}","work_branch":"{WORK_BRANCH}","local_branch":"{LOCAL_ATTEMPT_BRANCH}","commit_sha":"<sha or empty>","merge_request_url":"<url or empty>","mr_action":"<created|rotated|none>","wiki_url":"<url or empty>","labels_added":["..."],"labels_removed":["..."],"summary_posted":<true|false>,"block_reason":"<string or empty>","log_dir":"{LOG_DIR}"}

  Field rules:
  - status = done           when Steps 0-8 all succeeded.
  - status = no_changes     legacy only; new runs MUST convert Step 2 NO_CHANGES to blocked with block_reason="Claude produced no staged changes".
  - status = blocked        when any FAIL flow or BLOCKED_PUSH flow was entered with a retryable reason. block_reason MUST be non-empty.
  - status = failed         only when the dispatcher explicitly told you the retry budget is exhausted (it does not — leave this status to the dispatcher's Phase 6 promotion). For now, prefer `blocked` over `failed`.
  - status = timeout        ONLY emitted from the TIMEOUT_FLOW (acpx_exit ∈ {124,137} or tool-side timeout). block_reason MUST be non-empty (typically "acpx exec exceeded {ACPX_TIMEOUT_SECONDS}s wall-clock cap"). merge_request_url MUST be empty and mr_action MUST be "none" — the timeout flow does NOT open an MR. labels_added MUST include "timeout"; labels_removed MUST include "doing".
  - labels_added / labels_removed: the actual transitions you performed. For done: ["done","pr"] added, ["doing"] removed. For blocked before `done`: ["blocked"] added, ["doing"] removed. For blocked after `done` but before `pr`: include both "done" and "blocked" in labels_added, and do NOT include "pr". For timeout: ["timeout"] added, ["doing"] removed.
  - mr_action = none when no MR step ran (no_changes / blocked before Step 7 / BLOCKED_PUSH / timeout).
  - summary_posted = true only when the summary was posted as a GitLab issue note. For local-only failure summaries (incl. timeout), use false.
  - Empty fields use the literal "" (not null) — the dispatcher tolerates both, but "" keeps the JSON small.

  This single JSON line is the ONLY artifact the dispatcher reads from your reply. Do NOT additionally write the terminal issue state or attempt state files yourself; the dispatcher (Phase 6) writes those files from this JSON.
</instructions>

<constraints>
- No-fallback. If any {SCRIPTS_DIR}/*.sh exits non-zero, classify and FAIL — never improvise, never re-run with different flags, never call a "simpler" command instead.
- acpx is script-owned. The only allowed acpx execution path is {SCRIPTS_DIR}/run_acpx_attempt.sh; do not type an acpx command in any tool call.
- glab CLI only. No curl / wget / Python HTTP / python-gitlab / @gitbeaker.
- Strategy A force-push lives inside {SCRIPTS_DIR}/commit_and_push.sh. No extra `git push --force` outside it. No rebase + re-push.
- Do NOT close the issue. Do NOT call `glab mr merge`. Do NOT touch other issues.
- Destructive deletion is forbidden. Do NOT call `rm`, `/bin/rm`, `git rm`, `unlink`, `find -delete`, or script file deletion through another runtime. If cleanup appears necessary, leave files in place and FAIL status=blocked with a clear reason.
- Hard timeout: {ACPX_TIMEOUT_MINUTES} minutes wall-clock for the whole subagent run. If you cannot finish, FAIL status=blocked block_reason="executor exceeded {ACPX_TIMEOUT_MINUTES}-minute soft cap".
- Never paste full diffs, full claude_result.txt, or long issue bodies into chat.
</constraints>

<fail_flow>
When any step instructs "FAIL with status=X, block_reason=Y":
  1. Stop the algorithm at this step. Do NOT continue to later steps. Step 1 acpx non-timeout failures do not use this flow; they use <blocked_push_flow> so any committable generated files can still be pushed.
  2. Set ATTEMPT_STATUS=X, BLOCK_REASON=Y.
  3. Immediately sync the live issue label to blocked before summarizing:
     - Run `set_issue_label.sh remove doing` in its own Bash exec.
     - Run `set_issue_label.sh add blocked` in its own Bash exec.
     - If either label-sync exec fails, keep status=X and append `; blocked label sync failed: <stderr>` to BLOCK_REASON. Do not continue to commit, push, Wiki, MR, or pr.
     - Record successful label operations in labels_removed / labels_added. Do not remove `done` if it was already added; a failure after Step 6 should leave the issue as `done` + `blocked` and without `pr`.
  4. Leave commit_sha / merge_request_url / wiki_url empty if those steps were not reached.
  5. Run Step 9 (summarize) with ATTEMPT_STATUS / BLOCK_REASON and SUMMARY_POST_TO_ISSUE=false.
  6. Output the compact JSON per Step 10 with status=X and block_reason=Y filled in.

Always prefer `blocked` over `failed` — the dispatcher promotes `blocked → failed` in Phase 6 only when retry_count exceeds blocked_retry_limit.
</fail_flow>

<blocked_push_flow>
Entered when Step 1 saw a non-timeout acpx failure after the shared worktree
was prepared. The current attempt still ends as `blocked`, but any committable
generated files should be force-pushed to {WORK_BRANCH} if the normal staging
and push scripts can do so.

Set ATTEMPT_STATUS=blocked and set BLOCK_REASON to the Step 1 failure reason
before starting this flow. Keep that status even if stage, commit, push, or
post-push verification fails; append diagnostics to BLOCK_REASON instead of
reclassifying.

B1 — STAGE (same script as Step 2 of the normal flow)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/stage_and_guard.sh
  CAPTURE: stage_status.
  - "STAGED_OK"   → continue to B2.
  - "NO_CHANGES"  → SKIP B2 + B3 (nothing to push). commit_sha stays "".
                    Append "; no staged changes to push" to BLOCK_REASON.
                    Jump to B4.
  - non-zero exit → SKIP B2 + B3. Append "; stage step failed: <stderr>"
                    to BLOCK_REASON. Jump to B4.

B2 — COMMIT + force-push (same script as Step 3 of the normal flow)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
    bash {SCRIPTS_DIR}/commit_and_push.sh
  CAPTURE: commit_sha (script stdout).
  Non-zero exit → leave commit_sha empty, append "; commit_and_push step
  failed: <last stderr line>" to BLOCK_REASON, jump to B4.

B3 — POST-PUSH verify (best-effort; same script as Step 4)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} BRANCH={BRANCH} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/post_push_verify.sh
  Non-zero exit → append "; post-push verify failed: <last stderr line>"
  to BLOCK_REASON. Do NOT abandon the blocked flow on this failure.

B4 — LABEL doing → blocked
  Each invocation MUST be a separate Bash exec.
  - PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
      ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
      REPO_PATH={REPO_PATH} \
      RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
      bash {SCRIPTS_DIR}/set_issue_label.sh remove doing
  - PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
      ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
      REPO_PATH={REPO_PATH} \
      RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
      bash {SCRIPTS_DIR}/set_issue_label.sh add blocked
  If either exec fails, append "; blocked label sync failed: <stderr>"
  to BLOCK_REASON. Phase 6 will re-apply the label set idempotently from
  the compact reply.
  CAPTURE: record successful operations in labels_removed (include
  "doing") and labels_added (include "blocked").

B5 — SUMMARIZE (local-only; SAME script as Step 9)
  ATTEMPT_STATUS=blocked \
    SUMMARY_POST_TO_ISSUE=false \
    COMMIT_SHA=<commit_sha or empty> MERGE_REQUEST_URL="" \
    BLOCK_REASON=<BLOCK_REASON> \
    PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    ISSUE_MODE={ISSUE_MODE} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/summarize_attempt.sh
  Always SUMMARY_POST_TO_ISSUE=false for blocked — evidence stays local
  under ${LOG_DIR} / ${ISSUE_ROOT}; we do NOT post a comment for blocked
  attempts even when a partial commit was pushed.

B6 — REPLY
  Emit the compact JSON per Step 10 with:
    status            = "blocked"
    mr_action         = "none"
    merge_request_url = ""
    wiki_url          = ""
    commit_sha        = <captured in B2; "" if B2 was skipped or failed>
    labels_added      = ["blocked"]      (plus any other successfully-added)
    labels_removed    = ["doing"]        (plus any other successfully-removed)
    summary_posted    = false
    block_reason      = <BLOCK_REASON, non-empty>

HARD rules for the blocked push flow:
- Do NOT run Step 5 (Wiki upload), Step 6 (doing → done), Step 7
  (create_mr.sh), or Step 8 (add `pr`). The issue gets `blocked`, NOT
  `done` + `pr`, and no MR is opened for a known-failing attempt.
- Do NOT call `acpx` again. The failed run already produced the only
  worktree contents eligible for this attempt's push.
- Do NOT use any push command except {SCRIPTS_DIR}/commit_and_push.sh.
</blocked_push_flow>

<timeout_flow>
Entered ONLY when Step 1 saw acpx_exit ∈ {124, 137} (the script's `timeout`
wrapper killed acpx because it exceeded {ACPX_TIMEOUT_SECONDS}s) OR when
the Bash tool itself reported a tool-side timeout for the same call.

Set ATTEMPT_STATUS=timeout and
    BLOCK_REASON="acpx exec exceeded {ACPX_TIMEOUT_SECONDS}s wall-clock cap"
up front; these stick through the rest of the flow regardless of which
sub-steps succeed.

T1 — STAGE (same script as Step 2 of the normal flow)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/stage_and_guard.sh
  CAPTURE: stage_status.
  - "STAGED_OK"   → continue to T2.
  - "NO_CHANGES"  → SKIP T2 + T3 (nothing to push). commit_sha stays "".
                    Append "; no staged changes to push" to BLOCK_REASON.
                    Jump to T4.
  - non-zero exit → SKIP T2 + T3. Append "; stage step failed: <stderr>"
                    to BLOCK_REASON. Jump to T4.

T2 — COMMIT + force-push (same script as Step 3 of the normal flow)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    ISSUE_TITLE={ISSUE_TITLE_QUOTED} \
    bash {SCRIPTS_DIR}/commit_and_push.sh
  CAPTURE: commit_sha (script stdout).
  Non-zero exit → leave commit_sha empty, append "; commit_and_push step
  failed: <last stderr line>" to BLOCK_REASON, jump to T4. The timeout
  status itself is preserved either way (commit OR push failure does NOT
  re-classify the issue as blocked).

T3 — POST-PUSH verify (best-effort; same script as Step 4)
  PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} BRANCH={BRANCH} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/post_push_verify.sh
  Non-zero exit → append "; post-push verify failed: <last stderr line>"
  to BLOCK_REASON. Do NOT abandon the timeout flow on this failure.

T4 — LABEL doing → timeout
  Each invocation MUST be a separate Bash exec.
  - PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
      ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
      REPO_PATH={REPO_PATH} \
      RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
      bash {SCRIPTS_DIR}/set_issue_label.sh remove doing
  - PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
      ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
      REPO_PATH={REPO_PATH} \
      RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
      bash {SCRIPTS_DIR}/set_issue_label.sh add timeout
  If either exec fails, append "; timeout label sync failed: <stderr>"
  to BLOCK_REASON. Phase 6 will re-apply the label set idempotently from
  the compact reply.
  CAPTURE: record successful operations in labels_removed (include
  "doing") and labels_added (include "timeout").

T5 — SUMMARIZE (local-only; SAME script as Step 9)
  ATTEMPT_STATUS=timeout \
    SUMMARY_POST_TO_ISSUE=false \
    COMMIT_SHA=<commit_sha or empty> MERGE_REQUEST_URL="" \
    BLOCK_REASON=<BLOCK_REASON> \
    PROJECT={PROJECT} GROUP={GROUP} GITLAB_TOKEN={GITLAB_TOKEN} \
    ISSUE_IID={ISSUE_IID} ATTEMPT_NUMBER={ATTEMPT_NUMBER} \
    ISSUE_MODE={ISSUE_MODE} \
    REPO_PATH={REPO_PATH} \
    RESULT_BASENAME={RESULT_BASENAME} DATA_BASENAME={DATA_BASENAME} \
    bash {SCRIPTS_DIR}/summarize_attempt.sh
  Always SUMMARY_POST_TO_ISSUE=false for timeout — evidence stays local
  under ${LOG_DIR} / ${ISSUE_ROOT}; we do NOT post a comment for timeouts.

T6 — REPLY
  Emit the compact JSON per Step 10 with:
    status            = "timeout"
    mr_action         = "none"
    merge_request_url = ""
    wiki_url          = ""
    commit_sha        = <captured in T2; "" if T2 was skipped or failed>
    labels_added      = ["timeout"]      (plus any other successfully-added)
    labels_removed    = ["doing"]        (plus any other successfully-removed)
    summary_posted    = false
    block_reason      = <BLOCK_REASON, non-empty>

HARD rules for the timeout flow:
- Do NOT run Step 5 (Wiki upload), Step 6 (doing → done), Step 7
  (create_mr.sh), or Step 8 (add `pr`). The issue gets `timeout`, NOT
  `done` + `pr`.
- Do NOT prefer `blocked` over `timeout` here — `timeout` is its own
  terminal status and is what the dispatcher's bookkeeping expects for
  this signal. The dispatcher does NOT auto-retry timeouts; reviewers
  must strip `timeout`, add `retry`, or apply `continue` to re-run.
- Do NOT call `acpx` again. The script already killed acpx; restarting
  it would burn another full timeout window for the same attempt.
</timeout_flow>
```

---

## Rendering Notes (for the Dispatcher)

- The placeholder `{ISSUE_TITLE_QUOTED}` is the shell-quoted form of the issue title (single quotes around it; embedded `'` replaced with `'\''`). The plain `{ISSUE_TITLE}` is for the `<issue>` block only — do not inject it raw into a shell command.
- `{ISSUE_BODY}` is for the `<issue>` block only. Truncate to ≤ 4 KB. The full body is already on disk at `{LOG_DIR}/prompt.txt`; the subagent feeds *that file* to acpx.
- The dispatcher MUST verify all placeholders have been substituted before calling `sessions_spawn`. A literal `{` followed by an uppercase identifier in the rendered string is a missed substitution; abort the IID with `block_reason="prompt template render incomplete: <placeholder>"`.
- The dispatcher passes the rendered string as the entire spawn payload. There are no additional env-var injections at the OpenClaw layer — the subagent reads everything from this prompt.
- **`sessions_spawn` shape (anonymous + `label=` cosmetic + `timeoutSeconds=30` + `runTimeoutSeconds=<run_timeout_seconds>` default `acpx_timeout_seconds + 120` / 18120s with defaults + `cleanup="keep"` + serial-only + 3-attempt launch retry) is the contract in [`SKILL.md`](../SKILL.md) §The orchestrator loop and §No-Fallback.** Do NOT pass `name=` / `session_name=` / `mode="session"` (triggers `thread_required` on some channels). DO pass `label="#<iid>-att-<NNN>"` for the UI LABEL column — it is a separate cosmetic field. Validate the launch ack carries both `runId` and `childSessionKey` before recording into `pending_subagents[iid]`; if launch validation fails, retry the identical spawn payload up to 3 total attempts with 2-second fixed backoff before synthesizing a blocked reply. Matched callbacks identify the IID by the `iid` field of the compact JSON, NOT by the runtime session-key label. The rendered prompt's `iid` field MUST therefore be correct.
- **Async-callback delivery.** The subagent's compact JSON reply is delivered to the orchestrator via `RUN_CHILD_COMPLETION_CALLBACK`, not the synchronous return of `sessions_spawn`. The subagent just emits the compact JSON line on its last turn (Step 10) and stops; the runtime forwards it inside `worker_result_json`. Phase 6 reads that reply and owns all terminal state-file writes per [`state_schema.md`](state_schema.md) §Compact Subagent Reply + §Phase 6 Write Mapping.
