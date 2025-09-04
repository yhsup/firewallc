#!/bin/bash
# Firewall one-click config script
# Compatible with Debian/Ubuntu, CentOS/RHEL, Alpine
set -e

BACKUP_DIR="$HOME/fw_backup"
FIRST_RUN_FLAG="$HOME/.fw_first_run"
mkdir -p "$BACKUP_DIR"

# ================= 系统检测 =================
detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS="alpine"
    elif [[ -f /etc/debian_version ]]; then
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then
            OS="ubuntu"
        else
            OS="debian"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    else
        echo "未知系统，不支持！"
        exit 1
    fi
}

# ================= 依赖检测 =================
check_dependencies() {
    detect_os
    local NEED_INSTALL=()
    case "$OS" in
        ubuntu|debian)
            command -v ufw >/dev/null 2>&1 || NEED_INSTALL+=("ufw")
            command -v ss >/dev/null 2>&1 || NEED_INSTALL+=("iproute2")
            if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
                echo "⚙️ 缺少依赖: ${NEED_INSTALL[*]}, 正在安装..."
                apt update -y
                apt install -y "${NEED_INSTALL[@]}"
            fi
            ;;
        centos)
            command -v firewall-cmd >/dev/null 2>&1 || NEED_INSTALL+=("firewalld")
            command -v ss >/dev/null 2>&1 || NEED_INSTALL+=("iproute")
            if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
                echo "⚙️ 缺少依赖: ${NEED_INSTALL[*]}, 正在安装..."
                yum install -y "${NEED_INSTALL[@]}"
            fi
            ;;
        alpine)
            command -v iptables >/dev/null 2>&1 || NEED_INSTALL+=("iptables")
            command -v ss >/dev/null 2>&1 || NEED_INSTALL+=("iproute2")
            if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
                echo "⚙️ 缺少依赖: ${NEED_INSTALL[*]}, 正在安装..."
                apk add --no-cache "${NEED_INSTALL[@]}"
            fi
            ;;
    esac
}

# ================= 初始防火墙备份 =================
backup_initial_firewall() {
    detect_os
    local INITIAL_BACKUP="$BACKUP_DIR/initial_firewall_backup"
    if [ ! -f "$FIRST_RUN_FLAG" ]; then
        echo "⚠️ 检测到第一次运行防火墙脚本，是否备份当前防火墙为初始配置？(y/n)"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            mkdir -p "$BACKUP_DIR"
            case "$OS" in
                ubuntu|debian) ufw status verbose > "$INITIAL_BACKUP.txt" ;;
                centos) cp -r /etc/firewalld "$INITIAL_BACKUP" ;;
                alpine) iptables-save > "$INITIAL_BACKUP.txt" ;;
            esac
            echo "✅ 已备份当前防火墙为初始配置"
        else
            echo "❌ 未进行初始配置备份，请注意恢复功能不可用"
        fi
        touch "$FIRST_RUN_FLAG"
    fi
}

# ================= 防火墙状态 =================
show_status() {
    detect_os
    echo "===== 防火墙状态 ====="
    case "$OS" in
        ubuntu|debian) ufw status verbose ;;
        centos) firewall-cmd --list-all ;;
        alpine) iptables -L -n -v ;;
    esac
    echo "===== 开放端口 (IPv4) ====="
    ss -tuln4 2>/dev/null | awk 'NR>1{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq
    echo "===== 开放端口 (IPv6) ====="
    ss -tuln6 2>/dev/null | awk 'NR>1{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq
}

# ================= 启用/禁用防火墙 =================
enable_firewall() {
    detect_os
    case "$OS" in
        ubuntu|debian) ufw --force enable ;;
        centos) systemctl start firewalld ;;
        alpine) /etc/init.d/iptables start ;;
    esac
    echo "✅ 防火墙已启用"
    show_status
}

disable_firewall() {
    detect_os
    case "$OS" in
        ubuntu|debian) ufw --force disable ;;
        centos) systemctl stop firewalld ;;
        alpine) /etc/init.d/iptables stop ;;
    esac
    echo "⚠️ 防火墙已关闭"
}

