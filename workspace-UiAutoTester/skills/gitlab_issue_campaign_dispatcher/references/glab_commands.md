# glab Commands (Dispatcher)

The dispatcher is allowed only the commands listed below. Anything else — `curl`, `wget`, Python HTTP libraries, alternate `glab` subcommands — is forbidden by the GitLab Access Policy in `SKILL.md`.

## Authentication

Done once per tick by `scripts/glab_auth.sh`. After it runs, treat `${GITLAB_HOST}` (the value it printed) as available.

## D1 — Read one issue

Used for ad-hoc lookups. The bulk reconciliation in `scripts/reconcile.sh` already calls this for the entire IID range.

```bash
glab api --hostname "${GITLAB_HOST}" \
  "projects/$(printf %s "${GROUP}/${PROJECT}" | jq -sRr @uri)/issues/${IID}"
```

Response is the raw issue JSON. Parse with `jq` to read `.state` and `.labels`.

## D2 — List issues in the project (rarely needed)

Useful only for debugging. The dispatcher's normal flow does not need this; range iteration in `reconcile.sh` is preferred because it produces the evidence file.

```bash
glab api --hostname "${GITLAB_HOST}" --paginate \
  "projects/$(printf %s "${GROUP}/${PROJECT}" | jq -sRr @uri)/issues?per_page=100&scope=all"
```

## What is NOT allowed

- `curl`, `wget`, `httpie`, any HTTP library
- `glab issue list`, `glab issue view` — the dispatcher uses the raw API form so output is stable JSON
- Any operation that mutates GitLab state (label changes, MR creation, etc.) — those belong to the executor
- Falling back to anything not on this list "just for one quick check"

If a needed operation is not on this list, mark the affected IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and stop.
