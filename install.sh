```bash
#!/bin/bash
# fw 脚本安装/卸载助手
# 依赖: git, curl 或 wget
set -euo pipefail

# 配置区 - 请修改为你的GitHub仓库信息
GITHUB_RAW_BASE_URL="https://github.com/yhsup/firewallc/blob/main/fw.sh"
INSTALL_DIR="/usr/local/fw"
SCRIPT_NAME="firewall.sh"
LINK_NAME="/usr/local/bin/fw"

# 检测是否为root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 下载脚本（curl/wget任选其一）
download_script() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
    else
        echo "❌ 未安装 curl 或 wget，无法下载文件"
        exit 1
    fi
}

# 安装脚本逻辑
install_fw() {
    echo "开始安装 fw 脚本..."

    # 创建安装目录
    if [ -d "$INSTALL_DIR" ]; then
        echo "检测到已有安装，备份旧版本..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}_backup_$(date +%s)"
    fi
    mkdir -p "$INSTALL_DIR"

    # 下载脚本文件
    echo "从 GitHub 下载脚本..."
    download_script "$GITHUB_RAW_BASE_URL/$SCRIPT_NAME" "$INSTALL_DIR/$SCRIPT_NAME"

    if [ ! -f "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        echo "❌ 没有找到脚本文件 $SCRIPT_NAME，安装失败"
        exit 1
    fi

    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

    # 创建软链接到/usr/local/bin/fw
    if [ -L "$LINK_NAME" ]; then
        rm -f "$LINK_NAME"
    elif [ -f "$LINK_NAME" ]; then
        echo "检测到 $LINK_NAME 是文件，请先处理后再安装"
        exit 1
    fi
    ln -s "$INSTALL_DIR/$SCRIPT_NAME" "$LINK_NAME"

    echo "✅ 安装成功！"
    echo "请输入 'fw' 命令使用防火墙管理脚本"
}

# 卸载脚本逻辑
uninstall_fw() {
    echo "开始卸载 fw 脚本..."

    if [ -f "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        echo "调用防火墙脚本卸载并恢复配置..."
        bash "$INSTALL_DIR/$SCRIPT_NAME" -uninstall || echo "⚠️ 卸载过程中恢复配置失败，请手动处理"
    else
        echo "未找到安装的防火墙脚本，跳过恢复步骤"
    fi

    # 删除软链接和安装目录
    if [ -L "$LINK_NAME" ]; then
        rm -f "$LINK_NAME"
    fi
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi

    echo "✅ 卸载完成"
}

# 主菜单
show_menu() {
    echo "====== fw 防火墙脚本安装助手 ======"
    echo "1) 安装脚本"
    echo "2) 卸载脚本"
    echo "q) 退出"
    echo -n "请选择操作: "
    read -r choice

    case "$choice" in
        1) install_fw ;;
        2) uninstall_fw ;;
        q|Q) echo "退出" ; exit 0 ;;
        *) echo "❌ 无效选项" ; exit 1 ;;
    esac
}

main() {
    check_root
    show_menu
}

main "$@"
```
