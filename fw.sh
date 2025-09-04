#!/bin/bash
# Firewall one-click config script
# Compatible with Debian/Ubuntu, CentOS/RHEL, Alpine
set -e

BACKUP_DIR="$HOME/fw_backup"
FIRST_RUN_FLAG="$HOME/.fw_first_run"
SCRIPT_PATH="/usr/local/bin/fw"
ORIGINAL_SCRIPT_PATH="$(realpath "$0")"

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
        echo "⚠️ 检测到第一次运行防火墙脚本，是否备份当前防火墙为初始配置？(Y/n，回车默认选择Y)"
        read -r answer
        answer="${answer:-y}"   # 回车默认选择 y
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            mkdir -p "$BACKUP_DIR"
            case "$OS" in
                ubuntu|debian)
                    echo "# UFW initial rules backup" > "${INITIAL_BACKUP}.rules"
                    ufw status numbered | grep '\[ [0-9]\+\]' | sed 's/\[.*\]//g' >> "${INITIAL_BACKUP}.rules"
                    ;;
                centos)
                    cp -r /etc/firewalld "$INITIAL_BACKUP"
                    ;;
                alpine)
                    iptables-save > "${INITIAL_BACKUP}.txt"
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
        ubuntu|debian) ufw status verbose ;;
        centos) firewall-cmd --list-all ;;
        alpine) iptables -L -n -v ;;
    esac
    echo "===== 开放端口 (IPv4) ====="
    ss -tuln4 2>/dev/null | awk 'NR>1{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq
    echo "===== 开放端口 (IPv6) ====="
    ss -tuln6 2>/dev/null | awk 'NR>1{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq
}

# ================= 显示入站/出站默认策略 =================
show_firewall_policies() {
    detect_os
    echo "===== 防火墙默认策略（入站 / 出站） ====="
    case "$OS" in
        ubuntu|debian)
            local default_line in_policy out_policy
            default_line=$(ufw status verbose 2>/dev/null | grep -i "Default:")
            if [[ -n "$default_line" ]]; then
                # 示例字符串:
                # Default: deny (incoming), allow (outgoing), deny (routed)
                in_policy=$(echo "$default_line" | sed -n 's/.*Default: \([^ ]*\) *(incoming).*/\1/p')
                out_policy=$(echo "$default_line" | sed -n 's/.*(incoming), \([^ ]*\) *(outgoing).*/\1/p')
                in_policy=${in_policy:-未知}
                out_policy=${out_policy:-未知}
            else
                in_policy="未知"
                out_policy="未知"
            fi
            echo "入站默认策略 (INPUT): $in_policy"
            echo "出站默认策略 (OUTPUT): $out_policy"
            ;;
        centos)
            echo "入站默认策略 (INPUT): firewalld 默认通过服务/端口控制入站流量，未定义规则默认拒绝"
            echo "出站默认策略 (OUTPUT): 默认允许所有流量"
            ;;
        alpine)
            in_policy=$(iptables -L INPUT -n | grep "Chain INPUT" | awk '{print $4}')
            out_policy=$(iptables -L OUTPUT -n | grep "Chain OUTPUT" | awk '{print $4}')
            echo "入站默认策略 (INPUT): ${in_policy:-未知}"
            echo "出站默认策略 (OUTPUT): ${out_policy:-未知}"
            ;;
        *)
            echo "未知系统，无法显示默认策略"
            ;;
    esac
    echo "======================================"
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
    echo "✅ 已关闭指定端口"
    show_status
}

open_ports() {
    detect_os
    echo "请输入要开放的端口 (空格分隔, TCP/UDP同时开放):"
    read -r PORTS
    [ -z "$PORTS" ] && { echo "❌ 未输入端口"; return; }

    case "$OS" in
        ubuntu|debian)
            for port in $PORTS; do
                ufw allow "${port}/tcp"
                ufw allow "${port}/udp"
            done
            ;;
        centos)
            for port in $PORTS; do
                firewall-cmd --permanent --add-port="${port}/tcp"
                firewall-cmd --permanent --add-port="${port}/udp"
            done
            firewall-cmd --reload
            ;;
        alpine)
            for port in $PORTS; do
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            done
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 已开放指定端口"
    show_status
}

