#!/bin/bash
# Firewall one-click config script (已修改：开启即配置系统默认规则)
# Compatible with Debian/Ubuntu, CentOS/RHEL, Alpine
set -e

BACKUP_DIR="$HOME/fw_backup"
FIRST_RUN_FLAG="$HOME/.fw_first_run"
SCRIPT_PATH="/usr/local/bin/fw"
ORIGINAL_SCRIPT_PATH="$(realpath "$0")"
# 新增：系统默认需要开放的端口/规则（统一定义，便于维护）
DEFAULT_TCP_PORTS="22 80 443"  # SSH、HTTP、HTTPS
DEFAULT_UDP_PORTS="53"         # DNS
DEFAULT_RULES="lo,established,icmp"  # 回环、已建立连接、Ping

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
        answer="${answer:-y}"
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

# ================= 应用系统默认规则 =================
apply_default_rules() {
    detect_os
    echo "📦 正在应用系统默认防火墙规则（保障基础通信）..."
    case "$OS" in
        ubuntu|debian)
            # 1. 重置基础规则（修复：删除 UFW 不支持的 state 语法）
            ufw --force reset
            ufw default deny incoming  # 入站默认拒绝（仅开放必要端口）
            ufw default allow outgoing  # 出站默认允许（不限制主动访问）
            # 2. 应用默认规则：回环接口、Ping（UFW 自动处理已建立连接，无需手动加 state 规则）
            ufw allow in on lo  # 允许回环接口（本地服务通信）
            ufw allow in proto icmp from any to any icmp-type echo-request  # 允许 Ping
            # 3. 开放默认TCP/UDP端口（SSH、DNS、HTTP、HTTPS）
            for port in $DEFAULT_TCP_PORTS; do ufw allow "${port}/tcp"; done
            for port in $DEFAULT_UDP_PORTS; do ufw allow "${port}/udp"; done
            ;;
        centos)
            # （保持不变，无需修改）
            systemctl enable --now firewalld
            firewall-cmd --set-default-zone=public
            firewall-cmd --permanent --set-target=DROP --zone=public
            firewall-cmd --permanent --add-interface=lo --zone=trusted
            firewall-cmd --permanent --add-rich-rule='rule family="ipv4" state ESTABLISHED accept'
            firewall-cmd --permanent --add-icmp-block-inversion
            firewall-cmd --permanent --add-icmp-type=echo-request
            for port in $DEFAULT_TCP_PORTS; do firewall-cmd --permanent --add-port="${port}/tcp"; done
            for port in $DEFAULT_UDP_PORTS; do firewall-cmd --permanent --add-port="${port}/udp"; done
            firewall-cmd --reload
            ;;
        alpine)
            # （保持不变，无需修改）
            iptables -F && iptables -X
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
            for port in $DEFAULT_TCP_PORTS; do iptables -A INPUT -p tcp --dport "$port" -j ACCEPT; done
            for port in $DEFAULT_UDP_PORTS; do iptables -A INPUT -p udp --dport "$port" -j ACCEPT; done
            /etc/init.d/iptables save
            rc-update add iptables default
            ;;
    esac
    echo "✅ 系统默认规则应用完成（已开放：SSH/22、DNS/53、HTTP/80、HTTPS/443 + 基础通信）"
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

    echo ""
    echo "===== 开放端口 (IPv4 和 IPv6，含协议) ====="
    ss -tuln 2>/dev/null | awk '
        NR > 1 {
            proto = $1
            port = $5
            if (proto ~ /tcp/) {
                gsub(".*:", "", port)
                print port "/tcp"
            } else if (proto ~ /udp/) {
                gsub(".*:", "", port)
                print port "/udp"
            }
        }
    ' | sort -u
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
}

# ================= 启用/禁用防火墙（修改：启用时自动应用默认规则） =================
enable_firewall() {
    detect_os
    echo "🔌 正在启用防火墙并应用系统默认规则..."
    case "$OS" in
        ubuntu|debian) ufw --force enable ;;
        centos) systemctl start firewalld ;;
        alpine) /etc/init.d/iptables start ;;
    esac
    apply_default_rules  # 启用后自动应用默认规则
    echo "✅ 防火墙已启用（含系统默认规则）"
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

