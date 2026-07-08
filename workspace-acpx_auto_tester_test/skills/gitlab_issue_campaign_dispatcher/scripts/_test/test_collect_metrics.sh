#!/usr/bin/env bash
# Local smoke test for collect_metrics.sh — runnable on the dev machine
# (no acpx / glab). Builds a throwaway LOG_DIR + OUTPUT_DIR from fixtures.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
LOG_DIR="${TMP}/log"; OUTPUT_DIR="${TMP}/out"
mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}/hulat-spec-issue14"
cp "${HERE}/fixtures/timing.txt"     "${LOG_DIR}/timing.txt"
cp "${HERE}/fixtures/output_pass.xml" "${OUTPUT_DIR}/hulat-spec-issue14/output.xml"

out="$(LOG_DIR="${LOG_DIR}" OUTPUT_DIR="${OUTPUT_DIR}" ISSUE_IID=14 ATTEMPT_NUMBER=3 MODEL=pro \
  COLLECT_METRICS_SKIP_ENV_PATHS=1 bash "${SCRIPTS}/collect_metrics.sh")"

mf="${LOG_DIR}/metrics.json"
[ -f "${mf}" ] || { echo "FAIL: metrics.json not written"; exit 1; }
wall="$(jq -r '.wall_clock_seconds' "${mf}")"
passed="$(jq -r '.accuracy.passed' "${mf}")"
rate="$(jq -r '.accuracy.pass_rate' "${mf}")"
[ "${wall}" = "842" ]   || { echo "FAIL: wall=${wall} expected 842"; exit 1; }
[ "${passed}" = "18" ]  || { echo "FAIL: passed=${passed} expected 18"; exit 1; }
[ "${rate}" = "0.9" ]   || { echo "FAIL: pass_rate=${rate} expected 0.9"; exit 1; }
echo "PASS test_collect_metrics"
