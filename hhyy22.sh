#!/usr/bin/env bash
# ============================================================
# Hysteria 2 管理脚本 - 安全域名切换版
#
# 功能：
#   1. 安装 / 配置 Hysteria 2
#   2. 卸载 Hysteria 2
#   3. 更换域名 + 自动申请 ACME 证书
#   4. 查看 v2rayN 节点
#   5. 查看 Clash Verge / Mihomo 配置
#   6. 查看服务状态
#   7. 查看日志
#   8. 查看 ACME / 证书状态
#   9. 重启 Hysteria
#  10. 修复开机自启动
#
# 特点：
#   - 更换域名时自动备份旧配置
#   - 新域名启动失败自动恢复旧配置
#   - ACME 申请失败自动恢复旧配置
#   - 保留原端口 / 密码 / 邮箱 / 伪装网址
#   - 查看节点配置时始终读取当前 config.yaml
#   - VPS 重启后 Hysteria 自动启动
# ============================================================

set -Eeuo pipefail

# ============================================================
# 全局变量
# ============================================================

SERVICE="hysteria-server.service"
CONFIG="/etc/hysteria/config.yaml"
BACKUP_DIR="/etc/hysteria/backup"

HY2_BIN="/usr/local/bin/hysteria"
HY2_MANAGER="/usr/local/bin/hy2-manager"
HY2_CMD="/usr/local/bin/hy2"

NODE_FILE="/root/hy2-node.txt"

SYSTEMD_DROPIN="/etc/systemd/system/${SERVICE}.d/override.conf"

DOMAIN=""
PORT=""
EMAIL=""
PASSWORD=""
MASQUERADE_URL="https://www.bing.com"

# ============================================================
# 输出
# ============================================================

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
    echo -e "\033[36m$*\033[0m"
}

die() {
    red
    red "错误：$*"
    exit 1
}

pause() {
    echo
    read -rp "按回车继续..." _
}

# ============================================================
# 权限
# ============================================================

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行此脚本。"
    fi
}

# ============================================================
# 命令检测
# ============================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# 依赖
# ============================================================

install_dependencies() {

    local pm=""

    if command_exists apt-get; then
        pm="apt"
    elif command_exists dnf; then
        pm="dnf"
    elif command_exists yum; then
        pm="yum"
    else
        die "当前系统不支持。"
    fi

    blue "正在安装必要依赖..."

    if [[ "$pm" == "apt" ]]; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            openssl \
            python3 \
            dnsutils

    else

        "$pm" install -y \
            curl \
            wget \
            ca-certificates \
            openssl \
            python3 \
            bind-utils

    fi

    green "依赖检查完成。"
}

# ============================================================
# 域名验证
# ============================================================

validate_domain() {

    local d="$1"

    [[ -n "$d" ]] || return 1

    if [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        return 0
    fi

    return 1
}

# ============================================================
# 端口验证
# ============================================================

validate_port() {

    local p="$1"

    [[ "$p" =~ ^[0-9]+$ ]] || return 1

    (( p >= 1 && p <= 65535 )) || return 1

    return 0
}

# ============================================================
# 密码生成
# ============================================================

generate_password() {

    openssl rand -base64 32 \
        | tr -dc 'A-Za-z0-9' \
        | head -c 24

    echo
}

# ============================================================
# YAML 转义
# ============================================================

yaml_escape() {

    python3 - "$1" <<'PY'
import sys

s = sys.argv[1]

print(
    s.replace("\\", "\\\\")
     .replace('"', '\\"')
)
PY
}

# ============================================================
# URI 编码
# ============================================================

uri_encode() {

    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

# ============================================================
# 获取 VPS 公网 IPv4
# ============================================================

get_public_ip() {

    curl -4 -fsS \
        --max-time 8 \
        https://api.ipify.org \
        2>/dev/null || true
}

# ============================================================
# DNS 检查
# ============================================================

check_dns() {

    local domain="$1"
    local server_ip=""
    local dns_ip=""

    server_ip="$(get_public_ip)"

    if [[ -z "$server_ip" ]]; then

        yellow "无法获取 VPS 公网 IPv4。"

        return 1
    fi

    if command_exists dig; then

        dns_ip="$(
            dig +short A "$domain" 2>/dev/null \
            | grep -E '^[0-9.]+$' \
            | head -n1 \
            || true
        )"

    fi

    if [[ -z "$dns_ip" ]] && command_exists nslookup; then

        dns_ip="$(
            nslookup "$domain" 2>/dev/null \
            | awk '/^Address: / {print $2}' \
            | grep -E '^[0-9.]+$' \
            | head -n1 \
            || true
        )"

    fi

    echo
    echo "VPS 公网 IPv4 : $server_ip"
    echo "域名解析 IPv4 : ${dns_ip:-未解析}"
    echo

    if [[ -z "$dns_ip" ]]; then

        red "DNS 检查失败。"
        yellow "请把 $domain 的 A 记录指向：$server_ip"

        return 1
    fi

    if [[ "$server_ip" == "$dns_ip" ]]; then

        green "DNS 检查通过："
        green "$domain → $server_ip"

        return 0

    else

        yellow "DNS 当前解析：$domain → $dns_ip"
        yellow "VPS 公网 IP：$server_ip"
        yellow "两者不一致。"

        return 1
    fi
}

