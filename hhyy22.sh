#!/usr/bin/env bash

# ============================================================
# Hysteria 2 Installer & Manager
# Supported: Debian / Ubuntu / Rocky / AlmaLinux / CentOS / Fedora
#
# Usage:
#   bash /root/hy2.sh
#   bash /root/hy2.sh install
#   hy2
#   hy2 install
#
# Menu:
#   1. Install / Reconfigure Hysteria 2
#   2. Uninstall Hysteria 2
#   3. Get v2rayN Hysteria2 URI
#   4. Get Clash Verge / Mihomo Config
#   5. View Service Status / UDP Listener
#   6. View Recent Logs
#   7. Restart Service
# ============================================================

set -Eeuo pipefail

CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"
BACKUP_DIR="/etc/hysteria/backup"
NODE_FILE="/root/hy2-node.txt"
COMMAND_PATH="/usr/local/bin/hy2"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[OK]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

die() {
    error "$*"
    exit 1
}

pause() {
    echo
    read -r -p "按回车键继续..." _
}

trap 'error "脚本执行失败，行号: ${LINENO}"; exit 1' ERR

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

check_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，无法使用此脚本。"
}

detect_os() {
    [[ -f /etc/os-release ]] || die "无法识别 Linux 发行版。"

    # shellcheck disable=SC1091
    source /etc/os-release

    OS="${ID:-unknown}"
    VERSION_ID="${VERSION_ID:-unknown}"

    case "$OS" in
        debian|ubuntu|rocky|almalinux|centos|fedora)
            ;;
        *)
            warn "当前系统：${OS} ${VERSION_ID}"
            warn "该脚本主要针对 Debian / Ubuntu / Rocky / AlmaLinux / CentOS / Fedora。"
            read -r -p "是否继续？[y/N]: " continue_install
            [[ "$continue_install" =~ ^[Yy]$ ]] || exit 0
            ;;
    esac

    info "系统：${OS} ${VERSION_ID}"
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

install_dependencies() {
    info "检查并安装依赖..."

    case "$OS" in
        debian|ubuntu)
            apt-get update -y
            apt-get install -y curl ca-certificates iproute2 dnsutils procps openssl python3
            ;;
        rocky|almalinux|centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl ca-certificates iproute bind-utils procps-ng openssl python3
            else
                yum install -y curl ca-certificates iproute bind-utils procps openssl python3
            fi
            ;;
        fedora)
            dnf install -y curl ca-certificates iproute bind-utils procps-ng openssl python3
            ;;
        *)
            warn "未知系统，跳过依赖自动安装。"
            ;;
    esac
}

# ------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------

validate_domain() {
    local domain="$1"

    [[ -n "$domain" ]] || die "域名不能为空。"

    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    [[ "$domain" != *.* ]] && die "请输入完整域名，例如：hy.example.com"

    if [[ "$domain" =~ [^a-zA-Z0-9._-] ]]; then
        die "域名格式不正确：${domain}"
    fi

    printf '%s\n' "$domain"
}

validate_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
    (( port >= 1 && port <= 65535 )) || die "端口范围必须为 1-65535。"
}

yaml_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '%s' "$value"
}

uri_encode() {
    local value="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=''))
PY
    else
        warn "未检测到 python3；若密码有特殊字符，URI 可能无法正确编码。"
        printf '%s' "$value"
    fi
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        PASSWORD="$(openssl rand -hex 24)"
    else
        PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
    fi
}

install_command_shortcut() {
    if [[ "$SCRIPT_PATH" == "$COMMAND_PATH" ]]; then
        return 0
    fi

    if [[ -f "$SCRIPT_PATH" ]]; then
        chmod 700 "$SCRIPT_PATH" || true
        ln -sfn "$SCRIPT_PATH" "$COMMAND_PATH"
        chmod 755 "$COMMAND_PATH" || true
        success "已创建命令：hy2"
    else
        warn "无法创建 hy2 命令；请用 bash ${SCRIPT_PATH} 运行脚本。"
    fi
}

