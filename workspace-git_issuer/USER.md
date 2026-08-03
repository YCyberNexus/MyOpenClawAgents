# git_issuer User Contract

`git_issuer` 接收自由文本需求，创建或变更 GitLab issue，并输出蓝区样式的 Markdown 摘要和 fenced pretty JSON。

## 输入

典型新建：

```text
请在 ifp 项目创建一个登录流程自动化需求：验证管理员可以登录并进入首页。
```

如果明确指定“基于 `release/x` 分支处理”，建单脚本会把该安全 Git ref 保存为版本化机器 marker。
之后执行请求未另行指定分支时，req_executor 会基于 `release/x` 创建工作树并让 MR 目标跟随该分支；
执行请求中的显式分支仍具有更高优先级。
后续仅修改 Issue 描述时会保留该 marker；明确改为其他基准分支时替换 marker，只有明确要求取消
基准分支关联时才清除它。supersede 创建的替代 Issue 默认继承原 Issue 的 marker。

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
{
  "status": "success",
  "action": "created",
  "issue_iid": 312,
  "issue_url": "http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312",
  "project": "claw_gitlab/px_ifp_hulat_test",
  "entry_label": "todo",
  "superseded_by": null,
  "reason": null,
  "correlation_id": null,
  "req_dispatcher": {
    "action": "create_issue",
    "repo": "claw_gitlab/px_ifp_hulat_test",
    "source": "req_dispatcher",
    "wiki_url": null,
    "wiki_section": null,
    "wiki_item_ordinal": null,
    "result": {
      "issue_iid": 312,
      "issue_url": "http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312",
      "title": "登录流程自动化需求",
      "status": "created",
      "reason": null
    }
  }
}
```

失败：

```json
{
  "status": "failed",
  "action": "none",
  "issue_iid": null,
  "issue_url": null,
  "project": null,
  "entry_label": null,
  "superseded_by": null,
  "reason": "无法从需求文本解析出目标 project",
  "correlation_id": null,
  "req_dispatcher": {
    "action": "none",
    "repo": null,
    "source": "req_dispatcher",
    "wiki_url": null,
    "wiki_section": null,
    "wiki_item_ordinal": null,
    "result": {
      "issue_iid": null,
      "issue_url": null,
      "title": null,
      "status": "failed",
      "reason": "无法从需求文本解析出目标 project"
    }
  }
}
```

## 配置要求

- `config/project_routing.env` 必须包含目标 project 或别名。
- 真实 GitLab 操作需要 `GITLAB_TOKEN`。
- 本地测试使用 fake `glab`，不会创建真实 issue。
