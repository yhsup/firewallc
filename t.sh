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
    local answer=""  # 关键1：显式初始化answer变量，避免未定义（解决第76行报错核心）

    if [ ! -f "$FIRST_RUN_FLAG" ]; then
        echo "⚠️ 检测到第一次运行防火墙脚本，是否备份当前防火墙为初始配置？(Y/n，回车默认选择Y)"
        # 关键2：检查read命令是否成功（避免无终端交互时read卡住/失败）
        if read -r answer; then
            # 第76行：此时answer已初始化，即使为空也不会报错
            answer="${answer:-y}"  
        else
            # 若read失败（如非交互式运行），强制默认y，避免脚本中断
            answer="y"
            echo "ℹ️ 未检测到终端交互，默认选择备份（answer=y）"
        fi

        # 后续备份逻辑不变...
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
            # 1. 重置基础规则 + 同步 UFW 服务状态
            ufw --force reset
            ufw default deny incoming
            ufw default allow outgoing
            systemctl restart ufw
            ufw --force enable

            # 2. 修复：严格添加 Ping 规则（防重复+固定格式）
            local ICMP_RULE="-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT"  # 固定格式，无多余空格
            local RULE_FILE="/etc/ufw/before.rules"
            local RULE_MARKER="ufw-before-input -p icmp --icmp-type echo-request"  # 简化匹配标记，避免漏检

            # 严格检查：是否已存在相同规则（用标记匹配，避免完全字符串漏检）
            if ! grep -qF "$RULE_MARKER" "$RULE_FILE" 2>/dev/null; then
                # 只插入到 ufw-before-input 链的默认规则之后（更精准，避免插错位置）
                # 找到 "-A ufw-before-input -m conntrack..." 行，在它后面插入 Ping 规则
                sed -i '/-A ufw-before-input -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT/a '"$ICMP_RULE"'' "$RULE_FILE"
                echo "✅ 已添加 Ping 规则到 ufw-before-input 链（仅1条）"
                ufw reload
            else
                echo "ℹ️ Ping 规则已存在，无需重复添加"
            fi

            # 3. 开放默认端口 + 回环接口（保持不变）
            ufw allow in on lo
            for port in $DEFAULT_TCP_PORTS; do ufw allow "${port}/tcp"; done
            for port in $DEFAULT_UDP_PORTS; do ufw allow "${port}/udp"; done
            ;;
        # CentOS/Alpine 部分保持不变，无需修改
        centos)
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
    echo "✅ 系统默认规则应用完成（已开放：SSH/22、DNS/53、HTTP/80、HTTPS/443 + Ping + 基础通信）"
}

