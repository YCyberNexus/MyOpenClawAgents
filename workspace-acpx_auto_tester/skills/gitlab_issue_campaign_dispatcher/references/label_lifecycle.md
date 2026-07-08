# Label Lifecycle

This document is the workspace-wide reference for issue workflow labels. Both halves of the agent (the dispatcher's prep, and the subagent's post-acpx flow) follow these transitions.

## Required project labels

`scripts/ensure_labels.sh` (called once per tick by the dispatcher) ensures these workflow labels exist:

**Work-state labels (mutually exclusive):**
- `todo`
- `retry`
- `new`
- `continue` — **human-applied review label.** Reviewers set this on an issue whose MR was created and the agent applied `pr`, but where the actual Claude Code run did not finish (env failure, partial edits, etc.). The agent never sets `continue` itself — only humans do. When the dispatcher's reconciliation sees `continue`, it re-enqueues the IID and prepares the next attempt's repo checkout from the existing work branch (continue mode). **Reviewer contract** — including how to leave supplemental steps as an issue comment so the agent can pick them up — is documented in `continue_mode.md`.
- `doing`
- `done` — **transient only.** Applied by the subagent in Step 6 after Wiki evidence publication and before MR creation. Removed by Step 8 when `pr` is added. `done` and `pr` are never present simultaneously in steady state.
- `pr` — **stable completion label.** Applied by the subagent in Step 8 immediately after `create_mr.sh` succeeds; replaces `done` (which is removed in the same operation). An issue carrying `pr` is considered complete by the dispatcher.
- `blocked-cc` — subagent/CC-side retryable failure (acpx non-timeout failure, NO_CHANGES, push rejected, post-push steps failed). Partial work may be pushed to `${WORK_BRANCH}` but no MR / `pr` is opened.
- `blocked-dispatcher` — dispatcher-synthesized retryable failure: prep failed, launch failed after retry exhaustion, scope/stuck eviction, unparseable reply downgrade, or label-sync failure downgrade. No CC run produced output.
- `failed-cc` — `blocked-cc` promoted after `retry_count > blocked_retry_limit`. Terminal until human relabel.
- `failed-dispatcher` — `blocked-dispatcher` promoted after `retry_count > blocked_retry_limit`. Terminal until human relabel.
- `timeout` — **subagent-applied terminal label.** Set when `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`, default 18000s). Whatever Claude Code produced before the kill is still committed and force-pushed to `${WORK_BRANCH}`, but no MR / `pr` is opened. The dispatcher treats `timeout` as terminal: the IID is parked in `timeout_iids`, `retry_count` is NOT consumed, and the IID is NOT auto-retried on later ticks. Reviewers re-run the issue by stripping the `timeout` label, by adding `retry` on top of `timeout` for a fresh reset, or by applying `continue` for a continue-mode resume on the existing branch.

**Note:** the single `blocked` and `failed` labels are **not created** by `ensure_labels.sh` (they are superseded by `blocked-cc`/`blocked-dispatcher` and `failed-cc`/`failed-dispatcher`). `reconcile.sh` and `set_issue_label.sh` retain backward-compatible recognition of any residual single `blocked`/`failed` labels that may exist from earlier deployments, but the agent never creates them.

**Orthogonal: model-tier labels** (one per `model_tiers` entry, created by `ensure_labels.sh` when `model_tiers` is configured):
- `model:<tier>` — e.g. `model:flash`, `model:pro`, `model:max`. Persistent, monotonically increasing per issue. Mutually exclusive within this dimension only. See §Model tier and quality dimensions below.

**Orthogonal: quality signal** (created by `ensure_labels.sh`):
- `quality:low` — one-shot human signal applied during review; consumed by `resolve_model_tier` as a soft model-upgrade trigger and removed after the upgrade is applied.

`contiune` is tolerated as a legacy/misspelled alias for `continue` during reconciliation and removal, but the agent does not create that label.

When the scheduled trigger supplies `require_labels`, those labels are also treated as one-shot entry labels for the matched issue on that tick: if a required label is present on the issue selected for execution, the dispatcher removes it while transitioning the issue to `doing`.

## Transition diagram

