---
name: gitlab_single_issue_executor
description: "[SKILL_VERSION=2026-04-28.2] Execute one GitLab issue in one dedicated session. Clone or pull the repository, ensure labels exist, set the issue to doing, invoke Claude Code through acpx, persist logs, commit and push changes, create a merge request to master without merging, and update per-issue state on disk. Supports blocked and failed states for retryable scheduling. For this automation, a merge request being created successfully is the terminal completion condition, so the issue must be labeled `done` immediately after MR creation succeeds."
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Single-Issue Executor Skill

**SKILL_VERSION: 2026-04-28.2**

The executor MUST include `"skill_version": "2026-04-28.2"` in its compact chat summary, and MUST write the same string into `${ISSUE_STATE_FILE}.skill_version`. This lets the operator verify which version of the skill is actually loaded.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — populates issue-level AND attempt-level path variables (SOURCE it; auto-resolves the next attempt number).
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`.
- `scripts/clone_or_pull.sh` — keep the main repo's refs current (no working-tree edits; worktrees do that).
- `scripts/prepare_attempt.sh` — create the per-attempt git worktree, set up the `_hulat` symlink, write `.git/info/exclude`. Replaces the old `prepare_branch.sh`.
- `scripts/build_prompt.sh` — build `${LOG_DIR}/prompt.txt` from the live issue + (continue mode) past-attempt summaries + reviewer comments. See `references/continue_mode.md` for the template.
- `scripts/ensure_labels.sh` — make sure the seven workflow labels exist.
- `scripts/set_issue_label.sh` — add or remove a single label (used for every transition).
- `scripts/stage_and_guard.sh` — `git add -A` inside the worktree + leak guard (rejects `openclaw_log/`, `openclaw_state/`, `_hulat`).
- `scripts/commit_and_push.sh` — commit and FORCE-push the per-attempt local branch to the SINGLE remote `${WORK_BRANCH}` (Strategy A).
- `scripts/post_push_verify.sh` — confirm the remote branch contains no agent artifacts and no `_hulat`.
- `scripts/create_mr.sh` — fresh mode: reuse the existing open MR for `${WORK_BRANCH}` if any, else create one (Strategy A). Continue mode: close the existing open MR (without merging) and create a fresh one that references the closed predecessor — each continue cycle leaves a visible MR trail in GitLab.
- `scripts/summarize_attempt.sh` — write `${SUMMARY_FILE}` and post it as a GitLab issue note so future continue-mode runs can read what past attempts did.
- `references/paths.md` — full path layout and required artifacts.
- `references/state_schema.md` — `issue-<iid>.json` schema and update cadence.
- `references/glab_commands.md` — exhaustive list of allowed `glab` invocations.
- `references/label_lifecycle.md` — label transitions and how to perform them.
- `references/continue_mode.md` — reviewer contract for the `continue` label and the prompt template the executor builds in continue mode.

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
- `glab mr merge` (under any circumstances — MRs stay open until a human merges them)
- Closing the issue itself (`-f state_event=close`, `glab issue close`, etc.). Issue closure is GitLab's job via the `Closes #<iid>` keyword that `scripts/create_mr.sh` puts in the MR description. The executor only labels `done`.

The executor MAY close MRs (`glab mr close`) — but only as part of the continue-mode MR rotation in `scripts/create_mr.sh`. Closing is not merging, and it does not change the integration branch. Closed MRs remain in GitLab as historical record.
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use `set_issue_label.sh` instead.
- Any `glab` subcommand or flag not listed in `references/glab_commands.md`.

If a required operation is not in the allowed list, mark the issue `blocked` with `block_reason="executor needs unsupported glab op: <description>"` and stop. Do NOT fall back to curl.

If `glab auth status` fails after `scripts/glab_auth.sh`, mark the issue `blocked` with `block_reason="glab auth failed"` and stop.

