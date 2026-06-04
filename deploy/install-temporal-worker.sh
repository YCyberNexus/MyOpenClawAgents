#!/usr/bin/env bash
#
# install-temporal-worker.sh
# ---------------------------------------------------------------------------
# 一键把 Temporal dev server + acpx Temporal worker 部署为 systemd 服务，
# 让它们脱离 SSH 窗口常驻：关掉窗口、服务器重启都会自动拉起。
#
# 这是《TEMPORAL_DEV_部署教程.md》§5「让 dev server 和 worker 常驻」的可执行版本。
# 创建三样东西：
#   /etc/systemd/system/temporal-dev.service   ← Temporal dev server
#   /etc/systemd/system/acpx-worker.service    ← acpx Temporal worker
#   /usr/local/bin/acpx-worker-start.sh        ← worker 启动包装（补全 PATH / NODE_ID）
# 并把 GITLAB_TOKEN 写入 /data/acpx/worker.env（600 root）。
#
# 用法（首次部署，必须带 token）：
#   sudo GITLAB_TOKEN=<你的gitlab_token> bash deploy/install-temporal-worker.sh
#
# 再次运行（worker.env 已存在则沿用，不需要再传 token）：
#   sudo bash deploy/install-temporal-worker.sh
#
# 所有路径 / 用户都可用环境变量覆盖，见下方「可配置项」。脚本是幂等的，可重复运行。
# ---------------------------------------------------------------------------
set -euo pipefail

#------------------------------- 可配置项 ----------------------------------
# worker 运行身份：必须是装了 agent（~/.openclaw/workspace-...）的那个用户。
# 用 root 跑会导致 git 没有提交身份、且把仓库文件创建成 root 所属，引发权限错误。
RUN_USER="${RUN_USER:-claw}"

# 装了 acpx_temporal / temporalio 的 Python venv（worker 模块所在）。
VENV_DIR="${VENV_DIR:-/data/acpx/venv}"

# acpx / claude / node 这些命令所在目录（acpx 是 Node.js 工具，和 node 同目录）。
# systemd 不加载用户的 .bashrc，必须显式把它补进 worker 的 PATH，否则 acpx 报 127。
NODE_BIN_DIR="${NODE_BIN_DIR:-/opt/nodejs/nodejs-offline/node-v24.12.0-linux-x64/bin}"

# temporal 可执行文件；留空则自动探测（which temporal，再退回 /usr/local/bin/temporal）。
TEMPORAL_BIN="${TEMPORAL_BIN:-}"

# Temporal dev server 的持久化 SQLite 文件（schedule / workflow 状态都存这里）。
TEMPORAL_DB="${TEMPORAL_DB:-/var/lib/temporal/dev.db}"

# token 配置文件（systemd EnvironmentFile）。
WORKER_ENV="${WORKER_ENV:-/data/acpx/worker.env}"

TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-localhost:7233}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"

# worker 启动包装脚本路径。
WORKER_START="${WORKER_START:-/usr/local/bin/acpx-worker-start.sh}"

# schedule（可选，一次性写进 dev.db）。input 文件不存在则自动跳过；已存在的 schedule 不会重建。
SCHEDULE_ID="${SCHEDULE_ID:-campaign:ifp_ui_testing}"
SCHEDULE_INTERVAL="${SCHEDULE_INTERVAL:-1h}"
SCHEDULE_INPUT="${SCHEDULE_INPUT:-/data/acpx/campaign-input-ifp_ui_testing.json}"
#---------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 0. 前置检查 ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo GITLAB_TOKEN=<token> bash $0"

if [ -z "$TEMPORAL_BIN" ]; then
  TEMPORAL_BIN="$(command -v temporal || true)"
  if [ -z "$TEMPORAL_BIN" ] && [ -x /usr/local/bin/temporal ]; then
    TEMPORAL_BIN="/usr/local/bin/temporal"
  fi
fi
[ -n "$TEMPORAL_BIN" ] && [ -x "$TEMPORAL_BIN" ] \
  || die "找不到 temporal 可执行文件，请用 TEMPORAL_BIN=/path/to/temporal 指定"

[ -x "$VENV_DIR/bin/python" ] || die "找不到 $VENV_DIR/bin/python（VENV_DIR 配错了？）"
id "$RUN_USER" >/dev/null 2>&1 || die "用户 $RUN_USER 不存在（RUN_USER 配错了？）"
[ -x "$NODE_BIN_DIR/acpx" ] \
  || warn "在 $NODE_BIN_DIR 下没找到 acpx —— worker 跑测试时会 127，请确认 NODE_BIN_DIR"

log "temporal     : $TEMPORAL_BIN"
log "运行身份     : $RUN_USER"
log "worker venv  : $VENV_DIR"
log "acpx/node bin: $NODE_BIN_DIR"
log "temporal db  : $TEMPORAL_DB"

TEMPORAL_DB_DIR="$(dirname "$TEMPORAL_DB")"

# ---- 1. worker.env（token，600 root）-------------------------------------
mkdir -p "$(dirname "$WORKER_ENV")"
if [ -f "$WORKER_ENV" ]; then
  log "已存在 $WORKER_ENV，沿用（不覆盖）"
