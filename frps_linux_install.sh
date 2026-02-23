#!/usr/bin/env bash
set -euo pipefail

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# * 颜色定义
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[34m"
Font="\033[0m"

# * 可配置变量（支持环境变量覆盖）
FRPS_NAME="${FRPS_NAME:-${FRP_NAME:-frps}}"
FRPC_NAME="${FRPC_NAME:-frpc}"
GITHUB_OWNER="${GITHUB_OWNER:-fatedier}"
GITHUB_REPO="${GITHUB_REPO:-frp}"
INSTALL_BIN_PATH_FRPS="${INSTALL_BIN_PATH_FRPS:-${INSTALL_BIN_PATH:-/usr/local/bin/frps}}"
INSTALL_BIN_PATH_FRPC="${INSTALL_BIN_PATH_FRPC:-/usr/local/bin/frpc}"
CONFIG_DIR="${CONFIG_DIR:-/etc/frp}"
FRPS_CONFIG_PATH="${FRPS_CONFIG_PATH:-${CONFIG_PATH:-/etc/frp/frps.toml}}"
FRPC_CONFIG_PATH="${FRPC_CONFIG_PATH:-/etc/frp/frpc.toml}"
SYSTEMD_UNIT_PATH="${SYSTEMD_UNIT_PATH:-/etc/systemd/system/frps.service}"

# * 兼容旧变量名
FRP_NAME="${FRPS_NAME}"
INSTALL_BIN_PATH="${INSTALL_BIN_PATH_FRPS}"
CONFIG_PATH="${FRPS_CONFIG_PATH}"

# * 标记用户是否手动指定了代理前缀（环境变量或命令行）
if [[ -n "${GH_PROXY_PREFIX+x}" ]]; then
    GH_PROXY_PREFIX_MANUAL=1
else
    GH_PROXY_PREFIX_MANUAL=0
fi
GH_PROXY_PREFIX=""
DEFAULT_PROXY_PREFIXES=(
    "https://hk.gh-proxy.org/"
    "https://gh-proxy.org/"
    "https://cdn.gh-proxy.org/"
    "https://edgeone.gh-proxy.org/"
    "https://fastlyacname.gh-proxy.org/"
    "https://ghproxy.net/"
    "https://ghfast.top/"
)

# * 代理模式: auto|on|off
PROXY_MODE="${PROXY_MODE:-auto}"
# * frpc 同步模式: auto|on|off
SYNC_FRPC_MODE="${SYNC_FRPC_MODE:-auto}"
AUTO_CONFIRM="${AUTO_CONFIRM:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"
HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-8}"
HTTP_MAX_TIME="${HTTP_MAX_TIME:-30}"
TMP_ROOT="${TMP_ROOT:-/tmp}"

# * 兼容旧路径（用于提示与清理）
LEGACY_BIN_PATH_FRPS="/usr/local/frp/frps"
LEGACY_BIN_PATH_FRPC="/usr/local/frp/frpc"
LEGACY_CONFIG_PATH_FRPS="/usr/local/frp/frps.toml"
LEGACY_CONFIG_PATH_FRPC="/usr/local/frp/frpc.toml"
LEGACY_UNIT_PATH="/lib/systemd/system/frps.service"

LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
RELEASES_API_BASE="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases"
TAG_RELEASE_API_BASE="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags"

CURRENT_TEMP_DIR=""

print_info() {
    echo -e "${Blue}[INFO]${Font} $*" >&2
}

print_ok() {
    echo -e "${Green}[OK]${Font} $*" >&2
}

print_warn() {
    echo -e "${Yellow}[WARN]${Font} $*" >&2
}

print_error() {
    echo -e "${Red}[ERROR]${Font} $*" >&2
}

cleanup_temp() {
    if [[ -n "${CURRENT_TEMP_DIR}" && -d "${CURRENT_TEMP_DIR}" ]]; then
        rm -rf "${CURRENT_TEMP_DIR}"
    fi
}

trap cleanup_temp EXIT

usage() {
    cat <<'EOF'
frps 安装与管理脚本（支持可选同步 frpc）

用法:
  ./frps_linux_install.sh [全局参数] <命令> [命令参数]
  ./frps_linux_install.sh                 # 等同 install --latest

全局参数:
  --proxy=auto|on|off   GitHub 请求代理模式，默认 auto
                        auto: 先直连失败后代理；on: 始终代理；off: 始终直连
  --proxy-prefix=URL    手动指定单个代理前缀（必须 https:// 开头）
  --frpc[=MODE]         安装/升级时是否同步释放 frpc（auto|on|off）
                        --frpc 等同 --frpc=on
                        auto: 仅检测到现有 frpc 时同步升级；on: 总是同步；off: 不同步
  -y, --yes             自动确认（跳过交互确认）
  -h, --help            显示帮助

命令:
  latest
      输出最新版本号（如 0.67.0）

  list [COUNT]
      列出最近 COUNT 个发布版本（默认 6）
      示例:
        ./frps_linux_install.sh list
        ./frps_linux_install.sh list 10
        ./frps_linux_install.sh list --count=10

  install [VERSION]
      安装指定版本；不传版本则安装最新版本
      示例:
        ./frps_linux_install.sh install
        ./frps_linux_install.sh install 0.67.0
        ./frps_linux_install.sh install v0.67.0
        ./frps_linux_install.sh install --frpc=on

  update
      更新到最新版本（等同 install，可配合 --frpc 使用）

  info
      显示安装信息：frps/frpc 安装路径、配置路径、版本、systemd 状态

  edit [EDITOR]
      使用编辑器打开配置文件（默认 nano）
      示例:
        ./frps_linux_install.sh edit
        ./frps_linux_install.sh edit vi

  service <register|unregister|enable|disable|start|stop|restart|status>
      管理 systemd 服务

  uninstall [--purge]
      卸载 frps/frpc 二进制与 systemd；默认保留配置文件
      --purge: 一并删除配置文件
EOF

    echo ""
    echo "内置代理前缀参考（未手动指定 --proxy-prefix 时，代理重试会按以下顺序循环一次）:"
    local prefix=""
    while IFS= read -r prefix; do
        echo "  - ${prefix}"
    done < <(known_proxy_prefixes)
}

