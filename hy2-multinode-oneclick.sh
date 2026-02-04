#!/usr/bin/env bash
# reality-multi-node-vision.sh
# 支持多端口 + Vision流控 + BBR + 美国线路优化

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"

# ================= 默认配置 =================
# 美国 VPS 推荐伪装域名
SERVER_NAME="learn.microsoft.com"
FP="chrome"
# ===========================================

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}▶ 准备部署 Xray Reality (多节点 + Vision防掉线版)${NC}"

# 1. 交互式输入
echo -e "${BLUE}---------------------------------------${NC}"
read -p "请输入要生成的节点数量 (默认 1): " NODE_NUM
NODE_NUM=${NODE_NUM:-1}

read -p "请输入起始端口 (默认 443): " START_PORT
START_PORT=${START_PORT:-443}

echo -e "${BLUE}---------------------------------------${NC}"
echo -e "将被使用的端口: ${START_PORT} ~ $((START_PORT + NODE_NUM - 1))"
echo -e "伪装域名 (SNI): ${SERVER_NAME}"
echo -e "${BLUE}---------------------------------------${NC}"

# 2. 清理环境
systemctl stop xray 2>/dev/null
systemctl disable xray 2>/dev/null
rm -f /etc/systemd/system/xray.service
pkill -9 xray 2>/dev/null
rm -rf "$XRAY_DIR" "$XRAY_BIN"

# 3. 安装基础依赖 & 同步时间
echo -e "${BLUE}▶ 安装依赖并同步时间...${NC}"
apt update -y
apt install -y curl jq uuid-runtime qrencode unzip ufw ntpdate
ntpdate pool.ntp.org

# 4. 下载 Xray
ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
    aarch64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
    *) echo -e "${RED}不支持架构: $ARCH${NC}"; exit 1 ;;
esac

curl -L -o xray.zip "$URL"
unzip -o xray.zip > /dev/null
install -m 755 xray "$XRAY_BIN"
mkdir -p "$XRAY_DIR"
rm -f xray.zip geoip.dat geosite.dat LICENSE README.md

PUBLIC_IP=$(curl -s4 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s4 ip.sb)

# 5. 生成密钥对 (所有节点共用一对 Reality 密钥，但 UUID 不同)
REALITY_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/Public key/ {print $3}')

# 6. 循环构建多节点配置
INBOUNDS_JSON=""
LINKS_OUTPUT=""

echo -e "${BLUE}▶ 正在生成 $NODE_NUM 个节点配置...${NC}"

# 开启防火墙 SSH 防止把自己锁在外面
if command -v ufw >/dev/null 2>&1; then
    ufw allow ssh >/dev/null 2>&1
fi

for ((i=0; i<NODE_NUM; i++)); do
    CURRENT_PORT=$((START_PORT + i))
    UUID=$(uuidgen)
    SHORT_ID=$(openssl rand -hex 4)
    
    # 开放端口
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$CURRENT_PORT"/tcp >/dev/null 2>&1
    fi

    # 构建 JSON 片段
    # 注意：这里强制开启了 flow: xtls-rprx-vision
    NODE_JSON="{
      \"listen\": \"0.0.0.0\",
      \"port\": $CURRENT_PORT,
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
          \"dest\": \"$SERVER_NAME:443\",
          \"serverNames\": [\"$SERVER_NAME\"],
          \"privateKey\": \"$PRIVATE_KEY\",
          \"shortIds\": [\"$SHORT_ID\"]
        }
      }
    }"

    # 处理 JSON 逗号
    if [ $i -gt 0 ]; then
        INBOUNDS_JSON="$INBOUNDS_JSON,"
    fi
    INBOUNDS_JSON="$INBOUNDS_JSON$NODE_JSON"

    # 生成链接
    LINK="vless://${UUID}@${PUBLIC_IP}:${CURRENT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#US-Node-${CURRENT_PORT}"
    
    LINKS_OUTPUT+="${GREEN}节点 $((i+1)) (端口 ${CURRENT_PORT}):${NC}\n${LINK}\n\n"
done

# 7. 写入完整配置
cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    $INBOUNDS_JSON
  ],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# 8. 启动服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Multi-Node Vision
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

# 9. 开启 BBR
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}      ✔ 多节点部署成功 (Vision + BBR)         ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}重要提示：客户端必须开启 flow: xtls-rprx-vision${NC}"
echo -e "${YELLOW}Xray 内核版本要求 >= 1.8.0${NC}"
echo -e "${BLUE}----------------------------------------------${NC}"
echo -e "$LINKS_OUTPUT"
echo -e "${BLUE}----------------------------------------------${NC}"
echo -e "若需查看二维码，请复制链接到在线生成工具或客户端。"
