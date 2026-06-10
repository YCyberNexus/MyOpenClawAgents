# 环境 Precheck 清单填写指南

> 面向接入自动化测试 agent 的**项目团队**。读完按「你需要做什么」准备一份清单文件即可。

## 一、这是什么

自动化测试 agent 每一轮开始跑批前,会先对运行环境做一次「就绪检查」(precheck):
按你们提供的清单,逐项确认**项目依赖的外部服务能否连通、需要的命令/环境变量/文件是否就位**。

- 检查**全部通过** → 正常跑批。
- 有 `required`(必需)项**不通过** → 本轮**跳过跑批**,并在受影响的 issue 上打一个红色
  `precheck-failed` 标记,方便你们一眼看到「这批因为环境没就绪没能跑」。环境修好后,下一轮
  自动重试,issue 开始处理时该标记会自动消失。
- `optional`(可选)项不通过 → 只记录告警,**不影响**跑批。

这样可以避免「环境其实没准备好,却白白跑了一整批、报错还散落在各处」的情况。

## 二、你需要做什么

1. 在**项目仓库**里放一个 JSON 清单文件,推荐路径 `hulat/precheck.json`(也可放别的位置)。
2. 把这个文件的**相对路径**告诉我们(我们会配置到调度参数 `precheck_relpath`)。
3. 后续依赖有变化时,直接改这个文件即可,无需联系我们。

> 没配置或文件还没放?——没关系,系统会**自动跳过** precheck,功能向后兼容,可以先接入再补清单。

## 三、清单格式

一个 JSON 文件,顶层按**四类**分组,每类是一个数组。**用不到的类可以省略。**

```json
{
  "version": 1,
  "urls":     [ /* 服务连通性 */ ],
  "commands": [ /* 命令是否存在 */ ],
  "env_vars": [ /* 环境变量是否设置 */ ],
  "files":    [ /* 文件/目录是否存在 */ ]
}
```

每一条都有两个公共字段:

| 字段 | 是否必填 | 说明 |
| --- | --- | --- |
| `name` | 必填 | 给这条检查起个好认的名字,只用于报告展示(例如 `backend-api`、`java-home`) |
| `severity` | 可选 | `required`(必需,**缺省即此值**)或 `optional`(可选)。`required` 不通过会跳过本轮跑批;`optional` 只告警 |

### 1. `urls` —— 服务连通性

检查项目依赖的外部服务**能否连得上**。

| 字段 | 说明 |
| --- | --- |
| `url` | 必须带前缀:`http://主机[:端口]`(默认端口 80)、`https://主机[:端口]`(默认端口 443)、`tcp://主机:端口`(端口必填,用于数据库/redis 等非 HTTP 服务) |

```json
{ "name": "backend-api",    "url": "https://api.example.com",        "severity": "required" }
{ "name": "artifact-repo",  "url": "https://nexus.example.com:8081", "severity": "required" }
{ "name": "local-postgres", "url": "tcp://localhost:5432",           "severity": "optional" }
```

注意:
- **只检查 TCP 能否连通**(能否建立连接),**不会发送 HTTP 请求、不看返回状态码、不校验证书**。
  `https://` 仅用来推断默认端口 443。
- 带超时与重试,能抵抗瞬时网络抖动。
- 主机请写**裸主机名或 IPv4**,**不支持** `user:pass@host` 这种带账号的写法,也不支持 IPv6
  字面量 `[::1]`(会被判为格式错误)。

### 2. `commands` —— 命令是否存在

检查跑批所需的命令是否在 `PATH` 中。

| 字段 | 说明 |
| --- | --- |
| `bin` | 可执行文件名 |

```json
{ "name": "node", "bin": "node", "severity": "required" }
{ "name": "java", "bin": "java", "severity": "required" }
{ "name": "mvn",  "bin": "mvn",  "severity": "optional" }
```

> 只检查「是否存在」,不检查版本号。

### 3. `env_vars` —— 环境变量是否设置

检查需要的环境变量是否**已设置且非空**。

| 字段 | 说明 |
| --- | --- |
| `var` | 环境变量名 |

```json
{ "name": "java-home", "var": "JAVA_HOME",       "severity": "required" }
{ "name": "api-key",   "var": "EXAMPLE_API_KEY", "severity": "optional" }
```

注意:
- **只判断「有没有设置、是不是空」,绝不会读取或记录变量的值**(敏感信息安全)。
- 只能看到**运行机器上全局生效的环境变量**(例如 `JAVA_HOME`)。如果某个变量是在更靠后的环节
  才注入的,这里可能看不到 —— 这类变量**不要**放进 `env_vars`,否则会被误判为缺失。

### 4. `files` —— 文件/目录是否存在

检查依赖的配置文件、证书、数据目录等是否就位。

| 字段 | 说明 |
| --- | --- |
| `path` | 绝对路径直接用;相对路径相对**项目仓库根目录** |
| `kind` | `file`(必须是文件)/ `dir`(必须是目录)/ `any`(存在即可,**缺省值**) |

```json
{ "name": "knowledge-base", "path": "ifp-data",         "kind": "dir",  "severity": "required" }
{ "name": "tls-cert",       "path": "/etc/ssl/app.pem", "kind": "file", "severity": "optional" }
```

## 四、`required` 还是 `optional`?

- **`required`(必需)**:缺了它项目根本跑不起来 → 不通过就跳过本轮跑批,逼着先把环境修好。
  例如核心后端 API、构建必需的 `java`/`node`、必备配置文件。
- **`optional`(可选)**:缺了会降级但不致命 → 不通过只告警,跑批照常。
  例如可选的镜像加速源、非关键的辅助工具。

不确定时,**倾向写 `required`**(更安全,缺省也是它)。

## 五、完整模板(直接拷贝改写)

把下面内容存成 `hulat/precheck.json`,按你们项目的实际依赖增删每一项即可:

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

## 六、提交清单后会发生什么

| 情况 | 结果 |
| --- | --- |
| 全部 `required` 通过(`optional` 可有不通过) | 正常跑批 |
| 有 `required` 不通过 | 跳过本轮跑批;受影响 issue 打 `precheck-failed` 标记;下一轮自动重试 |
| 清单 JSON 写错了(格式非法) | 同上(跳过 + 打标记),请检查 JSON 语法 |
| 清单文件还没放 / 没配置 | 自动跳过 precheck,正常跑批 |

`precheck-failed` 标记只是「本轮因环境未就绪没跑」的提示:它不会消耗重试次数,也不影响其他流程,
环境修好、issue 开始被处理时会自动清除。

## 七、常见问题

- **Q:清单写错会不会把 issue 弄坏?** 不会。最坏情况只是「跳过本轮 + 打个红标记」,改对清单后下轮恢复。
- **Q:能检查 HTTP 接口是不是返回 200 吗?** 当前只验 TCP 连通(能否连上),不看 HTTP 状态。
- **Q:能检查命令版本吗?** 暂不支持,只验「命令是否存在」。
- **Q:JSON 里能写注释吗?** 标准 JSON 不支持注释,请保持纯 JSON。

---

如需我们帮忙配置 `precheck_relpath` 或排查 `precheck-failed`,把清单路径和最近一次的提示发给我们即可。
