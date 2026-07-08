# Label Lifecycle (v2)

This document is the workspace-wide reference for issue workflow labels. Both halves of the agent (the dispatcher's prep, and the subagent's post-acpx flow) follow these transitions.

## Label dimensions

v2 splits the issue's labels into three independent dimensions.

### 1. Workflow state (mutually exclusive — exactly one at a time)

`scripts/ensure_labels.sh` (called once per tick by the dispatcher) ensures these workflow labels exist:

- entry: `todo` / `new` / `retry`
- in progress: `doing`
- terminal success: `done`
- exception (Claude-Code side): `blocked-cc` / `failed-cc`
- exception (dispatcher side): `blocked-dispatcher` / `failed-dispatcher`
- exception (acpx wall-clock cap): `timeout`

The single v1 `blocked` and `failed` labels are **removed** from the vocabulary and replaced by the per-side variants. `ensure_labels.sh` only creates missing labels and never deletes existing ones, so historical `blocked` / `failed` labels left over from a v1 deployment are not cleaned up automatically — that is acceptable and no historical migration is performed.

`done` is the **terminal success** label. On the benchmark-test branch there is no MR and no `pr` label — `done` is NOT replaced by anything. The only allowed transient pair is `done` + `blocked-cc` or `done` + `blocked-dispatcher` (a CC-side failure after `done` was applied). GitLab-level completion is the issue being closed (a human closes it); there is no `pr`-based completion signal.

`continue` / resume is **disabled** on this branch. There is no `continue` (or legacy `contiune`) label handling: every attempt runs FRESH from `origin/${dev_branch}`. Reconciliation never re-enqueues an IID into continue mode and the dispatcher never checks out the existing work branch for resume.

`timeout` — **subagent-applied terminal label.** Set when `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`, default 18000s). Whatever Claude Code produced before the kill is still committed and pushed to `${LOCAL_ATTEMPT_BRANCH}`. The dispatcher treats `timeout` as terminal: the IID is parked in `timeout_iids`, `retry_count` is NOT consumed, the IID is NOT auto-retried on later ticks, and `timeout` is **never** promoted to a `failed-*` variant. Reviewers re-run the issue by stripping `timeout`, or by adding `retry` on top of `timeout` for a fresh reset.

When the scheduled trigger supplies `require_labels`, those labels are also treated as one-shot entry labels for the matched issue on that tick: if a required label is present on the issue selected for execution, the dispatcher removes it while transitioning the issue to `doing`.

### 2. Model tier (persistent, orthogonal — at most one at a time)

`model:flash` (TIER_0) / `model:pro` (TIER_1) / `model:max` (TIER_2). The number of tiers equals the length of the trigger-configurable ordered `model_tiers` list (3 tiers is the example here). This dimension is **not** part of the workflow mutual-exclusion group: it survives the transition into `doing` and follows the issue for its whole life until the issue is CLOSED. On the benchmark-test branch the tier is **pinned per tick** from the REQUIRED `pin_model_tier` trigger field — there is NO failure-escalation ladder and NO monotonic-raise invariant, so a pin MAY down-shift the issue from a higher prior tier. `ensure_labels.sh` creates the three default tiers with a distinct color so they stand out from the workflow state.

The model dimension is internally mutually exclusive: `set_issue_label.sh add model:pro` removes `model:flash` / `model:max` in the same GitLab update but touches no workflow label. Because the pin can down-shift, this mutual exclusion is exactly how `model:max` is cleared when a later tick pins `model:pro`.

### 3. Dispatcher precheck gate (tick-level, non-workflow)

`precheck-failed` — applied by the **dispatcher** (`dispatch_prepare_tick.sh` §16b) to a tick's batch IIDs when the environment precheck fails a `required` check, or the manifest is malformed; the whole tick then aborts. It is NOT a workflow state and NOT part of the mutual-exclusion group: `set_issue_label.sh add precheck-failed` produces no conflicts, so it coexists with whatever workflow label the issue already carries. It does **not** consume `retry_count` and does **not** change the model tier (the tier is pinned per tick from `pin_model_tier`, independent of any failure marker). `ensure_labels.sh` creates it with a distinct red color. It is cleared when the issue next enters `doing` (it is in the dispatcher's into-`doing` `REMOVE_LBLS` set) — reaching `doing` means that tick's precheck passed, so the marker is stale. Only the dispatcher sets/clears it; the subagent never touches it. Manifest contract: [`precheck_manifest.md`](precheck_manifest.md).

## Workflow mutual-exclusion group and the "进 doing 清除集"

The workflow mutual-exclusion group is:

```
{ todo, new, retry, doing, done,
  blocked-cc, blocked-dispatcher, timeout, failed-cc, failed-dispatcher }
```

