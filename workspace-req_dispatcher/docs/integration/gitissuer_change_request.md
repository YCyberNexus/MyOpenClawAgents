# git_issuer 变更请求对接文档（需求变更 / Change Request）

> 状态：**待与同事对齐**。本文件是给 `git_issuer` 作者的对接契约：在"创建 issue"之外，新增"对已存在 issue 的变更（更新 / 撤销 / 取代）"能力，使"需求已变成 issue #N、但还没处理或正在处理时需要改需求"的场景可被处理。`req_dispatcher` 在此流程里**基本不变**（仍纯透传），重活在 git_issuer（+ 可选的 114）。
>
> ⚠️ **主动编排（driven 路径）下不变**（见 [`../superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](../superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)）：req_dispatcher 升级为编排器后，**变更/撤销/取代流程仍由 req_dispatcher 透传，基本不变**——变更文本依旧整段透传给 git_issuer，req_dispatcher 仍只按 `run_id` 记 pending(stage=git_issuer) + 回调 drain（见 SKILL 接入路径 / git_issuer 回调路径，[`../../skills/requirement_dispatch/SKILL.md`](../../skills/requirement_dispatch/SKILL.md)）。差异仅在创建成功后的后续编排（route + spawn executor + 推用户）属 driven 新增，与本变更契约正交。下方 §6"关联（conversation → #N）"中复用 `req_origin` 作锚点的提示仅适用于 **cron 路径**（driven 路径 origin 由 req_dispatcher 自持，见 [`gitissuer_contract.md`](gitissuer_contract.md) 顶部）。

## 1. 适用场景

需求 A 已经过 `req_dispatcher → git_issuer` 变成了 GitLab issue #N，此时用户想：
- 修订 / 澄清需求（issue 还没被 req_executor 捞起，或正在跑，或已出 MR）；
- 撤销整个需求；
- 变更太大、近乎换了个需求。

req_executor 已有的"按 label 重跑 + 每次 attempt 重读 issue body + continue 注入 reviewer 评论 + MR 轮换 supersede"机制足以承载重跑，**无需改 req_executor**。本流程要做的，是让 git_issuer 把变更**正确落到 issue #N 上**。

## 2. 输入：区分"新建"还是"变更"

git_issuer 收到的仍是自由文本（req_dispatcher 透传，或 114 路由）。它要先判意图：

- **CREATE**（无目标 issue 引用）→ 走既有"需求→新建 issue"流程。
- **CHANGE**（文本里引用了已存在 issue：`#N` 或 issue URL）→ 走本文档的变更流程。

目标 issue 引用怎么来（关联方案，见 §6）：
- **A（推荐起步）**：用户显式说"改 #N：……"。前提是 git_issuer **创建时给用户的通知里带了 #N + URL**（见 §6）。
- **B（UX 更好）**：114 在会话里自动补 `#N`。属 114 侧。

git_issuer 仍需从文本解析：目标 project（同创建流程，从文本解析）、目标 issue 引用、修订后的需求内容。

## 3. 决策：按 #N 当前状态选操作

git_issuer 先用 `glab` 读 #N 的当前 **state（opened/closed）+ 工作态 label**，再按下表操作：

| #N 状态 | git_issuer 动作 | req_executor 后续效果 |
|---|---|---|
| opened，入口标签未被捞起（`todo`/`new`/`retry`，无 `doing`） | **编辑 issue description = 新需求**（保留现有入口标签）。可附一条变更说明 note。 | 下一轮 attempt 按新 description 重跑（fresh）。 |
| opened，`doing`（**正在跑**） | 编辑 description = 新需求 + 留一条 reviewer note 写变更要点；并打 **`retry`**（清零 fresh 重跑）或 **`continue`**（在工作分支上续跑）。**不要试图打断当前 attempt**（见 §5）。 | 当前 attempt 先跑完；**下一次** attempt 用新内容；旧 MR 被 req_executor 轮换关闭、建新 MR（`Supersedes !旧`）。 |
| opened，`pr`（**已完成**，MR 已建） | 编辑 description（可选）+ 留 reviewer note 写变更要点 + 打 **`continue`**。 | continue 模式续跑，req_executor 把 reviewer note 注入 prompt。 |
| opened，`blocked-*`/`failed-*`/`timeout` | 编辑 description = 新需求 + 留 note + 打 **`retry`**。 | 清零重跑。 |
| **撤销整个需求** | `glab issue close`（note 写撤销原因）。 | req_executor 把 `closed` 当**硬终态跳过**，永不再排。 |
| 变更**太大 ≈ 新需求** | 关旧 #N（note 写"被 #N' 取代"）+ **新建 #N'**（带入口标签，走创建流程）。 | req_executor 处理 #N'。 |

**最重要的一条规则**：**权威的需求内容永远写进 issue description**（req_executor 每次 attempt、所有模式都重读 description）。reviewer **评论**只有 **continue 模式**才会被注入 prompt——所以 `retry`/fresh 重跑必须靠改 description，不能只靠评论。

## 4. req_executor label 语义摘要（git_issuer 必须严格遵守）

git_issuer 在变更场景里**扮演 human reviewer**，所以可以打 req_executor 的人工 review 标签。但只能用下面这套，且只能碰指定的几个：

- **工作态标签（互斥）**：`todo` `new` `retry` `continue` `doing` `done`(瞬态) `pr` `blocked-cc` `blocked-dispatcher` `failed-cc` `failed-dispatcher` `timeout`。
- git_issuer **只允许打** `retry`（fresh 重置重跑）或 `continue`（续跑）——这俩是 req_executor 约定的 human review 重跑信号（req_executor 自己从不打它们）。
- git_issuer **绝不能打** `doing`/`done`/`pr`/`blocked-*`/`failed-*`/`timeout`——那些是 req_executor 自己的状态机，外部插手会破坏一致性。
- **撤销**用 `glab issue close`（不是打标签）。
- **不要动** req_executor 的正交标签 `model:*` / `quality:low`，也不要动用户的 priority/severity 等业务标签。
- 打标签务必用**定向 add/remove**（保留其它非工作态标签），不要整组覆盖 `labels=`。

## 5. 安全边界（务必遵守）

1. **"正在跑（`doing`）"改不了当前这次 attempt**：req_executor 在 attempt 开始时一次性渲染 prompt、`acpx claude exec` 是 one-shot。变更只在**下一次** attempt 生效。git_issuer **不要**尝试 kill 正在跑的子代理——req_executor 没有对外的"中途取消"流程（只有 stuck 驱逐和终态 kill）。若确需"立刻掐断正在跑的"，那是 **req_executor 侧的新能力**，不在本流程。
2. **git_issuer 只动 issue**（description / note / `retry`\|`continue` / `close` / 新建），**绝不 merge MR、绝不 close MR、绝不删历史**——MR 由 req_executor 轮换、由人合并。
3. **幂等**：同一 #N 短时间多次变更，以"最新一条"为准。重复编辑 description 没问题；重复打 `retry`/`continue` 无害，但避免无意义抖动。
4. **project 解析失败 / #N 不存在 / #N 已 closed**：按失败回传（见 §7），不臆造、不自动新建（除非用户明确要 supersede）。

## 6. 关联（conversation → #N）

`req_dispatcher` 极简、不报 IID、不存映射，所以关联必须在别处：

- **A（推荐起步）**：git_issuer **创建 issue 时给用户的通知必须带 `#N` + URL**（这也正是回传模板里 `issue_iid`/`issue_url` 的用途——确保 git_issuer 不只回 req_dispatcher，也通知到用户）。用户改需求时显式引用 #N。零新增状态。
- **B（升级）**：114 维护"企微会话 ↔ #N"映射，用户在同一会话说"改一下需求"，114 自动补 #N。属 114 侧。
- `req_dispatcher` **不参与关联**（保持极简）。

> 复用提示：测试结果闭环（[`result_notify_loop.md`](result_notify_loop.md)）要求 git_issuer 在 issue 上写 `<!-- req_origin v1 {...} -->` 标记。这条标记天然也是"会话 ↔ #N"的锚点——114 走方案 B 时可直接复用它，无需再造一套映射。supersede 出新 issue 时记得把 `req_origin` 复制过去。

## 7. 回传给 req_dispatcher（复用回调模板 + 加 `action`）

变更完成后，git_issuer 的回调终态 JSON 复用 [`gitissuer_contract.md`](gitissuer_contract.md) 的紧凑 JSON 模板，**新增 `action` 字段**标明本次做了什么；req_dispatcher 仍按 runtime `run_id` 匹配 pending（不依赖这些字段做匹配），`OUTCOME` 仍取 `status`：

成功（举例：对正在跑的 #312 改 body 并打 retry）：

```
{"status":"success","action":"updated+relabeled","issue_iid":312,"issue_url":"http://<host>/<group>/<project>/-/issues/312","project":"<group>/<project>","entry_label":"retry","superseded_by":null,"reason":null,"correlation_id":null}
```

supersede（关旧 312、新建 318）：

```
{"status":"success","action":"superseded","issue_iid":312,"issue_url":"http://<host>/<group>/<project>/-/issues/312","project":"<group>/<project>","entry_label":null,"superseded_by":318,"reason":null,"correlation_id":null}
```

失败（#N 不存在 / 已 closed / 解析不出目标）：

```
{"status":"failed","action":"none","issue_iid":null,"issue_url":null,"project":null,"entry_label":null,"superseded_by":null,"reason":"目标 issue #312 已关闭，无法变更","correlation_id":null}
```

新增字段：
- `action`：`updated`（改了 description）/ `relabeled`（打了 retry/continue）/ `updated+relabeled` / `closed`（撤销）/ `superseded`（关旧建新）/ `created`（按新需求新建）/ `none`（失败）。可组合表达。
- `superseded_by`：supersede 时新 issue 的 IID，否则 `null`。
- 其余字段同 [`gitissuer_contract.md`](gitissuer_contract.md) 的创建模板。

## 8. 给同事的实现 checklist

- [ ] 入参意图识别：CREATE vs CHANGE（从文本解析 `#N`/URL）。
- [ ] 读 #N 当前 state + 工作态 label（`glab`）。
- [ ] 按 §3 状态表选操作（编辑 description / 加 note / 打 `retry`\|`continue` / `close` / supersede 新建）。
- [ ] 严格遵守 §4 label 语义：只打 `retry`/`continue`，绝不碰 `doing`/`done`/`pr`/`blocked*`/`failed*`/`model:*`/`quality:low`；用定向 add/remove。
- [ ] 权威需求写进 **description**（fresh 重跑只认 description；评论仅 continue 模式注入）。
- [ ] 遵守 §5 边界：不打断正在跑的 attempt、不碰 MR、幂等。
- [ ] 创建流程的**用户通知带 `#N` + URL**（支撑关联方案 A）。
- [ ] 回调加 `action` / `superseded_by` 字段（§7）。

## 9. 各组件职责一览（变更流程）

| 组件 | 在变更流程里做什么 |
|------|--------------------|
| 企微用户 | 在 114 上说"改 #N：……"（方案 A）或"改一下需求"（方案 B） |
| 114 bot | 透传变更文本；（方案 B）补 `#N` 引用 |
| **req_dispatcher** | **不变**：仍纯透传 + 记 pending(run_id) + 回调 drain |
| **git_issuer** | **新增**：识别变更意图 → 按 #N 状态 编辑/打标签/关闭/supersede → 回调带 `action` |
| req_executor | **不变**：靠既有 `retry`/`continue`/`closed` + 重读 description + MR 轮换自动重跑收尾 |
