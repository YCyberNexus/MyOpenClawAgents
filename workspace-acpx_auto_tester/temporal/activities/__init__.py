"""Activity implementations. Each activity is a thin asyncio wrapper around a
``scripts/*.sh`` invocation under the dispatcher SKILL — the bash scripts are
the leaf side-effect carriers and are intentionally not rewritten.

See ``../README.md`` and the migration plan §Activity registry for the
StartToClose / RetryPolicy / heartbeat contract per activity.
"""
