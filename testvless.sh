#!/bin/bash
set -e

# --- 脚本配置 ---
# 为 REALITY 设置一个真实、可访问的目标网站（伪装目标）
# 您可以根据需要更改为其他网站，如 "www.microsoft.com"
DECOY_DOMAIN="www.google.com"

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

echo "🔧 更新系统并安装依赖..."
apt update -y
apt install -y curl socat openssl iptables-persistent unzip

echo "🔧 下载最新 Xray..."
# 如果遇到网络问题，可以手动替换下面的下载链接
curl -Lo /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip -d /usr/local/bin/
rm -f /tmp/xray.zip
chmod +x $XRAY_BIN

echo "🔧 生成10个UUID、privateKey和shortIds..."
declare -a UUIDS
declare -a PRIVATE_KEYS
declare -a SHORTID1S
declare -a SHORTID2S

for i in {0..9}; do
  UUIDS[$i]=$(cat /proc/sys/kernel/random/uuid)
  # Xray 1.8.1+ a private key with a length of 32 bytes (64 hex characters) is required
  PRIVATE_KEYS[$i]=$($XRAY_BIN x25519 | awk 'NR==1 {print $3}')
  SHORTID1S[$i]=$(openssl rand -hex 8)
  SHORTID2S[$i]=$(openssl rand -hex 8)
done

echo "🔧 创建日志目录并授权..."
mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray

echo "🔧 生成 Xray 配置文件..."
cat > $CONFIG_PATH <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
EOF

for i in {0..9}; do
  PORT=$((BASE_PORT + i*1000))
  UUID=${UUIDS[$i]}
  PRIVATE_KEY=${PRIVATE_KEYS[$i]}
  SHORTID1=${SHORTID1S[$i]}
  SHORTID2=${SHORTID2S[$i]}
  # 追加节点配置
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
            "$SHORTID1",
            "$SHORTID2"
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

echo "🔧 创建 systemd 服务文件..."
cat > $SERVICE_PATH <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=$XRAY_BIN run -config $CONFIG_PATH
Restart=on-failure

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

echo "✅ 安装完成，Xray + 10个 Reality 节点服务已启动"
echo ""
echo "================ 节点信息 ================"
for i in {0..9}; do
  PORT=$((BASE_PORT + i*1000))
  UUID=${UUIDS[$i]}
  # 从配置文件中获取正确的公私钥对
  KEYS=$($XRAY_BIN x25519)
  PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key/ {print $3}')
  PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key/ {print $3}')
  SHORTID1=${SHORTID1S[$i]}
  
  echo "----------------------------------------"
  echo "节点 $((i+1)):"
  echo "端口 (Port): $PORT"
  echo "UUID: $UUID"
  echo "公钥 (pbk): $PUBLIC_KEY"
  echo "Short ID (sid): $SHORTID1"
  echo "客户端 SNI: $DOMAIN"
  echo ""
  echo "VLESS 链接 (点击复制):"
  echo "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORTID1&flow=xtls-rprx-vision#${DOMAIN}_${PORT}"
done
echo "=========================================="
echo ""
echo "重要提示："
echo "1. REALITY 的伪装目标网站已设为 $DECOY_DOMAIN。"
echo "2. 请确保您的域名 $DOMAIN 已正确解析到本服务器的 IP 地址。"
echo "3. 请务必检查您的VPS提供商（如阿里云、谷歌云）的安全组，确保端口 443, 1443, ..., 9443 已放行。"
echo "4. 如果仍然无法连接，请使用 'systemctl status xray' 或 'journalctl -u xray' 查看服务日志。"
