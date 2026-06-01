# acpx-auto-tester-temporal

Replacement for the bash + JSON + `flock` dispatcher that previously lived under
[`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/`](../skills/gitlab_issue_campaign_dispatcher/).
The two OpenClaw triggers (`RUN_SCHEDULED_ISSUE_CAMPAIGN`,
`RUN_CHILD_COMPLETION_CALLBACK`) and the wrapper scripts they fan out to are
superseded by Temporal workflows and activities — see the migration plan in
[`/Users/yuanchenxiang/.claude/plans/2-dispatcher-temporal-temporal-gleaming-cat.md`](../../../.claude/plans/2-dispatcher-temporal-temporal-gleaming-cat.md)
for the rationale and phased rollout.

> **Where this code runs**: this Temporal package is deployed onto the existing
> acpx runner (the same machine that already hosts `acpx claude exec`,
> `glab`, the cloned target repo at `/data/<project>/`, and the per-issue
> linked worktrees). It is **not** meant to be executed on a developer laptop —
> `acpx` and Claude Code are runner-only per CLAUDE.md.

## Layout

```
temporal/
├── pyproject.toml           — package metadata + dev deps
├── requirements.txt         — pinned runtime deps for `pip install -r`
├── worker.py                — runner entrypoint: `python -m acpx_temporal.worker`
├── client.py                — schedule + workflow management CLI
├── shared/                  — dataclasses, error taxonomy, env bootstrap, UI account pool
├── activities/              — thin asyncio.subprocess wrappers around the kept bash scripts
├── workflows/               — CampaignWorkflow + IssueAttemptWorkflow
├── schedules/               — Schedule / ScheduleOverlapPolicy.BUFFER_ONE helper
└── tests/                   — pytest using temporalio.testing.WorkflowEnvironment
```

The bash scripts under `../skills/gitlab_issue_campaign_dispatcher/scripts/`
are **kept** and called by the activities via `asyncio.create_subprocess_exec`.
Only the four orchestrator dispatch wrappers
(`dispatch_prepare_tick.sh`, `dispatch_record_spawn.sh`,
`dispatch_followup.sh`, `_dispatch_lib.sh`, plus `allocate_attempt.sh`) are
slated for deletion in the migration's Phase 4.

## Prerequisites (Temporal layer)

The runner toolchain the bash leaf scripts depend on — `acpx` + Claude Code,
`glab`, `git`, `jq`, GNU coreutils `timeout` — is assumed already installed and
proven on this host (it was, under the legacy pure-agent dispatcher). This
section lists only what the **Temporal port adds on top**. If you are running
against a local `temporal server start-dev`, these seven items are the whole
delta over "just run the commands below":

1. **Deploy a checkout that includes the TLS-optional change.** The editable
   install points at this working tree, so the `_connect`/`_connect_client`
   helpers it runs must be the ones that make `TEMPORAL_TLS_CERT` /
   `TEMPORAL_TLS_KEY` optional. An older checkout still hard-requires them and
   `SystemExit`s the moment the worker tries to connect to the dev server.

2. **Install `temporalio` + `pydantic` into the worker's Python env**
   (`pip install -e`, see below). Needs PyPI (or a mirror) reachable.
   `temporalio` ships a compiled core; prebuilt wheels exist for mainstream
   Linux/macOS, but an exotic distro (e.g. musl/Alpine) may need a build
   toolchain. **Keep the `-e`** — a non-editable install breaks the relative
   `skills/.../scripts/` lookup unless you also set `ACPX_SCRIPTS_DIR`.

3. **Run the dev server, and persist it.** `temporal server start-dev` is
   in-memory by default and loses every Schedule on restart; pass
   `--db-filename /var/lib/temporal/dev.db` (any writable path). The `default`
   namespace is auto-registered — no manual creation needed.

4. **Put `GITLAB_TOKEN` in the worker process env.** This is the key change
   from the legacy path: the token used to ride in on the trigger payload, but
   the Temporal port reads it from `os.environ` at worker startup
   (`shared/env.py` → `glab_auth.sh`). A real token with `api` +
   `write_repository` scope.

5. **Author `/etc/acpx/campaign-input.json`.** It replaces the legacy trigger
   payload; `acpx-temporal-client create-schedule --input-file` validates it
   against `CampaignInput` before sending. See §Manage schedules for the field
   set.

6. **Keep `NODE_ID` consistent between the worker and the Schedule.** Both the
   `--task-queue` the worker binds and the `--task-queue` the Schedule targets
   derive from `acpx-worktree-${NODE_ID}`; a mismatch leaves the workflow
   pending forever because no worker polls its queue.

