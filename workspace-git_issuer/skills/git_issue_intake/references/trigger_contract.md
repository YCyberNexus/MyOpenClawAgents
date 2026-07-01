# Trigger Contract

`git_issuer` receives free text. The preferred upstream payload is:

```text
<requirement text>
```

Optional origin metadata may appear in the text as a JSON object line:

```text
origin={"channel":"wecom","user":"user-123","conversation":"conv-456","reply_agent":"wecom_receiver"}
```

The agent may pass that JSON to `create_issue.sh` as `ORIGIN_JSON`. When present, `create_issue.sh` writes a hidden issue note:

```text
<!-- req_origin v1 {"channel":"wecom","user":"user-123","conversation":"conv-456","reply_agent":"wecom_receiver"} -->
```

For change requests, the text must include `#<iid>` or an issue URL. If no issue reference is present, the agent should treat the input as CREATE.
