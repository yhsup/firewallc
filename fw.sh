#!/bin/bash
# Firewall one-click config script with uninstall support
# Compatible with Debian/Ubuntu, CentOS/RHEL, Alpine
set -euo pipefail
IFS=$'\n\t'

# 全局变量
BACKUP_DIR="$HOME/fw_backup"
FIRST_RUN_FLAG="$HOME/.fw_first_run"
OS=""  # 全局系统变量，避免多次检测

# ================= 权限检测 =================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 请使用root权限运行此脚本！"
        exit 1
    fi
}

# ================= 系统检测（只执行一次） =================
detect_os() {
    if [[ -n "$OS" ]]; then
        return
    fi
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
        echo "❌ 未知系统，不支持！"
        exit 1
    fi
}

# ================= 端口校验 =================
validate_ports() {
    local PORTS="$1"
    for port in $PORTS; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "❌ 端口号无效: $port （必须是1-65535之间的数字）"
            return 1
        fi
    done
    return 0
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
    mkdir -p "$BACKUP_DIR"
    local INITIAL_BACKUP="$BACKUP_DIR/initial_firewall_backup"
    if [ ! -f "$FIRST_RUN_FLAG" ]; then
        echo "⚠️ 检测到第一次运行防火墙脚本，是否备份当前防火墙为初始配置？(y/n)"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            case "$OS" in
                ubuntu|debian)
                    # 备份ufw配置文件和状态，保存更全面
                    ufw status verbose > "$INITIAL_BACKUP.txt"
                    ;;
                centos)
                    cp -r /etc/firewalld "$INITIAL_BACKUP"
                    ;;
                alpine)
                    iptables-save > "$INITIAL_BACKUP.txt"
                    ;;
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
        ubuntu|debian)
            ufw status verbose || echo "❌ ufw 状态获取失败"
            ;;
        centos)
            firewall-cmd --list-all || echo "❌ firewalld 状态获取失败"
            ;;
        alpine)
            iptables -L -n -v || echo "❌ iptables 状态获取失败"
            ;;
    esac
    echo "===== 开放端口 (IPv4) ====="
    ss -tuln4 2>/dev/null | awk 'NR>1{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq || echo "❌ 无法获取IPv4端口"
    echo "===== 开放端口 (IPv6) ====="
    ss -tuln6 2>/dev/null | awk 'NR>1{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq || echo "❌ 无法获取IPv6端口"
}

# ================= 启用/禁用防火墙 =================
enable_firewall() {
    detect_os
    case "$OS" in
        ubuntu|debian) ufw --force enable ;;
        centos)
            systemctl enable firewalld
            systemctl start firewalld
            ;;
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
    SSH_PORT=${SSH_PORT:-22}
    if ! validate_ports "$SSH_PORT"; then return; fi

    echo "请输入要开放的 TCP 端口 (空格分隔):"
    read -r TCP_PORTS
    if ! validate_ports "$TCP_PORTS"; then return; fi

    echo "请输入要开放的 UDP 端口 (空格分隔):"
    read -r UDP_PORTS
    if ! validate_ports "$UDP_PORTS"; then return; fi

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

# ================= 关闭端口 =================
close_ports() {
    detect_os
    echo "请输入要关闭的端口 (空格分隔, TCP/UDP同时关闭):"
    read -r PORTS
    if [ -z "$PORTS" ]; then
        echo "❌ 未输入端口"
        return
    fi
    if ! validate_ports "$PORTS"; then return; fi

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

# ================= 开启端口 =================
open_ports() {
    detect_os
    echo "请输入要开启的端口 (空格分隔):"
    read -r PORTS
    if [ -z "$PORTS" ]; then
        echo "❌ 未输入端口"
        return
    fi
    if ! validate_ports "$PORTS"; then return; fi

    echo "请选择协议类型 (tcp/udp/all):"
    read -r PROTO
    PROTO=$(echo "$PROTO" | tr '[:upper:]' '[:lower:]')

    if [[ ! "$PROTO" =~ ^(tcp|udp|all)$ ]]; then
        echo "❌ 协议类型无效，只能是 tcp, udp 或 all"
        return
    fi

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

# ================= 备份防火墙 =================
backup_firewall() {
    detect_os
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    case "$OS" in
        ubuntu|debian)
            ufw status verbose > "$BACKUP_DIR/ufw_backup_$TIMESTAMP.txt"
            ;;
        centos)
            cp -r /etc/firewalld "$BACKUP_DIR/firewalld_backup_$TIMESTAMP"
            ;;
        alpine)
            iptables-save > "$BACKUP_DIR/iptables_backup_$TIMESTAMP.txt"
            ;;
    esac
    echo "✅ 防火墙配置已备份到 $BACKUP_DIR"
}