7. **Launch the worker from an environment that still reaches the toolchain.**
   The worker only passes a whitelist of env vars (`PATH`, `HOME`, `LANG`, …;
   see `shared/env.py` `_INHERIT_PASSTHROUGH`) through to the bash subprocesses.
   Starting it from the same shell/account the legacy agent used is enough —
   `PATH` (for `glab`/`acpx`/`git`/`jq`) and `HOME` (for their config dirs) are
   inherited. Under systemd you must set `Environment=PATH=… HOME=…` explicitly.

Pre-flight check to run on the host before the first tick:

```bash
for c in jq git glab acpx timeout python3; do
  command -v "$c" >/dev/null 2>&1 && echo "OK       $c -> $(command -v "$c")" || echo "MISSING  $c"
done
python3 -c 'import sys; assert sys.version_info>=(3,11), sys.version; print("OK       python", sys.version.split()[0])'
( exec 3<>/dev/tcp/gitlab-b.pxsemic.tech/30000 ) 2>/dev/null \
  && echo "OK       gitlab host reachable" || echo "UNREACHABLE  gitlab-b.pxsemic.tech:30000"
```

## Install (runner side)

```bash
# Inside the runner's Python environment
pip install -e workspace-acpx_auto_tester/temporal
```

This exposes `acpx-temporal-worker` and `acpx-temporal-client` as console
scripts via the `[project.scripts]` entry in `pyproject.toml`. Keep the `-e`
flag (editable): the worker resolves the kept bash scripts by walking up from
the package's source location to `workspace-acpx_auto_tester/skills/...`, which
only exists in the source tree, not in a copied site-packages install.

## Run a worker (runner side)

TLS is **opt-in**: set BOTH `TEMPORAL_TLS_CERT` and `TEMPORAL_TLS_KEY` for a
Temporal Cloud mTLS connection, or leave BOTH unset to connect in plaintext to
a local `temporal server start-dev`. Setting exactly one of the two is rejected
at startup (guards against silently downgrading a Cloud deployment to plaintext).

### Against Temporal Cloud (mTLS)

```bash
export TEMPORAL_ADDRESS="<region>.tmprl.cloud:7233"
export TEMPORAL_NAMESPACE="acpx-auto-tester-temporal-prod"
export TEMPORAL_TLS_CERT="/etc/acpx/temporal-client.pem"
export TEMPORAL_TLS_KEY="/etc/acpx/temporal-client.key"
export NODE_ID="${HOSTNAME}"            # worktree affinity key
export GITLAB_TOKEN="<token>"           # forwarded to glab_auth.sh

python -m acpx_temporal.worker --task-queue "acpx-worktree-${NODE_ID}"
```

### Against a local dev server (plaintext)

Start the dev server first (use `--db-filename` so Schedules survive a restart —
the dev server is in-memory by default):

```bash
temporal server start-dev --db-filename /var/lib/temporal/dev.db
# gRPC: localhost:7233   Web UI: http://localhost:8233   namespace: default
```

Then launch the worker with the TLS pair unset:

```bash
export TEMPORAL_ADDRESS="localhost:7233"
export TEMPORAL_NAMESPACE="default"
unset  TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY   # plaintext connection
export NODE_ID="${HOSTNAME}"
export GITLAB_TOKEN="<token>"

python -m acpx_temporal.worker --task-queue "acpx-worktree-${NODE_ID}"
```

The worker binds to a **host-specific task queue** so all activities for a
given IID's per-issue linked worktree land on the same machine. See the
migration plan §Risk register row 1.

## Manage schedules (runner side)

```bash
# Create the production campaign schedule
acpx-temporal-client create-schedule \
    --schedule-id "campaign:px_ifp_hulat" \
    --task-queue  "acpx-worktree-${HOSTNAME}" \
    --interval    55m \
    --input-file  /etc/acpx/campaign-input.json

# Pause / resume / delete
acpx-temporal-client pause-schedule  --schedule-id campaign:px_ifp_hulat
acpx-temporal-client resume-schedule --schedule-id campaign:px_ifp_hulat
acpx-temporal-client delete-schedule --schedule-id campaign:px_ifp_hulat
```

## Local dev (laptops)

Only the offline parts are exercised on a developer machine:

```bash
pip install -e ".[dev]"
ruff check .
mypy .
pytest tests/
```

`pytest` uses `temporalio.testing.WorkflowEnvironment` to mock both the
Temporal Service and the bash leaf scripts, so the offline lint/type/test loop
above needs no running Temporal Service at all.

A live cluster is only required to actually run workers and schedules: that is
either Temporal Cloud (mTLS) or a local `temporal server start-dev` (plaintext)
as shown in §Run a worker. Note that end-to-end execution still needs the full
runner toolchain (`acpx` + Claude Code, `glab`, the cloned target repo) on the
worker host — the dev server only replaces the Temporal control plane, not those.
