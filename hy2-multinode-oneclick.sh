#!/usr/bin/env bash
# reality-reset-clean.sh
# 彻底清理旧数据 · 强制重装 Xray Reality · 全新密钥

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"
KEY_FILE="${XRAY_DIR}/reality.key"
SERVICE_FILE="/etc/systemd/system/xray.service"

# SNI 列表
SERVER_NAMES=(
  "www.microsoft.com"
  "learn.microsoft.com"
  "www.bing.com"
  "www.live.com"
  "azure.microsoft.com"
  "www.cloudflare.com"
  "developers.cloudflare.com"
  "shopify.com"
  "www.yahoo.com"
)
PORT_MIN=20000
PORT_MAX=59999
USED_PORTS=()

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

# ==========================================
# 1. 暴力清理旧环境 (响应你的要求)
# ==========================================
echo -e "${YELLOW}🔥 正在执行彻底清理 (删除所有旧配置)...${NC}"

systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1

# 删除二进制、配置目录、密钥、日志、服务文件
rm -rf "$XRAY_DIR"
rm -f "$XRAY_BIN"
rm -f "$SERVICE_FILE"
rm -f /usr/bin/xray # 有些旧脚本装在这里
rm -f ~/xray.zip

# 杀掉残留进程
pkill -9 xray >/dev/null 2>&1

systemctl daemon-reload
echo -e "${GREEN}✔ 清理完毕，环境已重置${NC}"

# ==========================================
# 2. 基础依赖与下载
# ==========================================
apt update -y
apt install -y curl uuid-runtime unzip ufw openssl

ARCH=$(uname -m)
echo -e "${BLUE}▶ 检测架构: ${ARCH}${NC}"

# 使用官方源
case $ARCH in
  x86_64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
  aarch64) URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
  *) echo -e "${RED}❌ 不支持的架构${NC}"; exit 1 ;;
esac

echo -e "${BLUE}▶ 下载 Xray Core...${NC}"
curl -L -o xray.zip "$URL"

if [ ! -s xray.zip ]; then
    echo -e "${RED}❌ 下载失败 (文件为空)。请检查服务器网络。${NC}"
    exit 1
fi

unzip -o xray.zip >/dev/null
install -m 755 xray "$XRAY_BIN"
rm -f xray.zip geoip.dat geosite.dat LICENSE README.md xray

# 验证二进制文件
if ! "$XRAY_BIN" version >/dev/null 2>&1; then
    echo -e "${RED}❌ Xray 安装失败，无法运行！${NC}"
    exit 1
fi

mkdir -p "$XRAY_DIR"

# ==========================================
# 3. 生成全新密钥 (强制覆盖)
# ==========================================
echo -e "${BLUE}▶ 生成全新的 Reality 密钥对...${NC}"
"$XRAY_BIN" x25519 > "$KEY_FILE"

PRIVATE_KEY=$(grep -i "Private key" "$KEY_FILE" | awk '{print $NF}' | tr -d '\r')
PUBLIC_KEY=$(grep -i "Public key"  "$KEY_FILE" | awk '{print $NF}' | tr -d '\r')

if [[ ${#PUBLIC_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥生成失败，请重试${NC}"
    exit 1
fi

echo -e "${GREEN}🔑 新密钥生成成功${NC}"

# ==========================================
# 4. 生成多节点配置
# ==========================================
read -p "请输入节点数量 (默认 5): " NODE_NUM
NODE_NUM=${NODE_NUM:-5}
PUBLIC_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)

get_random_port() {
  while true; do
    PORT=$((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN))
    printf '%s\n' "${USED_PORTS[@]}" | grep -qx "$PORT" && continue
    if ss -lnt | grep -q ":$PORT$"; then continue; fi
    USED_PORTS+=("$PORT")
    echo "$PORT"; return
  done
}

INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0

echo -e "${BLUE}▶ 正在构建配置...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
  PORT=$(get_random_port)
  UUID=$(uuidgen)
  SID=$(openssl rand -hex 4) # 这里的 shortId 必须短一点
  SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

  # 自动开放防火墙
  ufw allow "$PORT"/tcp >/dev/null 2>&1

  NODE_JSON=$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "$UUID", "flow": "" }],
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

  # 生成链接 (注意：为了兼容性，不加 flow)
  LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-${PORT}"
  ALL_LINKS+="${LINK}\n"
  
  COUNT=$((COUNT + 1))
done

# 写入配置文件
cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ $INBOUNDS_JSON ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ==========================================
# 5. 启动服务
# ==========================================
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Reality Service
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

# BBR 优化
if ! grep -q "bbr" /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}       安装完成 (已清理旧数据)          ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}⚠️  警告：公钥已变更！必须删除客户端所有旧节点！${NC}"
echo -e "${YELLOW}⚠️  警告：请直接复制下方新链接导入！${NC}"
echo -e "${BLUE}----------------------------------------${NC}"
echo -e "$ALL_LINKS"
echo -e "${BLUE}----------------------------------------${NC}"
