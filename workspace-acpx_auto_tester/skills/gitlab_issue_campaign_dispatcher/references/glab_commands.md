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

Every flag used in G1–G13 (plus G1b) has been verified to exist on the runner's installed `glab`. Before adding a new flag — here, in `scripts/*.sh`, or in `references/executor_prompt.md` — run `glab <subcommand> --help` on the runner and confirm the flag is listed. The runner may lag mainstream releases: e.g. `--description-file` on `glab mr create` is documented upstream but missing on some runner installs, so G7 uses `--description "$(cat <file>)"` instead. Workspace-wide policy lives in [`SOUL.md`](../../../SOUL.md) §GitLab Access.

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

Wrapped by `scripts/set_issue_label.sh add <label>`. The dispatcher uses this to transition entry labels to `doing`, to stamp the persistent `model:{tier}` label, and to re-apply final callback labels (`blocked-cc` / `blocked-dispatcher`, or `failed-cc` / `failed-dispatcher`). The subagent also uses it for immediate `done` / `blocked-cc` updates during the post-acpx flow.

For workflow labels, the wrapper also passes `remove_labels=<conflicting workflow labels>` in the same issue update, preserving unrelated non-workflow labels (incl. the orthogonal `model:{tier}` dimension) while enforcing the allowed workflow states (`done` terminal success, the transient `done` + `blocked-cc` / `done` + `blocked-dispatcher` pair, or one workflow label). Adding a `model:{tier}` label removes the other model tiers in the same update but touches no workflow label.

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

**RETIRED on benchmark-test** — this command existed only for the deleted `scripts/create_mr.sh`. There is no MR creation on this branch; the section is retained for reference only.

Used by `scripts/create_mr.sh` to list any open MRs pointing at the work branch before rotation. **Both** `fresh` and `continue` modes close every prior open MR and then create a fresh one each attempt (Strategy A — one open MR per issue at any moment, rotated per attempt). The returned JSON drives both the close loop (G10) and the final MR-URL extraction (`.[0].web_url`).

```bash
glab mr list \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --output json
```

Returns a JSON array. Do not add `--state opened`: runner-installed `glab 1.93.0` does not recognize that flag, and `glab mr list` already defaults to open MRs. `scripts/create_mr.sh` also filters the JSON with `jq '[.[] | select((.state // "opened") == "opened")]'` as a guard. Use `jq -r 'if length > 0 then .[0].web_url else "" end'` to extract the URL.

### G7 — Create a merge request (subagent)

**RETIRED on benchmark-test** — this command existed only for the deleted `scripts/create_mr.sh`. There is no MR creation on this branch; the section is retained for reference only.

Wrapped by `scripts/create_mr.sh`. Called once per attempt in **both** modes, after G10 has closed every prior open MR (if any). There is no fresh-mode reuse path — every attempt produces a new MR object.

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

### G8 — Look up the MR URL after creation (subagent, reserved)

**RETIRED on benchmark-test** — this command existed only for the deleted `scripts/create_mr.sh`. There is no MR creation on this branch; the section is retained for reference only.

Permitted command, but `scripts/create_mr.sh` does **not** currently call it: after creating the MR it re-runs the G6 list and extracts `.[0].web_url` from the guaranteed single open MR. G8 is retained as an allowed fallback for looking up a single MR by branch.

```bash
glab mr view "${WORK_BRANCH}" --repo "${PROJECT_FULL}" --output json | jq -r '.web_url'
```

### G9 — Post a note (comment) on the issue (subagent)

Used by `scripts/summarize_attempt.sh` to post successful `done` attempt summaries back to the issue so the next continue-mode run can read them. Failure summaries are written locally only when `SUMMARY_POST_TO_ISSUE=false`. Also used by `scripts/upload_attempt_artifacts.sh` to link Wiki evidence before `done` labeling and MR creation.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}"
```

The `-F body=@<file>` form uploads the file contents as the form field, which avoids quoting issues for large multiline summaries.

### G10 — Close (without merging) an existing MR (subagent)

**RETIRED on benchmark-test** — this command existed only for the deleted `scripts/create_mr.sh`. There is no MR creation on this branch; the section is retained for reference only.

Used by `scripts/create_mr.sh` in **both** modes to close every prior open MR for the work branch before creating a fresh one. Closing is NOT merging — the integration branch is unaffected; the closed MR remains in GitLab as historical record.

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
- `issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}/report.html` when a `report.html` exists under `${OUTPUT_DIR}`

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
  - dispatcher prep failure → mark IID `blocked-dispatcher` with `block_reason="dispatcher needs unsupported glab op: <description>"` and continue with other batch members.
  - subagent failure → mark issue `blocked-cc` with `block_reason="subagent needs unsupported glab op: <description>"` and stop.