**Do NOT pass `--hostname` to `glab api` calls.** `scripts/glab_auth.sh` exports `GITLAB_HOST` as an env var; glab natively reads that env var and routes API calls correctly. Passing `--hostname` with a `host:port` value confuses glab's URL resolution for some subcommands and historically caused the executor to spin trying alternative invocations (env var, `-R` flag, different config keys, etc.). The single allowed convention is: rely on the exported `GITLAB_HOST` env var, drop the `--hostname` flag everywhere.

### GitLab host is pinned at deployment time

The GitLab host (and protocol) the executor talks to is **pinned in `<workspace>/config/gitlab.env`**, NOT derived from the trigger's `gitlab_address` on every run. See `<workspace>/config/README.md` for the rationale.

Implications:

- The executor MUST read the host from `scripts/glab_auth.sh`, never re-derive it inline from `${GITLAB_ADDRESS}`. Calling `sed` on `${GITLAB_ADDRESS}` outside that script is forbidden.
- The trigger's `gitlab_address` is a **verification value**. `scripts/glab_auth.sh` will refuse to run if the trigger's host does not match `config/gitlab.env`, and exits non-zero. Map the exit codes to per-issue state as follows:
  - exit 10 (pin file missing) → `status=blocked`, `block_reason="deployment incomplete: config/gitlab.env missing"`
  - exit 11 (pin file fields missing) → `status=blocked`, `block_reason="deployment incomplete: config/gitlab.env malformed"`
  - exit 12 (bad protocol value) → `status=blocked`, `block_reason="deployment incomplete: GITLAB_API_PROTOCOL invalid"`
  - exit 13 (trigger does not match pin) → `status=blocked`, `block_reason="trigger gitlab_address does not match deployed config/gitlab.env"`
- `gitlab_token` from the trigger is used to refresh `glab auth login` against the pinned host every run; token rotation works, but the host itself never changes from a trigger input.

The `AUTHED_REMOTE_URL` used by `clone_or_pull.sh` is also constructed from the trigger's `GITLAB_ADDRESS`. That is acceptable because `clone_or_pull.sh` is a single, well-tested code path that does not parse host/protocol — it just passes the original URL straight to `git clone` / `git remote set-url`. Do NOT add separate host parsing in any other script.

---

## Repo Cleanliness Policy (READ FIRST — HARD RULE)

The pushed work branch MUST contain ONLY this issue's code changes. No agent logs, no agent state, no artifacts from other issues, no `_hulat` symlink.

- All agent-owned files live under `${ATTEMPT_DIR}` (= `${ISSUE_ROOT}/attempts/attempt-NNN/`), OUTSIDE the worktree. See `references/paths.md`.
- `${WORKTREE_DIR}` is the only directory the executor allows Claude Code to modify. It is a real `git worktree` of `${REPO_PATH}` — `git add -A` here only sees repo-tracked content.
- `_hulat` is a symlink inside `${WORKTREE_DIR}` pointing at `${HULAT_DIR}` for read-only config access. `scripts/prepare_attempt.sh` adds `/_hulat` to `.git/info/exclude` for the worktree.
- `scripts/stage_and_guard.sh` aborts with exit 3 if any `openclaw_log/`, `openclaw_state/`, or `_hulat` path appears in the staged tree.
- `scripts/post_push_verify.sh` aborts with exit 4 if the remote branch contains any such path.

If either guard trips, mark the issue `blocked`. Do NOT attempt to push or open an MR.

---

## Inputs

Required from the trigger command (`RUN_SINGLE_ISSUE_SESSION`):

- `group`, `project`, `branch`, `dev_branch`, `hulat_dir`, `gitlab_token`, `issue_iid`, `attempt_number`, `non_interactive=true`

`attempt_number` is the integer attempt number allocated by the dispatcher via `dispatcher/scripts/allocate_attempt.sh`. The executor MUST NOT compute its own attempt number — `env_paths.sh` will refuse to load if `ATTEMPT_NUMBER` is missing from the environment. This rule prevents the "empty attempt-NNN/ directories on session restart" bug from older versions.