is_root() {
    [[ "${EUID}" -eq 0 ]]
}

require_root() {
    if ! is_root; then
        print_error "该操作需要 root 权限，请使用 sudo 或 root 用户执行。"
        exit 1
    fi
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

confirm() {
    local prompt="$1"
    local default_yes="${2:-0}"
    local answer=""

    if [[ "${AUTO_CONFIRM}" == "1" ]]; then
        return 0
    fi

    if [[ "${default_yes}" == "1" ]]; then
        read -r -p "${prompt} [Y/n]: " answer
        [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]]
    else
        read -r -p "${prompt} [y/N]: " answer
        [[ "${answer}" =~ ^[Yy]$ ]]
    fi
}

detect_arch() {
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv7|armhf)
            echo "arm"
            ;;
        *)
            print_error "不支持的架构: ${machine}"
            exit 1
            ;;
    esac
}

normalize_version() {
    local input="$1"
    local normalized
    normalized="${input#v}"
    echo "${normalized}"
}

version_to_tag() {
    local version="$1"
    echo "v$(normalize_version "${version}")"
}

ensure_proxy_prefix() {
    if [[ "${GH_PROXY_PREFIX}" == http://* ]]; then
        print_error "代理前缀仅支持 https://，不支持 http://: ${GH_PROXY_PREFIX}"
        exit 1
    fi
    if [[ "${GH_PROXY_PREFIX}" != https://* ]]; then
        GH_PROXY_PREFIX="https://${GH_PROXY_PREFIX}"
    fi
    if [[ "${GH_PROXY_PREFIX}" != */ ]]; then
        GH_PROXY_PREFIX="${GH_PROXY_PREFIX}/"
    fi
}

normalize_proxy_mode() {
    local mode="${1:-auto}"
    mode="${mode,,}"
    case "${mode}" in
        auto|on|off)
            echo "${mode}"
            ;;
        always|force|proxy)
            echo "on"
            ;;
        direct|none|disable)
            echo "off"
            ;;
        *)
            print_error "无效 --proxy 参数: ${mode}（允许: auto|on|off；别名: always|force|proxy）"
            exit 1
            ;;
    esac
}

normalize_sync_frpc_mode() {
    local mode="${1:-auto}"
    mode="${mode,,}"
    case "${mode}" in
        auto|on|off)
            echo "${mode}"
            ;;
        yes|true|enable|enabled|with)
            echo "on"
            ;;
        no|false|disable|disabled|without)
            echo "off"
            ;;
        *)
            print_error "无效 --frpc 参数: ${mode}（允许: auto|on|off）"
            exit 1
            ;;
    esac
}

has_existing_frpc_release() {
    [[ -x "${INSTALL_BIN_PATH_FRPC}" || -x "${LEGACY_BIN_PATH_FRPC}" || -f "${FRPC_CONFIG_PATH}" || -f "${LEGACY_CONFIG_PATH_FRPC}" ]]
}

resolve_sync_frpc_flag() {
    SYNC_FRPC_MODE="$(normalize_sync_frpc_mode "${SYNC_FRPC_MODE}")"
    case "${SYNC_FRPC_MODE}" in
        on)
            echo "1"
            ;;
        off)
            echo "0"
            ;;
        auto)
            if has_existing_frpc_release; then
                echo "1"
            else
                echo "0"
            fi
            ;;
        *)
            print_error "无效 SYNC_FRPC_MODE: ${SYNC_FRPC_MODE}"
            exit 1
            ;;
    esac
}

