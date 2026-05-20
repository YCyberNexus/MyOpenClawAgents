"""Schedule + workflow management CLI.

Five subcommands:

* ``create-schedule``   — create the campaign Schedule with BUFFER_ONE overlap.
* ``pause-schedule``    — pause a running Schedule.
* ``resume-schedule``   — unpause.
* ``delete-schedule``   — tear down.
* ``start-attempt``     — kick off a one-off :class:`IssueAttemptWorkflow` for
                          PoC / manual replay.

All commands connect to Temporal Cloud via the same env-var contract as
``worker.py`` (TEMPORAL_ADDRESS / TEMPORAL_NAMESPACE / TEMPORAL_TLS_CERT /
TEMPORAL_TLS_KEY). ``--input-file`` JSON values are validated against
:class:`CampaignInput` / :class:`IssueAttemptWorkflowInput` before sending.
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
        description="Manage acpx_auto_tester Temporal schedules and one-off workflows.",
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
    cert = Path(_required_env("TEMPORAL_TLS_CERT")).read_bytes()
    key = Path(_required_env("TEMPORAL_TLS_KEY")).read_bytes()
    return await Client.connect(
        address, namespace=namespace, tls=TLSConfig(client_cert=cert, client_private_key=key)
    )


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