# ============================================================
# 防火墙
# ============================================================

open_firewall() {

    [[ -n "$PORT" ]] || return 0

    if command_exists ufw; then

        ufw allow "${PORT}/udp" \
            >/dev/null 2>&1 \
            || true

    fi

    if command_exists firewall-cmd; then

        firewall-cmd \
            --permanent \
            --add-port="${PORT}/udp" \
            >/dev/null 2>&1 \
            || true

        firewall-cmd \
            --reload \
            >/dev/null 2>&1 \
            || true

    fi
}

# ============================================================
# systemd
# ============================================================

setup_systemd() {

    mkdir -p "$(dirname "$SYSTEMD_DROPIN")"

    cat > "$SYSTEMD_DROPIN" <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=0
EOF

    systemctl daemon-reload

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1 \
        || true
}

# ============================================================
# 安装 Hysteria
# ============================================================

install_hysteria() {

    blue "正在安装 / 更新 Hysteria 2..."

    HYSTERIA_USER=root \
        bash <(
            curl -fsSL https://get.hy2.sh/
        )

    if [[ ! -x "$HY2_BIN" ]]; then

        die "Hysteria 安装失败。"

    fi

    green "Hysteria 2 安装完成。"
}

# ============================================================
# 写入 Hysteria 配置
# ============================================================

write_config() {

    local yaml_password
    local yaml_domain
    local yaml_email
    local yaml_url

    yaml_password="$(yaml_escape "$PASSWORD")"
    yaml_domain="$(yaml_escape "$DOMAIN")"
    yaml_email="$(yaml_escape "$EMAIL")"
    yaml_url="$(yaml_escape "$MASQUERADE_URL")"

    mkdir -p /etc/hysteria
    mkdir -p "$BACKUP_DIR"

    cat > "$CONFIG" <<EOF
listen: :${PORT}

acme:
  domains:
    - ${yaml_domain}
  email: ${yaml_email}

auth:
  type: password
  password: "${yaml_password}"

masquerade:
  type: proxy
  proxy:
    url: ${yaml_url}
    rewriteHost: true

disableUDP: false
udpIdleTimeout: 60s
EOF
}

# ============================================================
# 从 config.yaml 读取当前配置
# ============================================================

