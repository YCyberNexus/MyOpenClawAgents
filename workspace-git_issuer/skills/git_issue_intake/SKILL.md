---
name: git_issue_intake
description: "[SKILL_VERSION=2026-07-01.2] Create or change GitLab issues from free-text requirements for the req_dispatcher pipeline. Project selection is configuration-first and never guessed: parse only configured full project names, slugs, or aliases from config/project_routing.env. Use scripts/parse_project.sh, create_issue.sh, update_issue.sh, and emit_callback.sh for all deterministic work. GitLab access is glab-only. The last line of the final response must be one compact JSON callback compatible with req_dispatcher, including status, action, issue_iid, issue_url, project, entry_label, superseded_by, reason, and correlation_id."
---

# git_issue_intake

Use this skill when receiving a free-text requirement that should become a GitLab issue, or when receiving a change/cancel/supersede request for an existing issue.

## Algorithm

1. Read the user text.
2. Decide whether the intent is CREATE, CHANGE, CANCEL, or SUPERSEDE.
3. Call `scripts/parse_project.sh` with `REQUIREMENT_TEXT` set to the full text.
4. If parse returns `status=failed`, output the failure callback JSON as the final line and stop.
5. For CREATE, extract `ISSUE_TITLE` and `ISSUE_DESCRIPTION`, then call `scripts/create_issue.sh`.
6. For CHANGE/CANCEL/SUPERSEDE, extract `ISSUE_IID`, `ISSUE_DESCRIPTION`, `CHANGE_ACTION`, optional `RERUN_LABEL`, then call `scripts/update_issue.sh`.
7. Output the script's final JSON line verbatim as your own final line.

## Hard Rules

- Do not guess project when `parse_project.sh` fails.
- Do not access GitLab outside the scripts.
- Do not use curl, wget, Python HTTP libraries, or GitLab SDKs.
- Do not add workflow labels other than `retry` or `continue` in change flows.
- Do not merge MRs or close MRs.
- Keep the final line as compact JSON only.
