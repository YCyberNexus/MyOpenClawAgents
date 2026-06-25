# Trigger / 跨 agent 原语契约

> 状态：**部分待对齐**。下面"接入消息"与"两条逻辑路径"已定；"跨 agent spawn 原语"与"回调 trigger"的确切工具名/字段**待与 OpenClaw 维护者/同事对齐**（标注 ⚠️ 处）。架构不依赖这些具体取值——匹配以 `run_id` 为主，故即便对齐前也能推进设计与脚本。

## 接入消息（114 → req_dispatcher）

- 形态：自由文本，经网关 `agent run --agent req_dispatcher "<需求原文>" --deliver`（架构图"114 侧调用特定 agent"方式 A）或等价 HTTP 桥接（方式 B）。
- req_dispatcher 收到的就是一段需求文本，**不是结构化 trigger 信封**。orchestrator 据"路径判定"识别为接入路径。
- `req_dispatcher` 整段原样透传给 git_issuer，不解析。

## 跨 agent spawn 原语（req_dispatcher → git_issuer）⚠️ 待对齐

用户已确认：形态**类 `sessions_spawn`、可指定目标 agent、异步、结果经回调返回**。对齐时需敲定：

- [ ] 工具确切名称：是带 `agent`/`target_agent` 参数的 `sessions_spawn`，还是另一个专用跨 agent 工具？（据此更新 SKILL frontmatter `allowed-tools` 与接入路径第 3 步。）
- [ ] 如何指定目标 = `${GIT_ISSUER_AGENT}`（参数名）。
- [ ] 如何传 payload `{requirement_text}`（参数名、是否需写入临时文件再传路径，类似 acpx 的 `spawn_payload.txt`）。
- [ ] 返回里 `run_id` / `child_session_key` 的字段名（接入路径第 4 步据此填 `RUN_ID` / `CHILD_SESSION_KEY`）。
- [ ] launch ack 等待超时参数（类比 acpx `timeoutSeconds=30`）与运行超时参数（类比 `runTimeoutSeconds`）。
- [ ] 失败形态枚举（`status:"error"` / 网关超时 / 缺 `run_id` 等），以触发"同 payload 3 次 2s 退避"。

对齐前，连接所需的额外变量（如网关 url/token）写入 `config/dispatcher.env` 末尾占位处。

## 回调 trigger（git_issuer 完成 → req_dispatcher）⚠️ 待对齐

类比 acpx 的 `RUN_CHILD_COMPLETION_CALLBACK`。对齐时需敲定：

- [ ] 回调 trigger 的确切名称（占位：`RUN_GITISSUER_CALLBACK`）。
- [ ] 回调里 `run_id`（或 `child_session_key`）字段名——**回调路径以此为主匹配键**。
- [ ] git_issuer 终态输出承载在哪个字段（类比 acpx 的 `worker_result_json`），以及其结构（见 [`gitissuer_contract.md`](gitissuer_contract.md)）。

## 匹配策略

- **主（已定，已实现）：`run_id`**。接入路径记 `pending[run_id]`；回调路径用回调的 `run_id` 直接 drain（`drain_pending.sh` 按 `RUN_ID` 删除）。**不要求 git_issuer 回显任何我们的 token**，对同事 agent 零侵入。
- **匹配不到 pending（已定）**：迟到 / 重复 / 已被 stuck 驱逐的回调，仍照常调 `drain_pending.sh`，写 `was_pending=false` 审计行——预期情形、非错误。
- **兜底：`child_session_key`** ⚠️ 待对齐：仅当回调带 `child_session_key` 而 `run_id` 缺时才需要。**当前 `drain_pending.sh` 不支持按 `child_session_key` 反查**——若对齐后确实需要此路径，需给 `drain_pending.sh` 增"`RUN_ID` 空时按 `CHILD_SESSION_KEY` 反查 pending 主键再 drain"的分支。未对齐前不承诺此路径。
- **回显模式（`correlation_id`）** ⚠️ 待对齐：仅当 `run_id` 与 `child_session_key` 都拿不到的退化情形才启用。设想是接入时用 `${STATE_ROOT}/_dispatcher/seq`（flock 保护、`env_paths.sh` 已预留 `SEQ_FILE` 路径）单调递增生成 `correlation_id`、随 payload 传给 git_issuer 并要求其回显。**此 seq 生成机制尚未实现**（无脚本写 `seq`），且**需 git_issuer 配合回显、有侵入**。对齐时若确需此模式，再补 seq 自增脚本 + git_issuer 回显约定。**未对齐前不要自行用随机/时间戳生成 `correlation_id`**（违反 No-Fallback）。

## 两条逻辑路径（已定，详见 SKILL.md）

- 接入路径：evict_stuck → cross-agent spawn git_issuer → record_pending(run_id) → 最小 ack。
- 回调路径：解析终态 → 按 run_id drain_pending → 成功收尾 / 失败记录 + 可选 ops 通知。
