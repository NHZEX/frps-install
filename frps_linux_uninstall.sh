#!/usr/bin/env bash
set -euo pipefail

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/frps_linux_install.sh"

if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
    echo "[ERROR] 未找到安装管理脚本: ${INSTALL_SCRIPT}" >&2
    exit 1
fi

# * 兼容旧卸载入口，统一转发到主脚本 uninstall 子命令
exec bash "${INSTALL_SCRIPT}" uninstall "$@"
