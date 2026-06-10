# Precheck Manifest (`precheck_relpath`)

环境就绪 precheck 的清单契约。由**项目团队**维护,声明项目跑批前需要就绪的外部 URL、命令、
环境变量、文件/目录。dispatcher 每个调度 tick 在 `clone_or_pull.sh` 之后、batch 形成之后、
per-IID acpx 跑批之前据此做一次检查(`dispatch_prepare_tick.sh` §16b)。

可直接拷贝的模板见 [`precheck.example.json`](precheck.example.json)。

## 启用方式

- 通过 trigger 字段 `precheck_relpath` 启用,值是清单文件相对**项目 checkout 根**
  (`${REPO_PATH}`)的路径,例如 `precheck_relpath=hulat/precheck.json`。
- carry-forward 语义(同 `ui_accounts_relpath`):一旦设置即持久化进 `campaign_state.json`,
  后续 tick 省略该字段时从持久化状态恢复,直到某个 trigger 显式替换。
- opt-in:字段从未配置 → 整个 precheck 流程跳过(向后兼容)。
- 字段已配置但清单文件**不存在** → 跳过(`status:"skipped"`,exit 0),便于"先配字段、清单
  稍后补"的渐进迁移。

## 文件格式

JSON,顶层按类型分组,每组是一个数组。每组都可省略(缺省视为空数组)。

```json
{
  "version": 1,
  "urls":     [ /* TCP 连通性 */ ],
  "commands": [ /* PATH 中可执行文件 */ ],
  "env_vars": [ /* 环境变量存在性 */ ],
  "files":    [ /* 文件/目录存在性 */ ]
}
```

### 公共字段

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | 是 | 人类可读标识,用于证据文件与失败上报(出现在 chat_summary 的失败列表里) |
| `severity` | 否 | `required`(缺省)或 `optional`。`required` 失败 → abort 整个 tick;`optional` 失败 → 仅告警 |

### `urls[]` —— TCP 连通性

| 字段 | 说明 |
| --- | --- |
| `url` | 必须带 scheme:`http://host[:port]`(端口缺省 80)、`https://host[:port]`(端口缺省 443)、`tcp://host:port`(端口必填) |

- **只做 TCP 可达探测**(纯 bash `/dev/tcp`),验证"能否连得上",**不发送任何 HTTP 请求、不看
  状态码、不校验 TLS**。`https://` 仅用于推断默认端口 443。
- 探测带超时与重试(默认单次 5s、最多 3 次、间隔 2s),抵抗瞬时网络抖动。
- 本地服务(DB/redis 等)写成 `tcp://localhost:5432` 这种形式。
- 格式非法(无 scheme / `tcp://` 缺端口 / 端口非数字)→ 该条判 `fail`。

### `commands[]` —— 命令存在性

| 字段 | 说明 |
| --- | --- |
| `bin` | 在 `PATH` 中查找的可执行文件名(`command -v <bin>`) |

只验证"存在",不验证版本。

### `env_vars[]` —— 环境变量存在性

| 字段 | 说明 |
| --- | --- |
| `var` | 环境变量名 |

- **只验证已设置且非空**,**绝不读取/记录其值**(证据文件 detail 只写 `set and non-empty` /
  `unset or empty`)。
- **可见性边界(重要)**:precheck 在 dispatcher 进程里运行,只能看到 dispatcher/runner 进程
  环境里的变量(如全局的 `JAVA_HOME`)。若某个变量是后续才注入 acpx 子代理的(例如经
  `.claude/settings.json` 或子代理专属注入),dispatcher 层**看不到**——这类变量不要放进
  `env_vars`,否则会误判为缺失。只把"runner 全局环境变量"放进来。
- **Temporal 部署注意**:Temporal 路径下"runner 全局环境"指 **Temporal worker 进程**的
  环境(启动 worker 前 export 的变量);`run_environment_precheck` activity 会把 worker
  全量环境透传给 `precheck.sh`(契约变量覆盖优先)。`PRECHECK_TCP_*` 调优变量同样在
  worker 环境里设置。

### `files[]` —— 文件/目录存在性

| 字段 | 说明 |
| --- | --- |
| `path` | 绝对路径直接用;相对路径相对 `${REPO_PATH}` 解析 |
| `kind` | `file`(`-f`)/ `dir`(`-d`)/ `any`(`-e`,缺省) |

## 行为与退出码

| 情况 | dispatcher 反应 | precheck.sh 退出码 |
| --- | --- | --- |
| 清单缺失 | 跳过,tick 继续 | `0`(`status:"skipped"`) |
| 全部 `required` 通过(`optional` 可有失败) | tick 继续 | `0`(`status:"passed"`) |
| 至少一个 `required` 失败 | 给本 tick batch IID 打 `precheck-failed`,abort 整个 tick | `1`(`status:"failed"`) |
| 清单存在但 JSON 非法 | 给本 tick batch IID 打 `precheck-failed`,abort 整个 tick | `2`(`status:"manifest_error"`) |

- abort 与 `clone_or_pull_failed` / `ensure_labels_failed` 同一语义:本 tick 不再跑任何 acpx,
  下一个 tick 重试;环境修复后通过,并在 issue 进 `doing` 时自动清除 `precheck-failed`。
- `precheck-failed` 是 dispatcher 侧 tick 级可见标记:**不消耗 retry、不升级 model tier**
  (它不在 `resolve_model_tier` 的 hard 集 `{blocked-cc,timeout,failed-cc}`、也不触发 soft
  升级),可与任意工作流 label 共存,进 `doing` 时由 dispatcher 显式移除。详见
  [`label_lifecycle.md`](label_lifecycle.md)。

## 证据文件

每个 tick 写一份 `${RESULT_ROOT}/_dispatcher/log/precheck-<ts>.json`(同 `reconcile-<ts>.json`
约定):

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
    { "name": "mvn",         "type": "command", "severity": "optional", "result": "fail", "detail": "'mvn' not found in PATH" }
  ],
  "required_failures": []
}
```

## 探测调优(可选 env,一般无需设置)

| env | 默认 | 说明 |
| --- | --- | --- |
| `PRECHECK_TCP_TIMEOUT` | 5 | 单次 TCP 连接超时秒数 |
| `PRECHECK_TCP_RETRIES` | 3 | 每条 URL 最大尝试次数 |
| `PRECHECK_TCP_RETRY_INTERVAL` | 2 | 重试间隔秒数 |

## 设计约束

- 探测全程只用 bash 内置 `/dev/tcp` + `timeout` + `command -v` + `printenv` + 文件测试,
  **不引入 `curl`/`wget`/HTTP 库**,因此不触碰 SOUL.md / CLAUDE.md 的 no-curl 禁令。
- precheck 经 `env_paths.sh` 自举,会顺带做一次 `glab` 鉴权;若 GitLab 鉴权失败,会在 precheck.sh
  的 source 阶段就失败、表现为 precheck abort。运维排查时据此区分「GitLab 鉴权故障」与「真实环境
  就绪故障」(后者才会写出 `precheck-<ts>.json` 证据文件)。
- 不验证版本号、磁盘空间、可写性、HTTP 状态码(YAGNI;只验"存在"与"能否连通")。
