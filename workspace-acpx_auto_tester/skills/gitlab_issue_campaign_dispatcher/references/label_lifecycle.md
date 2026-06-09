# Label Lifecycle (v2)

This document is the workspace-wide reference for issue workflow labels. Both halves of the agent (the dispatcher's prep, and the subagent's post-acpx flow) follow these transitions.

## Label dimensions

v2 splits the issue's labels into three independent dimensions.

### 1. Workflow state (mutually exclusive — exactly one at a time)

`scripts/ensure_labels.sh` (called once per tick by the dispatcher) ensures these workflow labels exist:

- entry: `todo` / `new` / `retry` / `continue`
- in progress: `doing`
- produced (transient, pre-MR): `done`
- awaiting review: `pr` — created after the MR exists; **replaces** `done`
- exception (Claude-Code side): `blocked-cc` / `failed-cc`
- exception (dispatcher side): `blocked-dispatcher` / `failed-dispatcher`
- exception (acpx wall-clock cap): `timeout`

The single v1 `blocked` and `failed` labels are **removed** from the vocabulary and replaced by the per-side variants. `ensure_labels.sh` only creates missing labels and never deletes existing ones, so historical `blocked` / `failed` labels left over from a v1 deployment are not cleaned up automatically — that is acceptable and no historical migration is performed.

`pr` REPLACES `done` (it is no longer additive): after MR creation the issue carries `pr` and not `done`. The only allowed transient pair is `done` + `blocked-cc` or `done` + `blocked-dispatcher` (a failure after `done` but before the MR / `pr`).

`continue` — **human-applied review label.** Reviewers set this on an issue whose MR was created and labeled `pr` by the agent, but where the actual Claude Code run did not finish (env failure, partial edits, etc.). The agent never sets `continue` itself — only humans do. When the dispatcher's reconciliation sees `continue`, it re-enqueues the IID and prepares the next attempt's repo checkout from the existing work branch (continue mode). **Reviewer contract** — including how to leave supplemental steps as an issue comment so the agent can pick them up — is documented in `continue_mode.md`. `contiune` is tolerated as a legacy/misspelled alias during reconciliation and removal, but the agent does not create that label.

`timeout` — **subagent-applied terminal label.** Set when `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`, default 18000s). Whatever Claude Code produced before the kill is still committed and force-pushed to `${WORK_BRANCH}`, but no MR / `pr` is opened. The dispatcher treats `timeout` as terminal: the IID is parked in `timeout_iids`, `retry_count` is NOT consumed, the IID is NOT auto-retried on later ticks, and `timeout` is **never** promoted to a `failed-*` variant. Reviewers re-run the issue by stripping `timeout`, by adding `retry` on top of `timeout` for a fresh reset, or by applying `continue` for a continue-mode resume on the existing branch.

When the scheduled trigger supplies `require_labels`, those labels are also treated as one-shot entry labels for the matched issue on that tick: if a required label is present on the issue selected for execution, the dispatcher removes it while transitioning the issue to `doing`.

### 2. Model tier (persistent, orthogonal — at most one at a time)

`model:flash` (TIER_0, lowest / default) → `model:pro` (TIER_1) → `model:max` (TIER_2, cap). The number of tiers equals the length of the trigger-configurable ordered `model_tiers` list (3 tiers is the example here). This dimension is **not** part of the workflow mutual-exclusion group: it survives the transition into `doing` and follows the issue monotonically (never downgraded) for its whole life until the issue is CLOSED. `ensure_labels.sh` creates the three default tiers with a distinct color so they stand out from the workflow state.

The model dimension is internally mutually exclusive: `set_issue_label.sh add model:pro` removes `model:flash` / `model:max` in the same GitLab update but touches no workflow label and no `quality:low`.

### 3. Quality signal (one-shot)

`quality:low` — a human-applied soft signal added in AWAITING_REVIEW to mark a mediocre round. It triggers a single model upgrade and is then removed (consumed) by the dispatcher in PREPARE. Adding or removing it touches nothing else.

### 4. Dispatcher precheck gate (tick-level, non-workflow)

