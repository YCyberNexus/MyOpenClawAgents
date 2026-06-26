# 测试结果闭环回报（result notify loop）

> 状态：**待对齐 + 部分待实现（acpx 侧）**。本文件定义端到端把 `acpx_auto_tester` 的测试结果回报给"当初在企微发需求的那个人"的闭环。**`req_dispatcher` 全程不变**（仍纯透传，不追踪结果、不回状态）。

## 1. 目标

issue #N 被 acpx 处理到终态（`pr` 成功 / `failed-*` / `timeout`）后，通知**当初发起该需求的企微用户**，而不只是把 issue 建出来就断了。

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
4. **acpx_auto_tester（新增能力，在 `workspace-acpx_auto_tester`）**：Phase 6 到达终态（`pr` / `failed-cc` / `failed-dispatcher` / `timeout`）时，读 issue 的 `req_origin` 标记（acpx 本就用 `glab` 读 issue notes），把结果通过 channel 通知该 origin。复用 acpx 既有的 Phase 6 可选 `notify_channel` 基建。

## 4. `req_origin` 标记格式（git_issuer 写、acpx 读）

git_issuer 在 issue 上发一条隐藏标记 note（仿 acpx 自己的 `<!-- acpx_auto_tester:attempt-summary ... -->` 约定）：

```
<!-- req_origin v1 {"channel":"<企微/渠道标识>","user":"<发起人 id>","conversation":"<会话 id>"} -->
```

- 版本前缀 `v1` 便于演进。
- git_issuer **写**（创建时一次）；acpx **读**（终态时）；其它组件忽略。
- 用隐藏 HTML 注释 note，不污染 issue description / 标签 / 标题。
- 变更场景（[`gitissuer_change_request.md`](gitissuer_change_request.md)）里 supersede 出新 issue #N' 时，git_issuer 应把 `req_origin` 一并复制到 #N'，使续测结果仍能回到同一个人。

## 5. 通知内容（acpx → origin，文案待对齐）

- 成功（`pr`）：`#N 测试完成，MR：<merge_request_url>`
- 失败（`failed-*`）：`#N 测试未通过：<block_reason 摘要>，证据见 <evidence/wiki 链接>`
- 超时（`timeout`）：`#N 测试超时未完成，已停放待人工处理`

具体字段 acpx Phase 6 已有（MR URL / block_reason / wiki_url 等，见 acpx 的 compact reply / state）。

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
- [ ] **acpx_auto_tester**：Phase 6 终态读 `req_origin`，经 channel 通知 origin（含投递到企微的具体通道）。这是 `workspace-acpx_auto_tester` 的真实代码改动，需走它自己的 review 循环 + `SKILL_VERSION` bump。
- [ ] **通知文案**最终确定。

## 8. 边界

- req_dispatcher 不参与本闭环（不存映射、不回状态、不追踪结果）——与其极简定位一致。
- acpx 只在**终态**通知一次（不做中途进度播报）。
- 通知失败不应影响 acpx 主流程（best-effort，仿 Phase 6 现有 notify 语义）。
