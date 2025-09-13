#!/bin/bash

menu() {
    clear
    echo "=============================="
    echo " 防火墙管理脚本"
    echo " 1. 开启防火墙并配置规则 (自动备份初始规则)"
    echo " 2. 关闭防火墙并恢复初始规则"
    echo " 3. 查看当前规则"
    echo " 4. 修改放行端口"
    echo " 5. 备份规则"
    echo " 6. 恢复规则"
    echo " 7. 卸载防火墙脚本 (删除备份并恢复初始规则)"
    echo " 8. 创建软连接 (输入 fw 即可运行脚本)"
    echo " 0. 退出"
    echo "=============================="
}

detect_system() {
    if command -v apt >/dev/null 2>&1; then
        SYS="debian"
    elif command -v yum >/dev/null 2>&1; then
        SYS="centos"
    elif command -v apk >/dev/null 2>&1; then
        SYS="alpine"
    else
        SYS="unknown"
    fi
}

detect_firewall() {
    if systemctl is-active firewalld >/dev/null 2>&1; then
        FIREWALL="firewalld"
    else
        FIREWALL="iptables"
    fi
    echo ">>> 检测到使用防火墙类型: $FIREWALL"
}

detect_ssh_port() {
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    echo ">>> 检测到 SSH 端口: $SSH_PORT"
}

backup_init_rules() {
    mkdir -p /etc/iptables/backup
    if [[ "$FIREWALL" == "iptables" ]]; then
        if [[ ! -f /etc/iptables/backup/init.rules ]]; then
            iptables-save > /etc/iptables/backup/init.rules
            echo ">>> 已备份初始规则到 /etc/iptables/backup/init.rules"
        else
            echo ">>> 初始规则已存在，不重复备份"
        fi
    else
        firewall-cmd --permanent --export > /etc/iptables/backup/init.firewalld.xml
        echo ">>> 已备份 firewalld 初始规则到 /etc/iptables/backup/init.firewalld.xml"
    fi
}

restore_init_rules() {
    if [[ "$FIREWALL" == "iptables" ]]; then
        if [[ -f /etc/iptables/backup/init.rules ]]; then
            iptables-restore < /etc/iptables/backup/init.rules
            echo ">>> 已恢复初始 iptables 规则"
        else
            echo "⚠️ 没有找到初始 iptables 规则"
        fi
    else
        if [[ -f /etc/iptables/backup/init.firewalld.xml ]]; then
            firewall-cmd --permanent --reload
            echo ">>> 已恢复初始 firewalld 规则"
        else
            echo "⚠️ 没有找到初始 firewalld 规则"
        fi
    fi
}

open_firewall() {
    backup_init_rules
    detect_ssh_port
    echo ">>> 开启防火墙并设置规则..."

    if [[ "$FIREWALL" == "iptables" ]]; then
        iptables -F
        iptables -X
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT

        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
        echo "已放行 SSH 端口: $SSH_PORT"

        read -p "是否启用超安全模式（只允许 SSH 入站，其他全部拒绝）？(y/n): " safe_mode
        if [[ "$safe_mode" == "y" ]]; then
            echo ">>> 超安全模式已启用：仅允许 SSH 入站"
        else
            # 其他常用端口放行
            read -p "是否放行 HTTP 80 端口？(y/n): " close_http
            [[ "$close_http" == "y" ]] || iptables -A INPUT -p tcp --dport 80 -j ACCEPT

            read -p "是否放行 HTTPS 443 端口？(y/n): " close_https
            [[ "$close_https" == "y" ]] || iptables -A INPUT -p tcp --dport 443 -j ACCEPT

            read -p "是否放行 DNS 53 端口？(y/n): " close_dns
            [[ "$close_dns" == "y" ]] || iptables -A INPUT -p udp --dport 53 -j ACCEPT

            read -p "是否允许 Ping(ICMP)？(y/n): " close_ping
            [[ "$close_ping" == "y" ]] || iptables -A INPUT -p icmp -j ACCEPT
        fi

        echo ">>> iptables 规则已应用"

    else
        firewall-cmd --permanent --set-default-zone=drop
        firewall-cmd --permanent --zone=drop --add-port=${SSH_PORT}/tcp
        echo "已放行 SSH 端口: $SSH_PORT"

        read -p "是否启用超安全模式（只允许 SSH 入站，其他全部拒绝）？(y/n): " safe_mode
        if [[ "$safe_mode" == "y" ]]; then
            echo ">>> 超安全模式已启用：仅允许 SSH 入站"
        else
            read -p "是否放行 HTTP 80 端口？(y/n): " close_http
            [[ "$close_http" == "y" ]] || firewall-cmd --permanent --zone=drop --add-service=http

            read -p "是否放行 HTTPS 443 端口？(y/n): " close_https
            [[ "$close_https" == "y" ]] || firewall-cmd --permanent --zone=drop --add-service=https

            read -p "是否放行 DNS 53 端口？(y/n): " close_dns
            [[ "$close_dns" == "y" ]] || firewall-cmd --permanent --zone=drop --add-port=53/udp

            read -p "是否允许 Ping(ICMP)？(y/n): " close_ping
            [[ "$close_ping" == "y" ]] || firewall-cmd --permanent --zone=drop --add-icmp-block-inversion=no
        fi

        firewall-cmd --reload
        echo ">>> firewalld 规则已应用"
    fi
}
close_firewall() {
    echo ">>> 关闭防火墙并恢复初始规则..."
    restore_init_rules
}

