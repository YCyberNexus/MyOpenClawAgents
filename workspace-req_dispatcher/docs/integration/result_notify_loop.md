# 测试结果闭环回报（result notify loop）

> 状态：**待对齐 + 部分待实现（acpx 侧）**。本文件定义端到端把 `acpx_auto_tester` 的测试结果回报给"当初在企微发需求的那个人"的闭环。**`req_dispatcher` 全程不变**（仍纯透传，不追踪结果、不回状态）。

## 1. 目标

issue #N 被 acpx 处理到终态（`pr` 成功 / `failed-*` / `timeout`）后，通知**当初发起该需求的企微用户**，而不只是把 issue 建出来就断了。

> 词表提示：`pr` / `failed-*` / `timeout` 是 acpx **内部 GitLab 标签**（acpx 据此判终态）；对外回报的 req_result note 把它映射成 `status` ∈ `done` / `failed` / `timeout`（114 读的是这个，**不是**标签）。下文 §3/§5/§7 一致按 `status` 描述。

## 2. 为什么这条闭环不经过 req_dispatcher

- git_issuer 的回调 → req_dispatcher，是因为 req_dispatcher **spawn 了** git_issuer，要靠回调 drain 自己的 `pending[run_id]`（spawn/pending 记账）。
- **acpx 与 req_dispatcher 没有 spawn 关系**：req_dispatcher 从不调用 acpx，靠标签被动让 acpx 的 cron 捞起；该 issue 在 req_dispatcher 这边早已 drain，req_dispatcher 也不知道它对应哪个企微会话。
- 所以结果闭环**不可能也不应该**走 req_dispatcher（它保持极简）。**唯一能活到 acpx 阶段的载体是 issue 本身** → 发起人标识必须**落在 issue 上**。

## 3. 端到端流程

```
企微用户 → 114（转发需求，带上 origin 标识）
            → req_dispatcher（不变：整段透传，不解析 project 也不解析 origin）
            → git_issuer（解析 project + origin；建 issue；把 origin 写成隐藏标记 note）
            → GitLab issue #N（带 acpx 入口标签 + req_origin 标记 note）
            → acpx cron 捞起 → 跑测试 → 终态(pr/failed-*/timeout)
            → acpx 读 issue 的 req_origin 标记 → 通过 channel 通知该 origin
            → 114 接收 → 投递结果给那个企微用户
```

逐组件：

1. **114（发起侧）**：转发需求时带上发起人的 **origin 标识**（channel / user / conversation id）。由于 req_dispatcher 的接入是自由文本，114 把 origin 以一段**可被 git_issuer 稳定解析**的元数据放进文本（例如开头一行 `[origin] channel=<c> user=<u> conv=<id>`，或一个 fenced 元数据块）。
   - 若将来把接入契约升级为结构化 payload，则改用显式的 opaque `origin` 字段，**req_dispatcher 仍只透传**（见 [`trigger_command.md`](../../skills/requirement_dispatch/references/trigger_command.md) 的 payload 待对齐项）。
2. **req_dispatcher**：**不变**。整段透传给 git_issuer，既不解析 project 也不解析 origin。
3. **git_issuer（创建流程新增一步）**：从文本解析出 origin（和解析 project 一样）；建好 issue 后，把 origin 以**隐藏标记 note** 写到 issue 上（§4）。**不要写进 description**——description 是给 Claude Code 读的需求正文，混入元数据会污染它。
4. **acpx_auto_tester（新增能力，在 `workspace-acpx_auto_tester`）**：Phase 6 到达终态时，读 issue 的 `req_origin` 标记（acpx 本就用 `glab` 读 issue notes / G1b），把结果回报出去。
   - ⚠️ **事实纠正**：acpx **当前没有任何 notify 实现**（`SOUL.md`/`CLAUDE.md` 里的 "optional notify_channel" 只是字面提法，`scripts/` 里 grep `notify` 为空）。所以这是**从零新增**，不是"复用既有基建"。
   - **选定机制 = option A（发 `req_result` note + 114 轮询）**：acpx 在 issue 上用 G9 发一条结构化 note `<!-- req_result v1 {"iid":N,"status":"done|failed|timeout","attempt":K,"mr_url":...,"wiki_url":...,"reason":...,"ts":"...","origin":{...}} -->`，由 114 轮询/webhook 拿到再投递给企微用户。纯 glab、acpx 侧零待对齐、不依赖任何跨区 push 原语。完整字段以 §7（与 `post_result_note.sh` writer 同源）为准——`status` 是 note 自带的 `done|failed|timeout`，**不是** GitLab 标签 `pr`/`failed-*`。
   - **终态触发集**：acpx 的 `final_status ∈ {done, failed, timeout}` 才发（`done`=成功、`failed`=终态失败、`timeout`）；**`blocked` 不发**（可重试态，否则每次 attempt 刷屏）。
   - **落地形态**：新增 `post_result_note.sh`（G1b 读 `req_origin` → G9 发 `req_result`），在 `dispatch_followup.sh` 终态处 best-effort 调用（`set +e` 隔离，绝不污染 stdout/打断 Phase 6），用新 trigger 开关 `result_note_enabled`（默认 off）门控，现有 acpx 部署不受影响。

