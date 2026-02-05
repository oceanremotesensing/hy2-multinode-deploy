#!/usr/bin/env bash
# Xray-Reality-Auto-Deploy.sh
# 适配 Debian/Ubuntu/CentOS
# 功能：自动部署 Xray Reality + Vision 流控 + 随机端口

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
XRAY_BIN="/usr/local/bin/xray"
CONF_DIR="/etc/xray"
CONF_FILE="${CONF_DIR}/config.json"

# 1. 权限检查
[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 必须使用 root 权限运行此脚本！${NC}" && exit 1

echo -e "${BLUE}▶ 正在初始化安装环境...${NC}"

# 2. 强制时间同步 (防止 Reality 连接失败)
if command -v date >/dev/null 2>&1; then
    # 尝试同步时间
    systemctl stop xray >/dev/null 2>&1
    date -s "$(curl -sI https://www.google.com | grep ^Date: | sed 's/Date: //g')" >/dev/null 2>&1
    echo -e "${GREEN}✔ 服务器时间已同步: $(date)${NC}"
fi

# 3. 依赖安装 (自动识别系统)
echo -e "${BLUE}▶ 正在检查并安装依赖...${NC}"
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip jq uuid-runtime openssl coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip jq util-linux openssl coreutils >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget unzip jq util-linux openssl coreutils >/dev/null 2>&1
else
    echo -e "${RED}❌ 未知系统，无法自动安装依赖，请手动安装 curl/unzip/openssl${NC}"
    exit 1
fi

# 4. 安装/更新 Xray 核心
install_xray() {
    echo -e "${YELLOW}⬇️ 正在下载最新版 Xray 核心...${NC}"
    rm -rf "$XRAY_BIN" # 强制删除旧文件，避免版本冲突
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) FILE_ARCH="64" ;;
        aarch64|arm64) FILE_ARCH="arm64-v8a" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    # 创建临时目录下载
    mkdir -p /tmp/xray_dl
    cd /tmp/xray_dl || exit 1
    
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
    
    if ! unzip -o xray.zip >/dev/null; then
        echo -e "${RED}❌ 解压失败，下载文件可能损坏${NC}"
        cd ~ && rm -rf /tmp/xray_dl
        exit 1
    fi
    
    install -m 755 xray "$XRAY_BIN"
    cd ~ && rm -rf /tmp/xray_dl
    
    # 验证安装
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        echo -e "${RED}❌ Xray 安装后无法运行，请检查系统兼容性${NC}"
        exit 1
    fi
    echo -e "${GREEN}✔ Xray 核心安装成功${NC}"
}

# 如果没有安装或者无法运行，则重新安装
if [ ! -f "$XRAY_BIN" ] || ! "$XRAY_BIN" version >/dev/null 2>&1; then
    install_xray
else
    echo -e "${GREEN}✔ 检测到 Xray 已安装，跳过下载${NC}"
fi

# 5. 生成密钥 (关键修复：使用 awk 稳健提取)
echo -e "${BLUE}▶ 正在生成 Reality 密钥对...${NC}"
KEY_OUTPUT=$("$XRAY_BIN" x25519)

# 使用 awk '{print $NF}' 提取每行的最后一项，无视中间的空格
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}' | tr -d ' \r\n')

# 校验密钥有效性
if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥提取失败，尝试重新安装核心...${NC}"
    install_xray
    KEY_OUTPUT=$("$XRAY_BIN" x25519)
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}' | tr -d ' \r\n')
    
    if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
        echo -e "${RED}❌ 致命错误：无法生成有效的 Xray 密钥。${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✔ 密钥生成完毕${NC}"

# 6. 生成配置参数
UUID=$(uuidgen)
# 使用 shuf 生成真正的随机端口 (20000-59999)
PORT=$(shuf -i 20000-59999 -n 1)
SID=$(openssl rand -hex 4)
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)
SERVER_NAME="www.microsoft.com"

# 7. 写入配置文件 (开启 Vision 流控)
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
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
        "dest": "${SERVER_NAME}:443",
        "serverNames": ["${SERVER_NAME}"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 8. 配置防火墙 (如果有)
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port="$PORT"/tcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

# 9. 创建并启动服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality Service
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $CONF_FILE
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray

# 10. 输出客户端链接
LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-Vision-${PORT}"

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}✔ 部署成功！脚本已修复完毕。${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "地址 (IP): ${MY_IP}"
echo -e "端口 (Port): ${PORT}"
echo -e "用户ID (UUID): ${UUID}"
echo -e "流控 (Flow): xtls-rprx-vision"
echo -e "公钥 (PublicKey): ${PUBLIC_KEY}"
echo -e "${GREEN}============================================${NC}"
echo -e "${BLUE}请复制下方链接导入客户端 (v2rayNG / Shadowrocket / Nekobox)${NC}"
echo -e "\n${LINK}\n"
echo -e "${GREEN}============================================${NC}"