check_rules() {
    GREEN="\033[32m"
    YELLOW="\033[33m"
    RED="\033[31m"
    RESET="\033[0m"

    KEY_PORTS=(22 80 443 53)

    highlight_ports() {
        ports=$1
        [[ -z "$ports" ]] && echo "" && return
        IFS=',' read -ra arr <<< "$ports"
        out=""
        for p in "${arr[@]}"; do
            if [[ " ${KEY_PORTS[@]} " =~ " $p " ]]; then
                out+="${YELLOW}$p${RESET},"
            else
                out+="$p,"
            fi
        done
        echo "${out%,}"
    }

    echo -e "${YELLOW}>>> 防火墙规则概览${RESET}"

    if [[ "$FIREWALL" == "iptables" ]]; then
        # iptables 入站
        echo -e "\n--- 入站规则 (INPUT) ---"
        input_policy=$(iptables -L INPUT -n | grep 'Chain INPUT' | awk '{print $4}')
        tcp_in=$(iptables -L INPUT -n | grep '^ACCEPT' | grep tcp | grep -oP 'dpt:\K[0-9]+' | tr '\n' ',' | sed 's/,$//')
        udp_in=$(iptables -L INPUT -n | grep '^ACCEPT' | grep udp | grep -oP 'dpt:\K[0-9]+' | tr '\n' ',' | sed 's/,$//')

        if [[ "$tcp_in" == "$SSH_PORT" && -z "$udp_in" ]]; then
            echo -e "${GREEN}已开启超级安全模式，仅允许 SSH 端口 (${SSH_PORT})${RESET}"
        elif [[ -z "$tcp_in" && -z "$udp_in" ]]; then
            echo -e "${RED}入站: DENY${RESET}"
        else
            echo -e "TCP允许端口: $(highlight_ports $tcp_in)"
            echo -e "UDP允许端口: $(highlight_ports $udp_in)"
        fi
        echo -e "入站策略: ${input_policy}"

        # iptables 出站
        echo -e "\n--- 出站规则 (OUTPUT) ---"
        output_policy=$(iptables -L OUTPUT -n | grep 'Chain OUTPUT' | awk '{print $4}')
        tcp_out=$(iptables -L OUTPUT -n | grep '^ACCEPT' | grep tcp | grep -oP 'dpt:\K[0-9]+' | tr '\n' ',' | sed 's/,$//')
        udp_out=$(iptables -L OUTPUT -n | grep '^ACCEPT' | grep udp | grep -oP 'dpt:\K[0-9]+' | tr '\n' ',' | sed 's/,$//')

        if [[ -z "$tcp_out" && -z "$udp_out" ]]; then
            echo -e "${RED}出站: DENY${RESET}"
        else
            echo -e "TCP允许端口: $(highlight_ports $tcp_out)"
            echo -e "UDP允许端口: $(highlight_ports $udp_out)"
        fi
        echo -e "出站策略: ${output_policy}"

    else
        zones=$(firewall-cmd --get-zones)
        for zone in $zones; do
            echo -e "\nZone: $zone"

            services=$(firewall-cmd --zone=$zone --list-services | tr ' ' ', ')
            tcp_ports=$(firewall-cmd --zone=$zone --list-ports | tr ' ' ',')
            udp_ports="$tcp_ports"
            target=$(firewall-cmd --zone=$zone --get-target)

            # 入站显示
            if [[ "$tcp_ports" == "$SSH_PORT" && -z "$services" ]]; then
                echo -e "${GREEN}已开启超级安全模式，仅允许 SSH 端口 (${SSH_PORT})${RESET}"
            elif [[ -z "$services" && -z "$tcp_ports" ]]; then
                echo -e "${RED}入站: DENY${RESET}"
            else
                echo "入站允许的服务: ${services:-无}"
                echo "入站允许的TCP端口: $(highlight_ports $tcp_ports)"
                echo "入站允许的UDP端口: $(highlight_ports $udp_ports)"
            fi
            echo "入站策略: ${target}"

            # 出站显示（从 iptables 获取）
            tcp_out=$(iptables -L OUTPUT -n | grep '^ACCEPT' | grep tcp | grep -oP 'dpt:\K[0-9]+' | tr '\n' ',' | sed 's/,$//')
            udp_out=$(iptables -L OUTPUT -n | grep '^ACCEPT' | grep udp | grep -oP 'dpt:\K[0-9]+' | tr '\n' ',' | sed 's/,$//')

            if [[ -z "$tcp_out" && -z "$udp_out" ]]; then
                echo -e "${RED}出站: DENY${RESET}"
            else
                echo "出站允许的TCP端口: $(highlight_ports $tcp_out)"
                echo "出站允许的UDP端口: $(highlight_ports $udp_out)"
            fi
            echo "出站策略: 默认允许或 iptables 设置"
        done
    fi

    echo -e "${YELLOW}>>> 显示完毕${RESET}"
}

