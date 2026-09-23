#!/usr/bin/env bash

# ============================================================
# Hysteria 2 One-Click Installer & Manager
# For Debian / Ubuntu / Rocky / Alma / CentOS Stream / Fedora
#
# Usage:
#   bash /root/hy2.sh install
#   bash /root/hy2.sh
#   hy2 install
#   hy2
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
#   - Interactive node information menu
# ============================================================

set -Eeuo pipefail

CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"
BACKUP_DIR="/etc/hysteria/backup"
NODE_FILE="/root/hy2-node.txt"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
COMMAND_PATH="/usr/local/bin/hy2"

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

pause() {
    echo
    read -r -p "按回车键继续..." _
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

    # shellcheck disable=SC1091
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

    info "检查并安装基础依赖..."

    case "$OS" in
        debian|ubuntu)
            apt-get update -y
            apt-get install -y \
                curl \
                ca-certificates \
                iproute2 \
                dnsutils \
                procps \
                openssl \
                python3
            ;;
        rocky|almalinux|centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y \
                    curl \
                    ca-certificates \
                    iproute \
                    bind-utils \
                    procps-ng \
                    openssl \
                    python3
            else
                yum install -y \
                    curl \
                    ca-certificates \
                    iproute \
                    bind-utils \
                    procps \
                    openssl \
                    python3
            fi
            ;;
        fedora)
            dnf install -y \
                curl \
                ca-certificates \
                iproute \
                bind-utils \
                procps \
                openssl \
                python3
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

    local domain="$1"

    if [[ -z "$domain" ]]; then
        die "域名不能为空。"
    fi

    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    if [[ "$domain" =~ [^a-zA-Z0-9._-] ]]; then
        die "域名格式不正确：${domain}"
    fi

    if [[ "$domain" != *.* ]]; then
        die "请输入完整域名，例如：hy.example.com"
    fi

    printf '%s\n' "$domain"
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

    if ! command -v ss >/dev/null 2>&1; then
        return 0
    fi

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

    if [[ -z "${ips//[[:space:]]/}" ]]; then
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
        echo "$ips" | sed '/^[[:space:]]*$/d; s/^/    /'
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
    else
        warn "无法自动获取 VPS 公网 IPv4。"
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
# URL encode URI password
# ------------------------------------------------------------

uri_encode() {

    local value="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=''))
PY
    else
        printf '%s' "$value"
        warn "未安装 python3；若密码包含特殊字符，URI 可能无法正确导入。"
    fi
}

# ------------------------------------------------------------
# Install command shortcut
# ------------------------------------------------------------

install_command_shortcut() {

    if [[ "$SCRIPT_PATH" == "$COMMAND_PATH" ]]; then
        return 0
    fi

    if [[ -f "$SCRIPT_PATH" ]]; then
        chmod 700 "$SCRIPT_PATH" || true
        ln -sfn "$SCRIPT_PATH" "$COMMAND_PATH"
        chmod 755 "$COMMAND_PATH" || true
        success "命令已创建：hy2"
    else
        warn "无法确定脚本真实路径，跳过创建 hy2 命令。"
    fi
}

# ------------------------------------------------------------
# Install Hysteria
# ------------------------------------------------------------

install_hysteria() {

    info "安装 / 更新 Hysteria 2..."

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
        chmod 600 "$backup_file" || true

        success "旧配置已备份：${backup_file}"
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

# Masquerade proxy
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

    success "配置文件已生成：${CONFIG}"
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
        echo "AWS / Azure / GCP / Oracle / 阿里云 / 腾讯云等，"
        echo "都可能需要在控制台额外开放 UDP 端口。"
    fi
}

# ------------------------------------------------------------
# BBR optimization
# ------------------------------------------------------------

enable_bbr() {

    info "检查 BBR..."

    local available_cc=""

    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        available_cc="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
    fi

    if grep -qw bbr <<< "$available_cc"; then
        mkdir -p /etc/sysctl.d

        cat > /etc/sysctl.d/99-hysteria-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null 2>&1 || true

        success "BBR + fq 已设置。"
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
        journalctl --no-pager -n 80 -u "$SERVICE" || true
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

    URI_PASSWORD="$(uri_encode "$PASSWORD")"

    V2RAY_URI="hysteria2://${URI_PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#HY2-${DOMAIN}"
}

# ------------------------------------------------------------
# Generate complete Clash Verge / Mihomo configuration
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Save node information
# ------------------------------------------------------------

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
# Print install result
# ------------------------------------------------------------

show_result() {

    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Hysteria 2 安装成功！${RESET}"
    echo "============================================================"
    echo
    echo -e "${CYAN}服务器：${RESET} ${DOMAIN}"
    echo -e "${CYAN}端口：${RESET}   ${PORT}/UDP"
    echo -e "${CYAN}密码：${RESET}   ${PASSWORD}"
    echo -e "${CYAN}SNI：${RESET}    ${DOMAIN}"
    echo
    echo "============================================================"
    echo -e "${YELLOW}【v2rayN / Hysteria2 URI】${RESET}"
    echo "============================================================"
    echo
    echo "$V2RAY_URI"
    echo
    echo "============================================================"
    echo -e "${YELLOW}【Clash Verge Rev / Mihomo 完整配置】${RESET}"
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
    echo -e "${YELLOW}以后查看节点菜单：${RESET}"
    echo "hy2"
    echo
    echo "============================================================"
    echo -e "${GREEN}服务状态：${RESET}"
    systemctl --no-pager --full status "$SERVICE" | head -n 15 || true
    echo "============================================================"
    echo
}

