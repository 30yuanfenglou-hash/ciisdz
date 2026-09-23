#!/usr/bin/env bash

set -Eeuo pipefail

SERVICE="hysteria-server.service"
CONFIG="/etc/hysteria/config.yaml"
BACKUP_DIR="/etc/hysteria/backup"

HY2_BIN="/usr/local/bin/hysteria"
HY2_MANAGER="/usr/local/bin/hy2-manager"
HY2_CMD="/usr/local/bin/hy2"
NODE_FILE="/root/hy2-node.txt"

SYSTEMD_DROPIN="/etc/systemd/system/${SERVICE}.d/override.conf"

SCRIPT_URL="https://raw.githubusercontent.com/30yuanfenglou-hash/ciisdz/main/hhyy22.sh"

DOMAIN=""
PORT=""
EMAIL=""
PASSWORD=""
MASQUERADE_URL=""

red() {
    echo -e "\033[31m$*\033[0m"
}

green() {
    echo -e "\033[32m$*\033[0m"
}

yellow() {
    echo -e "\033[33m$*\033[0m"
}

blue() {
    echo -e "\033[34m$*\033[0m"
}

die() {
    red "错误：$*"
    exit 1
}

pause() {
    read -rp "按回车继续..." _
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 权限运行此脚本。"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_dependencies() {

    local packages=(
        curl
        wget
        ca-certificates
        openssl
        python3
    )

    if command_exists apt-get; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            openssl \
            python3 \
            dnsutils

    elif command_exists dnf; then

        dnf install -y \
            curl \
            wget \
            ca-certificates \
            openssl \
            python3 \
            bind-utils

    elif command_exists yum; then

        yum install -y \
            curl \
            wget \
            ca-certificates \
            openssl \
            python3 \
            bind-utils

    else
        yellow "未识别到 apt/dnf/yum，请确保 curl、wget、openssl、python3 和 DNS 工具已经安装。"
    fi
}

validate_domain() {

    local domain="$1"

    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        return 1
    fi

    if [[ "$domain" != *.* ]]; then
        return 1
    fi

    return 0
}

validate_port() {

    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        return 1
    fi

    return 0
}

generate_password() {

    openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24

    echo
}

yaml_escape() {

    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '%s' "$value"
}

uri_encode() {

    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=''))
PY
}

get_public_ip() {

    local ip=""

    ip="$(curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsSL --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    fi

    printf '%s' "$ip"
}

check_dns() {

    local domain="$1"
    local public_ip=""
    local resolved=""

    public_ip="$(get_public_ip || true)"

    echo
    blue "正在检查 DNS：$domain"

    if command_exists dig; then

        resolved="$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"

    elif command_exists nslookup; then

        resolved="$(nslookup "$domain" 2>/dev/null \
            | awk '/^Address: / {print $2}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | head -n 1 || true)"

    else

        yellow "系统没有 dig/nslookup，跳过 DNS 解析检查。"
        return 0

    fi

    if [[ -z "$resolved" ]]; then

        red "域名 $domain 没有解析到 IPv4 地址。"
        return 1

    fi

    echo "域名解析：$resolved"

    if [[ -n "$public_ip" ]]; then

        echo "服务器公网 IP：$public_ip"

        if [[ "$resolved" == "$public_ip" ]]; then

            green "DNS 检查通过。"

        else

            yellow "警告：域名解析 IP 与当前服务器公网 IP 不一致。"
            yellow "如果你使用了 CDN、代理或其他 DNS 架构，这是可能正常的。"

        fi

    else

        yellow "无法获取服务器公网 IP，跳过 IP 对比。"

    fi

    return 0
}

open_firewall() {

    local port="$1"

    if command_exists ufw; then

        ufw allow "${port}/udp" >/dev/null 2>&1 || true

    elif command_exists firewall-cmd; then

        firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true

    fi
}

