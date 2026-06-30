# Codex Project Rules

This file is for Codex-facing repository rules. Do not treat
`workspace-acpx_auto_tester/AGENTS.md` as Codex instructions; that file is part
of the deployed OpenClaw agent artifact.

## OpenClaw Three-Zone Network Memory

When reasoning about the company's OpenClaw architecture, use this network
zone model:

- Yellow zone: a fully external-isolated network environment. It can only open
  a small number of controlled egress paths to the blue zone.
- Blue zone: also largely isolated from the outside world. It can access
  external large-model services only through controlled channels.
- Green zone: a mostly open office network environment. It may access the
  internet under safe and compliant conditions.

OpenClaw blue-zone server addresses currently known for this project:

- `req_dispatcher`, `req_executor`, and `git_issuer` run on `10.64.5.104`.
- ZhiBan runs on `10.64.5.114`.
- Both `10.64.5.104` and `10.64.5.114` are company blue-zone servers.

## Destructive Command Restriction

Codex must not run `rm` in this repository, including `rm -f`, `rm -r`, or
`rm -rf`. Do not delete files or directories with shell commands. If cleanup is
needed, ask the user to do it manually or use a non-destructive archive/move
workflow after explicit approval.

## Skill Version Bump

Only changes under a `workspace-*` directory require a skill version bump.
Changes outside `workspace-*` directories do not require any agent version bump.

When Codex changes files under one or more `workspace-*` directories, bump only
the corresponding agent skill version for each touched workspace:

- `workspace-acpx_auto_tester/`:
  `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- `workspace-emcp/`:
  `workspace-emcp/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- `workspace-req_executor/`:
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- `workspace-req_dispatcher/`:
  `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`

If a new `workspace-*` directory is added, use that workspace's primary skill
file under `workspace-*/skills/*/SKILL.md`; if there is more than one plausible
primary skill, ask the user which agent version should be bumped.

The version marker format is:

```text
SKILL_VERSION=YYYY-MM-DD.N
```

Rules:

- If the version date is the same as today's date, increment `N` by 1.
- If the version date is different from today's date, change the date to today
  and reset `N` to 1.
- Within a bumped workspace, apply this rule for code, script, documentation,
  prompt, config, and rule-file changes.
