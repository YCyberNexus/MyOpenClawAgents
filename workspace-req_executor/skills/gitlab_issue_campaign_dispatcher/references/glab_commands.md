# glab Commands (Workspace-Wide)

The agent is allowed only the commands listed here. Any other approach to talking to GitLab — `curl`, `wget`, Python HTTP libraries, alternate `glab` subcommands not in this table, modifying `.gitlab-ci.yml` to bypass `glab` — is forbidden by the GitLab Access Policy in `SKILL.md`.

This list applies to BOTH the dispatcher's prep scripts and the subagent's post-acpx scripts. Both halves run from the same `scripts/` directory and share the same set of allowed glab calls. The "performer" column tells you who calls each command.

## Authentication and host

The host is pinned in `<workspace>/config/gitlab.env`; `scripts/env_paths.sh` invokes `scripts/glab_auth.sh` to authenticate and exports `${GITLAB_HOST}`, `${PROJECT_FULL}`, `${PROJECT_URI}`. Policy (verification, token rotation, abort-on-mismatch, never re-derive host) lives in [`SOUL.md`](../../../SOUL.md) §GitLab Host Pinning.

These auth commands are used only inside `scripts/glab_auth.sh`:

```bash
glab auth login \
  --hostname "${GITLAB_HOST}" \
  --token "${GITLAB_TOKEN}" \
  --api-protocol "${GITLAB_API_PROTOCOL}"

glab auth status --hostname "${GITLAB_HOST}"
```

## Flag compatibility

Every CLI flag used below has been verified against the deployment contract. Before adding a new flag — here, in `scripts/*.sh`, or in `references/executor_prompt.md` — verify it on the runner. The runner may lag mainstream releases: e.g. `--description-file` on `glab mr create` is missing on some installs, so G7 uses `--description "$(cat <file>)"`. G15/G16 use the stable `glab api` surface rather than version-sensitive `glab mr merge` flags. Workspace-wide policy lives in [`SOUL.md`](../../../SOUL.md) §GitLab Access.

## Commands

### G1 — Read one issue (dispatcher prep + reconcile)

Used by `scripts/reconcile.sh` (across the IID range) and ad-hoc by the dispatcher's prep step that reads `ISSUE_TITLE`. Also used inside `scripts/build_prompt.sh` to fetch the issue body for the Claude Code prompt.

```bash
glab api "projects/${PROJECT_URI}/issues/${ISSUE_IID}"
```

Response is the raw issue JSON. Parse with `jq` to read `.state`, `.labels`, `.title`, `.description`.

### G1b — Read the target issue's notes (dispatcher prep, continue mode)

Used in continue mode by `scripts/build_prompt.sh` to partition notes into past attempt summaries and reviewer comments.

```bash
glab api --paginate \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at"
```

The response is a JSON array of note objects. Non-system notes (`.system == false`) carry `body`, `author.username`, `created_at`. The dispatcher's prep concatenates these into the Claude Code prompt verbatim, in chronological order, separated by buckets per the marker comments.

In fresh mode, fetching notes is unnecessary. In continue mode, fetching notes is **mandatory**.

### G2 — List project labels (dispatcher prep)

Used by `scripts/ensure_labels.sh` to detect missing workflow labels.

```bash
glab api --paginate \
  "projects/${PROJECT_URI}/labels?per_page=100"
```

### G3 — Create a missing label (dispatcher prep)

Used by `scripts/ensure_labels.sh`. Run once per missing name.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/labels" \
  -f "name=${LABEL_NAME}" -f "color=#808080"
```

### G4 — Add a target label (dispatcher prep + subagent)

Wrapped by `scripts/set_issue_label.sh add <label>`. The dispatcher uses this to transition entry labels to `doing` and to re-apply final callback labels (`pr`, server-verified `finish`, blocked, failed, or timeout). The subagent also uses it for immediate `done` / `pr` / `finish` / failure updates during the post-acpx flow.

For workflow labels, the wrapper also passes `remove_labels=<conflicting workflow labels>` in the same issue update, preserving unrelated non-workflow labels while enforcing the allowed workflow states (`done` + `pr`, `done` + `blocked`, or one workflow label).

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "add_labels=${LABEL}"
```

### G5 — Remove a single label (dispatcher prep + subagent)

Wrapped by `scripts/set_issue_label.sh remove <label>`.

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "remove_labels=${LABEL}"
```

### G6 — Look up open MRs for the work branch (subagent)

Used by `scripts/create_mr.sh` to list open MRs for the work branch. Ordinary
branches use the result for rotation. During late binding,
`migrate_shared_dependency_head.sh` requires exactly one open ordinary
`issue/A` MR, then requires empty all-state `issue/A+C` history before creating
the replacement. Recovery may reuse only the one intent-owned exact open
replacement and never replaces closed or moved shared history. C requires
exactly one entry whose URL/IID matches A's migrated durable state, then reuses
it without mutation. The final exact MR
verification still reads source, target, and SHA through G14.

```bash
glab mr list \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --output json
```

Returns a JSON array. Do not add `--state opened`: runner-installed `glab 1.93.0` does not recognize that flag, and `glab mr list` already defaults to open MRs. `scripts/create_mr.sh` also filters the JSON with `jq '[.[] | select((.state // "opened") == "opened")]'` as a guard. Use `jq -r 'if length > 0 then .[0].web_url else "" end'` to extract the URL.

### G7 — Create a merge request (subagent)

Wrapped by `scripts/create_mr.sh`. Ordinary branches call it once per attempt
after G10 closes prior open MRs. A initially uses this ordinary path on
`issue/A` with only `Closes #A`. When C is later discovered,
`migrate_shared_dependency_head.sh` calls the same fixed `glab mr create`
surface to create the `issue/A+C` replacement containing `Closes #A`,
`Closes #C`, the migration intent marker, and the superseded old MR IID. C
must reuse that replacement and must not call G7.