## 4. `req_origin` 标记格式（git_issuer 写、acpx 读）

git_issuer 在 issue 上发一条隐藏标记 note（仿 acpx 自己的 `<!-- acpx_auto_tester:attempt-summary ... -->` 约定）：

```
<!-- req_origin v1 {"channel":"<企微/渠道标识>","user":"<发起人 id>","conversation":"<会话 id>"} -->
```

- 版本前缀 `v1` 便于演进。
- git_issuer **写**（创建时一次）；acpx **读**（终态时）；其它组件忽略。
- 用隐藏 HTML 注释 note，不污染 issue description / 标签 / 标题。
- 变更场景（[`gitissuer_change_request.md`](gitissuer_change_request.md)）里 supersede 出新 issue #N' 时，git_issuer 应把 `req_origin` 一并复制到 #N'，使续测结果仍能回到同一个人。

## 5. 通知内容（114 读 req_result note → origin，文案待对齐）

114 按 **req_result note 的 `status` 字段**（`done`/`failed`/`timeout`，见 §3/§7）选文案，**不是**按 GitLab 标签 `pr`/`failed-*`——后者是 acpx 内部的 issue 标签，从不出现在 note 里，114 也读不到：

- 成功（`status=done`）：`#N 测试完成，MR：<mr_url>`
- 失败（`status=failed`）：`#N 测试未通过：<reason 摘要>，证据见 <wiki_url>`
- 超时（`status=timeout`）：`#N 测试超时未完成，已停放待人工处理`

字段全部取自 req_result note（`mr_url` / `reason` / `wiki_url`，§7 列全；acpx Phase 6 已填）。

## 6. 各组件职责一览

| 组件 | 这条闭环里做什么 | 是否需改动 |
|------|------------------|-----------|
| 企微用户 | 发需求 / 收结果 | — |
| 114 | 转发时带上 origin 元数据；接收 acpx 结果并投给用户 | **需改** |
| req_dispatcher | 纯透传（含 origin 那段文本/字段） | **不变** |
| git_issuer | 解析 origin + 建 issue 时写 `req_origin` 标记 note | **需改**（创建流程加一步） |
| acpx_auto_tester | 终态读 `req_origin` + 通过 channel 通知 origin | **需改**（Phase 6 新增） |

## 7. 待对齐 / 待实现清单

- [ ] **114**：origin 元数据放进文本的确切格式；以及接收端如何把 acpx 的结果通知投给对应用户（经 channel / 跨区回传）。
- [ ] **git_issuer**：创建流程加"解析 origin + 写 `req_origin v1` 标记 note"；supersede 时复制 `req_origin` 到新 issue。
- [x] **acpx_auto_tester（option A，已实现，默认 off）**：已落地 `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/scripts/post_result_note.sh`（G1b 读 `req_origin` → G9 发 `req_result` note，含 `{iid,status,attempt,mr_url,wiki_url,reason,ts,origin}`）+ `dispatch_followup.sh` 终态(done/failed/timeout) best-effort 调用（`set +e` 隔离、stdout→/dev/null、无 `req_origin` 即 no-op）+ trigger 开关 `result_note_enabled`(默认 off，carry-forward) + glab_commands §G14 / SOUL / AGENTS / CLAUDE / state_schema(step 10) / trigger 同步 + `SKILL_VERSION=2026-06-26.1`。经 bash -n + jq 单测 + 2 轮 code-review 子代理（零问题放行）。**开启前置：git_issuer 写 `req_origin` + 114 轮询 `req_result` 两侧就绪后，在 trigger 设 `result_note_enabled=true`。** 本机不能跑 acpx，只做了 `bash -n` + jq 单测 + 评审。
- [ ] **通知文案**最终确定。

## 8. 边界

- req_dispatcher 不参与本闭环（不存映射、不回状态、不追踪结果）——与其极简定位一致。
- acpx 只在**终态**通知一次（不做中途进度播报）。
- 通知失败不应影响 acpx 主流程（best-effort，仿 Phase 6 现有 notify 语义）。