# ================= 配置端口（修改：保留用户自定义，叠加默认规则） =================
configure_ports() {
    detect_os
    # 先应用系统默认规则（保障基础通信）
    apply_default_rules
    
    # 再让用户输入自定义端口（叠加在默认规则上，不覆盖）
    echo "请输入额外需要开放的 SSH 端口 (默认已开放22，如需新增请输入，空则跳过):"
    read -r SSH_PORT_EXTRA
    echo "请输入额外需要开放的 TCP 端口 (空格分隔，空则跳过):"
    read -r TCP_PORTS_EXTRA
    echo "请输入额外需要开放的 UDP 端口 (空格分隔，空则跳过):"
    read -r UDP_PORTS_EXTRA

    case "$OS" in
        ubuntu|debian)
            [ -n "$SSH_PORT_EXTRA" ] && ufw allow "${SSH_PORT_EXTRA}/tcp"
            for port in $TCP_PORTS_EXTRA; do [ -n "$port" ] && ufw allow "${port}/tcp"; done
            for port in $UDP_PORTS_EXTRA; do [ -n "$port" ] && ufw allow "${port}/udp"; done
            ufw --force enable
            ;;
        centos)
            [ -n "$SSH_PORT_EXTRA" ] && firewall-cmd --permanent --add-port="${SSH_PORT_EXTRA}/tcp"
            for port in $TCP_PORTS_EXTRA; do [ -n "$port" ] && firewall-cmd --permanent --add-port="${port}/tcp"; done
            for port in $UDP_PORTS_EXTRA; do [ -n "$port" ] && firewall-cmd --permanent --add-port="${port}/udp"; done
            firewall-cmd --reload
            ;;
        alpine)
            [ -n "$SSH_PORT_EXTRA" ] && iptables -A INPUT -p tcp --dport "${SSH_PORT_EXTRA}" -j ACCEPT
            for port in $TCP_PORTS_EXTRA; do [ -n "$port" ] && iptables -A INPUT -p tcp --dport "$port" -j ACCEPT; done
            for port in $UDP_PORTS_EXTRA; do [ -n "$port" ] && iptables -A INPUT -p udp --dport "$port" -j ACCEPT; done
            /etc/init.d/iptables save
            ;;
    esac
    echo "✅ 防火墙配置完成（含系统默认规则 + 你的自定义端口）"
    show_status
}

# ================= 开/关端口（保留原功能，用于后续追加/删除端口） =================
open_ports() {
    detect_os
    echo "请输入要开放的端口（多个端口用空格分隔）:"
    read -r PORTS
    echo "请选择协议类型：1) TCP 2) UDP 3) TCP和UDP"
    read -r proto_choice

    [ -z "$PORTS" ] && { echo "❌ 未输入端口"; return; }

    for port in $PORTS; do
        case "$proto_choice" in
            1) protos=("tcp") ;;
            2) protos=("udp") ;;
            3) protos=("tcp" "udp") ;;
            *) echo "❌ 无效协议选项"; return ;;
        esac

        for proto in "${protos[@]}"; do
            case "$OS" in
                ubuntu|debian)
                    ufw allow "${port}/${proto}" || echo "⚠️ 添加失败: $port/$proto"
                    ;;
                centos)
                    firewall-cmd --permanent --add-port="${port}/${proto}" || echo "⚠️ 添加失败: $port/$proto"
                    ;;
                alpine)
                    iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
                    ;;
            esac
        done
    done

    [[ "$OS" == "centos" ]] && firewall-cmd --reload
    [[ "$OS" == "alpine" ]] && /etc/init.d/iptables save

    echo "✅ 已成功开放端口"
    show_status
}

close_ports() {
    detect_os
    echo "请输入要关闭的端口（多个端口用空格分隔）:"
    read -r PORTS
    echo "请选择协议类型：1) TCP 2) UDP 3) TCP和UDP"
    read -r proto_choice

    [ -z "$PORTS" ] && { echo "❌ 未输入端口"; return; }

    for port in $PORTS; do
        case "$proto_choice" in
            1) protos=("tcp") ;;
            2) protos=("udp") ;;
            3) protos=("tcp" "udp") ;;
            *) echo "❌ 无效协议选项"; return ;;
        esac

        for proto in "${protos[@]}"; do
            case "$OS" in
                ubuntu|debian)
                    ufw delete allow "${port}/${proto}" || echo "⚠️ 删除失败: $port/$proto"
                    ;;
                centos)
                    firewall-cmd --permanent --remove-port="${port}/${proto}" || echo "⚠️ 删除失败: $port/$proto"
                    ;;
                alpine)
                    iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
                    ;;
            esac
        done
    done

    [[ "$OS" == "centos" ]] && firewall-cmd --reload
    [[ "$OS" == "alpine" ]] && /etc/init.d/iptables save

    echo "✅ 已成功关闭端口"
    show_status
}

