#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_VERSION="2026.6.11"
NODE_VERSION="22.19.0"
PACKAGE_NAME="openclaw-rhel7-offline-${OPENCLAW_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PAYLOAD_DIR="${SCRIPT_DIR}/payload"

PREFIX="${HOME}/.local/openclaw-offline"
BIN_DIR="${HOME}/.local/bin"
WORKSPACE_DIR="${HOME}/.openclaw/workspace"
RUN_SETUP=1
INSTALL_GATEWAY_SERVICE=0

usage() {
  cat <<EOF
Usage: bash install.sh [options]

Options:
  --prefix PATH                 Install root. Default: ${PREFIX}
  --bin-dir PATH                Directory for openclaw wrapper. Default: ${BIN_DIR}
  --workspace PATH              OpenClaw workspace for setup. Default: ${WORKSPACE_DIR}
  --skip-setup                  Do not run openclaw setup.
  --install-gateway-service     Also install and start the OpenClaw Gateway service.
  -h, --help                    Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="${2:?missing value for --prefix}"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="${2:?missing value for --bin-dir}"
      shift 2
      ;;
    --workspace)
      WORKSPACE_DIR="${2:?missing value for --workspace}"
      shift 2
      ;;
    --skip-setup)
      RUN_SETUP=0
      shift
      ;;
    --install-gateway-service)
      INSTALL_GATEWAY_SERVICE=1
      shift
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

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd uname
need_cmd tar
need_cmd gzip
need_cmd sha256sum

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64)
    ;;
  *)
    echo "unsupported architecture: ${ARCH}; this package is Linux x86_64 only" >&2
    exit 1
    ;;
esac

if command -v ldd >/dev/null 2>&1; then
  GLIBC_VERSION="$(ldd --version 2>/dev/null | head -n 1 | grep -Eo '[0-9]+\.[0-9]+' | tail -n 1 || true)"
  if [ -n "${GLIBC_VERSION}" ]; then
    GLIBC_MAJOR="${GLIBC_VERSION%%.*}"
    GLIBC_MINOR="${GLIBC_VERSION#*.}"
    if [ "${GLIBC_MAJOR}" -lt 2 ] || { [ "${GLIBC_MAJOR}" -eq 2 ] && [ "${GLIBC_MINOR}" -lt 17 ]; }; then
      echo "glibc ${GLIBC_VERSION} is too old; need glibc >= 2.17" >&2
      exit 1
    fi
  fi
fi

if [ ! -d "${PAYLOAD_DIR}" ]; then
  echo "missing payload directory: ${PAYLOAD_DIR}" >&2
  exit 1
fi

(
  cd "${PAYLOAD_DIR}"
  sha256sum -c checksums.sha256
)

NODE_ARCHIVE="${PAYLOAD_DIR}/node-v${NODE_VERSION}-linux-x64-glibc-217.tar.gz"
NPM_CACHE_ARCHIVE="${PAYLOAD_DIR}/npm-cache-openclaw-${OPENCLAW_VERSION}.tar.gz"

for file in "${NODE_ARCHIVE}" "${NPM_CACHE_ARCHIVE}"; do
  if [ ! -f "${file}" ]; then
    echo "missing payload file: ${file}" >&2
    exit 1
  fi
done

TAR_WARNING_ARGS=()
if tar --help 2>/dev/null | grep -q -- '--warning'; then
  TAR_WARNING_ARGS=(--warning=no-unknown-keyword)
fi

RELEASE_DIR="${PREFIX}/releases/openclaw-${OPENCLAW_VERSION}"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"

mkdir -p "${PREFIX}/releases" "${PREFIX}/bin" "${BIN_DIR}"

if [ -e "${RELEASE_DIR}" ]; then
  BACKUP_DIR="${RELEASE_DIR}.backup-${TIMESTAMP}"
  echo "existing release found; moving to ${BACKUP_DIR}"
  mv "${RELEASE_DIR}" "${BACKUP_DIR}"
fi

mkdir -p "${RELEASE_DIR}/node" "${RELEASE_DIR}/npm-cache" "${RELEASE_DIR}/openclaw"

echo "extracting Node ${NODE_VERSION}"
tar "${TAR_WARNING_ARGS[@]}" -xzf "${NODE_ARCHIVE}" -C "${RELEASE_DIR}/node" --strip-components=1

echo "extracting npm offline cache"
tar "${TAR_WARNING_ARGS[@]}" -xzf "${NPM_CACHE_ARCHIVE}" -C "${RELEASE_DIR}/npm-cache"

NODE_BIN="${RELEASE_DIR}/node/bin/node"
NPM_BIN="${RELEASE_DIR}/node/bin/npm"
if [ ! -x "${NODE_BIN}" ] || [ ! -x "${NPM_BIN}" ]; then
  echo "payload node/npm is not executable" >&2
  exit 1
fi

