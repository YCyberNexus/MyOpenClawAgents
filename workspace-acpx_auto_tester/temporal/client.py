"""Schedule + workflow management CLI.

Five subcommands:

* ``create-schedule``   — create the campaign Schedule with BUFFER_ONE overlap.
* ``pause-schedule``    — pause a running Schedule.
* ``resume-schedule``   — unpause.
* ``delete-schedule``   — tear down.
* ``update-scope``      — signal a running :class:`CampaignWorkflow` with a
                          new hard IID scope.
* ``start-attempt``     — kick off a one-off :class:`IssueAttemptWorkflow` for
                          PoC / manual replay.

All commands connect via the same env-var contract as ``worker.py``
(TEMPORAL_ADDRESS / TEMPORAL_NAMESPACE, plus the optional mTLS pair
TEMPORAL_TLS_CERT / TEMPORAL_TLS_KEY — set both for Temporal Cloud, leave
both unset for a plaintext ``temporal server start-dev``). ``--input-file``
JSON values are validated against :class:`CampaignInput` /
:class:`IssueAttemptWorkflowInput` before sending.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import sys
from dataclasses import asdict, fields, is_dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any, Literal, get_args, get_origin, get_type_hints

from temporalio.client import Client, TLSConfig

from .schedules.campaign_schedule import build_campaign_schedule
from .shared.types import (
    AttemptInput,
    CampaignInput,
    IssueAttemptWorkflowInput,
)

LOG = logging.getLogger("acpx_temporal.client")


# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="acpx-temporal-client",
        description="Manage acpx_auto_tester_temporal Temporal schedules and one-off workflows.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sp = subparsers.add_parser("create-schedule", help="create a campaign Schedule")
    sp.add_argument("--schedule-id", required=True)
    sp.add_argument("--task-queue", required=True)
    sp.add_argument("--interval", required=True, help="e.g. 55m / 1h / 30s")
    sp.add_argument("--input-file", required=True, help="JSON matching CampaignInput")
    sp.add_argument("--note", default="")

    for cmd in ("pause-schedule", "resume-schedule", "delete-schedule"):
        sp = subparsers.add_parser(cmd, help=cmd)
        sp.add_argument("--schedule-id", required=True)
        if cmd != "delete-schedule":
            sp.add_argument("--note", default="")

    sp = subparsers.add_parser(
        "update-scope",
        help="signal a running CampaignWorkflow with a new IID scope",
    )
    workflow_selector = sp.add_mutually_exclusive_group(required=True)
    workflow_selector.add_argument(
        "--schedule-id",
        help="schedule id; workflow id is derived as '<schedule-id>:run'",
    )
    workflow_selector.add_argument("--workflow-id", help="CampaignWorkflow id")
    sp.add_argument("--issue-min-iid", required=True, type=int)
    sp.add_argument("--issue-max-iid", required=True, type=int)
    sp.add_argument(
        "--issue-iids",
        default="",
        help="optional comma-separated IID whitelist layered on top of the range",
    )

    sp = subparsers.add_parser("start-attempt", help="one-off IssueAttemptWorkflow")
    sp.add_argument("--task-queue", required=True)
    sp.add_argument("--workflow-id", required=True, help="e.g. issue:px_ifp_hulat:42")
    sp.add_argument("--input-file", required=True, help="JSON matching IssueAttemptWorkflowInput")

    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# Connection helper (mirrors worker.py)
# ---------------------------------------------------------------------------


def _required_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        raise SystemExit(f"missing required env var {name!r}")
    return val


async def _connect() -> Client:
    address = _required_env("TEMPORAL_ADDRESS")
    namespace = _required_env("TEMPORAL_NAMESPACE")
    # TLS is opt-in and mirrors worker.py: set BOTH TEMPORAL_TLS_CERT and
    # TEMPORAL_TLS_KEY for Temporal Cloud mTLS; leave both unset for a
    # plaintext ``temporal server start-dev`` connection.
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


# ---------------------------------------------------------------------------
# Helpers: JSON file → dataclass
# ---------------------------------------------------------------------------


_INTERVAL_RE = re.compile(r"^(\d+)\s*([smhd]?)$")


def _parse_interval(s: str) -> timedelta:
    """Parse ``"55m"`` / ``"1h"`` / ``"30s"`` / ``"2d"`` / plain seconds."""
    m = _INTERVAL_RE.match(s.strip().lower())
    if not m:
        raise SystemExit(f"invalid --interval value: {s!r}")
    value, unit = int(m.group(1)), m.group(2) or "s"
    return {
        "s": timedelta(seconds=value),
        "m": timedelta(minutes=value),
        "h": timedelta(hours=value),
        "d": timedelta(days=value),
    }[unit]


def _dataclass_from_json(path: str, cls: type) -> Any:
    """Hydrate ``cls`` (a dataclass) from a JSON file. Tuples are kept as
    JSON arrays; nested dataclasses are recursively hydrated.

    Annotations on this codebase are PEP-563-style strings (``from __future__
    import annotations`` is enabled in every module), so ``Field.type`` is a
    string at runtime. We resolve those via :func:`typing.get_type_hints`
    once per dataclass and pass real type objects down to :func:`_hydrate`.
    """
    if not is_dataclass(cls):
        raise TypeError(f"{cls} is not a dataclass")
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    return _hydrate(cls, raw)


def _parse_iid_csv(value: str) -> tuple[int, ...]:
    if not value.strip():
        return ()
    iids: list[int] = []
    for part in value.split(","):
        item = part.strip()
        if not item:
            continue
        try:
            iid = int(item)
        except ValueError as exc:
            raise SystemExit(f"invalid --issue-iids value: {value!r}") from exc
        if iid < 1:
            raise SystemExit(f"invalid --issue-iids value: {value!r}")
        iids.append(iid)
    return tuple(sorted(set(iids)))


def _hydrate(cls: Any, raw: Any) -> Any:
    """Recursively map JSON value into nested dataclass instances.

    Plain scalars pass through; ``tuple[X, ...]`` / ``list[X]`` generic types
    recurse on the element type; nested dataclass fields are looked up via
    :func:`typing.get_type_hints` so PEP-563 forward-reference strings are
    resolved at the right namespace.
    """
    # Top-of-recursion: real dataclass class (not a typing generic, not a
    # forward-ref string).
    if isinstance(cls, type) and is_dataclass(cls):
        if not isinstance(raw, dict):
            raise TypeError(
                f"expected dict for {cls.__name__}, got {type(raw).__name__}"
            )
        # Resolve string annotations once per dataclass.
        hints = get_type_hints(cls)
        kwargs: dict[str, Any] = {}
        for f in fields(cls):
            if f.name in raw:
                ftype = hints.get(f.name, f.type)
                kwargs[f.name] = _hydrate(ftype, raw[f.name])
        return cls(**kwargs)

    # Generic alias: tuple[X, ...] / list[X] / Literal[...] / X | None
    origin = get_origin(cls)
    args = get_args(cls)

    if origin is Literal:
        # Validate the JSON value against the Literal members so a typo in
        # the operator-supplied input file fails loudly here, not deep
        # inside a workflow activity.
        if raw not in args:
            raise ValueError(
                f"value {raw!r} is not a valid Literal value; expected one of {args}"
            )
        return raw

    if origin is tuple and args:
        item_cls = args[0]
        return tuple(_hydrate(item_cls, x) for x in raw)
    if origin is list and args:
        item_cls = args[0]
        return [_hydrate(item_cls, x) for x in raw]

    # Plain scalar (str/int/bool/Enum). Caller's dataclass __init__ will
    # raise TypeError on type mismatch, which is the right failure mode for
    # a malformed JSON input.
    return raw


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


async def _cmd_create_schedule(args: argparse.Namespace, client: Client) -> int:
    inp: CampaignInput = _dataclass_from_json(args.input_file, CampaignInput)
    inp = inp.validated()
    schedule = build_campaign_schedule(
        schedule_id=args.schedule_id,
        task_queue=args.task_queue,
        interval=_parse_interval(args.interval),
        input_payload=inp,
        note=args.note,
    )
    handle = await client.create_schedule(args.schedule_id, schedule)
    LOG.info("created schedule %s (handle=%r)", args.schedule_id, handle)
    return 0


async def _cmd_pause_schedule(args: argparse.Namespace, client: Client) -> int:
    handle = client.get_schedule_handle(args.schedule_id)
    await handle.pause(note=args.note or "paused via acpx-temporal-client")
    LOG.info("paused schedule %s", args.schedule_id)
    return 0


async def _cmd_resume_schedule(args: argparse.Namespace, client: Client) -> int:
    handle = client.get_schedule_handle(args.schedule_id)
    await handle.unpause(note=args.note or "resumed via acpx-temporal-client")
    LOG.info("resumed schedule %s", args.schedule_id)
    return 0


async def _cmd_delete_schedule(args: argparse.Namespace, client: Client) -> int:
    handle = client.get_schedule_handle(args.schedule_id)
    await handle.delete()
    LOG.info("deleted schedule %s", args.schedule_id)
    return 0


async def _cmd_update_scope(args: argparse.Namespace, client: Client) -> int:
    workflow_id = args.workflow_id or f"{args.schedule_id}:run"
    if args.issue_min_iid < 1:
        raise SystemExit("--issue-min-iid must be >= 1")
    if args.issue_max_iid < args.issue_min_iid:
        raise SystemExit("--issue-max-iid must be >= --issue-min-iid")

    issue_iids = _parse_iid_csv(args.issue_iids)
    handle = client.get_workflow_handle(workflow_id)
    await handle.signal(
        "update_scope",
        args.issue_min_iid,
        args.issue_max_iid,
        issue_iids,
    )
    LOG.info(
        "signaled workflow %s update_scope min=%d max=%d issue_iids=%s",
        workflow_id,
        args.issue_min_iid,
        args.issue_max_iid,
        list(issue_iids),
    )
    return 0


async def _cmd_start_attempt(args: argparse.Namespace, client: Client) -> int:
    inp: IssueAttemptWorkflowInput = _dataclass_from_json(
        args.input_file, IssueAttemptWorkflowInput
    )
    inp.campaign.validated()
    handle = await client.start_workflow(
        "IssueAttemptWorkflow",
        inp,
        id=args.workflow_id,
        task_queue=args.task_queue,
    )
    LOG.info(
        "started IssueAttemptWorkflow %s (run_id=%s)",
        args.workflow_id,
        handle.first_execution_run_id,
    )
    # Dump the input we sent for audit (sans secrets — there are none on
    # AttemptInput; GITLAB_TOKEN is worker env, not workflow input).
    LOG.debug("input payload: %s", json.dumps(asdict(inp), default=str)[:500])
    return 0


_COMMANDS = {
    "create-schedule": _cmd_create_schedule,
    "pause-schedule": _cmd_pause_schedule,
    "resume-schedule": _cmd_resume_schedule,
    "delete-schedule": _cmd_delete_schedule,
    "update-scope": _cmd_update_scope,
    "start-attempt": _cmd_start_attempt,
}


async def _run(args: argparse.Namespace) -> int:
    client = await _connect()
    return await _COMMANDS[args.command](args, client)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(
        level=getattr(args, "log_level", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        return asyncio.run(_run(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())


# Re-export to satisfy unused-import lints (these types are used in the
# JSON-hydration path but mypy doesn't see that through string annotations).
_ = (AttemptInput,)
