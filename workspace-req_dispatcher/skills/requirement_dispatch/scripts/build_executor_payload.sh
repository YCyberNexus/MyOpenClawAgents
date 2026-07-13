#!/usr/bin/env bash
# Build the exact RUN_SINGLE_ISSUE trigger req_dispatcher sends to req_executor.
set -euo pipefail

: "${PROJECT:?PROJECT required}"
: "${IID:?IID required}"
: "${CORRELATION_ID:?CORRELATION_ID required}"

DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}"
TARGET_BRANCH="${TARGET_BRANCH:-}"
EXECUTOR_AGENT="${EXECUTOR_AGENT:-}"
CALLBACK_NONCE="${CALLBACK_NONCE:-}"
ALLOW_LEGACY_PRE_UPGRADE="${ALLOW_LEGACY_PRE_UPGRADE:-false}"

[ -n "${DISPATCHER_CALLBACK_TARGET}" ] \
  || { echo "DISPATCHER_CALLBACK_TARGET must not be empty" >&2; exit 2; }

case "${DISPATCHER_CALLBACK_TARGET}" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "DISPATCHER_CALLBACK_TARGET must not contain control characters" >&2
    exit 2
    ;;
esac
if LC_ALL=C printf '%s' "${DISPATCHER_CALLBACK_TARGET}" | grep -q '[[:cntrl:]]'; then
  echo "DISPATCHER_CALLBACK_TARGET must not contain control characters" >&2
  exit 2
fi

if [ -n "${CALLBACK_NONCE}" ]; then
  [ -n "${EXECUTOR_AGENT}" ] \
    || { echo "EXECUTOR_AGENT must not be empty for authenticated callbacks" >&2; exit 2; }
  if ! [[ "${CALLBACK_NONCE}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "CALLBACK_NONCE must be 64 lowercase hexadecimal characters" >&2
    exit 2
  fi
  case "${EXECUTOR_AGENT}" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "EXECUTOR_AGENT must not contain control characters" >&2
      exit 2
      ;;
  esac
  if LC_ALL=C printf '%s' "${EXECUTOR_AGENT}" | grep -q '[[:cntrl:]]'; then
    echo "EXECUTOR_AGENT must not contain control characters" >&2
    exit 2
  fi
elif [ "${ALLOW_LEGACY_PRE_UPGRADE}" != true ]; then
  echo "CALLBACK_NONCE is required for new RUN_SINGLE_ISSUE requests" >&2
  exit 2
fi

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
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

if [ -n "${CALLBACK_NONCE}" ]; then
  printf 'executor_agent=%s\n' "${EXECUTOR_AGENT}"
  printf 'callback_nonce=%s\n' "${CALLBACK_NONCE}"
fi

if [ -n "${TARGET_BRANCH}" ]; then
  printf 'branch=%s\n' "${TARGET_BRANCH}"
fi