```
                          ┌────────────────────────────────────────────────┐
                          │                                                │
                          ▼                                                │
   todo/retry/new/continue/blocked-cc/blocked-dispatcher/trigger-label
             ──► doing ──► done (transient) ──► pr                        │
                │                                                          │
                ├──► blocked-cc   ──► doing  (after cooldown)  ────────────┘
                │      │
                │      └──► failed-cc   (retry_count > limit; terminal)
                │
                ├──► blocked-dispatcher ──► doing (after cooldown) ─────────┘
                │      │
                │      └──► failed-dispatcher  (retry_count > limit; terminal)
                │
                └──► timeout   (acpx exceeded wall-clock cap; partial work force-pushed to
                                ${WORK_BRANCH}; NO MR; terminal until human strips timeout
                                or applies retry/continue; retry_count NOT consumed)

   pr ──► continue  (HUMAN review action; agent never does this)
         │
         ▼
       doing       (executor in continue mode, on next tick)
         │
         ▼
       done (transient) ──► pr   (or blocked-cc / blocked-dispatcher / timeout as usual)

Note: `done` is a transient intermediate label only. The subagent applies it in Step 6 and
removes it in Step 8 when `pr` is added. `done` and `pr` never coexist in steady state.
```

## Concrete transitions and how to perform them

