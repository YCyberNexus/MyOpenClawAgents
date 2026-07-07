# 本机 GitLab / OpenClaw Agent Smoke

本机 GitLab 使用 Docker/Colima 运行，凭据保存在用户目录，不提交到仓库：

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env
```

已部署资源：

- GitLab URL: `http://localhost:8081`
- SSH 端口: `localhost:2222`
- Group: `claw_gitlab`
- Project: `claw_gitlab/px_ifp_hulat_test`
- Agent 用户: `openclaw_agent`
- 本地 repo parent: `/Users/yuanchenxiang/openclaw-local-data`

## 基础健康检查

```bash
docker ps --filter name=openclaw-local-gitlab --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

source /Users/yuanchenxiang/.openclaw-local-gitlab/env
curl -sS --fail --header "PRIVATE-TOKEN: ${AGENT_PAT}" \
  "${GITLAB_URL}/api/v4/user" | jq -r '{username,state}'

GITLAB_HOST="${GITLAB_HOST}" \
GITLAB_TOKEN="${AGENT_PAT}" \
  glab api projects/claw_gitlab%2Fpx_ifp_hulat_test |
  jq -r '{path_with_namespace,web_url,default_branch}'
```

本机实例已在容器内 `/etc/gitlab/gitlab.rb` 设置：

```ruby
puma['per_worker_max_memory_mb'] = 3072
```

该配置用于避免 QEMU/Colima 下 Puma RSS 触发默认约 1.2GB 的内存 watchdog，
导致短时间 502。

## git_issuer 创建 issue

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env

GITLAB_HOST="${GITLAB_HOST}" \
GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}" \
GITLAB_TOKEN="${AGENT_PAT}" \
DEFAULT_ENTRY_LABEL=todo \
PROJECT_FULL="${PROJECT_FULL}" \
ISSUE_TITLE='本地 GitLab 验证 issue' \
ISSUE_DESCRIPTION='用于验证 git_issuer 能在本机 GitLab 创建 issue，并打上 todo 标签。' \
ORIGIN_JSON='{"channel":"local","user":"codex","reply_agent":"local"}' \
bash workspace-git_issuer/skills/git_issue_intake/scripts/create_issue.sh
```

## req_dispatcher wiki intake

该 smoke 验证新入口：智伴给 req_dispatcher 一个 GitLab wiki URL，dispatcher 只读拉取
wiki 文档、拆分需求、生成多条 `git_issuer` 建单 payload。真实建 issue 仍由
`git_issuer` 完成。

本机只把覆盖写到 ignored local env：

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env

cat > workspace-req_dispatcher/config/dispatcher.local.env <<EOF
STATE_ROOT=/Users/yuanchenxiang/openclaw-local-data/req_dispatcher
WIKI_GITLAB_HOST=${GITLAB_HOST}
WIKI_GITLAB_API_PROTOCOL=${GITLAB_API_PROTOCOL}
WIKI_GITLAB_TOKEN=${AGENT_PAT}
DEFAULT_EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DOWNSTREAM_AGENT_TIMEOUT_SECONDS=120
RUN_AGENT_TURN_HEARTBEAT_SECONDS=10
EOF
```

创建或更新一个本地 wiki 页面：

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env
export GITLAB_HOST="${GITLAB_HOST}"
export GITLAB_TOKEN="${AGENT_PAT}"

PROJECT_URI="$(printf '%s' "${PROJECT_FULL}" | sed 's#/#%2F#g')"
WIKI_CONTENT="$(cat <<'EOF'
## 登录流程
实现登录页忘记密码入口。

## 导出流程
支持按筛选条件导出 CSV。
EOF
)"

glab api --method POST "projects/${PROJECT_URI}/wikis" \
  -f title='req-dispatcher-wiki-smoke' \
  -f content="${WIKI_CONTENT}" || \
glab api --method PUT "projects/${PROJECT_URI}/wikis/req-dispatcher-wiki-smoke" \
  -f content="${WIKI_CONTENT}"
```

用脚本验证 wiki fetch + split：

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env
cd /Users/yuanchenxiang/IdeaProjects/MyOpenClawAgents/workspace-req_dispatcher/skills/requirement_dispatch
source scripts/source_dispatcher_env.sh

MESSAGE="${GITLAB_URL}/${PROJECT_FULL}/-/wikis/req-dispatcher-wiki-smoke" \
FETCH_WIKI=1 \
bash scripts/prepare_wiki_downstream_payloads.sh | jq '{status, project, count:(.requirements|length), titles:[.requirements[].title]}'
```

预期输出里 `status` 是 `success`，`project` 是本地 `${PROJECT_FULL}`，`count` 为 `2`。

真实 OpenClaw agent smoke：

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env