```bash
glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${MERGE_TARGET_BRANCH}" \
  --title "Issue #${ISSUE_IID}: ${ISSUE_TITLE}" \
  --description "$(cat "${LOG_DIR}/mr_description.md")" \
  --yes
```

The inline `--description "$(cat ...)"` form is intentional. Some runner-installed `glab` versions don't recognize `--description-file`; the inline `--description` flag has been in glab since the beginning. See the "Flag compatibility" rule below.

### G8 — Look up the MR URL after creation (subagent, reserved)

Permitted command, but `scripts/create_mr.sh` does **not** currently call it: after creating the MR it re-runs the G6 list and extracts `.[0].web_url` from the guaranteed single open MR. G8 is retained as an allowed fallback for looking up a single MR by branch.

```bash
glab mr view "${WORK_BRANCH}" --repo "${PROJECT_FULL}" --output json | jq -r '.web_url'
```

### G9 — Post a note (comment) on the issue (subagent)

Used by `scripts/summarize_attempt.sh` to post successful `done` attempt summaries back to the issue so the next continue-mode run can read them. Failure summaries are written locally only when `SUMMARY_POST_TO_ISSUE=false`.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}"
```

The `-F body=@<file>` form uploads the file contents as the form field, which avoids quoting issues for large multiline summaries.

### G10 — Close (without merging) an existing MR (subagent)

Used by `scripts/create_mr.sh` for ordinary branch rotation. It is also used
once by `migrate_shared_dependency_head.sh` to close A's exact verified
ordinary MR before creating the shared replacement. The migration checkpoint
makes that close replay-safe; it never closes the replacement. C reuses the
exact replacement identity persisted by A. Closing is not merging; the target
branch remains unaffected.

```bash
glab mr close <mr_iid> --repo "${PROJECT_FULL}"
```

`<mr_iid>` is the per-project MR IID (the integer in `merge_requests/<N>`). Get it via G6 (`.[0].iid`).

### G11-G13 — Legacy Wiki page APIs (not used)

Current req_executor runs must not publish `prompt.txt`, `claude_result.txt`, or
`report.html` to project Wiki pages. `scripts/upload_attempt_artifacts.sh` is a
no-op compatibility shim for already-rendered legacy prompts and must not call
the Wiki read/create/update APIs.

### G14 — 结果回报: read `req_origin` + post `req_result` (dispatcher, Phase 6)

Used by `scripts/post_result_note.sh` when `result_note_enabled` is on, after a terminal `done` / `failed` / `timeout` drains. It reuses the existing note primitives — no new API surface:

- **Read** the issue's notes with **G1b** (`GET .../issues/${IID}/notes`), then extract the last `<!-- req_origin v1 {…} -->` marker's JSON payload (written upstream by `git_issuer`). If no such marker exists, the script is a no-op (the issue did not originate from the req_dispatcher → git_issuer pipeline).
- **Post** a `req_result` note with **G9** (`POST .../issues/${IID}/notes -F body=@<file>`), body's first line `<!-- req_result v1 {iid,status,attempt,mr_url,reason,ts,origin} -->` plus a human-readable summary line. An external relay (the 114 side) polls/webhooks these markers and delivers the result to the original requester.

This is best-effort and dispatcher-side: failure is logged to `wrapper.log` and never aborts Phase 6. It touches only issue **notes** — never labels, MR, or state files. Full cross-region contract: the req_dispatcher workspace's `docs/integration/result_notify_loop.md`.

### G15 — Read one exact MR (executor + Phase 6)

Used by `scripts/merge_mr.sh` before and after any requested merge, and again by
Phase 6 in read-only `verify` mode:

```bash
glab api "projects/${PROJECT_URI}/merge_requests/${MR_IID}"
```

The response must match the expected project-local IID, web URL, source branch,
target branch, and commit SHA. In attempt mode, only the exact post-PUT
`state=merged` response authorizes the fixed outer wrapper's first atomic
`finish` write. Phase 6 later repeats the bounded read-only check before durable
terminal persistence and callback emission. A marker or callback alone never
authorizes either decision; `opened` remains `pr`, and an unknown/mismatched
response must never authorize completion.

### G16 — Merge one exact MR with a SHA fence (executor only)

Allowed only inside `scripts/merge_mr.sh`, only when the durable request has
`auto_merge=true`, and only after G15 verified the exact MR identity:

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/merge_requests/${MR_IID}/merge" \
  -f "sha=${COMMIT_SHA}" \
  -f "should_remove_source_branch=false"
```

The command's exit code is not merge evidence. The helper must always perform a
second G15 read; only the exact server-side merged state is success. Approval,
CI, conflict, SHA mismatch, or network uncertainty leaves the outer executor's
first `finish` write unset. Phase 6 still performs its independent G15 read
before terminal persistence and callback emission.

## What is FORBIDDEN

- Direct `glab mr merge`, merge-by-URL, merge without the exact SHA fence, or any merge outside G16. Ordinary requests keep the MR open for human review.
- `glab issue close`, `glab api ... -f state_event=close` — the agent never closes the issue; GitLab auto-closes via the MR's `Closes #<iid>`.
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use G4/G5 instead.
- `curl`, `wget`, `httpie`, any HTTP library, any non-glab GitLab SDK.
- `glab issue list` / `glab issue view` for dispatcher-side reconciliation — use the raw `glab api` form (G1) so the output is stable JSON.
- Inventing flags or alternative subcommands. If the operation isn't in this list:
  - dispatcher prep failure → mark IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and continue with other batch members.
  - subagent failure → mark issue `blocked` with `block_reason="subagent needs unsupported glab op: <description>"` and stop.