load_current_config() {

    [[ -f "$CONFIG" ]] || return 1

    DOMAIN="$(
        sed -nE \
        's/^[[:space:]]*-[[:space:]]*(.+)[[:space:]]*$/\1/p' \
        "$CONFIG" \
        | head -n1 \
        || true
    )"

    DOMAIN="${DOMAIN//\"/}"
    DOMAIN="${DOMAIN//\'/}"

    PORT="$(
        sed -nE \
        's/^[[:space:]]*listen:[[:space:]]*:([0-9]+).*$/\1/p' \
        "$CONFIG" \
        | head -n1 \
        || true
    )"

    EMAIL="$(
        sed -nE \
        's/^[[:space:]]*email:[[:space:]]*(.+)$/\1/p' \
        "$CONFIG" \
        | head -n1 \
        || true
    )"

    EMAIL="${EMAIL//\"/}"
    EMAIL="${EMAIL//\'/}"

    PASSWORD="$(
        sed -nE \
        's/^[[:space:]]*password:[[:space:]]*"?(.*)"?$/\1/p' \
        "$CONFIG" \
        | head -n1 \
        || true
    )"

    PASSWORD="${PASSWORD%\"}"
    PASSWORD="${PASSWORD#\"}"

    local url=""

    url="$(
        sed -nE \
        's/^[[:space:]]*url:[[:space:]]*(.+)$/\1/p' \
        "$CONFIG" \
        | head -n1 \
        || true
    )"

    if [[ -n "$url" ]]; then

        MASQUERADE_URL="${url//\"/}"
        MASQUERADE_URL="${MASQUERADE_URL//\'/}"

    fi

    [[ -n "$DOMAIN" ]] || return 1
    [[ -n "$PORT" ]] || return 1
    [[ -n "$PASSWORD" ]] || return 1

    return 0
}

# ============================================================
# 生成 v2rayN URI
# ============================================================

generate_uri() {

    local encoded_password

    encoded_password="$(uri_encode "$PASSWORD")"

    echo \
"hysteria2://${encoded_password}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#HY2-${DOMAIN}"
}

# ============================================================
# 生成 Clash Verge / Mihomo
# ============================================================

generate_clash_yaml() {

    cat <<EOF
- name: HY2-${DOMAIN}
  type: hysteria2
  server: ${DOMAIN}
  port: ${PORT}
  password: "${PASSWORD}"
  sni: ${DOMAIN}
  skip-cert-verify: false
  alpn:
    - h3
EOF
}

# ============================================================
# 保存节点信息
# ============================================================

save_node_info() {

    local uri

    uri="$(generate_uri)"

    cat > "$NODE_FILE" <<EOF
============================================================
Hysteria 2 节点信息
============================================================

域名：
${DOMAIN}

端口：
${PORT}

密码：
${PASSWORD}

v2rayN URI：
${uri}

Clash Verge / Mihomo：

$(generate_clash_yaml)

============================================================
EOF

    chmod 600 "$NODE_FILE"
}

# ============================================================
# 等待服务启动
# ============================================================

wait_service_active() {

    local timeout="${1:-30}"
    local i=0

    while (( i < timeout )); do

        if systemctl is-active --quiet "$SERVICE"; then
            return 0
        fi

        sleep 1

        ((i++)) || true

    done

    return 1
}

# ============================================================
# 检查 ACME 日志
#
# 返回：
#   0 = 找到成功迹象
#   1 = 找到失败迹象
#   2 = 暂时没有明确结果
# ============================================================

check_acme_result() {

    local logs=""

    logs="$(
        journalctl \
            -u "$SERVICE" \
            --no-pager \
            -n 150 \
            2>/dev/null \
            || true
    )"

    if echo "$logs" | grep -Eiq \
        'certificate.*(obtained|issued|success)|\
certificate.*successfully|\
successfully.*certificate|\
certificate.*stored|\
acme.*success|\
acme.*certificate.*success|\
renew.*success'; then

        return 0
    fi

    if echo "$logs" | grep -Eiq \
        'acme.*(error|failed|failure)|\
certificate.*(error|failed|failure)|\
failed.*certificate|\
unable.*certificate|\
challenge.*failed|\
http-01.*failed|\
tls-alpn-01.*failed|\
rate limit'; then

        return 1
    fi

    return 2
}

# ============================================================
# 等待 ACME 结果
# ============================================================

wait_for_acme() {

    local max_wait=90
    local elapsed=0
    local result=2

    blue "正在等待 ACME 证书申请结果..."
    echo

    while (( elapsed < max_wait )); do

        if ! systemctl is-active --quiet "$SERVICE"; then
            return 1
        fi

        check_acme_result
        result=$?

        if [[ "$result" -eq 0 ]]; then

            green "检测到 ACME 证书申请成功。"
            return 0

        elif [[ "$result" -eq 1 ]]; then

            red "检测到 ACME 证书申请失败。"
            return 1

        fi

        echo -ne "\r等待 ACME：${elapsed}/${max_wait} 秒"

        sleep 3

        elapsed=$((elapsed + 3))

    done

    echo

    yellow "暂时没有从日志检测到明确的 ACME 成功/失败结果。"

    return 2
}