Adding any one workflow label removes the others in the same GitLab issue update, except the allowed transient pair `done` + `blocked-cc` / `done` + `blocked-dispatcher`.

The **"进 doing 清除集"** (the labels the dispatcher strips when transitioning an issue into `doing`) is the entire workflow group above. It **excludes** `model:{tier}` — the model tier must persist into `doing` as part of the issue's identity (it is then re-stamped to the tick's pinned tier). Additionally, the non-workflow `precheck-failed` marker (dimension 3 above) is removed in this same into-`doing` step, even though it is not part of the mutual-exclusion group.

## Transition diagram

```
   todo/new/retry/blocked-*/timeout/failed-*(reviewer-relabel)/trigger-label
             ──► doing ──► done            (done is terminal success — no MR / pr)
                │
                ├──► blocked-cc          (CC-side retryable failure; acpx failures still
                │                          push committable partial work)
                ├──► blocked-dispatcher  (dispatcher-side retryable failure: prep / spawn /
                │                          eviction; no CC output)
                └──► timeout             (acpx wall-clock cap; partial work pushed;
                                          terminal until human relabel)

  blocked-cc          ──► doing  (after cooldown, lowest priority) ──► …
  blocked-dispatcher  ──► doing  (same retry path)
        │
        ▼  (retry_count > blocked_retry_limit)
  failed-cc / failed-dispatcher   (terminal — same side as the blocked variant)
```

## outcome → label mapping (Phase 6, after AUTO_RUNNING)

The subagent's compact reply still uses the side-agnostic `status` vocabulary (`done` / `no_changes` / `blocked` / `failed` / `timeout`). The dispatcher's Phase 6 maps reply-status + side onto an internal terminal state and the live label:

| outcome (source)                                                                 | reply.status | side | internal final_status | live label              |
| -------------------------------------------------------------------------------- | ------------ | ---- | --------------------- | ----------------------- |
| solved, work pushed                                                              | `done`       | cc   | `done`                | `done` (terminal)       |
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

## model tier pinning (evaluated in PREPARE before START CHILD)

On the benchmark-test branch the model tier is **pinned per tick** from the REQUIRED `pin_model_tier` trigger field — there is NO failure-escalation ladder (no hard/soft upgrade triggers) and NO monotonic-raise invariant. PREPARE stamps the issue exactly `model:<pin_model_tier>`, removing any other `model:*` in the same update (so the pin MAY down-shift a higher prior tier). A `pin_model_tier` value not in the effective tier set (the `<tier>-settings.json` actually present under `model_settings_dir`) marks that IID `blocked-dispatcher`. To sweep one issue across candidate models, trigger one tick per candidate model.

## Concrete transitions and how to perform them

All transitions use targeted add/remove calls through `scripts/set_issue_label.sh` so that unrelated non-workflow labels on the issue are preserved. The script enforces both the workflow exclusivity and the model-dimension exclusivity automatically.

