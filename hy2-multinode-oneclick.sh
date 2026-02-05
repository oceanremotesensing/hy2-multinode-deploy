#!/usr/bin/env bash
# reality-vision-random-port-sni.sh
# 自动部署 Xray Reality Vision TCP 多节点 + 随机端口 + 多 SNI + 持久密钥

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"
KEY_FILE="${XRAY_DIR}/reality.key"

FP="chrome"

# ===== SNI 池（随机抽取） =====
SERVER_NAMES=(
  "learn.microsoft.com"
  "www.microsoft.com"
  "www.bing.com"
  "www.cloudflare.com"
  "www.apple.com"
  "developer.apple.com"
  "www.amazon.com"
)

# ===== 端口范围 =====
PORT_MIN=20000
PORT_MAX=59999
USED_PORTS=()

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}▶ Reality Vision TCP + 随机端口 + 多 SNI + 持久密钥${NC}"

read -p "请输入节点数量 (默认 10): " NODE_NUM
NODE_NUM=${NODE_NUM:-10}

# ===== 随机端口函数 =====
get_random_port() {
  while true; do
    PORT=$((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN))
    if printf '%s\n' "${USED_PORTS[@]}" | grep -qx "$PORT"; then continue; fi
    if ss -lnt | awk '{print $4}' | grep -q ":$PORT$"; then continue; fi
    USED_PORTS+=("$PORT")
    echo "$PORT"; return
  done
}

# ===== 清理旧环境 =====
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
  x86_64)  URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
  aarch64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
  *) echo -e "${RED}不支持架构${NC}"; exit 1 ;;
esac

curl -L -o xray.zip "$URL"
unzip -o xray.zip > /dev/null
install -m 755 xray "$XRAY_BIN"
mkdir -p "$XRAY_DIR"
rm -f xray.zip

PUBLIC_IP=$(curl -s4 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s4 ip.sb)

# ===== 生成/读取 Reality 密钥 =====
if [ -f "$KEY_FILE" ]; then
    echo -e "${GREEN}🔑 读取已有 Reality 密钥${NC}"
    PRIVATE_KEY=$(awk -F'= ' '/Private key/ {print $2}' "$KEY_FILE")
    PUBLIC_KEY=$(awk -F'= ' '/Public key/ {print $2}' "$KEY_FILE")
else
    echo -e "${GREEN}🔑 生成新的 Reality 密钥${NC}"
    KEYS=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key/ {print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key/ {print $3}')
    echo "$KEYS" > "$KEY_FILE"
fi

INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0

echo -e "${BLUE}▶ 正在生成 $NODE_NUM 个节点...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
    PORT=$(get_random_port)
    UUID=$(uuidgen)
    SID=$(openssl rand -hex 4)
    SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

    # 放行端口
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1
    fi

    # 构建单节点 JSON
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

    # 生成客户端链接
    LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp#Vision-${PORT}"
    ALL_LINKS+="${LINK}\n"

    echo -e "  ✔ 节点 $((COUNT+1)) → ${GREEN}${PORT}${NC} | SNI: ${BLUE}${SERVER_NAME}${NC}"
    COUNT=$((COUNT + 1))
done

# ===== 写入 Xray 配置 =====
cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ $INBOUNDS_JSON ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ===== systemd 服务 =====
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality Vision TCP Multi-Node
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
[ -x "$(command -v ufw)" ] && ufw --force enable >/dev/null 2>&1

# ===== BBR 开启 =====
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

# ===== 生成 Base64 订阅 =====
SUBSCRIPTION=$(echo -e "$ALL_LINKS" | base64 -w 0)

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}      ✔ $NODE_NUM 个节点部署完成 (Vision TCP + BBR)${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}提示：下方是【订阅内容】，可直接导入客户端${NC}"
echo -e "${BLUE}------------------- 复制下方内容 -------------------${NC}"
echo -e "$ALL_LINKS"
echo -e "${BLUE}---------------------------------------------------${NC}"
