# firewallc
防火墙控制脚本
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/yhsup/firewallc/blob/main/fw.sh))"

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

        测试版，未测试，未完善，谨慎使用
默认关闭所有入站，开启出站
输入fw快捷开启
