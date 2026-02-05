#!/usr/bin/env bash
# reality-10-nodes-fixed.sh
# 10节点版本 · 复用现有核心 · 显式密钥调试

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"
KEY_FILE="${XRAY_DIR}/reality.key"

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
  "www.amazon.com"
)
PORT_MIN=20000
PORT_MAX=59999
USED_PORTS=()

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

# ==========================================
# 1. 环境清理 (只清理配置，不删核心)
# ==========================================
echo -e "${YELLOW}🔥 正在清理旧配置...${NC}"
systemctl stop xray >/dev/null 2>&1
rm -rf "$XRAY_DIR"
rm -f /etc/systemd/system/xray.service
mkdir -p "$XRAY_DIR"

# ==========================================
# 2. 核心检测 (复用你已有的成功核心)
# ==========================================
echo -e "${BLUE}▶ 检测 Xray 核心状态...${NC}"

# 重新安装 unzip 确保万无一失
apt update -y >/dev/null 2>&1
apt install -y unzip curl >/dev/null 2>&1

# 检查当前核心能否运行
if [ -f "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
    echo -e "${GREEN}✔ 检测到现有 Xray 核心正常，跳过下载步骤。${NC}"
else
    echo -e "${RED}❌ 核心文件不存在或损坏，正在强制重新安装...${NC}"
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    unzip -o xray.zip >/dev/null
    install -m 755 xray "$XRAY_BIN"
    rm -f xray.zip xray
    
    # 再次检查
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        echo -e "${RED}❌ 严重错误：重新下载后依然无法运行 Xray。${NC}"
        exit 1
    fi
fi

# ==========================================
# 3. 密钥生成 (调试模式)
# ==========================================
echo -e "${BLUE}▶ 正在生成密钥对...${NC}"

# 直接将输出存入变量
KEY_OUTPUT=$("$XRAY_BIN" x25519)

if [ -z "$KEY_OUTPUT" ]; then
    echo -e "${RED}❌ 致命错误：xray x25519 命令没有任何输出！${NC}"
    exit 1
fi

# 打印调试信息
echo -e "${YELLOW}--- 调试信息：生成的密钥 ---${NC}"
echo "$KEY_OUTPUT"
echo -e "${YELLOW}----------------------------${NC}"

# 写入文件
echo "$KEY_OUTPUT" > "$KEY_FILE"

# 提取
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "Private key" | awk '{print $NF}' | tr -d '\r')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "Public key" | awk '{print $NF}' | tr -d '\r')

if [[ ${#PUBLIC_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 提取公钥失败。请检查上方调试信息。${NC}"
    exit 1
fi

echo -e "${GREEN}✔ 密钥提取成功！${NC}"

# ==========================================
# 4. 生成 10 个节点配置
# ==========================================
PUBLIC_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)
INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0
NODE_NUM=10  # 这里设定为10个

get_random_port() {
  while true; do
    PORT=$((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN))
    if ss -lnt | grep -q ":$PORT$"; then continue; fi
    echo "$PORT"; return
  done
}

echo -e "${BLUE}▶ 正在生成 $NODE_NUM 个新节点...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
  PORT=$(get_random_port)
  UUID=$(uuidgen)
  SID=$(openssl rand -hex 4)
  SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

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

  LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-${PORT}"
  ALL_LINKS+="${LINK}\n"
  
  COUNT=$((COUNT + 1))
done

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
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality 10 Nodes
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

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}✔ 10个节点部署成功！旧配置已清除。${NC}"
echo -e "${YELLOW}⚠️  必须删除客户端旧节点，复制下方新链接导入！${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${BLUE}$ALL_LINKS${NC}"
