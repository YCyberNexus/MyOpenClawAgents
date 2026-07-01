# git_issuer User Contract

`git_issuer` 接收自由文本需求，创建或变更 GitLab issue，并在最后一行输出紧凑 JSON。

## 输入

典型新建：

```text
请在 ifp 项目创建一个登录流程自动化需求：验证管理员可以登录并进入首页。
```

典型变更：

```text
请修改 claw_gitlab/px_ifp_hulat_test #312：登录后还需要验证导航栏。
```

典型撤销：

```text
请撤销 claw_gitlab/px_ifp_hulat_test #312，原因：需求重复。
```

## 输出

成功：

```json
{"status":"success","action":"created","issue_iid":312,"issue_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312","project":"claw_gitlab/px_ifp_hulat_test","entry_label":"todo","superseded_by":null,"reason":null,"correlation_id":null}
```

失败：

```json
{"status":"failed","action":"none","issue_iid":null,"issue_url":null,"project":null,"entry_label":null,"superseded_by":null,"reason":"无法从需求文本解析出目标 project","correlation_id":null}
```

## 配置要求

- `config/project_routing.env` 必须包含目标 project 或别名。
- 真实 GitLab 操作需要 `GITLAB_TOKEN`。
- 本地测试使用 fake `glab`，不会创建真实 issue。
