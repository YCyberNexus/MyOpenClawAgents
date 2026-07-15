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
- `done` — **transient only.** Applied by the subagent in Step 5 after post-push verification and before MR creation. Removed by Step 7 when `pr` is added. `done` and `pr` are never present simultaneously in steady state.
- `pr` — **stable completion label.** Applied by the subagent in Step 7 immediately after `create_mr.sh` succeeds; replaces `done` (which is removed in the same operation). An issue carrying `pr` is considered complete by the dispatcher.
- `finish` — **stable merged-completion label.** The fixed outer executor first writes it atomically only after `merge_mr.sh` completes exact GET, SHA-fenced PUT, and exact GET and observes the matching server-side `state=merged`. Phase 6 then performs an independent bounded read-only verification before committing the durable terminal result or emitting a successful callback. `finish` and `pr` are mutually exclusive and both are dispatcher completion signals.
- `blocked-cc` — subagent/CC-side retryable failure (acpx non-timeout failure, NO_CHANGES, push rejected, post-push steps failed). Partial work may be pushed to `${WORK_BRANCH}` but no MR / `pr` is opened.
- `blocked-dispatcher` — dispatcher-synthesized retryable failure: prep failed, launch failed after retry exhaustion, scope/stuck eviction, unparseable reply downgrade, or label-sync failure downgrade. No CC run produced output.
- `failed-cc` — `blocked-cc` promoted after `retry_count > blocked_retry_limit`. Terminal until human relabel.
- `failed-dispatcher` — `blocked-dispatcher` promoted after `retry_count > blocked_retry_limit`. Terminal until human relabel.
- `timeout` — **subagent-applied terminal label.** Set when `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`, default 3600s; later attempts may use the executor-wide `/timeout-executor` value). Whatever Claude Code produced before the kill is still committed and force-pushed to `${WORK_BRANCH}`, but no MR / `pr` is opened. The dispatcher treats `timeout` as terminal: the IID is parked in `timeout_iids`, `retry_count` is NOT consumed, and the IID is NOT auto-retried on later ticks. Reviewers re-run the issue by stripping the `timeout` label, by adding `retry` on top of `timeout` for a fresh reset, or by applying `continue` for a continue-mode resume on the existing branch.

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
             ──► doing ──► done (transient) ──► pr (review)              │
                                      └──────► finish (verified merge)    │
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