`branch` is the integration / target branch (where the MR is opened). `dev_branch` is the clean baseline branch the fresh-mode worktree is checked out from, so Claude Code starts from a tree that does not contain past issues' spec accumulation. If the project does not maintain a separate clean baseline, the operator may set `dev_branch=<same-as-branch>` to fall back to single-branch behavior.

Optional:

- `blocked_retry_limit`
- `gitlab_address` — pure verification value. The host is pinned in `<workspace>/config/gitlab.env`; the executor never derives it from this field. If supplied, `scripts/glab_auth.sh` checks that it resolves to the same `host:port` and protocol as the pin and aborts on mismatch (exit 13). If omitted, the pin is used unconditionally. The remote URL passed to `git clone` is also built from the pin, not from this field.
- `issue_mode` — `fresh` (default) or `continue`. Set by the dispatcher based on reconciliation. If `continue`, the executor reuses the existing `issue/<iid>-auto-fix` remote branch (or falls back to fresh if no remote branch exists) and starts the resolution flow from there. See `## Continue Mode` below.

`hulat_dir` is a string passed through to the Claude Code prompt. The executor itself never `cd`s into it or writes there. See `references/paths.md`.

---

## Continue Mode

The `continue` label is human-applied by reviewers. They set it on an issue whose MR was created and labeled `done` by the agent, but where the actual Claude Code run did not finish or was incorrect. When the dispatcher's reconciliation sees `continue` on an issue, it re-enqueues the IID and spawns the executor with `issue_mode=continue`.

In continue mode the executor:

- Detects the mode from the trigger field `issue_mode=continue`. As a backstop, it re-derives the mode at Step 3 of the algorithm from live labels: if labels include `continue`, treat as continue mode regardless of the trigger field.
- Transitions the issue label from `continue` to `doing` (instead of `todo` to `doing`). See `references/label_lifecycle.md`.
- Allocates a NEW attempt directory `attempt-NNN` (numbers are monotonically increasing — past attempts are preserved on disk). Calls `scripts/prepare_attempt.sh` with `ISSUE_MODE=continue`. The script bases the new worktree on `origin/${WORK_BRANCH}` (the existing work-in-progress branch from the prior attempt). If `${WORK_BRANCH}` does not exist on the remote, the script downgrades to fresh mode and records `mode_downgraded_from="continue"`.
- Builds the Claude Code prompt with the live issue body + ALL past `uiautotester:attempt-summary` notes + ALL non-summary reviewer comments. See `references/continue_mode.md`.
- After the attempt finishes, `scripts/summarize_attempt.sh` posts a new summary comment to the issue so future continue-mode runs can see what this attempt did.
- **MR rotation.** Unlike fresh mode (which reuses the single MR for `${WORK_BRANCH}`), continue mode closes the previous open MR (without merging — the integration branch is untouched) and creates a fresh MR pointing at the same source branch. The new MR's description includes `Supersedes !<old_mr_iid>` for traceability. Each continue cycle therefore produces a distinct MR object in GitLab so reviewers can see the resolution history.
- All other later steps (stage + guard, commit, force-push, post-push verify, label transitions) are identical to fresh mode.

The executor MUST NOT delete the remote work branch in continue mode, and MUST NOT delete past attempt directories on disk. Cleanliness guards (`stage_and_guard.sh`, `post_push_verify.sh`) still apply.

If continue-mode prep fails for any reason other than "remote branch does not exist" (corrupt fetch, conflicting worktree, etc.), follow the No-Fallback Policy: mark `status=blocked` with an accurate `block_reason`, do NOT silently fall back to fresh mode. The remote-branch-missing downgrade is the only documented exception.

---

## Claude Code Execution Contract

This is the ONLY way the executor is allowed to invoke Claude Code. It is governed by the No-Fallback Policy above — when this contract fails, the executor stops; it does NOT switch invocation modes or LLMs.