setup_systemd() {

    mkdir -p "$(dirname "$SYSTEMD_DROPIN")"

    cat > "$SYSTEMD_DROPIN" <<EOF
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=0
EOF

    systemctl daemon-reload

    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

install_hysteria() {

    if [[ -x "$HY2_BIN" ]]; then
        return 0
    fi

    blue "正在安装 Hysteria 2..."

    HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)

    if [[ ! -x "$HY2_BIN" ]]; then
        die "Hysteria 2 安装失败。"
    fi

    green "Hysteria 2 安装完成。"
}

write_config() {

    local escaped_domain
    local escaped_email
    local escaped_password
    local escaped_masquerade

    escaped_domain="$(yaml_escape "$DOMAIN")"
    escaped_email="$(yaml_escape "$EMAIL")"
    escaped_password="$(yaml_escape "$PASSWORD")"
    escaped_masquerade="$(yaml_escape "$MASQUERADE_URL")"

    mkdir -p /etc/hysteria

    cat > "$CONFIG" <<EOF
listen: :${PORT}

acme:
  domains:
    - ${escaped_domain}
  email: ${escaped_email}

auth:
  type: password
  password: "${escaped_password}"

masquerade:
  type: proxy
  proxy:
    url: ${escaped_masquerade}
    rewriteHost: true

disableUDP: false
udpIdleTimeout: 60s
EOF
}

load_current_config() {

    [[ -f "$CONFIG" ]] || return 1

    DOMAIN="$(
        sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)$/\1/p' "$CONFIG" \
        | head -n 1 \
        | sed 's/^"//;s/"$//'
    )"

    PORT="$(
        sed -n 's/^[[:space:]]*listen:[[:space:]]*:\([0-9]\+\).*$/\1/p' "$CONFIG" \
        | head -n 1
    )"

    EMAIL="$(
        sed -n 's/^[[:space:]]*email:[[:space:]]*\(.*\)$/\1/p' "$CONFIG" \
        | head -n 1 \
        | sed 's/^"//;s/"$//'
    )"

    PASSWORD="$(
        sed -n 's/^[[:space:]]*password:[[:space:]]*"\(.*\)"$/\1/p' "$CONFIG" \
        | head -n 1
    )"

    MASQUERADE_URL="$(
        sed -n 's/^[[:space:]]*url:[[:space:]]*\(.*\)$/\1/p' "$CONFIG" \
        | head -n 1 \
        | sed 's/^"//;s/"$//'
    )"

    [[ -n "$DOMAIN" ]] || return 1
    [[ -n "$PORT" ]] || return 1
    [[ -n "$EMAIL" ]] || return 1
    [[ -n "$PASSWORD" ]] || return 1

    return 0
}

generate_uri() {

    local encoded_password
    local encoded_domain

    encoded_password="$(uri_encode "$PASSWORD")"
    encoded_domain="$(uri_encode "$DOMAIN")"

    echo "hysteria2://${encoded_password}@${DOMAIN}:${PORT}/?sni=${encoded_domain}#HY2-${DOMAIN}"
}

generate_clash_yaml() {

    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: "HY2-${DOMAIN}"
    type: hysteria2
    server: ${DOMAIN}
    port: ${PORT}
    password: "${PASSWORD}"
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
}

save_node_info() {

    local uri=""

    uri="$(generate_uri)"

    cat > "$NODE_FILE" <<EOF
Hysteria 2 节点信息
====================

域名:
${DOMAIN}

端口:
${PORT}

密码:
${PASSWORD}

SNI:
${DOMAIN}

v2rayN:
${uri}

Clash Verge / Mihomo:
--------------------
$(generate_clash_yaml)
EOF

    chmod 600 "$NODE_FILE"
}

wait_service_active() {

    local timeout="${1:-30}"
    local i

    for ((i = 1; i <= timeout; i++)); do

        if systemctl is-active --quiet "$SERVICE"; then
            return 0
        fi

        sleep 1

    done

    return 1
}

check_acme_result() {

    local logs=""

    logs="$(journalctl -u "$SERVICE" -n 100 --no-pager 2>/dev/null || true)"

    if echo "$logs" | grep -qiE \
        'certificate|acme|renew|obtained|success|issued'; then
        return 0
    fi

    return 1
}