openclaw agent \
  --agent req_dispatcher \
  --session-id agent:req_dispatcher:main \
  --message "${GITLAB_URL}/${PROJECT_FULL}/-/wikis/req-dispatcher-wiki-smoke" \
  --timeout 1800 \
  --json
```

2026-07-03 本机验证结果：

- `req_dispatcher` 成功解析 wiki URL，拆出 2 条需求。
- `git_issuer` 在本机 GitLab 创建了 issue `#16`（登录流程）和 `#17`（导出流程）。
- 两条 issue 都路由到 `req_executor`，并生成 `RUN_SINGLE_ISSUE` handoff：
  `openclaw-req_executor-1783052334-87594` / `reqd-3`，
  `openclaw-req_executor-1783052504-88652` / `reqd-4`。
- dispatcher ledger 已 drain 两条 `git_issuer` success；pending 中保留两条 executor stage，等待执行器 I2 回调。
- 本机 gateway 仍提示 `scope upgrade pending approval`，但 embedded fallback 可完成 agent turn。
- 本机 `req_executor` 后续处理受执行器 GitLab host pin 影响；如果执行器报告蓝区 GitLab 从本机不可达，视为本机环境限制，不影响验证 `req_dispatcher -> git_issuer -> req_executor` handoff 边界。

## req_executor prepare tick

该 smoke 只验证 GitLab 认证、clone、reconcile、label transition 和 spawn payload 生成。
真正的 child spawn 由 OpenClaw runtime 负责；本地直接调用 wrapper 时不要假装已 spawn。

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env
export GITLAB_HOST="${GITLAB_HOST}"
export GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}"
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:${PATH}"

bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh <<EOF
RUN_SCHEDULED_ISSUE_CAMPAIGN
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
project=${PROJECT}
group=${GROUP}
gitlab_token=${AGENT_PAT}
branch=master
dev_branch=dev
issue_iids=1
issue_min_iid=1
issue_max_iid=1
hourly_issue_quota=1
max_runtime_minutes=10
blocked_retry_limit=3
blocked_cooldown_ticks=1
max_concurrent_subagents=1
max_accounts_per_issue=1
acpx_timeout_seconds=60
run_timeout_seconds=180
stuck_after_minutes=5
repo_path=${REPO_PARENT_PATH}
result_basename=ifp-result
data_basename=ifp-data
EOF
```

如果本地没有实际执行 `sessions_spawn`，用受控 launch failure 收尾，避免留下 pending：

```bash
source /Users/yuanchenxiang/.openclaw-local-gitlab/env
export GITLAB_HOST="${GITLAB_HOST}"
export GITLAB_API_PROTOCOL="${GITLAB_API_PROTOCOL}"
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:${PATH}"

PROJECT="${PROJECT}" \
GROUP="${GROUP}" \
GITLAB_TOKEN="${AGENT_PAT}" \
IID=1 \
ATTEMPT_NUMBER=1 \
STATUS=launch_failed \
LAUNCH_ATTEMPTS=1 \
LAUNCH_ERROR='local smoke test: spawn intentionally not invoked' \
REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
RESULT_BASENAME=ifp-result \
DATA_BASENAME=ifp-data \
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_record_spawn.sh
```

## acpx 状态

`acpx` 已安装在 `/opt/homebrew/bin/acpx`。`req_executor` 的真实运行路径固定为：

```bash
acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"
```

当前本机 Claude Code 已登录；如果直接运行 `acpx claude exec` 且没有继承用户
Claude 设置，仍可能报 `Authentication required`。`run_acpx_attempt.sh` 已默认设置
`ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1`，用于继承 `~/.claude/settings.json`
里的第三方模型和认证配置。

```bash
claude auth status
claude --print '只输出 OK'
ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1 \
  acpx --auth-policy skip --timeout 90 claude exec -f /tmp/openclaw-acpx-smoke.txt
```

当前验证输出为：

- `claude auth status` 返回 `loggedIn:true`、`authMethod:oauth_token`
- `claude --print ...` 返回 `OK`
- `ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1 acpx ... claude exec ...` 返回 `OK`

可选登录方式：

```bash
# Claude 订阅账号
claude auth login --claudeai

# Anthropic Console API 计费账号
claude auth login --console
```

这两个命令都会打开浏览器授权页，并在终端中等待 `Paste code here if prompted >`。
需要在同一个终端中粘贴浏览器授权页返回的 code，让 Claude Code 写入本机
`~/.claude` 登录状态。

登录或模型配置变更后先复测：

```bash
printf '只输出 OK\n' >/tmp/openclaw-acpx-smoke.txt
claude --print '只输出 OK'
ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1 \
  acpx --auth-policy skip --timeout 90 claude exec -f /tmp/openclaw-acpx-smoke.txt
```

这两条都成功后，再重跑 `workspace-req_executor/.../run_acpx_attempt.sh`。
