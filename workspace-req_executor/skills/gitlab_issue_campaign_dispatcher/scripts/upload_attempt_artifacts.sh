#!/usr/bin/env bash
# upload_attempt_artifacts.sh -- legacy compatibility shim.
#
# req_executor no longer publishes prompt.txt, claude_result.txt, or report.html
# to GitLab Wiki pages. The file remains only so already-rendered outer prompts
# from older deployments can call it without blocking the run. It intentionally
# does not source env_paths.sh and does not call glab.

set -euo pipefail

printf '\n'
