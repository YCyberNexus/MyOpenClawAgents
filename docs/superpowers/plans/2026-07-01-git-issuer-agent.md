# git_issuer Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建 `workspace-git_issuer/`，实现 `git_issuer` OpenClaw agent，并部署到本机 OpenClaw。

**Architecture:** `git_issuer` 是一个配置驱动的 OpenClaw agent。LLM 负责判定 CREATE/CHANGE/CANCEL/SUPERSEDE 与提取文本，shell 脚本负责 project 别名匹配、`glab` 操作和紧凑 JSON 回调输出。project 解析只允许命中 `project_routing.env`，不允许模型猜测。

**Tech Stack:** OpenClaw workspace Markdown contracts, AgentSkill `SKILL.md`, GNU bash 5.3, `jq`, `glab`, fake `glab` shell tests.

## Global Constraints

- 只新增 `workspace-git_issuer/` 和本计划文件，不改动已有 `workspace-req_dispatcher/` 未提交内容。
- 不运行 `rm` 命令。
- 所有手工文件编辑使用 `apply_patch`。
- 所有 GitLab 操作只通过 `glab`，不使用 `curl`、`wget`、HTTP 库或 GitLab SDK。
- 本地测试必须使用 fake `glab`，不得创建真实 GitLab issue。
- `workspace-git_issuer/skills/git_issue_intake/SKILL.md` 必须包含 `SKILL_VERSION=2026-07-01.1`。
- 实现后必须运行 shell 语法检查、fake `glab` 测试、OpenClaw skill 可见性检查和无副作用 agent 冒烟。

---

## File Structure

- Create: `workspace-git_issuer/AGENTS.md`，workspace 说明和 agent 身份。
- Create: `workspace-git_issuer/CLAUDE.md`，开发与部署约束。
- Create: `workspace-git_issuer/SOUL.md`，agent 角色、边界和 no-fallback 规则。
- Create: `workspace-git_issuer/USER.md`，用户使用契约。
- Create: `workspace-git_issuer/config/gitlab.env`，GitLab host/token/entry label/state pin。
- Create: `workspace-git_issuer/config/project_routing.env`，project 与别名映射。
- Create: `workspace-git_issuer/config/README.md`，配置说明。
- Create: `workspace-git_issuer/docs/GIT_ISSUER_USAGE.md`，使用说明。
- Create: `workspace-git_issuer/skills/git_issue_intake/SKILL.md`，唯一 skill。
- Create: `workspace-git_issuer/skills/git_issue_intake/references/callback_contract.md`，回调 JSON 契约。
- Create: `workspace-git_issuer/skills/git_issue_intake/references/trigger_contract.md`，输入文本与脚本调用契约。
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/env_paths.sh`，配置加载、路径、project URI 派生和 `glab` 鉴权。
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/emit_callback.sh`，统一输出紧凑 JSON。
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/parse_project.sh`，配置别名匹配。
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/create_issue.sh`，创建 issue、加入口标签、可选写 `req_origin`。
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/update_issue.sh`，变更/撤销/supersede issue。
- Create: `workspace-git_issuer/skills/git_issue_intake/tests/test_parse_project.sh`，project 解析测试。
- Create: `workspace-git_issuer/skills/git_issue_intake/tests/test_create_issue_fake_glab.sh`，创建 issue fake `glab` 测试。
- Create: `workspace-git_issuer/skills/git_issue_intake/tests/test_update_issue_fake_glab.sh`，变更 issue fake `glab` 测试。

## Task 1: Workspace Skeleton

**Files:**
- Create: `workspace-git_issuer/AGENTS.md`
- Create: `workspace-git_issuer/CLAUDE.md`
- Create: `workspace-git_issuer/SOUL.md`
- Create: `workspace-git_issuer/USER.md`
- Create: `workspace-git_issuer/config/gitlab.env`
- Create: `workspace-git_issuer/config/project_routing.env`
- Create: `workspace-git_issuer/config/README.md`
- Create: `workspace-git_issuer/docs/GIT_ISSUER_USAGE.md`
- Create: `workspace-git_issuer/skills/git_issue_intake/SKILL.md`
- Create: `workspace-git_issuer/skills/git_issue_intake/references/callback_contract.md`
- Create: `workspace-git_issuer/skills/git_issue_intake/references/trigger_contract.md`

**Interfaces:**
- Consumes: confirmed spec `docs/superpowers/specs/2026-06-30-git-issuer-agent-design.md`.
- Produces: OpenClaw-visible workspace and skill `git_issue_intake`.

- [x] **Step 1: Create contracts and config**

Write the workspace files with:

```text
Agent name: git_issuer
Session: agent:git_issuer:main
Skill: git_issue_intake
Project parsing: config/project_routing.env only; no guessing
GitLab access: glab only
Callback: final line compact JSON
```

- [x] **Step 2: Verify skill metadata**

Run:

```bash
rg -n "SKILL_VERSION=2026-07-01.1|name: git_issue_intake|agent:git_issuer:main" workspace-git_issuer
```

Expected: matches in `SKILL.md`, `AGENTS.md`, `SOUL.md`, and `USER.md`.

## Task 2: Project Parsing

**Files:**
- Create: `workspace-git_issuer/skills/git_issue_intake/tests/test_parse_project.sh`
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/emit_callback.sh`
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/parse_project.sh`

**Interfaces:**
- Consumes: `ROUTING_FILE`, `REQUIREMENT_TEXT`.
- Produces: compact JSON with `status`, `project`, `group`, `project_slug`, `matched`, `reason`.

- [x] **Step 1: Write failing parse tests**

Test cases:

```bash
REQUIREMENT_TEXT="请在 ifp 项目创建登录测试需求" bash scripts/parse_project.sh
REQUIREMENT_TEXT="请在 px_ifp_hulat_test 创建需求" bash scripts/parse_project.sh
REQUIREMENT_TEXT="项目 claw_gitlab/px_ifp_hulat_test 需要新增用例" bash scripts/parse_project.sh
REQUIREMENT_TEXT="完全未知项目" bash scripts/parse_project.sh
```

Expected:

```json
{"status":"success","project":"claw_gitlab/px_ifp_hulat_test","group":"claw_gitlab","project_slug":"px_ifp_hulat_test","matched":"ifp","reason":null}
{"status":"failed","project":null,"group":null,"project_slug":null,"matched":null,"reason":"无法从需求文本解析出目标 project"}
```

- [x] **Step 2: Run test and verify RED**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_parse_project.sh
```

