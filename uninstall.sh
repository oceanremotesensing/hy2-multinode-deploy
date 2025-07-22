#!/bin/bash

# --- 安全确认 ---
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!! 警告：此脚本将彻底卸载 Xray 及其所有相关配置 !!!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "将执行以下操作:"
echo "  - 停止并删除 Xray 服务"
echo "  - 删除 /usr/local/bin/xray 程序文件"
echo "  - 删除 /usr/local/etc/xray 整个配置和证书目录"
echo "  - 删除 /var/log/xray 日志目录"
echo "  - 删除防火墙规则"
echo "  - 卸载 acme.sh"
echo "  - 卸载 Nginx"
echo ""
read -p "此操作不可恢复，您确定要继续吗？ [请输入 y 确认]: " response

if [[ "$response" != "y" ]]; then
    echo "操作已取消。"
    exit 1
fi

echo "✅ 操作已确认，开始执行清理..."
echo "----------------------------------------"

# 1. 停止并禁用 Xray 服务
echo "🔧 正在停止并禁用 Xray 服务..."
systemctl stop xray > /dev/null 2>&1
systemctl disable xray > /dev/null 2>&1
echo "✅ Xray 服务已停止并禁用。"

# 2. 删除 Xray 相关文件和目录
echo "🔧 正在删除 Xray 文件和目录..."
rm -f /etc/systemd/system/xray.service
rm -f /usr/local/bin/xray
rm -rf /usr/local/etc/xray
rm -rf /var/log/xray
echo "✅ Xray 文件和目录已删除。"

# 3. 重新加载 systemd
echo "🔧 正在重新加载 systemd 服务..."
systemctl daemon-reload
echo "✅ systemd 已重新加载。"

# 4. 删除防火墙规则
echo "🔧 正在删除防火墙规则 (如果存在)..."
# 循环删除之前可能添加的端口
for i in {0..9}; do
  PORT=$((443 + i*1000))
  # 忽略任何错误，因为规则可能不存在
  iptables -D INPUT -p tcp --dport $PORT -j ACCEPT > /dev/null 2>&1 || true
done
# 额外确保443被删除
iptables -D INPUT -p tcp --dport 443 -j ACCEPT > /dev/null 2>&1 || true
# 保存更改
netfilter-persistent save > /dev/null 2>&1
echo "✅ 防火墙规则已移除。"

# 5. 卸载 acme.sh
if [ -d "$HOME/.acme.sh" ]; then
    echo "🔧 正在卸载 acme.sh..."
    "$HOME/.acme.sh/acme.sh" --uninstall > /dev/null 2>&1
    rm -rf "$HOME/.acme.sh"
    echo "✅ acme.sh 已卸载。"
else
    echo "ℹ️ 未找到 acme.sh，跳过卸载。"
fi

# 6. 卸载 Nginx
if dpkg -l | grep -q "nginx"; then
    echo "🔧 正在卸载 Nginx..."
    apt-get purge --auto-remove -y nginx nginx-common > /dev/null 2>&1
    echo "✅ Nginx 已卸载。"
else
    echo "ℹ️ 未找到 Nginx，跳过卸载。"
fi

echo "----------------------------------------"
echo "🎉 清理完成！"
echo ""
echo "所有与 Xray 相关的本地配置都已被移除。"
echo "重要提醒：本脚本【没有】也【不能】修改您在 Cloudflare 上的任何设置。"
echo "您的域名解析和代理设置仍然存在，请根据需要登录 Cloudflare 官网手动管理。"