known_proxy_prefixes() {
    local raw_prefix=""
    local prefix=""
    local -A seen_prefix=()

    for raw_prefix in "${DEFAULT_PROXY_PREFIXES[@]}"; do
        prefix="${raw_prefix}"
        [[ "${prefix}" != https://* ]] && continue
        [[ "${prefix}" != */ ]] && prefix="${prefix}/"
        if [[ -z "${seen_prefix["${prefix}"]+x}" ]]; then
            seen_prefix["${prefix}"]=1
            printf '%s\n' "${prefix}"
        fi
    done
}

proxy_retry_prefixes() {
    ensure_proxy_prefix

    if [[ "${GH_PROXY_PREFIX_MANUAL}" == "1" ]]; then
        printf '%s\n' "${GH_PROXY_PREFIX}"
        return 0
    fi

    known_proxy_prefixes
}

sanitize_remote_url() {
    local raw_url="$1"
    local cleaned_url="${raw_url}"

    # * 通过 https://*.github.com（含 github.com）定位真实目标地址，避免依赖固定代理前缀列表
    if [[ "${cleaned_url}" =~ (https://([A-Za-z0-9-]+\.)?github\.com/[^[:space:]]+) ]]; then
        cleaned_url="${BASH_REMATCH[1]}"
        if [[ "${cleaned_url}" != "${raw_url}" ]]; then
            print_warn "检测到 URL 代理前缀污染，已自动净化。"
        fi
    fi

    printf '%s' "${cleaned_url}"
}

sanitize_runtime_urls() {
    LATEST_RELEASE_API="$(sanitize_remote_url "${LATEST_RELEASE_API}")"
    RELEASES_API_BASE="$(sanitize_remote_url "${RELEASES_API_BASE}")"
    TAG_RELEASE_API_BASE="$(sanitize_remote_url "${TAG_RELEASE_API_BASE}")"
}

build_url_candidates() {
    local raw_url="$1"
    local clean_url=""
    local proxy_prefix=""
    local candidate=""
    local -a candidates=()
    local -A seen_candidate=()

    ensure_proxy_prefix
    PROXY_MODE="$(normalize_proxy_mode "${PROXY_MODE}")"
    clean_url="$(sanitize_remote_url "${raw_url}")"
    if [[ "${clean_url}" != https://* ]]; then
        print_error "仅支持 https URL，当前地址非法或被污染: ${raw_url}"
        return 1
    fi

    case "${PROXY_MODE}" in
        off)
            candidates+=("${clean_url}")
            ;;
        on)
            while IFS= read -r proxy_prefix; do
                candidate="${proxy_prefix}${clean_url}"
                if [[ -z "${seen_candidate["${candidate}"]+x}" ]]; then
                    seen_candidate["${candidate}"]=1
                    candidates+=("${candidate}")
                fi
            done < <(proxy_retry_prefixes)
            ;;
        auto)
            candidates+=("${clean_url}")
            seen_candidate["${clean_url}"]=1
            while IFS= read -r proxy_prefix; do
                candidate="${proxy_prefix}${clean_url}"
                if [[ -z "${seen_candidate["${candidate}"]+x}" ]]; then
                    seen_candidate["${candidate}"]=1
                    candidates+=("${candidate}")
                fi
            done < <(proxy_retry_prefixes)
            ;;
        *)
            print_error "无效 --proxy 参数: ${PROXY_MODE}（允许: auto|on|off）"
            exit 1
            ;;
    esac

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        print_error "未生成可用请求地址，请检查代理配置。"
        return 1
    fi

    printf '%s\n' "${candidates[@]}"
}

http_get() {
    local raw_url="$1"
    local candidate=""
    local output=""

    while IFS= read -r candidate; do
        print_info "请求地址: ${candidate}"
        if output="$(curl --silent --show-error --fail --location \
            --connect-timeout "${HTTP_CONNECT_TIMEOUT}" --max-time "${HTTP_MAX_TIME}" \
            "${candidate}")"; then
            printf '%s' "${output}"
            return 0
        fi
        print_warn "请求失败，尝试下一个地址: ${candidate}"
    done < <(build_url_candidates "${raw_url}")

    return 1
}

download_file() {
    local raw_url="$1"
    local output_path="$2"
    local candidate=""

    while IFS= read -r candidate; do
        print_info "请求地址: ${candidate}"
        if curl --show-error --fail --location \
            --connect-timeout "${HTTP_CONNECT_TIMEOUT}" --max-time "${HTTP_MAX_TIME}" \
            --output "${output_path}" "${candidate}"; then
            return 0
        fi
        print_warn "下载失败，尝试下一个地址: ${candidate}"
    done < <(build_url_candidates "${raw_url}")

    return 1
}

is_debian_family() {
    [[ -f /etc/debian_version ]] || has_cmd apt-get
}

tool_to_package_name() {
    local tool="$1"
    case "${tool}" in
        curl) echo "curl" ;;
        jq) echo "jq" ;;
        tar) echo "tar" ;;
        sha256sum) echo "coreutils" ;;
        nano) echo "nano" ;;
        *) echo "${tool}" ;;
    esac
}

ensure_tools() {
    local -a required=("$@")
    local -a missing=()
    local -a install_packages=()
    local tool=""
    local package=""

    for tool in "${required[@]}"; do
        if ! has_cmd "${tool}"; then
            missing+=("${tool}")
            package="$(tool_to_package_name "${tool}")"
            install_packages+=("${package}")
        fi
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        return 0
    fi

    print_warn "缺少依赖工具: ${missing[*]}"

    if [[ "${AUTO_INSTALL_DEPS}" != "1" ]]; then
        print_error "当前配置不允许自动安装依赖，请手动安装后重试。"
        exit 1
    fi

    if ! is_debian_family; then
        print_error "仅支持在 Debian/Ubuntu 自动安装依赖，请先手动安装: ${missing[*]}"
        exit 1
    fi

    require_root

    if ! confirm "检测到缺少依赖，是否执行 apt-get 自动安装?" 1; then
        print_error "用户取消依赖安装。"
        exit 1
    fi

    print_info "执行依赖安装: apt-get update && apt-get install -y ${install_packages[*]}"
    apt-get update
    apt-get install -y "${install_packages[@]}"

    for tool in "${required[@]}"; do
        if ! has_cmd "${tool}"; then
            print_error "依赖安装后仍找不到工具: ${tool}"
            exit 1
        fi
    done
}