# ================= 防火墙状态 =================
show_status() {
    detect_os
    echo "===== 防火墙状态及开放端口（${OS^^} 系统专属） ====="
    case "$OS" in
        ubuntu|debian)
            echo "【1. UFW 服务状态及开放规则】"
            # 第一步：用 systemctl 判断服务是否真的在运行（核心修复）
            if systemctl is-active --quiet ufw; then
                # 第二步：服务运行，再检查规则是否启用
                if ufw status | grep -qi "active"; then
                    local ufw_allow=$(ufw status numbered | grep -i "allow")
                    [[ -z "$ufw_allow" ]] && echo "❌ 未检测到任何开放的端口规则" || echo "$ufw_allow"
                else
                    echo "⚠️ UFW 服务已运行，但规则未启用，正在尝试启用..."
                    ufw --force enable
                    ufw reload
                    # 重新显示规则
                    local ufw_allow=$(ufw status numbered | grep -i "allow")
                    [[ -z "$ufw_allow" ]] && echo "❌ 规则启用后仍未检测到开放端口" || echo "$ufw_allow"
                fi
            else
                # 服务未运行，提示并尝试启动
                echo "⚠️ UFW 服务未运行，正在尝试启动..."
                systemctl start ufw
                ufw --force enable
                if systemctl is-active --quiet ufw; then
                    echo "✅ UFW 服务已启动，规则已启用"
                    local ufw_allow=$(ufw status numbered | grep -i "allow")
                    [[ -z "$ufw_allow" ]] && echo "❌ 未检测到开放端口规则" || echo "$ufw_allow"
                else
                    echo "❌ UFW 服务启动失败，请手动执行 'sudo systemctl start ufw' 修复"
                fi
            fi

            echo -e "\n【2. UFW 默认策略】"
            ufw status verbose | grep -i "default:" 2>/dev/null || echo "⚠️ 无法获取默认策略，UFW 状态异常"
            ;;
        # CentOS/Alpine 部分保持不变，无需修改
        centos)
            echo "【1. firewalld 服务状态及配置】"
            if systemctl is-active --quiet firewalld; then
                firewall-cmd --list-all
                echo -e "\n【2. firewalld 永久开放端口】"
                local fw_perm_ports=$(firewall-cmd --permanent --list-ports)
                [[ -z "$fw_perm_ports" ]] && echo "❌ 未检测到永久开放端口" || echo "$fw_perm_ports"
            else
                echo "⚠️ firewalld 未运行，正在启动..."
                systemctl start firewalld
                firewall-cmd --list-all || echo "❌ firewalld 启动失败，请手动修复"
            fi
            ;;
        alpine)
            echo "【1. iptables 服务状态及入站规则】"
            if /etc/init.d/iptables status | grep -qi "running"; then
                local ipt_allow=$(iptables -L INPUT -n -v | grep -E "ACCEPT.*(tcp|udp)" | grep -E "dpt:[0-9]+")
                [[ -z "$ipt_allow" ]] && echo "❌ 未检测到开放端口规则" || echo "$ipt_allow"
            else
                echo "⚠️ iptables 未运行，正在启动..."
                /etc/init.d/iptables start
                local ipt_allow=$(iptables -L INPUT -n -v | grep -E "ACCEPT.*(tcp|udp)" | grep -E "dpt:[0-9]+")
                [[ -z "$ipt_allow" ]] && echo "❌ 启动后仍未检测到开放规则" || echo "$ipt_allow"
            fi
            echo -e "\n【2. iptables 默认策略】"
            iptables -L | grep -E "Chain INPUT|Chain OUTPUT" | awk '{print $1, $2, $3, $4}'
            ;;
    esac

    # 通用：显示系统监听端口（保持不变）
    echo -e "\n【3. 系统当前监听的端口】"
    local ss_result=$(ss -tuln 2>/dev/null | awk '
        NR > 1 {
            proto = $1; port = $5
            if (proto ~ /tcp/) {gsub(".*:", "", port); print port "/tcp (监听中)"}
            else if (proto ~ /udp/) {gsub(".*:", "", port); print port "/udp (监听中)"}
        }
    ' | sort -u)
    [[ -z "$ss_result" ]] && echo "⚠️ 未检测到程序监听的端口" || echo "$ss_result"
}

# ================= 显示入站/出站默认策略 =================
show_firewall_policies() {
    detect_os
    echo "===== 防火墙默认策略（入站 / 出站） ====="
    case "$OS" in
        ubuntu|debian)
            # 简化：直接读取 UFW 默认策略，避免复杂 sed 解析导致阻塞
            local ufw_status=$(ufw status verbose 2>/dev/null)
            # 提取入站策略（Default: 后的第一个词）
            local in_policy=$(echo "$ufw_status" | grep -i "Default:" | awk '{print $2}')
            # 提取出站策略（Default: 后的第三个词）
            local out_policy=$(echo "$ufw_status" | grep -i "Default:" | awk '{print $4}')
            # 若提取失败，显示默认值
            in_policy=${in_policy:-"deny (默认拒绝)"}
            out_policy=${out_policy:-"allow (默认允许)"}
            echo "入站默认策略 (INPUT): $in_policy"
            echo "出站默认策略 (OUTPUT): $out_policy"
            ;;
        centos)
            # 保持不变，无需修改
            echo "入站默认策略 (INPUT): firewalld 默认通过服务/端口控制，未定义规则默认拒绝"
            echo "出站默认策略 (OUTPUT): 默认允许所有流量"
            ;;
        alpine)
            # 简化：直接读取 iptables 默认策略
            local in_policy=$(iptables -L INPUT -n | grep "Chain INPUT" | awk '{print $4}')
            local out_policy=$(iptables -L OUTPUT -n | grep "Chain OUTPUT" | awk '{print $4}')
            in_policy=${in_policy:-"DROP (默认拒绝)"}
            out_policy=${out_policy:-"ACCEPT (默认允许)"}
            echo "入站默认策略 (INPUT): $in_policy"
            echo "出站默认策略 (OUTPUT): $out_policy"
            ;;
        *)
            echo "未知系统，无法显示默认策略"
            ;;
    esac
    # 新增：强制输出换行，避免和后续菜单粘连
    echo ""
}

