# 设计:clone 后环境 precheck

- 日期:2026-06-09
- 状态:已批准设计,进入实现
- 关联代码:`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/`

## 1. 背景与目标

dispatcher 每个调度 tick 在 `dispatch_prepare_tick.sh` 的 tick-level prep(§13)里跑
`ensure_labels.sh` → `clone_or_pull.sh`,随后(§14)按需加载 UI 账号池,§15 过滤
`require_labels`,§16 形成 batch,§17 起做 per-IID prep 与 acpx 跑批。当前没有任何机制在
跑批前验证「环境是否就绪」:外部依赖 URL 不可达、构建工具缺失、必需 env var 未设置等问题,
要等 acpx 子代理实际跑起来才暴露,浪费整批跑批时间,且报错分散在各 IID 日志里、不利于项目
团队定位。

**目标**:由项目团队提供一份 precheck 清单(声明项目依赖的外部 URL、所需命令、env var、
文件/目录),dispatcher 在每个 tick 据此做一次环境就绪检查;`required` 项不满足则 fail-loud
abort 整个 tick、给本 tick 选中的 batch IID 打 `precheck-failed` label 并清晰上报,`optional`
项不满足只告警不阻塞。

**非目标**:不验证版本号、不验证磁盘空间/可写性、不做 HTTP 状态码/健康端点校验(只验 TCP
连通)、不引入任何新外部工具依赖、不改动 v2 工作流 label 的状态转移本身。

## 2. 设计决策汇总

| 维度 | 决策 |
| --- | --- |
| 触发时机 | 每个调度 tick 都跑;插在 batch 形成(§16)之后、per-IID prep(§17)之前,新增 §16b |
| 失败语义 | 分级:`required` 失败 → 给本 tick batch IID 打 `precheck-failed` → `emit_chat_failure` abort 整个 tick;`optional` 失败 → 仅 warn 并继续 |
| 清单发现 | 新 trigger 字段 `precheck_relpath`,carry-forward 持久化,opt-in;未配 或 文件不存在 → 跳过 precheck(不阻塞) |
| URL 探测 | 纯 bash `/dev/tcp` 做 TCP 可达探测(零外部依赖,不触碰 no-curl 禁令);只验证「能否连通」,不看 HTTP 状态 |
| 清单格式 | JSON,按类型分组:`urls` / `commands` / `env_vars` / `files`;用现成 `jq` 解析 |
| 清单位置(推荐) | `hulat/precheck.json`(test-team 维护区),由 `precheck_relpath` 指定 |
| issue label | 新增 `precheck-failed`;precheck 失败时打给本 tick batch IID,**不消耗 retry、不升级 model tier、下次进 doing 时清除**;不改动 v2 工作流 label 的状态转移 |

## 3. 触发器字段 `precheck_relpath`

- 语义与现有 `ui_accounts_relpath` 完全对齐:
  - **carry-forward**:一旦在某个 `RUN_SCHEDULED_ISSUE_CAMPAIGN` trigger 里设置,持久化进
    `campaign_state.json`,后续 tick 不带该字段时从持久化状态恢复,直到某个 trigger 显式替换。
  - 相对路径在**项目 checkout 根**下解析:`${REPO_PATH}/${precheck_relpath}`,**不**在
    `${REPO_PATH}/${DATA_BASENAME}/` 下。
  - opt-in:字段从未配置(trigger 与持久化状态都没有)→ 整个 precheck 流程跳过,行为与今天
    完全一致(向后兼容)。
- carry-forward 的 load/override/persist 合并逻辑放在 `dispatch_prepare_tick.sh`,与
  `result_basename` / `data_basename` / `ui_accounts_relpath` / `model_tiers` 同处一致。
  callback 路径(`dispatch_followup.sh`)只需把该字段一并持久化以保持 batch 内一致,
  **不在 callback 路径跑 precheck**。
- `env_paths.sh` 在 `PRECHECK_RELPATH` 非空时 derive `PRECHECK_FILE=${REPO_PATH}/${PRECHECK_RELPATH}`。

## 4. 清单 schema 与模板

按类型分组的 JSON。每组数组可省略(缺省为空)。`severity` 缺省视为 `required`(fail-loud 默认)。