# ============================================================
# 显示 ACME 日志
# ============================================================

show_acme_status() {

    echo
    green "================ ACME / 证书状态 ================"
    echo

    if ! systemctl is-active --quiet "$SERVICE"; then

        red "Hysteria 当前没有运行。"

        echo

        systemctl status "$SERVICE" \
            --no-pager \
            -l \
            || true

        return
    fi

    if load_current_config; then

        echo "当前域名：$DOMAIN"
        echo "ACME 邮箱：$EMAIL"

    fi

    echo
    echo "最近 ACME / TLS 日志："
    echo "--------------------------------------------------"

    journalctl \
        -u "$SERVICE" \
        --no-pager \
        -n 150 \
        2>/dev/null \
        | grep -Ei \
        'acme|certificate|cert|tls|obtain|renew|issued|challenge' \
        | tail -n 50 \
        || true

    echo "--------------------------------------------------"

    echo
    yellow "如果是刚刚更换域名，请给 ACME 一些时间完成申请。"
}

# ============================================================
# v2rayN
# ============================================================

show_v2rayn_node() {

    if ! load_current_config; then

        red "当前没有有效的 Hysteria 配置。"

        return 1
    fi

    echo
    green "================ v2rayN 节点 ================"
    echo
    echo "当前域名：$DOMAIN"
    echo "当前端口：$PORT"
    echo
    echo "v2rayN URI："
    echo
    generate_uri
    echo
    green "=============================================="
    echo
}

# ============================================================
# Clash Verge / Mihomo
# ============================================================

show_clash_verge_node() {

    if ! load_current_config; then

        red "当前没有有效的 Hysteria 配置。"

        return 1
    fi

    echo
    green "============= Clash Verge / Mihomo ============="
    echo
    echo "当前域名：$DOMAIN"
    echo
    generate_clash_yaml
    echo
    green "================================================="
    echo
}

# ============================================================
# 服务状态
# ============================================================

show_status() {

    echo
    green "================ Hysteria 状态 ================"
    echo

    systemctl status "$SERVICE" \
        --no-pager \
        -l \
        || true

    echo

    if load_current_config 2>/dev/null; then

        echo "当前域名：$DOMAIN"
        echo "当前端口：$PORT"

        echo

        if command_exists ss; then

            echo "UDP 监听："

            ss -lunp \
                | grep ":${PORT}" \
                || true

        fi

    fi

    echo
    echo "开机启动："

    if systemctl is-enabled "$SERVICE" \
        >/dev/null 2>&1; then

        green "已启用开机自动启动。"

    else

        red "未启用开机自动启动。"

    fi

    echo

    if systemctl is-active "$SERVICE" \
        >/dev/null 2>&1; then

        green "服务状态：运行中"

    else

        red "服务状态：未运行"

    fi
}

# ============================================================
# 日志
# ============================================================

show_logs() {

    echo
    green "================ Hysteria 日志 ================"
    echo

    journalctl \
        -u "$SERVICE" \
        -n 150 \
        --no-pager \
        || true
}

# ============================================================
# 重启
# ============================================================

restart_service() {

    systemctl daemon-reload

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1 \
        || true

    systemctl restart "$SERVICE"

    if wait_service_active 30; then

        green "Hysteria 重启成功。"

        return 0

    fi

    red "Hysteria 重启失败。"

    systemctl status "$SERVICE" \
        --no-pager \
        -l \
        || true

    return 1
}

# ============================================================
# 安全更换域名
# ============================================================