# ================= 启用/禁用防火墙（修改：启用时自动应用默认规则） =================
enable_firewall() {
    detect_os
    echo "🔌 正在启用防火墙并应用系统默认规则..."
    case "$OS" in
        ubuntu|debian)
            # 关键：先重启服务，再启用规则，避免服务状态异常
            systemctl restart ufw  # 强制重启 UFW 服务
            ufw --force enable      # 启用 UFW 规则
            ufw reload              # 重载规则，确保默认规则生效
            ;;
        centos)
            systemctl start firewalld
            systemctl enable firewalld  # 确保开机自启
            ;;
        alpine)
            /etc/init.d/iptables start
            rc-update add iptables default  # 开机自启
            ;;
    esac
    apply_default_rules  # 应用默认规则
    echo "✅ 防火墙已启用（含系统默认规则）"
    show_status
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
    local port_valid=1
    local target_port=""  # 明确端口变量
    local target_proto="" # 明确协议变量

    # Ubuntu/Debian 先确认 UFW 已启用（root 权限下）
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        if ! ufw status | grep -qi "active"; then
            echo "⚠️ UFW 未启用，正在自动启用..."
            ufw --force enable
            ufw reload
        fi
    fi

    # 1. 输入端口并严格校验（避免空值/非法值）
    echo "请输入要开放的端口（单个端口，例：8080；多个用空格分隔，例：8080 9090）:"
    read -r PORTS
    if [ -z "$PORTS" ]; then
        echo "❌ 未输入端口，操作终止"; return;
    fi
    # 校验每个端口是否为 1-65535 的纯数字
    for port in $PORTS; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo "⚠️ 端口 '$port' 无效（需1-65535纯数字），已跳过"; port_valid=0;
        fi
    done
    [[ $port_valid -eq 0 ]] && echo "ℹ️ 仅处理有效端口"

    # 2. 选择协议并明确赋值（避免协议变量为空）
    echo "请选择协议类型：1) TCP 2) UDP 3) TCP和UDP"
    read -r proto_choice
    case "$proto_choice" in
        1) protos=("tcp") ;;
        2) protos=("udp") ;;
        3) protos=("tcp" "udp") ;;
        *) echo "❌ 无效协议（仅1/2/3），操作终止"; return ;;
    esac

    # 3. 核心：拼接 UFW 命令并显示（方便排查错误）
    echo -e "\n===== 开始添加端口规则（root 权限） ====="
    for port in $PORTS; do
        # 跳过无效端口
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then continue; fi
        
        for proto in "${protos[@]}"; do
            target_port="$port"
            target_proto="$proto"
            # 关键：显示要执行的 UFW 命令（便于调试，比如看是否拼接成“ufw allow 8080/tcp”）
            echo "ℹ️ 即将执行命令：ufw allow ${target_port}/${target_proto}"
            
            # 执行 UFW 命令（root 权限下无需 sudo）
            if ufw allow "${target_port}/${target_proto}"; then
                echo "✅ 成功添加：${target_port}/${target_proto}"
            else
                # 失败时进一步排查：显示 UFW 错误日志（关键！看系统层面的失败原因）
                echo "❌ 失败！系统错误日志（最近10行）："
                journalctl -u ufw -n 10 --no-pager  # 查看 UFW 服务的错误日志
            fi
        done
    done
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
    # 1. 显式初始化变量（避免未定义报错，与 backup_initial_firewall 逻辑一致）
    detect_os
    local BACKUP_DIR="$HOME/fw_backup"  # 与初始备份共用目录，统一管理
    local TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)  # 时间戳区分备份版本
    local answer=""  # 交互选择变量
    local BACKUP_PATH=""  # 最终备份文件路径
    local BACKUP_SUFFIX=""  # 按系统区分文件后缀（rules/tar.gz/txt）

    # 2. 交互确认：询问是否执行备份（容错非交互式场景）
    echo "⚠️ 即将执行防火墙规则备份，备份文件将保存在 $BACKUP_DIR/ 下，是否继续？(Y/n，回车默认选择Y)"
    if read -r answer; then
        answer="${answer:-y}"  # 用户未输入时默认Y
    else
        # 非交互式运行（如脚本管道/后台执行），强制默认备份，避免中断
        answer="y"
        echo "ℹ️ 未检测到终端交互，默认执行备份（answer=y）"
    fi

    # 3. 确认备份后，分系统执行备份逻辑（格式与初始备份统一，便于恢复）
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        # 确保备份目录存在（避免目录不存在导致备份失败）
        mkdir -p "$BACKUP_DIR"

        case "$OS" in
            # Ubuntu/Debian：备份 UFW 规则（单行命令无反斜杠，规则带ufw前缀）
            ubuntu|debian)
                BACKUP_SUFFIX="rules"
                BACKUP_PATH="${BACKUP_DIR}/fw_backup_${TIMESTAMP}.${BACKUP_SUFFIX}"
                
                # 写入备份注释（含恢复方式提示）
                echo "# UFW manual backup (${TIMESTAMP})" > "${BACKUP_PATH}"
                echo "# 恢复方式：bash ${BACKUP_PATH}" >> "${BACKUP_PATH}"
                
                # 单行管道命令（无反斜杠，避免语法错）：过滤→清理→生成可执行规则
                ufw status numbered | grep '\[ [0-9]\+\]' | grep -E 'tcp|udp' | sed 's/\[.*\]//g; s/^[ \t]*//; s/ (v6)//g' | awk '{print "ufw allow", $1}' >> "${BACKUP_PATH}"

                # IPv6 规则（同样单行命令，带ufw前缀）
                echo "# IPv6 规则" >> "${BACKUP_PATH}"
                ufw status numbered | grep '\[ [0-9]\+\]' | grep -i "v6" | grep -E 'tcp|udp' | sed 's/\[.*\]//g; s/^[ \t]*//; s/ (v6)//g' | awk '{print "ufw allow", $1, "ipv6"}' >> "${BACKUP_PATH}"
                ;;

            # CentOS：备份 firewalld 配置目录（压缩存储，避免冗余）
            centos)
                BACKUP_SUFFIX="tar.gz"
                BACKUP_PATH="${BACKUP_DIR}/fw_backup_${TIMESTAMP}.${BACKUP_SUFFIX}"
                # 压缩 /etc/firewalld 目录，排除日志文件
                tar -zcf "${BACKUP_PATH}" /etc/firewalld/ --exclude='*.log'
                ;;

            # Alpine：备份 iptables 规则（标准 save 格式，与初始备份一致）
            alpine)
                BACKUP_SUFFIX="txt"
                BACKUP_PATH="${BACKUP_DIR}/fw_backup_${TIMESTAMP}.${BACKUP_SUFFIX}"
                # 用 iptables-save 生成标准可恢复规则
                iptables-save > "${BACKUP_PATH}"
                ;;
        esac

        # 4. 备份结果验证（检查文件存在+非空，显示关键信息）
        if [ -f "${BACKUP_PATH}" ] && [ -s "${BACKUP_PATH}" ]; then
            # 统计有效规则数（Ubuntu/Debian 专属，其他系统显示文件大小）
            if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
                local valid_rule_count=$(grep -c '^ufw allow' "${BACKUP_PATH}")
                echo -e "\n✅ 手动备份成功！"
                echo "📁 备份文件：${BACKUP_PATH}"
                echo "📄 有效规则数：${valid_rule_count} 条"
                echo -e "\n🔍 规则预览（前3条有效命令）："
                grep '^ufw allow' "${BACKUP_PATH}" | head -3
            else
                echo -e "\n✅ 手动备份成功！"
                echo "📁 备份文件：${BACKUP_PATH}"
                echo "📄 文件大小：$(du -sh "${BACKUP_PATH}" | awk '{print $1}')"
            fi
        else
            echo -e "\n❌ 手动备份失败！文件为空或未创建"
            # 清理无效空文件，避免残留
            [ -f "${BACKUP_PATH}" ] && rm -f "${BACKUP_PATH}"
        fi
    else
        echo -e "\n❌ 已取消手动备份"
    fi
}

