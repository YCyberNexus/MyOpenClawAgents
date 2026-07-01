# git_issuer Usage

`git_issuer` creates or changes GitLab issues from free-text requirements.

## Create

```text
请在 ifp 项目创建需求：验证管理员登录后能进入首页。
```

Expected final-line callback:

```json
{"status":"success","action":"created","issue_iid":312,"issue_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312","project":"claw_gitlab/px_ifp_hulat_test","entry_label":"todo","superseded_by":null,"reason":null,"correlation_id":null}
```

## Change

```text
请修改 claw_gitlab/px_ifp_hulat_test #312：登录后还需要验证导航栏。
```

`git_issuer` reads the issue state and labels, then edits the description and optionally adds `retry` or `continue`.

## Failure

Unknown projects fail:

```json
{"status":"failed","action":"none","issue_iid":null,"issue_url":null,"project":null,"entry_label":null,"superseded_by":null,"reason":"无法从需求文本解析出目标 project","correlation_id":null}
```