# ------------------------------------------------------------
# Network / DNS checks
# ------------------------------------------------------------

check_port() {
    local port="$1"

    command -v ss >/dev/null 2>&1 || return 0

    if ss -H -lunp | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then
        warn "UDP ${port} 当前已被占用："
        ss -lunp | grep -E "[:.]${port}[[:space:]]" || true
        read -r -p "仍然继续？[y/N]: " continue_port
        [[ "$continue_port" =~ ^[Yy]$ ]] || return 1
    fi

    if ss -H -ltnp | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
        warn "TCP ${port} 当前已被占用："
        ss -ltnp | grep -E "[:.]${port}[[:space:]]" || true
        read -r -p "仍然继续？[y/N]: " continue_port
        [[ "$continue_port" =~ ^[Yy]$ ]] || return 1
    fi
}

get_public_ip() {
    PUBLIC_IP=""

    if command -v curl >/dev/null 2>&1; then
        PUBLIC_IP="$(curl -4 -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ -n "$PUBLIC_IP" ]]; then
        info "VPS 公网 IPv4：${PUBLIC_IP}"
    else
        warn "无法自动获取 VPS 公网 IPv4。"
    fi
}

check_dns() {
    info "检查域名 DNS：${DOMAIN}"

    local ipv4=""
    local ipv6=""
    local ips=""

    if command -v dig >/dev/null 2>&1; then
        ipv4="$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 5 || true)"
        ipv6="$(dig +short AAAA "$DOMAIN" 2>/dev/null | grep ':' | head -n 5 || true)"
        ips="${ipv4}"$'\n'"${ipv6}"
    else
        ips="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    fi

    if [[ -z "${ips//[[:space:]]/}" ]]; then
        warn "没有检测到 ${DOMAIN} 的 DNS 解析。"
        warn "ACME 证书申请很可能失败。"
        echo
        echo "请确认：${DOMAIN} 的 A/AAAA 记录已指向当前 VPS 公网 IP。"
        echo
        read -r -p "仍然继续安装？[y/N]: " continue_dns
        [[ "$continue_dns" =~ ^[Yy]$ ]] || return 1
    else
        success "DNS 已解析："
        echo "$ips" | sed '/^[[:space:]]*$/d; s/^/    /'
    fi
}

# ------------------------------------------------------------
# Hysteria installation / config
# ------------------------------------------------------------

install_hysteria() {
    info "安装 / 更新 Hysteria 2..."

    if ! HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/); then
        die "Hysteria 2 安装失败。"
    fi

    command -v hysteria >/dev/null 2>&1 || die "找不到 hysteria 可执行文件。"

    success "Hysteria 2 已安装。"
    hysteria version || true
}

backup_config() {
    mkdir -p "$BACKUP_DIR"

    if [[ -f "$CONFIG" ]]; then
        local backup_file
        backup_file="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).yaml"

        cp -a "$CONFIG" "$backup_file"
        chmod 600 "$backup_file" || true

        success "旧配置已备份：${backup_file}"
    fi
}

create_config() {
    mkdir -p /etc/hysteria

    local yaml_password
    yaml_password="$(yaml_escape "$PASSWORD")"

    cat > "$CONFIG" <<EOF
# ============================================================
# Hysteria 2 Server Configuration
# Generated by hy2.sh
# ============================================================

listen: :${PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

auth:
  type: password
  password: "${yaml_password}"

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true

disableUDP: false
udpIdleTimeout: 60s
EOF

    chmod 600 "$CONFIG"

    success "服务端配置已生成：${CONFIG}"
}

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

configure_ufw() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -qi "Status: active" || return 0

    info "检测到 UFW，开放 UDP ${PORT}..."
    ufw allow "${PORT}/udp" >/dev/null
    success "UFW 已开放 UDP ${PORT}"
}

configure_firewalld() {
    command -v firewall-cmd >/dev/null 2>&1 || return 0
    systemctl is-active --quiet firewalld 2>/dev/null || return 0

    info "检测到 firewalld，开放 UDP ${PORT}..."
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null
    success "firewalld 已开放 UDP ${PORT}"
}

