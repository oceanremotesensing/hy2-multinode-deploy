#!/bin/bash
# Xray-Reality-10-Nodes-Final.sh
# 功能：强制修复环境 + 部署 10 个 Reality-Vision 节点

# 定义颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
XRAY_BIN="/usr/local/bin/xray"
CONF_FILE="/etc/xray/config.json"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

# ==========================================
# 1. 强力清理与环境修复 (解决 Hysteria 残留)
# ==========================================
echo -e "${YELLOW}🧹 [1/5] 正在执行环境大扫除...${NC}"

# 尝试解除不可修改属性 (针对顽固文件)
if [ -f "$XRAY_BIN" ]; then
    chattr -i "$XRAY_BIN" >/dev/null 2>&1
fi

# 删除旧核心和配置
rm -rf "$XRAY_BIN"
rm -rf /etc/xray
systemctl stop xray >/dev/null 2>&1

# 强制时间同步
if command -v date >/dev/null 2>&1; then
    date -s "$(curl -sI https://www.google.com | grep ^Date: | sed 's/Date: //g')" >/dev/null 2>&1
fi

# 安装依赖
echo -e "${BLUE}▶ 安装必要工具...${NC}"
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip jq uuid-runtime openssl coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip jq util-linux openssl coreutils >/dev/null 2>&1
fi

# ==========================================
# 2. 下载并安装正版 Xray
# ==========================================
echo -e "${YELLOW}⬇️ [2/5] 下载最新 Xray 核心...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) FILE_ARCH="64" ;;
    aarch64|arm64) FILE_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}❌ 不支持架构: $ARCH${NC}"; exit 1 ;;
esac

curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
unzip -o xray.zip >/dev/null
install -m 755 xray "$XRAY_BIN"
rm xray.zip

# 验证版本 (防止假冒)
VER_INFO=$("$XRAY_BIN" version 2>&1)
if [[ "$VER_INFO" != *"Xray"* ]]; then
    echo -e "${RED}❌ 核心安装失败或校验不通过！${NC}"
    exit 1
fi
echo -e "${GREEN}✔ Xray 安装成功!${NC}"

# ==========================================
# 3. 生成公私钥 (一套密钥供所有节点使用)
# ==========================================
echo -e "${BLUE}🔑 [3/5] 生成密钥对...${NC}"
KEY_OUTPUT=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}' | tr -d ' \r\n')

if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥生成失败。${NC}"; exit 1
fi

# ==========================================
# 4. 循环生成 10 个节点配置
# ==========================================
echo -e "${BLUE}⚡ [4/5] 正在生成 10 个节点配置...${NC}"

INBOUNDS="["
LINKS=""
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)
SERVER_NAME="www.microsoft.com"

# 循环 10 次
for ((i=1; i<=10; i++)); do
    # 生成随机端口 (20000-59999)
    PORT=$(shuf -i 20000-59999 -n 1)
    UUID=$(uuidgen)
    SID=$(openssl rand -hex 4)
    
    # 逗号处理：如果不是第一个节点，要在前面加逗号
    if [ $i -gt 1 ]; then INBOUNDS+=","; fi
    
    # 构建 JSON 片段
    INBOUNDS+=$(cat <<EOF
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
                "dest": "${SERVER_NAME}:443",
                "serverNames": ["${SERVER_NAME}"],
                "privateKey": "$PRIVATE_KEY",
                "shortIds": ["$SID"]
            }
        }
    }
EOF
)
    # 生成链接
    LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Node-${i}-${PORT}"
    LINKS+="${LINK}\n"
    
    # 简单防重复端口 (如果有防火墙，放行端口)
    if command -v ufw >/dev/null 2>&1; then ufw allow "$PORT"/tcp >/dev/null 2>&1; fi
done

INBOUNDS+="]"

# 写入完整配置文件
mkdir -p /etc/xray
cat > "$CONF_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": $INBOUNDS,
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ==========================================
# 5. 启动服务与输出
# ==========================================
echo -e "${BLUE}🚀 [5/5] 启动服务...${NC}"
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality 10 Nodes
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

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}✔ 10个节点部署成功！旧故障已修复。${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${YELLOW}请复制下方所有链接批量导入客户端：${NC}"
echo -e "${BLUE}$LINKS${NC}"