# ================= 备份/恢复/卸载（保留原功能，确保备份包含默认规则） =================
backup_firewall() {
    detect_os
    local BACKUP_FILE="$BACKUP_DIR/fw_backup_$(date +%F_%H-%M-%S)"

    case "$OS" in
        ubuntu|debian)
            echo "# UFW rules backup (含系统默认规则)" > "$BACKUP_FILE.rules"
            ufw status numbered | grep '\[ [0-9]\+\]' | sed 's/\[.*\]//g' >> "$BACKUP_FILE.rules"
            ;;
        centos)
            tar czf "$BACKUP_FILE.tar.gz" /etc/firewalld
            ;;
        alpine)
            iptables-save > "$BACKUP_FILE.txt"
            ;;
    esac

    echo "✅ 防火墙已备份到 $BACKUP_FILE（含系统默认规则）"
}

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
            echo "恢复 UFW 配置（含系统默认规则）..."
            ufw --force disable
            ufw reset

            while read -r rule; do
                rule="$(echo "$rule" | sed 's/^[ \t]*//;s/[ \t]*$//')"
                [[ -z "$rule" || "$rule" =~ ^# ]] && continue
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

# ================= 强制关闭/恢复端口（保留原功能） =================
FORCED_CLOSE_FILE="$BACKUP_DIR/forced_closed_ports.txt"

force_close_ports() {
    detect_os
    echo "请输入要强制关闭的端口 (空格分隔):"
    read -r PORTS
    [ -z "$PORTS" ] && { echo "❌ 未输入端口"; return; }

    echo "请选择协议类型:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP 和 UDP"
    read -r proto_opt
    case "$proto_opt" in
        1) PROTO="tcp" ;;
        2) PROTO="udp" ;;
        3) PROTO="both" ;;
        *) echo "❌ 无效选择"; return ;;
    esac

    for port in $PORTS; do
        case "$PROTO" in
            tcp)
                close_single_port "$port" tcp
                ;;
            udp)
                close_single_port "$port" udp
                ;;
            both)
                close_single_port "$port" tcp
                close_single_port "$port" udp
                ;;
        esac
    done

    echo "✅ 强制关闭完成"
    show_status
}

close_single_port() {
    local port=$1
    local proto=$2

    case "$OS" in
        ubuntu|debian)
            ufw delete allow "${port}/${proto}" || true
            ;;
        centos)
            firewall-cmd --permanent --remove-port="${port}/${proto}" || true
            ;;
        alpine)
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT || true
            ;;
    esac

    mkdir -p "$BACKUP_DIR"
    echo "$port/$proto" >> "$FORCED_CLOSE_FILE"
}

restore_forced_closed_ports() {
    detect_os
    if [ ! -f "$FORCED_CLOSE_FILE" ]; then
        echo "❌ 没有发现被强制关闭的端口记录"
        return
    fi

    echo "即将恢复以下被强制关闭的端口："
    cat "$FORCED_CLOSE_FILE"
    echo "是否继续？(Y/n)"
    read -r confirm
    confirm="${confirm:-y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "❌ 已取消恢复"
        return
    fi

    while read -r line; do
        port=$(echo "$line" | cut -d'/' -f1)
        proto=$(echo "$line" | cut -d'/' -f2)

        case "$OS" in
            ubuntu|debian)
                ufw allow "${port}/${proto}" || true
                ;;
            centos)
                firewall-cmd --permanent --add-port="${port}/${proto}" || true
                ;;
            alpine)
                iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT || true
                ;;
        esac
    done < "$FORCED_CLOSE_FILE"

    case "$OS" in
        centos) firewall-cmd --reload ;;
        alpine) /etc/init.d/iptables save ;;
    esac

    rm -f "$FORCED_CLOSE_FILE"
    echo "✅ 已恢复强制关闭的端口"
    show_status
}

# ================= 菜单（保留原功能，逻辑不变） =================
main_menu() {
    while true; do
        clear
        show_firewall_policies
        echo "====== 防火墙管理面板 ======"
        echo "1) 显示防火墙状态"
        echo "2) 启用防火墙（自动应用系统默认规则）"
        echo "3) 禁用防火墙"
        echo "4) 配置端口（默认规则 + 自定义端口）"
        echo "5) 关闭端口"
        echo "6) 开启端口"
        echo "7) 备份当前防火墙"
        echo "8) 恢复防火墙"
        echo "9) 卸载脚本"
        echo "10) 强制关闭端口（支持 TCP/UDP/tcp+udp）"
        echo "11) 恢复强制关闭的端口"
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
            10) force_close_ports; read -rp "按回车继续..." ;;
			11) restore_forced_closed_ports; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

top_menu() {
    while true; do
        clear
        echo "====== 防火墙脚本菜单 ======"
        echo "1) 打开防火墙控制面板（并自动启用防火墙+默认规则）"
        echo "2) 卸载脚本"
        echo "3) 只打开防火墙控制面板（不启用防火墙）"
        echo "0) 退出"
        echo -n "请输入选项 [默认: 3]: "
        read -r choice

        if [[ -z "$choice" ]]; then
            choice=3
        fi

        case "$choice" in
            1)
                enable_firewall
                main_menu
                ;;
            2)
                uninstall
                ;;
            3)
                main_menu
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效输入，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# ================= 脚本主函数 =================
main() {
    detect_os
    check_dependencies
    backup_initial_firewall
	
    if [ ! -L "$SCRIPT_PATH" ]; then
        echo "🔗 正在创建软连接 $SCRIPT_PATH -> $ORIGINAL_SCRIPT_PATH"
        ln -sf "$ORIGINAL_SCRIPT_PATH" "$SCRIPT_PATH"
        echo "✅ 软连接创建成功，可以通过命令 'fw' 运行脚本"
    fi

    top_menu
}

main "$@"