get_latest_version() {
    ensure_tools curl jq
    local json
    json="$(http_get "${LATEST_RELEASE_API}")" || {
        print_error "获取最新版本失败。"
        exit 1
    }

    local tag
    tag="$(printf '%s' "${json}" | jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        print_error "未能从 GitHub API 解析最新版本 tag_name。"
        exit 1
    fi

    normalize_version "${tag}"
}

list_recent_versions() {
    local limit="${1:-6}"
    ensure_tools curl jq

    if ! [[ "${limit}" =~ ^[1-9][0-9]*$ ]]; then
        print_error "list 参数必须是正整数，当前值: ${limit}"
        exit 1
    fi

    local list_api
    list_api="${RELEASES_API_BASE}?page=1&per_page=${limit}"

    local json
    json="$(http_get "${list_api}")" || {
        print_error "获取最近版本列表失败。"
        exit 1
    }

    print_info "最近 ${limit} 个发布版本:"
    printf '%s' "${json}" | jq -r '.[] | "- \(.tag_name)  (\(.published_at // "unknown"))"'
}

fetch_release_json_by_version() {
    local version="$1"
    local tag
    tag="$(version_to_tag "${version}")"
    http_get "${TAG_RELEASE_API_BASE}/${tag}"
}

get_asset_value() {
    local json="$1"
    local asset_name="$2"
    local field="$3"
    printf '%s' "${json}" | jq -r --arg asset_name "${asset_name}" --arg field "${field}" '
        .assets[]
        | select(.name == $asset_name)
        | .[$field]
    ' | head -n1
}

get_binary_version_by_path() {
    local binary_path="$1"
    local detected=""
    if [[ -x "${binary_path}" ]]; then
        detected="$("${binary_path}" -v 2>/dev/null | head -n1 | awk '{print $1}')"
        if [[ -n "${detected}" ]]; then
            echo "${detected}"
            return 0
        fi
    fi
    return 1
}

get_installed_version() {
    get_binary_version_by_path "${INSTALL_BIN_PATH_FRPS}"
}

get_installed_version_frpc() {
    get_binary_version_by_path "${INSTALL_BIN_PATH_FRPC}"
}

show_legacy_warning_if_exists() {
    if [[ -e "${LEGACY_BIN_PATH_FRPS}" || -e "${LEGACY_BIN_PATH_FRPC}" || -e "${LEGACY_CONFIG_PATH_FRPS}" || -e "${LEGACY_CONFIG_PATH_FRPC}" || -e "${LEGACY_UNIT_PATH}" ]]; then
        print_warn "检测到旧路径遗留文件:"
        [[ -e "${LEGACY_BIN_PATH_FRPS}" ]] && print_warn "  - ${LEGACY_BIN_PATH_FRPS}"
        [[ -e "${LEGACY_BIN_PATH_FRPC}" ]] && print_warn "  - ${LEGACY_BIN_PATH_FRPC}"
        [[ -e "${LEGACY_CONFIG_PATH_FRPS}" ]] && print_warn "  - ${LEGACY_CONFIG_PATH_FRPS}"
        [[ -e "${LEGACY_CONFIG_PATH_FRPC}" ]] && print_warn "  - ${LEGACY_CONFIG_PATH_FRPC}"
        [[ -e "${LEGACY_UNIT_PATH}" ]] && print_warn "  - ${LEGACY_UNIT_PATH}"
        print_warn "建议通过本脚本执行 uninstall 清理旧路径文件。"
    fi
}

write_systemd_unit() {
    cat >"${SYSTEMD_UNIT_PATH}" <<EOF
[Unit]
Description=Frp Server Service
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${INSTALL_BIN_PATH_FRPS} -c ${FRPS_CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF
}

systemd_available() {
    has_cmd systemctl
}

service_register() {
    require_root
    if ! systemd_available; then
        print_warn "当前系统未检测到 systemctl，跳过 register。"
        return 0
    fi

    write_systemd_unit
    systemctl daemon-reload
    print_ok "systemd 单元已注册: ${SYSTEMD_UNIT_PATH}"
}

service_unregister() {
    require_root
    if ! systemd_available; then
        print_warn "当前系统未检测到 systemctl，跳过 unregister。"
    else
        systemctl disable --now "${FRPS_NAME}" >/dev/null 2>&1 || true
    fi

    rm -f "${SYSTEMD_UNIT_PATH}"
    rm -f "${LEGACY_UNIT_PATH}"

    if systemd_available; then
        systemctl daemon-reload
    fi

    print_ok "systemd 单元已卸载（含旧路径清理）。"
}

service_enable() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 enable。"
        exit 1
    fi
    systemctl enable "${FRPS_NAME}"
    print_ok "已启用开机自启动: ${FRPS_NAME}"
}