change_domain() {

    require_root

    if ! load_current_config; then

        red "没有检测到现有 Hysteria 配置。"

        yellow "请先执行安装 / 配置。"

        return 1
    fi

    local old_domain="$DOMAIN"
    local old_port="$PORT"
    local old_email="$EMAIL"
    local old_password="$PASSWORD"
    local old_masquerade="$MASQUERADE_URL"

    local new_domain=""
    local backup_file=""

    echo
    green "=================================================="
    green "                更换 Hysteria 域名"
    green "=================================================="
    echo

    echo "当前域名：$old_domain"
    echo "当前端口：$old_port"
    echo

    read -rp "请输入新的域名： " new_domain

    validate_domain "$new_domain" || {

        red "域名格式不正确。"

        return 1
    }

    if [[ "$new_domain" == "$old_domain" ]]; then

        yellow "新域名和当前域名相同。"

        return 0
    fi

    echo
    yellow "新域名：$new_domain"
    echo

    yellow "第一步：检查 DNS..."

    if ! check_dns "$new_domain"; then

        echo
        red "DNS 检查没有通过。"

        echo
        echo "如果你刚刚修改 DNS，可能还没有生效。"
        echo

        read -rp \
            "仍然继续尝试申请证书吗？[y/N]： " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then

            yellow "已取消域名更换。"

            return 0
        fi
    fi

    # --------------------------------------------------------
    # 备份
    # --------------------------------------------------------

    mkdir -p "$BACKUP_DIR"

    backup_file="$BACKUP_DIR/config-before-domain-change-$(date +%Y%m%d-%H%M%S).yaml"

    cp "$CONFIG" "$backup_file"

    green "旧配置已备份："
    echo "$backup_file"

    # --------------------------------------------------------
    # 保存旧参数
    # --------------------------------------------------------

    DOMAIN="$new_domain"
    PORT="$old_port"
    EMAIL="$old_email"
    PASSWORD="$old_password"
    MASQUERADE_URL="$old_masquerade"

    # --------------------------------------------------------
    # 写入新域名
    # --------------------------------------------------------

    write_config

    open_firewall
    setup_systemd

    echo
    blue "第二步：写入新域名配置..."
    echo "新域名：$DOMAIN"
    echo

    # --------------------------------------------------------
    # 重启
    # --------------------------------------------------------

    blue "第三步：重启 Hysteria..."
    echo

    systemctl restart "$SERVICE"

    # --------------------------------------------------------
    # 等待服务
    # --------------------------------------------------------

    if ! wait_service_active 30; then

        red "Hysteria 使用新域名启动失败。"

        echo
        red "正在自动恢复旧配置..."

        cp "$backup_file" "$CONFIG"

        systemctl daemon-reload

        systemctl restart "$SERVICE" \
            || true

        echo
        red "域名更换失败。"
        green "旧域名已恢复：$old_domain"

        return 1
    fi

    green "Hysteria 服务已经正常运行。"

    # --------------------------------------------------------
    # ACME 检测
    # --------------------------------------------------------

    echo
    blue "第四步：等待新域名 ACME 证书..."

    set +e
    wait_for_acme
    acme_result=$?
    set -e

    # --------------------------------------------------------
    # ACME 明确失败
    # --------------------------------------------------------

    if [[ "$acme_result" -eq 1 ]]; then

        echo
        red "新域名证书申请失败。"

        echo
        red "正在恢复旧域名..."

        cp "$backup_file" "$CONFIG"

        systemctl daemon-reload

        systemctl restart "$SERVICE" \
            || true

        sleep 3

        if systemctl is-active --quiet "$SERVICE"; then

            green "旧配置恢复成功。"
            green "当前域名：$old_domain"

        else

            red "旧配置已写回，但服务未能正常启动。"
            red "请使用：$0 logs 查看日志。"

        fi

        return 1
    fi

    # --------------------------------------------------------
    # ACME 超时
    #
    # 这里不直接恢复。
    #
    # 因为 ACME 有时候需要更长时间完成。
    # 如果 Hysteria 本身已经正常运行，则保留新配置。
    # 用户可以通过菜单 8 查看详细 ACME 日志。
    # --------------------------------------------------------

    if [[ "$acme_result" -eq 2 ]]; then

        yellow "没有在规定时间内检测到明确的 ACME 结果。"

        yellow "但 Hysteria 当前正在正常运行。"

        yellow "暂时保留新域名配置。"

        yellow "请使用菜单 8 查看 ACME / 证书状态。"

    fi

    # --------------------------------------------------------
    # 新配置成功
    # --------------------------------------------------------

    DOMAIN="$new_domain"
    PORT="$old_port"
    EMAIL="$old_email"
    PASSWORD="$old_password"
    MASQUERADE_URL="$old_masquerade"

    save_node_info

    echo
    green "=================================================="
    green "              域名更换完成"
    green "=================================================="
    echo

    echo "旧域名：$old_domain"
    echo "新域名：$DOMAIN"
    echo "端口：$PORT"
    echo "密码：保持不变"
    echo "伪装网址：$MASQUERADE_URL"

    echo
    green "Hysteria 已经使用新域名配置。"

    echo
    echo "新的 v2rayN 节点："
    echo
    generate_uri

    echo
    echo "新的 Clash Verge / Mihomo 配置："
    echo
    generate_clash_yaml

    echo
    green "以后从菜单查看配置时，会自动显示当前新域名。"

    echo
    yellow "节点配置文件：$NODE_FILE"

    echo
}

