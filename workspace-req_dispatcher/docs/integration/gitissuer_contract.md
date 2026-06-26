# git_issuer I/O 契约

> 状态：**待与同事对齐**。`git_issuer` 是同事在 104 OpenClaw 上构建的 agent（"根据需求构建 GitLab issue"），不在本仓内。本文件记录 req_dispatcher 对它的最小依赖与待确认项。对齐后据此更新 SKILL 接入/回调路径的字段名。
>
> 本文件覆盖 **创建 issue** 流程。需求在变成 issue 后还要**变更/撤销/取代**的对接契约见 [`gitissuer_change_request.md`](gitissuer_change_request.md)。

## req_dispatcher 对 git_issuer 的依赖（最小）

req_dispatcher 是薄透传，对 git_issuer 的唯一硬依赖是：

1. **接受一段自由文本需求**作为输入（payload 字段名见 [`trigger_command.md`](../../skills/requirement_dispatch/references/trigger_command.md) ⚠️）。
2. **自己从文本解析目标 project/group**（req_dispatcher 不解析、不传结构化 project）。
3. **建好 GitLab issue 后，打上 acpx 入口标签**（如 `todo`/`new`），使 `acpx_auto_tester` 既有 cron 流程能被动捞起。
4. **在完成回调里带回终态**：成功/失败，成功时带 issue IID 与 URL，失败时带原因。

## 待对齐清单

- [ ] **入参字段**：除 `requirement_text` 外是否还需别的（如调用方标识、企微用户/会话 id 供 git_issuer 自己通知用户）？req_dispatcher 可透传但不依赖。
- [ ] **成功表达**：回调终态如何表示成功；`issue_iid`（整数）与 `issue_url` 在哪个字段。SKILL 回调路径据此填 `ISSUE_IID` / `ISSUE_URL`。
- [ ] **失败表达**：失败如何表示、原因字段名。SKILL 据此填 `OUTCOME=failed` + `REASON`。
- [ ] **入口标签**：git_issuer 默认打哪个 acpx 入口标签？是否按 project 不同而不同？（若需 req_dispatcher 显式指定，则启用 `config/dispatcher.env` 的 `DEFAULT_ENTRY_LABEL` 并随 payload 传——默认不需要。）
- [ ] **project 解析失败**：git_issuer 解析不出 project 时，回调按"失败 + 原因"返回（req_dispatcher 记 ledger + 可选 ops 通知，不自动重试）。
- [ ] **用户通知归属**：确认"issue 已建 / 测试结果"由 git_issuer / acpx 各自的 channel 通知企微用户——req_dispatcher 极简、不主动回状态，依赖此前提成立。

## 回传消息模板（git_issuer 完成回调的终态输出）

git_issuer 建完 issue 后，在它**最后一轮的最后一行**只输出**一行紧凑 JSON**（无散文、无代码围栏、无日志）。OpenClaw runtime 捕获该行作为完成回调的终态输出，交给 req_dispatcher 的回调路径解析（与 acpx 子代理的 compact-reply 同一约定）。承载该行的回调信封字段名待对齐，见 [`trigger_command.md`](../../skills/requirement_dispatch/references/trigger_command.md) §回调 trigger ⚠️。

**成功**（实际就输出这一行）：

```
{"status":"success","issue_iid":312,"issue_url":"http://<host>/<group>/<project>/-/issues/312","project":"<group>/<project>","entry_label":"todo","reason":null,"correlation_id":null}
```

**失败**：

```
{"status":"failed","issue_iid":null,"issue_url":null,"project":null,"entry_label":null,"reason":"无法从需求文本解析出目标 project","correlation_id":null}
```

### 字段语义

| 字段 | 何时必填 | 含义 / req_dispatcher 怎么用 |
|------|---------|------------------------------|
| `status` | 总是 | `"success"` \| `"failed"`。映射到 `drain_pending.sh` 的 `OUTCOME`（success→success，failed→failed）。**git_issuer 不发 `launch_failed`**——那是 req_dispatcher 在 spawn 失败时自己合成的（见 state_schema.md 的 outcome 枚举）。 |
| `issue_iid` | success | 整数 IID → `ISSUE_IID`。正整数、无前导零。 |
| `issue_url` | success | issue 完整 URL → `ISSUE_URL`。 |
| `project` | 建议 | git_issuer 从需求文本解析出的实际 `<group>/<project>`。供审计，并用于确认 acpx 衔接前提（该 project 是否有 acpx campaign 在跑，见 [`../../AGENTS.md`](../../AGENTS.md) §acpx 衔接依赖）。 |
| `entry_label` | 建议 | 实际打上的 acpx 入口标签（如 `todo`/`new`）。供排查"为何 acpx 没捞起"。 |
| `reason` | failed | 失败原因（解析不出 project / `glab` 建 issue 失败 / 打标签失败……）→ `REASON`。 |
| `correlation_id` | 可选 | **默认 `null`**。仅当走待对齐的"回显模式"才回显 req_dispatcher 传来的值（见下方"不依赖项"与 trigger_command.md §匹配）。 |

### 两条约定

1. **匹配不靠这个 JSON**：req_dispatcher 用 runtime 回调自带的 `run_id` 匹配 pending（对 git_issuer 零侵入）。本 JSON 只承载"issue 事实"；git_issuer **不需要知道也不需要回显 `run_id`**。
2. **只输出最后一行那一条**：运行过程的日志/散文随意，但最后一轮的最后一行必须只有这一行紧凑 JSON，runtime 才能干净捕获。

## 不依赖项（明确）

- req_dispatcher **不**依赖 git_issuer 回显任何 req_dispatcher 生成的 token（匹配以 `run_id` 为主，见 trigger_command.md §匹配）。仅在 `run_id`/`child_session_key` 都拿不到的退化情形才需要回显 `correlation_id`。
