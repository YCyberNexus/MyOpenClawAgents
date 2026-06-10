# Label Lifecycle

This document is the workspace-wide reference for issue workflow labels. Both halves of the agent (the dispatcher's prep, and the subagent's post-acpx flow) follow these transitions.

## Required project labels

`scripts/ensure_labels.sh` (called once per tick by the dispatcher) ensures these labels exist.

**Work labels** (mutually exclusive — exactly one at a time):

- `todo`
- `retry`
- `new`
- `doing`
- `done` — **transient produced state.** Set after Wiki evidence is published, before the MR is created. `done` is REPLACED by `pr` once the MR exists (they never coexist in steady state; the only allowed transient pair is `done` + `blocked-cc` / `done` + `blocked-dispatcher` — a failure after `done` but before `pr`).
- `pr` — set after MR creation; it REPLACES `done`. The completion signal is the `pr` label.
- `blocked-cc` — **CC-side retryable failure.** acpx non-timeout failure / `NO_CHANGES` / push rejected / a post-acpx step failed. Partial work is force-pushed to `${WORK_BRANCH}`. Promoted to `failed-cc` when `retry_count > blocked_retry_limit`.
- `blocked-dispatcher` — **dispatcher-side retryable failure.** Per-IID prep failure / `sessions_spawn` launch failure / scope eviction / stuck-pending (no callback). No CC output. Promoted to `failed-dispatcher` when `retry_count > blocked_retry_limit`.
- `timeout` — **subagent-applied terminal label.** Set when `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`, default 18000s). Whatever Claude Code produced before the kill is still committed and force-pushed to `${WORK_BRANCH}`, but no MR / `pr` is opened. The dispatcher treats `timeout` as terminal: the IID is parked in `timeout_iids`, `retry_count` is NOT consumed, and the IID is NOT auto-retried on later ticks. Reviewers re-run the issue by stripping the `timeout` label, by adding `retry` on top of `timeout` for a fresh reset, or by applying `continue` for a continue-mode resume on the existing branch.
- `failed-cc` — CC-side terminal failure (retry budget exhausted from `blocked-cc`, or a rare direct `failed`). Re-armable by a human.
- `failed-dispatcher` — dispatcher-side terminal failure (retry budget exhausted from `blocked-dispatcher`). Re-armable by a human.
- `continue` — **human-applied review label.** Reviewers set this on an issue whose MR was created and labeled `pr` by the agent, but where the actual Claude Code run did not finish (env failure, partial edits, etc.). The agent never sets `continue` itself — only humans do. When the dispatcher's reconciliation sees `continue`, it re-enqueues the IID and prepares the next attempt's repo checkout from the existing work branch (continue mode). **Reviewer contract** — including how to leave supplemental steps as an issue comment so the agent can pick them up — is documented in `continue_mode.md`.

The single `blocked` / `failed` labels from v1 are removed in v2 (replaced by the per-side variants above). `ensure_labels.sh` only creates missing labels and never deletes existing ones, so any historical `blocked` / `failed` labels on old issues are left untouched — acceptable, no history migration is required.

**Orthogonal model dimension** (persistent, internally mutually exclusive, NEVER cleared on entering `doing`):

- `model:flash` (TIER_0, the lowest/default), `model:pro` (TIER_1), `model:max` (TIER_2, capped). The tier list is trigger-configurable via `model_tiers` (3 tiers shown as the example). per-issue monotonic non-decreasing; a new issue has no `model:{tier}` (treated as TIER_0) and gets the lowest tier stamped on first PREPARE. Raised automatically by `resolve_model_tier` (§model upgrade below).

**One-shot soft signal:**

- `quality:low` — a human applies this in AWAITING_REVIEW to flag a mediocre attempt. It is one of the model-upgrade soft triggers and is removed once an upgrade it triggered has landed, or when the tier is already capped (it is NOT consumed on the very first model stamp — it then survives and drives the upgrade on the next PREPARE; single-tier ladders are the exception: the first stamp is already at cap, so it is consumed immediately).

**Dispatcher tick-level marker (non-workflow):**