```json
{
  "version": 1,
  "urls": [
    { "name": "backend-api",    "url": "https://api.example.com",        "severity": "required" },
    { "name": "artifact-repo",  "url": "https://nexus.example.com:8081", "severity": "required" },
    { "name": "local-postgres", "url": "tcp://localhost:5432",           "severity": "optional" }
  ],
  "commands": [
    { "name": "node", "bin": "node", "severity": "required" },
    { "name": "java", "bin": "java", "severity": "required" },
    { "name": "mvn",  "bin": "mvn",  "severity": "optional" }
  ],
  "env_vars": [
    { "name": "java-home", "var": "JAVA_HOME",       "severity": "required" },
    { "name": "api-key",   "var": "EXAMPLE_API_KEY", "severity": "optional" }
  ],
  "files": [
    { "name": "knowledge-base", "path": "ifp-data",         "kind": "dir",  "severity": "required" },
    { "name": "tls-cert",       "path": "/etc/ssl/app.pem", "kind": "file", "severity": "optional" }
  ]
}
```

字段约定:

- `version`:schema 版本,当前固定 `1`。
- 公共字段:`name`(人类可读标识,用于上报)、`severity`(`required` / `optional`,缺省 `required`)。
- `urls[].url`:必须带 scheme。支持:
  - `http://host[:port]` → 端口缺省 80
  - `https://host[:port]` → 端口缺省 443
  - `tcp://host:port` → 端口必填(用于 DB/redis 等非 HTTP 服务)
  - 只做 TCP 连通探测,不发送任何 HTTP 请求、不看状态码。格式非法(无 scheme / tcp 缺端口)→ 该条判 fail,`detail` 说明原因。
- `commands[].bin`:在 `PATH` 中查找的可执行文件名。
- `env_vars[].var`:环境变量名。**只验证已设置且非空,绝不读取/记录其值**(见 §9 安全)。
- `files[].path`:绝对路径直接用;相对路径相对 `${REPO_PATH}`。`files[].kind`:`file`(`-f`)/ `dir`(`-d`)/ `any`(`-e`,缺省)。

配套交付:

- `references/precheck_manifest.md`:逐字段说明 + 完整模板 + 探测语义 + 退出码表 + env 边界。
- `references/precheck.example.json`:可直接拷贝改写的模板。

## 5. 集成点:`dispatch_prepare_tick.sh` 新增 §16b

precheck 调用点放在 §16 batch 形成之后(此时 `BATCH_IIDS` 已知,失败能精确标记)、§17
allocate attempt(per-IID 重活的起点)之前。清单文件在已 clone 的仓库里(§13 `clone_or_pull.sh`
已跑过),此处可直接读。

```bash
# ─── 16b. Environment precheck (only when configured) ───
if [ -n "${PRECHECK_RELPATH}" ]; then
  PRECHECK_OUT="$(mktemp)"; chmod 600 "${PRECHECK_OUT}" 2>/dev/null || true
  set +e
  PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" \
    REPO_PARENT_PATH="${REPO_PARENT_PATH}" \
    RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" \
    PRECHECK_RELPATH="${PRECHECK_RELPATH}" \
    bash "${SCRIPT_DIR}/precheck.sh" >"${PRECHECK_OUT}" 2>&1
  PRECHECK_RC=$?
  set -e
  cat "${PRECHECK_OUT}" >>"${DISPATCHER_LOG_DIR}/wrapper.log"; rm -f "${PRECHECK_OUT}"
  if [ "${PRECHECK_RC}" -ne 0 ]; then
    # 给本 tick 选中的 batch IID 打 precheck-failed(可见性标记),再 abort 整个 tick。
    for iid in "${BATCH_IIDS[@]}"; do
      ISSUE_IID="${iid}" ... bash "${SCRIPT_DIR}/set_issue_label.sh" add precheck-failed \
        >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    done
    emit_chat_failure "precheck_failed (exit ${PRECHECK_RC}; batch=[${BATCH_IIDS[*]}]; see ${DISPATCHER_LOG_DIR}/precheck-<ts>.json)"
  fi
fi
```

