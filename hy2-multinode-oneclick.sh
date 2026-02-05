#!/usr/bin/env bash
# reality-10-nodes-fixed-v2.sh
# 修复版：自动架构检测 + 稳健的密钥生成 + 依赖修复

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
# 0. 基础依赖检查与安装
# ==========================================
echo -e "${BLUE}▶ 正在检查系统依赖...${NC}"
apt update -y >/dev/null 2>&1
# 必须安装 uuid-runtime 用于生成 UUID，openssl 用于生成 sid
apt install -y curl wget unzip jq uuid-runtime openssl >/dev/null 2>&1

# ==========================================
# 1. 环境清理
# ==========================================
echo -e "${YELLOW}🔥 正在清理旧配置...${NC}"
systemctl stop xray >/dev/null 2>&1
rm -rf "$XRAY_DIR"
rm -f /etc/systemd/system/xray.service
mkdir -p "$XRAY_DIR"

# ==========================================
# 2. 核心检测与安装 (自动架构适配)
# ==========================================
echo -e "${BLUE}▶ 检测 Xray 核心状态...${NC}"

install_xray() {
    echo -e "${YELLOW}⬇️ 正在下载 Xray Core...${NC}"
    
    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            FILE_ARCH="64"
            ;;
        aarch64|arm64)
            FILE_ARCH="arm64-v8a"
            ;;
        *)
            echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"
            exit 1
            ;;
    esac

    # 创建临时目录
    mkdir -p /tmp/xray_install
    cd /tmp/xray_install || exit 1

    # 下载
    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
    curl -L -o xray.zip "$DOWNLOAD_URL"

    # 解压并安装
    if unzip -o xray.zip >/dev/null; then
        install -m 755 xray "$XRAY_BIN"
        echo -e "${GREEN}✔ Xray 安装成功 (架构: $FILE_ARCH)${NC}"
    else
        echo -e "${RED}❌ 解压失败，下载文件可能损坏${NC}"
        cd ~
        rm -rf /tmp/xray_install
        exit 1
    fi

    # 清理
    cd ~
    rm -rf /tmp/xray_install
}

# 检查当前核心能否运行
if [ -f "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
    echo -e "${GREEN}✔ 检测到现有 Xray 核心正常，跳过下载。${NC}"
else
    install_xray
    # 再次检查
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        echo -e "${RED}❌ 严重错误：新安装的核心无法运行，请检查系统兼容性。${NC}"
        exit 1
    fi
fi

# ==========================================
# 3. 密钥生成 (修复正则匹配)
# ==========================================
echo -e "${BLUE}▶ 正在生成密钥对...${NC}"

# 运行命令获取输出
KEY_OUTPUT=$("$XRAY_BIN" x25519)

if [ -z "$KEY_OUTPUT" ]; then
    echo -e "${RED}❌ 致命错误：xray x25519 命令没有任何输出！${NC}"
    exit 1
fi

# 写入文件留底
echo "$KEY_OUTPUT" > "$KEY_FILE"

# 修复后的提取逻辑：使用 awk -F': ' 更加精准
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk -F': ' '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk -F': ' '{print $2}' | tr -d ' \r\n')

# 调试检查
if [[ ${#PRIVATE_KEY} -lt 40 || ${#PUBLIC_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥提取失败。${NC}"
    echo -e "原始输出:\n$KEY_OUTPUT"
    exit 1
fi

echo -e "${GREEN}✔ 密钥生成完毕!${NC}"

# ==========================================
# 4. 生成 10 个节点配置
# ==========================================
PUBLIC_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)
INBOUNDS_JSON=""
ALL_LINKS=""
COUNT=0
NODE_NUM=10 

get_random_port() {
  while true; do
    PORT=$((RANDOM % (PORT_MAX - PORT_MIN + 1) + PORT_MIN))
    # 检查端口占用
    if ss -lnt | grep -q ":$PORT "; then continue; fi
    echo "$PORT"; return
  done
}

echo -e "${BLUE}▶ 正在生成 $NODE_NUM 个新节点...${NC}"

while [ $COUNT -lt $NODE_NUM ]; do
  PORT=$(get_random_port)
  UUID=$(uuidgen)
  SID=$(openssl rand -hex 4)
  SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

  # 尝试开放防火墙 (兼容 ufw)
  if command -v ufw >/dev/null 2>&1; then
      ufw allow "$PORT"/tcp >/dev/null 2>&1
  fi

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

  # 链接生成
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
