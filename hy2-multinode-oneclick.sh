#!/usr/bin/env bash
# reality-xhttp-random-port-random-sni.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"

FP="chrome"

# ===== SNI 池（随机）=====
SERVER_NAMES=(
  "learn.microsoft.com"
  "www.microsoft.com"
  "www.bing.com"
  "www.cloudflare.com"
  "www.apple.com"
  "developer.apple.com"
  "www.amazon.com"
)

# ===== 随机端口范围 =====
PORT_MIN=20000
PORT_MAX=59999
USED_PORTS=()

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}▶ Reality + XHTTP + 随机端口 + 随机 SNI${NC}"

read -p "请输入节点数量 (默认 10): " NODE_NUM
NODE_NUM=${NODE_NUM:-10}

# ===== 随机端口 =====
get_random_port() {
  while true; do
    PORT=$((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN))
    if printf '%s\n' "${USED_PORTS[@]}" | grep -qx "$PORT"; then continue; fi
    if ss -lnt | awk '{print $4}' | grep -q ":$PORT$"; then continue; fi
    USED_PORTS+=("$PORT")
    echo "$PORT"; return
  done
}

# ===== 清理 =====
systemctl stop xray 2>/dev/null
rm -rf "$XRAY_DIR" "$XRAY_BIN"
rm -f /etc/systemd/system/xray.service
pkill -9 xray 2>/dev/null

apt update -y
apt install -y curl uuid-runtime unzip ufw ntpdate openssl
ntpdate pool.ntp.org

# ===== 安装 Xray =====
ARCH=$(uname -m)
case $ARCH in
  x86_64)  URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
  aarch64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
  *) echo "不支持架构"; exit 1 ;;
esac

curl -L -o xray.zip "$URL"
unzip -o xray.zip > /dev/null
install -m 755 xray "$XRAY_BIN"
mkdir -p "$XRAY_DIR"
rm -f xray.zip

PUBLIC_IP=$(curl -s4 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s4 ip.sb)

# ===== Reality 密钥 =====
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key/ {print $3}')

INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0

echo -e "${BLUE}▶ 正在生成节点...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
  PORT=$(get_random_port)
  UUID=$(uuidgen)
  SID=$(openssl rand -hex 4)

  # 随机 SNI
  SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

  ufw allow "$PORT"/tcp >/dev/null 2>&1

  NODE_JSON=$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "$UUID" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "dest": "$SERVER_NAME:443",
      "serverNames": ["$SERVER_NAME"],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": ["$SID"]
    },
    "xhttpSettings": {
      "path": "/",
      "mode": "auto"
    }
  }
}
EOF
)

  [ $COUNT -gt 0 ] && INBOUNDS_JSON+=","
  INBOUNDS_JSON+="$NODE_JSON"

  ALL_LINKS+="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp&xhttp=true#XHTTP-${SERVER_NAME}-${PORT}\n"

  echo -e "  ✔ 节点 $((COUNT+1)) → ${GREEN}${PORT}${NC} | SNI: ${BLUE}${SERVER_NAME}${NC}"
  COUNT=$((COUNT + 1))
done

cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ $INBOUNDS_JSON ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality XHTTP Random-Port Random-SNI
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $CONF
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray
ufw --force enable >/dev/null 2>&1

echo -e "\n${GREEN}✔ 部署完成（随机端口 + 随机 SNI）${NC}"
echo -e "${BLUE}👇 复制以下节点导入客户端：${NC}"
echo -e "$ALL_LINKS"