# ------------------------------------------------------------
# Read current node configuration
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

    [[ -n "$CURRENT_DOMAIN" ]] || die "无法从 ACME 配置读取域名。"
    [[ -n "$CURRENT_PORT" ]] || die "无法从 listen 配置读取端口。"
    [[ "$CURRENT_PORT" =~ ^[0-9]+$ ]] || die "读取到的端口格式不正确：${CURRENT_PORT}"
    [[ -n "$CURRENT_PASSWORD" ]] || die "无法从 auth.password 读取密码。"

    CURRENT_SNI="$CURRENT_DOMAIN"
    CURRENT_URI_PASSWORD="$(uri_encode "$CURRENT_PASSWORD")"
    CURRENT_YAML_PASSWORD="$(yaml_escape "$CURRENT_PASSWORD")"
    CURRENT_URI="hysteria2://${CURRENT_URI_PASSWORD}@${CURRENT_DOMAIN}:${CURRENT_PORT}/?sni=${CURRENT_SNI}#HY2-${CURRENT_DOMAIN}"
}

# ------------------------------------------------------------
# Show v2rayN Hysteria2 URI
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
    echo "------------------------------------------------------------"
    echo "复制下面链接，在 v2rayN 中导入分享链接："
    echo "------------------------------------------------------------"
    echo
    echo "$CURRENT_URI"

    pause
}

# ------------------------------------------------------------
# Show Clash Verge / Mihomo configuration
# ------------------------------------------------------------

show_clash_verge_node() {

    load_current_node

    clear || true

    echo
    echo "============================================================"
    echo -e "${GREEN}       Clash Verge Rev / Mihomo 配置${RESET}"
    echo "============================================================"
    echo
    echo "复制以下完整 YAML 到 Clash Verge 本地配置："
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
    echo "------------------------------------------------------------"
    info "PROXY 策略组仅包含 HY2 节点，默认流量固定走 HY2。"
    echo "------------------------------------------------------------"

    pause
}

# ------------------------------------------------------------
# Show service status
# ------------------------------------------------------------

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
                warn "未检测到 UDP ${CURRENT_PORT} 正在监听。"
        else
            ss -lunp | grep -i hysteria || true
        fi
    else
        warn "未安装 ss，无法查看监听端口。"
    fi

    pause
}

# ------------------------------------------------------------
# Show recent logs
# ------------------------------------------------------------

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
# Restart Hysteria service
# ------------------------------------------------------------

restart_hysteria() {

    clear || true

    echo
    info "正在重启 Hysteria 2 服务..."

    systemctl restart "$SERVICE"

    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then
        success "Hysteria 2 已重启，服务状态正常。"
    else
        error "Hysteria 2 重启失败。"
        journalctl --no-pager -n 80 -u "$SERVICE" || true
    fi

    pause
}

# ------------------------------------------------------------
# Interactive menu
# ------------------------------------------------------------

hy2_menu() {

    while true; do

        clear || true

        echo
        echo "============================================================"
        echo -e "${CYAN}             Hysteria 2 管理菜单${RESET}"
        echo "============================================================"
        echo
        echo "  1. 获取 v2rayN Hysteria2 节点"
        echo "  2. 获取 Clash Verge / Mihomo 配置"
        echo "  3. 查看 Hysteria 2 服务状态和监听端口"
        echo "  4. 查看最近 80 行服务日志"
        echo "  5. 重启 Hysteria 2 服务"
        echo "  0. 退出"
        echo
        echo "============================================================"
        echo

        read -r -p "请选择 [0-5]: " choice

        case "$choice" in
            1)
                show_v2rayn_node
                ;;
            2)
                show_clash_verge_node
                ;;
            3)
                show_hysteria_status
                ;;
            4)
                show_hysteria_logs
                ;;
            5)
                restart_hysteria
                ;;
            0)
                clear || true
                exit 0
                ;;
            *)
                warn "无效选择，请输入 0-5。"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Main installer
# ------------------------------------------------------------

main() {

    check_root
    detect_os
    check_systemd
    install_dependencies
    install_command_shortcut

    echo
    echo "============================================================"
    echo "        Hysteria 2 一键安装 / 更新"
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
    configure_firewall
    enable_bbr
    start_service
    check_listening
    generate_uri
    generate_clash
    save_node_info
    show_result
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------

case "${1:-}" in
    install|update)
        main
        ;;
    menu|"")
        check_root
        hy2_menu
        ;;
    status)
        check_root
        show_hysteria_status
        ;;
    logs)
        check_root
        show_hysteria_logs
        ;;
    v2rayn|uri)
        check_root
        show_v2rayn_node
        ;;
    clash)
        check_root
        show_clash_verge_node
        ;;
    restart)
        check_root
        restart_hysteria
        ;;
    *)
        echo "用法："
        echo "  hy2              打开管理菜单"
        echo "  hy2 install      安装或更新 Hysteria 2"
        echo "  hy2 status       查看服务状态和 UDP 监听"
        echo "  hy2 logs         查看最近日志"
        echo "  hy2 v2rayn       输出 v2rayN URI"
        echo "  hy2 clash        输出 Clash Verge / Mihomo YAML"
        echo "  hy2 restart      重启 Hysteria 2"
        exit 1
        ;;
esac