# ============================================================
# 安装 / 初始配置
# ============================================================

install_or_configure() {

    require_root

    install_dependencies

    install_hysteria

    echo
    green "=================================================="
    green "              Hysteria 2 初始配置"
    green "=================================================="
    echo

    read -rp \
        "请输入域名，例如 hy.example.com： " \
        DOMAIN

    validate_domain "$DOMAIN" || {

        red "域名格式不正确。"

        return 1
    }

    echo

    read -rp \
        "请输入监听 UDP 端口 [443]： " \
        PORT

    PORT="${PORT:-443}"

    validate_port "$PORT" || {

        red "端口不正确。"

        return 1
    }

    echo

    read -rp \
        "请输入 ACME 邮箱： " \
        EMAIL

    [[ -n "$EMAIL" ]] || {

        red "邮箱不能为空。"

        return 1
    }

    echo

    read -rp \
        "伪装网址 [https://www.bing.com]： " \
        MASQUERADE_URL

    MASQUERADE_URL="${MASQUERADE_URL:-https://www.bing.com}"

    PASSWORD="$(generate_password)"

    echo
    yellow "正在检查 DNS..."

    check_dns "$DOMAIN" || {

        echo
        yellow "DNS 检查没有通过。"

        read -rp \
            "仍然继续安装吗？[y/N]： " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then

            yellow "安装已取消。"

            return 0
        fi
    }

    # --------------------------------------------------------
    # 备份旧配置
    # --------------------------------------------------------

    if [[ -f "$CONFIG" ]]; then

        mkdir -p "$BACKUP_DIR"

        cp "$CONFIG" \
            "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).yaml"

    fi

    # --------------------------------------------------------
    # 写配置
    # --------------------------------------------------------

    write_config

    open_firewall
    setup_systemd

    # --------------------------------------------------------
    # 启动
    # --------------------------------------------------------

    echo
    blue "正在启动 Hysteria..."

    systemctl restart "$SERVICE"

    if ! wait_service_active 30; then

        red "Hysteria 启动失败。"

        systemctl status "$SERVICE" \
            --no-pager \
            -l \
            || true

        echo
        echo "最近日志："

        journalctl \
            -u "$SERVICE" \
            -n 80 \
            --no-pager \
            || true

        return 1
    fi

    green "Hysteria 服务启动成功。"

    save_node_info

    echo
    green "=================================================="
    green "              Hysteria 2 安装完成"
    green "=================================================="
    echo

    echo "域名：$DOMAIN"
    echo "端口：$PORT"
    echo "密码：$PASSWORD"

    echo
    echo "v2rayN URI："
    echo
    generate_uri

    echo
    yellow "ACME 证书由 Hysteria 自动申请 / 续期。"

    echo
    yellow "请确认："
    echo "1. 域名 A 记录已经指向 VPS"
    echo "2. UDP ${PORT} 已放行"
    echo "3. 如果使用 Cloudflare，请确认相关 DNS / 代理设置符合证书验证要求"

    echo
}

# ============================================================
# 卸载
# ============================================================