configure_firewall() {
    configure_ufw
    configure_firewalld

    if ! command -v ufw >/dev/null 2>&1 &&
       ! command -v firewall-cmd >/dev/null 2>&1; then
        warn "没有检测到 UFW 或 firewalld。"
    fi

    echo
    warn "还必须确认 VPS 云厂商安全组/防火墙允许 UDP ${PORT}。"
}

# ------------------------------------------------------------
# BBR / fq
# ------------------------------------------------------------

enable_bbr() {
    info "检查 BBR 支持..."

    local available_cc=""
    [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]] && \
        available_cc="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"

    if grep -qw bbr <<< "$available_cc"; then
        mkdir -p /etc/sysctl.d

        cat > /etc/sysctl.d/99-hysteria-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null 2>&1 || true
        success "BBR + fq 已设置。"
    else
        warn "当前内核未检测到 BBR，跳过 BBR 设置。"
    fi
}

# ------------------------------------------------------------
# systemd service
# ------------------------------------------------------------

start_service() {
    info "重新加载 systemd..."
    systemctl daemon-reload

    info "设置服务开机启动..."
    systemctl enable "$SERVICE" >/dev/null

    info "启动 Hysteria 2..."
    systemctl restart "$SERVICE"

    sleep 3

    if systemctl is-active --quiet "$SERVICE"; then
        success "Hysteria 2 服务运行正常。"
    else
        error "Hysteria 2 启动失败。"
        echo
        journalctl --no-pager -n 100 -u "$SERVICE" || true
        exit 1
    fi
}

check_listening() {
    command -v ss >/dev/null 2>&1 || return 0

    echo
    info "检查 UDP ${PORT} 监听状态："

    ss -lunp | grep -E "[:.]${PORT}[[:space:]]" || \
        warn "没有发现 UDP ${PORT} 监听，请检查服务日志。"
}

restart_hysteria() {
    clear || true

    echo
    info "重启 Hysteria 2 服务..."

    systemctl restart "$SERVICE"

    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then
        success "Hysteria 2 已重启，服务正常。"
    else
        error "重启失败，最近日志如下："
        journalctl --no-pager -n 80 -u "$SERVICE" || true
    fi

    pause
}

# ------------------------------------------------------------
# Client node generation
# ------------------------------------------------------------

generate_uri() {
    URI_PASSWORD="$(uri_encode "$PASSWORD")"
    V2RAY_URI="hysteria2://${URI_PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#HY2-${DOMAIN}"
}

generate_clash() {
    local yaml_password
    yaml_password="$(yaml_escape "$PASSWORD")"

    CLASH_CONFIG=$(cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: "HY2-${DOMAIN}"
    type: hysteria2
    server: ${DOMAIN}
    port: ${PORT}
    password: "${yaml_password}"
    sni: "${DOMAIN}"
    skip-cert-verify: false

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "HY2-${DOMAIN}"

rules:
  - MATCH,PROXY
EOF
)
}

save_node_info() {
    cat > "$NODE_FILE" <<EOF
============================================================
Hysteria 2 Node
Generated: $(date '+%Y-%m-%d %H:%M:%S')
============================================================

Domain:
${DOMAIN}

Port:
${PORT}

Password:
${PASSWORD}

SNI:
${DOMAIN}

Protocol:
Hysteria2

------------------------------------------------------------
v2rayN / Hysteria2 URI
------------------------------------------------------------

${V2RAY_URI}

------------------------------------------------------------
Clash Verge / Mihomo Full Config
------------------------------------------------------------

${CLASH_CONFIG}

------------------------------------------------------------
Server Config
------------------------------------------------------------

${CONFIG}

============================================================
EOF

    chmod 600 "$NODE_FILE"
    success "节点信息已保存：${NODE_FILE}"
}

# ------------------------------------------------------------
# Load current configuration
# ------------------------------------------------------------

