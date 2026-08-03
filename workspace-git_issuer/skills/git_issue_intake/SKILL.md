---
name: git_issue_intake
description: "[SKILL_VERSION=2026-08-03.1] Create or change GitLab issues from free-text requirements for the req_dispatcher pipeline, preserving an explicitly stated processing base branch in a versioned Issue marker. Project selection is configuration-first and never guessed: parse only configured full project names, slugs, or aliases from config/project_routing.env. Use scripts/parse_project.sh, create_issue.sh, update_issue.sh, emit_callback.sh, and format_callback_output.sh for all deterministic work. GitLab access is glab-only. Final responses should match the blue-zone markdown style: a short issue summary plus a fenced pretty JSON object under `req_dispatcher`, derived from the compact callback JSON."
---

# git_issue_intake

Use this skill when receiving a free-text requirement that should become a GitLab issue, or when receiving a change/cancel/supersede request for an existing issue.

## Algorithm

1. Read the user text.
2. Decide whether the intent is CREATE, CHANGE, CANCEL, or SUPERSEDE.
3. Call `scripts/parse_project.sh` with `REQUIREMENT_TEXT` set to the full text.
4. If parse returns `status=failed`, pass that JSON through `scripts/format_callback_output.sh` and stop.
5. For CREATE, extract `ISSUE_TITLE`, `ISSUE_DESCRIPTION`, and an optional explicitly stated processing/base/source branch. Pass that branch as `ISSUE_BASE_BRANCH` to `scripts/create_issue.sh`; otherwise leave it unset.
6. For CHANGE/CANCEL/SUPERSEDE, extract `ISSUE_IID`, `ISSUE_DESCRIPTION`, `CHANGE_ACTION`, optional `RERUN_LABEL`, then call `scripts/update_issue.sh`. A description-only change leaves the branch controls unset so the current marker is preserved. Pass a newly explicit branch as `ISSUE_BASE_BRANCH`; set `CLEAR_ISSUE_BASE_BRANCH=true` only when the user explicitly removes the association. SUPERSEDE inherits the current marker by default.
7. Pass the script's compact callback JSON to `scripts/format_callback_output.sh` with `REQUIREMENT_TEXT` set to the original user text and `ISSUE_TITLE` set when known, then output the formatter's markdown verbatim.

## Hard Rules

- Do not guess project when `parse_project.sh` fails.
- Do not infer a base branch from repository defaults or unrelated target text. When the user explicitly states the processing/base/source branch, pass it exactly as `ISSUE_BASE_BRANCH`; `create_issue.sh` validates it and prepends `<!-- req_executor_base_branch:v1 branch=<safe-ref> -->` to the Issue description.
- Do not erase an existing base-branch marker during an ordinary Issue edit. `update_issue.sh` preserves it, replaces it only from an explicit safe `ISSUE_BASE_BRANCH`, and clears it only from explicit `CLEAR_ISSUE_BASE_BRANCH=true`; never set both controls.
- Do not access GitLab outside the scripts.
- Do not use curl, wget, Python HTTP libraries, or GitLab SDKs.
- Do not add workflow labels other than `retry` or `continue` in change flows.
- Do not merge MRs or close MRs.
- Do not hand-write the final markdown or JSON; always use `format_callback_output.sh` to render the blue-zone-style response.