# ================= 恢复防火墙 =================
restore_firewall() {
    detect_os
    echo "当前备份目录 $BACKUP_DIR 中的文件列表："
    ls -1 "$BACKUP_DIR"
    echo "请输入要恢复的备份文件名或目录名："
    read -r RESTORE_FILE
    if [ ! -e "$BACKUP_DIR/$RESTORE_FILE" ]; then
        echo "❌ 备份文件不存在"
        return
    fi

    case "$OS" in
        ubuntu|debian)
            # 直接导入ufw规则较复杂，此处只简单展示恢复，建议人工检查
            echo "⚠️ UFW规则恢复仅支持手动恢复，请查看备份文件 $BACKUP_DIR/$RESTORE_FILE"
            ;;
        centos)
            systemctl stop firewalld
            rm -rf /etc/firewalld
            cp -r "$BACKUP_DIR/$RESTORE_FILE" /etc/firewalld
            systemctl start firewalld
            ;;
        alpine)
            iptables-restore < "$BACKUP_DIR/$RESTORE_FILE"
            ;;
    esac
    echo "✅ 恢复完成"
    show_status
}

# ================= 恢复初始配置 =================
restore_initial() {
    detect_os
    local INITIAL_BACKUP="$BACKUP_DIR/initial_firewall_backup"
    if [ ! -e "$INITIAL_BACKUP" ] && [ ! -d "$INITIAL_BACKUP" ] && [ ! -e "$INITIAL_BACKUP.txt" ]; then
        echo "❌ 未找到初始备份，无法恢复"
        return
    fi
    case "$OS" in
        ubuntu|debian)
            if [ -f "$INITIAL_BACKUP.txt" ]; then
                echo "⚠️ 恢复初始配置请手动查看文件：$INITIAL_BACKUP.txt"
            else
                echo "❌ 找不到初始备份文件"
            fi
            ;;
        centos)
            if [ -d "$INITIAL_BACKUP" ]; then
                systemctl stop firewalld
                rm -rf /etc/firewalld
                cp -r "$INITIAL_BACKUP" /etc/firewalld
                systemctl start firewalld
                echo "✅ 已恢复初始防火墙配置"
            else
                echo "❌ 找不到初始备份目录"
            fi
            ;;
        alpine)
            if [ -f "$INITIAL_BACKUP.txt" ]; then
                iptables-restore < "$INITIAL_BACKUP.txt"
                echo "✅ 已恢复初始防火墙配置"
            else
                echo "❌ 找不到初始备份文件"
            fi
            ;;
    esac
}

# ================= 卸载 =================
uninstall() {
    echo "⚠️ 正在卸载防火墙脚本，恢复初始防火墙配置..."
    restore_initial
    rm -f "$FIRST_RUN_FLAG"
    echo "✅ 卸载完成"
    exit 0
}

# ================= 主菜单 =================
main_menu() {
    while true; do
        echo
        echo "======= 防火墙配置管理脚本 ======="
        echo "0) 初始化防火墙（设置端口）"
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
        echo "================================="
        read -rp "请输入选项: " choice
        case "$choice" in
            0) configure_ports ;;
            1) enable_firewall ;;
            2) disable_firewall ;;
            3) configure_ports ;;
            4) backup_firewall ;;
            5) restore_firewall ;;
            6) show_status ;;
            7) close_ports ;;
            8) open_ports ;;
            9) restore_initial ;;
            q|Q) echo "退出脚本"; exit 0 ;;
            *) echo "❌ 无效选项" ;;
        esac
    done
}

# ================= 入口 =================
check_root
check_dependencies
backup_initial_firewall

# 处理卸载参数
if [[ "${1-}" == "-uninstall" ]]; then
    uninstall
fi

main_menu
