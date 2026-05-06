# glab Commands (Dispatcher)

The dispatcher is allowed only the commands listed below. Anything else — `curl`, `wget`, Python HTTP libraries, alternate `glab` subcommands — is forbidden by the GitLab Access Policy in `SKILL.md`.

## Authentication and host

The host is pinned in `<workspace>/config/gitlab.env`; `scripts/env_paths.sh` invokes `scripts/glab_auth.sh` to authenticate and exports `${GITLAB_HOST}`, `${PROJECT_FULL}`, `${PROJECT_URI}`. Policy (verification, token rotation, abort-on-mismatch, never re-derive host) lives in [`SOUL.md`](../../../SOUL.md) §GitLab Host Pinning.

The dispatcher may use these auth commands only inside `scripts/glab_auth.sh`:

```bash
glab auth login \
  --hostname "${GITLAB_HOST}" \
  --token "${GITLAB_TOKEN}" \
  --api-protocol "${GITLAB_API_PROTOCOL}"

glab auth status --hostname "${GITLAB_HOST}"
```

## D1 — Read one issue

Used by reconciliation and `scripts/prepare_issue_environment.sh` / `scripts/build_prompt.sh`.

```bash
glab api \
  "projects/$(printf %s "${GROUP}/${PROJECT}" | jq -sRr @uri)/issues/${IID}"
```

Response is the raw issue JSON. Parse with `jq` to read `.state` and `.labels`.

## D1b — Read one issue's notes

Used by dispatcher-owned `scripts/build_prompt.sh` in continue mode before the worker is spawned.

```bash
glab api --paginate \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes?sort=asc&order_by=created_at"
```

## D3 — Verify glab auth

Used by `scripts/preflight_issue.sh` after `scripts/env_paths.sh` has authenticated against the pinned host.

```bash
glab auth status --hostname "${GITLAB_HOST}"
```

## D4 — List open MRs for the prepared work branch

Used by `scripts/preflight_issue.sh` in fresh mode to skip IIDs that already have an open MR.

```bash
glab mr list \
  --repo "${PROJECT_FULL}" \
  --source-branch "${WORK_BRANCH}" \
  --state opened \
  --output json
```

## D2 — List issues in the project (rarely needed)

Useful only for debugging. The dispatcher's normal flow does not need this; range iteration in `reconcile.sh` is preferred because it produces the evidence file.

```bash
glab api --paginate \
  "projects/$(printf %s "${GROUP}/${PROJECT}" | jq -sRr @uri)/issues?per_page=100&scope=all"
```

## What is NOT allowed

- `curl`, `wget`, `httpie`, any HTTP library
- `glab issue list`, `glab issue view` — the dispatcher uses the raw API form so output is stable JSON
- Any operation that mutates GitLab state (label changes, MR creation, Wiki writes, etc.) — those belong to the prepared worker
- Falling back to anything not on this list "just for one quick check"

If a needed operation is not on this list, mark the affected IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and stop.
