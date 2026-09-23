#!/usr/bin/env bash

# ============================================================
# Hysteria 2 One-Click Installer
# For Debian / Ubuntu / Rocky / Alma / CentOS Stream / Fedora
#
# Features:
#   - Install / Update Hysteria 2
#   - Interactive domain / port / password / email
#   - ACME automatic TLS certificate
#   - Password authentication
#   - Masquerade proxy
#   - systemd auto-start
#   - Firewall helper for UFW / firewalld
#   - BBR + fq optimization when supported
#   - Generate v2rayN hysteria2:// URI
#   - Generate Clash Verge / Mihomo YAML
# ============================================================

set -Eeuo pipefail

CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"
BACKUP_DIR="/etc/hysteria/backup"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Error handler
# ------------------------------------------------------------

trap 'error "脚本执行失败，行号: $LINENO"; exit 1' ERR

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行此脚本。"
    fi
}

# ------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------

detect_os() {

    if [[ ! -f /etc/os-release ]]; then
        die "无法识别 Linux 发行版。"
    fi

    source /etc/os-release

    OS="${ID:-unknown}"
    VERSION_ID="${VERSION_ID:-unknown}"

    case "$OS" in
        debian|ubuntu|rocky|almalinux|centos|fedora)
            ;;
        *)
            warn "当前系统：${OS} ${VERSION_ID}"
            warn "该脚本主要针对 Debian / Ubuntu / Rocky / AlmaLinux / CentOS Stream / Fedora。"
            read -r -p "是否继续？[y/N]: " CONTINUE
            [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 0
            ;;
    esac

    info "系统：${OS} ${VERSION_ID}"
}

# ------------------------------------------------------------
# Check systemd
# ------------------------------------------------------------

check_systemd() {

    if ! command -v systemctl >/dev/null 2>&1; then
        die "当前系统没有 systemd，无法使用此安装脚本。"
    fi
}

# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------

install_dependencies() {

    info "检查基础依赖..."

    case "$OS" in

        debian|ubuntu)
            apt-get update -y
            apt-get install -y \
                curl \
                ca-certificates \
                iproute2 \
                dnsutils \
                procps \
                openssl
            ;;

        rocky|almalinux|centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y \
                    curl \
                    ca-certificates \
                    iproute \
                    bind-utils \
                    procps-ng \
                    openssl
            else
                yum install -y \
                    curl \
                    ca-certificates \
                    iproute \
                    bind-utils \
                    procps \
                    openssl
            fi
            ;;

        fedora)
            dnf install -y \
                curl \
                ca-certificates \
                iproute \
                bind-utils \
                procps \
                openssl
            ;;

        *)
            warn "跳过自动安装依赖。"
            ;;
    esac
}

# ------------------------------------------------------------
# Validate domain
# ------------------------------------------------------------

