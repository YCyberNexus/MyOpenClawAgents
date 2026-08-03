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

## Local Testing Config Safety

When adapting this project for local testing, Codex must not modify tracked
configuration values that are intended for the `10.64.5.104` blue-zone server.
Keep blue-zone defaults such as GitLab host/protocol, GitLab token injection
contract, clone roots under `/data`, callback targets, and persistent state
roots intact in tracked files. Put workstation-specific overrides only in
ignored `*.local.env` files or process environment variables, and verify before
committing that local-only paths, temporary sessions, and test GitLab endpoints
did not leak into tracked config.

## Destructive Command Restriction

Codex must not run `rm` in this repository, including `rm -f`, `rm -r`, or
`rm -rf`. Do not delete files or directories with shell commands. If cleanup is
needed, ask the user to do it manually or use a non-destructive archive/move
workflow after explicit approval.

## GNU/BSD Shell Portability

Repository-maintained shell code must treat GNU/Linux and BSD/macOS command
differences as a correctness boundary, not merely as a fallback-order issue.
This applies to scripts, tests, documented command examples, and shell snippets
embedded in prompts or generated bootstrap/executor payloads.

Do not use a platform-specific probe as a naked `cmd_a || cmd_b` fallback when
its stdout becomes data. A command can emit diagnostic or differently-shaped
output before failing, and the same option can have unrelated semantics on the
other platform. For example, BSD `stat -f FORMAT` formats file metadata, while
GNU `stat -f` reports filesystem information; BSD `date -r EPOCH` formats an
epoch, while GNU `date -r ARG` treats `ARG` as a reference file.

For every cross-platform probe:

- Capture each candidate command separately and suppress its stderr.
- Accept a candidate only when both its exit status and its output format are
  valid for the expected value. Never let failed-probe stdout flow into the
  next command, a comparison, JSON, or a persisted result.
- Prefer commands whose option semantics are unambiguous for the deployment
  platform, then try the alternate-platform form only as a validated fallback.
- Fail clearly when no supported implementation is available. For example,
  explicitly test for `sha256sum` and then `shasum`; do not assume every system
  lacking the first command has the second.

A safe mode probe follows this shape:

```bash
portable_file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)" \
      && [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$mode"
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)" \
      && [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$mode"
  else
    return 1
  fi
}
```

Apply the same capture-and-validate rule to time conversion: use GNU
`date -d` and BSD `date -r`/`date -j -f` only in separate branches, and verify
that the result has the required epoch or timestamp shape before accepting it.

When touching shell code, audit nearby uses of portability-sensitive tools and
options, including `stat`, `date`, `sed -i`, `readlink -f`, `grep -P`,
`sort -V`, `xargs -r`, `base64`, and `find`. Verification must include
`bash -n`, focused behavior tests, and adversarial fake-command tests that emit
misleading stdout on both failure and apparent success. For affected production
paths, verify against actual GNU coreutils and native BSD/macOS behavior; a pass
on only one platform is insufficient. If a helper is duplicated in a generated
prompt or payload, tests must extract and execute that generated copy as well.

## jq 1.5 Compatibility Baseline

All repository-maintained shell scripts, jq filters, tests, and documented jq
command examples must be compatible with jq 1.5. Do not use command-line
options, syntax, or builtins introduced in jq 1.6 or later, including `?//`,
`$ENV`, `walk`, `halt`, `halt_error`, `isempty`, `utf8bytelength`,
`strflocaltime`, and the SQL-style `INDEX`, `JOIN`, and `IN` builtins.

jq 1.5 `join(...)` requires string elements. Before joining numeric or
potentially mixed arrays, explicitly normalize the elements with
`map(tostring)`. Verification for jq-related changes must execute the affected
filters with an actual jq 1.5 binary; passing with a newer local jq alone is not
sufficient.

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
