#!/bin/bash
set -euo pipefail

# --- 用户配置 ---
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443)
DEST_DOMAIN="wjfreeonekeycard.top"
NODE_NAME_PREFIX="REALITY"
# --- 配置结束 ---

NODES=${#PORTS[@]}

echo "🔧 [1/7] 停止旧服务并安装依赖..."
systemctl stop xray || true
systemctl disable xray || true
apt update -qq
apt install -y curl unzip socat openssl

echo "🔧 [2/7] 安装/更新 Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "🔧 [3/7] 生成 ${NODES} 组 REALITY 密钥和 UUID..."
CLIENT_INFO_DIR=$(mktemp -d)

for ((i=0; i<NODES; i++)); do
  node_index=$((i+1))
  KEY_PAIR=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
  PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')
  UUID=$(/usr/local/bin/xray uuid)
  SHORT_ID=$(openssl rand -hex 8)
  
  echo "$PRIVATE_KEY" > "${CLIENT_INFO_DIR}/node${node_index}.priv"
  echo "$PUBLIC_KEY" > "${CLIENT_INFO_DIR}/node${node_index}.pub"
  echo "$UUID" > "${CLIENT_INFO_DIR}/node${node_index}.uuid"
  echo "$SHORT_ID" > "${CLIENT_INFO_DIR}/node${node_index}.sid"
done

echo "🔧 [4/7] 创建服务器配置文件..."
CONFIG_JSON_HEAD='{
  "log": {"loglevel": "warning"},
  "inbounds": ['
CONFIG_JSON_OUTBOUNDS='],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}'
INBOUNDS_CONFIG=""

for ((i=0; i<NODES; i++)); do
  node_index=$((i+1))
  port=${PORTS[$i]}
  private_key=$(cat "${CLIENT_INFO_DIR}/node${node_index}.priv")
  uuid=$(cat "${CLIENT_INFO_DIR}/node${node_index}.uuid")
  short_id=$(cat "${CLIENT_INFO_DIR}/node${node_index}.sid")

  current_inbound=$(cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${DEST_DOMAIN}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      }
    }
EOF
)
  INBOUNDS_CONFIG+="${current_inbound}"
  if (( i < NODES - 1 )); then
    INBOUNDS_CONFIG+=","
  fi
done

echo "${CONFIG_JSON_HEAD}${INBOUNDS_CONFIG}${CONFIG_JSON_OUTBOUNDS}" > /usr/local/etc/xray/config.json

echo "🔧 [5/7] 启动 Xray 服务..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2
if ! systemctl status xray --no-pager | grep -q "active (running)"; then
  echo "❌ Xray 服务启动失败，请检查日志！"
  journalctl -u xray -n 50
  exit 1
fi

echo "🔧 [6/7] 生成 ${NODES} 个客户端配置链接..."
echo ""
echo "✅ 部署完成！以下是你的 ${NODES} 个 Reality 节点链接："
echo "--------------------------------------------------"

for ((i=0; i<NODES; i++)); do
  node_index=$((i+1))
  port=${PORTS[$i]}
  uuid=$(cat "${CLIENT_INFO_DIR}/node${node_index}.uuid")
  public_key=$(cat "${CLIENT_INFO_DIR}/node${node_index}.pub")
  short_id=$(cat "${CLIENT_INFO_DIR}/node${node_index}.sid")
  
  VLESS_LINK="vless://${uuid}@${DEST_DOMAIN}:${port}?encryption=none&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision#${NODE_NAME_PREFIX}-${node_index}"
  echo "${VLESS_LINK}"
  echo ""
done

echo "--------------------------------------------------"

echo "🔧 [7/7] 清理临时文件..."
rm -rf "$CLIENT_INFO_DIR"

echo ""
echo "⚠️ 重要提示：请务必确保服务器防火墙和云服务商安全组放行以下端口（TCP协议）:"
echo "${PORTS[*]}"
