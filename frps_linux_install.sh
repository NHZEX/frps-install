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
FRP_NAME="${FRP_NAME:-frps}"
GITHUB_OWNER="${GITHUB_OWNER:-fatedier}"
GITHUB_REPO="${GITHUB_REPO:-frp}"
INSTALL_BIN_PATH="${INSTALL_BIN_PATH:-/usr/local/bin/frps}"
CONFIG_DIR="${CONFIG_DIR:-/etc/frp}"
CONFIG_PATH="${CONFIG_PATH:-/etc/frp/frps.toml}"
SYSTEMD_UNIT_PATH="${SYSTEMD_UNIT_PATH:-/etc/systemd/system/frps.service}"
GH_PROXY_PREFIX="${GH_PROXY_PREFIX:-https://hk.gh-proxy.org/}"
# * 代理模式: auto|on|off
PROXY_MODE="${PROXY_MODE:-auto}"
AUTO_CONFIRM="${AUTO_CONFIRM:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"
HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-8}"
HTTP_MAX_TIME="${HTTP_MAX_TIME:-45}"
TMP_ROOT="${TMP_ROOT:-/tmp}"

# * 兼容旧路径（用于提示与清理）
LEGACY_BIN_PATH="/usr/local/frp/frps"
LEGACY_CONFIG_PATH="/usr/local/frp/frps.toml"
LEGACY_UNIT_PATH="/lib/systemd/system/frps.service"

LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
RECENT_RELEASES_API="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases?page=1&per_page=6"
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
frps 安装与管理脚本（仅 frps）

用法:
  ./frps_linux_install.sh [全局参数] <命令> [命令参数]
  ./frps_linux_install.sh                 # 等同 install --latest

全局参数:
  --proxy=auto|on|off   GitHub 请求代理模式，默认 auto
  -y, --yes             自动确认（跳过交互确认）
  -h, --help            显示帮助

命令:
  latest
      输出最新版本号（如 0.67.0）

  list
      列出最近 6 个发布版本

  install [VERSION]
      安装指定版本；不传版本则安装最新版本
      示例:
        ./frps_linux_install.sh install
        ./frps_linux_install.sh install 0.67.0
        ./frps_linux_install.sh install v0.67.0

  update
      更新到最新版本（等同 install）

  info
      显示安装信息：安装路径、配置路径、当前版本、systemd 状态

  edit [EDITOR]
      使用编辑器打开配置文件（默认 nano）
      示例:
        ./frps_linux_install.sh edit
        ./frps_linux_install.sh edit vi

  service <register|unregister|enable|disable|start|stop|restart|status>
      管理 systemd 服务

  uninstall [--purge]
      卸载 frps 二进制与 systemd；默认保留配置文件
      --purge: 一并删除配置文件
EOF
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
    if [[ "${GH_PROXY_PREFIX}" != */ ]]; then
        GH_PROXY_PREFIX="${GH_PROXY_PREFIX}/"
    fi
}

build_url_candidates() {
    local raw_url="$1"
    ensure_proxy_prefix
    case "${PROXY_MODE}" in
        off)
            printf '%s\n' "${raw_url}"
            ;;
        on)
            printf '%s\n' "${GH_PROXY_PREFIX}${raw_url}"
            printf '%s\n' "${raw_url}"
            ;;
        auto)
            printf '%s\n' "${raw_url}"
            printf '%s\n' "${GH_PROXY_PREFIX}${raw_url}"
            ;;
        *)
            print_error "无效 --proxy 参数: ${PROXY_MODE}（允许: auto|on|off）"
            exit 1
            ;;
    esac
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
    ensure_tools curl jq
    local json
    json="$(http_get "${RECENT_RELEASES_API}")" || {
        print_error "获取最近版本列表失败。"
        exit 1
    }

    print_info "最近 6 个发布版本:"
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