service_disable() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 disable。"
        exit 1
    fi
    systemctl disable "${FRPS_NAME}"
    print_ok "已禁用开机自启动: ${FRPS_NAME}"
}

service_start() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 start。"
        exit 1
    fi
    systemctl start "${FRPS_NAME}"
    print_ok "服务已启动: ${FRPS_NAME}"
}

service_stop() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 stop。"
        exit 1
    fi
    systemctl stop "${FRPS_NAME}"
    print_ok "服务已停止: ${FRPS_NAME}"
}

service_restart() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 restart。"
        exit 1
    fi
    systemctl restart "${FRPS_NAME}"
    print_ok "服务已重启: ${FRPS_NAME}"
}

service_status() {
    if ! systemd_available; then
        print_warn "未检测到 systemctl。"
        return 0
    fi
    systemctl status "${FRPS_NAME}" --no-pager
}

show_install_info() {
    local installed_version="未安装"
    local installed_version_frpc="未安装"
    if version="$(get_installed_version)"; then
        installed_version="${version}"
    fi
    if version_frpc="$(get_installed_version_frpc)"; then
        installed_version_frpc="${version_frpc}"
    fi

    echo "frps 安装路径: ${INSTALL_BIN_PATH_FRPS}"
    echo "frps 配置文件路径: ${FRPS_CONFIG_PATH}"
    echo "frpc 安装路径: ${INSTALL_BIN_PATH_FRPC}"
    echo "frpc 配置文件路径: ${FRPC_CONFIG_PATH}"
    echo "systemd 单元路径: ${SYSTEMD_UNIT_PATH}"
    echo "frps 当前版本: ${installed_version}"
    echo "frpc 当前版本: ${installed_version_frpc}"

    if systemd_available; then
        local enabled_state active_state
        enabled_state="$(systemctl is-enabled "${FRPS_NAME}" 2>/dev/null || true)"
        active_state="$(systemctl is-active "${FRPS_NAME}" 2>/dev/null || true)"
        echo "服务启用状态: ${enabled_state:-unknown}"
        echo "服务运行状态: ${active_state:-unknown}"
    else
        echo "服务状态: systemctl 不可用"
    fi

    show_legacy_warning_if_exists
}

verify_digest_or_confirm_skip() {
    local digest="$1"
    local tarball_path="$2"
    local expected_hash actual_hash

    if [[ -z "${digest}" || "${digest}" == "null" ]]; then
        print_warn "该版本资产未提供 digest，无法自动校验 sha256。"
        if ! confirm "是否继续安装（不进行 hash 校验）?" 0; then
            print_error "用户取消安装。"
            exit 1
        fi
        return 0
    fi

    if [[ "${digest}" != sha256:* ]]; then
        print_warn "检测到非 sha256 digest: ${digest}"
        if ! confirm "是否继续安装（不进行 hash 校验）?" 0; then
            print_error "用户取消安装。"
            exit 1
        fi
        return 0
    fi

    expected_hash="${digest#sha256:}"
    actual_hash="$(sha256sum "${tarball_path}" | awk '{print $1}')"

    if [[ "${expected_hash}" != "${actual_hash}" ]]; then
        print_error "sha256 校验失败。"
        print_error "期望: ${expected_hash}"
        print_error "实际: ${actual_hash}"
        exit 1
    fi

    print_ok "sha256 校验通过。"
}

ensure_config_file() {
    local extracted_config_path="$1"
    require_root

    mkdir -p "${CONFIG_DIR}"

    if [[ -f "${FRPS_CONFIG_PATH}" ]]; then
        print_info "frps 配置文件已存在，保持不覆盖: ${FRPS_CONFIG_PATH}"
        return 0
    fi

    if [[ -f "${LEGACY_CONFIG_PATH_FRPS}" ]]; then
        print_warn "检测到旧 frps 配置文件: ${LEGACY_CONFIG_PATH_FRPS}"
        if confirm "是否迁移旧 frps 配置到新路径 ${FRPS_CONFIG_PATH}?" 0; then
            cp -f "${LEGACY_CONFIG_PATH_FRPS}" "${FRPS_CONFIG_PATH}"
            print_ok "已迁移旧 frps 配置到: ${FRPS_CONFIG_PATH}"
            return 0
        fi
    fi

    cp -f "${extracted_config_path}" "${FRPS_CONFIG_PATH}"
    print_ok "已生成默认 frps 配置: ${FRPS_CONFIG_PATH}"
}

ensure_frpc_config_file() {
    local extracted_config_path_frpc="$1"
    require_root

    mkdir -p "${CONFIG_DIR}"

    if [[ -f "${FRPC_CONFIG_PATH}" ]]; then
        print_info "frpc 配置文件已存在，保持不覆盖: ${FRPC_CONFIG_PATH}"
        return 0
    fi

    if [[ -f "${LEGACY_CONFIG_PATH_FRPC}" ]]; then
        print_warn "检测到旧 frpc 配置文件: ${LEGACY_CONFIG_PATH_FRPC}"
        if confirm "是否迁移旧 frpc 配置到新路径 ${FRPC_CONFIG_PATH}?" 0; then
            cp -f "${LEGACY_CONFIG_PATH_FRPC}" "${FRPC_CONFIG_PATH}"
            print_ok "已迁移旧 frpc 配置到: ${FRPC_CONFIG_PATH}"
            return 0
        fi
    fi

    cp -f "${extracted_config_path_frpc}" "${FRPC_CONFIG_PATH}"
    print_ok "已生成默认 frpc 配置: ${FRPC_CONFIG_PATH}"
}