Note: `done` is a transient intermediate label only. The subagent applies it in Step 5 and
removes it in Step 7 when `pr` is added. `done` and `pr` never coexist in steady state.
```

## Concrete transitions and how to perform them

All transitions use targeted add/remove calls through `scripts/set_issue_label.sh` so that unrelated non-workflow labels on the issue are preserved. The script enforces workflow-label exclusivity when adding a workflow label: it removes conflicting workflow labels in the same GitLab issue update, leaving only the target label except for the allowed transient pairs `done + blocked-cc` and `done + blocked-dispatcher` (failure after Step 5 but before Step 7).

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked-cc` / `blocked-dispatcher` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep in fresh mode | remove entry/failure/timeout labels and every matched trigger `require_labels` label, but preserve `pr`/`finish` unless the frozen request has `force_rerun_pr=true`; a fresh live `pr`/`finish`/closed observation drains the attempt as skipped instead of adding `doing` |
| `continue` / `contiune` | `doing` | dispatcher | dispatcher begins prep in continue mode | remove `todo`, `continue`, `contiune`, `retry`, `new`, `blocked-cc`, `blocked-dispatcher`, `done`, `pr`, `finish`, `failed-cc`, `failed-dispatcher`, `timeout`, and every matched trigger `require_labels` label; add `doing` |
| `doing`    | `done`     | subagent   | branch pushed and post-push verification passed (Step 5) | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done`     |
| `done`     | `pr`       | subagent   | immediately after MR creation / rotation succeeds (Step 7) — `done` is removed and `pr` is added in its place | `set_issue_label.sh add pr` (which also removes `done`); result: `pr` only, `done` absent |
| `done`     | `finish`   | fixed outer executor | automatic merge was explicitly requested; `merge_mr.sh` exact GET / SHA-fenced PUT / exact GET observed the matching MR merged at the committed SHA | one atomic `set_issue_label.sh add finish` update removes conflicting `pr`/`done`; Phase 6 later independently re-verifies before terminal persistence and callback |
| `doing`    | `blocked-cc`  | subagent   | CC-side retryable failure during this run (acpx non-timeout failure, NO_CHANGES, push rejected, post-push steps failed); for acpx failures, committable partial work is first staged, committed, and force-pushed to `${WORK_BRANCH}` when possible, but no MR / `pr` is opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-cc`  |
| `doing`    | `blocked-dispatcher` | dispatcher | dispatcher-synthesized retryable failure (prep failed, launch failed after retry exhaustion, scope/stuck eviction, unparseable reply downgrade, label-sync failure downgrade); no CC run output | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-dispatcher` |
| `doing`    | `timeout`  | subagent   | `acpx claude exec` exceeded its wall-clock cap; partial work was committed and force-pushed to `${WORK_BRANCH}` but NO MR / `pr` was opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add timeout`  |
| `done`     | `done+blocked-cc` | subagent | CC-side retryable failure after `done` (Step 5), before `pr` can be added (Step 7) | `set_issue_label.sh add blocked-cc`; do NOT add `pr`                  |
| `done`     | `done+blocked-dispatcher` | dispatcher | dispatcher-side label-sync failure after `done` (Step 5), before `pr` can be added | `set_issue_label.sh add blocked-dispatcher`; do NOT add `pr`          |
| `blocked-cc`  | `doing`    | dispatcher | retry begins on a later tick after cooldown | `set_issue_label.sh remove blocked-cc` ; `set_issue_label.sh add doing`  |
| `blocked-dispatcher` | `doing` | dispatcher | retry begins on a later tick after cooldown | `set_issue_label.sh remove blocked-dispatcher` ; `set_issue_label.sh add doing` |
| `blocked-cc`  | `failed-cc`   | dispatcher | `retry_count > blocked_retry_limit` during Phase 6; launch-side `sessions_spawn` failures do not increment `retry_count` | `set_issue_label.sh remove blocked-cc` ; `set_issue_label.sh add failed-cc` |
| `blocked-dispatcher` | `failed-dispatcher` | dispatcher | `retry_count > blocked_retry_limit` during Phase 6 | `set_issue_label.sh remove blocked-dispatcher` ; `set_issue_label.sh add failed-dispatcher` |
| `timeout`  | `doing`    | dispatcher | a human reviewer stripped the `timeout` label, added `retry` on top of `timeout`, or applied `continue` — the dispatcher then treats it like any other unfinished entry | normal `*` → `doing` transition above |
| `pr`       | `continue` | **human reviewer** | reviewer notices the prior run was incomplete and wants the agent to re-run on the existing branch | manual on the GitLab UI; the agent does NOT make this transition itself |

## Important rules

