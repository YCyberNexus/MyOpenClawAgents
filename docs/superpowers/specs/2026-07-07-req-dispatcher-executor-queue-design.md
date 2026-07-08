# req_dispatcher Executor Queue Design

## Problem

`req_executor` can run one `RUN_SINGLE_ISSUE` reliably, but the ad-hoc
"continue with the next issue" behavior can live only in an OpenClaw chat turn.
If that turn is aborted after issue `#11` completes and before issue `#12` is
durably launched, the remaining issue list stalls until a human wakes the
session again.

The required behavior is a durable FIFO queue:

- New wiki intake appends newly created GitLab issues to the tail.
- At most one executor issue is active at a time.
- When the active issue finishes, the next queued issue starts automatically.
- If the dispatcher turn is interrupted, a later wake-up resumes from disk.

## Ownership

`req_dispatcher` owns the queue. It already owns wiki intake, issue creation
handoff, executor routing, origin metadata, executor result callbacks, and user
notifications. `req_executor` remains a single-issue worker that accepts
`RUN_SINGLE_ISSUE`.

## State

Add a durable queue file under the existing dispatcher state root:

```text
${STATE_ROOT}/_dispatcher/executor_queue.json
```

Shape:

```json
{
  "next_id": 1,
  "active": null,
  "queue": []
}
```

Each queued item stores:

- `queue_id`: stable monotonic id such as `execq-1`.
- `project`: GitLab `group/project`.
- `iid`: positive GitLab issue IID.
- `issue_url`: optional GitLab issue URL.
- `executor_agent`: routed executor agent name.
- `origin`: captured requester origin object, or `null`.
- `req_digest`: human-readable requirement digest.
- `queued_at`: epoch seconds.

`active` stores the same item plus:

- `correlation_id`: generated once and reused across launch retries.
- `run_id`: deterministic dispatcher-side run id for the executor turn.
- `launch_state`: `launching`, `launched`, or `launch_failed`.
- `launch_attempts`: integer.
- `launch_started_at`, `launched_at`, `next_retry_after`: epoch seconds or `null`.

The existing `${STATE_ROOT}/_dispatcher/pending.json` remains the source for
"executor callback expected" records. The queue is the source for "not yet
started or currently active executor issue".

## Scripts

Add three queue scripts under `workspace-req_dispatcher/skills/requirement_dispatch/scripts/`:

- `enqueue_executor_issue.sh`: append one issue to the FIFO queue.
- `drain_executor_queue.sh`: if no launched active item exists, claim the next
  queued item or recover a stale launching item, invoke `RUN_SINGLE_ISSUE`
  through `run_agent_turn.sh`, prewrite executor pending when claiming active,
  and mark launch accepted only after the executor returns
  `worker_result_json.status="waiting_for_callbacks"` or current
  `chat_summary` text containing `waiting_for_callbacks`.
- `finish_executor_queue_active.sh`: called from the executor callback path
  after `drain_pending.sh`; clears `active` only when the callback correlation
  matches the active item.

`drain_executor_queue.sh` must not hold the queue lock while calling OpenClaw.
It performs short locked state transitions before and after the call.

## Recovery

Before calling the executor, `drain_executor_queue.sh` moves the item to
`active` with `launch_state="launching"` and persists it. It reuses the same
`correlation_id` and `run_id` on retry. If the process is interrupted:

- If no executor turn was launched, a later drain sees stale `launching` and
  retries.
- If the executor turn was launched but pending was not recorded, retrying the
  same `RUN_SINGLE_ISSUE` is safe because `req_executor` has same-IID pending
  guards.
- If the executor callback arrives while `active` is still `launching`,
  `finish_executor_queue_active.sh` can still clear it by `correlation_id`.

An outer `run_agent_turn.sh` success is not sufficient to treat the issue as
launched. If the executor returns `completed`, `no_eligible_iids`,
`tick_failed`, plain text, or any other output that does not mean "waiting for
callbacks", the queue deletes the prewritten pending placeholder, keeps the
item as `launch_failed`, and a later drain can retry or surface the condition.
If the executor completes and callbacks before its initial turn returns, the
callback drains the placeholder and clears active; the launch drain then returns
`active_changed_after_launch` without recreating stale pending.

A periodic wake-up should call `RUN_EXECUTOR_QUEUE_DRAIN` on
`agent:req_dispatcher:main`, for example every minute. This is the recovery
mechanism for aborted UI/chat turns.

The wake-up must run `evict_stuck.sh` before queue drain. If an executor
pending entry has exceeded `STUCK_AFTER_MINUTES`, eviction writes the timeout
ledger row, removes the pending entry, and clears the matching queue `active`
by `run_id` or `correlation_id`. Without this, a timed-out launched active item
could keep the FIFO blocked forever.

## Orchestrator Contract

Update the `req_dispatcher` skill:

- Path A: after `git_issuer` succeeds, route the project, enqueue the issue,
  drain the `git_issuer` audit stage, then call `drain_executor_queue.sh` once.
  The intake ack can say the issue was queued or launched.
- Path B: after executor result notification and `drain_pending.sh`, call
  `finish_executor_queue_active.sh`, then call `drain_executor_queue.sh` once.
- New Path C: `RUN_EXECUTOR_QUEUE_DRAIN` calls `evict_stuck.sh`, then
  `drain_executor_queue.sh`, and prints the queue drain compact status.

## Failure Policy

Executor launch failures do not remove the queue item. The active item records
`launch_failed`, increments `launch_attempts`, sets `next_retry_after`, and a
later drain retries. This prevents transient gateway or model interruptions from
dropping work.

Executor terminal statuses (`done`, `failed`, `timeout`) clear the active item
because the issue is no longer "待执行". Business retry still requires a new
request or a deliberate requeue.

## Tests

Add shell tests with fake `openclaw`:

- Enqueue preserves FIFO order and stores project, IID, executor, origin, and
  issue URL.
- Draining launches only the first issue and records executor pending.
- Finishing the first issue clears active; the next drain launches the second.
- A stale `launching` active item is retried with the same `correlation_id` and
  `run_id`, proving recovery from an aborted dispatcher turn.
- Stuck executor pending eviction clears the matching queue active and
  preserves queued items behind it.
- Executor output that does not contain
  `worker_result_json.status="waiting_for_callbacks"` or current
  `chat_summary` text containing `waiting_for_callbacks` is rejected and does
  not leave pending behind.

## Deployment

The blue-zone deployment needs a recurring wake-up:

```text
RUN_EXECUTOR_QUEUE_DRAIN
```

targeting `agent:req_dispatcher:main`. The wake-up is idempotent: it does
nothing while an active launched issue is still waiting for callback and has
not exceeded `STUCK_AFTER_MINUTES`, and it does nothing when the queue is empty.