install_binary_and_config() {
    local version="$1"
    local arch="$2"
    local release_json="$3"
    local sync_frpc_flag="${4:-0}"
    local tag tarball_name tarball_url digest
    local tarball_path extracted_dir extracted_bin extracted_cfg extracted_bin_frpc extracted_cfg_frpc

    tag="$(version_to_tag "${version}")"
    tarball_name="frp_${version}_linux_${arch}.tar.gz"
    tarball_url="$(get_asset_value "${release_json}" "${tarball_name}" "browser_download_url" || true)"
    digest="$(get_asset_value "${release_json}" "${tarball_name}" "digest" || true)"

    if [[ -z "${tarball_url}" || "${tarball_url}" == "null" ]]; then
        print_error "发布版本 ${tag} 中未找到资产: ${tarball_name}"
        exit 1
    fi

    CURRENT_TEMP_DIR="$(mktemp -d "${TMP_ROOT}/frps-install.XXXXXX")"
    tarball_path="${CURRENT_TEMP_DIR}/${tarball_name}"

    print_info "开始下载: ${tarball_name}"
    download_file "${tarball_url}" "${tarball_path}" || {
        print_error "下载失败: ${tarball_url}"
        exit 1
    }
    print_ok "下载完成: ${tarball_path}"

    verify_digest_or_confirm_skip "${digest}" "${tarball_path}"

    tar -xzf "${tarball_path}" -C "${CURRENT_TEMP_DIR}"
    extracted_dir="${CURRENT_TEMP_DIR}/frp_${version}_linux_${arch}"
    extracted_bin="${extracted_dir}/${FRPS_NAME}"
    extracted_bin_frpc="${extracted_dir}/${FRPC_NAME}"
    extracted_cfg="${extracted_dir}/${FRPS_NAME}.toml"
    extracted_cfg_frpc="${extracted_dir}/${FRPC_NAME}.toml"

    if [[ ! -f "${extracted_bin}" ]]; then
        print_error "解压后未找到二进制: ${extracted_bin}"
        exit 1
    fi
    if [[ ! -f "${extracted_cfg}" ]]; then
        print_error "解压后未找到配置模板: ${extracted_cfg}"
        exit 1
    fi
    if [[ "${sync_frpc_flag}" == "1" ]]; then
        if [[ ! -f "${extracted_bin_frpc}" ]]; then
            print_error "解压后未找到 frpc 二进制: ${extracted_bin_frpc}"
            exit 1
        fi
        if [[ ! -f "${extracted_cfg_frpc}" ]]; then
            print_error "解压后未找到 frpc 配置模板: ${extracted_cfg_frpc}"
            exit 1
        fi
    fi

    require_root
    install -m 0755 "${extracted_bin}" "${INSTALL_BIN_PATH_FRPS}"
    print_ok "已安装二进制: ${INSTALL_BIN_PATH_FRPS}"

    ensure_config_file "${extracted_cfg}"

    if [[ "${sync_frpc_flag}" == "1" ]]; then
        install -m 0755 "${extracted_bin_frpc}" "${INSTALL_BIN_PATH_FRPC}"
        print_ok "已安装二进制: ${INSTALL_BIN_PATH_FRPC}"
        ensure_frpc_config_file "${extracted_cfg_frpc}"
    else
        print_info "本次未同步释放 frpc（SYNC_FRPC_MODE=${SYNC_FRPC_MODE}）。"
    fi
}

resolve_target_version() {
    local input="${1:-latest}"
    if [[ "${input}" == "latest" || -z "${input}" ]]; then
        get_latest_version
    else
        normalize_version "${input}"
    fi
}

confirm_install_summary() {
    local version="$1"
    local arch="$2"
    local sync_frpc_flag="${3:-0}"
    local current="未安装"
    local sync_frpc_text="否"

    if old_version="$(get_installed_version)"; then
        current="${old_version}"
    fi
    if [[ "${sync_frpc_flag}" == "1" ]]; then
        sync_frpc_text="是"
    fi

    echo "=============================================="
    echo "准备安装 frps"
    echo "当前版本: ${current}"
    echo "目标版本: ${version}"
    echo "系统架构: ${arch}"
    echo "frps 安装路径: ${INSTALL_BIN_PATH_FRPS}"
    echo "frps 配置路径: ${FRPS_CONFIG_PATH}"
    echo "同步释放 frpc: ${sync_frpc_text}（模式: ${SYNC_FRPC_MODE}）"
    if [[ "${sync_frpc_flag}" == "1" ]]; then
        echo "frpc 安装路径: ${INSTALL_BIN_PATH_FRPC}"
        echo "frpc 配置路径: ${FRPC_CONFIG_PATH}"
    fi
    echo "systemd 路径: ${SYSTEMD_UNIT_PATH}"
    echo "代理模式: ${PROXY_MODE}"
    echo "=============================================="

    if ! confirm "请确认本次安装版本信息是否正确，继续安装?" 0; then
        print_error "用户取消安装。"
        exit 1
    fi
}

