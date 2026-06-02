# Label Lifecycle

This document is the workspace-wide reference for issue workflow labels. Both halves of the agent (the dispatcher's prep, and the subagent's post-acpx flow) follow these transitions.

## Required project labels

`scripts/ensure_labels.sh` (called once per tick by the dispatcher) ensures these workflow labels exist:

- `todo`
- `retry`
- `new`
- `doing`
- `pr`
- `done`
- `blocked`
- `failed`
- `timeout` — **subagent-applied terminal label.** Set when `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`, default 18000s). Whatever Claude Code produced before the kill is still committed and force-pushed to `${WORK_BRANCH}`, but no MR / `pr` is opened. The dispatcher treats `timeout` as terminal: the IID is parked in `timeout_iids`, `retry_count` is NOT consumed, and the IID is NOT auto-retried on later ticks. Reviewers re-run the issue by stripping the `timeout` label, by adding `retry` on top of `timeout` for a fresh reset, or by applying `continue` for a continue-mode resume on the existing branch.
- `continue` — **human-applied review label.** Reviewers set this on an issue whose MR was created and labeled `done` + `pr` by the agent, but where the actual Claude Code run did not finish (env failure, partial edits, etc.). The agent never sets `continue` itself — only humans do. When the dispatcher's reconciliation sees `continue`, it re-enqueues the IID and prepares the next attempt's repo checkout from the existing work branch (continue mode). **Reviewer contract** — including how to leave supplemental steps as an issue comment so the agent can pick them up — is documented in `continue_mode.md`.

`contiune` is tolerated as a legacy/misspelled alias for `continue` during reconciliation and removal, but the agent does not create that label.

When the scheduled trigger supplies `require_labels`, those labels are also treated as one-shot entry labels for the matched issue on that tick: if a required label is present on the issue selected for execution, the dispatcher removes it while transitioning the issue to `doing`.

## Transition diagram

```
                     ┌──────────────────────────────────────┐
                     │                                      │
                     ▼                                      │
   todo/retry/new/continue/blocked/trigger-label
             ──► doing ──► done ──► done+pr                 │
                │                                           │
                ▼                                           │
              blocked ──► doing  (after cooldown, and only after non-blocked candidates) ──┘
                │
                ▼
              failed   (retry exhausted, terminal)

  doing ──► blocked  (retryable failure; acpx failures still force-push
                      committable partial work to ${WORK_BRANCH} when possible,
                      but do not open an MR / add pr)

  doing ──► timeout   (acpx exceeded wall-clock cap; partial work force-pushed to ${WORK_BRANCH};
                       NO MR; terminal until a human strips timeout or applies retry/continue)

   done+pr ──► continue  (HUMAN review action; agent never does this)
              │
              ▼
            doing      (executor in continue mode, on next tick)
              │
              ▼
            done ──► done+pr   (or blocked / failed / timeout as usual)
```

## Concrete transitions and how to perform them