echo "installing OpenClaw ${OPENCLAW_VERSION} from offline npm cache"
export PATH="${RELEASE_DIR}/node/bin:${PATH}"
NPM_USERCONFIG="${RELEASE_DIR}/npm-userconfig"
NPM_GLOBALCONFIG="${RELEASE_DIR}/npm-globalconfig"
: > "${NPM_USERCONFIG}"
: > "${NPM_GLOBALCONFIG}"
NPM_INSTALL_ENV=(
  env -i
  "HOME=${HOME}"
  "PATH=${RELEASE_DIR}/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  'npm_config_registry=https://registry.npmjs.org/'
  "npm_config_userconfig=${NPM_USERCONFIG}"
  "npm_config_globalconfig=${NPM_GLOBALCONFIG}"
  "npm_config_cache=${RELEASE_DIR}/npm-cache"
  'npm_config_update_notifier=false'
  'npm_config_audit=false'
  'npm_config_fund=false'
)
"${NPM_INSTALL_ENV[@]}" "${NPM_BIN}" install \
  --global \
  --prefix "${RELEASE_DIR}/openclaw" \
  --cache "${RELEASE_DIR}/npm-cache" \
  --registry "https://registry.npmjs.org/" \
  --userconfig "${NPM_USERCONFIG}" \
  --globalconfig "${NPM_GLOBALCONFIG}" \
  --offline \
  --ignore-scripts \
  --include=optional \
  --no-audit \
  --no-fund \
  "openclaw@${OPENCLAW_VERSION}"

OPENCLAW_ENTRY="${RELEASE_DIR}/openclaw/bin/openclaw"
OPENCLAW_PACKAGE_ROOT="${RELEASE_DIR}/openclaw/lib/node_modules/openclaw"
if [ ! -x "${OPENCLAW_ENTRY}" ]; then
  echo "openclaw binary was not installed at ${OPENCLAW_ENTRY}" >&2
  exit 1
fi

if [ -f "${OPENCLAW_PACKAGE_ROOT}/scripts/postinstall-bundled-plugins.mjs" ]; then
  echo "running OpenClaw postinstall"
  (
    cd "${OPENCLAW_PACKAGE_ROOT}"
    "${NODE_BIN}" scripts/postinstall-bundled-plugins.mjs
  )
fi

cat > "${PREFIX}/bin/openclaw" <<EOF
#!/usr/bin/env bash
export PATH="${RELEASE_DIR}/node/bin:\$PATH"
exec "${OPENCLAW_ENTRY}" "\$@"
EOF
chmod 0755 "${PREFIX}/bin/openclaw"

cat > "${PREFIX}/bin/node" <<EOF
#!/usr/bin/env bash
exec "${RELEASE_DIR}/node/bin/node" "\$@"
EOF
chmod 0755 "${PREFIX}/bin/node"

cat > "${PREFIX}/bin/npm" <<EOF
#!/usr/bin/env bash
export PATH="${RELEASE_DIR}/node/bin:\$PATH"
exec "${RELEASE_DIR}/node/bin/npm" "\$@"
EOF
chmod 0755 "${PREFIX}/bin/npm"

ln -sfn "${PREFIX}/bin/openclaw" "${BIN_DIR}/openclaw"

if [ -f "${HOME}/.bashrc" ] && ! grep -F "${BIN_DIR}" "${HOME}/.bashrc" >/dev/null 2>&1; then
  {
    printf '\n# OpenClaw offline installer\n'
    printf 'export PATH="%s:$PATH"\n' "${BIN_DIR}"
  } >> "${HOME}/.bashrc"
fi

echo "checking OpenClaw version"
"${PREFIX}/bin/openclaw" --version

if [ "${RUN_SETUP}" -eq 1 ]; then
  echo "running openclaw setup"
  if ! "${PREFIX}/bin/openclaw" setup \
    --non-interactive \
    --accept-risk \
    --workspace "${WORKSPACE_DIR}"; then
    cat >&2 <<EOF
openclaw setup returned a non-zero status after CLI installation.
This commonly happens when the Gateway service is not running yet.
The CLI is installed; run \`openclaw gateway run\`.
Use \`--install-gateway-service\` only on servers with systemd user services.
EOF
  fi
fi

if [ "${INSTALL_GATEWAY_SERVICE}" -eq 1 ]; then
  echo "installing OpenClaw Gateway service"
  GATEWAY_SERVICE_READY=1
  if ! "${PREFIX}/bin/openclaw" gateway install; then
    GATEWAY_SERVICE_READY=0
  elif ! "${PREFIX}/bin/openclaw" gateway start; then
    GATEWAY_SERVICE_READY=0
  fi

  if [ "${GATEWAY_SERVICE_READY}" -ne 1 ]; then
    cat >&2 <<EOF
Gateway service could not be installed or started automatically.
The CLI installation is complete.

OpenClaw's managed Gateway service requires systemd user services on Linux.
If this server does not provide systemd user services, run Gateway directly
or put it under your existing process supervisor.

To run Gateway without systemd user services:
  ${PREFIX}/bin/openclaw gateway run

To keep it running in the background for a quick smoke test:
  nohup ${PREFIX}/bin/openclaw gateway run > "${PREFIX}/gateway.log" 2>&1 &
EOF
  fi
fi

cat <<EOF

OpenClaw ${OPENCLAW_VERSION} installed.

Command:
  ${BIN_DIR}/openclaw

For the current shell:
  export PATH="${BIN_DIR}:\$PATH"

Verify:
  bash "${SCRIPT_DIR}/verify.sh" --prefix "${PREFIX}"
EOF
