#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_SH="${ROOT_DIR}/install.sh"

grep -F 'Gateway service could not be installed or started automatically.' "${INSTALL_SH}" >/dev/null
grep -F 'The CLI installation is complete.' "${INSTALL_SH}" >/dev/null
grep -F 'To run Gateway without systemd user services:' "${INSTALL_SH}" >/dev/null
grep -F 'openclaw gateway run' "${INSTALL_SH}" >/dev/null

if grep -F 'gateway service install failed; CLI installation is still complete' "${INSTALL_SH}" >/dev/null; then
  echo "gateway service install failure must not force installer exit" >&2
  exit 1
fi
