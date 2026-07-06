# OpenClaw RedHat 7.9 离线安装包

这个包只安装 OpenClaw CLI 本体，不部署任何项目 agent 工件。

目标环境：

- Linux x86_64
- RedHat Enterprise Linux 7.9 或兼容系统
- `glibc >= 2.17`
- 目标服务器安装阶段不需要互联网
- 目标服务器需要有 `bash`、`tar`、`gzip`、`sha256sum`

## 安装

把 zip 上传到服务器后执行：

```bash
unzip openclaw-rhel7-offline-2026.6.11.zip
cd openclaw-rhel7-offline-2026.6.11
bash install.sh
```

默认安装位置：

- 程序目录：`$HOME/.local/openclaw-offline`
- 命令链接：`$HOME/.local/bin/openclaw`
- OpenClaw 工作区：`$HOME/.openclaw/workspace`

如果要指定路径：

```bash
bash install.sh --prefix /opt/openclaw-offline --bin-dir /usr/local/bin
```

当前 shell 如果还找不到 `openclaw`，执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 校验

```bash
bash verify.sh
```

预期能看到：

- Node 版本
- OpenClaw 版本
- OpenClaw 配置校验结果

## 可选：安装 Gateway 服务

安装器默认只安装 CLI 并执行基础 `openclaw setup`。如果服务器的 systemd 环境已经准备好，可以显式要求安装并启动 Gateway 服务：

```bash
bash install.sh --install-gateway-service
```

如果服务安装失败，CLI 安装本身仍然保留，可手动排查：

```bash
openclaw gateway status
openclaw gateway run
```

## 已知边界

- 这个包不配置模型密钥、聊天渠道或项目 agent。安装后仍需要按你的内网模型和通道策略配置 OpenClaw。
- Node 使用 `linux-x64-glibc-217` 构建，用于兼容 RHEL 7.9 的 `glibc 2.17`。
- 如果服务器不是 x86_64，不能使用本包。
