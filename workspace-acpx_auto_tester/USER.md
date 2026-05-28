# acpx_auto_tester_temporal User Contract

Use this workspace for a recurring scheduled GitLab issue campaign.

## Scheduler Command

Send the same dispatcher command every tick. Command name: `RUN_SCHEDULED_ISSUE_CAMPAIGN`. Full input list, required vs optional fields, and override rules are in [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md).

Notes:

- `branch` is the **integration / target** branch (typically `master`); `dev_branch` is the **clean baseline** (typically `dev`) used to reset fresh-mode repo checkouts so Claude Code does not see past issues' spec accumulation. If your project has no separate baseline, set `dev_branch=<same-as-branch>`.
- `max_concurrent_subagents` defaults to `1`; raise it to fan out across multiple in-flight IIDs. When the deployment configures the UI account pool at `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}` (no default; opt in with trigger field `ui_accounts_relpath`, resolved under the project checkout root so the pool may live under any repo subdirectory), the pool size also caps `max_concurrent_subagents`; when the field is unconfigured, no pool is read and no upper bound applies. Each in-flight subagent must hold a distinct account. `max_accounts_per_issue` defaults to `14` and caps how many accounts any one issue receives after the pool is divided by concurrency. The dispatcher gives each IID its own shared per-issue linked git worktree (reused across every attempt of that IID; `continue` resumes from latest same-IID work, while all non-continue entry labels reset from the clean baseline after archiving prior `${RESULT_BASENAME}/issue-<iid>/` files; same-IID attempts never run concurrently). Cross-IID parallelism stays safe at the working-tree level because different IIDs always get different worktree paths.
- `gitlab_address` is no longer required (the host is pinned at `<workspace>/config/gitlab.env`). If supplied, it is treated as a verification value — see [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md) §Optional inputs.

## Expected Behavior

- same dispatcher session every scheduler tick
- one dedicated session per issue
- backlog carryover
- blocked issues may be skipped temporarily and retried later
- remaining quota should be used on later issues when possible
- detailed logs are stored on disk, not in chat
