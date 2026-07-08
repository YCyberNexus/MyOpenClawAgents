# glab Commands (Workspace-Wide)

The agent is allowed only the commands listed here. Any other approach to talking to GitLab — `curl`, `wget`, Python HTTP libraries, alternate `glab` subcommands not in this table, modifying `.gitlab-ci.yml` to bypass `glab` — is forbidden by the GitLab Access Policy in `SKILL.md`.

This list applies to BOTH the dispatcher's prep scripts and the subagent's post-acpx scripts. Both halves run from the same `scripts/` directory and share the same set of allowed glab calls. The "performer" column tells you who calls each command.

> **No MR and no continue-mode on this branch.** benchmark-test has no merge-request flow: there is no `scripts/create_mr.sh`, and `glab mr create` / `glab mr merge` / `glab mr list` / `glab mr close` / `glab mr view` are never invoked. GitLab-level completion is a human closing the issue; `done` is the agent's terminal success label. `continue` / resume is disabled (every attempt is fresh), and no script reads the issue's notes. The retired MR commands (former G6–G8, G10) and the continue-mode notes read (former G1b) have been removed from this list, and the remaining commands renumbered to a contiguous G1–G9.

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

Every flag used in G1–G9 has been verified to exist on the runner's installed `glab`. Before adding a new flag — here, in `scripts/*.sh`, or in `references/executor_prompt.md` — run `glab <subcommand> --help` on the runner and confirm the flag is listed. The runner may lag mainstream releases, so prefer a long-standing flag over a recently-added one when both exist (e.g. `--description "$(cat <file>)"` over the newer `--description-file <file>`). Workspace-wide policy lives in [`SOUL.md`](../../../SOUL.md) §GitLab Access.

## Commands

### G1 — Read one issue (dispatcher prep + reconcile)

Used by `scripts/reconcile.sh` (across the IID range) and ad-hoc by the dispatcher's prep step that reads `ISSUE_TITLE`. Also used inside `scripts/build_prompt.sh` to fetch the issue body for the Claude Code prompt.

```bash
glab api "projects/${PROJECT_URI}/issues/${ISSUE_IID}"
```

Response is the raw issue JSON. Parse with `jq` to read `.state`, `.labels`, `.title`, `.description`.

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

### G6 — Post a note (comment) on the issue (subagent)

Used by `scripts/summarize_attempt.sh` to post successful `done` attempt summaries back to the issue as a durable, human-readable record. Failure summaries are written locally only when `SUMMARY_POST_TO_ISSUE=false`. Also used by `scripts/upload_attempt_artifacts.sh` to link Wiki evidence before `done` labeling.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}"
```

The `-F body=@<file>` form uploads the file contents as the form field, which avoids quoting issues for large multiline summaries.

### G7 — Read a Wiki page (subagent)

Used by `scripts/upload_attempt_artifacts.sh` to decide whether to create or update an attempt-scoped Wiki page.

```bash
glab api "projects/${PROJECT_URI}/wikis/${WIKI_SLUG_URI}"
```

`WIKI_SLUG_URI` is the URI-encoded Wiki title, for example `issue33%2Fattempt-001%2Fprompt.txt`.

### G8 — Create a Wiki page (subagent)

Used by `scripts/upload_attempt_artifacts.sh` when G7 reports the page is absent. The script creates attempt-scoped Wiki pages:

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

### G9 — Update a Wiki page (subagent)

Used by `scripts/upload_attempt_artifacts.sh` when rerunning the same allocated attempt or resuming after a partial post.

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/wikis/${WIKI_SLUG_URI}" \
  -f "title=${WIKI_TITLE}" \
  -F "content=@${SOURCE_PATH}" \
  -f "format=markdown"
```

The subagent constructs browser URLs as `${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${PROJECT_FULL}/-/wikis/${WIKI_TITLE}` and posts those links back to the issue with G6.

## What is FORBIDDEN

- Any `glab mr` subcommand (`create` / `merge` / `close` / `list` / `view`) — benchmark-test has no merge-request flow at all.
- `glab issue close`, `glab api ... -f state_event=close` — the agent never closes the issue; closing is a human action. There is no MR and no `Closes #<iid>` auto-close on this branch.
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use G4/G5 instead.
- `curl`, `wget`, `httpie`, any HTTP library, any non-glab GitLab SDK.
- `glab issue list` / `glab issue view` for dispatcher-side reconciliation — use the raw `glab api` form (G1) so the output is stable JSON.
- Inventing flags or alternative subcommands. If the operation isn't in this list:
  - dispatcher prep failure → mark IID `blocked-dispatcher` with `block_reason="dispatcher needs unsupported glab op: <description>"` and continue with other batch members.
  - subagent failure → mark issue `blocked-cc` with `block_reason="subagent needs unsupported glab op: <description>"` and stop.
