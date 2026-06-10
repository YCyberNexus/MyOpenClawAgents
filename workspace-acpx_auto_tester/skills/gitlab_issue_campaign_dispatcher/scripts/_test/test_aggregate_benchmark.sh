#!/usr/bin/env bash
# Local smoke test for aggregate_benchmark.sh — runnable on the dev machine
# (no acpx / glab). Feeds a fixture ledger via LEDGER_FILE and asserts the
# rendered issue × model matrix.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
out="$(LEDGER_FILE="${HERE}/fixtures/metrics.jsonl" bash "${SCRIPTS}/aggregate_benchmark.sh")"
echo "${out}"
echo "${out}" | grep -q "flash" || { echo "FAIL: no flash column"; exit 1; }
echo "${out}" | grep -q "pro"   || { echo "FAIL: no pro column"; exit 1; }
echo "${out}" | grep -q "#14"   || { echo "FAIL: no issue 14 row"; exit 1; }
echo "${out}" | grep -q "90%"   || { echo "FAIL: pro pass_rate 90% missing"; exit 1; }
echo "${out}" | grep -q "n/a"   || { echo "FAIL: unavailable accuracy not shown as n/a"; exit 1; }
echo "PASS test_aggregate_benchmark"
