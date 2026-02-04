#!/usr/bin/env bash
# xray-vless-reality-fixed.sh

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"

BASE_PORT=20000          # 起始端口
PORT_STEP=1              # 端口递增
SERVER_NAME="www.microsoft.com"
FP="chrome"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}请使用 root 运行${NC}" && exit 1

echo -e "${BLUE}▶ 安装依赖...${NC}"
apt update -y
apt install -y curl jq uuid-runtime qrencode unzip ufw

# ===== 下载 Xray =====
if [ ! -f "$XRAY_BIN" ]; then
  echo -e "${BLUE}▶ 下载 Xray-core...${NC}"
  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o xray.zip
  install -m 755 xray "$XRAY_BIN"
fi

mkdir -p "$XRAY_DIR"

PUBLIC_IP=$(curl -s4 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && echo -e "${RED}无法获取公网 IP${NC}" && exit 1

# ===== Reality 密钥 =====
REALITY_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/Public key/ {print $3}')

read -p "请输入节点数量（默认 3）: " NUM
NUM=${NUM:-3}

INBOUNDS=()
LINKS=""

echo -e "${BLUE}▶ 配置节点...${NC}"

for ((i=0;i<NUM;i++)); do
  PORT=$((BASE_PORT + i * PORT_STEP))
  UUID=$(uuidgen)
  SHORT_ID=$(openssl rand -hex 4)

  # --- 自动放行防火墙 ---
  ufw allow ${PORT}/tcp >/dev/null 2>&1

  INBOUNDS+=("{
    \"listen\": \"0.0.0.0\",
    \"port\": $PORT,
    \"protocol\": \"vless\",
    \"settings\": {
      \"clients\": [{
        \"id\": \"$UUID\",
        \"flow\": \"xtls-rprx-vision\"
      }],
      \"decryption\": \"none\"
    },
    \"streamSettings\": {
      \"network\": \"tcp\",
      \"security\": \"reality\",
      \"realitySettings\": {
        \"show\": false,
        \"dest\": \"$SERVER_NAME:443\",
        \"xver\": 0,
        \"serverNames\": [\"$SERVER_NAME\"],
        \"privateKey\": \"$PRIVATE_KEY\",
        \"shortIds\": [\"$SHORT_ID\"]
      }
    }
  }")

  LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${PORT}"
  LINKS+="$LINK\n"

  echo -e "  ✔ 端口 ${GREEN}${PORT}${NC} 已就绪"
done

# ===== 写入配置 =====
cat > "$CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    $(IFS=,; echo "${INBOUNDS[*]}")
  ],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# ===== systemd =====
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS REALITY
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

# ===== 启用 UFW（如果没开）=====
ufw --force enable >/dev/null 2>&1

echo -e "\n${GREEN}✔ Xray 已启动${NC}"
echo -e "${BLUE}========== VLESS + REALITY 链接 ==========${NC}"
echo -e "$LINKS"

echo -e "${BLUE}========== 聚合二维码 ==========${NC}"
qrencode -t ANSIUTF8 "$LINKS"
