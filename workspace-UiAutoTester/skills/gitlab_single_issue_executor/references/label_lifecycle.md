# Label Lifecycle (Executor)

## Required project labels

The executor ensures these seven labels exist via `scripts/ensure_labels.sh`:

- `todo`
- `doing`
- `pr`
- `done`
- `blocked`
- `failed`
- `continue` — **human-applied review label.** Reviewers set this on an issue whose MR was created and labeled `done` by the agent, but where the actual Claude Code run did not finish (env failure, partial edits, etc.). The agent never sets `continue` itself — only humans do. When the dispatcher's reconciliation sees `continue`, it re-enqueues the IID and the executor restarts the resolution flow against the existing work branch. **Reviewer contract** — including how to leave supplemental steps as an issue comment so the agent can pick them up — is documented in `continue_mode.md`.

## Transition diagram

```
                     ┌──────────────────────────────────────┐
                     │                                      │
                     ▼                                      │
   (start) ──► doing ──► pr ──► done                        │
                │                                           │
                ▼                                           │
              blocked ──► doing  (after cooldown / retry) ──┘
                │
                ▼
              failed   (retry exhausted, terminal)


   done ──► continue  (HUMAN review action; agent never does this)
              │
              ▼
            doing      (executor in continue mode, on next tick)
              │
              ▼
            pr ──► done   (or blocked / failed as usual)
```

## Concrete transitions and how to perform them

All transitions use single-label add/remove (`scripts/set_issue_label.sh`) so that unrelated labels on the issue are preserved.

| From       | To         | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo`     | `doing`    | executor begins work in fresh mode                   | `set_issue_label.sh remove todo` ; `set_issue_label.sh add doing`     |
| `continue` | `doing`    | executor begins work in continue mode (resume run)   | `set_issue_label.sh remove continue` ; `set_issue_label.sh add doing` |
| `doing`    | `pr`       | branch pushed, attempt artifacts published to the project Wiki and linked from the issue, MR successfully created | `set_issue_label.sh remove doing` ; `set_issue_label.sh add pr`       |
| `pr`       | `done`     | immediately after MR creation succeeds (terminal)    | `set_issue_label.sh remove pr` ; `set_issue_label.sh add done`        |
| `doing`    | `blocked`  | retryable failure during this run                    | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked`  |
| `blocked`  | `doing`    | retry begins on a later tick                         | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add doing`  |
| `blocked`  | `failed`   | `retry_count > blocked_retry_limit`                  | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add failed` |
| `done`     | `continue` | **human reviewer** notices the prior run was incomplete and wants the agent to re-run on the existing branch | manual on the GitLab UI; the executor does NOT make this transition itself |

## Important rules

1. **`pr` is a transient state.** For this automation, successful MR creation is the terminal completion condition. The executor MUST transition `pr → done` immediately after `create_mr.sh` returns. The issue must not be left at `pr` waiting for human merge.
2. **Attempt evidence comes first.** Before `create_mr.sh` runs and before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Never call `glab mr merge`.** The merge request stays open for human review.
4. **No full-set label overwrite.** Always use add+remove of single labels (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, etc.) the user may have added.
5. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.

## Issue closure vs `done` label

These are two SEPARATE signals. The executor only controls the first; the second is GitLab's job.

| Signal              | Who sets it                         | When                                              | Means                                  |
| ------------------- | ----------------------------------- | ------------------------------------------------- | -------------------------------------- |
| `done` label        | the executor (this skill)           | immediately after attempt evidence Wiki publication and `create_mr.sh` return successfully | "the agent finished its half of the work" |
| issue closed (`state=closed`) | GitLab itself (native auto-close) | when the MR is merged                             | "a human reviewed, approved, and merged" |

GitLab's native auto-close is triggered by the **closing keyword in the MR description**. `scripts/create_mr.sh` writes the description starting with:

```
Closes #${ISSUE_IID}
```

When the MR merges, GitLab parses that line and closes the linked issue automatically. No agent action is required.

**Prerequisites on the GitLab project** (these are GitLab defaults; only worry about them if someone disabled them):

- Project → Settings → Merge requests → "Automatically close referenced merge requests" is enabled.
- The MR's target branch is the project's default branch (`master` in this workspace), which is the only case GitLab auto-closes for. Auto-close does NOT fire on MRs into non-default branches.

**The executor MUST NOT close the issue itself** (no `glab api ... --method PUT ... -f state_event=close`). Closing is the human reviewer's prerogative via the merge action; the executor's job ends at `done`.

**Approve vs merge.** GitLab's auto-close fires on **merge**, not approve. If your team uses "approve must precede merge", the practical effect is "issue closes after approve+merge", which is what you want. There is no agent-side support for "close on approve only" — that would require webhook plumbing outside this skill.
