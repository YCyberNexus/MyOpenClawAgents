# Dispatcher Wrappers

The LLM orchestrator does not hand-write campaign logic. It calls shell wrappers and acts only on their JSON envelopes.

## `dispatch_prepare_tick.sh`

Owns scheduled preparation:

- parses and validates `RUN_SCHEDULED_ISSUE_CAMPAIGN`
- sources `env_paths.sh`
- loads and persists `.req_executor/_dispatcher/campaign_state.json`
- reconciles GitLab labels
- forms the eligible IID batch
- allocates attempt numbers
- prepares per-IID worktrees
- builds `${LOG_DIR}/prompt.txt`
- renders `${LOG_DIR}/spawn_payload.txt`
- emits `dispatch_entries[]` for `sessions_spawn`

It does not read runtime basename, data directory, or account-pool trigger fields.

## `dispatch_record_spawn.sh`

Records a `sessions_spawn` result for one IID. On launch failure it synthesizes a blocked Phase 6 reply and drains the pending entry.

## `dispatch_followup.sh`

Consumes `RUN_CHILD_COMPLETION_CALLBACK` compact JSON, validates it, reconciles the IID, writes terminal state, updates labels, optionally reports results back to `req_dispatcher`, and emits cleanup instructions.

## Standard Env

All wrappers accept:

```text
PROJECT
GROUP
GITLAB_TOKEN
REPO_PARENT_PATH   # optional; defaults to /data
```

Per-IID wrappers additionally receive `ISSUE_IID` and `ATTEMPT_NUMBER`. `env_paths.sh` derives every path from those values and the fixed `.req_executor` runtime directory.
