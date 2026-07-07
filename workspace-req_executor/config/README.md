# Workspace Config

Files in this directory are **deployment-time pins** edited once on each runner where the agent is deployed. They are NOT generated from trigger inputs and they are NOT touched by the agent at runtime.

Local clone-parent overrides go in ignored `campaign_defaults.local.env`: `dispatch_single_issue.sh` loads `campaign_defaults.env` first, then `campaign_defaults.local.env` when present. Do not commit secrets or personal machine paths to tracked config.

## `gitlab.env`

Pins the GitLab host the agent talks to. Required fields:

- `GITLAB_HOST` — host (with port if non-default) of the pinned GitLab instance. Exported by `scripts/glab_auth.sh`; `glab` reads it natively from the env var, so `glab api` / `glab mr` / `glab issue` calls **must NOT pass `--hostname`** (only `glab auth login` / `glab auth status` inside `glab_auth.sh` take that flag). Example: `gitlab-b.pxsemic.tech:30000`.
- `GITLAB_API_PROTOCOL` — `http` or `https` (must match what the GitLab server actually serves).
- `GITLAB_TOKEN` — optional runner-side token fallback. Keep the committed value empty. Prefer process env or a runner-local deployment copy for real secrets.
- `WIKI_GITLAB_HOST` / `WIKI_GITLAB_API_PROTOCOL` / `WIKI_GITLAB_TOKEN` / `WIKI_GLAB_BIN` — wiki-facing GitLab pins. Current deployment stores these values directly in tracked `gitlab.env`; `glab_auth.sh` also uses `WIKI_GITLAB_TOKEN` as the fallback token when `GITLAB_TOKEN` is empty and uses `WIKI_GLAB_BIN` as the `glab` binary when `GLAB_BIN` is unset.

### Why pin?

The agent runs unattended for long stretches. Re-parsing the host out of `${GITLAB_ADDRESS}` on every tick is fragile — variable corruption, accidental whitespace, or a bad `sed` regex would silently make the agent talk to the wrong place. By pinning at deployment time:

- the agent uses a single, fixed `GITLAB_HOST` on every call to `glab`
- the trigger's `gitlab_address` becomes a **verification** input — if it doesn't resolve to the pinned host, `scripts/glab_auth.sh` aborts with **exit 13** (stderr: `trigger gitlab_address (...) does not match deployment pin (...)`) and the orchestrator records a `block_reason` to that effect. (Exit codes: `10` pin file missing, `11` required field missing, `12` bad `GITLAB_API_PROTOCOL`, `13` trigger/pin host or protocol mismatch.)
- token selection order is: explicit `GITLAB_TOKEN` environment value, `GITLAB_TOKEN` in this file, then `WIKI_GITLAB_TOKEN` in this file.

### Setup

1. Edit `gitlab.env` on the runner with the correct host and protocol. Leave the committed `GITLAB_TOKEN` empty unless this runner deliberately owns a local, uncommitted deployment copy.
2. Run `glab auth login --hostname <host> --token <token> --api-protocol <proto>` once manually to validate; you should see `glab auth status --hostname <host>` succeed.
3. After this, the agent is free to run scheduled ticks.

### Multiple GitLab hosts?

This workspace assumes a single GitLab deployment per runner. If you ever need to point a different runner at a different GitLab, change `gitlab.env` on that runner. Do not try to make the agent multi-tenant by reading the host from trigger inputs — that defeats the whole point of pinning.

## `campaign_defaults.env`

Pins only the clone parent used by the **driven** `RUN_SINGLE_ISSUE` entry point. On the driven path, `req_dispatcher` sends only the I1 trigger inputs: `project`, `iid`, `correlation_id`, `dispatcher_callback_target`, and optional `group`.

Like `gitlab.env`, this file is `source`d (and may be loaded under `set -a`), so it must stay pure `KEY=value` lines — no shell logic, no command substitution, no conditionals.

### Why only this is pinned

The runner has to know where to clone repositories before it can read issue content or repository-local guidance. Everything else is either supplied by the issue/wiki, inferred by the wrapper (`branch` from `origin/HEAD`), or handled by Claude Code/OpenClaw defaults.

### Fields

| Field | Pinned value | Meaning |
| --- | --- | --- |
| `REPO_PARENT_PATH` | `/data` | Absolute parent under which the project is cloned; the final clone target is `${REPO_PARENT_PATH}/${PROJECT}`. Use ignored `campaign_defaults.local.env` to override this for local testing. |

Do not put branch, quota, timeout, token, runtime basename, data directory, or account-pool fields in `campaign_defaults.env`.

## Runtime Layout

`req_executor` stores its own state under the fixed in-repo directory `${REPO_PATH}/.req_executor/`. This directory is not configurable through trigger fields or tracked config. `clone_or_pull.sh` adds `/.req_executor/` to the local `.git/info/exclude`; `stage_and_guard.sh` force-adds only the current issue's output directory plus `prompt.txt` and `claude_result.txt`.

There is no UI-account pool configuration in this workspace. The issue body is passed to Claude Code as the task prompt; credentials, account pools, or project-specific data directories must be described by the issue itself if they are relevant.
