#!/usr/bin/env bash
# collect_metrics.sh — BEST-EFFORT observation script. Writes ${LOG_DIR}/metrics.json
# with efficiency (wall_clock_seconds from ${LOG_DIR}/timing.txt) and accuracy
# (robot pass rate parsed from Robot Framework output.xml under ${OUTPUT_DIR}).
#
# It NEVER fails the attempt: missing/garbled inputs → the relevant field is
# null / available:false and the script still exits 0. This is a DELIBERATE
# exception to the strict no-fallback policy because metrics are observational,
# not a work product. Only a genuine bash/IO fault (e.g. unwritable LOG_DIR)
# is fatal.
#
# Required env: LOG_DIR, OUTPUT_DIR, ISSUE_IID, ATTEMPT_NUMBER
# Optional env: MODEL (the pinned tier name)
#               COLLECT_METRICS_SKIP_ENV_PATHS=1  (unit-test escape hatch:
#                   skip sourcing env_paths.sh so the script can run from
#                   fixtures without the full trigger env)
#
# Output: writes ${LOG_DIR}/metrics.json and prints its path on stdout.

# NOTE: intentionally NOT `set -e` — best-effort. Keep -u/-o pipefail off too
# so a missing optional var never aborts.
set +e

if [ "${COLLECT_METRICS_SKIP_ENV_PATHS:-0}" != "1" ]; then
  # __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"
fi

: "${LOG_DIR:?collect_metrics: LOG_DIR required}"
: "${OUTPUT_DIR:?collect_metrics: OUTPUT_DIR required}"
: "${ISSUE_IID:?collect_metrics: ISSUE_IID required}"
: "${ATTEMPT_NUMBER:?collect_metrics: ATTEMPT_NUMBER required}"
MODEL="${MODEL:-}"

mkdir -p "${LOG_DIR}"
metrics_file="${LOG_DIR}/metrics.json"

# ── efficiency: wall_clock_seconds from timing.txt ───────────────────────────
wall="null"
timing="${LOG_DIR}/timing.txt"
if [ -f "${timing}" ]; then
  s="$(sed -n 's/^start_epoch=//p' "${timing}" | head -n1)"
  e="$(sed -n 's/^end_epoch=//p'   "${timing}" | head -n1)"
  case "${s}${e}" in
    ''|*[!0-9]*) : ;;                       # non-numeric → leave null
    *) [ "${e}" -ge "${s}" ] && wall="$(( e - s ))" ;;
  esac
fi

# ── accuracy: robot pass rate from Robot Framework output.xml ─────────────────
acc_json='{"available":false}'
if command -v python3 >/dev/null 2>&1; then
  parsed="$(python3 - "${OUTPUT_DIR}" <<'PY'
import sys, os, json, glob
import xml.etree.ElementTree as ET
out_dir = sys.argv[1]
files = glob.glob(os.path.join(out_dir, "**", "output.xml"), recursive=True)
passed = failed = skipped = 0
found = False
for f in files:
    try:
        root = ET.parse(f).getroot()
    except Exception:
        continue
    stat = None
    for s in root.findall("./statistics/total/stat"):
        stat = s  # the LAST total/stat is Robot Framework's "All Tests" row
    if stat is None:
        continue
    found = True
    passed  += int(stat.get("pass", 0) or 0)
    failed  += int(stat.get("fail", 0) or 0)
    skipped += int(stat.get("skip", 0) or 0)
if not found:
    print(json.dumps({"available": False}))
else:
    denom = passed + failed
    rate = round(passed / denom, 4) if denom else None
    print(json.dumps({"available": True, "passed": passed, "failed": failed,
                      "skipped": skipped, "total": passed + failed + skipped,
                      "pass_rate": rate, "robot_files": len(files)}))
PY
)"
  if [ -n "${parsed}" ] && echo "${parsed}" | jq -e . >/dev/null 2>&1; then
    acc_json="${parsed}"
  fi
fi

# ── assemble metrics.json ─────────────────────────────────────────────────────
jq -nc \
  --argjson iid "${ISSUE_IID}" \
  --argjson attempt "${ATTEMPT_NUMBER}" \
  --arg model "${MODEL}" \
  --argjson wall "${wall}" \
  --argjson accuracy "${acc_json}" \
  '{iid:$iid, attempt_number:$attempt,
    model:(if $model=="" then null else $model end),
    wall_clock_seconds:$wall,
    accuracy:$accuracy}' > "${metrics_file}"

echo "${metrics_file}"
exit 0
