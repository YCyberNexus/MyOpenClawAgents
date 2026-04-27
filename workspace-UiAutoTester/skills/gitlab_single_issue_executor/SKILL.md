---
name: gitlab_single_issue_executor
description: "[SKILL_VERSION=2026-04-24.4] Execute one GitLab issue in one dedicated session. Clone or pull the repository, ensure labels exist, set the issue to doing, invoke Claude Code through acpx, persist logs, commit and push changes, create a merge request to master without merging, and update per-issue state on disk. Supports blocked and failed states for retryable scheduling. For this automation, a merge request being created successfully is the terminal completion condition, so the issue must be labeled `done` immediately after MR creation succeeds."
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Single-Issue Executor Skill

**SKILL_VERSION: 2026-04-24.4**

The executor MUST include `"skill_version": "2026-04-24.4"` in its compact chat summary, and MUST write the same string into `${ISSUE_STATE_FILE}.skill_version`. This lets the operator verify which version of the skill is actually loaded.

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

- Build the prompt at `${LOG_DIR}/prompt.txt` with: target issue body, `hulat_dir` reference, instruction to "work only on this issue, modify content under `${REPO_PATH}`, do not ask the user, summarize briefly when done".
- Run synchronously, one-shot, with `${REPO_PATH}` as the working directory:
  ```bash
  cd "${REPO_PATH}"
  acpx claude exec -f "${LOG_DIR}/prompt.txt" \
    1>"${LOG_DIR}/claude_result.txt" \
    2>"${LOG_DIR}/acpx_raw.log"
  ```
- Forbidden: `-s` (persistent session), `--no-wait`, `acpx claude command`. Wait for the command to complete before continuing.
- Claude must write only inside `${REPO_PATH}`. It MUST NOT write into `${WORK_ROOT}`, `${HULAT_DIR}`, or anywhere else.
- If the command fails:
  - retryable (runtime/library mismatch, transient env, transient credential / connectivity): `status=blocked`, set `block_reason`, exit cleanly
  - non-recoverable or `retry_count > blocked_retry_limit`: `status=failed`

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
  "skill_version": "2026-04-24.4",
  "iid": 14,
  "status": "done",
  "work_branch": "issue/14-auto-fix",
  "commit_sha": "abc1234...",
  "merge_request_url": "http://gitlab.example.com/..."
}
```

```json
{
  "skill_version": "2026-04-24.4",
  "iid": 14,
  "status": "blocked",
  "retry_count": 2,
  "block_reason": "Claude Code runtime requires GLIBC 2.29+"
}
```

Never paste full logs, full diffs, or long issue bodies into chat. Detailed evidence stays under `${LOG_DIR}`.
