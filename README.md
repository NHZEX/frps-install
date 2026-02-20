# frps

## 项目简介

基于 [fatedier/frp](https://github.com/fatedier/frp) 的 `frps` Linux 安装与管理脚本。

当前脚本聚焦 **frps 二进制安装**，提供版本管理、配置编辑、安装信息查询和 systemd 管理能力。

## 快速开始

```bash
git clone https://github.com/nhzex/frps-install.git
cd frps
sudo ./frps_linux_install.sh --help
```

安装最新版本：

```bash
sudo ./frps_linux_install.sh install
```

### 一键脚本

```bash
curl -fsSL https://raw.githubusercontent.com/nhzex/frps-install/main/frps_linux_install.sh | sudo bash
```

#### 加速代理

```bash
curl -fsSL https://hk.gh-proxy.org/https://raw.githubusercontent.com/nhzex/frps-install/main/frps_linux_install.sh | sudo bash
```

## 主要能力

- 自动识别最新版本并安装
- 列出最近 6 个发布版本
- 支持手动安装指定版本
- 使用 release 资产 `digest` 做 sha256 校验（缺失时二次确认）
- 支持 `gh-proxy` 加速及回退
- 支持 `edit` 快速编辑配置（默认 `nano`）
- 支持显示安装信息（安装路径、配置路径、版本、服务状态）
- 支持 systemd 注册、卸载、启用/禁用自启动及启停管理

## 命令示例

### 版本相关

```bash
# 最新版本号
bash frps_linux_install.sh latest

# 最近 6 个版本
bash frps_linux_install.sh list
```

### 安装与更新

```bash
# 安装最新版本
sudo bash frps_linux_install.sh install

# 安装指定版本（支持 v 前缀）
sudo bash frps_linux_install.sh install 0.67.0
sudo bash frps_linux_install.sh install v0.67.0

# 更新到最新版本
sudo bash frps_linux_install.sh update
```

### 配置编辑与信息查询

```bash
# 默认用 nano 编辑配置
sudo bash frps_linux_install.sh edit

# 指定编辑器
sudo bash frps_linux_install.sh edit vi

# 查看安装信息
bash frps_linux_install.sh info
```

### systemd 管理

```bash
sudo bash frps_linux_install.sh service register
sudo bash frps_linux_install.sh service enable
sudo bash frps_linux_install.sh service start
sudo bash frps_linux_install.sh service status
sudo bash frps_linux_install.sh service disable
sudo bash frps_linux_install.sh service unregister
```

### 卸载

```bash
# 卸载二进制与服务，保留配置
sudo bash frps_linux_install.sh uninstall

# 卸载并删除配置
sudo bash frps_linux_install.sh uninstall --purge
```

兼容入口（旧脚本）仍可用，会自动转发到主脚本：

```bash
sudo bash frps_linux_uninstall.sh
```

## 默认路径

- 二进制：`/usr/local/bin/frps`
- 配置：`/etc/frp/frps.toml`
- systemd：`/etc/systemd/system/frps.service`

## 代理与依赖

- 代理模式：`--proxy=auto|on|off`
  - `auto`：先直连，失败后走 `https://gh-proxy.com/`
  - `on`：优先走 `gh-proxy`，失败回退直连
  - `off`：仅直连
- 依赖工具：`curl`、`jq`、`tar`、`sha256sum`
- 在 Debian/Ubuntu 上，缺少依赖时脚本会询问后自动 `apt-get install`

## 安全提醒

- 请在首次安装后立刻修改配置中的默认凭据（如 `webServer.user`、`webServer.password`、`auth.token`）。
- 不要将真实敏感信息写入公开仓库，建议通过受控配置文件或密钥管理方案维护。

## 下一步建议

- 复用当前 CLI 结构扩展 `frpc` 安装模式，保持一致的版本管理和 systemd 管理体验。