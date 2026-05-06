#!/usr/bin/env bash
# Deprecated executor entrypoint. Repo clone/fetch is dispatcher-owned.
set -euo pipefail
echo "clone_or_pull.sh is dispatcher-owned; run skills/gitlab_issue_campaign_dispatcher/scripts/clone_or_pull.sh before RUN_PREPARED_ISSUE_WORKER." >&2
exit 64