All transitions use targeted add/remove calls through `scripts/set_issue_label.sh` so that unrelated non-workflow labels on the issue are preserved. The script enforces workflow-label exclusivity when adding a workflow label: it removes conflicting workflow labels in the same GitLab issue update, leaving only the target label except for the allowed transient pairs `done + blocked-cc` and `done + blocked-dispatcher` (failure after Step 6 but before Step 8).

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked-cc` / `blocked-dispatcher` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep in fresh mode | remove `todo`, `retry`, `new`, `continue`, `contiune`, `blocked-cc`, `blocked-dispatcher`, `done`, `pr`, `failed-cc`, `failed-dispatcher`, `timeout`, and every matched trigger `require_labels` label; add `doing` |
| `continue` / `contiune` | `doing` | dispatcher | dispatcher begins prep in continue mode | remove `todo`, `continue`, `contiune`, `retry`, `new`, `blocked-cc`, `blocked-dispatcher`, `done`, `pr`, `failed-cc`, `failed-dispatcher`, `timeout`, and every matched trigger `require_labels` label; add `doing` |
| `doing`    | `done`     | subagent   | branch pushed, post-push verification passed, attempt artifacts published to the project Wiki and linked from the issue (Step 6) | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done`     |
| `done`     | `pr`       | subagent   | immediately after MR creation / rotation succeeds (Step 8) — `done` is removed and `pr` is added in its place | `set_issue_label.sh add pr` (which also removes `done`); result: `pr` only, `done` absent |
| `doing`    | `blocked-cc`  | subagent   | CC-side retryable failure during this run (acpx non-timeout failure, NO_CHANGES, push rejected, post-push steps failed); for acpx failures, committable partial work is first staged, committed, and force-pushed to `${WORK_BRANCH}` when possible, but no MR / `pr` is opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-cc`  |
| `doing`    | `blocked-dispatcher` | dispatcher | dispatcher-synthesized retryable failure (prep failed, launch failed after retry exhaustion, scope/stuck eviction, unparseable reply downgrade, label-sync failure downgrade); no CC run output | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-dispatcher` |
| `doing`    | `timeout`  | subagent   | `acpx claude exec` exceeded its wall-clock cap; partial work was committed and force-pushed to `${WORK_BRANCH}` but NO MR / `pr` was opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add timeout`  |
| `done`     | `done+blocked-cc` | subagent | CC-side retryable failure after Wiki evidence and `done` (Step 6), before `pr` can be added (Step 8) | `set_issue_label.sh add blocked-cc`; do NOT add `pr`                  |
| `done`     | `done+blocked-dispatcher` | dispatcher | dispatcher-side label-sync failure after `done` (Step 6), before `pr` can be added | `set_issue_label.sh add blocked-dispatcher`; do NOT add `pr`          |
| `blocked-cc`  | `doing`    | dispatcher | retry begins on a later tick after cooldown | `set_issue_label.sh remove blocked-cc` ; `set_issue_label.sh add doing`  |
| `blocked-dispatcher` | `doing` | dispatcher | retry begins on a later tick after cooldown | `set_issue_label.sh remove blocked-dispatcher` ; `set_issue_label.sh add doing` |
| `blocked-cc`  | `failed-cc`   | dispatcher | `retry_count > blocked_retry_limit` during Phase 6; launch-side `sessions_spawn` failures do not increment `retry_count` | `set_issue_label.sh remove blocked-cc` ; `set_issue_label.sh add failed-cc` |
| `blocked-dispatcher` | `failed-dispatcher` | dispatcher | `retry_count > blocked_retry_limit` during Phase 6 | `set_issue_label.sh remove blocked-dispatcher` ; `set_issue_label.sh add failed-dispatcher` |
| `timeout`  | `doing`    | dispatcher | a human reviewer stripped the `timeout` label, added `retry` on top of `timeout`, or applied `continue` — the dispatcher then treats it like any other unfinished entry | normal `*` → `doing` transition above |
| `pr`       | `continue` | **human reviewer** | reviewer notices the prior run was incomplete and wants the agent to re-run on the existing branch | manual on the GitLab UI; the agent does NOT make this transition itself |

## Important rules

1. **`pr` replaces `done`, not adds to it.** `done` is a transient intermediate label applied by the subagent in Step 6 after Wiki evidence publication. `pr` is applied in Step 8 after MR creation and removes `done` in the same operation. `done` and `pr` MUST NOT coexist in steady state — an issue in the `pr` state no longer carries `done`.
2. **Attempt evidence comes first.** Before `create_mr.sh` runs and before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Dispatcher completion requires `pr` (not `done`).** `done` is transient and will be removed. Reconciliation considers an issue complete when the `pr` label is present (and `continue` is absent). `done` alone is NOT a completion signal.
4. **Never call `glab mr merge`.** The merge request stays open for human review.
5. **No full-set label overwrite.** Always use targeted add/remove operations through `set_issue_label.sh` (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, model tier, quality, etc.) the user may have added.
6. **Workflow-label exclusivity.** Aside from the transient pairs `done + blocked-cc` and `done + blocked-dispatcher`, an issue should carry at most one work-state label at a time. `set_issue_label.sh add <workflow-label>` removes conflicting workflow labels automatically. `model:{tier}` labels are orthogonal and are NOT removed when a work-state label is added (see §Model tier and quality dimensions below).
7. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
8. **Dispatcher final synchronization.** Phase 6 re-applies the terminal workflow labels from the compact reply as an idempotent safety net: `done` replies must end with `pr` only (no `done`); `blocked` (CC-side) replies must end with `blocked-cc` and no `doing`; `blocked` (dispatcher-side) must end with `blocked-dispatcher` and no `doing`; promoted `failed-cc` replies must end with `failed-cc` and no `blocked-cc` / `doing`; `failed-dispatcher` must end with `failed-dispatcher` and no `blocked-dispatcher` / `doing`; and `timeout` replies must end with `timeout` and no `doing` / `blocked-cc` / `blocked-dispatcher` / `failed-cc` / `failed-dispatcher`.
9. **`timeout` is never auto-retried.** Unlike `blocked-cc` / `blocked-dispatcher`, a `timeout` IID stays in `timeout_iids` until a human reviewer strips the label, adds `retry`, or applies `continue`. Stripping `timeout` or adding `retry` re-enqueues via the regular `user_reopened` path and runs a fresh reset; `continue` resumes from the existing `${WORK_BRANCH}` (the partial work is already pushed there) while refreshing shared config paths from latest `origin/${DEV_BRANCH}`. The agent does NOT promote `timeout` to `failed`; `retry_count` is NOT consumed.

## Issue closure vs `done` / `pr` labels

These are distinct signals. The agent controls `done` (transient) and `pr` (stable); GitLab controls issue closure.

| Signal              | Who sets it                         | When                                              | Means                                  |
| ------------------- | ----------------------------------- | ------------------------------------------------- | -------------------------------------- |
| `done` label        | the subagent (Step 6)               | immediately after attempt evidence Wiki publication, before MR creation / rotation | transient: "agent finished solving and published evidence; MR creation in progress" |
| `pr` label          | the subagent (Step 8)               | immediately after `create_mr.sh` returns successfully; simultaneously removes `done` | stable: "the MR exists for human review; issue is complete from the agent's perspective" |
| issue closed (`state=closed`) | GitLab itself (native auto-close) | when the MR is merged                             | "a human reviewed, approved, and merged" |

GitLab's native auto-close is triggered by the **closing keyword in the MR description**. `scripts/create_mr.sh` writes the description starting with:

```
Closes #${ISSUE_IID}
```

When the MR merges, GitLab parses that line and closes the linked issue automatically. No agent action is required.

**Prerequisites on the GitLab project** (these are GitLab defaults; only worry about them if someone disabled them):

- Project → Settings → Merge requests → "Automatically close referenced merge requests" is enabled.
- The MR's target branch is the project's default branch (`master` in this workspace), which is the only case GitLab auto-closes for. Auto-close does NOT fire on MRs into non-default branches.

**The agent MUST NOT close the issue itself** (no `glab api ... --method PUT ... -f state_event=close`). Closing is the human reviewer's prerogative via the merge action; the subagent's job ends when `pr` is present.

**Approve vs merge.** GitLab's auto-close fires on **merge**, not approve. If your team uses "approve must precede merge", the practical effect is "issue closes after approve+merge", which is what you want. There is no agent-side support for "close on approve only" — that would require webhook plumbing outside this skill.

---

## Model tier and quality dimensions

These two dimensions are **orthogonal** to the work-state labels: they coexist with any work-state label and are never cleared when a work-state transition occurs (e.g. entering `doing` does NOT remove the current `model:{tier}` label).

### `model:{tier}` — persistent, monotonically increasing

When the trigger configures `model_tiers` (an ordered list of `{"tier","settings"}` objects), `ensure_labels.sh` creates the corresponding `model:<tier>` labels (e.g. `model:flash`, `model:pro`, `model:max`). These labels:

- Are **mutually exclusive within the `model:*` namespace** — exactly one `model:{tier}` is present on an issue at any time when `model_tiers` is configured.
- Are **persistent across all attempts** and follow the issue until it is `CLOSED`.
- Are **monotonically non-decreasing per issue** — `resolve_model_tier` only ever advances the tier, never lowers it.
- **Source of truth is GitLab**; `state.json.model_tier` is a cache, aligned by `reconcile.sh` each tick.

**`resolve_model_tier` — Phase 4, before entering `doing`:**

1. Read current tier: live `model:{tier}` GitLab label → `state.json.model_tier` cache → TIER_0 (lowest, default).
2. Evaluate `UPGRADE?`:
   - **Hard trigger:** previous attempt outcome (`state.json.status` + `state.json.block_side`) ∈ `{blocked-cc, timeout, failed-cc}` — CC-side failures.
   - **Soft trigger (any one):** `quality:low` label is present on the issue OR `state.json.continue_count >= campaign_state.continue_upgrade_threshold`.
   - **Excluded:** `blocked-dispatcher` / `failed-dispatcher` — dispatcher/infrastructure-side failures; model upgrade has no effect on infrastructure problems.
3. If `UPGRADE?` is true and current tier is not the highest → advance one tier. If already at the highest → stay. If `UPGRADE?` is false → keep current tier.
4. Write the `model:{tier}` label to GitLab (removing the prior tier label in the same operation). Update `state.json.model_tier`.
5. If the new tier has an associated settings file (`model_tiers[k].settings` relpath), inject it into the worktree (priority: `model_tiers` settings file > `claude_settings_path` trigger field > committed `.claude/settings.json`).
6. If `quality:low` was a trigger, remove it from the issue labels now (one-shot signal consumed).

When `model_tiers` is unconfigured (`null`), the entire `resolve_model_tier` flow is skipped and no `model:{tier}` label is written.

### `quality:low` — one-shot soft signal

Applied manually by a human reviewer during `AWAITING_REVIEW` (i.e. while the issue carries `pr`), to signal "this run's output quality was low — use a stronger model next time." The dispatcher's `resolve_model_tier` in Phase 4 reads this label as a soft upgrade trigger and removes it after the upgrade is applied. `quality:low` is never set by the agent itself. If no `model_tiers` is configured, `quality:low` is preserved on the issue but has no effect.
