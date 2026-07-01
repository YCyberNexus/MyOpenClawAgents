#!/usr/bin/env bash
# Compatibility entrypoint for agents that invoke scripts/ from the workspace
# root instead of the skill directory.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SCRIPT_DIR}/../skills/gitlab_issue_campaign_dispatcher"
cd "${SKILL_DIR}"
exec bash scripts/dispatch_single_issue.sh "$@"
