# glab Commands (Executor)

The executor is allowed only the commands listed here. Any other approach to talking to GitLab — `curl`, `wget`, Python HTTP libraries, alternate `glab` subcommands not in this table, modifying `.gitlab-ci.yml` to bypass `glab` — is forbidden by the GitLab Access Policy in `SKILL.md`.

## Authentication and host

The host is **pinned at deployment time** in `<workspace>/config/gitlab.env`. `scripts/glab_auth.sh` reads that pin, verifies the trigger's `gitlab_address` matches, refreshes the token via `glab auth login`, and prints `${GITLAB_HOST}`.

The executor MUST source `${GITLAB_HOST}` from `scripts/glab_auth.sh` only. It MUST NEVER re-derive the host from `${GITLAB_ADDRESS}` (no inline `sed`, no `awk`, no manual stripping of scheme/trailing slash).

After `glab_auth.sh` runs, the agent should also export the URI-encoded project handle:

```bash
PROJECT_FULL="${GROUP}/${PROJECT}"
PROJECT_URI="$(printf %s "${PROJECT_FULL}" | jq -sRr @uri)"
export GITLAB_HOST PROJECT_FULL PROJECT_URI
```

## E1 — Read the target issue

Used to fetch title, description, and current labels.

```bash
glab api --hostname "${GITLAB_HOST}" \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}"
```

## E1b — Read the target issue's notes (comments)

Used in **continue mode** so the executor can pick up reviewer-supplied supplemental steps. Reviewers leave the supplemental instructions as a comment on the issue before flipping the label from `done` to `continue`; this command reads those comments. See `references/continue_mode.md` for the reviewer contract.

```bash
glab api --hostname "${GITLAB_HOST}" --paginate \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at"
```

The response is a JSON array of note objects. The executor cares about non-system notes (`.system == false`); each has `body`, `author.username`, `created_at`. The executor concatenates these into the Claude Code prompt verbatim, in chronological order.

In fresh mode, fetching notes is optional — the original description is the source of truth. In continue mode, fetching notes is **mandatory**.

## E2 — List project labels

Used by `scripts/ensure_labels.sh` to detect missing workflow labels.

```bash
glab api --hostname "${GITLAB_HOST}" --paginate \
  "projects/${PROJECT_URI}/labels?per_page=100"
```

## E3 — Create a missing label

Used by `scripts/ensure_labels.sh`. Run once per missing name.

```bash
glab api --hostname "${GITLAB_HOST}" --method POST \
  "projects/${PROJECT_URI}/labels" \
  -f "name=${LABEL_NAME}" -f "color=#808080"
```

## E4 — Add a single label to the issue (preferred for transitions)

Wrapped by `scripts/set_issue_label.sh add <label>`.

```bash
glab api --hostname "${GITLAB_HOST}" --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "add_labels=${LABEL}"
```

## E5 — Remove a single label from the issue (preferred for transitions)

Wrapped by `scripts/set_issue_label.sh remove <label>`.

```bash
glab api --hostname "${GITLAB_HOST}" --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "remove_labels=${LABEL}"
```

## E6 — Look up an existing open MR for the work branch

Used by `scripts/create_mr.sh` to detect "MR already exists for this branch" before creating a new one (Strategy A — single MR per issue).

```bash
glab mr list \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --state opened \
  --output json
```

Returns a JSON array. Use `jq -r 'if length > 0 then .[0].web_url else "" end'` to extract the URL.

## E7 — Create a merge request

Wrapped by `scripts/create_mr.sh`. Only call this when E6 returned empty.

```bash
glab mr create \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --target-branch "${BRANCH}" \
  --title "Issue #${ISSUE_IID}: ${ISSUE_TITLE}" \
  --description-file "${LOG_DIR}/mr_description.md" \
  --yes
```

## E8 — Look up the MR URL after creation

```bash
glab mr view "${WORK_BRANCH}" --repo "${PROJECT_FULL}" --output json | jq -r '.web_url'
```

## E9 — Post a note (comment) on the issue

Used by `scripts/summarize_attempt.sh` to post the per-attempt summary back to the issue so the next continue-mode run can read it.

```bash
glab api --hostname "${GITLAB_HOST}" --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}"
```

The `-F body=@<file>` form uploads the file contents as the form field, which avoids quoting issues for large multiline summaries.

## What is FORBIDDEN

- `glab mr merge` — under any circumstances. The MR stays open.
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use E4/E5 instead.
- `curl`, `wget`, `httpie`, any HTTP library, any non-glab GitLab SDK.
- Inventing flags or alternative subcommands. If the operation isn't in this list, mark the issue `blocked` with `block_reason="executor needs unsupported glab op: <description>"` and stop.
