#!/bin/bash
set -euo pipefail

DOMAIN="wjfreeonekeycard.top"
FAKE_HOST="www.cloudflare.com"
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)
NODE_NAME_PREFIX="REALITY"

echo "==== 1. 清理旧 Xray 服务和配置 ===="
systemctl stop xray || true
systemctl disable xray || true
rm -f /usr/local/etc/xray/config.json
rm -f /etc/systemd/system/xray.service
rm -f /usr/local/bin/xray
systemctl daemon-reload
echo "旧服务清理完成。"

echo "==== 2. 安装必要依赖 ===="
apt update -qq
apt install -y curl unzip socat jq openssl

echo "==== 3. 安装/更新 Xray-core ===="
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

CLIENT_INFO_DIR=$(mktemp -d)
INBOUNDS_CONFIG=""

echo "==== 4. 生成配置及密钥 ===="
for i in "${!PORTS[@]}"; do
  node_index=$((i+1))
  port=${PORTS[$i]}
  echo "生成节点 $node_index : 端口 $port"

  UUID=$(xray uuid)
  KEY_PAIR=$(xray x25519)
  PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
  PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')
  SHORT_ID=$(openssl rand -hex 8)

  echo "$UUID" > "$CLIENT_INFO_DIR/node${node_index}.uuid"
  echo "$PRIVATE_KEY" > "$CLIENT_INFO_DIR/node${node_index}.priv"
  echo "$PUBLIC_KEY" > "$CLIENT_INFO_DIR/node${node_index}.pub"
  echo "$SHORT_ID" > "$CLIENT_INFO_DIR/node${node_index}.sid"

  inbound=$(cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$FAKE_HOST:443",
          "xver": 0,
          "serverNames": ["$FAKE_HOST"],
          "privateKey": "$PRIVATE_KEY",
          "shortId": "$SHORT_ID"
        }
      }
    }
EOF
)

  INBOUNDS_CONFIG+="$inbound"
  if [ $i -lt $((${#PORTS[@]} - 1)) ]; then
    INBOUNDS_CONFIG+=","
  fi
done

echo "==== 5. 写入 Xray 配置文件 ===="
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    $INBOUNDS_CONFIG
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

echo "==== 6. 创建 systemd 服务文件 ===="
cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo "==== 7. 启动并启用 Xray 服务 ===="
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

echo ""
echo "==== 部署完成，以下是 10 条 Reality VLESS 链接 ===="
for i in $(seq 1 10); do
  UUID=$(cat "$CLIENT_INFO_DIR/node${i}.uuid")
  PUBKEY=$(cat "$CLIENT_INFO_DIR/node${i}.pub")
  SHORTID=$(cat "$CLIENT_INFO_DIR/node${i}.sid")
  PORT=${PORTS[$((i-1))]}

  echo "vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=reality&sni=${FAKE_HOST}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&flow=xtls-rprx-vision#${NODE_NAME_PREFIX}-${i}"
done

rm -rf "$CLIENT_INFO_DIR"

echo ""
echo "请确保防火墙放行端口：${PORTS[*]}"