| From       | To         | Performer  | Trigger                                              | Operations                                                            |
| ---------- | ---------- | ---------- | ---------------------------------------------------- | --------------------------------------------------------------------- |
| `todo` / `retry` / `new` / `blocked-cc` / `blocked-dispatcher` / `timeout` / `failed-*` / trigger `require_labels` | `doing` | dispatcher | dispatcher begins prep (always fresh mode) | remove the entire workflow group (entry labels + done + blocked-*/timeout/failed-* + matched trigger `require_labels`) plus the non-workflow `precheck-failed` marker; add `doing`; preserve `model:{tier}` |
| (any)      | `model:{tier}` | dispatcher | tier pinning in PREPARE, after the `doing` transition | `set_issue_label.sh add model:<pin_model_tier>` (removes the old model:* in the same update — the pin may down-shift) |
| `doing`    | `done`     | subagent   | branch pushed, post-push verified, Wiki artifacts published | `set_issue_label.sh remove doing` ; `set_issue_label.sh add done` (terminal success — no `pr`) |
| `doing`    | `blocked-cc` | subagent | CC-side retryable failure; committable partial work first pushed to `${LOCAL_ATTEMPT_BRANCH}` when possible | `set_issue_label.sh remove doing` ; `set_issue_label.sh add blocked-cc` |
| `doing`    | `blocked-dispatcher` | dispatcher | prep / spawn / eviction failure (no CC output) | Phase 6 synthesizes the reply and syncs `blocked-dispatcher` |
| `doing`    | `timeout`  | subagent   | `acpx claude exec` exceeded its wall-clock cap; partial work pushed | `set_issue_label.sh remove doing` ; `set_issue_label.sh add timeout`  |
| `done`     | `done` + `blocked-cc` | subagent | CC-side failure after Wiki + `done` | `set_issue_label.sh add blocked-cc`                  |
| `blocked-cc` / `blocked-dispatcher` | `doing` | dispatcher | retry begins on a later tick after no non-blocked backlog or fresh candidates remain | normal `*` → `doing` transition above |
| `blocked-cc` | `failed-cc` | dispatcher | `retry_count > blocked_retry_limit` in Phase 6 (launch-side synths do not increment) | `set_issue_label.sh add failed-cc` |
| `blocked-dispatcher` | `failed-dispatcher` | dispatcher | same over-limit rule, dispatcher side | `set_issue_label.sh add failed-dispatcher` |
| (batch IID, any workflow state) | + `precheck-failed` | dispatcher | §16b environment precheck `required` failure or malformed manifest; whole tick aborts | best-effort `set_issue_label.sh add precheck-failed` on each batch IID (non-workflow add, coexists with the current label); no `retry_count` change, no tier change |
| `precheck-failed` | (removed) | dispatcher | issue next enters `doing` (that tick's precheck passed) | included in the into-`doing` `REMOVE_LBLS` set |
| `timeout`  | `doing`    | dispatcher | a human stripped `timeout` or added `retry` | normal `*` → `doing` transition above |

## Important rules

1. **`done` is terminal success.** On the benchmark-test branch there is no MR and no `pr` label — `done` is the terminal success state and is never replaced. The only allowed transient pair is `done` + `blocked-cc` / `done` + `blocked-dispatcher`.
2. **Attempt evidence comes first.** Before the issue can be labeled `done`, `scripts/upload_attempt_artifacts.sh` MUST publish attempt-scoped Wiki pages for `prompt.txt`, `claude_result.txt`, and optional `report.html`, then link them from the issue.
3. **Dispatcher completion = issue closed.** Reconciliation treats an issue as complete when it is closed on GitLab (a human closes it). There is no `pr`-based completion signal; `done` is the agent's terminal success label but does not by itself close the issue.
4. **Never call `glab mr merge`.** MR creation is removed on this branch; the command is retired anyway.
5. **No full-set label overwrite.** Always use targeted add/remove operations through `set_issue_label.sh` (G4/G5 in `glab_commands.md`). A full overwrite via `labels=...` would wipe manually-applied labels (priority, severity, model:{tier}, etc.).
6. **Workflow-label exclusivity.** Aside from the `done` + `blocked-*` transient pair, an issue carries at most one workflow label at a time. `set_issue_label.sh add <workflow-label>` removes conflicting workflow labels automatically, so a missed explicit `remove` cannot leave a stale workflow label behind. The `model:{tier}` dimension is orthogonal and not affected.
7. **Idempotence.** Adding a label that already exists, or removing one that is absent, is a no-op — it is safe to issue these calls without checking first.
8. **Dispatcher final synchronization.** Phase 6 re-applies the terminal workflow labels from the compact reply as an idempotent safety net: `done` replies end as `done`; `blocked-cc` / `blocked-dispatcher` replies end with that one variant and no `doing`; promoted `failed-cc` / `failed-dispatcher` replies end with that variant and no `blocked-*` / `doing`; `timeout` replies end with `timeout` and no `doing` / `blocked-*` / `failed-*`.
9. **`timeout` is never auto-retried.** Unlike `blocked-*`, a `timeout` IID stays in `timeout_iids` until a human strips the label or adds `retry`. Stripping `timeout` or adding `retry` re-enqueues via the regular `user_reopened` path and runs a fresh reset. The agent does NOT promote `timeout` to `failed-*`; `retry_count` is NOT consumed.
10. **Model tier is pinned per tick.** PREPARE stamps the issue with `model:<pin_model_tier>` from the REQUIRED `pin_model_tier` trigger field — there is no monotonic-raise invariant, so the pin may down-shift a higher prior tier (the `model:*` mutual exclusion clears the others in the same update). It is consulted from the live `model:{tier}` label (source of truth) plus the cached `model_tier` in `issue-<iid>/state.json`.

## Issue completion

The agent's terminal success label is `done`; GitLab-level completion is the issue being **closed**, which is a human action.

| Signal              | Who sets it                         | When                                              | Means                                  |
| ------------------- | ----------------------------------- | ------------------------------------------------- | -------------------------------------- |
| `done` label        | the subagent                        | after the solved work is pushed and Wiki evidence published | "the agent finished this attempt successfully" |
| issue closed (`state=closed`) | a human reviewer | when the work is accepted                          | "a human reviewed and closed the issue" |

There is no MR and no auto-close on this branch. **The agent MUST NOT close the issue itself** (no `glab api ... --method PUT ... -f state_event=close`); closing is the human reviewer's prerogative, and the subagent's job ends when `done` is present.