validate_domain() {

    DOMAIN="$1"

    if [[ -z "$DOMAIN" ]]; then
        die "域名不能为空。"
    fi

    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN%%/*}"

    if [[ "$DOMAIN" =~ [^a-zA-Z0-9._-] ]]; then
        die "域名格式不正确：$DOMAIN"
    fi

    if [[ "$DOMAIN" != *.* ]]; then
        die "请输入完整域名，例如：hy.example.com"
    fi

    echo "$DOMAIN"
}

# ------------------------------------------------------------
# Check port
# ------------------------------------------------------------

validate_port() {

    local port="$1"

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        die "端口必须是数字。"
    fi

    if (( port < 1 || port > 65535 )); then
        die "端口范围必须是 1-65535。"
    fi
}

# ------------------------------------------------------------
# Check port usage
# ------------------------------------------------------------

check_port() {

    local port="$1"

    if command -v ss >/dev/null 2>&1; then

        if ss -H -lunp | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then
            warn "UDP ${port} 当前已经被占用。"
            ss -lunp | grep -E "[:.]${port}[[:space:]]" || true

            read -r -p "仍然继续？[y/N]: " CONTINUE
            [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 1
        fi

        if ss -H -ltnp | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
            warn "TCP ${port} 当前已经被占用。"
            ss -ltnp | grep -E "[:.]${port}[[:space:]]" || true

            read -r -p "仍然继续？[y/N]: " CONTINUE
            [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
}

# ------------------------------------------------------------
# Resolve domain
# ------------------------------------------------------------

check_dns() {

    info "检查域名 DNS：${DOMAIN}"

    local ips=""
    local ipv4=""
    local ipv6=""

    if command -v dig >/dev/null 2>&1; then

        ipv4="$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 5 || true)"
        ipv6="$(dig +short AAAA "$DOMAIN" 2>/dev/null | grep ':' | head -n 5 || true)"

        ips="${ipv4}"$'\n'"${ipv6}"

    else

        ips="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"

    fi

    if [[ -z "${ips// }" ]]; then
        warn "没有检测到 ${DOMAIN} 的 DNS 解析。"
        warn "ACME 证书申请大概率会失败。"
        echo
        echo "请确认："
        echo "  ${DOMAIN} -> VPS 公网 IP"
        echo

        read -r -p "仍然继续安装？[y/N]: " CONTINUE
        [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 1

    else

        success "DNS 已解析："
        echo "$ips" | sed 's/^/    /'
    fi
}

# ------------------------------------------------------------
# Get public IPv4
# ------------------------------------------------------------

get_public_ip() {

    PUBLIC_IP=""

    if command -v curl >/dev/null 2>&1; then
        PUBLIC_IP="$(curl -4 -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ -n "$PUBLIC_IP" ]]; then
        info "VPS 公网 IPv4：${PUBLIC_IP}"
    fi
}

# ------------------------------------------------------------
# Generate password
# ------------------------------------------------------------

generate_password() {

    if command -v openssl >/dev/null 2>&1; then

        PASSWORD="$(openssl rand -hex 24)"

    else

        PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"

    fi
}

# ------------------------------------------------------------
# Escape YAML double quoted value
# ------------------------------------------------------------

yaml_escape() {

    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '%s' "$value"
}

# ------------------------------------------------------------
# Install Hysteria
# ------------------------------------------------------------

install_hysteria() {

    info "安装 / 更新 Hysteria 2..."

    # 官方安装脚本
    # 使用 root 运行服务，避免 ACME 证书权限问题
    if ! HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/); then
        die "Hysteria 2 安装失败。"
    fi

    if ! command -v hysteria >/dev/null 2>&1; then
        die "找不到 hysteria 可执行文件。"
    fi

    success "Hysteria 2 安装完成。"

    hysteria version || true
}

# ------------------------------------------------------------
# Backup old configuration
# ------------------------------------------------------------

backup_config() {

    mkdir -p "$BACKUP_DIR"

    if [[ -f "$CONFIG" ]]; then

        local backup_file

        backup_file="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).yaml"

        cp -a "$CONFIG" "$backup_file"

        success "旧配置已备份：$backup_file"
    fi
}

# ------------------------------------------------------------
# Create configuration
# ------------------------------------------------------------

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

# Automatic TLS certificate through ACME
acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

# Password authentication
auth:
  type: password
  password: "${yaml_password}"

# Masquerade
# This is optional. It makes normal HTTP requests receive
# content proxied from the specified HTTPS website.
masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true

# Keep UDP forwarding enabled
disableUDP: false

# Reasonable idle timeout
udpIdleTimeout: 60s
EOF

    chmod 600 "$CONFIG"

    success "配置文件已生成：$CONFIG"
}

# ------------------------------------------------------------
# Validate Hysteria config
# ------------------------------------------------------------

validate_config() {

    info "检查 Hysteria 配置..."

    if hysteria server -c "$CONFIG" --help >/dev/null 2>&1; then
        :
    fi

    # Hysteria doesn't provide a universal "config test" command
    # in every release, so rely on systemd startup and logs.
    success "配置文件已生成，稍后通过 systemd 启动检查。"
}

# ------------------------------------------------------------
# Firewall - UFW
# ------------------------------------------------------------

configure_ufw() {

    if ! command -v ufw >/dev/null 2>&1; then
        return 0
    fi

    if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        return 0
    fi

    info "检测到 UFW 已启用，开放 UDP ${PORT}..."

    ufw allow "${PORT}/udp" >/dev/null

    success "UFW 已允许 UDP ${PORT}"
}

# ------------------------------------------------------------
# Firewall - firewalld
# ------------------------------------------------------------

configure_firewalld() {

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        return 0
    fi

    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        return 0
    fi

    info "检测到 firewalld 已启用，开放 UDP ${PORT}..."

    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null

    success "firewalld 已允许 UDP ${PORT}"
}

# ------------------------------------------------------------
# Firewall helper
# ------------------------------------------------------------

configure_firewall() {

    configure_ufw
    configure_firewalld

    if ! command -v ufw >/dev/null 2>&1 &&
       ! command -v firewall-cmd >/dev/null 2>&1; then

        warn "没有检测到 UFW / firewalld。"

        echo
        echo "请确认 VPS 云厂商安全组允许："
        echo
        echo "    UDP ${PORT}"
        echo
        echo "例如："
        echo "AWS / Azure / GCP / Oracle / 阿里云 / 腾讯云等"
        echo "都可能需要在控制台额外开放 UDP 端口。"
    fi
}

# ------------------------------------------------------------
# BBR optimization
# ------------------------------------------------------------

enable_bbr() {

    info "检查 BBR..."

    local available_cc=""
    local available_qdisc=""

    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        available_cc="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
    fi

    if [[ -f /proc/sys/net/sched/available ]]; then
        available_qdisc="$(cat /proc/sys/net/sched/available)"
    fi

    if grep -qw bbr <<< "$available_cc"; then

        mkdir -p /etc/sysctl.d

        cat > /etc/sysctl.d/99-hysteria-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null 2>&1 || true

        success "BBR 已启用。"

    else

        warn "当前内核没有检测到 BBR，跳过 BBR 设置。"
    fi
}

# ------------------------------------------------------------
# Start service
# ------------------------------------------------------------

start_service() {

    info "重新加载 systemd..."

    systemctl daemon-reload

    info "设置 Hysteria 开机自启..."

    systemctl enable "$SERVICE" >/dev/null

    info "启动 Hysteria..."

    systemctl restart "$SERVICE"

    sleep 3

    if systemctl is-active --quiet "$SERVICE"; then

        success "Hysteria 2 服务运行正常。"

    else

        error "Hysteria 2 启动失败。"

        echo
        echo "最近日志："
        echo "------------------------------------------------------------"

        journalctl --no-pager -n 50 -u "$SERVICE" || true

        echo "------------------------------------------------------------"

        exit 1
    fi
}

# ------------------------------------------------------------
# Show listening port
# ------------------------------------------------------------

check_listening() {

    sleep 1

    if command -v ss >/dev/null 2>&1; then

        echo
        info "检查监听端口..."

        ss -lunp | grep -E "[:.]${PORT}[[:space:]]" || \
            warn "没有在 ss 中看到 UDP ${PORT}，请检查服务日志。"
    fi
}

# ------------------------------------------------------------
# Generate v2rayN URI
# ------------------------------------------------------------

generate_uri() {

    # 密码建议使用脚本生成的 hex 密码。
    # 如果用户手动输入特殊字符，则 URL encode。
    if command -v python3 >/dev/null 2>&1; then

        URI_PASSWORD="$(
            python3 - "$PASSWORD" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=''))
PY
        )"

    else

        # 手动输入特殊字符时，如果没有 python3，
        # 尽量提醒用户。
        URI_PASSWORD="$PASSWORD"
    fi

    V2RAY_URI="hysteria2://${URI_PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}"
}

# ------------------------------------------------------------
# Generate Clash configuration
# ------------------------------------------------------------

generate_clash() {

    CLASH_CONFIG=$(cat <<EOF
- name: "HY2-${DOMAIN}"
  type: hysteria2
  server: ${DOMAIN}
  port: ${PORT}
  password: "${PASSWORD}"
  sni: ${DOMAIN}
  skip-cert-verify: false
EOF
)
}

# ------------------------------------------------------------
# Save node information
# ------------------------------------------------------------

save_node_info() {

    NODE_FILE="/root/hy2-node.txt"

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
Clash Verge / Mihomo
------------------------------------------------------------

${CLASH_CONFIG}

------------------------------------------------------------
Server Config
------------------------------------------------------------

${CONFIG}

============================================================
EOF

    chmod 600 "$NODE_FILE"

    success "节点信息已保存：$NODE_FILE"
}

# ------------------------------------------------------------
# Print result
# ------------------------------------------------------------

show_result() {

    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Hysteria 2 安装成功！${RESET}"
    echo "============================================================"
    echo
    echo -e "${CYAN}服务器：${RESET} ${DOMAIN}"
    echo -e "${CYAN}端口：${RESET}   ${PORT}"
    echo -e "${CYAN}密码：${RESET}   ${PASSWORD}"
    echo -e "${CYAN}SNI：${RESET}    ${DOMAIN}"
    echo
    echo "============================================================"
    echo -e "${YELLOW}【v2rayN / Hysteria2】${RESET}"
    echo "============================================================"
    echo
    echo "$V2RAY_URI"
    echo
    echo "============================================================"
    echo -e "${YELLOW}【Clash Verge Rev / Mihomo】${RESET}"
    echo "============================================================"
    echo
    echo "$CLASH_CONFIG"
    echo
    echo "============================================================"
    echo -e "${YELLOW}配置文件：${RESET}"
    echo "$CONFIG"
    echo
    echo -e "${YELLOW}节点信息备份：${RESET}"
    echo "$NODE_FILE"
    echo
    echo "============================================================"
    echo -e "${GREEN}服务状态：${RESET}"
    systemctl --no-pager --full status "$SERVICE" | head -n 15 || true
    echo "============================================================"
    echo
    echo -e "${GREEN}完成。${RESET}"
    echo
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {

    check_root
    detect_os
    check_systemd
    install_dependencies

    echo
    echo "============================================================"
    echo "        Hysteria 2 一键安装"
    echo "============================================================"
    echo

    read -r -p "请输入你的域名，例如 hy.example.com: " DOMAIN
    DOMAIN="$(validate_domain "$DOMAIN")"

    echo
    read -r -p "请输入端口 [默认 443]: " PORT
    PORT="${PORT:-443}"

    validate_port "$PORT"
    check_port "$PORT"

    echo
    read -r -p "请输入 ACME 邮箱: " EMAIL

    if [[ -z "$EMAIL" ]]; then
        die "ACME 邮箱不能为空。"
    fi

    echo
    echo "密码设置："
    echo "1. 自动生成随机强密码"
    echo "2. 自己输入密码"
    echo

    read -r -p "请选择 [默认 1]: " PASSWORD_MODE
    PASSWORD_MODE="${PASSWORD_MODE:-1}"

    if [[ "$PASSWORD_MODE" == "2" ]]; then

        read -r -s -p "请输入密码: " PASSWORD
        echo

        if [[ -z "$PASSWORD" ]]; then
            die "密码不能为空。"
        fi

    else

        generate_password

        echo
        echo "自动生成密码：${PASSWORD}"
    fi

    echo
    read -r -p "Masquerade 目标网站 [默认 https://www.bing.com/]: " MASQUERADE_URL
    MASQUERADE_URL="${MASQUERADE_URL:-https://www.bing.com/}"

    echo
    echo "============================================================"
    echo "即将安装："
    echo "============================================================"
    echo "域名       : ${DOMAIN}"
    echo "端口       : ${PORT}/UDP"
    echo "ACME 邮箱  : ${EMAIL}"
    echo "密码       : ${PASSWORD}"
    echo "伪装网站   : ${MASQUERADE_URL}"
    echo "============================================================"
    echo

    get_public_ip
    check_dns

    echo
    read -r -p "确认开始安装？[Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

    echo

    backup_config
    install_hysteria
    create_config
    validate_config
    configure_firewall
    enable_bbr
    start_service
    check_listening
    generate_uri
    generate_clash
    save_node_info
    show_result
}

main "$@"