# ================= 配置端口 =================
configure_ports() {
    detect_os
    echo "请输入 SSH 端口 (默认22):"
    read -r SSH_PORT
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    echo "请输入要开放的 TCP 端口 (空格分隔):"
    read -r TCP_PORTS
    echo "请输入要开放的 UDP 端口 (空格分隔):"
    read -r UDP_PORTS

    case "$OS" in
        ubuntu|debian)
            apt install -y ufw >/dev/null 2>&1
            ufw --force reset
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow "${SSH_PORT}/tcp"
            for port in $TCP_PORTS; do [ -n "$port" ] && ufw allow "${port}/tcp"; done
            for port in $UDP_PORTS; do [ -n "$port" ] && ufw allow "${port}/udp"; done
            ufw --force enable
            ;;
        centos)
            yum install -y firewalld >/dev/null 2>&1
            systemctl enable firewalld
            systemctl start firewalld
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
            for port in $TCP_PORTS; do [ -n "$port" ] && firewall-cmd --permanent --add-port="${port}/tcp"; done
            for port in $UDP_PORTS; do [ -n "$port" ] && firewall-cmd --permanent --add-port="${port}/udp"; done
            firewall-cmd --reload
            ;;
        alpine)
            apk add -q iptables >/dev/null 2>&1
            rc-update add iptables >/dev/null 2>&1
            iptables -F
            iptables -X
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
            for port in $TCP_PORTS; do [ -n "$port" ] && iptables -A INPUT -p tcp --dport "$port" -j ACCEPT; done
            for port in $UDP_PORTS; do [ -n "$port" ] && iptables -A INPUT -p udp --dport "$port" -j ACCEPT; done
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 防火墙配置完成"
    show_status
}

# ================= 开/关端口 =================
close_ports() {
    detect_os
    echo "请输入要关闭的端口 (空格分隔, TCP/UDP同时关闭):"
    read -r PORTS
    [ -z "$PORTS" ] && { echo "❌ 未输入端口"; return; }

    case "$OS" in
        ubuntu|debian)
            for port in $PORTS; do
                ufw delete allow "${port}/tcp" || true
                ufw delete allow "${port}/udp" || true
            done
            ;;
        centos)
            for port in $PORTS; do
                firewall-cmd --permanent --remove-port="${port}/tcp"
                firewall-cmd --permanent --remove-port="${port}/udp"
            done
            firewall-cmd --reload
            ;;
        alpine)
            for port in $PORTS; do
                iptables -D INPUT -p tcp --dport "$port" -j ACCEPT || true
                iptables -D INPUT -p udp --dport "$port" -j ACCEPT || true
            done
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 指定端口已关闭 (TCP/UDP)"
    show_status
}

open_ports() {
    detect_os
    echo "请输入要开启的端口 (空格分隔):"
    read -r PORTS
    [ -z "$PORTS" ] && { echo "❌ 未输入端口"; return; }
    echo "请选择协议类型 (tcp/udp/all):"
    read -r PROTO
    PROTO=$(echo "$PROTO" | tr '[:upper:]' '[:lower:]')

    case "$OS" in
        ubuntu|debian)
            for port in $PORTS; do
                [[ "$PROTO" == "tcp" || "$PROTO" == "all" ]] && ufw allow "${port}/tcp"
                [[ "$PROTO" == "udp" || "$PROTO" == "all" ]] && ufw allow "${port}/udp"
            done
            ;;
        centos)
            for port in $PORTS; do
                [[ "$PROTO" == "tcp" || "$PROTO" == "all" ]] && firewall-cmd --permanent --add-port="${port}/tcp"
                [[ "$PROTO" == "udp" || "$PROTO" == "all" ]] && firewall-cmd --permanent --add-port="${port}/udp"
            done
            firewall-cmd --reload
            ;;
        alpine)
            for port in $PORTS; do
                [[ "$PROTO" == "tcp" || "$PROTO" == "all" ]] && iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                [[ "$PROTO" == "udp" || "$PROTO" == "all" ]] && iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            done
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 指定端口已开启"
    show_status
}

