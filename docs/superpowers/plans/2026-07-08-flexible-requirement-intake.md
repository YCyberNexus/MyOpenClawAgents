# Flexible Requirement Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `req_dispatcher` accept more company requirement input shapes by deterministically extracting GitLab projects from free text, repository URLs, and `glab api` snippets while still failing locally when no project can be determined.

**Architecture:** Keep the existing dispatcher orchestration unchanged. Only expand `prepare_downstream_payloads.sh` so non-Wiki free text can normalize more project locator shapes into the same `CREATE_GITLAB_ISSUE` payload; update the dispatcher contracts to describe the broader accepted input shapes and keep no-project input as a dispatcher-side failure.

**Tech Stack:** Bash, `awk`, `sed`, `jq`, shell test scripts, req_dispatcher Markdown contracts.

## Global Constraints

- Do not run `rm` in this repository.
- Do not make `req_dispatcher` write GitLab; it still only prepares payloads and calls downstream agents through existing scripts.
- Do not let `req_dispatcher` semantically guess projects; extraction must be deterministic from explicit text, URLs, or encoded API paths.
- If no project can be extracted, `prepare_downstream_payloads.sh` must return `status=failed`, `project=null`, `git_issuer_payload=null`, and a reason asking for `group/project` or a concrete GitLab/Wiki URL.
- Changes under `workspace-req_dispatcher/` require bumping `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md` from `SKILL_VERSION=2026-07-08.1` to `SKILL_VERSION=2026-07-08.2`.

---

### Task 1: Add Failing Intake Tests

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_downstream_payloads.sh`

**Interfaces:**
- Consumes: `prepare_downstream_payloads.sh` stdout JSON `{status,project,requirement_text,git_issuer_payload,reason}`.
- Produces: Regression coverage for repository URL extraction, encoded `glab api projects/<encoded>` extraction, and no-project failure wording.

- [ ] **Step 1: Add tests for flexible project locators**

Append these assertions before the final `echo` in `test_prepare_downstream_payloads.sh`:

```bash
repo_url_input="$(
  MESSAGE='请处理 http://gitlab-b.pxsemic.tech:30000/claw_gitlab/ifp_ui_testing_2/-/wikis/Home 里的测试点生成需求。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${repo_url_input}")" != "success" ]; then
  echo "expected repository/wiki URL input to succeed" >&2
  printf '%s\n' "${repo_url_input}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${repo_url_input}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected project extracted from repository/wiki URL" >&2
  printf '%s\n' "${repo_url_input}" >&2
  exit 1
fi

if ! jq -r '.git_issuer_payload' <<<"${repo_url_input}" | grep -q '^repo=claw_gitlab/ifp_ui_testing_2$'; then
  echo "expected URL-derived payload to include repo line" >&2
  printf '%s\n' "${repo_url_input}" >&2
  exit 1
fi

encoded_api_input="$(
  MESSAGE='用 glab api "projects/claw_gitlab%2Fifp_ui_testing_2/wikis" 列出所有 Wiki 页面并生成测试功能/需求点文档。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${encoded_api_input}")" != "success" ]; then
  echo "expected encoded glab api project input to succeed" >&2
  printf '%s\n' "${encoded_api_input}" >&2
  exit 1
fi

if [ "$(jq -r '.project' <<<"${encoded_api_input}")" != "claw_gitlab/ifp_ui_testing_2" ]; then
  echo "expected project decoded from glab api projects path" >&2
  printf '%s\n' "${encoded_api_input}" >&2
  exit 1
fi

unresolved_input="$(
  MESSAGE='请把这批 Wiki 需求整理成测试功能点。' \
  bash "${SKILL_DIR}/scripts/prepare_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${unresolved_input}")" != "failed" ]; then
  echo "expected no-project free text to fail in dispatcher intake" >&2
  printf '%s\n' "${unresolved_input}" >&2
  exit 1
fi

if [ "$(jq -r '.git_issuer_payload' <<<"${unresolved_input}")" != "null" ]; then
  echo "expected no git_issuer payload when project cannot be determined" >&2
  printf '%s\n' "${unresolved_input}" >&2
  exit 1
fi

if ! jq -r '.reason' <<<"${unresolved_input}" | grep -q 'group/project'; then
  echo "expected no-project reason to ask for group/project or URL" >&2
  printf '%s\n' "${unresolved_input}" >&2
  exit 1
fi
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_downstream_payloads.sh
```

Expected: FAIL before implementation. The encoded `glab api` input currently extracts the malformed project `projects/claw_gitlab%2Fifp_ui_testing_2`, or the URL case extracts a host/path fragment instead of `claw_gitlab/ifp_ui_testing_2`.

---

### Task 2: Implement Deterministic Project Extraction

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/prepare_downstream_payloads.sh`