All transitions use targeted add/remove calls through `scripts/set_issue_label.sh` so that unrelated non-workflow labels on the issue are preserved. The script also enforces workflow-label exclusivity when adding a workflow label: it removes conflicting workflow labels in the same GitLab issue update, leaving only the target label except for the allowed `done` + `pr` and `done` + `blocked` pairs.

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep in fresh mode | remove `todo`, `retry`, `new`, `continue`, `contiune`, `blocked`, `done`, `pr`, and every matched trigger `require_labels` label; add `doing` |
| `continue` / `contiune` | `doing` | dispatcher | dispatcher begins prep in continue mode | remove `todo`, `continue`, `contiune`, `retry`, `new`, `blocked`, `done`, `pr`, and every matched trigger `require_labels` label; add `doing` |
| `doing`    | `done`     | subagent   | branch pushed, post-push verification passed, attempt artifacts published to the project Wiki and linked from the issue | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done`     |
| `done`     | `done+pr`  | subagent   | immediately after MR creation / rotation succeeds    | `set_issue_label.sh add pr`                                           |
| `doing`    | `blocked`  | subagent   | retryable failure during this run; for acpx failures, committable partial work is first staged, committed, and force-pushed to `${WORK_BRANCH}` when possible, but no MR / `pr` is opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked`  |
| `doing`    | `timeout`  | subagent   | `acpx claude exec` exceeded its wall-clock cap; partial work was committed and force-pushed to `${WORK_BRANCH}` but NO MR / `pr` was opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add timeout`  |
| `done`     | `done+blocked` | subagent | retryable failure after Wiki evidence and `done`, before `pr` can be added | `set_issue_label.sh add blocked`; do NOT add `pr`                     |
| `blocked`  | `doing`    | dispatcher | retry begins on a later tick after no non-blocked backlog or fresh candidates remain | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add doing`  |
| `blocked`  | `failed`   | dispatcher | `retry_count > blocked_retry_limit` during Phase 6; launch-side `sessions_spawn` failures do not increment `retry_count` | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add failed` |
| `timeout`  | `doing`    | dispatcher | a human reviewer stripped the `timeout` label, added `retry` on top of `timeout`, or applied `continue` — the dispatcher then treats it like any other unfinished entry | normal `*` → `doing` transition above |
| `done+pr`  | `continue` | **human reviewer** | reviewer notices the prior run was incomplete and wants the agent to re-run on the existing branch | manual on the GitLab UI; the agent does NOT make this transition itself |

## Important rules

1. **`pr` is additive, not a replacement for `done`.** `done` means the agent has solved the issue and published Wiki evidence. `pr` means the corresponding MR exists. After successful MR creation / rotation, both labels MUST be present.
2. **Attempt evidence comes first.** Before `create_mr.sh` runs and before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Dispatcher completion requires `done+pr`.** Because `done` is applied before MR creation, the dispatcher must not treat `done` alone as terminal completion. Reconciliation only considers an issue complete when both labels are present, unless `continue` is also present.
4. **Never call `glab mr merge`.** The merge request stays open for human review.
5. **No full-set label overwrite.** Always use targeted add/remove operations through `set_issue_label.sh` (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, etc.) the user may have added.
6. **Workflow-label exclusivity.** Aside from `done` + `pr` and `done` + `blocked`, an issue should carry at most one workflow label at a time. `set_issue_label.sh add <workflow-label>` removes conflicting workflow labels automatically, so a missed explicit `remove blocked` cannot leave `doing` + `blocked` behind.
7. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
8. **Dispatcher final synchronization.** Phase 6 re-applies the terminal workflow labels from the compact reply as an idempotent safety net: `done` replies must end with `done` + `pr`, `blocked` replies must end with `blocked` and no `doing`, promoted `failed` replies must end with `failed` and no `blocked` / `doing`, and `timeout` replies must end with `timeout` and no `doing` / `blocked` / `failed`.
9. **`timeout` is never auto-retried.** Unlike `blocked`, a `timeout` IID stays in `timeout_iids` until a human reviewer strips the label, adds `retry`, or applies `continue`. Stripping `timeout` or adding `retry` re-enqueues via the regular `user_reopened` path and runs a fresh reset; `continue` resumes from the existing `${WORK_BRANCH}` (the partial work is already pushed there) while refreshing shared config paths from latest `origin/${DEV_BRANCH}`. The agent does NOT promote `timeout` to `failed`; `retry_count` is NOT consumed.

## Issue closure vs `done` label

These are two SEPARATE signals. The agent only controls the first; the second is GitLab's job.

| Signal              | Who sets it                         | When                                              | Means                                  |
| ------------------- | ----------------------------------- | ------------------------------------------------- | -------------------------------------- |
| `done` label        | the subagent                        | immediately after attempt evidence Wiki publication, before MR creation / rotation | "the agent finished solving and published evidence" |
| `pr` label          | the subagent                        | immediately after `create_mr.sh` returns successfully | "the MR exists for human review" |
| issue closed (`state=closed`) | GitLab itself (native auto-close) | when the MR is merged                             | "a human reviewed, approved, and merged" |

GitLab's native auto-close is triggered by the **closing keyword in the MR description**. `scripts/create_mr.sh` writes the description starting with:

```
Closes #${ISSUE_IID}
```

When the MR merges, GitLab parses that line and closes the linked issue automatically. No agent action is required.

**Prerequisites on the GitLab project** (these are GitLab defaults; only worry about them if someone disabled them):

- Project → Settings → Merge requests → "Automatically close referenced merge requests" is enabled.
- The MR's target branch is the project's default branch (`master` in this workspace), which is the only case GitLab auto-closes for. Auto-close does NOT fire on MRs into non-default branches.

**The agent MUST NOT close the issue itself** (no `glab api ... --method PUT ... -f state_event=close`). Closing is the human reviewer's prerogative via the merge action; the subagent's job ends when `done` and `pr` are both present.

**Approve vs merge.** GitLab's auto-close fires on **merge**, not approve. If your team uses "approve must precede merge", the practical effect is "issue closes after approve+merge", which is what you want. There is no agent-side support for "close on approve only" — that would require webhook plumbing outside this skill.
