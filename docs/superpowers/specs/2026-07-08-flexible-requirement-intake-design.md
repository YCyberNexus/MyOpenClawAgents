# Flexible Requirement Intake Design

## 背景

`req_dispatcher` 是公司需求入口，不应把输入格式当成业务门槛。智伴、
WebUI 或人工手动输入都可能带来不同形态的需求：完整 GitLab Wiki URL、
仓库 URL、`group/project` 文本、`glab api` 命令片段，或普通自然语言描述。

当前实现对具体 Wiki URL 支持较强，但对“某仓库 Wiki 所有页面”这类非 URL
需求仍容易让模型按职责边界直接答复“我不能写 GitLab/Wiki”。正确行为应是：
dispatcher 不直接做 GitLab 写操作，但也不因形态不匹配拒绝需求；它应尽力把
输入归一化为 `git_issuer` 可处理的建单请求，再由既有链路进入 `req_executor`。

## 目标

- 支持智伴和 WebUI 的自由形态需求输入。
- 保留现有具体 Wiki URL 读取与拆分能力。
- 对非 Wiki URL 需求做确定性 project 提取和文本归一化。
- 解析不到 project 时不由 dispatcher 直接拒绝，而是把原文交给 `git_issuer`
  按现有契约解析；若 `git_issuer` 仍无法确定 project，则由它返回标准失败
  JSON 和最小补充信息。
- dispatcher 仍不写 GitLab，不建 issue、不打标签、不写 note、不跑 issue。

## 非目标

- 不增加默认 triage project。
- 不让 dispatcher 用 LLM 语义猜测 project。
- 不让 dispatcher 遍历 Wiki、创建 Wiki 页面或新增 GitLab 写 API。
- 不改变 `req_executor` 的执行职责；它仍只接收 `RUN_SINGLE_ISSUE`。

## 输入分类

dispatcher 接入路径按以下顺序归一化：

1. **具体 Wiki URL**
   - 形如 `http(s)://<host>/<group>/<project>/-/wikis/<slug>`。
   - 继续走 `prepare_wiki_downstream_payloads.sh`。
   - 成功时生成一组 `source=req_dispatcher_wiki` 的 `git_issuer` payload。

2. **可确定 project 的自由文本**
   - 支持直接出现 `group/project`。
   - 支持仓库 URL 中的 `/<group>/<project>`。
   - 支持 `glab api "projects/<encoded-group%2Fproject>/..."` 片段。
   - 支持类似“对 GitLab 仓库 xxx/yyy 的 Wiki 所有页面……”的自然语言。
   - 输出一条 `source=req_dispatcher` 的 `git_issuer` payload，需求正文保留用户意图。

3. **无法确定 project 的自由文本**
   - 不再返回“需求文本未包含可识别的 GitLab project”作为 dispatcher 终态拒绝。
   - 生成一条 `source=req_dispatcher_unresolved` 的 `git_issuer` payload。
   - payload 明确说明：dispatcher 未能确定 project，请 `git_issuer` 按现有
     契约解析；若仍无法确定，返回需要用户补充的最小信息。
   - 若 `git_issuer` 返回失败或待补充原因，dispatcher 按现有失败通知路径推回用户。

## 数据流

接入路径保持现有编排顺序：

```text
capture_origin
  -> prepare_wiki_downstream_payloads 或 prepare_downstream_payloads
  -> evict_stuck
  -> run_agent_turn(git_issuer)
  -> record/drain git_issuer stage
  -> route_project
  -> enqueue_executor_issue
  -> drain_executor_queue
  -> ack
```

变化点只在 `prepare_downstream_payloads.sh`：

- 当前可确定 project 的行为保持不变。
- 增加对仓库 URL 和 `glab api projects/<encoded>` 的 project 提取。
- 无 project 时也输出 `status=success`，但 `project=null`，并生成
  `git_issuer_payload`。
- 后续路径不得用 prepare 阶段的 `project=null` 做路由；路由仍只使用
  `git_issuer` 成功返回的 `project`。

## `git_issuer` Payload 约定

可确定 project 时：

```text
CREATE_GITLAB_ISSUE
repo=<group/project>
source=req_dispatcher

请根据下面的需求创建一个 GitLab issue；不要反问 repo，repo 已在上方给出。
只负责创建或变更 issue，不要调用 req_executor，不要回复企微用户。
完成后最后一行输出 req_dispatcher 契约 JSON。

需求正文：
<归一化后的需求正文>
```

无法确定 project 时：

```text
CREATE_GITLAB_ISSUE
source=req_dispatcher_unresolved

req_dispatcher 未能从用户输入中确定 GitLab project。
请按 git_issuer 的现有契约解析该需求：如果能够按确定性规则确定归属则创建 issue；
否则返回 status=failed，并在 reason 中说明需要用户补充的最小信息。
不要调用 req_executor，不要回复企微用户。
完成后最后一行输出 req_dispatcher 契约 JSON。

用户原始需求：
<清理 transport/origin 包装后的需求正文>
```

## 失败处理

- 具体 Wiki URL 读取失败仍停止在 dispatcher，因为这是 dispatcher 自己负责的只读读取步骤。
- 自由文本无 project 不再是 dispatcher 拒绝条件。
- `git_issuer` 返回失败时，沿用现有 `notify_user.sh EVENT=failure` 路径。
- `git_issuer` 成功但缺少合法 `project` / `issue_iid` / `issue_url` 时，仍视为下游返回形态错误或建单失败，不进入 executor。
- `route_project.sh` 仍只处理 `git_issuer` 返回的合法 `group/project`。

## 测试

新增或调整 `prepare_downstream_payloads.sh` 覆盖：

- 直接 `group/project` 输入仍生成 `repo=<group/project>`。
- 仓库 URL 输入能提取 `group/project`。
- `glab api "projects/group%2Fproject/wikis"` 输入能解码提取 `group/project`。
- “某仓库 Wiki 所有页面”自然语言能进入 project 已知路径。
- 无 project 的自然语言输出 `status=success`、`project=null`、
  `source=req_dispatcher_unresolved`，且包含原始需求正文。

编排层回归：

- 无 project 的 prepare 成功后会调用 `git_issuer`，而不是直接 `notify_user`
  拒绝。
- 若 `git_issuer` 对 unresolved payload 返回失败 reason，dispatcher 会把该
  reason 推回用户。

## 部署影响

只涉及 `workspace-req_dispatcher` 的入口准备逻辑、提示契约和测试。改动后需要
bump `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md` 的
`SKILL_VERSION`。
