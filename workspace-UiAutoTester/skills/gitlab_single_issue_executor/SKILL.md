---
name: gitlab_single_issue_executor
description: Execute one GitLab issue in one dedicated session. Clone or pull the repository, ensure labels exist, set the issue to doing, invoke Claude Code through acpx, persist logs, commit and push changes, create a merge request to master without merging, and update per-issue state on disk. Supports blocked and failed states for retryable scheduling. For this automation, a merge request being created successfully is the terminal completion condition, so the issue must be labeled `done` immediately after MR creation succeeds.
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Single-Issue Executor Skill

## Purpose

This skill is for a dedicated issue session.
One dedicated session must execute only one GitLab issue.

It must:
1. clone or pull `<gitlab-address>/<group>/<project>` branch `<branch>` into `/data/<project>/`
2. read the single target issue `<issue_iid>`
3. ensure repository labels `todo`, `doing`, `pr`, `done`, `blocked`, and `failed` exist
4. set that issue label to `doing`
5. use the issue description plus `hulat_dir` as Claude Code task context and invoke Claude Code through `acpx`
6. save logs to `/data/<project>/openclaw_log/issue-<iid>/`
7. commit and push changes if any
8. create a merge request targeting `master` without merging
9. immediately label the issue `done` after merge request creation succeeds
10. update per-issue state on disk
11. mark retryable runtime/environment problems as `blocked`
12. mark exhausted retries or non-recoverable cases as `failed`

---

## Inputs

Required inputs:
- `gitlab_address`
- `group`
- `project`
- `branch`
- `hulat_dir`
- `gitlab_token`
- `issue_iid`
- `non_interactive`

Optional inputs:
- `blocked_retry_limit`

Expected values:
- `non_interactive=true`

---

## Trigger Command

The dedicated issue session should receive:

```text
RUN_SINGLE_ISSUE_SESSION
gitlab_address=<gitlab-address>
group=<group>
project=<project>
branch=<branch>
hulat_dir=<hulat_dir>
gitlab_token=<token>
issue_iid=<iid>
non_interactive=true
blocked_retry_limit=<limit>
```

---

## Paths

```bash
REPO_PATH="/data/${PROJECT}"
LOG_DIR="${REPO_PATH}/openclaw_log/issue-${ISSUE_IID}"
STATE_DIR="${REPO_PATH}/openclaw_state"
ISSUE_STATE_DIR="${STATE_DIR}/issues"
ISSUE_STATE_FILE="${ISSUE_STATE_DIR}/issue-${ISSUE_IID}.json"
REMOTE_URL="${GITLAB_ADDRESS}/${GROUP}/${PROJECT}.git"
AUTHED_REMOTE_URL="$(echo "${REMOTE_URL}" | sed "s#://#://oauth2:${GITLAB_TOKEN}@#")"
```

---

## Local Preparation

```bash
mkdir -p /data "${LOG_DIR}" "${ISSUE_STATE_DIR}"
```

If the repository does not exist locally:

```bash
git clone -b "${BRANCH}" "${AUTHED_REMOTE_URL}" "${REPO_PATH}"
```

If it already exists:

```bash
cd "${REPO_PATH}"
git remote set-url origin "${AUTHED_REMOTE_URL}"
git fetch origin
git checkout "${BRANCH}"
git pull origin "${BRANCH}"
```

---

## Resolve Project ID

Use the GitLab project API and fail if the project ID is empty or `null`.

---

## Read Issue

Read issue `<issue_iid>` and extract:
- title
- description
- labels

---

## Ensure Labels

Required labels:
- `todo`
- `doing`
- `pr`
- `done`
- `blocked`
- `failed`

Create missing labels when necessary.

---

## Per-Issue State File

Persist the issue state to:

```text
/data/<project>/openclaw_state/issues/issue-<iid>.json
```

Recommended schema:

```json
{
  "iid": 14,
  "session": "issue-px_ifp_hulat-14",
  "status": "in_progress",
  "retry_count": 1,
  "block_reason": null,
  "work_branch": null,
  "commit_sha": null,
  "merge_request_url": null,
  "updated_at": "2026-04-23T10:00:00Z"
}
```

Update this file at every major step.

---

## Claude Code Execution Contract

Build a prompt file under the issue log directory.

The prompt must instruct Claude Code to:
- work only on the target issue
- modify repository content under `/data/<project>`
- avoid asking the user questions
- finish directly and summarize changes briefly

