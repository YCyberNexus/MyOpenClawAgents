# git_issuer Agent Design

## 背景

`req_dispatcher` 已升级为 104 OpenClaw 上的需求接入与端到端编排器。它接收 114 转发来的自由文本需求，但不解析 project、不持 GitLab token、不碰 GitLab。链路中的 `git_issuer` 负责把自由文本需求转成 GitLab issue，并把 issue 事实通过回调交还给 `req_dispatcher`，后者再路由到目标 `req_executor`。

当前仓库还没有 `workspace-git_issuer/`。本设计新增该 workspace，并把它部署为本机 OpenClaw agent `git_issuer`。

## 目标

构建一个独立 OpenClaw agent：

- Agent name: `git_issuer`
- 固定 session: `agent:git_issuer:main`
- 唯一 skill: `git_issue_intake`
- workspace: `workspace-git_issuer/`

它支持两类输入：

- 新建需求：自由文本中命中配置里的 project 别名后，创建 GitLab issue，打执行器入口标签，并输出 `req_dispatcher` 可解析的紧凑 JSON。
- 变更需求：自由文本引用已有 issue `#N` 或 issue URL 时，按当前 issue 状态执行编辑、重跑标签、关闭或 supersede，并输出带 `action` 的紧凑 JSON。

## 核心决策

采用“配置别名优先，模型不猜项目”的方案。

`git_issuer` 只能根据 `config/project_routing.env` 中的项目名、全名或别名解析 project。若自由文本没有命中配置，agent 必须失败回传，不允许靠语义猜测目标 project。这样可以避免错误创建 issue 到不相关项目。

## 非目标

- 不实现自然语言任意 project 推断。
- 不绕过 `glab` 调 GitLab API。
- 不 merge MR，不 close MR，不删除历史。
- 不触碰 `req_executor` 的内部状态文件。
- 不在本地测试中创建真实 GitLab issue。

## Workspace 结构

```text
workspace-git_issuer/
  AGENTS.md
  CLAUDE.md
  SOUL.md
  USER.md
  config/
    README.md
    gitlab.env
    project_routing.env
  docs/
    GIT_ISSUER_USAGE.md
  skills/
    git_issue_intake/
      SKILL.md
      references/
        callback_contract.md
        trigger_contract.md
      scripts/
        env_paths.sh
        parse_project.sh
        create_issue.sh
        update_issue.sh
        emit_callback.sh
      tests/
        test_parse_project.sh
        test_create_issue_fake_glab.sh
        test_update_issue_fake_glab.sh
```

## 配置

`config/gitlab.env` 是部署期 pin：

```text
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=
DEFAULT_ENTRY_LABEL=todo
STATE_ROOT=/data/git_issuer
```

`GITLAB_TOKEN` 可以为空；部署时推荐由 runner 的环境变量注入。脚本以环境变量优先，配置文件兜底。缺 token 时，真实 GitLab 操作失败并输出失败 JSON。

`config/project_routing.env` 逐行配置 project 与别名：

```text
claw_gitlab/px_ifp_hulat_test|px_ifp_hulat_test,ifp,hulat
```

左侧是 GitLab `<group>/<project>`，右侧是逗号分隔别名。匹配规则：

- 命中完整 `<group>/<project>`。
- 命中 project slug。
- 命中别名。
- 大小写敏感，默认不做模糊匹配。

未命中时返回失败原因 `无法从需求文本解析出目标 project`。

## 新建 Issue 流程

1. `git_issuer` 收到自由文本需求。
2. LLM 判定本次为 CREATE，并提取要写入 issue 的需求正文。
3. LLM 调用 `parse_project.sh`，脚本只按 `project_routing.env` 精确匹配 project。
4. 命中后调用 `create_issue.sh`。
5. `create_issue.sh` 使用 `glab issue create` 创建 issue，并用定向标签操作添加入口标签。
6. 若文本中携带 origin 元数据，脚本写入隐藏 note：

```text
<!-- req_origin v1 {"channel":"wecom","user":"user-123","conversation":"conv-456","reply_agent":"wecom_receiver"} -->
```

7. 最后一行输出紧凑 JSON：

```json
{"status":"success","action":"created","issue_iid":312,"issue_url":"http://<host>/<group>/<project>/-/issues/312","project":"<group>/<project>","entry_label":"todo","superseded_by":null,"reason":null,"correlation_id":null}
```