- 未配 `precheck_relpath` → 整段跳过,行为与今天完全一致(向后兼容)。
- 失败时给 `BATCH_IIDS`(§16 选中、最多并发数个)逐个 `set_issue_label.sh add precheck-failed`,
  打 label 尽力而为(单个失败不阻断,`|| true`),随后统一 `emit_chat_failure` abort。
- precheck 失败 **不进入 §17 per-IID prep**,所以本 tick 不会写 `pending_subagents`、不增
  `retry_count`、不调 `resolve_model_tier`。
- 注:`set_issue_label.sh` 的最小 env 见 §6.5;实现时按现有调用点补齐(`PROJECT`/`GROUP`/
  `GITLAB_TOKEN`/`ISSUE_IID` 等)。

## 6. `precheck.sh` 脚本契约

### 6.1 入口与 env

- 顶部 `source env_paths.sh`(同其它脚本的自举模式)。
- 必需 env:`PRECHECK_RELPATH`(非空);经 `env_paths.sh` 间接需要 `PROJECT` / `GROUP` /
  `GITLAB_TOKEN` / `REPO_PARENT_PATH` / `RESULT_BASENAME` / `DATA_BASENAME` 等以 derive `REPO_PATH`。
  - 实现待核对:`precheck.sh` 不访问 GitLab,理论上不需要 glab 鉴权。若 `env_paths.sh` 自举
    强制 `glab_auth.sh` / `GITLAB_HOST`,则沿用现有脚本对此的处理方式(不新增逻辑)。
- 可选 env:`PRECHECK_TCP_TIMEOUT`(单次 TCP 连接超时秒数,默认 5)、`PRECHECK_TCP_RETRIES`
  (每条 URL 最大尝试次数,默认 3)、`PRECHECK_TCP_RETRY_INTERVAL`(重试间隔秒数,默认 2)。

### 6.2 控制流与退出码

| 情况 | 行为 | 退出码 |
| --- | --- | --- |
| `PRECHECK_FILE` 不存在 | 写一条 `status:"skipped"` 证据,正常返回 | `0` |
| 清单存在但 JSON 解析失败 | 写 `status:"manifest_error"` 证据 | `2` |
| 解析成功,所有 `required` 通过(`optional` 可能有失败,记 warn) | 写 `status:"passed"` 证据 | `0` |
| 解析成功,至少一个 `required` 失败 | 写 `status:"failed"` 证据 | `1` |

`dispatch_prepare_tick.sh` 把任何非 0(`1`/`2`)都当 abort,先打 label 再 `emit_chat_failure`。
`skipped` 与 `passed` 都是 `0`,tick 继续。

### 6.3 各类探测实现

- **URL**:从 `url` 解析 scheme/host/port → 重试循环(至多 `PRECHECK_TCP_RETRIES` 次,
  间隔 `PRECHECK_TCP_RETRY_INTERVAL` 秒):
  `timeout "${PRECHECK_TCP_TIMEOUT}" bash -c 'exec 3<>/dev/tcp/'"${host}/${port}"`。
  任一次成功即 pass;全部失败即 fail。重试用于抵抗瞬时网络抖动,避免每-tick 误判 abort 整批。
  - 依赖说明:`/dev/tcp` 是 bash 内置伪设备,故用 `bash -c`;`timeout` 来自 GNU coreutils
    (runner 已广泛使用 GNU 工具,假设可用)。两者都不属于 no-curl 禁令范围。
- **command**:`command -v "${bin}" >/dev/null 2>&1`。
- **env_var**:`[ -n "$(printenv -- "${var}")" ]`(只验已导出的环境变量;比 `${!var}` 间接展开更安全,且「已导出」正是 runner 全局变量的正确范围)。
- **file**:按 `kind` 用 `-f` / `-d` / `-e`;相对路径前缀 `${REPO_PATH}/`。

### 6.4 证据文件

写入 `${DISPATCHER_LOG_DIR}/precheck-<ts>.json`(`<ts>` 由 `date +%s` 生成),模式同
`reconcile-<ts>.json`:

