#!/bin/bash
set -euo pipefail

# 文件路径定义
FORCED_CLOSED_PORTS_FILE="/etc/force_closed_ports.list"
BACKUP_DIR="/etc/firewall_backup"
BACKUP_FILE="${BACKUP_DIR}/firewall_backup_$(date +%F_%T).rules"

# 全局变量
OS=""

# 检查是否root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] 请以 root 权限运行此脚本！"
        exit 1
    fi
}

# 系统检测
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) OS="debian" ;;
            centos|rhel) OS="centos" ;;
            alpine) OS="alpine" ;;
            *) OS="unknown" ;;
        esac
    else
        OS="unknown"
    fi
    if [ "$OS" = "unknown" ]; then
        echo "[ERROR] 不支持的操作系统"
        exit 1
    fi
}

# 安装必要依赖
install_packages() {
    local packages=("$@")
    echo "[INFO] 安装依赖包: ${packages[*]}"
    case "$OS" in
        debian)
            apt update -y
            apt install -y "${packages[@]}"
            ;;
        centos)
            yum install -y "${packages[@]}"
            ;;
        alpine)
            apk add --no-cache "${packages[@]}"
            ;;
    esac
}

check_dependencies() {
    case "$OS" in
        debian)
            command -v ufw >/dev/null 2>&1 || install_packages ufw
            command -v ss >/dev/null 2>&1 || install_packages iproute2
            ;;
        centos)
            command -v firewall-cmd >/dev/null 2>&1 || install_packages firewalld
            command -v ss >/dev/null 2>&1 || install_packages iproute
            ;;
        alpine)
            command -v iptables >/dev/null 2>&1 || install_packages iptables
            command -v ss >/dev/null 2>&1 || install_packages iproute2
            ;;
    esac
}

# 备份当前防火墙配置
backup_firewall() {
    echo "[INFO] 备份当前防火墙配置..."
    mkdir -p "$BACKUP_DIR"
    case "$OS" in
        debian|centos)
            iptables-save > "$BACKUP_FILE"
            echo "[INFO] 已备份iptables规则到 $BACKUP_FILE"
            ;;
        alpine)
            iptables-save > "$BACKUP_FILE"
            echo "[INFO] 已备份iptables规则到 $BACKUP_FILE"
            ;;
    esac
}

# 恢复防火墙配置
restore_firewall() {
    echo "[INFO] 请选择恢复备份文件："
    select file in "$BACKUP_DIR"/*.rules; do
        if [ -f "$file" ]; then
            iptables-restore < "$file"
            echo "[INFO] 防火墙配置已从 $file 恢复"
            break
        else
            echo "[WARN] 选择的文件无效，请重试。"
        fi
    done
}

# 统一添加端口规则
add_port() {
    local port=$1
    local proto=$2
    case "$OS" in
        debian)
            ufw allow "${port}/${proto}" && echo "[INFO] ufw 允许端口 $port/$proto"
            ;;
        centos)
            firewall-cmd --permanent --add-port="${port}/${proto}" && firewall-cmd --reload && echo "[INFO] firewalld 允许端口 $port/$proto"
            ;;
        alpine)
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT && echo "[INFO] iptables 允许端口 $port/$proto"
            ;;
    esac
}

# 统一删除端口规则
remove_port() {
    local port=$1
    local proto=$2
    case "$OS" in
        debian)
            ufw delete allow "${port}/${proto}" && echo "[INFO] ufw 删除端口 $port/$proto"
            ;;
        centos)
            firewall-cmd --permanent --remove-port="${port}/${proto}" && firewall-cmd --reload && echo "[INFO] firewalld 删除端口 $port/$proto"
            ;;
        alpine)
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT && echo "[INFO] iptables 删除端口 $port/$proto"
            ;;
    esac
}

# 显示所有开放端口
list_open_ports() {
    echo "[INFO] 当前开放端口:"
    case "$OS" in
        debian)
            ufw status numbered
            ;;
        centos)
            firewall-cmd --list-ports
            ;;
        alpine)
            ss -tuln | grep -E 'LISTEN'
            ;;
    esac
}

# 强制关闭端口 - 并保存到文件
force_close_ports() {
    echo "[INFO] 请输入要强制关闭的端口，多个端口用空格分隔:"
    read -rp "> " ports
    ports=$(echo "$ports" | xargs) # 去除首尾空白
    if [ -z "$ports" ]; then
        echo "[WARN] 未输入端口，取消操作。"
        return
    fi

    for port in $ports; do
        echo "[INFO] 关闭端口 $port"
        # 删除所有协议的允许规则
        remove_port "$port" tcp || true
        remove_port "$port" udp || true
    done

    # 追加到强制关闭文件，避免重启恢复
    echo "$ports" | tr ' ' '\n' >> "$FORCED_CLOSED_PORTS_FILE"
    echo "[INFO] 已保存强制关闭端口列表到 $FORCED_CLOSED_PORTS_FILE"
}

# 恢复强制关闭端口（从文件删除规则）
restore_forced_closed_ports() {
    if [ ! -f "$FORCED_CLOSED_PORTS_FILE" ]; then
        echo "[WARN] 找不到强制关闭端口文件 $FORCED_CLOSED_PORTS_FILE"
        return
    fi
    echo "[INFO] 恢复强制关闭端口..."
    while read -r port; do
        [ -z "$port" ] && continue
        echo "[INFO] 恢复端口 $port"
        # 这里默认恢复允许规则，默认用tcp
        add_port "$port" tcp
    done < "$FORCED_CLOSED_PORTS_FILE"
    rm -f "$FORCED_CLOSED_PORTS_FILE"
    echo "[INFO] 已删除强制关闭端口文件"
}

# 显示菜单
main_menu() {
    while true; do
        cat <<EOF
================ 防火墙管理脚本 ================
1) 显示当前开放端口
2) 允许端口
3) 删除端口
4) 强制关闭端口
5) 恢复强制关闭端口
6) 备份防火墙配置
7) 恢复防火墙配置
0) 退出
================================================
EOF
        read -rp "请选择操作 [0-7]: " choice
        case "$choice" in
            1)
                list_open_ports
                ;;
            2)
                read -rp "请输入允许的端口号: " port
                read -rp "请输入协议 (tcp/udp) [tcp]: " proto
                proto=${proto:-tcp}
                add_port "$port" "$proto"
                ;;
            3)
                read -rp "请输入要删除的端口号: " port
                read -rp "请输入协议 (tcp/udp) [tcp]: " proto
                proto=${proto:-tcp}
                remove_port "$port" "$proto"
                ;;
            4)
                force_close_ports
                ;;
            5)
                restore_forced_closed_ports
                ;;
            6)
                backup_firewall
                ;;
            7)
                restore_firewall
                ;;
            0)
                echo "[INFO] 退出脚本"
                exit 0
                ;;
            *)
                echo "[WARN] 无效选择，请重新输入"
                ;;
        esac
        echo
    done
}

# 脚本入口
main() {
    check_root
    detect_os
    check_dependencies
    main_menu
}

main "$@"