1. **`pr` or `finish` replaces `done`.** `done` is transient. Ordinary MR creation ends at `pr`; the fixed outer executor writes `finish` only after its exact server-side GET/PUT/GET verification. `pr`, `finish`, and `done` do not coexist in steady state.
2. **No attempt Wiki evidence.** req_executor must not publish `prompt.txt`, `claude_result.txt`, or `report.html` to project Wiki pages. `scripts/upload_attempt_artifacts.sh` is kept only as a no-op compatibility shim for already-rendered legacy prompts.
3. **Dispatcher completion requires `pr`, `finish`, or closed state (not `done`).** `done` alone is NOT a completion signal. `open_unfinished` excludes both stable labels.
4. **Automatic merge is explicit and fail-closed.** The fixed executor may call the exact MR REST merge endpoint only when `auto_merge=true`, with the expected source SHA. Its exact pre-GET, SHA-fenced PUT, and exact post-GET must observe the matching MR merged before the wrapper atomically writes `finish`. Phase 6 subsequently performs a separate bounded read-only verification before terminal state persistence and callback emission; it does not postpone the first `finish` write. A marker or callback alone never authorizes `finish` or a successful terminal callback. An opened MR stays at `pr`; an unknown state preserves existing labels. Direct free-form `glab mr merge` remains forbidden.
5. **No full-set label overwrite.** Always use targeted add/remove operations through `set_issue_label.sh` (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, model tier, quality, etc.) the user may have added.
6. **Workflow-label exclusivity.** Aside from the transient pairs `done + blocked-cc` and `done + blocked-dispatcher`, an issue should carry at most one work-state label at a time. `set_issue_label.sh add <workflow-label>` removes conflicting workflow labels automatically. `model:{tier}` labels are orthogonal and are NOT removed when a work-state label is added (see §Model tier and quality dimensions below).
7. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
8. **Dispatcher final synchronization.** Phase 6 independently re-verifies requested automatic merges after the fixed outer executor may already have written `finish`: exact merged state preserves or idempotently synchronizes `finish` and permits terminal success; exact opened state keeps `pr` and reports failure; unknown state preserves labels and cannot produce a successful callback. Ordinary `done` replies end with `pr`. Blocked, failed, and timeout synchronization otherwise follows the existing side-specific labels.
9. **Preparation rechecks stable completion at the mutation boundary.** Reconcile evidence is only a snapshot. Before transition, the dispatcher reads the live Issue again; `set_issue_label.sh add doing` also refuses to overwrite a newly arrived `pr`, `finish`, or closed state. Unless `continue` or `force_rerun_pr=true` explicitly authorizes a rerun, such a race drains the pending placeholder as completed/skipped and never starts an executor attempt.
9. **`timeout` is never auto-retried.** Unlike `blocked-cc` / `blocked-dispatcher`, a `timeout` IID stays in `timeout_iids` until a human reviewer strips the label, adds `retry`, or applies `continue`. Stripping `timeout` or adding `retry` re-enqueues via the regular `user_reopened` path and runs a fresh reset; `continue` resumes from the existing `${WORK_BRANCH}` when available. The agent does NOT promote `timeout` to `failed`; `retry_count` is NOT consumed.

## Issue closure vs `done` / `pr` / `finish` labels

These are distinct signals. The agent controls `done` (transient), `pr` (stable review completion), and server-verified `finish`; GitLab controls issue closure.

| Signal              | Who sets it                         | When                                              | Means                                  |
| ------------------- | ----------------------------------- | ------------------------------------------------- | -------------------------------------- |
| `done` label        | the subagent (Step 5)               | immediately after post-push verification, before MR creation / rotation | transient: "agent finished solving; MR creation in progress" |
| `pr` label          | the subagent (Step 7)               | immediately after `create_mr.sh` returns successfully; simultaneously removes `done` | stable: "the MR exists for human review; issue is complete from the agent's perspective" |
| `finish` label      | fixed outer executor; Phase 6 later re-verifies | first written atomically after exact GET / SHA-fenced PUT / exact GET observes the matching MR merged; independently checked again before terminal persistence/callback | stable: "the requested automatic merge completed" |
| issue closed (`state=closed`) | GitLab itself (native auto-close) | when the MR is merged                             | "the linked MR was merged" |

GitLab's native auto-close is triggered by the **closing keyword in the MR description**. `scripts/create_mr.sh` writes the description starting with:

```
Closes #${ISSUE_IID}
```

When the MR merges, GitLab parses that line and closes the linked issue automatically. No agent action is required.

**Prerequisites on the GitLab project** (these are GitLab defaults; only worry about them if someone disabled them):

- Project → Settings → Merge requests → "Automatically close referenced merge requests" is enabled.
- The MR's target branch must match the branch where GitLab auto-close behavior is expected. Auto-close does not fire on unrelated target branches.

**The agent MUST NOT close the issue itself** (no `glab api ... --method PUT ... -f state_event=close`). GitLab closes it through the MR merge, whether that merge is a human review action or an explicitly requested and server-verified automatic merge.

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