`precheck-failed` — applied by the **dispatcher** (`dispatch_prepare_tick.sh` §16b) to a tick's batch IIDs when the environment precheck fails a `required` check, or the manifest is malformed; the whole tick then aborts. It is NOT a workflow state and NOT part of the mutual-exclusion group: `set_issue_label.sh add precheck-failed` produces no conflicts, so it coexists with whatever workflow label the issue already carries. It does **not** consume `retry_count` and does **not** upgrade the model tier (it is neither in `resolve_model_tier`'s hard set `{ blocked-cc, timeout, failed-cc }` nor a soft trigger). `ensure_labels.sh` creates it with a distinct red color. It is cleared when the issue next enters `doing` (it is in the dispatcher's into-`doing` `REMOVE_LBLS` set) — reaching `doing` means that tick's precheck passed, so the marker is stale. Only the dispatcher sets/clears it; the subagent never touches it. Manifest contract: [`precheck_manifest.md`](precheck_manifest.md).

## Workflow mutual-exclusion group and the "进 doing 清除集"

The workflow mutual-exclusion group is:

```
{ todo, new, retry, continue, doing, done, pr,
  blocked-cc, blocked-dispatcher, timeout, failed-cc, failed-dispatcher }
```

Adding any one workflow label removes the others in the same GitLab issue update, except the allowed transient pair `done` + `blocked-cc` / `done` + `blocked-dispatcher`. `pr` keeps only itself (it replaces `done`).

The **"进 doing 清除集"** (the labels the dispatcher strips when transitioning an issue into `doing`) is the entire workflow group above. It **excludes** `model:{tier}` and `quality:low` — the model tier must persist into `doing` (it is part of the issue's identity for life), and `quality:low` is consumed separately by `resolve_model_tier` only when it actually drives an upgrade. Additionally, the non-workflow `precheck-failed` marker (dimension 4 above) is removed in this same into-`doing` step, even though it is not part of the mutual-exclusion group.

## Transition diagram

```
   todo/new/retry/continue/blocked-*/timeout/failed-*(reviewer-relabel)/trigger-label
             ──► doing ──► done ──► pr            (pr replaces done)
                │
                ├──► blocked-cc          (CC-side retryable failure; acpx failures still
                │                          force-push committable partial work, no MR / pr)
                ├──► blocked-dispatcher  (dispatcher-side retryable failure: prep / spawn /
                │                          eviction; no CC output)
                └──► timeout             (acpx wall-clock cap; partial work force-pushed;
                                          NO MR; terminal until human relabel)

  blocked-cc          ──► doing  (after cooldown, lowest priority) ──► …
  blocked-dispatcher  ──► doing  (same retry path)
        │
        ▼  (retry_count > blocked_retry_limit)
  failed-cc / failed-dispatcher   (terminal — same side as the blocked variant)

   pr ──► continue  (HUMAN review action; agent never does this)
        │
        ▼
      doing  (executor in continue mode, on next tick) ──► done ──► pr (or blocked-*/timeout)
```

## outcome → label mapping (Phase 6, after AUTO_RUNNING)

The subagent's compact reply still uses the side-agnostic `status` vocabulary (`done` / `no_changes` / `blocked` / `failed` / `timeout`). The dispatcher's Phase 6 maps reply-status + side onto an internal terminal state and the live label:

| outcome (source)                                                                 | reply.status | side | internal final_status | live label              |
| -------------------------------------------------------------------------------- | ------------ | ---- | --------------------- | ----------------------- |
| solved, MR created                                                               | `done`       | cc   | `done`                | `pr` (replaces `done`)  |
| acpx non-timeout failure / NO_CHANGES / push rejected / acpx post-step failure    | `blocked`    | cc   | `blocked_cc`          | `blocked-cc`            |
| prep failure / spawn launch failure / scope or stuck eviction                     | `blocked`    | disp | `blocked_dispatcher`  | `blocked-dispatcher`    |
| acpx exceeded wall-clock cap                                                      | `timeout`    | cc   | `timeout`             | `timeout`               |
| direct failed (rare; subagent prefers `blocked`)                                  | `failed`     | cc   | `failed_cc`           | `failed-cc`             |

The side is determined by who produced the reply: a real subagent callback is always CC-side (`block_side: "cc"`); a dispatcher-synthesized blocked reply (`phase6_synthesize_blocked`) is always dispatcher-side (`block_side: "dispatcher"`).

## retry over-limit promotion (per side)

- `blocked-cc` and `retry_count > blocked_retry_limit` → `failed-cc`
- `blocked-dispatcher` and `retry_count > blocked_retry_limit` → `failed-dispatcher`
- `timeout` does NOT participate: it never consumes `retry_count` (parked) and is never auto-promoted.

Launch-side synthesized blocked replies (`dispatch_record_spawn.sh STATUS=launch_failed`) do NOT increment `retry_count` and are not promoted on that tick.

## model upgrade (resolve_model_tier, evaluated in PREPARE before START CHILD)

`UPGRADE? = hard ∪ soft`:

- **hard**: the prior outcome that caused this re-schedule ∈ { `blocked-cc`, `timeout`, `failed-cc` }
- **soft** (any hit): `quality:low` present ∨ cumulative continue count ≥ N (trigger `model_upgrade_continue_threshold`, N=0 disables) ∨ auto-score < threshold (black-box; **NOT implemented** in this version — only a commented hook position)
- **excluded**: `blocked-dispatcher` / `failed-dispatcher` / `precheck-failed` (infrastructure / environment side; a higher model would not help — `precheck-failed` is in neither the hard set nor a soft trigger, so it already never upgrades)

Decision: hit and not capped → upgrade one tier (add the higher `model:{tier}`, remove the old one — model dimension is internally exclusive); hit but already at the cap → keep the cap; no hit → keep the current tier. A new issue with no `model:{tier}` label is treated as TIER_0; the first PREPARE explicitly stamps the lowest tier (`model:flash`). `quality:low` is removed (consumed) once an upgrade evaluation used it.

One-liner: CC-side outcomes { `blocked-cc`, `timeout`, `failed-cc` } upgrade one tier on the next run; dispatcher-side { `blocked-dispatcher`, `failed-dispatcher` } never upgrade.

## Concrete transitions and how to perform them

All transitions use targeted add/remove calls through `scripts/set_issue_label.sh` so that unrelated non-workflow labels on the issue are preserved. The script enforces both the workflow exclusivity and the model-dimension exclusivity automatically.

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked-cc` / `blocked-dispatcher` / `timeout` / `failed-*` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep in fresh mode | remove the entire workflow group (entry labels + done/pr + blocked-*/timeout/failed-* + matched trigger `require_labels`) plus the non-workflow `precheck-failed` marker; add `doing`; preserve `model:{tier}` and `quality:low` |
| `continue` / `contiune` | `doing` | dispatcher | dispatcher begins prep in continue mode | remove the workflow group (incl. continue/contiune); add `doing`; preserve `model:{tier}` |
| (any)      | `model:{tier}` | dispatcher | resolve_model_tier in PREPARE, after the `doing` transition | `set_issue_label.sh add model:<tier>` (removes the old model:* in the same update); on a soft-trigger upgrade also `remove quality:low` |
| `doing`    | `done`     | subagent   | branch pushed, post-push verified, Wiki artifacts published | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done`     |
| `done`     | `pr`       | subagent   | immediately after MR creation / rotation succeeds    | `set_issue_label.sh add pr` (removes `done` — pr replaces it)         |
| `doing`    | `blocked-cc` | subagent | CC-side retryable failure; committable partial work first force-pushed to `${WORK_BRANCH}` when possible, no MR / `pr` | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-cc` |
| `doing`    | `blocked-dispatcher` | dispatcher | prep / spawn / eviction failure (no CC output) | Phase 6 synthesizes the reply and syncs `blocked-dispatcher` |
| `doing`    | `timeout`  | subagent   | `acpx claude exec` exceeded its wall-clock cap; partial work force-pushed, NO MR / `pr` | `set_issue_label.sh remove doing` ; `set_issue_label.sh add timeout`  |
| `done`     | `done` + `blocked-cc` | subagent | CC-side failure after Wiki + `done`, before `pr` | `set_issue_label.sh add blocked-cc`; do NOT add `pr`                  |
| `blocked-cc` / `blocked-dispatcher` | `doing` | dispatcher | retry begins on a later tick after no non-blocked backlog or fresh candidates remain | normal `*` → `doing` transition above |
| `blocked-cc` | `failed-cc` | dispatcher | `retry_count > blocked_retry_limit` in Phase 6 (launch-side synths do not increment) | `set_issue_label.sh add failed-cc` |
| `blocked-dispatcher` | `failed-dispatcher` | dispatcher | same over-limit rule, dispatcher side | `set_issue_label.sh add failed-dispatcher` |
| (batch IID, any workflow state) | + `precheck-failed` | dispatcher | §16b environment precheck `required` failure or malformed manifest; whole tick aborts | best-effort `set_issue_label.sh add precheck-failed` on each batch IID (non-workflow add, coexists with the current label); no `retry_count` change, no tier upgrade |
| `precheck-failed` | (removed) | dispatcher | issue next enters `doing` (that tick's precheck passed) | included in the into-`doing` `REMOVE_LBLS` set |
| `timeout`  | `doing`    | dispatcher | a human stripped `timeout`, added `retry`, or applied `continue` | normal `*` → `doing` transition above |
| `pr`       | `continue` | **human reviewer** | reviewer wants the agent to re-run on the existing branch | manual on the GitLab UI; the agent never makes this transition itself |

## Important rules

1. **`pr` REPLACES `done`.** `done` is the pre-MR transient state ("solved and published Wiki evidence"); `pr` means the MR exists. After successful MR creation / rotation the issue carries ONLY `pr`. `{done, pr}` never coexist.
2. **Attempt evidence comes first.** Before `create_mr.sh` runs and before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Dispatcher completion requires `pr`.** Reconciliation treats an issue as complete when the live label set contains `pr` (or the issue is closed), unless `continue` is also present. `done` alone (pre-MR) is NOT terminal completion.
4. **Never call `glab mr merge`.** The merge request stays open for human review.
5. **No full-set label overwrite.** Always use targeted add/remove operations through `set_issue_label.sh` (E4/E5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, model:{tier}, etc.).
6. **Workflow-label exclusivity.** Aside from the `done` + `blocked-*` transient pair, an issue carries at most one workflow label at a time. `set_issue_label.sh add <workflow-label>` removes conflicting workflow labels automatically, so a missed explicit `remove` cannot leave a stale workflow label behind. The model:{tier} and quality:low dimensions are orthogonal and not affected.
7. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
8. **Dispatcher final synchronization.** Phase 6 re-applies the terminal workflow labels from the compact reply as an idempotent safety net: `done` replies end as `pr` (no `done`); `blocked-cc` / `blocked-dispatcher` replies end with that one variant and no `doing`; promoted `failed-cc` / `failed-dispatcher` replies end with that variant and no `blocked-*` / `doing`; `timeout` replies end with `timeout` and no `doing` / `blocked-*` / `failed-*`.
9. **`timeout` is never auto-retried.** Unlike `blocked-*`, a `timeout` IID stays in `timeout_iids` until a human strips the label, adds `retry`, or applies `continue`. Stripping `timeout` or adding `retry` re-enqueues via the regular `user_reopened` path and runs a fresh reset; `continue` resumes from the existing `${WORK_BRANCH}`. The agent does NOT promote `timeout` to `failed-*`; `retry_count` is NOT consumed.
10. **Model tier is monotone for life.** `resolve_model_tier` only ever raises the tier (or holds at the cap) and never lowers it. It is not cleared by any workflow transition. It is consulted from the live `model:{tier}` label (source of truth) plus the cached `model_tier` in `issue-<iid>/state.json`.

## Issue closure vs `pr` label

These are two SEPARATE signals. The agent only controls the first; the second is GitLab's job.

| Signal              | Who sets it                         | When                                              | Means                                  |
| ------------------- | ----------------------------------- | ------------------------------------------------- | -------------------------------------- |
| `pr` label          | the subagent                        | immediately after `create_mr.sh` returns successfully (replacing the transient `done`) | "the MR exists for human review" |
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
