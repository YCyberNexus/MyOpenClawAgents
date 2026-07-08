# req_dispatcher Executor Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable FIFO executor issue queue owned by `req_dispatcher`, with automatic drain and recovery after interrupted dispatcher turns.

**Architecture:** `req_dispatcher` stores queued and active executor work in `${STATE_ROOT}/_dispatcher/executor_queue.json`. Queue scripts handle enqueue, one-item drain, and callback completion; the existing `req_executor RUN_SINGLE_ISSUE` remains the worker boundary.

**Tech Stack:** Bash 4+, `jq`, existing OpenClaw CLI wrapper `run_agent_turn.sh`, existing dispatcher `pending.json` and `ledger.jsonl`.

## Global Constraints

- Do not write GitLab from `req_dispatcher`; it only calls `git_issuer` and `req_executor`.
- Use `/opt/homebrew/bin/bash` for local req_dispatcher script tests when available.
- Do not run destructive cleanup commands in the repository.
- Changes under `workspace-req_dispatcher/` require bumping `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md` `SKILL_VERSION`.
- Queue drain must be idempotent and safe to call from a periodic wake-up.

---

### Task 1: Queue State Primitives

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/env_paths.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/enqueue_executor_issue.sh`
- Test: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_queue_enqueue.sh`

**Interfaces:**
- Produces: `${EXECUTOR_QUEUE_FILE}` and `enqueue_executor_issue.sh` stdout JSON `{status, queue_id, queued_count}`.

- [ ] **Step 1: Write failing enqueue test**
- [ ] **Step 2: Run test and verify it fails because script/file is missing**
- [ ] **Step 3: Implement queue file initialization and enqueue script**
- [ ] **Step 4: Run enqueue test and verify pass**

### Task 2: Queue Drain Launch

**Files:**
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/drain_executor_queue.sh`
- Test: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_queue_drain.sh`

**Interfaces:**
- Consumes: queued item from `executor_queue.json`.
- Produces: active item plus a prewritten executor pending placeholder.
- Accepts a launch only when executor `worker_result_json.status` is
  `waiting_for_callbacks` or current chat summary text contains
  `waiting_for_callbacks`; other outputs become `launch_failed` without
  leaving pending behind.

- [ ] **Step 1: Write failing drain test with fake `openclaw`**
- [ ] **Step 2: Verify failure because drain script does not exist**
- [ ] **Step 3: Implement one-item claim, `RUN_SINGLE_ISSUE` launch, and pending record**
- [ ] **Step 4: Run drain test and verify first issue launches only once**

### Task 3: Callback Completion and Next Drain

**Files:**
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/finish_executor_queue_active.sh`
- Test: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_queue_finish_and_next.sh`

**Interfaces:**
- Consumes: `CORRELATION_ID`, optional `PROJECT`, `IID`.
- Produces: cleared `active` when correlation matches.

- [ ] **Step 1: Write failing finish/next test**
- [ ] **Step 2: Verify failure because finish script does not exist**
- [ ] **Step 3: Implement active clear by correlation**
- [ ] **Step 4: Run finish/next test and verify second queued issue launches**

### Task 4: Interrupted Launch Recovery

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/drain_executor_queue.sh`
- Test: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_queue_recover_launching.sh`

**Interfaces:**
- Consumes: stale active item with `launch_state="launching"`.
- Produces: relaunch using the same `correlation_id` and `run_id`.

- [ ] **Step 1: Write failing stale-launching recovery test**
- [ ] **Step 2: Verify failure because stale active blocks drain**
- [ ] **Step 3: Add stale `launching` reclaim and same-id retry**
- [ ] **Step 4: Run recovery test and verify ids are reused**

### Task 5: Orchestrator Contract and Version Bump

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`
- Modify: `workspace-req_dispatcher/CLAUDE.md`
- Modify: `workspace-req_dispatcher/AGENTS.md`
- Modify: `workspace-req_dispatcher/SOUL.md`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/references/state_schema.md`
- Modify: `workspace-req_dispatcher/config/README.md`

**Interfaces:**
- Documents `RUN_EXECUTOR_QUEUE_DRAIN`, enqueue-on-intake, finish-and-drain-on-callback, and periodic wake-up deployment.

- [ ] **Step 1: Update docs to make the queue path the canonical executor path**
- [ ] **Step 2: Bump `SKILL_VERSION=2026-07-08.1`**
- [ ] **Step 3: Run syntax checks and targeted queue tests**

### Task 6: Stuck Executor Active Recovery

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/evict_stuck.sh`
- Test: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_evict_stuck_notifies_executor_timeout.sh`
- Modify: queue recovery contract docs listed in Task 5.

**Interfaces:**
- When `evict_stuck.sh` evicts an executor pending entry, it clears the matching `executor_queue.json.active` by `run_id` or `correlation_id`.
- `RUN_EXECUTOR_QUEUE_DRAIN` runs `evict_stuck.sh` before `drain_executor_queue.sh`.

- [ ] **Step 1: Add failing test proving stuck executor pending leaves queue active blocked**
- [ ] **Step 2: Implement active clearing in `evict_stuck.sh` under the existing queue/pending lock**
- [ ] **Step 3: Update Path C docs to evict before drain**
- [ ] **Step 4: Run evict and queue tests**
