#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "${TEST_DIR}/test_openclaw_agent_gateway_v4.mjs"
