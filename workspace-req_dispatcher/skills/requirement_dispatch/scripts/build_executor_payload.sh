#!/usr/bin/env bash
# Build the exact RUN_SINGLE_ISSUE trigger req_dispatcher sends to req_executor.
set -euo pipefail

: "${PROJECT:?PROJECT required}"
: "${IID:?IID required}"
: "${CORRELATION_ID:?CORRELATION_ID required}"

DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}"
TARGET_BRANCH="${TARGET_BRANCH:-${BRANCH:-}}"

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\[*|*\]*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ] || return 1
  return 0
}

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

if [ -n "${TARGET_BRANCH}" ] && ! validate_branch_name "${TARGET_BRANCH}"; then
  echo "branch must be a safe Git ref name, got: ${TARGET_BRANCH}" >&2
  exit 2
fi

cat <<EOF
RUN_SINGLE_ISSUE
project=${PROJECT}
iid=${IID}
correlation_id=${CORRELATION_ID}
dispatcher_callback_target=${DISPATCHER_CALLBACK_TARGET}
EOF

if [ -n "${TARGET_BRANCH}" ]; then
  printf 'branch=%s\n' "${TARGET_BRANCH}"
fi