modify_ports() {
    read -p "请选择放行方向 (1=入站, 2=出站, 3=入站+出站): " direction

    read -p "请输入要放行的 TCP 端口 (空格分隔): " new_tcp
    read -p "请输入要放行的 UDP 端口 (空格分隔): " new_udp

    if [[ "$FIREWALL" == "iptables" ]]; then
        for port in $new_tcp; do
            [[ "$direction" == "1" || "$direction" == "3" ]] && iptables -A INPUT -p tcp --dport $port -j ACCEPT
            [[ "$direction" == "2" || "$direction" == "3" ]] && iptables -A OUTPUT -p tcp --dport $port -j ACCEPT
            echo "已放行 TCP $port"
        done

        for port in $new_udp; do
            [[ "$direction" == "1" || "$direction" == "3" ]] && iptables -A INPUT -p udp --dport $port -j ACCEPT
            [[ "$direction" == "2" || "$direction" == "3" ]] && iptables -A OUTPUT -p udp --dport $port -j ACCEPT
            echo "已放行 UDP $port"
        done

    else
        # 入站规则用 firewalld
        if [[ "$direction" == "1" || "$direction" == "3" ]]; then
            for port in $new_tcp; do
                firewall-cmd --permanent --zone=drop --add-port=${port}/tcp
                echo "入站 TCP 端口已放行: $port"
            done
            for port in $new_udp; do
                firewall-cmd --permanent --zone=drop --add-port=${port}/udp
                echo "入站 UDP 端口已放行: $port"
            done
        fi

        # 出站规则用 iptables
        if [[ "$direction" == "2" || "$direction" == "3" ]]; then
            for port in $new_tcp; do
                iptables -A OUTPUT -p tcp --dport $port -j ACCEPT
                echo "出站 TCP 端口已放行: $port"
            done
            for port in $new_udp; do
                iptables -A OUTPUT -p udp --dport $port -j ACCEPT
                echo "出站 UDP 端口已放行: $port"
            done
        fi

        firewall-cmd --reload
    fi
}
backup_rules() {
    mkdir -p /etc/iptables/backup
    if [[ "$FIREWALL" == "iptables" ]]; then
        iptables-save > /etc/iptables/backup/backup-$(date +%Y%m%d-%H%M%S).rules
        echo ">>> iptables 规则已备份"
    else
        firewall-cmd --permanent --export > /etc/iptables/backup/backup-$(date +%Y%m%d-%H%M%S).xml
        echo ">>> firewalld 规则已备份"
    fi
}

