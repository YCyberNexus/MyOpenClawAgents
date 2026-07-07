# Callback Contract

The deterministic issue scripts still emit one compact callback JSON object:

```json
{"status":"success|failed","action":"created|updated|relabeled|updated+relabeled|closed|superseded|none","issue_iid":312,"issue_url":"http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312","project":"claw_gitlab/px_ifp_hulat_test","entry_label":"todo","superseded_by":null,"reason":null,"correlation_id":null}
```

Fields:

- `status`: `success` or `failed`.
- `action`: `created`, `updated`, `relabeled`, `updated+relabeled`, `closed`, `superseded`, or `none`.
- `issue_iid`: positive integer on success where an issue exists, else `null`.
- `issue_url`: full GitLab issue URL on success where an issue exists, else `null`.
- `project`: full `<group>/<project>` on success, else `null`.
- `entry_label`: created or rerun label, else `null`.
- `superseded_by`: new issue IID when action is `superseded`, else `null`.
- `reason`: failure reason or `null`.
- `correlation_id`: always `null` unless a future runtime contract explicitly supplies one.

The agent's final response must pass that compact JSON to
`scripts/format_callback_output.sh`. The final response is blue-zone-style
Markdown: a short issue summary plus a fenced pretty JSON object. The JSON
keeps the compact callback fields at the top level for req_dispatcher
compatibility, and also includes a nested `req_dispatcher` object for the
blue-zone display shape.

Example final JSON block:

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
    "source": "req_dispatcher_wiki",
    "wiki_url": "http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements",
    "wiki_section": "登录流程",
    "wiki_item_ordinal": 7,
    "result": {
      "issue_iid": 312,
      "issue_url": "http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/issues/312",
      "title": "登录接口验收",
      "status": "created",
      "reason": null
    }
  }
}
```
