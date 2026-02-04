#!/usr/bin/env bash
# reality-batch-10.sh
# 批量生成节点 + 自动生成订阅 + 端口避让

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"

# ================= 配置 =================
SERVER_NAME="learn.microsoft.com" # 美国推荐
FP="chrome"
# =======================================

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}▶ 准备批量部署 Xray Reality (多节点订阅版)${NC}"

# 1. 交互输入
read -p "请输入节点数量 (默认 10): " NODE_NUM
NODE_NUM=${NODE_NUM:-10}

echo -e "${YELLOW}建议起始端口：${NC}"
echo -e "1. 输入 ${GREEN}443${NC} (首个节点最稳，后续节点端口递增)"
echo -e "2. 输入 ${GREEN}20000${NC} (高位端口，完全避开系统端口)"
read -p "请输入起始端口 (默认 20000): " START_PORT
START_PORT=${START_PORT:-20000}

# 2. 环境清理与准备
systemctl stop xray 2>/dev/null
rm -f /etc/systemd/system/xray.service
pkill -9 xray 2>/dev/null
rm -rf "$XRAY_DIR" "$XRAY_BIN"

apt update -y
apt install -y curl jq uuid-runtime qrencode unzip ufw ntpdate
ntpdate pool.ntp.org

# 3. 下载 Xray
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

# 4. 生成密钥 (所有节点共用 Reality 密钥，方便管理)
REALITY_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/Public key/ {print $3}')

# 5. 循环生成配置
INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0
CURRENT_PORT=$START_PORT

echo -e "${BLUE}▶ 正在生成 $NODE_NUM 个节点...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
    # 智能避让：跳过 445 端口 (SMB) 和一些常用攻击端口
    if [[ $CURRENT_PORT -eq 445 ]]; then
        echo -e "${YELLOW}  ⚠ 跳过端口 445 (防止被 VPS 商家封锁)${NC}"
        CURRENT_PORT=$((CURRENT_PORT + 1))
        continue
    fi

    UUID=$(uuidgen)
    SHORT_ID=$(openssl rand -hex 4)
    
    # 防火墙放行
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$CURRENT_PORT"/tcp >/dev/null 2>&1
    fi

    # 构建 JSON
    NODE_JSON="{
      \"listen\": \"0.0.0.0\",
      \"port\": $CURRENT_PORT,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{ \"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\" }],
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

    if [ $COUNT -gt 0 ]; then INBOUNDS_JSON="$INBOUNDS_JSON,"; fi
    INBOUNDS_JSON="$INBOUNDS_JSON$NODE_JSON"

    # 生成链接
    LINK="vless://${UUID}@${PUBLIC_IP}:${CURRENT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Node-${CURRENT_PORT}"
    ALL_LINKS+="${LINK}\n"
    
    echo -e "  ✔ 节点 $((COUNT+1)) 端口: ${GREEN}${CURRENT_PORT}${NC}"
    
    CURRENT_PORT=$((CURRENT_PORT + 1))
    COUNT=$((COUNT + 1))
done

# 6. 写入文件
cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ $INBOUNDS_JSON ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 7. 启动服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Multi-Node
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

# 8. BBR 开启
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

# 9. 生成 Base64 订阅
SUBSCRIPTION=$(echo -e "$ALL_LINKS" | base64 -w 0)

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}      ✔ 10个节点部署完成 (Vision + BBR)       ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}提示：下方是【订阅内容】，请直接全选复制，${NC}"
echo -e "${YELLOW}然后在 v2rayN / Shadowrocket 中选择 '从剪贴板导入'${NC}"
echo -e "${BLUE}------------------- 复制下方内容 -------------------${NC}"
echo -e "$ALL_LINKS"
echo -e "${BLUE}---------------------------------------------------${NC}"
