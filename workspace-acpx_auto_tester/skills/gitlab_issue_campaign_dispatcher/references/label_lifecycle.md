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


   done+pr ──► continue  (HUMAN review action; agent never does this)
              │
              ▼
            doing      (executor in continue mode, on next tick)
              │
              ▼
            done ──► done+pr   (or blocked / failed as usual)
```

## Concrete transitions and how to perform them

All transitions use single-label add/remove (`scripts/set_issue_label.sh`) so that unrelated labels on the issue are preserved.

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep in fresh mode | remove `todo`, `retry`, `new`, `continue`, `contiune`, `blocked`, `done`, `pr`, and every matched trigger `require_labels` label; add `doing` |
| `continue` / `contiune` | `doing` | dispatcher | dispatcher begins prep in continue mode | remove `todo`, `continue`, `contiune`, `retry`, `new`, `blocked`, `done`, `pr`, and every matched trigger `require_labels` label; add `doing` |
| `doing`    | `done`     | subagent   | branch pushed, post-push verification passed, attempt artifacts published to the project Wiki and linked from the issue | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done`     |
| `done`     | `done+pr`  | subagent   | immediately after MR creation / rotation succeeds    | `set_issue_label.sh add pr`                                           |
| `doing`    | `blocked`  | subagent   | retryable failure during this run                    | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked`  |
| `done`     | `done+blocked` | subagent | retryable failure after Wiki evidence and `done`, before `pr` can be added | `set_issue_label.sh add blocked`; do NOT add `pr`                     |
| `blocked`  | `doing`    | dispatcher | retry begins on a later tick after no non-blocked backlog or fresh candidates remain | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add doing`  |
| `blocked`  | `failed`   | dispatcher | `retry_count > blocked_retry_limit` during Phase 6   | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add failed` |
| `done+pr`  | `continue` | **human reviewer** | reviewer notices the prior run was incomplete and wants the agent to re-run on the existing branch | manual on the GitLab UI; the agent does NOT make this transition itself |

## Important rules

1. **`pr` is additive, not a replacement for `done`.** `done` means the agent has solved the issue and published Wiki evidence. `pr` means the corresponding MR exists. After successful MR creation / rotation, both labels MUST be present.
2. **Attempt evidence comes first.** Before `create_mr.sh` runs and before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Dispatcher completion requires `done+pr`.** Because `done` is applied before MR creation, the dispatcher must not treat `done` alone as terminal completion. Reconciliation only considers an issue complete when both labels are present, unless `continue` is also present.
4. **Never call `glab mr merge`.** The merge request stays open for human review.
5. **No full-set label overwrite.** Always use add+remove of single labels (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, etc.) the user may have added.
6. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
7. **Dispatcher final synchronization.** Phase 6 re-applies the terminal workflow labels from the compact reply as an idempotent safety net: `done` replies must end with `done` + `pr`, `blocked` replies must end with `blocked` and no `doing`, and promoted `failed` replies must end with `failed` and no `blocked` / `doing`.

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
