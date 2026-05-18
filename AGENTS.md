# Codex Project Rules

This file is for Codex-facing repository rules. Do not treat
`workspace-acpx_auto_tester/AGENTS.md` as Codex instructions; that file is part
of the deployed OpenClaw agent artifact.

## Skill Version Bump

Every repository change made by Codex must bump the dispatcher skill version in
`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md`.

The version marker format is:

```text
SKILL_VERSION=YYYY-MM-DD.N
```

Rules:

- If the version date is the same as today's date, increment `N` by 1.
- If the version date is different from today's date, change the date to today
  and reset `N` to 1.
- Apply this rule for code, script, documentation, prompt, config, and rule-file
  changes.
