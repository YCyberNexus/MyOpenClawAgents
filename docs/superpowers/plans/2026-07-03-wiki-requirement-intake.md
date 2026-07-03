# Wiki Requirement Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a req_dispatcher wiki intake path that fetches a GitLab wiki page, splits it into requirements, creates issues through git_issuer, and dispatches each issue to req_executor.

**Architecture:** Keep the existing active orchestration chain. Add focused req_dispatcher helpers for wiki URL parsing, read-only wiki fetching, Markdown splitting, and git_issuer payload generation; reuse the existing `run_agent_turn.sh`, `route_project.sh`, `build_executor_payload.sh`, pending state, and executor callback path.

**Tech Stack:** Bash, jq, glab CLI, OpenClaw agent CLI, existing shell test style under `workspace-req_dispatcher/skills/requirement_dispatch/tests`.

## Global Constraints

- Reply and docs are in Simplified Chinese when user-facing; code identifiers and command literals stay unchanged.
- Do not run `rm` in this repository.
- `req_dispatcher` must not create issues, write labels, write notes, or run executor work directly.
- Local-only GitLab host/token/path overrides must stay in ignored `*.local.env` files or process environment variables.
- Any edit under `workspace-req_dispatcher/` requires bumping `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md` `SKILL_VERSION` for 2026-07-03.
- Production code changes require a failing test first.

---

### Task 1: Wiki URL Parser And Splitter

**Files:**
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_wiki_downstream_payloads.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/prepare_wiki_downstream_payloads.sh`

**Interfaces:**
- Consumes: `MESSAGE` or `MESSAGE_FILE` or stdin.
- Produces: JSON object `{status, project, wiki_url, wiki_slug, requirements, git_issuer_payloads, reason}`.

- [x] **Step 1: Write failing tests**

Create `test_prepare_wiki_downstream_payloads.sh` with cases for:

```bash
MESSAGE='请处理 http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements' \
bash scripts/prepare_wiki_downstream_payloads.sh
```

Expected:

```json
{"status":"failed","reason":"wiki content is required when WIKI_CONTENT is not provided and fetch is disabled"}
```

Then set `WIKI_CONTENT` containing two `##` sections and expect two payloads with `repo=claw_gitlab/px_ifp_hulat_test`, `source=req_dispatcher_wiki`, `wiki_url=...`, and per-item titles.

- [x] **Step 2: Verify red**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_wiki_downstream_payloads.sh
```

Expected: fail because `prepare_wiki_downstream_payloads.sh` does not exist.

- [x] **Step 3: Implement minimal parser and splitter**

Implement:

- GitLab wiki URL parsing.
- `WIKI_CONTENT` test injection.
- Heading split, numbered split, fallback whole page.
- JSON output with one payload per requirement.

- [x] **Step 4: Verify green**

Run the same test and expect `ok prepare_wiki_downstream_payloads builds wiki item payloads`.

### Task 2: Read-Only Wiki Fetch

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/prepare_wiki_downstream_payloads.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_fetch_wiki_fake_glab.sh`
- Modify: `workspace-req_dispatcher/config/dispatcher.env`
- Modify: `workspace-req_dispatcher/config/README.md`

**Interfaces:**
- Consumes: `FETCH_WIKI=1`, `GITLAB_HOST`, `GITLAB_API_PROTOCOL`, `GITLAB_TOKEN`, `GLAB_BIN`.
- Produces: same JSON as Task 1 using fetched `.content`.

- [x] **Step 1: Write fake glab failing test**

Create fake `glab` that records the API path and returns:

```json
{"content":"## A\nDo A\n\n## B\nDo B"}
```

Run with `FETCH_WIKI=1 GLAB_BIN=<fake>` and assert path includes `projects/claw_gitlab%2Fpx_ifp_hulat_test/wikis/product%2Frequirements`.

- [x] **Step 2: Verify red**

Expected: fail because fetch mode is not implemented.

- [x] **Step 3: Implement fetch mode**

Use `glab api` only. Fail with a clear JSON failure if token/host is missing, glab exits nonzero, or response lacks `.content`.

- [x] **Step 4: Verify green**

Run fake glab test.

### Task 3: Skill Contract And Config Docs

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/references/trigger_command.md`
- Modify: `workspace-req_dispatcher/AGENTS.md`
- Modify: `workspace-req_dispatcher/CLAUDE.md`
- Modify: `workspace-req_dispatcher/config/README.md`

**Interfaces:**
- Documents new wiki intake path and per-exec env contract.

- [x] **Step 1: Update docs and skill**

Add wiki URL intake before legacy free-text prepare. Document read-only GitLab credentials and sequential per-item orchestration. Bump `SKILL_VERSION`.

- [x] **Step 2: Verify docs align**

Search for stale statements saying the dispatcher only accepts explicit `group/project` in free text, and update them to include wiki URL as an accepted source.

### Task 4: Local Simulated Flow

**Files:**
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_wiki_intake_simulated_flow.sh`

**Interfaces:**
- Uses fake `openclaw` with `run_agent_turn.sh`.

- [x] **Step 1: Write failing simulated flow test**

Fake `openclaw` returns two `git_issuer` success JSON lines for two calls and two executor success envelopes. Assert the test observes two `CREATE_GITLAB_ISSUE` messages and two `RUN_SINGLE_ISSUE` messages.

- [x] **Step 2: Implement the smallest shell harness needed**

The harness may live only in tests and call existing scripts in the same sequence the SKILL documents.

- [x] **Step 3: Verify green**

Run all req_dispatcher tests.

### Task 5: Local OpenClaw Smoke

**Files:**
- Modify: `docs/local-gitlab-openclaw-smoke.md`

**Interfaces:**
- Uses existing local GitLab setup and local OpenClaw agents.

- [x] **Step 1: Prepare ignored local env**

Use `workspace-req_dispatcher/config/dispatcher.local.env` for local GitLab read values and temp state root.

- [x] **Step 2: Create or update a local GitLab wiki page**

Use local GitLab tooling outside tracked config. The page contains two sections.

- [x] **Step 3: Send wiki URL to local `req_dispatcher`**

Run `openclaw agent --agent req_dispatcher --message "<wiki url>" --timeout <seconds>`.

- [x] **Step 4: Inspect results**

Confirm issues were created through `git_issuer` and executor handoff payloads were emitted or recorded. If local executor cannot run full `acpx`, verify the driven handoff boundary and document the stopped point.

## Self-Review

- Spec coverage: parser, fetch, split, payload, orchestration, docs, local smoke are covered.
- Placeholder scan: no implementation step depends on unspecified behavior; local OpenClaw smoke may reveal runtime-specific issues and must be debugged systematically.
- Type consistency: all payloads keep existing `project`, `iid`, `correlation_id`, and `dispatcher_callback_target` names.