Expected: fails because `parse_project.sh` does not exist.

- [x] **Step 3: Implement parser**

Implementation rules:

```text
Routing line format: full/group_project|alias1,alias2
Ignore empty and # lines
Match full project, slug after final slash, and aliases as fixed substrings
Unknown project returns failed JSON and exit 0
Malformed routing line returns failed JSON and exit 2
```

- [x] **Step 4: Verify GREEN**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_parse_project.sh
```

Expected: prints `ok parse_project`.

## Task 3: Create Issue

**Files:**
- Create: `workspace-git_issuer/skills/git_issue_intake/tests/test_create_issue_fake_glab.sh`
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/env_paths.sh`
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/create_issue.sh`

**Interfaces:**
- Consumes: `PROJECT_FULL`, `ISSUE_TITLE`, `ISSUE_DESCRIPTION`, optional `ORIGIN_JSON`, `DEFAULT_ENTRY_LABEL`, `GITLAB_TOKEN`.
- Produces: `created` callback JSON compatible with `req_dispatcher`.

- [x] **Step 1: Write failing fake glab test**

Fake `glab` should return:

```json
{"iid":312,"web_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312"}
```

The test asserts:

```text
glab auth login is called with pinned host
glab api --method POST projects/<encoded>/issues is called
glab api --method PUT projects/<encoded>/issues/312 -f add_labels=todo is called
callback JSON has status=success action=created issue_iid=312 entry_label=todo
```

- [x] **Step 2: Run test and verify RED**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_create_issue_fake_glab.sh
```

Expected: fails because `create_issue.sh` does not exist.

- [x] **Step 3: Implement env and create script**

Use only:

```bash
glab auth login --hostname "${GITLAB_HOST}" --token "${GITLAB_TOKEN}" --api-protocol "${GITLAB_API_PROTOCOL}"
glab auth status --hostname "${GITLAB_HOST}"
glab api --method POST "projects/${PROJECT_URI}/issues" -f "title=${ISSUE_TITLE}" -F "description=@${DESCRIPTION_FILE}"
glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -f "add_labels=${DEFAULT_ENTRY_LABEL}"
glab api --method POST "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" -F "body=@${BODY_FILE}"
```