install_or_update() {
    local requested_version="${1:-latest}"
    local version arch release_json sync_frpc_flag

    ensure_tools curl jq tar sha256sum
    require_root

    arch="$(detect_arch)"
    version="$(resolve_target_version "${requested_version}")"
    sync_frpc_flag="$(resolve_sync_frpc_flag)"
    confirm_install_summary "${version}" "${arch}" "${sync_frpc_flag}"

    print_info "获取发布信息: v${version}"
    release_json="$(fetch_release_json_by_version "${version}")" || {
        print_error "未找到发布版本: v${version}"
        exit 1
    }

    install_binary_and_config "${version}" "${arch}" "${release_json}" "${sync_frpc_flag}"

    if systemd_available; then
        service_register
        systemctl enable "${FRPS_NAME}" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "${FRPS_NAME}"; then
            systemctl restart "${FRPS_NAME}" || print_warn "服务重启失败，请手动检查配置。"
        else
            systemctl start "${FRPS_NAME}" || print_warn "服务启动失败，请先检查配置后手动启动。"
        fi
        print_ok "systemd 已注册，已尝试启用自启动并启动服务。"
    else
        print_warn "未检测到 systemctl，已完成二进制安装，请自行管理进程。"
    fi

    print_ok "安装/更新完成。"
    show_install_info
    print_info "可执行配置编辑命令: $0 edit"
}

run_edit() {
    local editor="${1:-nano}"
    ensure_tools "${editor}"

    if [[ ! -f "${FRPS_CONFIG_PATH}" ]]; then
        print_error "frps 配置文件不存在: ${FRPS_CONFIG_PATH}，请先执行 install。"
        exit 1
    fi

    if [[ ! -w "${FRPS_CONFIG_PATH}" ]] && ! is_root; then
        print_warn "当前用户可能没有写权限，建议使用 sudo 执行 edit。"
    fi

    "${editor}" "${FRPS_CONFIG_PATH}"
}

run_uninstall() {
    local purge_config="${1:-0}"
    require_root

    echo "=============================================="
    echo "准备卸载 frps"
    echo "将删除 frps 二进制: ${INSTALL_BIN_PATH_FRPS}"
    echo "将删除 frpc 二进制: ${INSTALL_BIN_PATH_FRPC}"
    echo "将卸载 unit: ${SYSTEMD_UNIT_PATH}"
    echo "将清理旧路径 unit: ${LEGACY_UNIT_PATH}"
    if [[ "${purge_config}" == "1" ]]; then
        echo "将删除 frps 配置: ${FRPS_CONFIG_PATH}"
        echo "将删除 frpc 配置: ${FRPC_CONFIG_PATH}"
        echo "将清理旧 frps 配置: ${LEGACY_CONFIG_PATH_FRPS}"
        echo "将清理旧 frpc 配置: ${LEGACY_CONFIG_PATH_FRPC}"
    else
        echo "保留 frps 配置: ${FRPS_CONFIG_PATH}"
        echo "保留 frpc 配置: ${FRPC_CONFIG_PATH}"
    fi
    echo "=============================================="

    if ! confirm "确认执行卸载?" 0; then
        print_error "用户取消卸载。"
        exit 1
    fi

    if systemd_available; then
        systemctl disable --now "${FRPS_NAME}" >/dev/null 2>&1 || true
    fi

    rm -f "${INSTALL_BIN_PATH_FRPS}" "${INSTALL_BIN_PATH_FRPC}"
    rm -f "${LEGACY_BIN_PATH_FRPS}" "${LEGACY_BIN_PATH_FRPC}"

    rm -f "${SYSTEMD_UNIT_PATH}" "${LEGACY_UNIT_PATH}"
    if systemd_available; then
        systemctl daemon-reload
    fi

    if [[ "${purge_config}" == "1" ]]; then
        rm -f "${FRPS_CONFIG_PATH}" "${FRPC_CONFIG_PATH}" "${LEGACY_CONFIG_PATH_FRPS}" "${LEGACY_CONFIG_PATH_FRPC}"
        rmdir --ignore-fail-on-non-empty "${CONFIG_DIR}" 2>/dev/null || true
        print_ok "配置文件已删除。"
    fi

    print_ok "卸载完成。"
    if [[ "${purge_config}" != "1" ]]; then
        print_info "frps 配置文件仍保留在: ${FRPS_CONFIG_PATH}"
        print_info "frpc 配置文件仍保留在: ${FRPC_CONFIG_PATH}"
    fi
}

run_service_command() {
    local subcommand="${1:-}"
    case "${subcommand}" in
        register)
            service_register
            ;;
        unregister|uninstall)
            service_unregister
            ;;
        enable)
            service_enable
            ;;
        disable)
            service_disable
            ;;
        start)
            service_start
            ;;
        stop)
            service_stop
            ;;
        restart)
            service_restart
            ;;
        status)
            service_status
            ;;
        *)
            print_error "未知 service 子命令: ${subcommand}"
            print_error "允许: register|unregister|enable|disable|start|stop|restart|status"
            exit 1
            ;;
    esac
}