Write at least:
- `prompt.txt`
- `claude_result.txt`
- `acpx_raw.log`

Invoke Claude Code through `acpx`.

If Claude execution fails:
- preserve logs
- classify the problem
- if retryable, write issue state as `blocked`
- if not retryable or retry limit is exceeded, write issue state as `failed`
- do not lose the dedicated session mapping

Typical retryable blocked examples:
- runtime/library mismatch
- transient environment/tool startup failure
- temporary credential or remote connectivity issue

Typical non-recoverable or exhausted examples:
- repeated deterministic repository corruption not auto-fixable
- retry count exceeded configured limit

---

## Git Evidence

After Claude execution, save:
- `git_status.txt`
- `git_diff.patch`

---

## Work Branch

Use one work branch per issue:

```text
issue/<iid>-auto-fix
```

---

## Commit, Push, and MR Creation

If repository changes exist:
1. checkout `issue/<iid>-auto-fix`
2. stage changes with an explicit and exhaustive add step (see "Required Staging Rules" below)
3. commit changes
4. push branch
5. create merge request targeting `master`
6. save MR metadata to disk
7. update issue labels from `doing` to `pr`
8. immediately update issue labels from `pr` to `done`
9. write issue state as `done`

For this automation campaign, successful merge request creation is the terminal completion condition for the issue executor. The issue must not stay at `pr` for future scheduler retries.

If no changes exist:
- preserve logs
- write issue state as `no_changes`

### Required Staging Rules

Every work branch pushed to GitLab MUST contain that run's execution evidence. The executor must not rely on Claude's own staging choices.

Mandatory order:

1. Finish writing all log artifacts BEFORE staging. At minimum these must exist on disk before `git add`:
   - `${LOG_DIR}/prompt.txt`
   - `${LOG_DIR}/claude_result.txt`
   - `${LOG_DIR}/acpx_raw.log`
   - `${LOG_DIR}/git_status.txt`
   - `${LOG_DIR}/git_diff.patch`
   - `${ISSUE_STATE_FILE}`
2. Checkout the work branch `issue/<iid>-auto-fix` only after the above artifacts are written.
3. Stage in two steps so logs cannot be missed:
   ```bash
   # a. all repository changes produced by Claude
   git add -A

   # b. force-add log + state artifacts even if gitignored
   git add -f -- \
     "openclaw_log/issue-${ISSUE_IID}/" \
     "openclaw_state/issues/issue-${ISSUE_IID}.json"
   ```
4. Before committing, verify the staged tree actually contains the log artifacts:
   ```bash
   git diff --cached --name-only | grep -q "openclaw_log/issue-${ISSUE_IID}/claude_result.txt" \
     || { echo "missing logs in staging"; exit 1; }
   ```
   If the check fails, do not push or create an MR. Mark the issue `blocked` with `block_reason="logs missing from work branch staging"`.
5. Commit with a message including the issue IID, then push.

### .gitignore Handling

If the repository's `.gitignore` excludes `openclaw_log/` or `openclaw_state/`, the executor must still include this run's artifacts by using `git add -f` as shown above. Never modify the repository's `.gitignore` to achieve this.

### Post-Push Verification

After `git push`, the executor must confirm that the remote branch tip contains the log artifacts, for example:

```bash
git fetch origin "issue/${ISSUE_IID}-auto-fix"
git ls-tree -r --name-only "origin/issue/${ISSUE_IID}-auto-fix" \
  | grep -q "openclaw_log/issue-${ISSUE_IID}/claude_result.txt" \
  || { echo "remote branch missing logs"; exit 1; }
```

If verification fails, mark the issue `blocked` rather than proceeding to MR creation.

---

## Label Transition Rules

Suggested label transitions:
- `todo` -> `doing`
- `doing` -> `pr`
- `pr` -> `done` immediately after successful merge request creation
- `doing` -> `blocked` for retryable blocked issues
- `blocked` -> `doing` when retry starts
- `blocked` -> `failed` when retries are exhausted

Preserve unrelated labels whenever possible.

---

## Chat Output Policy

Return only a compact issue summary, such as:

```json
{
  "iid": 14,
  "status": "blocked",
  "retry_count": 2,
  "block_reason": "Claude Code runtime requires GLIBC 2.29+"
}
```

or:

```json
{
  "iid": 14,
  "status": "done",
  "work_branch": "issue/14-auto-fix",
  "merge_request_url": "http://gitlab.example.com/..."
}
```

Never paste full logs or full diffs into chat.