**Interfaces:**
- Consumes: Normalized requirement text after transport wrapper stripping.
- Produces: `PROJECT` from the first supported locator in this order: `glab api projects/<encoded>`, GitLab URL path, plain `group/project`.

- [ ] **Step 1: Add URL decoding and project extraction helpers**

In `prepare_downstream_payloads.sh`, add helper functions after `emit_json()`:

```bash
url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

extract_project() {
  local text="$1"
  local candidate=""

  candidate="$(
    printf '%s\n' "${text}" | awk '
      match($0, /projects\/[A-Za-z0-9_.~%+-]+%2[Ff][A-Za-z0-9_.~%+-]+/) {
        value = substr($0, RSTART + length("projects/"), RLENGTH - length("projects/"))
        sub(/\/.*/, "", value)
        print value
        exit
      }'
  )"
  if [ -n "${candidate}" ]; then
    url_decode "${candidate}"
    return 0
  fi

  candidate="$(
    printf '%s\n' "${text}" | awk '
      match($0, /https?:\/\/[^[:space:]）)，]+/) {
        url = substr($0, RSTART, RLENGTH)
        sub(/^https?:\/\/[^/]+\//, "", url)
        sub(/\/-\/.*/, "", url)
        sub(/[?#].*/, "", url)
        n = split(url, parts, "/")
        if (n >= 2 && parts[1] != "" && parts[2] != "") {
          print parts[1] "/" parts[2]
          exit
        }
      }'
  )"
  if [ -n "${candidate}" ]; then
    url_decode "${candidate}"
    return 0
  fi

  printf '%s\n' "${text}" | awk '
    match($0, /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }'
}
```

- [ ] **Step 2: Replace inline project regex with helper call**

Replace the current `PROJECT="$( ... awk match ... )"` block with:

```bash
PROJECT="$(extract_project "${NORMALIZED}")"
```

- [ ] **Step 3: Update the missing-project reason**

Change the missing project failure reason to:

```bash
emit_json failed "" "${NORMALIZED}" "" "需求文本未包含可识别的 GitLab project（格式 group/project），请补充目标 group/project 或具体 GitLab/Wiki URL"
```

- [ ] **Step 4: Run focused test and verify it passes**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_downstream_payloads.sh
```

Expected: PASS with `ok prepare_downstream_payloads builds tailored downstream messages`.

---

### Task 3: Update Contracts, Version, And Verification

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`
- Modify: `workspace-req_dispatcher/SOUL.md`
- Modify: `workspace-req_dispatcher/USER.md`
- Modify: `workspace-req_dispatcher/AGENTS.md`
- Modify: `workspace-req_dispatcher/CLAUDE.md`
- Modify: `workspace-req_dispatcher/config/README.md`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/references/trigger_command.md`

**Interfaces:**
- Consumes: Behavior from Tasks 1-2.
- Produces: Runtime-facing instructions that describe flexible deterministic project extraction and unchanged no-project failure behavior.

- [ ] **Step 1: Update text contracts**

Update wording in the files above so old free-text intake is described as accepting explicit project locators in these forms:

```text
group/project、GitLab 仓库/Wiki URL，或 glab api projects/<encoded-group%2Fproject>/... 片段
```

Keep this rule visible wherever missing project behavior is described:

```text
无法确定 project 时，prepare_downstream_payloads.sh 返回 failed；req_dispatcher 推用户失败说明并停止，不调用 git_issuer。
```

- [ ] **Step 2: Bump skill version**

In `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`, change:

```text
[SKILL_VERSION=2026-07-08.1]
```

to:

```text
[SKILL_VERSION=2026-07-08.2]
```

- [ ] **Step 3: Run syntax checks for changed scripts**

Run:

```bash
/opt/homebrew/bin/bash -n workspace-req_dispatcher/skills/requirement_dispatch/scripts/prepare_downstream_payloads.sh
```

Expected: exit 0, no output.

- [ ] **Step 4: Run focused tests**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_downstream_payloads.sh
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_wiki_downstream_payloads.sh
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_wiki_intake_simulated_flow.sh
```

Expected: all print `ok ...` and exit 0.

- [ ] **Step 5: Run repository diff checks**

Run:

```bash
git diff --check -- workspace-req_dispatcher docs/superpowers/plans/2026-07-08-flexible-requirement-intake.md
git status --short
```

Expected: no whitespace errors; status lists only the plan plus intended `workspace-req_dispatcher` files.