parse_global_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proxy=*)
                PROXY_MODE="${1#*=}"
                shift
                ;;
            --proxy-prefix=*)
                GH_PROXY_PREFIX="${1#*=}"
                GH_PROXY_PREFIX_MANUAL=1
                shift
                ;;
            --frpc)
                SYNC_FRPC_MODE="on"
                shift
                ;;
            --frpc=*)
                SYNC_FRPC_MODE="${1#*=}"
                shift
                ;;
            --sync-frpc|--sync-frpc=*)
                # * 兼容旧参数，建议改用 --frpc
                if [[ "$1" == "--sync-frpc" ]]; then
                    SYNC_FRPC_MODE="on"
                else
                    SYNC_FRPC_MODE="${1#*=}"
                fi
                print_warn "参数 --sync-frpc 已弃用，请使用 --frpc"
                shift
                ;;
            --yes|-y)
                AUTO_CONFIRM=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done

    PROXY_MODE="$(normalize_proxy_mode "${PROXY_MODE}")"
    SYNC_FRPC_MODE="$(normalize_sync_frpc_mode "${SYNC_FRPC_MODE}")"
    ensure_proxy_prefix
    sanitize_runtime_urls

    REMAINING_ARGS=("$@")
}

main() {
    parse_global_options "$@"
    set -- "${REMAINING_ARGS[@]}"

    local command="${1:-help}"
    [[ $# -gt 0 ]] && shift || true

    case "${command}" in
        latest)
            get_latest_version
            ;;
        list)
            local list_count="6"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --count=*)
                        list_count="${1#*=}"
                        ;;
                    [0-9]*)
                        list_count="$1"
                        ;;
                    *)
                        print_error "list 不支持的参数: $1"
                        exit 1
                        ;;
                esac
                shift
            done
            list_recent_versions "${list_count}"
            ;;
        install)
            local requested="latest"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --latest)
                        requested="latest"
                        ;;
                    --proxy=*)
                        PROXY_MODE="${1#*=}"
                        ;;
                    --proxy-prefix=*)
                        GH_PROXY_PREFIX="${1#*=}"
                        GH_PROXY_PREFIX_MANUAL=1
                        ;;
                    --frpc)
                        SYNC_FRPC_MODE="on"
                        ;;
                    --frpc=*)
                        SYNC_FRPC_MODE="${1#*=}"
                        ;;
                    --sync-frpc|--sync-frpc=*)
                        # * 兼容旧参数，建议改用 --frpc
                        if [[ "$1" == "--sync-frpc" ]]; then
                            SYNC_FRPC_MODE="on"
                        else
                            SYNC_FRPC_MODE="${1#*=}"
                        fi
                        print_warn "参数 --sync-frpc 已弃用，请使用 --frpc"
                        ;;
                    --yes|-y)
                        AUTO_CONFIRM=1
                        ;;
                    *)
                        if [[ "${requested}" == "latest" ]]; then
                            requested="$1"
                        else
                            print_error "install 命令参数过多: $1"
                            exit 1
                        fi
                        ;;
                esac
                shift
            done
            PROXY_MODE="$(normalize_proxy_mode "${PROXY_MODE}")"
            SYNC_FRPC_MODE="$(normalize_sync_frpc_mode "${SYNC_FRPC_MODE}")"
            install_or_update "${requested}"
            ;;
        update)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --proxy=*)
                        PROXY_MODE="${1#*=}"
                        ;;
                    --proxy-prefix=*)
                        GH_PROXY_PREFIX="${1#*=}"
                        GH_PROXY_PREFIX_MANUAL=1
                        ;;
                    --frpc)
                        SYNC_FRPC_MODE="on"
                        ;;
                    --frpc=*)
                        SYNC_FRPC_MODE="${1#*=}"
                        ;;
                    --sync-frpc|--sync-frpc=*)
                        # * 兼容旧参数，建议改用 --frpc
                        if [[ "$1" == "--sync-frpc" ]]; then
                            SYNC_FRPC_MODE="on"
                        else
                            SYNC_FRPC_MODE="${1#*=}"
                        fi
                        print_warn "参数 --sync-frpc 已弃用，请使用 --frpc"
                        ;;
                    --yes|-y)
                        AUTO_CONFIRM=1
                        ;;
                    *)
                        print_error "update 不支持的参数: $1"
                        exit 1
                        ;;
                esac
                shift
            done
            PROXY_MODE="$(normalize_proxy_mode "${PROXY_MODE}")"
            SYNC_FRPC_MODE="$(normalize_sync_frpc_mode "${SYNC_FRPC_MODE}")"
            install_or_update "latest"
            ;;
        info)
            show_install_info
            ;;
        edit)
            local editor="${1:-nano}"
            run_edit "${editor}"
            ;;
        service)
            run_service_command "${1:-}"
            ;;
        uninstall)
            local purge="0"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --purge)
                        purge="1"
                        ;;
                    --yes|-y)
                        AUTO_CONFIRM=1
                        ;;
                    *)
                        print_error "uninstall 不支持的参数: $1"
                        exit 1
                        ;;
                esac
                shift
            done
            run_uninstall "${purge}"
            ;;
        --help|-h|help)
            usage
            ;;
        *)
            print_error "未知命令: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
