#!/usr/bin/env bash
set -euo pipefail

PREFIX="${HOME}/.local/openclaw-offline"

usage() {
  cat <<EOF
Usage: bash verify.sh [options]

Options:
  --prefix PATH   Install root. Default: ${PREFIX}
  -h, --help      Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="${2:?missing value for --prefix}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

OPENCLAW_BIN="${PREFIX}/bin/openclaw"
NODE_BIN="${PREFIX}/bin/node"
NPM_BIN="${PREFIX}/bin/npm"

for file in "${OPENCLAW_BIN}" "${NODE_BIN}" "${NPM_BIN}"; do
  if [ ! -x "${file}" ]; then
    echo "missing executable: ${file}" >&2
    exit 1
  fi
done

echo "Node:"
"${NODE_BIN}" --version

echo "npm:"
"${NPM_BIN}" --version

echo "OpenClaw:"
"${OPENCLAW_BIN}" --version

echo "OpenClaw config validation:"
"${OPENCLAW_BIN}" config validate

echo "OK"
