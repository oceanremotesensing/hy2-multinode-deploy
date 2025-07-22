#!/bin/bash
set -e

# --- 脚本配置 ---
DECOY_DOMAIN="www.microsoft.com"

# --- 脚本变量 ---
BASE_PORT=443
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SERVICE_PATH="/etc/systemd/system/xray.service"

# --- 交互式输入域名 ---
read -p "请输入您已正确解析到本VPS的域名: " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "错误: 域名不能为空！"
  exit 1
fi
echo "您的域名将设置为: $DOMAIN"
echo "REALITY 伪装域名为: $DECOY_DOMAIN"
echo "----------------------------------------"

echo "🔧 更新系统并安装依赖 (包含setcap工具)..."
apt update -y
apt install -y curl socat openssl iptables-persistent unzip libcap2-bin

echo "🔧 下载并安装最新 Xray..."
curl -Lo /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip -d /usr/local/bin/
rm -f /tmp/xray.zip
chmod +x $XRAY_BIN

echo "🔧 授予 Xray 绑定特权端口的能力..."
setcap 'cap_net_bind_service=+ep' $XRAY_BIN

echo "🔧 生成10组匹配的UUID和密钥对 (私钥+公钥)..."
declare -a UUIDS
declare -a PRIVATE_KEYS
declare -a PUBLIC_KEYS
declare -a SHORTIDS

# 修正后的逻辑：一次性生成并存储所有需要的密钥
for i in {0..9}; do
  UUIDS[$i]=$(cat /proc/sys/kernel/random/uuid)
  # 生成一组密钥对
  KEYS=$($XRAY_BIN x25519)
  # 将私钥和公钥分别存入数组
  PRIVATE_KEYS[$i]=$(echo "$KEYS" | awk '/Private key/ {print $3}')
  PUBLIC_KEYS[$i]=$(echo "$KEYS" | awk '/Public key/ {print $3}')
  SHORTIDS[$i]=$(openssl rand -hex 8)
done
echo "✅ 10组密钥对已生成并保存完毕。"

echo "🔧 创建日志目录并授权..."
mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray

echo "🔧 生成 Xray 配置文件..."
# 清空旧文件
> $CONFIG_PATH

cat > $CONFIG_PATH <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
EOF

# 使用之前保存好的密钥写入配置
for i in {0..9}; do
  PORT=$((BASE_PORT + i*1000))
  UUID=${UUIDS[$i]}
  PRIVATE_KEY=${PRIVATE_KEYS[$i]}
  SHORTID=${SHORTIDS[$i]}
  
  cat >> $CONFIG_PATH <<EOF
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DECOY_DOMAIN:443",
          "xver": 0,
          "serverNames": [
            "$DECOY_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORTID"
          ]
        }
      }
    }$( [ $i -lt 9 ] && echo "," )
EOF
done

cat >> $CONFIG_PATH <<EOF
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    }
  ]
}
EOF
echo "✅ 配置文件已使用正确的私钥生成。"

echo "🔧 设置配置文件权限..."
chown nobody:nogroup $CONFIG_PATH
chmod 644 $CONFIG_PATH

echo "🔧 创建 systemd 服务文件..."
cat > $SERVICE_PATH <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=nobody
Restart=on-failure
RestartSec=5s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

echo "🔧 重新加载 systemd，启动并启用 Xray 服务..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

echo "🔧 放行防火墙端口..."
for i in {0..9}; do
  PORT=$((BASE_PORT + i*1000))
  iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
done
netfilter-persistent save

echo "⏳ 等待服务启动并进行最终状态检查..."
sleep 3
# 最终检查服务状态，如果失败则显示日志
systemctl status xray --no-pager || (journalctl -u xray -n 20 && exit 1)

echo ""
echo "✅ 安装完成！下面是您【正确】的节点信息："
echo "==================================================="
# 使用之前保存好的、与配置文件匹配的公钥生成链接
for i in {0..9}; do
  PORT=$((BASE_PORT + i*1000))
  UUID=${UUIDS[$i]}
  PUBLIC_KEY=${PUBLIC_KEYS[$i]}
  SHORTID=${SHORTIDS[$i]}
  
  echo "----------------------------------------"
  echo "节点 $((i+1)):"
  echo "地址 (Address): $DOMAIN"
  echo "端口 (Port): $PORT"
  echo "UUID: $UUID"
  echo "公钥 (pbk): $PUBLIC_KEY"
  echo "Short ID (sid): $SHORTID"
  echo ""
  echo "VLESS 链接 (点击复制):"
  echo "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORTID&flow=xtls-rprx-vision#${DOMAIN}_${PORT}"
done
echo "==================================================="
echo ""
echo "重要提示："
echo "1. 请务必使用上面新生成的链接，旧的链接已全部失效！"
echo "2. 如果运行此脚本后还不能连接，问题将 100% 在于【VPS提供商的防火墙/安全组】，请务必检查并放行端口 443, 1443, 等。"
