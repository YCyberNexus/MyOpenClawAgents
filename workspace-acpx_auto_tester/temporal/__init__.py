"""acpx_temporal — Temporal (Python SDK) port of the acpx_auto_tester dispatcher.

See README.md for layout and runtime contract. The on-disk directory is named
``temporal/`` but the Python package is importable as ``acpx_temporal``
(remapped via ``pyproject.toml`` ``[tool.setuptools.package-dir]``).
"""

__all__ = ["__version__"]
__version__ = "0.1.0"
