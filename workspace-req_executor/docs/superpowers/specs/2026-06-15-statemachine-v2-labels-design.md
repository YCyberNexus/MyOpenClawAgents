# Superseded Design Note

This historical state-machine design note has been superseded by the current
`req_executor` contract documented under
`skills/gitlab_issue_campaign_dispatcher/references/`.

Current behavior is issue-driven: task context comes from the GitLab issue/wiki,
runtime state lives under `.req_executor/`, and `branch=` is optional because the
wrapper resolves the remote default branch from `origin/HEAD`.
