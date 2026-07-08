# State Schema

Runtime state lives under `${REPO_PATH}/.req_executor/`.

## Campaign State

Path:

```text
${REPO_PATH}/.req_executor/_dispatcher/campaign_state.json
```

Important fields:

- `project`
- `repo_path`
- `branch`
- `issue_min_iid`
- `issue_max_iid`
- `hourly_issue_quota`
- `max_runtime_minutes`
- `blocked_retry_limit`
- `blocked_cooldown_ticks`
- `max_concurrent_subagents`
- `stuck_after_minutes`
- `run_timeout_seconds`
- `acpx_timeout_seconds`
- `kill_subagent_on_terminal`
- `result_note_enabled`
- `issue_iids_whitelist`
- `require_labels`
- `require_labels_match`
- `model_tiers`
- `continue_upgrade_threshold`
- `pending_subagents`
- `blocked_iids`
- `failed_iids`
- `timeout_iids`
- `completed_iids`
- `last_reconcile_evidence`
- `updated_at`

There are no persisted runtime basename, data directory, or account-pool fields.

## Per-Issue State

Path:

```text
${REPO_PATH}/.req_executor/issues/issue-<iid>/state.json
${REPO_PATH}/.req_executor/issues/issue-<iid>/attempt_state.json
${REPO_PATH}/.req_executor/issues/issue-<iid>/summary.md
```

The driven `RUN_SINGLE_ISSUE` path also writes:

```text
${REPO_PATH}/.req_executor/issues/issue-<iid>/dispatch_origin.json
```

`dispatch_origin.json` records `correlation_id`, `dispatcher_callback_target`, full `project`, and `iid` for the result callback to `req_dispatcher`.

## Compact Subagent Reply

The subagent's final reply is compact JSON with:

- `iid`
- `attempt_number`
- `status`: `done`, `blocked`, `failed`, or `timeout`
- optional `mr_url`
- optional `wiki_url` legacy compatibility field; new req_executor replies keep it empty
- optional `reason`
- optional `summary`

`dispatch_followup.sh` validates the IID and attempt number against `pending_subagents` before mutating state.