- Build the prompt at `${LOG_DIR}/prompt.txt` by running `scripts/build_prompt.sh`. The script generates the canonical layout (issue title + description + working env + rules) for both modes, and additionally appends past-attempt summaries + reviewer comments in continue mode. Do NOT hand-write `prompt.txt` — that risks omitting comments and past summaries and silently losing context. See `references/continue_mode.md` for the exact template.
- Run synchronously, one-shot, with `${WORKTREE_DIR}` as the working directory (NOT `${REPO_PATH}` — Claude must operate inside the per-attempt worktree, not the main repo):
  ```bash
  cd "${WORKTREE_DIR}"
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
- Claude must write only inside `${WORKTREE_DIR}`. It MUST NOT write into `${REPO_PATH}` (the main repo's working tree), `${WORK_ROOT}`, `${HULAT_DIR}`, or anywhere else. Reading from `${WORKTREE_DIR}/_hulat` (the symlink) is fine; writing through that symlink is forbidden.

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

## Per-Exec Env Contract (READ BEFORE Step 1 — HARD RULE)

OpenClaw runs each `Bash` tool call in a **fresh shell**. Exports made in one exec do NOT survive to the next. As of SKILL_VERSION 2026-04-28.2, every `scripts/*.sh` file in this skill self-bootstraps by sourcing `env_paths.sh` at its top — but that script needs the minimum trigger inputs to be in env at every call.

**Every Bash exec MUST start with these 5 env vars exported:**

```
PROJECT          # project slug
ISSUE_IID        # integer issue IID
ATTEMPT_NUMBER   # integer attempt number (allocated by dispatcher)
GROUP            # GitLab group slug
GITLAB_TOKEN     # GitLab access token
```

Some scripts also need `BRANCH`, `DEV_BRANCH`, `HULAT_DIR`, `ISSUE_MODE`, `ISSUE_TITLE` — these are listed at the top of each script. Pass whatever the script needs.

Recommended pattern for every exec:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat ISSUE_IID=33 ATTEMPT_NUMBER=1 GROUP=claw_gitlab \
GITLAB_TOKEN=<token> BRANCH=master DEV_BRANCH=dev HULAT_DIR=/data/openclaw/bu_data/px_hulat \
ISSUE_MODE=fresh ISSUE_TITLE="..." \
bash scripts/<script>.sh
```

The script itself sources `env_paths.sh`, which derives all paths, runs `glab_auth.sh` to set `GITLAB_HOST`, computes `PROJECT_FULL` / `PROJECT_URI`, and proceeds. The model does NOT need to manage these derived vars across execs.

---

## Working Directory (READ BEFORE Step 1 — HARD RULE)

All `scripts/...` and `references/...` paths in this SKILL are **relative to this skill's own directory** (the directory containing this SKILL.md, e.g. `<workspace>/skills/gitlab_single_issue_executor/`).

Before issuing ANY `bash scripts/...` command, the executor MUST `cd` into the skill directory in the same shell session. Otherwise relative paths like `scripts/env_paths.sh` resolve against whatever cwd OpenClaw started the session in (often the user home, NOT the skill dir), and the first invocation fails with "no such file or directory".

The skill directory's absolute path is known to the agent at load time (the same path SKILL.md was read from). Bootstrap snippet, run ONCE per session before anything else:

```bash
SKILL_DIR="<absolute path of this SKILL.md's parent>"   # e.g. /home/claw/.openclaw/workspace-UiAutoTester/skills/gitlab_single_issue_executor
cd "${SKILL_DIR}"
```

After this, every subsequent `bash scripts/X.sh` and `source scripts/X.sh` invocation resolves correctly. Do NOT attempt to invoke scripts from any other cwd; do NOT prepend `./` or `../`; do NOT try to find scripts via `find` or `ls`. The single allowed convention is: `cd ${SKILL_DIR}` once, then invoke scripts by relative path.

Note: at Step 8 (acpx) the algorithm explicitly switches cwd to `${WORKTREE_DIR}` for the Claude Code invocation. After acpx returns, switch back to `${SKILL_DIR}` (or use absolute paths to scripts) so the remaining `bash scripts/...` commands continue to work. The path-conscious order is documented in each step below.

---

## Executor Algorithm

Run once per session for `${ISSUE_IID}`. Every run produces a brand-new attempt directory.

When a step below says `bash scripts/X.sh`, that is shorthand for the script action. In an actual OpenClaw Bash tool call, prefix the command with the minimum env vars from the Per-Exec Env Contract plus any script-specific vars in the same exec. Never rely on exports from a previous Bash tool call.

1. **Bootstrap.**
   - `cd ${SKILL_DIR}` — see "Working Directory" above; mandatory before any relative `scripts/...` invocation.
   - Verify the trigger supplied `attempt_number=<N>`. If missing, mark the issue `blocked` with `block_reason="trigger missing attempt_number"` and stop. (The dispatcher must call `allocate_attempt.sh` before every spawn — see dispatcher SKILL.)
   - If doing an explicit bootstrap check in the current shell, use the full minimum env contract:
     `PROJECT=<project> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N> GROUP=<group> GITLAB_TOKEN=<token> source scripts/env_paths.sh`
     This resolves both issue-level and attempt-level paths, authenticates glab, computes `PROJECT_FULL` / `PROJECT_URI`, and creates the `attempt-${N}/` skeleton.
   - Do NOT call `scripts/glab_auth.sh` separately after `env_paths.sh`, and do NOT manually export `PROJECT_FULL` or `PROJECT_URI`. Every later `bash scripts/...` command is a fresh shell and must receive the minimum env vars from the Per-Exec Env Contract; the target script will source `env_paths.sh` itself.
2. **Sync the main repo.** `bash scripts/clone_or_pull.sh`. This only fetches refs and prunes stale worktrees; it does NOT switch branches in the main repo.
3. **Read the target issue + resolve mode.** Use command E1 from `references/glab_commands.md`. Capture title, description, current labels. `ISSUE_TITLE` is the short form for commit / MR title. Resolve `ISSUE_MODE`:
   - if the trigger field `issue_mode=continue` was supplied, OR live labels include `continue` → `ISSUE_MODE=continue`
   - else → `ISSUE_MODE=fresh`
   Export `ISSUE_MODE`.
4. **Ensure labels exist.** `bash scripts/ensure_labels.sh`. (Includes `continue`.)
5. **Transition entry label → `doing`.** Use `scripts/set_issue_label.sh`:
   - `ISSUE_MODE=fresh`: `remove todo`, then `add doing`
   - `ISSUE_MODE=continue`: `remove continue`, then `add doing`
   Remove is idempotent.
6. **Initialize per-attempt state and refresh per-issue state.** Per `references/state_schema.md`:
   - `${ATTEMPT_STATE_FILE}` (new) — write `iid`, `attempt_number`, `attempt_started_at`, `mode_requested=${ISSUE_MODE}`, `skill_version`. Other fields filled in as the algorithm progresses.
   - `${ISSUE_STATE_FILE}` — write/update `status=in_progress`, `mode="${ISSUE_MODE}"`, `attempts_total=${ATTEMPT_NUMBER}`, `latest_attempt_number=${ATTEMPT_NUMBER}`, `latest_attempt_dir=${ATTEMPT_DIR}`, increment `retry_count` if this is a retry, set `skill_version`, `updated_at`.
7. **Prepare the per-attempt worktree.** `ISSUE_MODE="${ISSUE_MODE}" bash scripts/prepare_attempt.sh`. The script prints two lines: the actual mode (`fresh` or `continue`) and `${LOCAL_ATTEMPT_BRANCH}`. If a downgrade happened (continue requested but no remote branch), set `mode_downgraded_from="continue"` and `mode_actual="fresh"` in `${ATTEMPT_STATE_FILE}`. Otherwise `mode_actual` matches `mode_requested`. Write `local_branch=${LOCAL_ATTEMPT_BRANCH}` into `${ATTEMPT_STATE_FILE}`.
8. **Build the prompt and run Claude Code.**
   1. `bash scripts/build_prompt.sh` (writes `${LOG_DIR}/prompt.txt`). In continue mode this fetches issue notes (E1b) and partitions them into "past attempt summaries" + "reviewer comments".
   2. Capture stderr — record `no_reviewer_comments` and `prior_attempt_count` into `${ATTEMPT_STATE_FILE}`.
   3. Run acpx per the Claude Code Execution Contract, with `${WORKTREE_DIR}` as cwd, then return to `${SKILL_DIR}` so subsequent relative `scripts/...` invocations still work:
      ```bash
      cd "${WORKTREE_DIR}"
      acpx claude exec -f "${LOG_DIR}/prompt.txt" \
        1>"${LOG_DIR}/claude_result.txt" \
        2>"${LOG_DIR}/acpx_raw.log"
      cd "${SKILL_DIR}"
      ```
      On failure follow the retryable / non-recoverable rules. The executor MUST NOT extract specific commands from reviewer comments and run them itself — those are for Claude Code.
9. **Stage + guard.**
   ```bash
   bash scripts/stage_and_guard.sh
   ```
   - Exit 3 → leak. `status=blocked`, `block_reason="agent artifacts leaked into worktree"`, run summarize_attempt then stop.
   - `NO_CHANGES` → `status=no_changes`, run summarize_attempt then stop. No push, no MR.
   - `STAGED_OK` → continue.
10. **Commit + force-push (Strategy A).** `ISSUE_TITLE="..." bash scripts/commit_and_push.sh` (prints commit SHA). Write `commit_sha` into both the per-attempt and per-issue state files.
11. **Post-push verify.** `bash scripts/post_push_verify.sh`. Exit 4 → `status=blocked`, `block_reason="remote branch polluted with agent artifacts"`, summarize then stop.
12. **Ensure MR exists (mode-dependent rotation).** `ISSUE_TITLE="..." bash scripts/create_mr.sh` (prints MR URL). Write `merge_request_url` into both state files.
    - In `ISSUE_MODE=fresh`: reuses the existing open MR for `${WORK_BRANCH}` if any, else creates one (Strategy A — single MR per issue).
    - In `ISSUE_MODE=continue`: closes any existing open MR for `${WORK_BRANCH}` (without merging), then creates a fresh MR. The new MR's description includes `Supersedes !<old_mr_iid>` so reviewers can trace which previous MR this run replaces.
    - The MR description always starts with `Closes #${ISSUE_IID}` so GitLab auto-closes the issue when whichever MR is current is eventually merged.
13. **Transition `doing → pr → done`.** Per `references/label_lifecycle.md`. The executor does NOT close the issue itself.
14. **Summarize the attempt.** `ATTEMPT_STATUS=done COMMIT_SHA=... MERGE_REQUEST_URL=... bash scripts/summarize_attempt.sh`. This writes `${SUMMARY_FILE}` and posts the same content as a GitLab issue note (E9) marked with `<!-- uiautotester:attempt-summary v1 attempt=${ATTEMPT_NUMBER_PADDED} -->`. Set `summary_posted_to_issue=true` in `${ATTEMPT_STATE_FILE}`.
    For non-`done` terminal statuses (`no_changes`, `blocked`, `failed`), Step 14 still runs — pass the appropriate `ATTEMPT_STATUS` and `BLOCK_REASON`. The summary is always posted, even on failure paths, so future continue-mode runs and reviewers can see what happened.
15. **Finalize.** Write the terminal `status` and `updated_at` to BOTH `${ATTEMPT_STATE_FILE}` (with `attempt_finished_at`) and `${ISSUE_STATE_FILE}`. Return the compact chat summary.

---

## Chat Output Policy

Return a single compact JSON summary. Examples:

```json
{
  "skill_version": "2026-04-28.2",
  "iid": 14,
  "status": "done",
  "work_branch": "issue/14-auto-fix",
  "commit_sha": "abc1234...",
  "merge_request_url": "http://gitlab.example.com/..."
}
```

```json
{
  "skill_version": "2026-04-28.2",
  "iid": 14,
  "status": "blocked",
  "retry_count": 2,
  "block_reason": "Claude Code runtime requires GLIBC 2.29+"
}
```

Never paste full logs, full diffs, or long issue bodies into chat. Detailed evidence stays under `${LOG_DIR}`.
