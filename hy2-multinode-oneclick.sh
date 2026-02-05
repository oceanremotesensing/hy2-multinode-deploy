#!/usr/bin/env bash
# reality-vision-stable.sh
# Xray Reality TCP 多节点 · 随机端口 · 多 SNI · 持久密钥 · 最稳方案

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"
KEY_FILE="${XRAY_DIR}/reality.key"

FP="chrome"

# ===== 稳定 SNI 池 =====
SERVER_NAMES=(
  "www.microsoft.com"
  "learn.microsoft.com"
  "www.bing.com"
  "www.office.com"
  "www.live.com"
  "login.microsoftonline.com"
  "azure.microsoft.com"
  "www.cloudflare.com"
  "developers.cloudflare.com"
  "dash.cloudflare.com"
  "blog.cloudflare.com"
  "workers.cloudflare.com"
  "pages.cloudflare.com"
)
PORT_MIN=20000
PORT_MAX=59999
USED_PORTS=()

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}▶ Xray Reality TCP 多节点（稳定方案）${NC}"

read -p "请输入节点数量 (默认 10): " NODE_NUM
NODE_NUM=${NODE_NUM:-10}

get_random_port() {
  while true; do
    PORT=$((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN))
    printf '%s\n' "${USED_PORTS[@]}" | grep -qx "$PORT" && continue
    ss -lnt | awk '{print $4}' | grep -q ":$PORT$" && continue
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

# ===== 下载 Xray =====
ARCH=$(uname -m)
case $ARCH in
  x86_64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
  aarch64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
  *) echo -e "${RED}不支持架构${NC}"; exit 1 ;;
esac

curl -L -o xray.zip "$URL"
unzip -o xray.zip >/dev/null
install -m 755 xray "$XRAY_BIN"
mkdir -p "$XRAY_DIR"
rm -f xray.zip

PUBLIC_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)

# ===== Reality 密钥（稳定解析）=====
if [ -f "$KEY_FILE" ]; then
  echo -e "${GREEN}🔑 使用已有 Reality 密钥${NC}"
else
  echo -e "${GREEN}🔑 生成新的 Reality 密钥${NC}"
  $XRAY_BIN x25519 > "$KEY_FILE"
fi

PRIVATE_KEY=$(grep -i "Private key" "$KEY_FILE" | awk '{print $NF}' | tr -d '\r')
PUBLIC_KEY=$(grep -i "Public key"  "$KEY_FILE" | awk '{print $NF}' | tr -d '\r')
# ===== 公钥合法性校验 =====
if ! echo "$PUBLIC_KEY" | grep -Eq '^[A-Za-z0-9_-]{43,44}$'; then
  echo -e "${RED}❌ Reality PublicKey 非法：$PUBLIC_KEY${NC}"
  exit 1
fi

INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0

echo -e "${BLUE}▶ 正在生成节点...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
  PORT=$(get_random_port)
  UUID=$(uuidgen)
  SID=$(openssl rand -hex 8)
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
    }
  }
}
EOF
)

  [ $COUNT -gt 0 ] && INBOUNDS_JSON+=","
  INBOUNDS_JSON+="$NODE_JSON"

  # ===== 客户端链接（无 flow，最稳）=====
  LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-${PORT}"
  ALL_LINKS+="${LINK}\n"

  echo -e " ✔ 端口 ${GREEN}${PORT}${NC} | SNI ${BLUE}${SERVER_NAME}${NC}"
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
Description=Xray Reality TCP Stable
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

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

echo -e "\n${GREEN}====================================${NC}"
echo -e "${GREEN}✔ Reality TCP 节点部署完成（最稳）${NC}"
echo -e "${GREEN}====================================${NC}"
echo -e "${BLUE}---------- 客户端链接 ----------${NC}"
echo -e "$ALL_LINKS"
echo -e "${BLUE}---------------------------------${NC}"