get_installed_version() {
    local detected=""
    if [[ -x "${INSTALL_BIN_PATH}" ]]; then
        detected="$("${INSTALL_BIN_PATH}" -v 2>/dev/null | head -n1 | awk '{print $1}')"
        if [[ -n "${detected}" ]]; then
            echo "${detected}"
            return 0
        fi
    fi
    return 1
}

show_legacy_warning_if_exists() {
    if [[ -e "${LEGACY_BIN_PATH}" || -e "${LEGACY_CONFIG_PATH}" || -e "${LEGACY_UNIT_PATH}" ]]; then
        print_warn "检测到旧路径遗留文件:"
        [[ -e "${LEGACY_BIN_PATH}" ]] && print_warn "  - ${LEGACY_BIN_PATH}"
        [[ -e "${LEGACY_CONFIG_PATH}" ]] && print_warn "  - ${LEGACY_CONFIG_PATH}"
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
ExecStart=${INSTALL_BIN_PATH} -c ${CONFIG_PATH}

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
        systemctl disable --now "${FRP_NAME}" >/dev/null 2>&1 || true
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
    systemctl enable "${FRP_NAME}"
    print_ok "已启用开机自启动: ${FRP_NAME}"
}

service_disable() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 disable。"
        exit 1
    fi
    systemctl disable "${FRP_NAME}"
    print_ok "已禁用开机自启动: ${FRP_NAME}"
}

service_start() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 start。"
        exit 1
    fi
    systemctl start "${FRP_NAME}"
    print_ok "服务已启动: ${FRP_NAME}"
}

service_stop() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 stop。"
        exit 1
    fi
    systemctl stop "${FRP_NAME}"
    print_ok "服务已停止: ${FRP_NAME}"
}

service_restart() {
    require_root
    if ! systemd_available; then
        print_error "未检测到 systemctl，无法 restart。"
        exit 1
    fi
    systemctl restart "${FRP_NAME}"
    print_ok "服务已重启: ${FRP_NAME}"
}

service_status() {
    if ! systemd_available; then
        print_warn "未检测到 systemctl。"
        return 0
    fi
    systemctl status "${FRP_NAME}" --no-pager
}

show_install_info() {
    local installed_version="未安装"
    if version="$(get_installed_version)"; then
        installed_version="${version}"
    fi

    echo "安装路径: ${INSTALL_BIN_PATH}"
    echo "配置文件路径: ${CONFIG_PATH}"
    echo "systemd 单元路径: ${SYSTEMD_UNIT_PATH}"
    echo "当前版本: ${installed_version}"

    if systemd_available; then
        local enabled_state active_state
        enabled_state="$(systemctl is-enabled "${FRP_NAME}" 2>/dev/null || true)"
        active_state="$(systemctl is-active "${FRP_NAME}" 2>/dev/null || true)"
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

    if [[ -f "${CONFIG_PATH}" ]]; then
        print_info "配置文件已存在，保持不覆盖: ${CONFIG_PATH}"
        return 0
    fi

    if [[ -f "${LEGACY_CONFIG_PATH}" ]]; then
        print_warn "检测到旧配置文件: ${LEGACY_CONFIG_PATH}"
        if confirm "是否迁移旧配置到新路径 ${CONFIG_PATH}?" 0; then
            cp -f "${LEGACY_CONFIG_PATH}" "${CONFIG_PATH}"
            print_ok "已迁移旧配置到: ${CONFIG_PATH}"
            return 0
        fi
    fi

    cp -f "${extracted_config_path}" "${CONFIG_PATH}"
    print_ok "已生成默认配置: ${CONFIG_PATH}"
}