```json
{
  "ts": 1749456000,
  "manifest_relpath": "hulat/precheck.json",
  "manifest_path": "/data/px_ifp_hulat/hulat/precheck.json",
  "status": "passed",
  "summary": {
    "required_total": 5, "required_passed": 5, "required_failed": 0,
    "optional_total": 3, "optional_passed": 2, "optional_failed": 1
  },
  "checks": [
    { "name": "backend-api", "type": "url",     "severity": "required", "result": "pass", "detail": "tcp api.example.com:443 reachable" },
    { "name": "java-home",   "type": "env_var", "severity": "required", "result": "pass", "detail": "set and non-empty" },
    { "name": "mvn",         "type": "command", "severity": "optional", "result": "fail", "detail": "not found in PATH" }
  ],
  "required_failures": []
}
```

- `detail` 对 env_var **只描述状态**(`set and non-empty` / `unset or empty`),**绝不含变量值**。
- `required_failures` 是失败的 `required` 项 `name` 列表,供 chat_summary 直接引用。

### 6.5 `set_issue_label.sh add precheck-failed` 调用

dispatcher 在 §16b 失败分支里对每个 batch IID 调用现有 `set_issue_label.sh add precheck-failed`。
按现有调用点补齐其最小 env(`PROJECT`/`GROUP`/`GITLAB_TOKEN`/`REPO_PARENT_PATH`/basenames/
`ISSUE_IID`)。`set_issue_label.sh` 需识别 `precheck-failed` 为合法 label。

## 7. `precheck-failed` label 语义

- **创建**:`ensure_labels.sh` 新增 `precheck-failed`(给一个区别于工作流 gray 的颜色,如红色
  `#d9534f`,在看板上醒目)。
- **何时打**:§16b precheck 失败时(`required` 检查失败,或清单非法 JSON —— 任何非 0 退出),打给本 tick 选中的 batch IID。
- **不消耗 retry**:precheck 失败属环境/基础设施问题,不增 `retry_count`(与 spawn launch
  失败的「不增 retry」精神一致)。
- **不升级 model tier**:`precheck-failed` 与 `blocked-dispatcher` / `failed-dispatcher` 同属
  dispatcher 侧,`resolve_model_tier` 的 UPGRADE 集**排除**它(更大的模型不会修复环境)。
  `resolve_model_tier` 读 prior live labels 时把 `precheck-failed` 当中性标记忽略。
- **何时清除**:纳入「进 doing 清除集」——issue 下次真正进 `doing`(意味着该 tick precheck
  已通过)时,`set_issue_label.sh` 的 doing 转换顺带移除 `precheck-failed`。无需人工清理。
- **不改变 eligibility**:`precheck-failed` 是附加可见标记,不改变 §15/§16 的候选判定;下个
  tick 该 IID 仍按其工作流 label 正常参与 batch,precheck 修复后即被重试。
- **与工作流 label 的关系**:`precheck-failed` 是 dispatcher 侧 tick 级标记,与单 IID 的
  `blocked-*` / `failed-*` / `timeout` 不冲突,可与任意工作流 label 共存,直到进 doing 被清除。

## 8. 失败语义与上报

- `required` 失败:先给 batch IID 打 `precheck-failed`,再 `emit_chat_failure`,chat_summary
  列出失败项名字与受影响 batch,例如
  `precheck_failed (2 required failed: backend-api, java-home; batch=[14 27]; see precheck-1749456000.json)`。
- abort 语义与 `clone_or_pull_failed` / `ensure_labels_failed` 一致:本 tick 不再跑任何 acpx,
  等下一个 tick 重试(若环境已修复则通过、并在进 doing 时清掉 `precheck-failed`)。
- `optional` 失败只进证据文件的 `summary` / `checks`,不影响退出码、不打 label、不进
  chat_summary 失败列表。

## 9. 安全与语义边界

- **env_var 值零泄漏**:precheck 只判断 env var 是否设置且非空,任何日志/证据文件/chat 输出都
  不含其值。
- **env_var 可见性边界(已知 limitation,文档显式标注)**:precheck 在 dispatcher 进程里跑,
  只能看到 dispatcher/runner 进程环境里的 env var(如全局的 `JAVA_HOME`)。若某些 env var 是
  后续才注入 acpx 子代理的,dispatcher 层可能看不到 —— 这类变量不适合放进 `env_vars` 清单。
  `references/precheck_manifest.md` 会写出这个边界。