uninstall_firewall() {
    echo -e "\n⚠️ 卸载将删除所有备份规则、恢复初始规则，并删除软连接！"
    read -p "你确定要继续吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && { echo "已取消卸载"; return; }

    read -p "再次确认，是否真的删除所有规则并卸载？(y/n): " confirm2
    [[ "$confirm2" != "y" ]] && { echo "已取消卸载"; return; }

    # 1. 恢复初始规则
    restore_init_rules

    # 2. 删除所有备份文件
    echo ">>> 正在删除所有备份文件..."
    rm -f "$BACKUP_DIR"/*
    echo ">>> 已删除所有备份文件"

    # 3. 删除软连接
    SYMLINK_PATH="/usr/local/bin/fw"
    if [[ -L "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH"
        echo ">>> 已删除软连接 $SYMLINK_PATH"
    fi

    # 4. 自动确保 SSH 端口开放
    detect_ssh_port
    if [[ "$FIREWALL" == "iptables" ]]; then
        iptables -C INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
        echo ">>> 已确保 SSH 端口 $SSH_PORT 开放"
    else
        firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
        firewall-cmd --reload
        echo ">>> 已确保 SSH 端口 $SSH_PORT 开放 (firewalld)"
    fi

    # 5. 提示用户脚本自身可手动删除
    SCRIPT_PATH="$(realpath "$0")"
    echo ">>> 卸载完成，脚本文件 $SCRIPT_PATH 可手动删除"

    exit 0
}

create_symlink() {
    read -p "请输入软连接路径 (默认 /usr/local/bin/fw): " symlink_path
    symlink_path=${symlink_path:-/usr/local/bin/fw}

    SCRIPT_PATH="$(realpath "$0")"

    if [[ -e "$symlink_path" ]]; then
        read -p "软连接已存在，是否覆盖？(y/n): " overwrite
        [[ "$overwrite" != "y" ]] && { echo "已取消创建"; return; }
        rm -f "$symlink_path"
    fi

    ln -s "$SCRIPT_PATH" "$symlink_path"
    chmod +x "$SCRIPT_PATH"
    echo ">>> 已创建软连接：输入 '$symlink_path' 即可运行脚本"
}

restore_rules() {
    if [[ "$FIREWALL" == "iptables" ]]; then
        files=(/etc/iptables/backup/*.rules)

        if [[ ! -f "/etc/iptables/backup/init.rules" ]]; then
            echo "⚠️ 没有找到初始 iptables 规则"
        fi

        echo "可用备份文件："
        [[ -f "/etc/iptables/backup/init.rules" ]] && echo "0) 初始规则: /etc/iptables/backup/init.rules"
        idx=1
        for f in "${files[@]}"; do
            [[ "$f" != "/etc/iptables/backup/init.rules" ]] && echo "$((idx))) $f" && ((idx++))
        done

        read -p "请输入要恢复的备份序号 (例如 0 或 1): " choice
        if [[ "$choice" == "0" ]]; then
            iptables-restore < "/etc/iptables/backup/init.rules"
            echo ">>> 已恢复初始 iptables 规则"
        else
            file_to_restore="${files[$((choice-1))]}"
            if [[ -f "$file_to_restore" ]]; then
                iptables-restore < "$file_to_restore"
                echo ">>> 已恢复规则: $file_to_restore"
            else
                echo "⚠️ 无效序号"
            fi
        fi

    else
        files=(/etc/iptables/backup/*.xml)

        echo "可用备份文件："
        [[ -f "/etc/iptables/backup/init.firewalld.xml" ]] && echo "0) 初始规则: /etc/iptables/backup/init.firewalld.xml"
        idx=1
        for f in "${files[@]}"; do
            [[ "$f" != "/etc/iptables/backup/init.firewalld.xml" ]] && echo "$((idx))) $f" && ((idx++))
        done

        read -p "请输入要恢复的备份序号 (例如 0 或 1): " choice
        if [[ "$choice" == "0" ]]; then
            firewall-cmd --reload
            echo ">>> 已恢复初始 firewalld 规则 (请确认规则已生效)"
        else
            file_to_restore="${files[$((choice-1))]}"
            if [[ -f "$file_to_restore" ]]; then
                firewall-cmd --reload
                echo ">>> 已恢复 firewalld 规则 (请确认规则已生效)"
            else
                echo "⚠️ 无效序号"
            fi
        fi
    fi
}

# 主循环
detect_system
detect_firewall
while true; do
    menu
    read -p "请输入选项: " choice
    case $choice in
        1) open_firewall ;;
        2) close_firewall ;;
        3) check_rules ;;
        4) modify_ports ;;
        5) backup_rules ;;
        6) restore_rules ;;
        7) uninstall_firewall ;;
        8) create_symlink ;;
        0) exit ;;
        *) echo "无效选项，请重试" ;;
    esac
    read -p "按回车键继续..."
done
