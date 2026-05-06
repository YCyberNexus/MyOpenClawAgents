# glab Commands (Prepared Worker)

The prepared worker is allowed only the commands listed here. Any other approach to talking to GitLab — `curl`, `wget`, Python HTTP libraries, alternate `glab` subcommands not in this table, modifying `.gitlab-ci.yml` to bypass `glab` — is forbidden by the GitLab Access Policy in `SKILL.md`.

## Authentication and host

The host is pinned in `<workspace>/config/gitlab.env`; `scripts/env_paths.sh` invokes `scripts/glab_auth.sh` to authenticate and exports `${GITLAB_HOST}`, `${PROJECT_FULL}`, `${PROJECT_URI}`. Policy (verification, token rotation, abort-on-mismatch, never re-derive host) lives in [`SOUL.md`](../../../SOUL.md) §GitLab Host Pinning. Minimum trigger env vars per Bash exec are listed in `SKILL.md` §Per-Exec Env Contract.

The prepared worker may use these auth commands only inside `scripts/glab_auth.sh`:

```bash
glab auth login \
  --hostname "${GITLAB_HOST}" \
  --token "${GITLAB_TOKEN}" \
  --api-protocol "${GITLAB_API_PROTOCOL}"

glab auth status --hostname "${GITLAB_HOST}"
```

Reading issue bodies and notes is dispatcher-owned prompt preparation. The prepared worker receives that content through `${LOG_DIR}/prompt.txt` and must not fetch/rebuild it.

## E2 — List project labels

Used by `scripts/ensure_labels.sh` to detect missing workflow labels.

```bash
glab api --paginate \
  "projects/${PROJECT_URI}/labels?per_page=100"
```

## E3 — Create a missing label

Used by `scripts/ensure_labels.sh`. Run once per missing name.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/labels" \
  -f "name=${LABEL_NAME}" -f "color=#808080"
```

## E4 — Add a single label to the issue (preferred for transitions)

Wrapped by `scripts/set_issue_label.sh add <label>`.

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}" \
  -f "add_labels=${LABEL}"
```

## E5 — Remove a single label from the issue (preferred for transitions)

Wrapped by `scripts/set_issue_label.sh remove <label>`.

```bash
glab api --method PUT \
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

## E10 — Close (without merging) an existing MR

Used by `scripts/create_mr.sh` in continue mode to close the previous attempt's MR before creating a fresh one. Closing is NOT merging — the integration branch is unaffected; the closed MR remains in GitLab as historical record.

```bash
glab mr close <mr_iid> --repo "${PROJECT_FULL}"
```

`<mr_iid>` is the per-project MR IID (the integer in `merge_requests/<N>`). Get it via E6 (`.[0].iid`).

The prepared worker MUST NEVER call `glab mr merge`. Closing (E10) is allowed as part of the continue-mode MR rotation; merging is not.

## E9 — Post a note (comment) on the issue

Used by `scripts/summarize_attempt.sh` to post the per-attempt summary back to the issue so the next continue-mode run can read it. Also used by `scripts/upload_attempt_artifacts.sh` to link Wiki evidence before `done` labeling and MR creation.

```bash
glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${SUMMARY_FILE}"
```

The `-F body=@<file>` form uploads the file contents as the form field, which avoids quoting issues for large multiline summaries.

## E11 — Read a Wiki page

Used by `scripts/upload_attempt_artifacts.sh` before `done` labeling and MR creation to decide whether to create or update an attempt-scoped Wiki page.

```bash
glab api \
  "projects/${PROJECT_URI}/wikis/${WIKI_SLUG_URI}"
```

`WIKI_SLUG_URI` is the URI-encoded Wiki title, for example `issue33%2Fattempt-001%2Fprompt.txt`.

## E12 — Create a Wiki page

Used by `scripts/upload_attempt_artifacts.sh` when E11 reports the page is absent. The script creates attempt-scoped Wiki pages:

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

## E13 — Update a Wiki page

Used by `scripts/upload_attempt_artifacts.sh` when rerunning the same allocated attempt or resuming after a partial post. Updating is preferable to creating duplicate pages.

```bash
glab api --method PUT \
  "projects/${PROJECT_URI}/wikis/${WIKI_SLUG_URI}" \
  -f "title=${WIKI_TITLE}" \
  -F "content=@${SOURCE_PATH}" \
  -f "format=markdown"
```

The prepared worker constructs browser URLs as `${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${PROJECT_FULL}/-/wikis/${WIKI_TITLE}` and posts those links back to the issue with E9.

## What is FORBIDDEN

- `glab mr merge` — under any circumstances. The MR stays open.
- Full-set label overwrite (`-f labels=...`) for transitions — wipes manually added labels. Use E4/E5 instead.
- `curl`, `wget`, `httpie`, any HTTP library, any non-glab GitLab SDK.
- Inventing flags or alternative subcommands. If the operation isn't in this list, mark the issue `blocked` with `block_reason="worker needs unsupported glab op: <description>"` and stop.