- [x] **Step 4: Verify GREEN**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_create_issue_fake_glab.sh
```

Expected: prints `ok create_issue fake glab`.

## Task 4: Update Issue

**Files:**
- Create: `workspace-git_issuer/skills/git_issue_intake/tests/test_update_issue_fake_glab.sh`
- Create: `workspace-git_issuer/skills/git_issue_intake/scripts/update_issue.sh`

**Interfaces:**
- Consumes: `PROJECT_FULL`, `ISSUE_IID`, `CHANGE_ACTION`, `ISSUE_DESCRIPTION`, optional `RERUN_LABEL`.
- Produces: callback JSON with `action` in `updated`, `updated+relabeled`, `closed`, or `superseded`.

- [x] **Step 1: Write failing fake glab test**

Test fake issue states:

```json
{"state":"opened","labels":["todo"],"web_url":"http://example/312"}
{"state":"opened","labels":["doing"],"web_url":"http://example/313"}
{"state":"opened","labels":["pr"],"web_url":"http://example/314"}
```

Assertions:

```text
todo issue is edited without retry/continue
doing issue with RERUN_LABEL=retry edits description and adds retry
pr issue with RERUN_LABEL=continue edits description and adds continue
cancel action posts close state_event and action=closed
```

- [x] **Step 2: Run test and verify RED**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_update_issue_fake_glab.sh
```

Expected: fails because `update_issue.sh` does not exist.

- [x] **Step 3: Implement update script**

Use only:

```bash
glab api "projects/${PROJECT_URI}/issues/${ISSUE_IID}"
glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -F "description=@${DESCRIPTION_FILE}"
glab api --method POST "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" -F "body=@${BODY_FILE}"
glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -f "add_labels=${RERUN_LABEL}"
glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -f "state_event=close"
```

Reject any `RERUN_LABEL` except `retry` or `continue`.

- [x] **Step 4: Verify GREEN**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_update_issue_fake_glab.sh
```

Expected: prints `ok update_issue fake glab`.

## Task 5: Verification And Deployment

**Files:**
- Modify: local OpenClaw config via `openclaw agents add git_issuer --workspace /Users/yuanchenxiang/IdeaProjects/MyOpenClawAgents/workspace-git_issuer --non-interactive --json`

**Interfaces:**
- Consumes: completed `workspace-git_issuer/`.
- Produces: registered local OpenClaw agent `git_issuer`.

- [x] **Step 1: Run syntax checks**

Run:

```bash
for f in workspace-git_issuer/skills/git_issue_intake/scripts/*.sh workspace-git_issuer/skills/git_issue_intake/tests/*.sh; do /opt/homebrew/bin/bash -n "$f"; done
```

Expected: exit 0.

- [x] **Step 2: Run all local tests**

Run:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_parse_project.sh
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_create_issue_fake_glab.sh
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_update_issue_fake_glab.sh
```

Expected:

```text
ok parse_project
ok create_issue fake glab
ok update_issue fake glab
```

- [x] **Step 3: Register agent**

Run:

```bash
openclaw agents add git_issuer --workspace /Users/yuanchenxiang/IdeaProjects/MyOpenClawAgents/workspace-git_issuer --non-interactive --json
```

Expected: JSON with `"agentId":"git_issuer"`.

- [x] **Step 4: Verify OpenClaw skill**

Run:

```bash
openclaw skills info git_issue_intake --agent git_issuer
```

Expected: `git_issue_intake ✓ Ready`.

- [x] **Step 5: Run no-side-effect smoke**

Run:

```bash
openclaw agent --agent git_issuer --session-key agent:git_issuer:smoke --message '本地冒烟测试。不要调用脚本、不要访问 GitLab、不要 spawn 其它 agent。只回复 agent name 和唯一 skill。' --timeout 180 --json
```

Expected: response contains `git_issuer` and `git_issue_intake`.

## Self-Review

- Spec coverage: tasks cover workspace, config, skill, scripts, tests, and deployment.
- Placeholder scan: no unresolved placeholder markers or open-ended implementation steps.
- Type consistency: JSON fields match callback contract: `status`, `action`, `issue_iid`, `issue_url`, `project`, `entry_label`, `superseded_by`, `reason`, `correlation_id`.
