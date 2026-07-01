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