- `precheck-failed` — applied by the **dispatcher** (`dispatch_prepare_tick.sh` §16b) to a tick's batch IIDs when the environment precheck fails a `required` check, or the manifest is malformed; the whole tick then aborts. It is NOT a workflow state and NOT part of the mutual-exclusion group: `set_issue_label.sh add precheck-failed` produces no conflicts, so it coexists with whatever workflow label the issue already carries. It does **not** consume `retry_count` and does **not** upgrade the model tier (it is neither in `resolve_model_tier`'s hard set `{ blocked-cc, timeout, failed-cc }` nor a soft trigger). `ensure_labels.sh` creates it with a distinct red color. It is cleared when the issue next enters `doing` (it is in the dispatcher's into-`doing` `REMOVE_LBLS` set) — reaching `doing` means that tick's precheck passed, so the marker is stale. Only the dispatcher sets/clears it; the subagent never touches it. Manifest contract: [`precheck_manifest.md`](precheck_manifest.md).

`contiune` is tolerated as a legacy/misspelled alias for `continue` during reconciliation and removal, but the agent does not create that label.

When the scheduled trigger supplies `require_labels`, those labels are also treated as one-shot entry labels for the matched issue on that tick: if a required label is present on the issue selected for execution, the dispatcher removes it while transitioning the issue to `doing`.

## Transition diagram

```
                     ┌──────────────────────────────────────┐
                     │                                      │
                     ▼                                      │
   todo/retry/new/continue/blocked-*/trigger-label
             ──► doing ──► done ──► pr  (pr REPLACES done)   │
                │                                           │
                ▼                                           │
              blocked-cc / blocked-dispatcher ──► doing  (after cooldown, and only after non-blocked candidates) ──┘
                │
                ▼
              failed-cc / failed-dispatcher   (retry exhausted; re-armable by a human)

  doing ──► blocked-cc          (CC-side retryable failure; acpx failures still force-push
                                 committable partial work to ${WORK_BRANCH} when possible,
                                 but do not open an MR / add pr)

  doing ──► blocked-dispatcher  (dispatcher-side prep / spawn / stuck failure; no CC output)

  doing ──► timeout   (acpx exceeded wall-clock cap; partial work force-pushed to ${WORK_BRANCH};
                       NO MR; terminal until a human strips timeout or applies retry/continue)

   pr ──► continue  (HUMAN review action, optionally with quality:low; agent never does this)
              │
              ▼
            doing      (executor in continue mode, on next tick)
              │
              ▼
            done ──► pr   (or blocked-cc / blocked-dispatcher / failed-* / timeout as usual)

  model:flash → model:pro → model:max   (orthogonal, persistent, single monotonic upgrade per
                                         CC-side re-arm; never cleared on entering doing)
```

## Concrete transitions and how to perform them

All transitions use targeted add/remove calls through `scripts/set_issue_label.sh` so that unrelated non-work labels on the issue are preserved. The script also enforces work-label exclusivity when adding a work label: it removes conflicting work labels in the same GitLab issue update, leaving only the target label except for the allowed `done` + `blocked-cc` / `done` + `blocked-dispatcher` transient pairs. `pr` REPLACES `done` (they never coexist). The orthogonal `model:{tier}` and `quality:low` labels are NEVER removed by a work-label transition.

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked-*` / `failed-*` / `timeout` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep in fresh mode | remove the entry labels (`todo`, `retry`, `new`, `continue`, `contiune`, `done`, `pr`, `timeout`, `blocked-cc`, `blocked-dispatcher`, `failed-cc`, `failed-dispatcher`, and every matched trigger `require_labels` label) and the non-workflow `precheck-failed` marker; add `doing`. `model:{tier}` / `quality:low` are NOT removed. |
| `continue` / `contiune` | `doing` | dispatcher | dispatcher begins prep in continue mode | remove the entry labels as above; add `doing` |
| `doing`    | `done`     | subagent   | branch pushed, post-push verification passed, attempt artifacts published to the project Wiki and linked from the issue | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done` (transient produced state) |
| `done`     | `pr`       | subagent   | immediately after MR creation / rotation succeeds    | `set_issue_label.sh add pr` (REPLACES `done`)                        |
| `doing`    | `blocked-cc` | subagent | CC-side retryable failure during this run; for acpx failures, committable partial work is first staged, committed, and force-pushed to `${WORK_BRANCH}` when possible, but no MR / `pr` is opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-cc` |
| `doing`    | `blocked-dispatcher` | dispatcher | dispatcher-side prep / `sessions_spawn` / scope eviction / stuck failure; no CC output | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-dispatcher` |
| `doing`    | `timeout`  | subagent   | `acpx claude exec` exceeded its wall-clock cap; partial work was committed and force-pushed to `${WORK_BRANCH}` but NO MR / `pr` was opened | `set_issue_label.sh remove doing` ; `set_issue_label.sh add timeout`  |
| `done`     | `done+blocked-cc` | subagent | CC-side retryable failure after Wiki evidence and `done`, before `pr` can be added | `set_issue_label.sh add blocked-cc`; do NOT add `pr`                  |
| `blocked-cc` / `blocked-dispatcher` | `doing` | dispatcher | retry begins on a later tick after no non-blocked backlog or fresh candidates remain | `set_issue_label.sh add doing` (clears the blocked-* label via exclusivity) |
| `blocked-cc`  | `failed-cc`  | dispatcher | `retry_count > blocked_retry_limit` during Phase 6; launch-side `sessions_spawn` failures do not increment `retry_count` | `set_issue_label.sh add failed-cc` |
| `blocked-dispatcher` | `failed-dispatcher` | dispatcher | `retry_count > blocked_retry_limit` during Phase 6 | `set_issue_label.sh add failed-dispatcher` |
| `timeout`  | `doing`    | dispatcher | a human reviewer stripped the `timeout` label, added `retry` on top of `timeout`, or applied `continue` — the dispatcher then treats it like any other unfinished entry | normal `*` → `doing` transition above |
| `pr`       | `continue` | **human reviewer** | reviewer notices the prior run was incomplete and wants the agent to re-run on the existing branch (optionally adding `quality:low`) | manual on the GitLab UI; the agent does NOT make this transition itself |
| `*` (any work label) | `model:{higher}` | dispatcher | `resolve_model_tier` in PREPARE: a CC-side re-arm (or soft trigger) raised the tier | `set_issue_label.sh add model:{higher}` (removes the prior `model:{tier}`, leaves all work labels) |
| (batch IID, any workflow state) | + `precheck-failed` | dispatcher | §16b environment precheck `required` failure or malformed manifest; whole tick aborts | best-effort `set_issue_label.sh add precheck-failed` on each batch IID (non-workflow add, coexists with the current label); no `retry_count` change, no tier upgrade |
| `precheck-failed` | (removed) | dispatcher | issue next enters `doing` (that tick's precheck passed) | included in the into-`doing` `REMOVE_LBLS` set |

## Important rules

1. **`pr` REPLACES `done`.** `done` is a transient produced state (Wiki evidence published, MR not yet created). After successful MR creation / rotation the subagent adds `pr`, which removes `done`; the completion signal is the `pr` label alone. `done` + `pr` never coexist.
2. **Attempt evidence comes first.** Before `create_mr.sh` runs and before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Dispatcher completion requires `pr`.** Reconciliation considers an issue complete when the `pr` label is present (or the issue is `closed`), unless `continue` is also present.
4. **Never call `glab mr merge`.** The merge request stays open for human review.
5. **No full-set label overwrite.** Always use targeted add/remove operations through `set_issue_label.sh` (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, etc.) the user may have added.
6. **Work-label exclusivity.** Aside from `done` + `blocked-cc` / `done` + `blocked-dispatcher`, an issue carries at most one work label at a time. `set_issue_label.sh add <work-label>` removes conflicting work labels automatically, so a missed explicit `remove` cannot leave `doing` + `blocked-cc` behind. `model:{tier}` and `quality:low` are orthogonal and are never touched by a work-label add.
7. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
8. **Dispatcher final synchronization.** Phase 6 re-applies the terminal work labels from the compact reply as an idempotent safety net: `done` replies must end with `pr` (not `done`); `blocked-cc` / `blocked-dispatcher` replies must end with that label and no `doing`; promoted `failed-cc` / `failed-dispatcher` replies must end with that label and no `blocked-*` / `doing`; and `timeout` replies must end with `timeout` and no `doing` / `blocked-*` / `failed-*`.
9. **`timeout` is never auto-retried.** Unlike `blocked-*`, a `timeout` IID stays in `timeout_iids` until a human reviewer strips the label, adds `retry`, or applies `continue`. Stripping `timeout` or adding `retry` re-enqueues via the regular `user_reopened` path and runs a fresh reset; `continue` resumes from the existing `${WORK_BRANCH}` (the partial work is already pushed there) while refreshing shared config paths from latest `origin/${DEV_BRANCH}`. The agent does NOT promote `timeout` to `failed-*`; `retry_count` is NOT consumed.
10. **Model upgrade (`resolve_model_tier`, §6 of statemachine.v2).** Evaluated in PREPARE, before the attempt starts. UPGRADE? = hard trigger (the prior-attempt outcome ∈ { `blocked-cc`, `timeout`, `failed-cc` }) ∪ soft trigger (`quality:low` present, or `continue` accumulation ≥ `model_upgrade_continue_threshold`, or an unimplemented auto-score placeholder). Dispatcher-side outcomes (`blocked-dispatcher` / `failed-dispatcher`) are excluded from the hard trigger — raising the model never helps an infrastructure failure; `precheck-failed` is in neither the hard set nor a soft trigger, so it never upgrades the tier either. The upgrade ladder and `MODEL` selection run on the EFFECTIVE tier list (`derive_effective_model_tiers`: the subset of `model_tiers` whose `<tier>-settings.json` exists in `model_settings_dir`, order preserved; unconfigured dir → the full list). On a hit below the cap the dispatcher adds the next `model:{tier}` (removing the prior one) and consumes any `quality:low`; at the cap it stays at `model:max` (any `quality:low` is still consumed). A brand-new issue resolves to TIER_0 and gets the lowest `model:{tier}` stamped on first PREPARE.

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
