#!/usr/bin/env bash
# Deprecated executor entrypoint. Prompt generation is dispatcher-owned.
set -euo pipefail
echo "build_prompt.sh is dispatcher-owned; run skills/gitlab_issue_campaign_dispatcher/scripts/build_prompt.sh before RUN_PREPARED_ISSUE_WORKER." >&2
exit 64
