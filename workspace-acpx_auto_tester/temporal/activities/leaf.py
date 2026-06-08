"""Leaf activities — Steps 1–9 of the legacy executor prompt.

Each activity is a thin :func:`run_script` wrapper that:

* builds the per-attempt env via :func:`shared.env.build_attempt_env`;
* shells out to the corresponding ``scripts/*.sh`` script;
* parses the script's documented stdout shape (commit SHA, MR URL,
  status keywords like ``STAGED_OK`` / ``NO_CHANGES`` / ``ACPX_EXIT=…``);
* maps non-zero exits + bad stdout into typed :class:`ApplicationError`
  via :func:`shared.errors.raise_app_error`.

See :mod:`acpx_temporal.shared.types` for the input/output dataclass shapes
and the migration plan §Activity registry for StartToClose / RetryPolicy
per activity.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Final

from temporalio import activity

from ..shared.env import build_attempt_env, merge_env
from ..shared.errors import AcpxErrorType, raise_app_error
from ..shared.types import (
    STATUS_TO_LABEL,
    AcpxResult,
    AttemptInput,
    CampaignInput,
    CommitPushResult,
    LabelsState,
    MrAction,
    MrResult,
    StagedDiff,
)
from .subprocess import (
    ScriptResult,
    make_marker_file_heartbeat,
    run_script,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _padded_attempt(attempt_number: int) -> str:
    """Mirror the legacy ``ATTEMPT_NUMBER_PADDED`` (3-digit zero-padded)."""
    return f"{attempt_number:03d}"


def _local_attempt_branch(iid: int, attempt_number: int) -> str:
    return f"issue/{iid}-auto-fix-att{_padded_attempt(attempt_number)}"


def _derive_paths(camp: CampaignInput, att: AttemptInput) -> dict[str, str]:
    """Compute the absolute paths the bash scripts expect via env vars.

    ``env_paths.sh`` derives these inside each script, but a handful of
    scripts (e.g. ``commit_and_push.sh``) require ``WORKTREE_DIR`` /
    ``LOG_DIR`` / ``OUTPUT_DIR`` to be exported from the caller as well.
    """
    repo_path = f"{camp.repo_parent_path.rstrip('/')}/{camp.project}"
    worktree = f"{repo_path}/{camp.result_basename}/.worktrees/issue-{att.iid}"
    output = f"{worktree}/{camp.result_basename}/issue-{att.iid}/hulat-spec-issue{att.iid}"
    log_dir = (
        f"{worktree}/{camp.result_basename}/issue-{att.iid}/log/"
        f"attempt-{_padded_attempt(att.attempt_number)}"
    )
    issue_root = f"{repo_path}/{camp.result_basename}/issues/issue-{att.iid}"
    summary_file = f"{issue_root}/summary.md"

    return {
        "REPO_PATH": repo_path,
        "WORKTREE_DIR": worktree,
        "LOG_DIR": log_dir,
        "OUTPUT_DIR": output,
        "ISSUE_ROOT": issue_root,
        "ATTEMPT_DIR": issue_root,  # same as ISSUE_ROOT in current layout
        "SUMMARY_FILE": summary_file,
        "ATTEMPT_NUMBER_PADDED": _padded_attempt(att.attempt_number),
        "LOCAL_ATTEMPT_BRANCH": _local_attempt_branch(att.iid, att.attempt_number),
    }


def _full_env(camp: CampaignInput, att: AttemptInput) -> dict[str, str]:
    """Per-attempt env for any leaf activity. Merges trigger envelope +
    per-IID vars + derived paths."""
    base = build_attempt_env(camp, att)
    return merge_env(base, _derive_paths(camp, att))


# ---------------------------------------------------------------------------
# A7 — run_claude_code_attempt (acpx + heartbeat)
# ---------------------------------------------------------------------------

# Matches the `ACPX_EXIT=<n>` last-line marker that run_acpx_attempt.sh prints.
_ACPX_EXIT_RE: Final[re.Pattern[str]] = re.compile(r"^ACPX_EXIT=(\d+)\s*$", re.MULTILINE)


@activity.defn(name="run_claude_code_attempt")
async def run_claude_code_attempt(camp: CampaignInput, att: AttemptInput) -> AcpxResult:
    """Run ``acpx claude exec`` for one attempt via ``run_acpx_attempt.sh``.

    The script enforces its own wall-clock cap (``ACPX_TIMEOUT_SECONDS``,
    default 18000s) and the patched progress-marker file under
    ``${LOG_DIR}/acpx_progress.marker`` drives Temporal heartbeats.

    Non-retryable outcomes:
        * exit 124 / 137 → ``acpx_timed_out`` (TIMEOUT flow)
        * any other non-zero → ``acpx_failed``

    The script's stdout's last line ``ACPX_EXIT=<n>`` is the canonical exit
    code (in case ``timeout`` masked the original signal-induced exit).
    """
    env = _full_env(camp, att)
    paths = _derive_paths(camp, att)
    marker_path = Path(paths["LOG_DIR"]) / "acpx_progress.marker"

    res = await run_script(
        "run_acpx_attempt.sh",
        env=env,
        cwd=paths["WORKTREE_DIR"],
        heartbeat=make_marker_file_heartbeat(marker_path),
        heartbeat_every_s=60.0,
    )

    # Trust the script's printed exit code when present (it ran inside a
    # `set +e ... acpx_exit=$? ... exit ${acpx_exit}` block).
    reported = _ACPX_EXIT_RE.search(res.stdout)
    exit_code = int(reported.group(1)) if reported else res.exit_code
    timed_out = exit_code in (124, 137)

    if timed_out:
        raise_app_error(
            AcpxErrorType.ACPX_TIMED_OUT,
            f"acpx exceeded {camp.acpx_timeout_seconds}s wall-clock cap "
            f"(exit {exit_code})",
            details=(paths["LOG_DIR"],),
        )
    if exit_code != 0:
        raise_app_error(
            AcpxErrorType.ACPX_FAILED,
            f"acpx exited non-zero ({exit_code}); see {paths['LOG_DIR']}/acpx_raw.log",
            details=(res.stderr[-2000:],),  # truncate to keep history small
        )

    return AcpxResult(exit_code=0, timed_out=False, log_dir=paths["LOG_DIR"])


# ---------------------------------------------------------------------------
# A8 — stage_and_guard
# ---------------------------------------------------------------------------


@activity.defn(name="stage_and_guard")
async def stage_and_guard(camp: CampaignInput, att: AttemptInput) -> StagedDiff:
    """Run ``stage_and_guard.sh``. NO_CHANGES → non-retryable ApplicationError."""
    env = _full_env(camp, att)
    res = await run_script(
        "stage_and_guard.sh",
        env=env,
        cwd=_derive_paths(camp, att)["WORKTREE_DIR"],
    )
    _raise_on_failed_subprocess("stage_and_guard.sh", res)

    if "NO_CHANGES" in res.stdout:
        raise_app_error(
            AcpxErrorType.NO_CHANGES,
            "stage_and_guard.sh reported NO_CHANGES — acpx produced no staged diff",
        )
    if "STAGED_OK" not in res.stdout:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            "stage_and_guard.sh exited 0 but emitted neither STAGED_OK nor NO_CHANGES",
        )

    # Best-effort parse of `git diff --stat` summary if the script printed it.
    diff_summary = _last_nonempty_line(res.stdout)
    return StagedDiff(
        has_changes=True,
        changed_files=_changed_file_count(res.stdout),
        diff_summary=diff_summary,
    )


# ---------------------------------------------------------------------------
# A9 — commit_and_push
# ---------------------------------------------------------------------------

# commit_and_push.sh prints `git rev-parse HEAD` on its last stdout line.
_SHA_RE: Final[re.Pattern[str]] = re.compile(r"^[a-f0-9]{7,40}$")


@activity.defn(name="commit_and_push")
async def commit_and_push(camp: CampaignInput, att: AttemptInput) -> CommitPushResult:
    """Strategy-A force-push to ``${WORK_BRANCH}``.

    Non-retryable error types:
        * ``lease_conflict`` — ``--force-with-lease`` rejected.
        * ``push_rejected`` / ``protected_branch`` — server-side hook block.
    """
    paths = _derive_paths(camp, att)
    env = _full_env(camp, att)
    res = await run_script(
        "commit_and_push.sh",
        env=env,
        cwd=paths["WORKTREE_DIR"],
    )

    if res.exit_code != 0:
        msg = res.stderr.lower()
        # Parenthesized precedence (review I1): two distinct triggers for
        # lease conflict — "stale info" alone OR (rejected AND lease). The
        # generic "rejected" without "lease" / "stale info" falls through to
        # the protected-branch / push-rejected checks below.
        if ("stale info" in msg) or ("rejected" in msg and "lease" in msg):
            raise_app_error(
                AcpxErrorType.LEASE_CONFLICT,
                "force-with-lease rejected; concurrent push to "
                f"{att.work_branch}",
            )
        if "protected branch" in msg:
            raise_app_error(
                AcpxErrorType.PROTECTED_BRANCH,
                f"push to {att.work_branch} rejected by protected-branch policy",
            )
        if ("rejected" in msg) or ("denied" in msg):
            raise_app_error(
                AcpxErrorType.PUSH_REJECTED,
                f"push to {att.work_branch} rejected: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"commit_and_push.sh failed (exit {res.exit_code}): {res.stderr[-500:]}",
        )

    sha = _last_nonempty_line(res.stdout)
    if not _SHA_RE.match(sha):
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"commit_and_push.sh did not emit a valid SHA on last stdout line: {sha!r}",
        )
    return CommitPushResult(
        commit_sha=sha,
        local_branch=paths["LOCAL_ATTEMPT_BRANCH"],
        pushed_to=att.work_branch,
    )


# ---------------------------------------------------------------------------
# A10 — post_push_verify
# ---------------------------------------------------------------------------


@activity.defn(name="post_push_verify")
async def post_push_verify(camp: CampaignInput, att: AttemptInput) -> bool:
    """Confirm ``origin/${WORK_BRANCH}`` and ``origin/${BRANCH}`` are reachable.

    Failure → ``ref_not_found`` (non-retryable; means commit_and_push didn't
    actually land the ref).
    """
    paths = _derive_paths(camp, att)
    res = await run_script(
        "post_push_verify.sh",
        env=_full_env(camp, att),
        cwd=paths["WORKTREE_DIR"],
    )
    if res.exit_code != 0:
        msg = res.stderr.lower()
        if ("not found" in msg) or ("couldn't find remote ref" in msg):
            raise_app_error(
                AcpxErrorType.REF_NOT_FOUND,
                f"post_push_verify could not fetch a remote ref: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"post_push_verify.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )
    return True


# ---------------------------------------------------------------------------
# A11 — upload_wiki_artifacts
# ---------------------------------------------------------------------------


@activity.defn(name="upload_wiki_artifacts")
async def upload_wiki_artifacts(camp: CampaignInput, att: AttemptInput) -> str:
    """Publish ``prompt.txt`` + ``claude_result.txt`` (+ optional report.html)
    to the project Wiki and link from the issue. Returns first Wiki page URL.
    """
    paths = _derive_paths(camp, att)
    res = await run_script(
        "upload_attempt_artifacts.sh",
        env=_full_env(camp, att),
    )
    if res.exit_code != 0:
        msg = res.stderr.lower()
        if "403" in msg or "forbidden" in msg:
            raise_app_error(
                AcpxErrorType.GLAB_WIKI_FORBIDDEN,
                f"Wiki upload forbidden: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"upload_attempt_artifacts.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )
    links_file = Path(paths["LOG_DIR"]) / "wiki_artifact_links.md"
    wiki_url = _first_url_from_markdown_links(links_file)
    if not wiki_url:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            "upload_attempt_artifacts.sh succeeded but did not write a Wiki URL "
            f"to {links_file}",
        )
    return wiki_url


# ---------------------------------------------------------------------------
# A12 — transition_label_doing_to_done (two sub-calls)
# ---------------------------------------------------------------------------


@activity.defn(name="transition_label_doing_to_done")
async def transition_label_doing_to_done(
    camp: CampaignInput, att: AttemptInput
) -> LabelsState:
    """Remove ``doing``, add ``done``. Two separate ``set_issue_label.sh``
    invocations because each call is one atomic glab API mutation.
    """
    env = _full_env(camp, att)
    res_remove = await run_script("set_issue_label.sh", env=env, args=("remove", "doing"))
    _raise_on_glab_error("set_issue_label.sh remove doing", res_remove)

    res_add = await run_script("set_issue_label.sh", env=env, args=("add", "done"))
    _raise_on_glab_error("set_issue_label.sh add done", res_add)

    return LabelsState(labels=_parse_labels_state(res_add.stdout))


# ---------------------------------------------------------------------------
# A13 — create_or_rotate_mr (non-atomic; NEVER retry)
# ---------------------------------------------------------------------------


@activity.defn(name="create_or_rotate_mr")
async def create_or_rotate_mr(camp: CampaignInput, att: AttemptInput) -> MrResult:
    """List existing open MRs for ``${WORK_BRANCH}``, close them, create one
    fresh MR. ``mr_action`` = ``"rotated"`` if at least one MR was closed,
    else ``"created"``.

    Non-atomic — :class:`MR_ROTATE_FAILED` on any error and treat as
    non-retryable (the workflow goes to FAIL flow).
    """
    res = await run_script(
        "create_mr.sh",
        env=_full_env(camp, att),
        cwd=_derive_paths(camp, att)["WORKTREE_DIR"],
    )
    if res.exit_code != 0:
        raise_app_error(
            AcpxErrorType.MR_ROTATE_FAILED,
            f"create_mr.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )

    lines = [ln for ln in res.stdout.splitlines() if ln.strip()]
    if len(lines) < 2:
        raise_app_error(
            AcpxErrorType.MR_ROTATE_FAILED,
            f"create_mr.sh stdout malformed (need >=2 lines, got {len(lines)}): {res.stdout!r}",
        )
    url = lines[0].strip()
    action_raw = lines[1].strip()
    if action_raw not in ("created", "rotated"):
        raise_app_error(
            AcpxErrorType.MR_ROTATE_FAILED,
            f"create_mr.sh emitted unknown action {action_raw!r}; expected created|rotated",
        )
    action: MrAction = action_raw  # type: ignore[assignment]
    return MrResult(url=url, action=action)


# ---------------------------------------------------------------------------
# A14 — add_pr_label
# ---------------------------------------------------------------------------


@activity.defn(name="add_pr_label")
async def add_pr_label(camp: CampaignInput, att: AttemptInput) -> LabelsState:
    """Add ``pr`` to the issue. v2: ``pr`` REPLACES ``done`` —
    ``set_issue_label.sh`` removes ``done`` when it adds ``pr``."""
    res = await run_script(
        "set_issue_label.sh",
        env=_full_env(camp, att),
        args=("add", "pr"),
    )
    _raise_on_glab_error("set_issue_label.sh add pr", res)
    return LabelsState(labels=_parse_labels_state(res.stdout))


# ---------------------------------------------------------------------------
# A15 — summarize_attempt
# ---------------------------------------------------------------------------


@activity.defn(name="summarize_attempt")
async def summarize_attempt(
    camp: CampaignInput,
    att: AttemptInput,
    status: str,
    commit_sha: str,
    merge_request_url: str,
    block_reason: str,
    summary_post_to_issue: bool,
) -> bool:
    """Write the per-attempt summary markdown + (for success only) post it as
    a GitLab issue note. Returns whether the note was posted.
    """
    env = merge_env(
        _full_env(camp, att),
        {
            "ATTEMPT_STATUS": status,
            "COMMIT_SHA": commit_sha,
            "MERGE_REQUEST_URL": merge_request_url,
            "BLOCK_REASON": block_reason,
            "SUMMARY_POST_TO_ISSUE": "true" if summary_post_to_issue else "false",
        },
    )
    res = await run_script("summarize_attempt.sh", env=env)
    _raise_on_failed_subprocess("summarize_attempt.sh", res, allow_glab_retry=True)
    # summarize_attempt.sh writes SUMMARY_POSTED=true|false to stderr and the
    # summary file path to stdout.
    return "SUMMARY_POSTED=true" in res.stderr


# ---------------------------------------------------------------------------
# A16 — sync_terminal_labels (used by FAIL / TIMEOUT flows)
# ---------------------------------------------------------------------------


@activity.defn(name="sync_terminal_labels")
async def sync_terminal_labels(
    camp: CampaignInput, att: AttemptInput, terminal_status: str
) -> LabelsState:
    """Apply terminal-state labels for non-done outcomes (v2 per-side).

    Accepts the Python status enum value (underscored) and maps it to the
    matching hyphenated GitLab work label:

    * ``blocked_cc``          → remove ``doing``,            add ``blocked-cc``
    * ``blocked_dispatcher``  → remove ``doing``,            add ``blocked-dispatcher``
    * ``failed_cc``           → remove ``doing``,            add ``failed-cc``
    * ``failed_dispatcher``   → remove ``doing``,            add ``failed-dispatcher``
    * ``timeout``             → remove ``doing``,            add ``timeout``

    ``set_issue_label.sh`` enforces v2 work-label exclusivity, so the single
    ``add`` of the target label already removes every other work label (and
    ``pr`` replaces ``done``), while leaving ``model:{tier}`` / ``quality:low``
    untouched. We still issue an explicit ``remove doing`` first so the
    transition is obvious in the audit log. Each call is one ``set_issue_label.sh``
    invocation (the underlying glab API is single-label-at-a-time per call).
    """
    env = _full_env(camp, att)

    target_label = STATUS_TO_LABEL.get(terminal_status)
    if target_label is None:
        raise_app_error(
            AcpxErrorType.INVARIANT_VIOLATION,
            f"sync_terminal_labels got unsupported status {terminal_status!r}",
        )

    last_stdout = ""
    res = await run_script("set_issue_label.sh", env=env, args=("remove", "doing"))
    _raise_on_glab_error("set_issue_label.sh remove doing", res)
    last_stdout = res.stdout

    res = await run_script("set_issue_label.sh", env=env, args=("add", target_label))
    _raise_on_glab_error(f"set_issue_label.sh add {target_label}", res)
    last_stdout = res.stdout

    return LabelsState(labels=_parse_labels_state(last_stdout))


# ===========================================================================
# Private helpers
# ===========================================================================


def _raise_on_failed_subprocess(
    name: str, res: ScriptResult, *, allow_glab_retry: bool = False
) -> None:
    if res.exit_code == 0:
        return
    if allow_glab_retry and ("rate" in res.stderr.lower() or "504" in res.stderr):
        raise_app_error(
            AcpxErrorType.GITLAB_TRANSIENT,
            f"{name} got a transient GitLab error: {res.stderr[-500:]}",
        )
    raise_app_error(
        AcpxErrorType.SUBPROCESS_FAILED,
        f"{name} exit {res.exit_code}: {res.stderr[-500:]}",
    )


def _raise_on_glab_error(name: str, res: ScriptResult) -> None:
    if res.exit_code == 0:
        return
    msg = res.stderr.lower()
    if "401" in msg or "unauthorized" in msg or "authentication" in msg:
        raise_app_error(
            AcpxErrorType.GLAB_AUTH_FAILED,
            f"{name} got 401/unauthorized: {res.stderr[-500:]}",
        )
    if "404" in msg or "not found" in msg:
        raise_app_error(
            AcpxErrorType.GLAB_ISSUE_NOT_FOUND,
            f"{name} got 404/not found: {res.stderr[-500:]}",
        )
    if "rate" in msg or "504" in msg or "503" in msg:
        raise_app_error(
            AcpxErrorType.GITLAB_TRANSIENT,
            f"{name} transient: {res.stderr[-500:]}",
        )
    raise_app_error(
        AcpxErrorType.SUBPROCESS_FAILED,
        f"{name} exit {res.exit_code}: {res.stderr[-500:]}",
    )


def _last_nonempty_line(text: str) -> str:
    for line in reversed(text.splitlines()):
        if line.strip():
            return line.strip()
    return ""


def _first_url_from_markdown_links(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""

    match = re.search(r"https?://\S+", text)
    return match.group(0).rstrip(").,") if match else ""


def _changed_file_count(stdout: str) -> int:
    """Best-effort parse of ``git diff --stat`` last summary line.

    Lines look like ``" 3 files changed, 142 insertions(+), 18 deletions(-)"``.
    Return 0 when no match.
    """
    m = re.search(r"(\d+)\s+files?\s+changed", stdout)
    return int(m.group(1)) if m else 0


def _parse_labels_state(stdout: str) -> tuple[str, ...]:
    """Best-effort parse of ``set_issue_label.sh`` stdout for the current label
    state. The script prints lines like ``add:doing`` / ``remove_conflicts:todo,new``;
    we don't reconstruct full state — we just return a placeholder marker.
    Real label state is sourced from reconcile_gitlab on the next tick.
    """
    return tuple(line.strip() for line in stdout.splitlines() if line.strip())


__all__ = [
    "add_pr_label",
    "commit_and_push",
    "create_or_rotate_mr",
    "post_push_verify",
    "run_claude_code_attempt",
    "stage_and_guard",
    "summarize_attempt",
    "sync_terminal_labels",
    "transition_label_doing_to_done",
    "upload_wiki_artifacts",
]