# ================= 备份 =================
backup_firewall() {
    detect_os
    local BACKUP_FILE="$BACKUP_DIR/fw_backup_$(date +%F_%H-%M-%S)"

    case "$OS" in
        ubuntu|debian)
            echo "# UFW rules backup" > "$BACKUP_FILE.rules"
            ufw status numbered | grep '\[ [0-9]\+\]' | sed 's/\[.*\]//g' >> "$BACKUP_FILE.rules"
            ;;
        centos)
            tar czf "$BACKUP_FILE.tar.gz" /etc/firewalld
            ;;
        alpine)
            iptables-save > "$BACKUP_FILE.txt"
            ;;
    esac

    echo "✅ 防火墙已备份到 $BACKUP_FILE"
}

# ================= 恢复 =================
restore_firewall() {
    detect_os

    echo "可用备份列表："
    local files=("$BACKUP_DIR"/*)
    local i=1

    for file in "${files[@]}"; do
        echo "$i) $(basename "$file")"
        ((i++))
    done

    echo -n "请输入要恢复的备份编号: "
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
        echo "❌ 无效编号"
        return
    fi

    local FILE="${files[$((choice - 1))]}"
    echo "⚙️ 正在恢复备份：$(basename "$FILE")"

    case "$OS" in
        ubuntu|debian)
            echo "恢复 UFW 配置..."
            ufw --force disable
            ufw reset

            while read -r rule; do
                rule="$(echo "$rule" | sed 's/^[ \t]*//;s/[ \t]*$//')" # 去除首尾空格
                [[ -z "$rule" || "$rule" =~ ^# ]] && continue          # 跳过注释/空行
                ufw $rule || echo "⚠️ 规则执行失败: ufw $rule"
            done < "$FILE"

            ufw --force enable
            ;;
        centos)
            tar xzf "$FILE" -C /
            systemctl restart firewalld
            ;;
        alpine)
            iptables-restore < "$FILE"
            /etc/init.d/iptables save
            ;;
    esac

    echo "✅ 恢复完成"
    show_status
}

# ================= 卸载 =================
uninstall() {
    echo "确认卸载防火墙脚本？(y/n)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        detect_os
        local INITIAL_BACKUP="$BACKUP_DIR/initial_firewall_backup"

        if [ -e "${INITIAL_BACKUP}.rules" ] || [ -e "${INITIAL_BACKUP}.txt" ] || [ -d "${INITIAL_BACKUP}" ]; then
            echo "检测到初始防火墙备份，是否恢复该配置？(Y/n，回车默认选择Y)"
            read -r restore_answer
            restore_answer="${restore_answer:-y}"
            if [[ "$restore_answer" =~ ^[Yy]$ ]]; then
                case "$OS" in
                    ubuntu|debian)
                        if [ -f "${INITIAL_BACKUP}.rules" ]; then
                            echo "正在自动恢复 UFW 初始配置..."
                            ufw --force disable
                            ufw reset
                            while read -r rule; do
                                rule="$(echo "$rule" | sed 's/^[ \t]*//;s/[ \t]*$//')"
                                [[ -z "$rule" || "$rule" =~ ^# ]] && continue
                                ufw $rule || echo "⚠️ 执行失败: ufw $rule"
                            done < "${INITIAL_BACKUP}.rules"
                            ufw --force enable
                            echo "✅ UFW 已恢复初始配置"
                        else
                            echo "❌ 找不到 UFW 备份文件，跳过恢复"
                        fi
                        ;;
                    centos)
                        if [ -d "${INITIAL_BACKUP}" ]; then
                            echo "正在恢复 firewalld 初始配置..."
                            rm -rf /etc/firewalld
                            cp -r "${INITIAL_BACKUP}" /etc/firewalld
                            systemctl restart firewalld
                            echo "✅ firewalld 已恢复初始配置"
                        else
                            echo "❌ 找不到 firewalld 备份目录，跳过恢复"
                        fi
                        ;;
                    alpine)
                        if [ -f "${INITIAL_BACKUP}.txt" ]; then
                            echo "正在恢复 iptables 初始配置..."
                            iptables-restore < "${INITIAL_BACKUP}.txt"
                            /etc/init.d/iptables save
                            echo "✅ iptables 已恢复初始配置"
                        else
                            echo "❌ 找不到 iptables 备份文件，跳过恢复"
                        fi
                        ;;
                esac
            else
                echo "跳过恢复初始配置"
            fi
        else
            echo "未找到初始防火墙备份，跳过恢复"
        fi

        echo "🧹 正在删除所有备份文件..."
        rm -rf "$BACKUP_DIR"

        echo "🗑️ 删除快捷命令和标志文件..."
        rm -f "$SCRIPT_PATH"
        rm -f "$FIRST_RUN_FLAG"

        echo "✅ 已卸载防火墙脚本及所有备份"
        exit 0
    else
        echo "取消卸载"
    fi
}