wait_for_acme() {

    local timeout="${1:-60}"
    local i

    for ((i = 1; i <= timeout; i++)); do

        if check_acme_result; then
            return 0
        fi

        sleep 1

    done

    return 1
}

show_acme_status() {

    echo
    blue "========== ACME / 证书状态 =========="
    echo

    if ! systemctl is-active --quiet "$SERVICE"; then
        yellow "Hysteria 服务当前没有运行。"
    fi

    echo "服务："
    systemctl status "$SERVICE" --no-pager -l || true

    echo
    echo "最近 ACME 日志："

    journalctl -u "$SERVICE" \
        --no-pager \
        -n 100 \
        | grep -iE 'acme|certificate|cert|renew|tls' \
        || true

    echo
}

show_v2rayn_node() {

    if ! load_current_config; then
        red "没有找到有效的 Hysteria 2 配置。"
        return 1
    fi

    echo
    blue "========== v2rayN 节点 =========="
    echo
    generate_uri
    echo
}

show_clash_verge_node() {

    if ! load_current_config; then
        red "没有找到有效的 Hysteria 2 配置。"
        return 1
    fi

    echo
    blue "========== Clash Verge / Mihomo =========="
    echo

    generate_clash_yaml

    echo
}

show_status() {

    echo
    blue "========== Hysteria 2 服务状态 =========="
    echo

    systemctl status "$SERVICE" --no-pager -l || true

    echo

    if [[ -f "$CONFIG" ]]; then
        echo "配置文件：$CONFIG"
    else
        yellow "配置文件不存在。"
    fi

    if [[ -x "$HY2_BIN" ]]; then
        echo
        echo "Hysteria 版本："
        "$HY2_BIN" version 2>/dev/null || "$HY2_BIN" -v 2>/dev/null || true
    fi

    echo
}

show_logs() {

    echo
    blue "========== Hysteria 2 日志 =========="
    echo

    journalctl -u "$SERVICE" \
        --no-pager \
        -n 100 \
        -f
}

restart_service() {

    systemctl restart "$SERVICE"

    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then
        green "Hysteria 2 重启成功。"
    else
        red "Hysteria 2 重启失败。"
        systemctl status "$SERVICE" --no-pager -l || true
        return 1
    fi
}

change_domain() {

    require_root

    if ! load_current_config; then
        die "当前没有有效的 Hysteria 2 配置。"
    fi

    local old_domain="$DOMAIN"
    local old_config="$CONFIG"
    local backup_file=""

    local new_domain=""
    local new_email=""
    local new_port=""
    local new_masquerade=""

    echo
    blue "========== 更换域名 =========="
    echo
    echo "当前域名：$old_domain"
    echo

    read -rp "请输入新域名： " new_domain

    if ! validate_domain "$new_domain"; then
        die "域名格式不正确。"
    fi

    read -rp "端口 [${PORT}]： " new_port
    new_port="${new_port:-$PORT}"

    if ! validate_port "$new_port"; then
        die "端口不正确。"
    fi

    read -rp "邮箱 [${EMAIL}]： " new_email
    new_email="${new_email:-$EMAIL}"

    read -rp "伪装网站 [${MASQUERADE_URL}]： " new_masquerade
    new_masquerade="${new_masquerade:-$MASQUERADE_URL}"

    mkdir -p "$BACKUP_DIR"

    backup_file="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).yaml"

    cp -a "$old_config" "$backup_file"

    if ! check_dns "$new_domain"; then
        yellow "DNS 检查未通过。"
        read -rp "仍然继续吗？[y/N]: " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    DOMAIN="$new_domain"
    PORT="$new_port"
    EMAIL="$new_email"
    MASQUERADE_URL="$new_masquerade"

    write_config

    open_firewall "$PORT"
    setup_systemd

    systemctl restart "$SERVICE"

    if ! wait_service_active 30; then

        red "Hysteria 服务启动失败，正在恢复旧配置。"

        cp -a "$backup_file" "$CONFIG"

        systemctl restart "$SERVICE"

        return 1
    fi

    if ! wait_for_acme 60; then

        yellow "暂未检测到明确的 ACME 成功日志。"
        yellow "保留新配置，请使用菜单 8 检查证书状态。"

    else

        green "ACME 证书处理成功。"

    fi

    save_node_info

    echo
    green "域名更换完成。"
    echo
}

