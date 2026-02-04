#!/usr/bin/env bash
# reality-clean-reinstall.sh

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"

BASE_PORT=20000
SERVER_NAME="www.cloudflare.com"
FP="chrome"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}▶ 开始【彻底清理旧配置】${NC}"

# ===== 停止并删除 xray 服务 =====
systemctl stop xray 2>/dev/null
systemctl disable xray 2>/dev/null
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload

# ===== 杀掉残留进程 =====
pkill -9 xray 2>/dev/null

# ===== 删除旧文件 =====
rm -rf "$XRAY_DIR"
rm -f "$XRAY_BIN"

# ===== 防火墙重置（保留 SSH）=====
if command -v ufw >/dev/null 2>&1; then
  echo -e "${YELLOW}▶ 重置 UFW 防火墙（保留 SSH）${NC}"
  ufw --force reset
  ufw allow ssh
fi

echo -e "${GREEN}✔ 清理完成${NC}"

# ======================================================
# ================== 开始重新部署 =====================
# ======================================================

echo -e "${BLUE}▶ 安装依赖...${NC}"
apt update -y
apt install -y curl jq uuid-runtime qrencode unzip ufw

# ===== 下载 Xray =====
echo -e "${BLUE}▶ 下载 Xray-core...${NC}"
curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o xray.zip
install -m 755 xray "$XRAY_BIN"

mkdir -p "$XRAY_DIR"

PUBLIC_IP=$(curl -s4 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && echo -e "${RED}无法获取公网 IP${NC}" && exit 1

# ===== Reality 密钥 =====
REALITY_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/Public key/ {print $3}')

read -p "请输入节点数量（默认 2，强兼容推荐 1-2）: " NUM
NUM=${NUM:-2}

INBOUNDS=()
LINKS=""

echo -e "${BLUE}▶ 创建节点...${NC}"

for ((i=0;i<NUM;i++)); do
  PORT=$((BASE_PORT + i))
  UUID=$(uuidgen)
  SHORT_ID=$(openssl rand -hex 4)

  ufw allow ${PORT}/tcp >/dev/null 2>&1

  INBOUNDS+=("{
    \"listen\": \"0.0.0.0\",
    \"port\": $PORT,
    \"protocol\": \"vless\",
    \"settings\": {
      \"clients\": [{
        \"id\": \"$UUID\"
      }],
      \"decryption\": \"none\"
    },
    \"streamSettings\": {
      \"network\": \"tcp\",
      \"security\": \"reality\",
      \"realitySettings\": {
        \"dest\": \"$SERVER_NAME:443\",
        \"serverNames\": [\"$SERVER_NAME\"],
        \"privateKey\": \"$PRIVATE_KEY\",
        \"shortIds\": [\"$SHORT_ID\"]
      }
    }
  }")

  LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${PORT}"
  LINKS+="$LINK\n"

  echo -e "  ✔ 端口 ${GREEN}${PORT}${NC} 就绪"
done

cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    $(IFS=,; echo "${INBOUNDS[*]}")
  ],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS REALITY (Clean)
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

echo -e "\n${GREEN}✔ 全新 REALITY 已部署完成${NC}"
echo -e "${BLUE}========== VLESS 链接 ==========${NC}"
echo -e "$LINKS"
echo -e "${BLUE}========== 聚合二维码 ==========${NC}"
qrencode -t ANSIUTF8 "$LINKS"
