"""Pure-Python helpers shared across workflows + activities.

Nothing in this subpackage is allowed to import :mod:`temporalio.workflow` —
these modules are loaded from inside workflow code, where the determinism
sandbox forbids most stdlib I/O. Activities and the worker entrypoint may
import freely.
"""
