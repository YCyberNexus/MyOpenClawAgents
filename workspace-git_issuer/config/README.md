# git_issuer Config

## `gitlab.env`

- `gitlab.env` is runner-local secret material and is not committed. Use
  `gitlab.env.example` as the template for a new runner.
- `GITLAB_HOST`: pinned GitLab host, including port when needed.
- `GITLAB_API_PROTOCOL`: `http` or `https`.
- `GITLAB_TOKEN`: local runner token pin used by the intake scripts when no
  external token environment variable is provided. Treat it as secret material.
- `DEFAULT_ENTRY_LABEL`: label added after issue creation, usually `todo`.
- `STATE_ROOT`: persistent state/log root on the runner.

## `project_routing.env`

Each non-comment line maps one GitLab project to accepted aliases:

```text
claw_gitlab/px_ifp_hulat_test|px_ifp_hulat_test,ifp,hulat
```

`git_issuer` accepts only configured projects. If a requirement does not mention a configured full project, slug, or alias, it returns a failed callback JSON.
