"""Temporal worker entrypoint.

Reads Cloud connection settings + per-host identity from env, registers every
workflow + activity, and runs a single :class:`temporalio.worker.Worker`
bound to ``f"acpx-worktree-{NODE_ID}"``.

Why a host-specific task queue:
    Per-issue linked git worktrees live on the worker host's local
    filesystem at ``${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/``.
    Every activity for one IID must land on the host that owns that
    worktree, or stage / commit / push will fail. Worktree affinity is
    achieved by:

    * the worker binds to ``acpx-worktree-${NODE_ID}``;
    * ``CampaignWorkflow`` starts child workflows on
      ``workflow.info().task_queue`` (i.e. the same queue);
    * Schedule + Worker-host pairing ensures the parent workflow itself
      lands on the same host.

Environment contract:
    * ``TEMPORAL_ADDRESS``     — required, e.g. ``us-east-1.tmprl.cloud:7233``
                                 (or ``localhost:7233`` for ``temporal server start-dev``)
    * ``TEMPORAL_NAMESPACE``   — required, e.g. ``acpx-auto-tester-temporal-prod``
                                 (``default`` for the dev server)
    * ``TEMPORAL_TLS_CERT``    — optional (path), mTLS client cert PEM. Set together
                                 with TEMPORAL_TLS_KEY for Temporal Cloud; leave both
                                 unset for a plaintext local dev-server connection.
    * ``TEMPORAL_TLS_KEY``     — optional (path), mTLS client private key PEM
    * ``NODE_ID``              — required, e.g. ``runner-01`` (used in task queue)
    * ``GITLAB_TOKEN``         — required; forwarded to glab_auth.sh by activities
    * ``ACPX_SCRIPTS_DIR``     — optional; defaults to the SKILL's scripts dir
    * ``ACPX_UI_ACCOUNTS_PATH``— optional absolute-path escape hatch (used by
                                 local tests). In production the pool path is
                                 derived from the CampaignInput trigger as
                                 ``${REPO_PATH}/${ui_accounts_relpath}`` (resolved
                                 under the project checkout root, NOT under
                                 ``${REPO_PATH}/${DATA_BASENAME}/``).
                                 The pool is opt-in: an empty ``ui_accounts_relpath``
                                 skips the UI-account flow entirely.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from pathlib import Path

from temporalio.client import Client, TLSConfig
from temporalio.worker import Worker

# Activities
from .activities.leaf import (
    add_pr_label,
    commit_and_push,
    create_or_rotate_mr,
    post_push_verify,
    run_claude_code_attempt,
    stage_and_guard,
    summarize_attempt,
    sync_terminal_labels,
    transition_label_doing_to_done,
    upload_wiki_artifacts,
)
from .activities.orchestrator import (
    allocate_attempt_number,
    build_executor_prompt,
    clone_or_pull_repo,
    ensure_workflow_labels,
    load_ui_account_pool,
    mark_issue_doing,
    prepare_attempt_worktree,
    record_attempt_outcome,
    reconcile_gitlab,
    self_heal_safety_bin,
)

# Workflows
from .workflows.campaign import CampaignWorkflow
from .workflows.issue_attempt import IssueAttemptWorkflow

LOG = logging.getLogger("acpx_temporal.worker")


def _required_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        raise SystemExit(
            f"missing required env var {name!r}. "
            "See workspace-acpx_auto_tester/temporal/README.md §Run a worker."
        )
    return val


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="acpx-temporal-worker",
        description="Run the acpx_auto_tester_temporal Temporal worker on this host.",
    )
    parser.add_argument(
        "--task-queue",
        default=None,
        help=(
            "Task queue name. Defaults to f'acpx-worktree-${NODE_ID}'. "
            "Override only when you understand worktree-affinity implications."
        ),
    )
    parser.add_argument(
        "--max-concurrent-activities", type=int, default=4,
        help="Worker-side concurrent activity cap. Default 4.",
    )
    parser.add_argument(
        "--max-concurrent-workflow-tasks", type=int, default=8,
        help="Worker-side concurrent workflow task cap. Default 8.",
    )
    parser.add_argument(
        "--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )
    return parser.parse_args(argv)


async def _connect_client() -> Client:
    address = _required_env("TEMPORAL_ADDRESS")
    namespace = _required_env("TEMPORAL_NAMESPACE")

    # TLS is opt-in. Set BOTH TEMPORAL_TLS_CERT and TEMPORAL_TLS_KEY for a
    # Temporal Cloud mTLS connection; leave both unset to connect in plaintext
    # against a local ``temporal server start-dev`` (localhost:7233, no TLS).
    # Setting only one of the two is an operator mistake — fail loudly rather
    # than silently downgrading a Cloud deployment to plaintext.
    cert = os.environ.get("TEMPORAL_TLS_CERT")
    key = os.environ.get("TEMPORAL_TLS_KEY")
    tls: TLSConfig | bool = False
    if bool(cert) != bool(key):
        raise SystemExit(
            "TEMPORAL_TLS_CERT and TEMPORAL_TLS_KEY must be set together "
            "(both for Cloud mTLS, or neither for a plaintext dev server)."
        )
    if cert and key:
        cert_path = Path(cert)
        key_path = Path(key)
        if not cert_path.is_file():
            raise SystemExit(f"TEMPORAL_TLS_CERT does not point at a file: {cert_path}")
        if not key_path.is_file():
            raise SystemExit(f"TEMPORAL_TLS_KEY does not point at a file: {key_path}")
        tls = TLSConfig(
            client_cert=cert_path.read_bytes(),
            client_private_key=key_path.read_bytes(),
        )
    LOG.info(
        "connecting to Temporal at %s namespace=%s tls=%s",
        address,
        namespace,
        bool(tls),
    )
    return await Client.connect(address, namespace=namespace, tls=tls)


async def _run(args: argparse.Namespace) -> None:
    # Sanity-check that the worker has every secret/var its activities need
    # BEFORE connecting (so a misconfigured runner fails fast).
    _required_env("GITLAB_TOKEN")
    node_id = _required_env("NODE_ID")

    client = await _connect_client()
    task_queue = args.task_queue or f"acpx-worktree-{node_id}"

    LOG.info("worker starting: task_queue=%s node_id=%s", task_queue, node_id)

    worker = Worker(
        client,
        task_queue=task_queue,
        workflows=[CampaignWorkflow, IssueAttemptWorkflow],
        activities=[
            # Registration order mirrors the CampaignWorkflow bootstrap
            # sequence (A1 → A2 → A2b → A3 → A4 → …) so a reader can
            # follow the tick lifecycle top-to-bottom.
            # Orchestrator (A1–A6)
            reconcile_gitlab,
            ensure_workflow_labels,
            self_heal_safety_bin,
            clone_or_pull_repo,
            load_ui_account_pool,
            allocate_attempt_number,
            prepare_attempt_worktree,
            build_executor_prompt,
            mark_issue_doing,
            record_attempt_outcome,
            # Leaf (A7–A16)
            run_claude_code_attempt,
            stage_and_guard,
            commit_and_push,
            post_push_verify,
            upload_wiki_artifacts,
            transition_label_doing_to_done,
            create_or_rotate_mr,
            add_pr_label,
            summarize_attempt,
            sync_terminal_labels,
        ],
        max_concurrent_activities=args.max_concurrent_activities,
        max_concurrent_workflow_tasks=args.max_concurrent_workflow_tasks,
    )

    LOG.info("worker ready, polling…")
    await worker.run()


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(
        level=args.log_level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        LOG.info("interrupted")
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
