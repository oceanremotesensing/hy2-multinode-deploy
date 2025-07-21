#!/bin/bash
set -euo pipefail

# --- 用户配置 ---
#
# 您可以自定义将要使用的端口列表
PORTS=(443 8443 9443 10443 11443 12443 13443 14443 15443 16443)
# 伪装的目标域名
DEST_DOMAIN="www.microsoft.com"
# 客户端连接的基础备注名称
NODE_NAME_PREFIX="REALITY"
# --- 配置结束 ---


# --- 脚本主体 ---
# 获取节点数量
NODES=${#PORTS[@]}

echo "🔧 [1/7] 停止旧服务并安装依赖..."
systemctl stop xray || true
systemctl disable xray || true
apt update -qq
apt install -y curl unzip socat

echo "🔧 [2/7] 安装/更新 Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "🔧 [3/7] 生成 ${NODES} 组 REALITY 密钥和 UUID..."
# 创建临时目录存放客户端信息
CLIENT_INFO_DIR=$(mktemp -d)

for ((i=0; i<NODES; i++)); do
  node_index=$((i+1))
  KEY_PAIR=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/Private key/ {print $3}')
  PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/Public key/ {print $3}')
  UUID=$(/usr/local/bin/xray uuid)
  SHORT_ID=$(openssl rand -hex 8)
  
  # 保存密钥信息用于后续生成链接
  echo "$PRIVATE_KEY" > "${CLIENT_INFO_DIR}/node${node_index}.priv"
  echo "$PUBLIC_KEY" > "${CLIENT_INFO_DIR}/node${node_index}.pub"
  echo "$UUID" > "${CLIENT_INFO_DIR}/node${node_index}.uuid"
  echo "$SHORT_ID" > "${CLIENT_INFO_DIR}/node${node_index}.sid"
done

echo "🔧 [4/7] 创建服务器配置文件..."
# 获取服务器公网 IP
SERVER_IP=$(curl -s https://api.ipify.org)
if [[ -z "$SERVER_IP" ]]; then
  echo "❌ 获取公网 IP 失败，请检查服务器网络！"
  rm -rf "$CLIENT_INFO_DIR"
  exit 1
fi

# 开始构建 config.json
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

  # 为每个节点创建一个 inbound 配置
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
          "shortId": "${short_id}"
        }
      }
    }
EOF
)
  INBOUNDS_CONFIG+="${current_inbound}"
  # 如果不是最后一个，则添加逗号
  if (( i < NODES - 1 )); then
    INBOUNDS_CONFIG+=","
  fi
done

# 组合成最终的 config.json
echo "${CONFIG_JSON_HEAD}${INBOUNDS_CONFIG}${CONFIG_JSON_OUTBOUNDS}" > /usr/local/etc/xray/config.json

echo "🔧 [5/7] 启动 Xray 服务..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2
systemctl status xray --no-pager || (echo "❌ Xray 服务启动失败，请检查日志！" && journalctl -u xray -n 50 && exit 1)

echo "🔧 [6/7] 生成 ${NODES} 个客户端配置链接..."
echo ""
echo "✅ 部署完成！"
echo "=================================================="
echo "🔗 您的 ${NODES} 个 VLESS REALITY 链接:"
echo ""

for ((i=0; i<NODES; i++)); do
  node_index=$((i+1))
  port=${PORTS[$i]}
  uuid=$(cat "${CLIENT_INFO_DIR}/node${node_index}.uuid")
  public_key=$(cat "${CLIENT_INFO_DIR}/node${node_index}.pub")
  short_id=$(cat "${CLIENT_INFO_DIR}/node${node_index}.sid")
  
  VLESS_LINK="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision#${NODE_NAME_PREFIX}-${node_index}"
  echo "${VLESS_LINK}"
  echo ""
done

echo "=================================================="
echo "请将上面的链接复制到您的客户端中使用。"

echo "🔧 [7/7] 清理临时文件..."
rm -rf "$CLIENT_INFO_DIR"
echo ""
echo "⚠️ 重要提示：请务必在您的 MassiveGrid 防火墙中，为 TCP 和 UDP 协议放行以下所有端口！"
echo "${PORTS[*]}"
