#!/usr/bin/env bash
# reality-10-nodes-fixed-v3.sh
# 优化版：修复端口随机范围 + 增加 XTLS Vision + 兼容 CentOS

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

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

# ==========================================
# 0. 基础依赖检查与安装 (兼容 CentOS/Debian)
# ==========================================
echo -e "${BLUE}▶ 正在检查系统依赖...${NC}"

# 简单的包管理器检测
if command -v apt >/dev/null 2>&1; then
    PM="apt"
    $PM update -y >/dev/null 2>&1
    $PM install -y curl wget unzip jq uuid-runtime openssl coreutils >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    $PM install -y curl wget unzip jq util-linux openssl coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    $PM install -y curl wget unzip jq util-linux openssl coreutils >/dev/null 2>&1
else
    echo -e "${RED}❌ 未知系统，请手动安装依赖 (curl, wget, unzip, jq, uuid/util-linux, openssl)${NC}"
    exit 1
fi

# ==========================================
# 1. 环境清理 & 时间同步
# ==========================================
echo -e "${YELLOW}🔥 正在清理环境并同步时间...${NC}"
systemctl stop xray >/dev/null 2>&1
rm -rf "$XRAY_DIR"
rm -f /etc/systemd/system/xray.service
mkdir -p "$XRAY_DIR"

# 强制同步时间 (Xray 强依赖时间)
date -s "$(curl -sI https://google.com | grep ^Date: | sed 's/Date: //g')" >/dev/null 2>&1
echo -e "${GREEN}✔ 时间同步完成: $(date)${NC}"

# ==========================================
# 2. 核心检测与安装
# ==========================================
echo -e "${BLUE}▶ 检测 Xray 核心状态...${NC}"

install_xray() {
    echo -e "${YELLOW}⬇️ 正在下载 Xray Core...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) FILE_ARCH="64" ;;
        aarch64|arm64) FILE_ARCH="arm64-v8a" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    mkdir -p /tmp/xray_install
    cd /tmp/xray_install || exit 1

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
    curl -L -o xray.zip "$DOWNLOAD_URL"

    if unzip -o xray.zip >/dev/null; then
        install -m 755 xray "$XRAY_BIN"
        echo -e "${GREEN}✔ Xray 安装成功 (架构: $FILE_ARCH)${NC}"
    else
        echo -e "${RED}❌ 下载或解压失败${NC}"
        cd ~ && rm -rf /tmp/xray_install && exit 1
    fi
    cd ~ && rm -rf /tmp/xray_install
}

if [ -f "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
    echo -e "${GREEN}✔ 检测到现有核心，跳过下载。${NC}"
else
    install_xray
fi

# ==========================================
# 3. 密钥生成
# ==========================================
echo -e "${BLUE}▶ 正在生成密钥对...${NC}"
KEY_OUTPUT=$("$XRAY_BIN" x25519)
[ -z "$KEY_OUTPUT" ] && echo -e "${RED}❌ 生成密钥失败${NC}" && exit 1

echo "$KEY_OUTPUT" > "$KEY_FILE"
# 优化提取逻辑，防止格式变动
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}' | tr -d ' \r\n')

if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥无效${NC}"; exit 1
fi
echo -e "${GREEN}✔ 密钥生成完毕${NC}"

# ==========================================
# 4. 生成 10 个节点配置
# ==========================================
PUBLIC_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)
INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0
NODE_NUM=10 

# 使用 shuf 生成真正的随机端口，避免 Bash RANDOM 限制
get_random_port() {
  while true; do
    # shuf -i 生成范围内的随机数
    PORT=$(shuf -i $PORT_MIN-$PORT_MAX -n 1)
    if ss -lnt | grep -q ":$PORT "; then continue; fi
    echo "$PORT"; return
  done
}

echo -e "${BLUE}▶ 正在生成 $NODE_NUM 个新节点 (开启 XTLS Vision)...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
  PORT=$(get_random_port)
  UUID=$(uuidgen)
  SID=$(openssl rand -hex 4)
  SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

  if command -v ufw >/dev/null 2>&1; then ufw allow "$PORT"/tcp >/dev/null 2>&1; fi
  if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --zone=public --add-port="$PORT"/tcp --permanent >/dev/null 2>&1; fi

  # 启用 xtls-rprx-vision
  NODE_JSON=$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
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

  # 链接包含 flow 参数
  LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-Vision-${PORT}"
  ALL_LINKS+="${LINK}\n"
  
  COUNT=$((COUNT + 1))
done

if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --reload >/dev/null 2>&1; fi

# 写入配置
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

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}✔ 部署成功！已启用 XTLS-Vision 流控。${NC}"
echo -e "${YELLOW}⚠️  请复制下方链接导入客户端 (支持 v2rayNG, Shadowrocket 等)${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${BLUE}$ALL_LINKS${NC}"