# ================= 主菜单 =================
main_menu() {
    while true; do
        clear
        show_firewall_policies
        echo "====== 防火墙管理面板 ======"
        echo "1) 显示防火墙状态"
        echo "2) 启用防火墙"
        echo "3) 禁用防火墙"
        echo "4) 配置端口"
        echo "5) 关闭端口"
        echo "6) 开启端口"
        echo "7) 备份当前防火墙"
        echo "8) 恢复防火墙"
        echo "9) 卸载脚本"
        echo "0) 返回"
        echo -n "请输入选项: "
        read -r opt
        case "$opt" in
            1) show_status; read -rp "按回车继续..." ;;
            2) enable_firewall; read -rp "按回车继续..." ;;
            3) disable_firewall; read -rp "按回车继续..." ;;
            4) configure_ports; read -rp "按回车继续..." ;;
            5) close_ports; read -rp "按回车继续..." ;;
            6) open_ports; read -rp "按回车继续..." ;;
            7) backup_firewall; read -rp "按回车继续..." ;;
            8) restore_firewall; read -rp "按回车继续..." ;;
            9) uninstall ;;
            0) break ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

# ================= 顶层菜单 =================
top_menu() {
    while true; do
        clear
        echo "====== 防火墙脚本菜单 ======"
        echo "1) 打开防火墙控制面板（并自动启用防火墙）"
        echo "2) 卸载脚本"
        echo "3) 只打开防火墙控制面板（不启用防火墙）"
        echo "0) 退出"
        echo -n "请输入选项: "
        read -r choice
        case "$choice" in
            1)
                enable_firewall
                main_menu
                ;;
            2) uninstall ;;
            3) main_menu ;;  
            0) exit 0 ;;
            *) echo "无效输入，请重新输入" ; sleep 1 ;;
        esac
    done
}

# ================= 脚本主函数 =================
main() {
    detect_os
    check_dependencies
    backup_initial_firewall

    # 自动创建软链接，方便快捷调用
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "创建快捷命令：$SCRIPT_PATH"
        ln -sf "$ORIGINAL_SCRIPT_PATH" "$SCRIPT_PATH"
        chmod +x "$ORIGINAL_SCRIPT_PATH" "$SCRIPT_PATH"
    fi

    if [[ "$1" == "-uninstall" ]]; then
        uninstall
        exit 0
    fi

    # 首次运行安装服务或其他初始化任务（此处留空）
    # if [ ! -f "$FIRST_RUN_FLAG" ]; then
    #     # 你的初始化操作
    #     touch "$FIRST_RUN_FLAG"
    # fi

    top_menu
}

main "$@"
