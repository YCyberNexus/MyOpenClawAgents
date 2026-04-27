# Label Lifecycle (Executor)

## Required project labels

The executor ensures these six labels exist via `scripts/ensure_labels.sh`:

- `todo`
- `doing`
- `pr`
- `done`
- `blocked`
- `failed`

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
```

## Concrete transitions and how to perform them

All transitions use single-label add/remove (`scripts/set_issue_label.sh`) so that unrelated labels on the issue are preserved.

| From       | To         | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo`     | `doing`    | executor begins work on a new issue                  | `set_issue_label.sh remove todo` ; `set_issue_label.sh add doing`     |
| `doing`    | `pr`       | branch pushed, MR successfully created               | `set_issue_label.sh remove doing` ; `set_issue_label.sh add pr`       |
| `pr`       | `done`     | immediately after MR creation succeeds (terminal)    | `set_issue_label.sh remove pr` ; `set_issue_label.sh add done`        |
| `doing`    | `blocked`  | retryable failure during this run                    | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked`  |
| `blocked`  | `doing`    | retry begins on a later tick                         | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add doing`  |
| `blocked`  | `failed`   | `retry_count > blocked_retry_limit`                  | `set_issue_label.sh remove blocked` ; `set_issue_label.sh add failed` |

## Important rules

1. **`pr` is a transient state.** For this automation, successful MR creation is the terminal completion condition. The executor MUST transition `pr → done` immediately after `create_mr.sh` returns. The issue must not be left at `pr` waiting for human merge.
2. **Never call `glab mr merge`.** The merge request stays open for human review.
3. **No full-set label overwrite.** Always use add+remove of single labels (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, etc.) the user may have added.
4. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
