#!/bin/bash
set -e

echo "📦 安装依赖"
apt update
apt install -y curl wget unzip qrencode

echo "⬇️ 下载 Xray-core"
mkdir -p /usr/local/etc/xray
cd /usr/local/bin
wget -qO xray https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip Xray-linux-64.zip && rm Xray-linux-64.zip
chmod +x xray

echo "🔧 生成配置参数"
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=$((RANDOM % 10000 + 10000))
PBK=$(xray x25519 | grep 'Public key' | awk '{print $4}')
SBK=$(xray x25519 | grep 'Secret key' | awk '{print $4}')
SNI="www.cloudflare.com"
SHORT_ID=$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)

echo "📄 写入配置文件"
cat <<EOF > /usr/local/etc/xray/config.json
{
  "inbounds": [
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
          "dest": "www.cloudflare.com:443",
          "xver": 0,
          "serverNames": [
            "www.cloudflare.com"
          ],
          "privateKey": "$SBK",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

echo "🛠️ 写入 systemd 服务"
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 启动服务"
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

echo "✅ 部署完成"
echo
echo "▶️ Reality 节点链接如下："
echo "vless://$UUID@$(curl -s ipv4.ip.sb):$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PBK&sid=$SHORT_ID&type=tcp#RealityNode"
