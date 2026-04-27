---
name: gitlab_single_issue_executor
description: "[SKILL_VERSION=2026-04-24.5] Execute one GitLab issue in one dedicated session. Clone or pull the repository, ensure labels exist, set the issue to doing, invoke Claude Code through acpx, persist logs, commit and push changes, create a merge request to master without merging, and update per-issue state on disk. Supports blocked and failed states for retryable scheduling. For this automation, a merge request being created successfully is the terminal completion condition, so the issue must be labeled `done` immediately after MR creation succeeds."
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Single-Issue Executor Skill

**SKILL_VERSION: 2026-04-24.5**

The executor MUST include `"skill_version": "2026-04-24.5"` in its compact chat summary, and MUST write the same string into `${ISSUE_STATE_FILE}.skill_version`. This lets the operator verify which version of the skill is actually loaded.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — populates path variables (SOURCE it).
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`.
- `scripts/clone_or_pull.sh` — clone or update `${REPO_PATH}`.
- `scripts/prepare_branch.sh` — clean working tree, create `${WORK_BRANCH}` from clean integration branch.
- `scripts/ensure_labels.sh` — make sure the six workflow labels exist.
- `scripts/set_issue_label.sh` — add or remove a single label (used for every transition).
- `scripts/stage_and_guard.sh` — `git add -A` + leak guard; prints `STAGED_OK` or `NO_CHANGES`.
- `scripts/commit_and_push.sh` — commit + push the work branch.
- `scripts/post_push_verify.sh` — confirm the remote branch contains no agent artifacts.
- `scripts/create_mr.sh` — create the MR via `glab mr create` and print its URL.
- `references/paths.md` — full path layout and required artifacts.
- `references/state_schema.md` — `issue-<iid>.json` schema and update cadence.
- `references/glab_commands.md` — exhaustive list of allowed `glab` invocations.
- `references/label_lifecycle.md` — label transitions and how to perform them.

When in doubt about a path / schema / command / transition, READ the matching reference file. Do NOT reconstruct content from memory.

---

## No-Fallback Policy (READ FIRST — HARD RULE)

**The executor MUST follow the prescribed method exactly. When the prescribed method fails, the executor marks the issue `blocked` (or `failed`) and stops — it does NOT improvise an alternative approach.**

This rule overrides any default model behavior that says "try another way", "be helpful", "complete the task one way or another", or "the user wants this to succeed". For this skill, **a clean controlled failure is strictly better than an unsupervised alternative attempt**.

### Concrete prohibitions

1. If a script in `scripts/` exits non-zero, the executor MUST NOT:
   - rewrite the script's logic inline in bash
   - skip the script and "do the same thing manually"
   - try a "simpler" or "different" command that "should work"
   The executor reads the script's stdout/stderr, classifies the failure, writes per-issue state accordingly, and stops.
2. If `acpx claude exec -f "${LOG_DIR}/prompt.txt"` fails or Claude Code errors out mid-execution, the executor MUST NOT:
   - retry the same prompt with a smaller or different prompt
   - switch to `acpx claude command`, persistent `acpx claude` sessions (`-s`), `--no-wait`, or any other acpx mode
   - run `claude` directly without acpx
   - call any other LLM CLI (`openai`, `gemini`, `ollama`, etc.) as a substitute
   - manually edit the repo to "do what Claude was supposed to do"
   - re-run acpx with a tweaked working directory or a different `${HULAT_DIR}` value
   The exact and ONLY allowed invocation is the one in "Claude Code Execution Contract" below. If it fails, mark the issue `blocked` (retryable) or `failed` (non-recoverable / retry-exhausted) with an accurate `block_reason`, preserve all logs under `${LOG_DIR}`, and return.
3. If `glab` cannot do something, the executor MUST NOT fall back to `curl` / `wget` / Python HTTP / `python-gitlab` / any HTTP library. (Also covered by GitLab Access Policy.)
4. If `git push` is rejected (non-fast-forward, hook rejection, auth, etc.), the executor MUST NOT:
   - `git push --force` / `--force-with-lease`
   - rewrite history with `git rebase` / `git reset --hard` and re-push
   - push to a different branch name
   Mark the issue `blocked` with the rejection reason verbatim and stop.
5. If `prepare_branch.sh` cannot produce a clean working tree, the executor MUST NOT manually `rm -rf` parts of the repo or skip the clean step. Mark the issue `blocked` with `block_reason="working tree could not be cleaned: <reason>"` and stop.
6. If `stage_and_guard.sh` exits 3 (artifact leak), the executor MUST NOT manually `git rm` the leaked paths and re-run staging. The leak indicates a prior bug that must be investigated; mark `blocked` with `block_reason="agent artifacts leaked into repo working tree"` and stop.
7. If `post_push_verify.sh` exits 4 (remote polluted), the executor MUST NOT manually `git push --delete` and rebuild. Mark `blocked` with `block_reason="remote branch polluted with agent artifacts"` and stop.
8. If `create_mr.sh` fails, the executor MUST NOT create the MR through the GitLab web UI scrape, through `git push --push-option=merge_request.create`, or by manually crafting an HTTP request. Mark `blocked` and stop.
9. If a required input is missing or malformed, the executor MUST abort with `status=blocked`, `block_reason="missing required input: <field>"`. It MUST NOT guess a default.

### What the executor does on failure

For every failure path:

1. Write the failure into `${LOG_DIR}` with the rawest possible detail (stderr, exit code, command line, current working directory).
2. Update `${ISSUE_STATE_FILE}`:
   - retryable env / runtime / connectivity issue → `status=blocked`, increment `retry_count`, set `block_reason`
   - `retry_count > blocked_retry_limit` or non-recoverable → `status=failed`, set `block_reason`
3. Do NOT push, do NOT create an MR, do NOT change the issue label to `done`.
4. Return the compact chat summary with the failure status.

### What "improvising" looks like (forbidden examples)

- "`acpx claude exec` returned non-zero, let me retry with `acpx claude command -p ...`." — forbidden.
- "Claude Code crashed halfway through, let me complete the remaining edits by hand based on its output so far." — forbidden.
- "`glab mr create` failed, let me POST to `/api/v4/projects/.../merge_requests` with curl." — forbidden.
- "`git push` was rejected because of a server-side hook, let me `git push --force` to overwrite." — forbidden.
- "The work branch already exists on the remote, let me delete it and try again." — forbidden (mark `blocked` instead).
- "`set_issue_label.sh` returned a 403, let me set the label by editing the issue description through the web UI." — forbidden.

If you find yourself reaching for a tool, command, flag, or workflow that is not explicitly listed in this SKILL, in `scripts/`, or in `references/`, that is the signal to stop and fail — not the signal to try harder.

---

## Single-Issue Rule (READ FIRST — HARD RULE)

**One dedicated session executes exactly ONE issue, ever.**

- Never reuse an executor session for a different IID. The session name `issue-<project>-<iid>` is bound to that IID for life.
- All scripts assume `${ISSUE_IID}` is fixed for the session. Changing it mid-session is a bug.

---

## GitLab Access Policy (READ FIRST — HARD RULE)

The executor MUST access GitLab exclusively through the `glab` CLI, via the scripts in `scripts/` and the commands documented in `references/glab_commands.md`.

Forbidden — never used to talk to GitLab:

- `curl`, `wget`, `http`, `httpie`
- Any HTTP library in any language (`requests`, `urllib`, `python-gitlab`, `@gitbeaker/*`, etc.)
- `glab mr merge` (under any circumstances — MRs stay open)
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use `set_issue_label.sh` instead.
- Any `glab` subcommand or flag not listed in `references/glab_commands.md`.

If a required operation is not in the allowed list, mark the issue `blocked` with `block_reason="executor needs unsupported glab op: <description>"` and stop. Do NOT fall back to curl.

If `glab auth status` fails after `scripts/glab_auth.sh`, mark the issue `blocked` with `block_reason="glab auth failed"` and stop.

---

## Repo Cleanliness Policy (READ FIRST — HARD RULE)

The pushed work branch MUST contain ONLY this issue's code changes. No agent logs, no agent state, no artifacts from other issues.

- All agent-owned files live under `${WORK_ROOT} = /data/openclaw_work/${PROJECT}/`, OUTSIDE the repo working tree. See `references/paths.md`.
- `scripts/prepare_branch.sh` enforces a pristine working tree before branching (reset + clean -fdx).
- `scripts/stage_and_guard.sh` aborts with exit 3 if any `openclaw_log/` or `openclaw_state/` path appears in the staged tree.
- `scripts/post_push_verify.sh` aborts with exit 4 if the remote branch contains any such path.

If either guard trips, mark the issue `blocked`. Do NOT attempt to push or open an MR.

---

## Inputs

Required from the trigger command (`RUN_SINGLE_ISSUE_SESSION`):

- `gitlab_address`, `group`, `project`, `branch`, `hulat_dir`, `gitlab_token`, `issue_iid`, `non_interactive=true`

Optional:

- `blocked_retry_limit`

`hulat_dir` is a string passed through to the Claude Code prompt. The executor itself never `cd`s into it or writes there. See `references/paths.md`.

---

## Claude Code Execution Contract

This is the ONLY way the executor is allowed to invoke Claude Code. It is governed by the No-Fallback Policy above — when this contract fails, the executor stops; it does NOT switch invocation modes or LLMs.

- Build the prompt at `${LOG_DIR}/prompt.txt` with: target issue body, `hulat_dir` reference, instruction to "work only on this issue, modify content under `${REPO_PATH}`, do not ask the user, summarize briefly when done".
- Run synchronously, one-shot, with `${REPO_PATH}` as the working directory:
  ```bash
  cd "${REPO_PATH}"
  acpx claude exec -f "${LOG_DIR}/prompt.txt" \
    1>"${LOG_DIR}/claude_result.txt" \
    2>"${LOG_DIR}/acpx_raw.log"
  ```
  This exact command is the contract. Wait for it to return.
- **Hard prohibitions on the invocation form:**
  - `-s` (persistent session) — forbidden
  - `--no-wait` — forbidden
  - `acpx claude command` — forbidden
  - any persistent / streaming acpx mode — forbidden
  - calling `claude` directly without acpx — forbidden
  - any non-Claude LLM CLI as a substitute (`openai`, `gemini`, `ollama`, etc.) — forbidden
- Claude must write only inside `${REPO_PATH}`. It MUST NOT write into `${WORK_ROOT}`, `${HULAT_DIR}`, or anywhere else.

### What to do when this contract fails

If `acpx claude exec` returns non-zero, hangs and is killed by the runtime, or Claude Code itself reports an error mid-execution:

1. Preserve all output that was written to `${LOG_DIR}` (do NOT delete partial logs).
2. Classify the failure from the stderr / exit code:
   - retryable (runtime / library mismatch, transient env failure, transient credential / connectivity, acpx process startup failure): `status=blocked`, increment `retry_count`, set `block_reason` to the verbatim error
   - non-recoverable or `retry_count > blocked_retry_limit`: `status=failed`, set `block_reason`
3. Do NOT push, do NOT open an MR, do NOT label the issue `done`.
4. Return the compact chat summary with the failure status and stop.

**Forbidden recovery moves (per No-Fallback Policy):**

- Re-running with a tweaked or shortened prompt
- Switching to `acpx claude command` / persistent session / `--no-wait`
- Running `claude` directly
- Using a different LLM
- Manually editing the repo to "complete what Claude was supposed to do"
- Re-running with a different working directory or `${HULAT_DIR}`

---

## Executor Algorithm

Run once per session for `${ISSUE_IID}`.

1. **Bootstrap.**
   - `PROJECT=<project> ISSUE_IID=<iid> source scripts/env_paths.sh`
   - `GITLAB_HOST="$(bash scripts/glab_auth.sh)"`; export `PROJECT_FULL`, `PROJECT_URI`. If auth fails, mark `blocked` with `block_reason="glab auth failed"` and stop.
2. **Sync repo.** `bash scripts/clone_or_pull.sh`.
3. **Read the target issue.** Use command E1 from `references/glab_commands.md`. Capture title, description, current labels into shell variables; `ISSUE_TITLE` is the short form for commit / MR title.
4. **Ensure labels exist.** `bash scripts/ensure_labels.sh`.
5. **Transition `todo → doing`.** Use `scripts/set_issue_label.sh remove todo`, then `... add doing`. (Idempotent — safe even if `todo` was absent.)
6. **Initialize / refresh per-issue state.** Per `references/state_schema.md`: write `status=in_progress`, increment `retry_count` if this is a retry, set `skill_version`, `updated_at`.
7. **Prepare work branch.** `bash scripts/prepare_branch.sh`. Write `work_branch=${WORK_BRANCH}` into `${ISSUE_STATE_FILE}`.
8. **Run Claude Code** as per the execution contract above. On failure follow the retryable / non-recoverable rules.
9. **Stage + guard.**
   ```bash
   bash scripts/stage_and_guard.sh
   ```
   - Exit 3 → leak detected. Mark `status=blocked`, `block_reason="agent artifacts leaked into repo working tree"`, stop.
   - `NO_CHANGES` → `status=no_changes`, keep logs, stop. Do NOT push.
   - `STAGED_OK` → continue.
10. **Commit + push.** `ISSUE_TITLE="..." bash scripts/commit_and_push.sh` (prints commit SHA). Write `commit_sha` into the state file.
11. **Post-push verify.** `bash scripts/post_push_verify.sh`. Exit 4 → mark `status=blocked`, `block_reason="remote branch polluted with agent artifacts"`, stop.
12. **Create MR.** `ISSUE_TITLE="..." bash scripts/create_mr.sh` (prints MR URL). Write `merge_request_url` into the state file.
13. **Transition `doing → pr → done`.** Per `references/label_lifecycle.md`: remove `doing` add `pr`; immediately remove `pr` add `done`. The issue must NOT be left at `pr`.
14. **Finalize.** Write `status=done` and `updated_at` to `${ISSUE_STATE_FILE}`. Return the compact chat summary.

---

## Chat Output Policy

Return a single compact JSON summary. Examples:

```json
{
  "skill_version": "2026-04-24.5",
  "iid": 14,
  "status": "done",
  "work_branch": "issue/14-auto-fix",
  "commit_sha": "abc1234...",
  "merge_request_url": "http://gitlab.example.com/..."
}
```

```json
{
  "skill_version": "2026-04-24.5",
  "iid": 14,
  "status": "blocked",
  "retry_count": 2,
  "block_reason": "Claude Code runtime requires GLIBC 2.29+"
}
```

Never paste full logs, full diffs, or long issue bodies into chat. Detailed evidence stays under `${LOG_DIR}`.
