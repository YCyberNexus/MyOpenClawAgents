#!/usr/bin/env bash
set -euo pipefail

stage_name="$(basename "$0" .sh)"
printf '%s\n' "${stage_name}" >>"${TICK_ORDER_LOG:?}"

if [ "${stage_name}" = "evict" ]; then
  printf '%s\n' "evicted 0"
else
  jq -nc --arg stage "${stage_name}" '{status:"fixture",stage:$stage}'
fi
