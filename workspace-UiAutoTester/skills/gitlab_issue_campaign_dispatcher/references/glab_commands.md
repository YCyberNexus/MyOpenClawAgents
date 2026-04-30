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

Used for ad-hoc lookups. The bulk reconciliation in `scripts/reconcile.sh` already calls this for the entire IID range.

```bash
glab api \
  "projects/$(printf %s "${GROUP}/${PROJECT}" | jq -sRr @uri)/issues/${IID}"
```

Response is the raw issue JSON. Parse with `jq` to read `.state` and `.labels`.

## D2 — List issues in the project (rarely needed)

Useful only for debugging. The dispatcher's normal flow does not need this; range iteration in `reconcile.sh` is preferred because it produces the evidence file.

```bash
glab api --paginate \
  "projects/$(printf %s "${GROUP}/${PROJECT}" | jq -sRr @uri)/issues?per_page=100&scope=all"
```

## What is NOT allowed

- `curl`, `wget`, `httpie`, any HTTP library
- `glab issue list`, `glab issue view` — the dispatcher uses the raw API form so output is stable JSON
- Any operation that mutates GitLab state (label changes, MR creation, etc.) — those belong to the executor
- Falling back to anything not on this list "just for one quick check"

If a needed operation is not on this list, mark the affected IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and stop.
