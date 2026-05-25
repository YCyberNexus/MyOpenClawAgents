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

## Install (runner side)

```bash
# Inside the runner's Python environment
pip install -e workspace-acpx_auto_tester/temporal
```

This exposes `acpx-temporal-worker` and `acpx-temporal-client` as console
scripts via the `[project.scripts]` entry in `pyproject.toml`.

## Run a worker (runner side)

```bash
export TEMPORAL_ADDRESS="<region>.tmprl.cloud:7233"
export TEMPORAL_NAMESPACE="acpx-auto-tester-temporal-prod"
export TEMPORAL_TLS_CERT="/etc/acpx/temporal-client.pem"
export TEMPORAL_TLS_KEY="/etc/acpx/temporal-client.key"
export NODE_ID="${HOSTNAME}"            # worktree affinity key
export GITLAB_TOKEN="<token>"           # forwarded to glab_auth.sh

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
Temporal Service and the bash leaf scripts. There is no `temporal server
start-dev` step in the local loop — the runner is the only place that ever
talks to a live Temporal Cloud cluster.