restore_firewall() {
    detect_os
    local BACKUP_LIST=()
    local SELECTED_BACKUP=""

    # 1. 列出可用备份（按系统区分）
    echo "可用备份列表："
    case "$OS" in
        ubuntu|debian)
            BACKUP_LIST=($(ls -1 "$BACKUP_DIR"/*.rules 2>/dev/null | sort -r))
            ;;
        centos)
            BACKUP_LIST=($(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | sort -r))
            ;;
        alpine)
            BACKUP_LIST=($(ls -1 "$BACKUP_DIR"/*.txt 2>/dev/null | sort -r))
            ;;
    esac

    if [ ${#BACKUP_LIST[@]} -eq 0 ]; then
        echo "❌ 未检测到任何备份文件"
        return
    fi

    # 显示备份列表并选择
    for i in "${!BACKUP_LIST[@]}"; do
        echo "$((i+1))) $(basename "${BACKUP_LIST[$i]}")"
    done
    read -p "请输入要恢复的备份编号: " NUM
    SELECTED_BACKUP="${BACKUP_LIST[$((NUM-1))]}"
    [ -z "$SELECTED_BACKUP" ] && { echo "❌ 无效编号"; return; }

    # 2. 执行恢复（核心优化：Ubuntu/Debian 分支过滤无效行）
    echo -e "\n⚙️ 正在恢复备份：$(basename "$SELECTED_BACKUP")"
    case "$OS" in
        ubuntu|debian)
            echo "恢复 UFW 配置（仅执行有效规则，跳过注释/空行）..."
            # 先重置 UFW（清除当前规则，避免冲突）
            ufw --force reset

            # 核心优化：过滤无效行，只执行完整规则
            # 规则：1. 跳过注释行（^#）；2. 跳过空行（^$）；3. 只保留含“ufw allow/deny”且有端口的行（避免残缺）
            grep -v '^#\|^$' "$SELECTED_BACKUP" | \
                grep -E '^ufw allow|^ufw deny' | \
                grep -E 'tcp|udp' | \
                while read -r rule; do
                    echo "ℹ️ 执行规则：$rule"
                    # 执行有效规则，忽略个别失败（避免一条错全停）
                    if ! $rule; then
                        echo "⚠️ 规则执行失败（可能已存在）：$rule"
                    fi
                done

            # 启用 UFW 并验证
            ufw --force enable
            echo "✅ UFW 恢复完成（已跳过无效/重复规则）"
            ;;

        # CentOS/Alpine 部分不变（原逻辑无问题）
        centos)
            echo "恢复 firewalld 配置..."
            systemctl stop firewalld
            rm -rf /etc/firewalld/
            tar -zxf "$SELECTED_BACKUP" -C /
            systemctl start firewalld
            echo "✅ firewalld 恢复成功"
            ;;
        alpine)
            echo "恢复 iptables 配置..."
            iptables-restore < "$SELECTED_BACKUP"
            /etc/init.d/iptables save
            echo "✅ iptables 恢复成功"
            ;;
    esac

    # 显示恢复后状态
    echo -e "\n恢复后防火墙状态："
    show_status
}

uninstall() {
    echo "确认卸载防火墙脚本？(y/n)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        detect_os
        local INITIAL_BACKUP="$BACKUP_DIR/initial_firewall_backup"
        local ufw_reset_flag=0  # 标记是否需要后续执行UFW重置

        # ================= 1. 恢复初始配置（保留原逻辑，新增UFW重置判断） =================
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
                            # 恢复备份的规则
                            while read -r rule; do
                                rule="$(echo "$rule" | sed 's/^[ \t]*//;s/[ \t]*$//')"
                                [[ -z "$rule" || "$rule" =~ ^# ]] && continue
                                ufw $rule || echo "⚠️ 执行失败: ufw $rule"
                            done < "${INITIAL_BACKUP}.rules"
                            ufw --force enable
                            echo "✅ UFW 已恢复初始配置"
                            ufw_reset_flag=1  # 已恢复备份，无需后续重置
                        else
                            echo "❌ 找不到 UFW 备份文件，标记为需要后续重置"
                            ufw_reset_flag=0
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
                echo "跳过恢复初始配置，标记为需要后续清理"
                ufw_reset_flag=0
            fi
        else
            echo "未找到初始防火墙备份，标记为需要后续清理"
            ufw_reset_flag=0
        fi

        # ================= 2. 针对Ubuntu/Debian：无备份时强制重置UFW（新增核心逻辑） =================
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]] && [[ $ufw_reset_flag -eq 0 ]]; then
            echo "⚙️ 开始重置 UFW 到系统默认状态（清除所有自定义规则）..."
            ufw --force reset  # 强制重置UFW（清除所有规则）
            ufw disable        # 禁用UFW（避免残留开机启动）
            echo "✅ UFW 已重置并禁用，恢复到系统初始状态"
        fi

        # ================= 3. 清理文件：明确删除软链接fw + 备份 + 标志文件 =================
        echo "🧹 正在删除所有防火墙备份文件..."
        rm -rf "$BACKUP_DIR"

        echo "🗑️ 正在删除软链接（/usr/local/bin/fw）..."
        rm -f "$SCRIPT_PATH"  # $SCRIPT_PATH即/usr/local/bin/fw，确保删除软链接

        echo "🗑️ 正在删除脚本运行标志文件..."
        rm -f "$FIRST_RUN_FLAG"

        echo "✅ 防火墙脚本卸载完成！状态说明："
        # 卸载后状态提示（增强用户感知）
        case "$OS" in
            ubuntu|debian) echo " - UFW：已重置并禁用（无残留规则）" ;;
            centos) echo " - firewalld：保持恢复后的初始状态（或原系统状态）" ;;
            alpine) echo " - iptables：保持恢复后的初始状态（或原系统状态）" ;;
        esac
        echo " - 软链接：/usr/local/bin/fw 已删除（后续无法通过fw命令运行脚本）"
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

# ================= 主菜单（修复：调整显示顺序，确保菜单优先加载） =================
main_menu() {
    while true; do
        # 1. 先清屏（避免残留输出干扰）
        clear
        # 2. 先显示主菜单标题和选项（确保用户能看到菜单）
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
        echo ""  # 换行分隔
        # 3. 再显示防火墙默认策略（避免策略显示阻塞菜单）
        show_firewall_policies
        # 4. 最后提示输入选项（确保焦点在输入上）
        echo -n "请输入选项: "
        read -r opt
        # 5. 选项逻辑（保持不变）
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
            *) echo "无效输入，1秒后重新显示菜单..."; sleep 1 ;;
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
