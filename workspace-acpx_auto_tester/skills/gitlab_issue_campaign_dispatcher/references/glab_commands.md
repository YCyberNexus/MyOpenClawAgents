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

Every flag used in G1–G13 has been verified to exist on the runner's installed `glab`. Before adding a new flag — here, in `scripts/*.sh`, or in `references/executor_prompt.md` — run `glab <subcommand> --help` on the runner and confirm the flag is listed. The runner may lag mainstream releases: e.g. `--description-file` on `glab mr create` is documented upstream but missing on some runner installs, so G7 uses `--description "$(cat <file>)"` instead. Workspace-wide policy lives in [`SOUL.md`](../../../SOUL.md) §GitLab Access.

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

### G4 — Add a single label (dispatcher prep + subagent)

Wrapped by `scripts/set_issue_label.sh add <label>`. The dispatcher uses this to transition to `doing` (and `add` is also used by the subagent for `done`/`pr`/`blocked`/`failed`).

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

### G6 — Look up an existing open MR for the work branch (subagent)

Used by `scripts/create_mr.sh` to detect "MR already exists for this branch" before creating a new one (Strategy A — single MR per issue, fresh mode).

```bash
glab mr list \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --state opened \
  --output json
```

Returns a JSON array. Use `jq -r 'if length > 0 then .[0].web_url else "" end'` to extract the URL.

### G7 — Create a merge request (subagent)

Wrapped by `scripts/create_mr.sh`. Only call this when G6 returned empty (fresh mode) or after G10 closed prior MRs (continue mode).

```bash
glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${BRANCH}" \
  --title "Issue #${ISSUE_IID}: ${ISSUE_TITLE}" \
  --description "$(cat "${LOG_DIR}/mr_description.md")" \
  --yes
```

The inline `--description "$(cat ...)"` form is intentional. Some runner-installed `glab` versions don't recognize `--description-file`; the inline `--description` flag has been in glab since the beginning. See the "Flag compatibility" rule below.

### G8 — Look up the MR URL after creation (subagent)

```bash
glab mr view "${WORK_BRANCH}" --repo "${PROJECT_FULL}" --output json | jq -r '.web_url'
```

### G9 — Post a note (comment) on the issue (subagent)

Used by `scripts/summarize_attempt.sh` to post the per-attempt summary back to the issue so the next continue-mode run can read it. Also used by `scripts/upload_attempt_artifacts.sh` to link Wiki evidence before `done` labeling and MR creation.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}"
```

The `-F body=@<file>` form uploads the file contents as the form field, which avoids quoting issues for large multiline summaries.

### G10 — Close (without merging) an existing MR (subagent, continue mode only)

Used by `scripts/create_mr.sh` in continue mode to close the previous attempt's MR before creating a fresh one. Closing is NOT merging — the integration branch is unaffected; the closed MR remains in GitLab as historical record.

```bash
glab mr close <mr_iid> --repo "${PROJECT_FULL}"
```

`<mr_iid>` is the per-project MR IID (the integer in `merge_requests/<N>`). Get it via G6 (`.[0].iid`).

### G11 — Read a Wiki page (subagent)

Used by `scripts/upload_attempt_artifacts.sh` to decide whether to create or update an attempt-scoped Wiki page.

```bash
glab api "projects/${PROJECT_URI}/wikis/${WIKI_SLUG_URI}"
```

`WIKI_SLUG_URI` is the URI-encoded Wiki title, for example `issue33%2Fattempt-001%2Fprompt.txt`.

### G12 — Create a Wiki page (subagent)

Used by `scripts/upload_attempt_artifacts.sh` when G11 reports the page is absent. The script creates attempt-scoped Wiki pages:

- `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/prompt.txt`
- `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/claude_result.txt`
- `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/report.html` when a `report.html` exists under `${WORKTREE_DIR}`

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/wikis" \
  -f "title=${WIKI_TITLE}" \
  -F "content=@${SOURCE_PATH}" \
  -f "format=markdown"
```

### G13 — Update a Wiki page (subagent)

Used by `scripts/upload_attempt_artifacts.sh` when rerunning the same allocated attempt or resuming after a partial post.

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/wikis/${WIKI_SLUG_URI}" \
  -f "title=${WIKI_TITLE}" \
  -F "content=@${SOURCE_PATH}" \
  -f "format=markdown"
```

The subagent constructs browser URLs as `${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${PROJECT_FULL}/-/wikis/${WIKI_TITLE}` and posts those links back to the issue with G9.

## What is FORBIDDEN

- `glab mr merge` — under any circumstances. The MR stays open until a human merges.
- `glab issue close`, `glab api ... -f state_event=close` — the agent never closes the issue; GitLab auto-closes via the MR's `Closes #<iid>`.
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use G4/G5 instead.
- `curl`, `wget`, `httpie`, any HTTP library, any non-glab GitLab SDK.
- `glab issue list` / `glab issue view` for dispatcher-side reconciliation — use the raw `glab api` form (G1) so the output is stable JSON.
- Inventing flags or alternative subcommands. If the operation isn't in this list:
  - dispatcher prep failure → mark IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and continue with other batch members.
  - subagent failure → mark issue `blocked` with `block_reason="subagent needs unsupported glab op: <description>"` and stop.