# ================= 备份/恢复 =================
backup_firewall() {
    detect_os
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    case "$OS" in
        ubuntu|debian) ufw status verbose > "$BACKUP_DIR/ufw_backup_$TIMESTAMP.txt" ;;
        centos) cp -r /etc/firewalld "$BACKUP_DIR/firewalld_backup_$TIMESTAMP" ;;
        alpine) iptables-save > "$BACKUP_DIR/iptables_backup_$TIMESTAMP.txt" ;;
    esac
    echo "✅ 防火墙已备份到 $BACKUP_DIR"
}

restore_firewall() {
    detect_os
    echo "可用备份列表:"
    ls -1 "$BACKUP_DIR"
    echo "请输入要恢复的备份文件名:"
    read -r BACKUP_FILE
    [ -z "$BACKUP_FILE" ] && { echo "❌ 未输入备份文件名"; return; }
    [ ! -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ ! -d "$BACKUP_DIR/$BACKUP_FILE" ] && { echo "❌ 文件不存在"; return; }

    case "$OS" in
        ubuntu|debian)
            ufw --force reset
            grep -E "ALLOW|DENY" "$BACKUP_DIR/$BACKUP_FILE" | while read -r line; do
                RULE=$(echo "$line" | awk '{print $1 " " $2 " " $3}')
                ufw $RULE
            done
            ufw --force enable
            ;;
        centos)
            rm -rf /etc/firewalld
            cp -r "$BACKUP_DIR/$BACKUP_FILE" /etc/firewalld
            systemctl restart firewalld
            ;;
        alpine)
            iptables-restore < "$BACKUP_DIR/$BACKUP_FILE"
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 防火墙已恢复"
    show_status
}

restore_initial_firewall() {
    detect_os
    local INITIAL_BACKUP="$BACKUP_DIR/initial_firewall_backup"
    local FILE="$INITIAL_BACKUP"
    [[ "$OS" == "ubuntu" || "$OS" == "debian" ]] && FILE="$INITIAL_BACKUP.txt"
    [[ "$OS" == "alpine" ]] && FILE="$INITIAL_BACKUP.txt"

    [ ! -f "$FILE" ] && [ ! -d "$FILE" ] && { echo "❌ 无初始配置备份文件，请先备份"; return; }

    echo "⚠️ 即将恢复初始防火墙配置，是否继续？(y/n)"
    read -r answer
    [[ ! "$answer" =~ ^[Yy]$ ]] && { echo "已取消恢复"; return; }

    case "$OS" in
        ubuntu|debian)
            ufw --force reset
            grep -E "ALLOW|DENY" "$FILE" | while read -r line; do
                RULE=$(echo "$line" | awk '{print $1 " " $2 " " $3}')
                ufw $RULE
            done
            ufw --force enable
            ;;
        centos)
            rm -rf /etc/firewalld
            cp -r "$FILE" /etc/firewalld
            systemctl restart firewalld
            ;;
        alpine)
            iptables-restore < "$FILE"
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 已恢复初始防火墙配置"
    show_status
}

# ================= 主菜单 =================
main_menu() {
    check_dependencies
    backup_initial_firewall
    while true; do
        echo "====== 防火墙菜单 ======"
        echo "0) 初始化防火墙"
        echo "1) 开启防火墙"
        echo "2) 关闭防火墙"
        echo "3) 修改防火墙端口"
        echo "4) 备份防火墙设置"
        echo "5) 恢复防火墙设置"
        echo "6) 查看防火墙状态和开放端口"
        echo "7) 关闭端口 (TCP/UDP同时关闭)"
        echo "8) 开启端口 (选择 TCP/UDP/all)"
        echo "9) 恢复初始防火墙配置"
        echo "q) 退出"
        echo -n "请选择操作: "
        read -r choice
        case $choice in
            0) configure_ports ;;
            1) enable_firewall ;;
            2) disable_firewall ;;
            3) configure_ports ;;
            4) backup_firewall ;;
            5) restore_firewall ;;
            6) show_status ;;
            7) close_ports ;;
            8) open_ports ;;
            9) restore_initial_firewall ;;
            q|Q) exit 0 ;;
            *) echo "❌ 无效选项" ;;
        esac
    done
}

main_menu
