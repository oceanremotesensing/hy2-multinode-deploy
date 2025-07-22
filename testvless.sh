#!/bin/bash
set -e

DOMAIN="wjfreeonekeycard.top"
BASE_PORT=443
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SERVICE_PATH="/etc/systemd/system/xray.service"

echo "🔧 更新系统并安装依赖..."
apt update -y
apt install -y curl socat openssl iptables-persistent unzip

echo "🔧 下载最新 Xray..."
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
  PRIVATE_KEYS[$i]=$(openssl rand -hex 32)
  SHORTID1S[$i]=$(openssl rand -hex 8)
  SHORTID2S[$i]=$(openssl rand -hex 8)
done

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
          "dest": "$DOMAIN:$PORT",
          "xver": 0,
          "serverNames": [
            "$DOMAIN"
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

echo "节点信息如下："
for i in {0..9}; do
  PORT=$((BASE_PORT + i*1000))
  UUID=${UUIDS[$i]}
  PRIVATE_KEY=${PRIVATE_KEYS[$i]}
  SHORTID1=${SHORTID1S[$i]}
  SHORTID2=${SHORTID2S[$i]}
  echo "------------------------------"
  echo "端口: $PORT"
  echo "UUID: $UUID"
  echo "privateKey: $PRIVATE_KEY"
  echo "shortIds: $SHORTID1, $SHORTID2"
  echo "链接示例："
  echo "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PRIVATE_KEY&sid=$SHORTID1&flow=xtls-rprx-vision#$DOMAIN-$PORT"
done
