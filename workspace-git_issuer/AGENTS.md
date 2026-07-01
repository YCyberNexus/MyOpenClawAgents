# git_issuer Workspace Notes

本工作区实现 `git_issuer`：104 OpenClaw 上“自由文本需求 → GitLab issue”的建单与变更 agent。它接收 `req_dispatcher` 透传的自由文本，按本 workspace 的配置解析目标 project，创建或变更 GitLab issue，并在最后一行输出 `req_dispatcher` 可解析的紧凑 JSON。

## Agent Identity

- Agent name: `git_issuer`
- 固定 session: `agent:git_issuer:main`
- 唯一 skill: `skills/git_issue_intake/`

## Core Rules

- Project 解析只允许使用 `config/project_routing.env` 的完整 project、slug 或别名；未命中必须失败回传，不允许模型凭语义猜 project。
- GitLab 访问只允许通过 `glab`，由 `scripts/` 封装；不得使用 `curl`、`wget`、HTTP 库或 GitLab SDK。
- 新建 issue 后必须打执行器入口标签，默认来自 `config/gitlab.env` 的 `DEFAULT_ENTRY_LABEL`。
- 变更 issue 时只允许按契约添加 `retry` 或 `continue`；不得添加 `doing`、`done`、`pr`、`blocked-*`、`failed-*`、`timeout`，不得改 `model:*` 或 `quality:low`。
- 最后一轮最后一行必须是单行紧凑 JSON，不加代码围栏，不加解释文字。

## Execution Model

`git_issuer` 没有子代理。它在固定 session 中处理一次输入，调用 `git_issue_intake` skill 下的脚本完成确定性工作：

- `parse_project.sh`：按配置别名解析 project。
- `create_issue.sh`：创建 GitLab issue，添加入口标签，可选写 `req_origin` note。
- `update_issue.sh`：编辑、重跑标签、关闭或 supersede 既有 issue。
- `emit_callback.sh`：输出统一回调 JSON。

## Deployment Pin

部署期配置在 `config/gitlab.env` 和 `config/project_routing.env`。`GITLAB_TOKEN` 可由环境变量注入，环境变量优先于配置文件。

## Local Testing

本地测试必须使用 fake `glab`，不得创建真实 GitLab issue。统一使用 `/opt/homebrew/bin/bash` 做语法检查和测试。
