#!/usr/bin/env bash
# Source req_dispatcher deployment pins, then optional local overrides.
#
# Usage from the skill dir:
#   source scripts/source_dispatcher_env.sh
#
# Tests may set DISPATCHER_CONFIG_DIR to a throwaway config directory.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "source_dispatcher_env.sh: source this file instead of executing it" >&2
  exit 2
fi

SOURCE_DISPATCHER_ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DISPATCHER_ENV_SKILL_DIR="$(cd "${SOURCE_DISPATCHER_ENV_SCRIPT_DIR}/.." && pwd)"
SOURCE_DISPATCHER_ENV_CONFIG_DIR="${DISPATCHER_CONFIG_DIR:-$(cd "${SOURCE_DISPATCHER_ENV_SKILL_DIR}/../.." && pwd)/config}"

if [ ! -f "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.env" ]; then
  echo "source_dispatcher_env.sh: missing dispatcher.env at ${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.env" >&2
  return 2
fi

set -a
# shellcheck disable=SC1091
source "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.env"
if [ -f "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.local.env" ]; then
  # shellcheck disable=SC1091
  source "${SOURCE_DISPATCHER_ENV_CONFIG_DIR}/dispatcher.local.env"
fi
set +a

unset SOURCE_DISPATCHER_ENV_SCRIPT_DIR
unset SOURCE_DISPATCHER_ENV_SKILL_DIR
unset SOURCE_DISPATCHER_ENV_CONFIG_DIR
