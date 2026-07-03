# Wiki Requirement Intake Design

## Background

The requirement source changes from a free-text issue request to a blue-zone
GitLab wiki URL supplied by ZhiBan. `req_dispatcher` must fetch the wiki
document, split it into requirement items, ask `git_issuer` to create issues in
the wiki page's GitLab project, and then hand each created issue to
`req_executor`.

## Approach

Use the existing active orchestration chain and add a wiki intake preflight in
`req_dispatcher`.

- `req_dispatcher` remains the orchestrator and still does not create issues or
  run issues.
- `req_dispatcher` may perform read-only wiki fetches using deployment-pinned
  GitLab read credentials.
- `git_issuer` remains the only component that creates or changes GitLab
  issues.
- `req_executor` remains unchanged and continues to receive one
  `RUN_SINGLE_ISSUE` trigger per created issue.

## Input

ZhiBan sends a normal req_dispatcher message containing a GitLab wiki URL.
Supported URL shapes:

- `http(s)://<host>/<group>/<project>/-/wikis/<slug>`
- optional query strings and fragments are ignored for fetching
- URL-decoded wiki slugs are accepted, but project path stays the canonical
  GitLab `group/project` extracted from the URL

Messages without a recognizable GitLab wiki URL continue through the current
free-text path.

## Wiki Fetch

`req_dispatcher` adds read-only wiki helpers:

- parse the URL into `project`, `wiki_slug`, `wiki_url`, and GitLab API project
  URI.
- fetch wiki content with `glab api projects/<encoded-project>/wikis/<slug>`.
- read GitLab host/protocol/token from dispatcher deployment config plus
  ignored local overrides.

The dispatcher must not use the read token for issue creation, labels, notes, or
executor work. It only reads the wiki page content.

## Splitting

The splitter produces a JSON array of requirement items.

Default rules:

- Prefer Markdown heading sections at `##` or `###`.
- If no useful headings exist, split numbered requirement blocks such as `1.`,
  `1、`, or `需求1`.
- Drop empty sections and obvious metadata-only sections.
- If the page cannot be split into more than one useful item, keep the whole
  page as one requirement.

Each item has:

- `ordinal`: one-based item number.
- `title`: section title or generated title.
- `body`: the Markdown fragment for that requirement.
- `wiki_url`: source URL.
- `wiki_section`: title when available.

## Downstream Payloads

For each requirement item, `req_dispatcher` builds a normal `git_issuer` create
payload:

```text
CREATE_GITLAB_ISSUE
repo=<project from wiki URL>
source=req_dispatcher_wiki
wiki_url=<original wiki URL>
wiki_section=<section title or generated item name>
wiki_item_ordinal=<n>

请根据下面的需求创建一个 GitLab issue；不要反问 repo，repo 已在上方给出。
只负责创建或变更 issue，不要调用 req_executor，不要回复企微用户。
完成后最后一行输出 req_dispatcher 契约 JSON。

需求正文：
<split requirement body>
```

The issue fact remains whatever `git_issuer` returns: `project`, `issue_iid`,
and `issue_url`.

## Orchestration

The intake path becomes:

1. capture origin.
2. detect wiki URL.
3. fetch and split wiki page.
4. evict stuck pending entries.
5. for each split item, call `git_issuer` with that item's payload.
6. for each successful `git_issuer` result, route project and call
   `req_executor RUN_SINGLE_ISSUE`.
7. record one executor pending entry per created issue.
8. notify the user of partial failures and final executor callbacks through the
   existing result path.

`req_dispatcher` processes split items sequentially. This keeps state simple,
avoids accidental duplicate issue creation caused by parallel retry ambiguity,
and matches the existing single-issue orchestration contract.

## Failure Handling

- Invalid or unsupported wiki URL: notify user and stop before calling
  `git_issuer`.
- Wiki fetch failure: notify user and stop before calling `git_issuer`.
- Empty wiki page or no usable requirements: notify user and stop.
- Some item creation fails: record and notify that item failure, continue with
  later items only if the failure came from `git_issuer` business output. A
  launcher/config/script failure still stops by the existing No-Fallback rule.
- Executor launch failure after issue creation: use the existing "created issue
  but failed to start executor" path for that item.

## Testing

Required verification:

- parser tests for supported wiki URL shapes.
- splitter tests for headings, numbered blocks, and fallback whole-page behavior.
- payload tests proving `repo`, `source=req_dispatcher_wiki`, `wiki_url`, and
  item metadata are present.
- local fake-`glab` fetch test.
- local simulated orchestration test with fake `openclaw`/`glab`, proving two
  wiki sections become two `git_issuer` calls and two executor payloads.
- local OpenClaw smoke on the existing local GitLab setup: create a wiki page,
  send its URL to `req_dispatcher`, observe created issues and driven executor
  handoff behavior.

## Out Of Scope

- No semantic deduplication across wiki pages.
- No automatic update/delete of issues when a wiki page changes.
- No executor changes unless testing reveals a contract bug.
- No write operations from `req_dispatcher` to GitLab.
