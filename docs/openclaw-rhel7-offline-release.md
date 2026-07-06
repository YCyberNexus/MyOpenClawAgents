# OpenClaw RHEL7 离线安装包发布说明

OpenClaw RHEL7 离线安装包的 zip 文件体积超过 GitHub 普通仓库
100MiB 单文件限制，因此不提交到 Git 历史中。

当前离线安装包：

- 文件名：`openclaw-rhel7-offline-2026.6.11.zip`
- Release 标签：`openclaw-rhel7-2026.6.11`
- SHA-256：`57bbf02a09a79154858db7e926ba35bbf7c9f5ce4e409b76a466859be68a134b`
- 用途：在 RedHat Enterprise Linux 7.9 或兼容系统上离线安装 OpenClaw CLI 本体

发布方式：

```bash
gh release create openclaw-rhel7-2026.6.11 openclaw-rhel7-offline-2026.6.11.zip \
  --repo YCyberNexus/MyOpenClawAgents \
  --target orchestra \
  --title "OpenClaw RHEL7 offline 2026.6.11" \
  --notes "RedHat 7.9 离线安装包，只安装 OpenClaw CLI 本体，不包含项目 agent。"
```

安装包源码位于 `packaging/openclaw-rhel7-offline/`。生成后的 zip 只作为
GitHub Release 附件保存，避免后续推送被大文件限制拒绝。