load_current_node() {
    [[ -f "$CONFIG" ]] || die "未找到 Hysteria 配置文件：${CONFIG}"

    CURRENT_PORT="$(
        awk '
            /^[[:space:]]*listen:[[:space:]]*/ {
                value=$0
                sub(/^[[:space:]]*listen:[[:space:]]*/, "", value)
                sub(/[[:space:]]+#.*/, "", value)
                gsub(/["'\'' ]/, "", value)
                n=split(value, a, ":")
                print a[n]
                exit
            }
        ' "$CONFIG"
    )"

    CURRENT_DOMAIN="$(
        awk '
            /^[[:space:]]*acme:[[:space:]]*$/ {
                in_acme=1
                next
            }
            in_acme && /^[[:space:]]*domains:[[:space:]]*$/ {
                in_domains=1
                next
            }
            in_domains && /^[[:space:]]*-[[:space:]]*/ {
                value=$0
                sub(/^[[:space:]]*-[[:space:]]*/, "", value)
                sub(/[[:space:]]+#.*/, "", value)
                gsub(/["'\'' ]/, "", value)
                print value
                exit
            }
            in_acme && /^[^[:space:]]/ {
                exit
            }
        ' "$CONFIG"
    )"

    CURRENT_PASSWORD="$(
        awk '
            /^[[:space:]]*password:[[:space:]]*/ {
                value=$0
                sub(/^[[:space:]]*password:[[:space:]]*/, "", value)
                sub(/[[:space:]]+#.*/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

                if (value ~ /^".*"$/) {
                    sub(/^"/, "", value)
                    sub(/"$/, "", value)
                } else if (value ~ /^\047.*\047$/) {
                    sub(/^\047/, "", value)
                    sub(/\047$/, "", value)
                }

                print value
                exit
            }
        ' "$CONFIG"
    )"

    [[ -n "$CURRENT_DOMAIN" ]] || die "无法读取 ACME 域名。"
    [[ -n "$CURRENT_PORT" ]] || die "无法读取服务端口。"
    [[ "$CURRENT_PORT" =~ ^[0-9]+$ ]] || die "读取的端口格式无效：${CURRENT_PORT}"
    [[ -n "$CURRENT_PASSWORD" ]] || die "无法读取 auth.password。"

    CURRENT_SNI="$CURRENT_DOMAIN"
    CURRENT_URI_PASSWORD="$(uri_encode "$CURRENT_PASSWORD")"
    CURRENT_YAML_PASSWORD="$(yaml_escape "$CURRENT_PASSWORD")"
    CURRENT_URI="hysteria2://${CURRENT_URI_PASSWORD}@${CURRENT_DOMAIN}:${CURRENT_PORT}/?sni=${CURRENT_SNI}#HY2-${CURRENT_DOMAIN}"
}

# ------------------------------------------------------------
# Menu output functions
# ------------------------------------------------------------

show_v2rayn_node() {
    load_current_node

    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       v2rayN / Hysteria2 节点${RESET}"
    echo "============================================================"
    echo
    echo "服务器 : ${CURRENT_DOMAIN}"
    echo "端口   : ${CURRENT_PORT}/UDP"
    echo "SNI    : ${CURRENT_SNI}"
    echo
    echo "复制下方 URI，在 v2rayN 中使用“导入分享链接”："
    echo
    echo "$CURRENT_URI"

    pause
}

show_clash_verge_node() {
    load_current_node

    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Clash Verge Rev / Mihomo 配置${RESET}"
    echo "============================================================"
    echo
    echo "复制下方完整 YAML 到 Clash Verge 的本地配置："
    echo

    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: "HY2-${CURRENT_DOMAIN}"
    type: hysteria2
    server: ${CURRENT_DOMAIN}
    port: ${CURRENT_PORT}
    password: "${CURRENT_YAML_PASSWORD}"
    sni: "${CURRENT_SNI}"
    skip-cert-verify: false

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "HY2-${CURRENT_DOMAIN}"

rules:
  - MATCH,PROXY
EOF

    echo
    info "PROXY 策略组只包含 HY2 节点；默认流量固定通过 HY2。"

    pause
}

show_hysteria_status() {
    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Hysteria 2 服务状态${RESET}"
    echo "============================================================"
    echo

    systemctl --no-pager --full status "$SERVICE" | head -n 30 || true

    echo
    echo "============================================================"
    echo -e "${YELLOW}【UDP 监听状态】${RESET}"
    echo "============================================================"

    if command -v ss >/dev/null 2>&1; then
        if [[ -f "$CONFIG" ]]; then
            load_current_node
            ss -lunp | grep -E "[:.]${CURRENT_PORT}[[:space:]]" || \
                warn "没有检测到 UDP ${CURRENT_PORT} 正在监听。"
        else
            warn "尚未安装或配置 Hysteria 2。"
        fi
    else
        warn "未安装 ss，无法查看监听端口。"
    fi

    pause
}

show_hysteria_logs() {
    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Hysteria 2 最近 80 行日志${RESET}"
    echo "============================================================"
    echo

    journalctl --no-pager -n 80 -u "$SERVICE" || true

    pause
}

# ------------------------------------------------------------
# Uninstall Hysteria
# ------------------------------------------------------------

uninstall_hysteria() {
    clear || true

    echo
    echo "============================================================"
    echo -e "${RED}       卸载 Hysteria 2${RESET}"
    echo "============================================================"
    echo
    warn "此操作会停止并删除 Hysteria 2 服务、程序、配置、证书和节点信息。"
    echo
    echo "将删除："
    echo "  - ${CONFIG}"
    echo "  - /etc/hysteria/"
    echo "  - ${NODE_FILE}"
    echo
    warn "卸载后，现有 HY2 节点将无法使用。"
    echo

    read -r -p "确定卸载？请输入 YES 确认: " uninstall_confirm

    if [[ "$uninstall_confirm" != "YES" ]]; then
        info "已取消卸载。"
        pause
        return 0
    fi

    echo
    info "停止并禁用 Hysteria 服务..."

    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true

    if command -v curl >/dev/null 2>&1; then
        info "执行 Hysteria 官方卸载程序..."
        bash <(curl -fsSL https://get.hy2.sh/) --remove || \
            warn "官方卸载程序返回异常，继续清理本脚本创建的文件。"
    else
        warn "未找到 curl，跳过官方卸载程序。"
    fi

    info "清理配置、备份、节点信息及服务残留..."

    rm -rf /etc/hysteria
    rm -f "$NODE_FILE"
    rm -f "/etc/systemd/system/${SERVICE}"
    rm -f "/etc/systemd/system/multi-user.target.wants/${SERVICE}"

    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true

    success "Hysteria 2 已卸载。"
    info "管理脚本和 hy2 命令已保留；可再次运行 hy2 后选择安装。"

    pause
}

# ------------------------------------------------------------
# Installer workflow
# ------------------------------------------------------------

main() {
    check_root
    check_systemd
    detect_os
    install_dependencies
    install_command_shortcut

    clear || true

    echo
    echo "============================================================"
    echo "        Hysteria 2 安装 / 重新配置"
    echo "============================================================"
    echo

    read -r -p "请输入你的域名，例如 hy.example.com: " DOMAIN
    DOMAIN="$(validate_domain "$DOMAIN")"

    echo
    read -r -p "请输入端口 [默认 443]: " PORT
    PORT="${PORT:-443}"

    validate_port "$PORT"
    check_port "$PORT" || return 0

    echo
    read -r -p "请输入 ACME 邮箱: " EMAIL
    [[ -n "$EMAIL" ]] || die "ACME 邮箱不能为空。"

    echo
    echo "密码设置："
    echo "1. 自动生成随机强密码"
    echo "2. 自己输入密码"
    echo

    read -r -p "请选择 [默认 1]: " password_mode
    password_mode="${password_mode:-1}"

    if [[ "$password_mode" == "2" ]]; then
        read -r -s -p "请输入密码: " PASSWORD
        echo
        [[ -n "$PASSWORD" ]] || die "密码不能为空。"
    else
        generate_password
        echo
        success "已生成随机密码：${PASSWORD}"
    fi

    echo
    read -r -p "Masquerade 目标网站 [默认 https://www.bing.com/]: " MASQUERADE_URL
    MASQUERADE_URL="${MASQUERADE_URL:-https://www.bing.com/}"

    echo
    echo "============================================================"
    echo "即将执行："
    echo "============================================================"
    echo "域名       : ${DOMAIN}"
    echo "端口       : ${PORT}/UDP"
    echo "ACME 邮箱  : ${EMAIL}"
    echo "密码       : ${PASSWORD}"
    echo "伪装网站   : ${MASQUERADE_URL}"
    echo "============================================================"

    echo
    get_public_ip
    check_dns || return 0

    echo
    read -r -p "确认开始安装？[Y/n]: " confirm_install
    confirm_install="${confirm_install:-Y}"

    [[ "$confirm_install" =~ ^[Yy]$ ]] || return 0

    backup_config
    install_hysteria
    create_config
    configure_firewall
    enable_bbr
    start_service
    check_listening
    generate_uri
    generate_clash
    save_node_info

    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Hysteria 2 安装成功！${RESET}"
    echo "============================================================"
    echo
    echo "服务器 : ${DOMAIN}"
    echo "端口   : ${PORT}/UDP"
    echo "密码   : ${PASSWORD}"
    echo "SNI    : ${DOMAIN}"
    echo
    echo "============================================================"
    echo -e "${YELLOW}【v2rayN URI】${RESET}"
    echo "============================================================"
    echo
    echo "${V2RAY_URI}"
    echo
    echo "============================================================"
    echo -e "${YELLOW}【节点信息文件】${RESET}"
    echo "============================================================"
    echo
    echo "${NODE_FILE}"
    echo
    echo "以后直接输入：hy2"
    echo "即可获取节点配置、查看状态、日志或卸载。"
    echo

    pause
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

hy2_menu() {
    while true; do
        clear || true

        echo
        echo "============================================================"
        echo -e "${CYAN}             Hysteria 2 管理菜单${RESET}"
        echo "============================================================"
        echo
        echo "  1. 安装 / 重新配置 Hysteria 2"
        echo "  2. 卸载 Hysteria 2"
        echo "  3. 获取 v2rayN Hysteria2 节点"
        echo "  4. 获取 Clash Verge / Mihomo 配置"
        echo "  5. 查看 Hysteria 2 服务状态和 UDP 监听"
        echo "  6. 查看最近 80 行服务日志"
        echo "  7. 重启 Hysteria 2 服务"
        echo "  0. 退出"
        echo
        echo "============================================================"
        echo

        read -r -p "请选择 [0-7]: " choice

        case "$choice" in
            1)
                main
                ;;
            2)
                uninstall_hysteria
                ;;
            3)
                show_v2rayn_node
                ;;
            4)
                show_clash_verge_node
                ;;
            5)
                show_hysteria_status
                ;;
            6)
                show_hysteria_logs
                ;;
            7)
                restart_hysteria
                ;;
            0)
                clear || true
                exit 0
                ;;
            *)
                warn "无效选择，请输入 0-7。"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Script entry
# ------------------------------------------------------------

check_root

case "${1:-}" in
    install|update)
        main
        ;;
    uninstall|remove)
        uninstall_hysteria
        ;;
    status)
        show_hysteria_status
        ;;
    logs)
        show_hysteria_logs
        ;;
    v2rayn|uri)
        show_v2rayn_node
        ;;
    clash)
        show_clash_verge_node
        ;;
    restart)
        restart_hysteria
        ;;
    menu|"")
        hy2_menu
        ;;
    *)
        echo "用法："
        echo "  hy2              打开管理菜单"
        echo "  hy2 install      安装或重新配置"
        echo "  hy2 uninstall    卸载 Hysteria 2"
        echo "  hy2 status       查看状态和监听端口"
        echo "  hy2 logs         查看日志"
        echo "  hy2 v2rayn       显示 v2rayN URI"
        echo "  hy2 clash        显示 Clash Verge YAML"
        echo "  hy2 restart      重启服务"
        exit 1
        ;;
esac