uninstall_hysteria() {

    require_root

    echo
    red "即将卸载 Hysteria 2。"
    echo

    read -rp \
        "确定继续吗？[y/N]： " \
        answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then

        yellow "已取消。"

        return 0
    fi

    systemctl disable --now "$SERVICE" \
        >/dev/null 2>&1 \
        || true

    rm -f "$SYSTEMD_DROPIN"

    rm -f "$CONFIG"

    rm -f "$HY2_BIN"

    rm -f "$HY2_CMD"

    systemctl daemon-reload

    rm -rf /etc/hysteria

    green "Hysteria 2 已卸载。"
}

# ============================================================
# 修复开机自动启动
# ============================================================

repair_autostart() {

    require_root

    if [[ ! -f "$CONFIG" ]]; then

        red "没有找到 Hysteria 配置：$CONFIG"

        return 1
    fi

    setup_systemd

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1 \
        || true

    systemctl daemon-reload

    green "开机自动启动已经修复。"

    echo

    systemctl is-enabled "$SERVICE" \
        || true

    echo

    green "当前 systemd 状态："

    systemctl status "$SERVICE" \
        --no-pager \
        -l \
        || true
}

# ============================================================
# 创建 hy2 快捷命令
# ============================================================

create_shortcut() {

    cat > "$HY2_CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/hy2-manager "$@"
EOF

    chmod +x "$HY2_CMD"
}

# ============================================================
# 安装管理器本身
# ============================================================

install_manager_command() {

    local current_script=""

    current_script="$(readlink -f "$0")"

    if [[ "$current_script" != "$HY2_MANAGER" ]]; then

        cp "$current_script" "$HY2_MANAGER"

        chmod +x "$HY2_MANAGER"

    fi

    create_shortcut
}

# ============================================================
# 菜单
# ============================================================

menu() {

    while true; do

        clear

        echo
        green "=================================================="
        green "              Hysteria 2 管理脚本"
        green "=================================================="
        echo

        if load_current_config 2>/dev/null; then

            echo "当前域名：$DOMAIN"
            echo "当前端口：$PORT"

            if systemctl is-active --quiet "$SERVICE"; then

                green "服务状态：运行中"

            else

                red "服务状态：未运行"

            fi

        else

            yellow "当前：尚未安装 / 未配置"

        fi

        echo
        echo "  1. 安装 / 配置 Hysteria 2"
        echo "  2. 卸载 Hysteria 2"
        echo "  3. 更换域名并自动申请新证书"
        echo "  4. 查看 v2rayN 节点"
        echo "  5. 查看 Clash Verge / Mihomo 配置"
        echo "  6. 查看服务状态"
        echo "  7. 查看 Hysteria 日志"
        echo "  8. 查看 ACME / 证书状态"
        echo "  9. 重启 Hysteria"
        echo " 10. 修复开机自动启动"
        echo "  0. 退出"

        echo
        echo "--------------------------------------------------"

        read -rp \
            "请选择 [0-10]： " \
            choice

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
                pause
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

# ============================================================
# CLI
# ============================================================

main() {

    require_root

    case "${1:-menu}" in

        install)
            install_or_configure
            ;;

        update)
            install_or_configure
            ;;

        uninstall)
            uninstall_hysteria
            ;;

        domain|changedomain)
            change_domain
            ;;

        v2rayn|uri)
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

        acme|cert|certificate)
            show_acme_status
            ;;

        restart)
            restart_service
            ;;

        repair|autostart)
            repair_autostart
            ;;

        menu)
            menu
            ;;

        *)
            echo
            echo "Hysteria 2 管理脚本"
            echo
            echo "用法："
            echo
            echo "  $0 install       安装 / 配置"
            echo "  $0 uninstall    卸载"
            echo "  $0 domain       更换域名"
            echo "  $0 v2rayn       查看 v2rayN"
            echo "  $0 clash        查看 Clash"
            echo "  $0 status       查看状态"
            echo "  $0 logs         查看日志"
            echo "  $0 acme         查看证书"
            echo "  $0 restart      重启"
            echo "  $0 repair       修复开机启动"
            echo "  $0 menu         打开菜单"
            echo

    esac
}

# ============================================================
# 启动
# ============================================================
install_manager_command
main "$@"