- **no-curl 禁令不受影响**:全程只用 `/dev/tcp` + `timeout`,不引入 `curl`/`wget`/HTTP 库,
  因此 `SOUL.md` / `CLAUDE.md` 的 no-curl 禁令无需新增例外条款。

## 10. 文件改动清单

| 文件 | 改动 |
| --- | --- |
| `scripts/precheck.sh`(新) | 探测主体,契约见 §6 |
| `scripts/env_paths.sh` | `PRECHECK_RELPATH` 非空时 derive `PRECHECK_FILE` |
| `scripts/ensure_labels.sh` | 新建 `precheck-failed` label(红色) |
| `scripts/set_issue_label.sh` | 识别 `precheck-failed` 为合法 label;纳入「进 doing 清除集」 |
| `scripts/dispatch_prepare_tick.sh` | §16b 调用 + 失败给 batch 打 `precheck-failed` + abort;`precheck_relpath` carry-forward;`resolve_model_tier` 排除 `precheck-failed` |
| `scripts/dispatch_followup.sh` | 仅把 `precheck_relpath` 一并持久化(callback 路径不跑 precheck) |
| `references/precheck_manifest.md`(新) | schema 逐字段说明 + 模板 + 探测语义 + 退出码表 + env 边界 |
| `references/precheck.example.json`(新) | 可拷贝模板 |
| `references/trigger_command.md` | 加 `precheck_relpath` 字段(carry-forward 表) |
| `references/paths.md` | precheck 证据文件路径 `precheck-<ts>.json` |
| `references/state_schema.md` | `campaign_state.json.precheck_relpath` 持久化字段 |
| `references/label_lifecycle.md` | `precheck-failed` 语义(打/清/不升 tier/不耗 retry) |
| `SKILL.md` | tick-level prep / §16b 加 precheck 步骤;`precheck-failed` 说明;**bump `SKILL_VERSION`** |
| `CLAUDE.md`(根) | 同步架构描述(辅助文档,不触发 version bump);进 doing 清除集补 `precheck-failed` |

> 注:除 `CLAUDE.md`、`docs/` 外,本次改动全部落在 `workspace-acpx_auto_tester/` 下,触发项目
> Stop hook 的强制 code review,且需在同一提交里 bump `SKILL_VERSION`。

## 11. 测试计划

- 每个改动脚本 `bash -n scripts/<name>.sh`。
- 手测 `precheck.sh` 五种用例的退出码与证据文件:
  1. 全 `required` 通过(含若干 `optional` 失败)→ exit 0,`status:"passed"`。
  2. 至少一个 `required` 失败 → exit 1,`status:"failed"`,`required_failures` 非空。
  3. 坏 JSON 清单 → exit 2,`status:"manifest_error"`。
  4. 清单文件缺失 → exit 0,`status:"skipped"`。
  5. URL 瞬时不可达但重试内恢复 → pass(验证重试逻辑)。
- 验证 env_var 探测**不**把值写进证据文件/日志。
- 验证 `ensure_labels.sh` 能创建 `precheck-failed`;`set_issue_label.sh add precheck-failed`
  幂等;进 doing 转换会清除 `precheck-failed`。
- 按 `CLAUDE.md` 走 `code-reviewer` 子代理审查循环(最多 3 轮)。

## 12. 实现顺序建议

1. `precheck.sh` + `references/precheck_manifest.md` + `precheck.example.json`(自包含,可独立手测)。
2. `env_paths.sh` derive `PRECHECK_FILE`。
3. `ensure_labels.sh` + `set_issue_label.sh`(新 label 创建 + 进 doing 清除集 + 合法性)。
4. `dispatch_prepare_tick.sh` §16b 集成 + carry-forward + `resolve_model_tier` 排除;
   `dispatch_followup.sh` 持久化。
5. 文档:`trigger_command.md` / `paths.md` / `state_schema.md` / `label_lifecycle.md` /
   `SKILL.md`(含 version bump) / `CLAUDE.md`。
6. `bash -n` 全量 + 手测用例 + code review 循环。
