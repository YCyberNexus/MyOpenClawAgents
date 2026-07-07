# req_executor State Machine Summary

The issue state machine is label-driven:

- `todo` / `new` / `retry` enqueue fresh work.
- `continue` resumes an existing issue branch when available.
- `doing` marks an in-flight attempt.
- `blocked-cc`, `failed-cc`, and `timeout` describe Claude Code side outcomes.
- `blocked-dispatcher` and `failed-dispatcher` describe wrapper or orchestration side outcomes.
- `pr` marks successful MR creation/update.

The current executor prompt is built from the GitLab issue content plus prior attempt summaries and reviewer comments. Runtime state lives under `.req_executor/`; project-specific fixtures or credentials must be supplied by the issue or repository, not by executor trigger fields.
