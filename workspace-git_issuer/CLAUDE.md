# git_issuer Development Notes

This is an OpenClaw agent deployment artifact, not an application repo.

## Static Checks

Use Homebrew bash for scripts:

```bash
for f in workspace-git_issuer/skills/git_issue_intake/scripts/*.sh workspace-git_issuer/skills/git_issue_intake/tests/*.sh; do /opt/homebrew/bin/bash -n "$f"; done
```

Run local tests with fake `glab`:

```bash
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_parse_project.sh
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_create_issue_fake_glab.sh
/opt/homebrew/bin/bash workspace-git_issuer/skills/git_issue_intake/tests/test_update_issue_fake_glab.sh
```

## Rules

- Do not run real GitLab operations in local tests.
- Do not run `rm` in this repository.
- Do not change existing `workspace-req_dispatcher/` worktree changes while working on `workspace-git_issuer/`.
- Any change under `workspace-git_issuer/` requires bumping the skill version in `skills/git_issue_intake/SKILL.md`.
