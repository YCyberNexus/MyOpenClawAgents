#!/usr/bin/env bash
# aggregate_benchmark.sh — read the benchmark metrics ledger and print an
# issue × model matrix (wall_clock_seconds / pass_rate) as markdown to stdout.
# For each (iid, model) the LATEST appended record wins.
#
# Env:
#   LEDGER_FILE   override the ledger path (used by the unit test). When unset,
#                 env_paths.sh derives ${RESULT_ROOT}/_dispatcher/benchmark/metrics.jsonl.
#
# The ledger is the append-only JSONL written by phase6_write_state_files
# (one line per terminal `done` attempt). Each line carries at least:
#   {iid, attempt_number, model, wall_clock_seconds, accuracy:{available,pass_rate,...}, status, ts}

set -euo pipefail

if [ -n "${LEDGER_FILE:-}" ]; then
  ledger="${LEDGER_FILE}"
else
  # __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"
  ledger="${RESULT_ROOT}/_dispatcher/benchmark/metrics.jsonl"
fi

if [ ! -f "${ledger}" ]; then
  echo "no benchmark ledger at ${ledger}" >&2
  exit 0
fi

# Slurp the JSONL into an array, keep the latest record per (iid, model)
# (group_by is stable, so within a key the last appended line is .[-1]),
# then render a markdown matrix: rows = issues, columns = models,
# cell = "<wall_clock_seconds>s / <pass_rate>%" (or "n/a" when accuracy
# is unavailable, "-" when that (iid, model) was never run).
jq -rs '
  (group_by([.iid, .model]) | map(.[-1])) as $rows
  | ($rows | map(.model) | unique) as $models
  | ($rows | map(.iid)   | unique | sort) as $iids
  | "# benchmark matrix (wall_clock_seconds / pass_rate)",
    "",
    ("| issue | " + ($models | join(" | ")) + " |"),
    ("|---|" + ($models | map("---") | join("|")) + "|"),
    ( $iids[] as $i
      | "| #\($i) | "
        + ( [ $models[] as $m
              | ( [ $rows[] | select(.iid==$i and .model==$m) ] | first ) as $r
              | if $r == null then "-"
                else "\($r.wall_clock_seconds)s / "
                     + ( if (($r.accuracy.available // false) == true) and ($r.accuracy.pass_rate != null)
                         then "\((($r.accuracy.pass_rate) * 100) | floor)%"
                         else "n/a" end )
                end
            ] | join(" | ") )
        + " |" )
' "${ledger}"