install_or_configure() {

    require_root

    install_dependencies
    install_hysteria

    echo
    blue "========== 安装 / 配置 Hysteria 2 =========="
    echo

    while true; do

        read -rp "请输入域名： " DOMAIN

        if validate_domain "$DOMAIN"; then
            break
        fi

        red "域名格式不正确，请重新输入。"
    done

    while true; do

        read -rp "请输入端口 [443]： " PORT
        PORT="${PORT:-443}"

        if validate_port "$PORT"; then
            break
        fi

        red "端口不正确，请重新输入。"
    done

    read -rp "请输入 ACME 邮箱： " EMAIL

    if [[ -z "$EMAIL" ]]; then
        die "邮箱不能为空。"
    fi

    read -rp "伪装网站 [https://www.bing.com]： " MASQUERADE_URL
    MASQUERADE_URL="${MASQUERADE_URL:-https://www.bing.com}"

    PASSWORD="$(generate_password)"

    echo
    echo "正在检查 DNS..."
    check_dns "$DOMAIN" || true

    mkdir -p "$BACKUP_DIR"

    if [[ -f "$CONFIG" ]]; then

        cp -a "$CONFIG" \
            "${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).yaml"

    fi

    write_config

    open_firewall "$PORT"

    setup_systemd

    systemctl restart "$SERVICE"

    if ! wait_service_active 30; then

        red "Hysteria 2 启动失败。"
        systemctl status "$SERVICE" --no-pager -l || true

        return 1
    fi

    green "Hysteria 2 服务已启动。"

    echo
    yellow "正在等待 ACME 证书申请..."

    if wait_for_acme 60; then
        green "ACME 证书申请成功。"
    else
        yellow "暂未检测到明确的 ACME 成功日志。"
        yellow "可以稍后使用菜单 8 查看 ACME / 证书状态。"
    fi

    save_node_info

    echo
    green "========== 安装 / 配置完成 =========="
    echo

    echo "v2rayN 节点："
    generate_uri

    echo
    echo "Clash Verge / Mihomo："
    generate_clash_yaml

    echo
    echo "节点信息已保存到："
    echo "$NODE_FILE"

    echo
}

uninstall_hysteria() {

    require_root

    echo
    blue "========== 卸载 Hysteria 2 =========="
    echo

    read -rp "确定要卸载 Hysteria 2 吗？[y/N]: " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi

    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true

    rm -f "$SYSTEMD_DROPIN"

    systemctl daemon-reload

    if [[ -x "$HY2_BIN" ]]; then

        if "$HY2_BIN" service uninstall >/dev/null 2>&1; then
            :
        fi

    fi

    rm -f "$HY2_BIN"
    rm -f "$CONFIG"

    green "Hysteria 2 已卸载。"
}

repair_autostart() {

    require_root

    echo
    blue "========== 修复开机自动启动 =========="
    echo

    if [[ ! -f "$CONFIG" ]]; then
        red "配置文件不存在：$CONFIG"
        return 1
    fi

    setup_systemd

    systemctl enable "$SERVICE"

    systemctl restart "$SERVICE"

    if systemctl is-active --quiet "$SERVICE"; then
        green "开机自动启动已修复。"
        green "当前服务运行正常。"
    else
        red "服务启动失败。"
        systemctl status "$SERVICE" --no-pager -l || true
        return 1
    fi
}

create_shortcut() {

    cat > "$HY2_CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/hy2-manager "$@"
EOF

    chmod +x "$HY2_CMD"
}

