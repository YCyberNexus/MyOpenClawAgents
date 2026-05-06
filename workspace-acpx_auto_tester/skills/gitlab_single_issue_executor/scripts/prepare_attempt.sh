#!/usr/bin/env bash
# Deprecated executor entrypoint. Worktree preparation is dispatcher-owned.
set -euo pipefail
echo "prepare_attempt.sh is dispatcher-owned; run skills/gitlab_issue_campaign_dispatcher/scripts/prepare_attempt.sh before RUN_PREPARED_ISSUE_WORKER." >&2
exit 64