失败时输出：

```json
{"status":"failed","action":"none","issue_iid":null,"issue_url":null,"project":null,"entry_label":null,"superseded_by":null,"reason":"无法从需求文本解析出目标 project","correlation_id":null}
```

## 变更 Issue 流程

LLM 识别到 `#N` 或 issue URL 时进入 CHANGE 流程。它仍必须通过 `parse_project.sh` 解析 project，不能从 issue URL 之外猜 project。

`update_issue.sh` 先读取 issue 当前状态与工作态标签，再执行：

| 当前状态 | 动作 |
| --- | --- |
| opened，未被捞起，含 `todo`/`new`/`retry` 且无 `doing` | 编辑 description，可写变更 note，保留入口标签 |
| opened，`doing` | 编辑 description，写变更 note，添加 `retry` 或 `continue` |
| opened，`pr` | 编辑 description，写变更 note，添加 `continue` |
| opened，`blocked-*`/`failed-*`/`timeout` | 编辑 description，写变更 note，添加 `retry` |
| 用户明确撤销 | 关闭 issue，写撤销 note |
| 变更太大 | 关闭旧 issue，创建新 issue，输出 `superseded_by` |

标签操作只能定向 add/remove：

- 允许添加：`retry`、`continue`
- 不允许添加：`doing`、`done`、`pr`、`blocked-*`、`failed-*`、`timeout`
- 不允许改：`model:*`、`quality:low`、业务 priority/severity 标签

## LLM 与脚本职责边界

LLM 负责：

- 判定 CREATE / CHANGE / CANCEL / SUPERSEDE。
- 从自由文本提取 issue 标题、需求正文、issue 引用、变更说明。
- 选择 `retry` 或 `continue`，但必须遵守 `gitissuer_change_request.md` 的状态表。
- 调用脚本，并把脚本最后一行 JSON 原样作为最后一行输出。

脚本负责：

- project 配置匹配。
- GitLab host/token 校验。
- 所有 `glab` 操作。
- JSON 输出格式。
- 本地状态目录与日志。

## 回调契约

`git_issuer` 的最后一轮最后一行必须只有一行紧凑 JSON。字段兼容 `workspace-req_dispatcher/docs/integration/gitissuer_contract.md` 与 `gitissuer_change_request.md`：

```json
{"status":"success|failed","action":"created|updated|relabeled|updated+relabeled|closed|superseded|none","issue_iid":312,"issue_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312","project":"claw_gitlab/px_ifp_hulat_test","entry_label":"todo|retry|continue|null","superseded_by":null,"reason":null,"correlation_id":null}
```

`req_dispatcher` 仍以 runtime 回调自带 `run_id` 匹配 pending，不依赖 `git_issuer` 回显 token。

## 测试策略

不在本地测试中访问真实 GitLab。测试使用 fake `glab`：

- `test_parse_project.sh`：验证别名、slug、全名命中；未知项目失败。
- `test_create_issue_fake_glab.sh`：验证创建 issue 的 `glab` 参数、入口标签、成功 JSON。
- `test_update_issue_fake_glab.sh`：验证不同 label/state 下的编辑、`retry`、`continue`、close、supersede 决策。
- 所有脚本运行 `/opt/homebrew/bin/bash -n`。
- OpenClaw 部署后运行无副作用冒烟：要求 agent 回答身份和 skill，不调用 GitLab。

## 部署验收

部署命令：

```bash
openclaw agents add git_issuer --workspace /Users/yuanchenxiang/IdeaProjects/MyOpenClawAgents/workspace-git_issuer --non-interactive --json
```

验收：

- `openclaw agents list` 出现 `git_issuer`。
- `openclaw skills info git_issue_intake --agent git_issuer` 为 Ready。
- `openclaw agent --agent git_issuer` 无副作用冒烟成功。
- fake `glab` 测试全部通过。

## 风险与约束

- 若需求文本没有项目别名，必须失败回传，不能猜。
- 若 GitLab token 未配置，真实创建/变更失败，但 fake 测试仍可跑。
- `req_dispatcher` 的跨 agent spawn/回调原语仍待最终对齐；`git_issuer` 只保证最后一行 JSON 契约。
- 新增 `workspace-git_issuer/` 后，需要按仓库规则在主 skill 文件写入 `SKILL_VERSION=2026-06-30.1`。