install_binary_and_config() {
    local version="$1"
    local arch="$2"
    local release_json="$3"
    local tag tarball_name tarball_url digest
    local tarball_path extracted_dir extracted_bin extracted_cfg

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
    extracted_bin="${extracted_dir}/${FRP_NAME}"
    extracted_cfg="${extracted_dir}/${FRP_NAME}.toml"

    if [[ ! -f "${extracted_bin}" ]]; then
        print_error "解压后未找到二进制: ${extracted_bin}"
        exit 1
    fi
    if [[ ! -f "${extracted_cfg}" ]]; then
        print_error "解压后未找到配置模板: ${extracted_cfg}"
        exit 1
    fi

    require_root
    install -m 0755 "${extracted_bin}" "${INSTALL_BIN_PATH}"
    print_ok "已安装二进制: ${INSTALL_BIN_PATH}"

    ensure_config_file "${extracted_cfg}"
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
    local current="未安装"

    if old_version="$(get_installed_version)"; then
        current="${old_version}"
    fi

    echo "=============================================="
    echo "准备安装 frps"
    echo "当前版本: ${current}"
    echo "目标版本: ${version}"
    echo "系统架构: ${arch}"
    echo "安装路径: ${INSTALL_BIN_PATH}"
    echo "配置路径: ${CONFIG_PATH}"
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
    local version arch release_json

    ensure_tools curl jq tar sha256sum
    require_root

    arch="$(detect_arch)"
    version="$(resolve_target_version "${requested_version}")"
    confirm_install_summary "${version}" "${arch}"

    print_info "获取发布信息: v${version}"
    release_json="$(fetch_release_json_by_version "${version}")" || {
        print_error "未找到发布版本: v${version}"
        exit 1
    }

    install_binary_and_config "${version}" "${arch}" "${release_json}"

    if systemd_available; then
        service_register
        systemctl enable "${FRP_NAME}" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "${FRP_NAME}"; then
            systemctl restart "${FRP_NAME}" || print_warn "服务重启失败，请手动检查配置。"
        else
            systemctl start "${FRP_NAME}" || print_warn "服务启动失败，请先检查配置后手动启动。"
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

    if [[ ! -f "${CONFIG_PATH}" ]]; then
        print_error "配置文件不存在: ${CONFIG_PATH}，请先执行 install。"
        exit 1
    fi

    if [[ ! -w "${CONFIG_PATH}" ]] && ! is_root; then
        print_warn "当前用户可能没有写权限，建议使用 sudo 执行 edit。"
    fi

    "${editor}" "${CONFIG_PATH}"
}

run_uninstall() {
    local purge_config="${1:-0}"
    require_root

    echo "=============================================="
    echo "准备卸载 frps"
    echo "将删除二进制: ${INSTALL_BIN_PATH}"
    echo "将卸载 unit: ${SYSTEMD_UNIT_PATH}"
    echo "将清理旧路径 unit: ${LEGACY_UNIT_PATH}"
    if [[ "${purge_config}" == "1" ]]; then
        echo "将删除配置: ${CONFIG_PATH}"
        echo "将清理旧配置: ${LEGACY_CONFIG_PATH}"
    else
        echo "保留配置: ${CONFIG_PATH}"
    fi
    echo "=============================================="

    if ! confirm "确认执行卸载?" 0; then
        print_error "用户取消卸载。"
        exit 1
    fi

    if systemd_available; then
        systemctl disable --now "${FRP_NAME}" >/dev/null 2>&1 || true
    fi

    rm -f "${INSTALL_BIN_PATH}"
    rm -f "${LEGACY_BIN_PATH}"

    rm -f "${SYSTEMD_UNIT_PATH}" "${LEGACY_UNIT_PATH}"
    if systemd_available; then
        systemctl daemon-reload
    fi

    if [[ "${purge_config}" == "1" ]]; then
        rm -f "${CONFIG_PATH}" "${LEGACY_CONFIG_PATH}"
        rmdir --ignore-fail-on-non-empty "${CONFIG_DIR}" 2>/dev/null || true
        print_ok "配置文件已删除。"
    fi

    print_ok "卸载完成。"
    if [[ "${purge_config}" != "1" ]]; then
        print_info "配置文件仍保留在: ${CONFIG_PATH}"
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
            list_recent_versions
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
            install_or_update "${requested}"
            ;;
        update)
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
