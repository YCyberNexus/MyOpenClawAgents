"""Effective model-tier ladder derivation (v2 tier auto-discovery).

Python twin of ``_dispatch_lib.sh::derive_effective_model_tiers``: the
configured ``model_tiers`` is the ordered *wisdom superset* (lowest → highest),
and the actual per-deployment upgrade ladder is the EFFECTIVE subset whose
``<tier>-settings.json`` exists and is readable under ``model_settings_dir``
— order preserved, re-derived each tick.

Filesystem access lives here (NOT in workflow code): this helper is sync and
reads the worker host's disk, so it must only be called from inside an
activity (``activities/orchestrator.py::derive_effective_tiers``). Workflow
code receives the result through that activity and threads it downstream via
``CampaignInput.effective_model_tiers``.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Sequence


def derive_effective_model_tiers(
    model_tiers: Sequence[str],
    model_settings_dir: str,
) -> tuple[str, ...]:
    """Return the EFFECTIVE ordered model-tier ladder.

    Mirrors the bash helper's contract exactly:

    * ``model_settings_dir`` empty → returns ``model_tiers`` unchanged
      (auto-discovery disabled; legacy behavior — the tier is then only a
      prompt-text hint).
    * configured → returns the subset of ``model_tiers`` for which
      ``${model_settings_dir}/<tier>-settings.json`` is readable (bash
      ``[ -r … ]``, mirrored with ``os.access(…, os.R_OK)``), preserving
      ``model_tiers`` order.
    * configured but nothing matches → returns the empty tuple; the caller
      decides (the prepare path aborts the tick with
      ``no_model_settings_files``; there is no Temporal followup path — the
      next tick re-derives).

    Args:
        model_tiers: ordered tier names (the FULL configured list, e.g.
            ``("flash", "pro", "max")``).
        model_settings_dir: absolute directory holding the per-tier settings
            files, or the empty string when unconfigured.
    """
    if not model_settings_dir:
        return tuple(model_tiers)
    base = Path(model_settings_dir)
    return tuple(
        tier
        for tier in model_tiers
        if os.access(base / f"{tier}-settings.json", os.R_OK)
    )


__all__ = ["derive_effective_model_tiers"]
