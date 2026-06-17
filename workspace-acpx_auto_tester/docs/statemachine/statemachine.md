> ⚠️ 已废弃 / 历史 v1。本文件描述早期语义（单一 `blocked`/`failed`、`done`+`pr` 共存、`continue` 重入队），已被取代。当前 benchmark-test 分支的权威状态机见 `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/label_lifecycle.md`（及 statemachine.v2.md §6）。请勿据本文件理解当前行为。

# Issue 全生命周期状态机

本文件是历史 v1 快照，描述早期标签生命周期与 dispatcher 算法（保留作历史记录，不反映当前 benchmark-test 行为）。

- **状态边界 = GitLab 上 issue 的可观察状态**（标签组合 + open/closed）。
- **状态内部的 entry/do/exit** = dispatcher 或 subagent 在该状态下执行的脚本/动作（note 标注执行者）。
- **转移边 `event[guard]/activity`** = 外部事件（人触发 / scheduler tick / runtime callback）+ 判定条件 + 转移时附带的副作用。
- **self-loop** 表达"事件来了但 guard 不满足只能空转"或"重试相同动作"。

## 图示

```mermaid
stateDiagram-v2
    direction TB
    [*] --> DRAFTING : user_clicks_New_Issue / open editor in browser

    DRAFTING : entry/ blank form
    DRAFTING : do/ user fills title and body locally
    DRAFTING : do/ user may attach files, paste logs, preview markdown

    DRAFTING --> [*]       : user_cancels / discard draft (no iid ever assigned)
    DRAFTING --> SUBMITTED : user_clicks_Submit / POST issue, iid assigned, state=opened

    SUBMITTED : entry/ open on GitLab with iid, no workflow label
    SUBMITTED : do/ user refines title or body via PATCH issue
    SUBMITTED : do/ user or reviewers may post notes and discuss

    SUBMITTED --> SUBMITTED : user_edits_body or user_posts_note / PATCH issue or POST note (no trigger label yet)
    SUBMITTED --> PENDING   : user_adds_label[label in todo, new, continue, retry] / -
    SUBMITTED --> CLOSED    : user_closes / -

    state PENDING {
        [*] --> Queued
        Queued : entry/ label in todo, new, continue, retry
        Queued : do/ wait for next scheduler tick
    }

    PENDING --> PENDING : tick[not can_dispatch] / reconcile, no-op
    PENDING --> DOING   : tick[can_dispatch] / reconcile + prep + spawn
    PENDING --> CLOSED  : user_closes

    state DOING {
        direction LR
        [*] --> PREPARING

        PREPARING : entry/ allocate_attempt.sh
        PREPARING : entry/ bind k-th UI account slot
        PREPARING : do/ prepare_attempt.sh (per-issue worktree)
        PREPARING : do/ build_prompt.sh
        PREPARING : do/ set_issue_label.sh sets doing
        PREPARING : exit/ write pending_subagents[iid] placeholder
        note left of PREPARING
            run by dispatcher
            any script non-zero exit means no inline retry
        end note

        PREPARING --> SPAWNING : prep_ok / -
        PREPARING --> [*]      : prep_failed / synth blocked, retry_count unchanged

        SPAWNING : entry/ sessions_spawn (anonymous, timeoutSeconds=30)
        SPAWNING : do/ wait launch ack (runId + childSessionKey)
        SPAWNING : exit/ record ack into pending_subagents[iid]
        note left of SPAWNING : run by dispatcher

        SPAWNING --> EXECUTING : launch_ack_ok / return waiting_for_callbacks
        SPAWNING --> SPAWNING  : launch_err[attempts lt 3] / wait 2s, retry same payload
        SPAWNING --> [*]       : launch_err[attempts eq 3] / synth blocked, retry_count unchanged

        EXECUTING : entry/ subagent Steps 0 to 4 (no SKILL, no state writes)
        EXECUTING : do/ run_acpx_attempt.sh (acpx claude exec)
        EXECUTING : do/ Claude Code generates spec in WORKTREE_DIR
        EXECUTING : exit/ stage_and_guard.sh + commit_and_push.sh (force-push)
        note right of EXECUTING
            run by subagent
            no direct acpx, no fallback LLM
        end note

        EXECUTING --> PUBLISHING : acpx_ok and push_ok / -
        EXECUTING --> [*]        : acpx_fail or push_rejected / FAIL blocked

        PUBLISHING : entry/ post_push_verify.sh
        PUBLISHING : do/ upload_attempt_artifacts.sh (wiki)
        PUBLISHING : do/ create_mr.sh (rotate)
        PUBLISHING : do/ set_issue_label.sh add pr
        PUBLISHING : do/ summarize_attempt.sh
        PUBLISHING : exit/ emit ONE compact JSON line
        note right of PUBLISHING
            run by subagent
            never glab mr merge, never close issue
        end note

        PUBLISHING --> [*] : terminal_emit / runtime triggers RUN_CHILD_COMPLETION_CALLBACK
    }

    DOING --> DOING   : tick[iid_active] / reconcile, no-op
    DOING --> DONE    : callback[done] / labels(done,pr)
    DOING --> BLOCKED : callback[blocked] / label(blocked), retry++
    DOING --> BLOCKED : tick[stuck] / evict, synth blocked
    DOING --> FAILED  : callback[failed] / label(failed)

    DONE : labels = done + pr, MR open, wait for reviewer

    DONE --> PENDING : add_label[continue] / re-enqueue, mode=continue
    DONE --> CLOSED  : human_merges_MR
    DONE --> CLOSED  : user_closes

    BLOCKED : label = blocked, retain LOG_DIR

    BLOCKED --> PENDING : add_label[retry or continue]
    BLOCKED --> FAILED  : tick[retry_count gt limit] / promote
    BLOCKED --> CLOSED  : user_closes

    FAILED : label = failed, never reschedule
    FAILED --> CLOSED : user_closes

    CLOSED : is_closed_on_gitlab, hard terminal skip
    CLOSED --> [*]
```

## 图里 guard / activity 的缩写

- `tick` = `scheduler_tick`，每次都先跑 `reconcile.sh` 并写 `reconcile-<ts>.json` 证据文件。
- `can_dispatch` = `reconcile_ok` ∧ `pending_subagents` 空 ∧ `batch_slot_free` ∧ `launch_quota_ok` ∧ `not iid_active`。
- `stuck` = `pending_subagents[iid]` 等待超过 `stuck_after_minutes`（默认 330 分钟）。
- `callback[*]` 三条共享的副作用：drain `pending_subagents[iid]` + 尽力 `subagents kill` 子会话；图里只写了状态特有的标签转移。
- DOING→DONE 时 GitLab 仍 open；要等人合并对应 MR 后，GitLab 通过 MR 描述里的 `Closes #<iid>` 自动把 issue 改为 closed。

## 唯一一条画不进图的约定

**GitLab 实时标签 = 状态的 source of truth；磁盘 `campaign_state.json` / `state.json` / `attempt_state.json` 只是 dispatcher 的进度缓存。**

它决定了图里所有 guard（`iid_active`、`retry_count > blocked_retry_limit`、`stuck` 等）该读哪份数据：缓存与 GitLab 冲突时永远以 GitLab 为准，靠每个 tick 强制跑 `reconcile.sh` 并写 `reconcile-<ts>.json` 证据文件兜底。**没有证据文件 = 这个 tick 直接判失败**。
