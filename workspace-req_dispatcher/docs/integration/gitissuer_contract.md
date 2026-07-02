# git_issuer I/O 契约

> 状态：**req_dispatcher 侧最小依赖已定**。蓝区 `git_issuer` 是 104 OpenClaw 上的 agent（"根据需求构建 GitLab issue"）。本机 `workspace-git_issuer` 仅作测试工件，不作为蓝区行为依据。req_dispatcher 通过 `scripts/run_agent_turn.sh` 调用蓝区 `git_issuer`，并只依赖它最后一行输出的紧凑 JSON。
>
> 主动编排（driven 路径）下，req_dispatcher **不依赖 git_issuer 写 `req_origin` 标记 note，也不依赖 git_issuer 通知用户**。origin 由 req_dispatcher 在接入路径自己 capture 并全程随 pending 携带，建 issue 成功/失败由 req_dispatcher 推回用户。req_dispatcher 只复用 `git_issuer` 最后一行 JSON 里的 `project` / `issue_iid`(=iid) / `issue_url`，据此 route 到 req_executor 并调用 `RUN_SINGLE_ISSUE {project, iid, ...}`。
>
> 本文件覆盖 **创建 issue** 流程。需求在变成 issue 后还要**变更/撤销/取代**的对接契约见 [`gitissuer_change_request.md`](gitissuer_change_request.md)。

## req_dispatcher 对 git_issuer 的依赖（最小）

req_dispatcher 对蓝区 git_issuer 的硬依赖是：

1. **接受一段自由文本需求**作为输入。req_dispatcher 通过 `run_agent_turn.sh` 把需求原文作为 `openclaw agent --message` 的正文传入。
2. **自己从文本解析目标 project/group**（req_dispatcher 不解析、不传结构化 project）。
3. **建好 GitLab issue 后，打上执行器入口标签**（如 `todo`/`new`），使 `req_executor` 既有 cron 流程能被动捞起。
4. **最后一行输出终态 JSON**：成功/失败，成功时带 `project`、issue IID 与 URL，失败时带原因。

## 蓝区 git_issuer 输出清单

- **成功表达**：`status="success"`，`issue_iid` 为正整数，`issue_url` 为完整 issue URL，`project` 为完整 `group/project`。
- **失败表达**：`status="failed"`，`reason` 为失败原因；project 解析失败也按失败 JSON 返回。
- **入口标签**：git_issuer 负责给新 issue 打执行器入口标签。req_dispatcher 不依赖具体标签名；执行器 driven 路径由 req_dispatcher 直接调用。
- **origin 标记**：driven 路径不依赖 git_issuer 写 `req_origin` note；cron 路径若仍使用旧闭环，按 [`result_notify_loop.md`](result_notify_loop.md) 另行处理。
- **用户通知归属**：driven 路径由 req_dispatcher 推建单失败、启动失败和最终执行结果；git_issuer 不需要直接通知企微用户。

## 回传消息模板（git_issuer 完成回调的终态输出）

git_issuer 建完 issue 后，在它**最后一轮的最后一行**只输出**一行紧凑 JSON**（无散文、无代码围栏、无日志）。`run_agent_turn.sh` 会解析目标 agent 输出中的最后一行 JSON，并把它放进 envelope 的 `worker_result_json` 字段。

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
| `status` | 总是 | `"success"` \| `"failed"`。映射到 `drain_pending.sh` 的 `OUTCOME`（success→success，failed→failed）。**git_issuer 不发 `launch_failed`**——那是 req_dispatcher 在下游调用失败耗尽重试时自己合成的（见 state_schema.md 的 outcome 枚举）。 |
| `issue_iid` | success | 整数 IID → `ISSUE_IID`。正整数、无前导零。 |
| `issue_url` | success | issue 完整 URL → `ISSUE_URL`。 |
| `project` | success 必填 | git_issuer 从需求文本解析出的实际 `<group>/<project>`。req_dispatcher 用它调用 `route_project.sh`；合法 project 未命中覆盖表时会走 `DEFAULT_EXECUTOR_AGENT`。 |
| `entry_label` | 建议 | 实际打上的执行器入口标签（如 `todo`/`new`）。供排查"为何 req_executor 没捞起"。 |
| `reason` | failed | 失败原因（解析不出 project / `glab` 建 issue 失败 / 打标签失败……）→ `REASON`。 |
| `correlation_id` | 可选 | **默认 `null`**。driven 路径不依赖 git_issuer 回显此字段。 |

### 两条约定

1. **匹配不靠这个 JSON**：req_dispatcher 用 `run_agent_turn.sh` envelope 的 `run_id` 做审计键。本 JSON 只承载"issue 事实"；git_issuer **不需要知道也不需要回显 `run_id`**。
2. **只输出最后一行那一条**：运行过程的日志/散文随意，但最后一轮的最后一行必须只有这一行紧凑 JSON，`run_agent_turn.sh` 才能干净捕获。

## 不依赖项（明确）

- req_dispatcher **不**依赖 git_issuer 回显任何 req_dispatcher 生成的 token；`correlation_id` 只用于 executor 段。
