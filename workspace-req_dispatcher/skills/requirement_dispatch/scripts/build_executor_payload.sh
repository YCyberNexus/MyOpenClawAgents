#!/usr/bin/env bash
# Build the exact RUN_SINGLE_ISSUE trigger req_dispatcher sends to req_executor.
set -euo pipefail

: "${PROJECT:?PROJECT required}"
: "${IID:?IID required}"
: "${CORRELATION_ID:?CORRELATION_ID required}"

DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}"

case "${PROJECT}" in
  */*) ;;
  *)
    echo "PROJECT must be <group>/<project>, got: ${PROJECT}" >&2
    exit 2
    ;;
esac

case "${PROJECT}" in
  */|/*|*//*)
    echo "PROJECT must be <group>/<project>, got: ${PROJECT}" >&2
    exit 2
    ;;
esac

case "${IID}" in
  *[!0-9]*|"")
    echo "IID must be a positive integer, got: ${IID}" >&2
    exit 2
    ;;
  0)
    echo "IID must be a positive integer, got: ${IID}" >&2
    exit 2
    ;;
esac

cat <<EOF
RUN_SINGLE_ISSUE
project=${PROJECT}
iid=${IID}
correlation_id=${CORRELATION_ID}
dispatcher_callback_target=${DISPATCHER_CALLBACK_TARGET}
EOF
