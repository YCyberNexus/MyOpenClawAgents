#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_SH="${ROOT_DIR}/install.sh"

grep -F 'env -i' "${INSTALL_SH}" >/dev/null
grep -F 'npm_config_registry=https://registry.npmjs.org/' "${INSTALL_SH}" >/dev/null
grep -F 'NPM_USERCONFIG="${RELEASE_DIR}/npm-userconfig"' "${INSTALL_SH}" >/dev/null
grep -F 'NPM_GLOBALCONFIG="${RELEASE_DIR}/npm-globalconfig"' "${INSTALL_SH}" >/dev/null
grep -F 'npm_config_userconfig=${NPM_USERCONFIG}' "${INSTALL_SH}" >/dev/null
grep -F 'npm_config_globalconfig=${NPM_GLOBALCONFIG}' "${INSTALL_SH}" >/dev/null