install_manager_command() {

    local current_script=""
    local tmp_manager=""

    # ------------------------------------------------------------
    # 修复点：
    #
    # 使用：
    #   bash <(curl -Ls ...)
    #
    # 时，$0 可能是 /dev/fd/...，
    # readlink -f 后会变成：
    #
    #   /proc/xxxx/fd/pipe:[xxxxx]
    #
    # 这不是普通文件，不能直接 cp。
    #
    # 本地执行脚本时仍然按照原来的方式复制；
    # 在线 <(curl) 执行时，则重新从 SCRIPT_URL 下载脚本。
    # ------------------------------------------------------------

    if [[ -f "$0" ]]; then

        current_script="$(readlink -f "$0")"

        if [[ "$current_script" != "$HY2_MANAGER" ]]; then

            cp "$current_script" "$HY2_MANAGER"

            chmod +x "$HY2_MANAGER"

        fi

    else

        tmp_manager="${HY2_MANAGER}.tmp.$$"

        if ! curl -fsSL \
            --retry 3 \
            --connect-timeout 10 \
            --max-time 120 \
            "$SCRIPT_URL" \
            -o "$tmp_manager"; then

            rm -f "$tmp_manager"

            die "无法下载管理器脚本：$SCRIPT_URL"

        fi

        if [[ ! -s "$tmp_manager" ]]; then

            rm -f "$tmp_manager"

            die "下载的管理器脚本为空。"

        fi

        chmod +x "$tmp_manager"

        mv -f "$tmp_manager" "$HY2_MANAGER"

    fi

    create_shortcut
}

menu() {

    while true; do

        clear 2>/dev/null || true

        echo
        echo "=========================================="
        echo "        Hysteria 2 管理器"
        echo "=========================================="
        echo
        echo "1. 安装 / 配置 Hysteria 2"
        echo "2. 卸载 Hysteria 2"
        echo "3. 更换域名并自动申请新证书"
        echo "4. 查看 v2rayN 节点"
        echo "5. 查看 Clash Verge / Mihomo 配置"
        echo "6. 查看服务状态"
        echo "7. 查看 Hysteria 日志"
        echo "8. 查看 ACME / 证书状态"
        echo "9. 重启 Hysteria"
        echo "10. 修复开机自动启动"
        echo "0. 退出"
        echo
        echo "=========================================="
        echo

        read -rp "请选择 [0-10]: " choice

        case "$choice" in

            1)
                install_or_configure
                pause
                ;;

            2)
                uninstall_hysteria
                pause
                ;;

            3)
                change_domain
                pause
                ;;

            4)
                show_v2rayn_node
                pause
                ;;

            5)
                show_clash_verge_node
                pause
                ;;

            6)
                show_status
                pause
                ;;

            7)
                show_logs
                ;;

            8)
                show_acme_status
                pause
                ;;

            9)
                restart_service
                pause
                ;;

            10)
                repair_autostart
                pause
                ;;

            0)
                exit 0
                ;;

            *)
                red "无效选项。"
                sleep 1
                ;;

        esac

    done
}

main() {

    require_root

    local action="${1:-menu}"

    case "$action" in

        install)
            install_or_configure
            ;;

        update)
            install_or_configure
            ;;

        uninstall)
            uninstall_hysteria
            ;;

        domain)
            change_domain
            ;;

        v2rayn)
            show_v2rayn_node
            ;;

        clash)
            show_clash_verge_node
            ;;

        status)
            show_status
            ;;

        logs)
            show_logs
            ;;

        acme)
            show_acme_status
            ;;

        restart)
            restart_service
            ;;

        repair)
            repair_autostart
            ;;

        menu)
            menu
            ;;

        *)
            echo "用法："
            echo
            echo "  $0 install"
            echo "  $0 update"
            echo "  $0 uninstall"
            echo "  $0 domain"
            echo "  $0 v2rayn"
            echo "  $0 clash"
            echo "  $0 status"
            echo "  $0 logs"
            echo "  $0 acme"
            echo "  $0 restart"
            echo "  $0 repair"
            echo "  $0 menu"
            echo
            ;;

    esac
}

install_manager_command

main "$@"
