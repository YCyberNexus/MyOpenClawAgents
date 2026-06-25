# git_issuer I/O 契约

> 状态：**待与同事对齐**。`git_issuer` 是同事在 104 OpenClaw 上构建的 agent（"根据需求构建 GitLab issue"），不在本仓内。本文件记录 req_dispatcher 对它的最小依赖与待确认项。对齐后据此更新 SKILL 接入/回调路径的字段名。

## req_dispatcher 对 git_issuer 的依赖（最小）

req_dispatcher 是薄透传，对 git_issuer 的唯一硬依赖是：

1. **接受一段自由文本需求**作为输入（payload 字段名见 [`trigger_command.md`](trigger_command.md) ⚠️）。
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

## 不依赖项（明确）

- req_dispatcher **不**依赖 git_issuer 回显任何 req_dispatcher 生成的 token（匹配以 `run_id` 为主，见 trigger_command.md §匹配）。仅在 `run_id`/`child_session_key` 都拿不到的退化情形才需要回显 `correlation_id`。
