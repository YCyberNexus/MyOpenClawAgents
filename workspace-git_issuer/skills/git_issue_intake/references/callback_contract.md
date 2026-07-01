# Callback Contract

The final turn's final line must be one compact JSON object:

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