else
  [ -n "${GITLAB_TOKEN:-}" ] \
    || die "首次部署需要 token：sudo GITLAB_TOKEN=<token> bash $0"
  ( umask 077
    # 用 printf + 双引号写入，token 内容原样落盘，不被 shell 二次解析。
    { printf 'GITLAB_TOKEN=%s\n'      "$GITLAB_TOKEN"
      printf 'TEMPORAL_ADDRESS=%s\n'  "$TEMPORAL_ADDRESS"
      printf 'TEMPORAL_NAMESPACE=%s\n' "$TEMPORAL_NAMESPACE"
    } > "$WORKER_ENV" )
  log "已写入 $WORKER_ENV"
fi
chmod 600 "$WORKER_ENV"
chown root:root "$WORKER_ENV"

# ---- 2. temporal-dev.service ---------------------------------------------
mkdir -p "$TEMPORAL_DB_DIR"
cat > /etc/systemd/system/temporal-dev.service <<EOF
[Unit]
Description=Temporal dev server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p ${TEMPORAL_DB_DIR}
ExecStart=${TEMPORAL_BIN} server start-dev --db-filename ${TEMPORAL_DB}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
log "已写入 /etc/systemd/system/temporal-dev.service"

# ---- 3. worker 启动包装脚本 ----------------------------------------------
# 外层 here-doc 不带引号：${NODE_BIN_DIR}/${VENV_DIR} 立即展开成真实路径；
# \${PATH}/\$(hostname)/\${NODE_ID} 用 \ 转义，原样写进文件、worker 运行时才展开。
cat > "$WORKER_START" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# 补全 systemd 精简 PATH：node bin 提供 acpx/claude/node，venv bin 提供 python 工具。
export PATH="${NODE_BIN_DIR}:${VENV_DIR}/bin:\${PATH}"
export NODE_ID="\$(hostname)"
exec ${VENV_DIR}/bin/python -m acpx_temporal.worker \\
  --task-queue "acpx-worktree-\${NODE_ID}"
EOF
chmod +x "$WORKER_START"
log "已写入 $WORKER_START"

# ---- 4. acpx-worker.service ----------------------------------------------
cat > /etc/systemd/system/acpx-worker.service <<EOF
[Unit]
Description=ACPX Temporal worker
After=temporal-dev.service
Requires=temporal-dev.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${VENV_DIR}
EnvironmentFile=${WORKER_ENV}
ExecStart=${WORKER_START}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
log "已写入 /etc/systemd/system/acpx-worker.service"

# ---- 5. 启动 + 开机自启 ---------------------------------------------------
systemctl daemon-reload
systemctl enable --now temporal-dev.service
systemctl enable --now acpx-worker.service
log "temporal-dev / acpx-worker 已启动并设为开机自启"

# ---- 6. schedule（可选，幂等）--------------------------------------------
setup_schedule() {
  if [ ! -f "$SCHEDULE_INPUT" ]; then
    warn "schedule input 文件不存在，跳过 schedule 创建：$SCHEDULE_INPUT"
    return 0
  fi

  # 等 Temporal frontend 就绪（schedule list 能成功即可），最多 ~30s。
  local i ready=0
  for i in $(seq 1 30); do
    if "$TEMPORAL_BIN" schedule list \
         --address "$TEMPORAL_ADDRESS" --namespace "$TEMPORAL_NAMESPACE" >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || { warn "Temporal 未在 30s 内就绪，跳过 schedule 创建"; return 0; }

  # 已存在则不重建（避免 ScheduleAlreadyRunningError）。
  if "$TEMPORAL_BIN" schedule describe \
       --schedule-id "$SCHEDULE_ID" \
       --address "$TEMPORAL_ADDRESS" --namespace "$TEMPORAL_NAMESPACE" >/dev/null 2>&1; then
    log "schedule '$SCHEDULE_ID' 已存在，跳过创建"
    return 0
  fi

  local node_id; node_id="$(hostname)"
  if sudo -u "$RUN_USER" env \
       "PATH=${NODE_BIN_DIR}:${VENV_DIR}/bin:${PATH}" \
       "TEMPORAL_ADDRESS=${TEMPORAL_ADDRESS}" \
       "TEMPORAL_NAMESPACE=${TEMPORAL_NAMESPACE}" \
       "${VENV_DIR}/bin/acpx-temporal-client" create-schedule \
         --schedule-id "$SCHEDULE_ID" \
         --task-queue  "acpx-worktree-${node_id}" \
         --interval    "$SCHEDULE_INTERVAL" \
         --input-file  "$SCHEDULE_INPUT"; then
    log "schedule '$SCHEDULE_ID' 已创建（task-queue=acpx-worktree-${node_id}）"
  else
    warn "schedule 创建失败，请手动检查 input 文件与 Temporal 状态"
  fi
}
setup_schedule

# ---- 7. 收尾：状态 + 常用命令 --------------------------------------------
echo
log "部署完成。当前服务状态："
systemctl --no-pager --lines=0 status temporal-dev.service acpx-worker.service || true

cat <<EOF

下一步 / 常用命令
-----------------
看实时日志：
  sudo journalctl -u acpx-worker  -f
  sudo journalctl -u temporal-dev -f
查看 schedule：
  ${TEMPORAL_BIN} schedule list --namespace ${TEMPORAL_NAMESPACE}
手动催一轮：
  ${TEMPORAL_BIN} schedule trigger --schedule-id ${SCHEDULE_ID} --namespace ${TEMPORAL_NAMESPACE}
改了 token（${WORKER_ENV}）后重启 worker：
  sudo systemctl restart acpx-worker.service
EOF
