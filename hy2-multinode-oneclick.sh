#!/bin/bash
# Xray-Reality-10-Nodes-Fixed.sh
# 修复版：增强了密钥生成部分的稳定性

# 定义颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
XRAY_BIN="/usr/local/bin/xray"
CONF_FILE="/etc/xray/config.json"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

# ==========================================
# 1. 强力清理与环境修复
# ==========================================
echo -e "${YELLOW}🧹 [1/5] 正在执行环境大扫除...${NC}"

# 停止服务
systemctl stop xray >/dev/null 2>&1

# 解除文件锁定并删除
if [ -f "$XRAY_BIN" ]; then chattr -i "$XRAY_BIN" >/dev/null 2>&1; fi
rm -rf "$XRAY_BIN" /etc/xray

# 强制时间同步 (非常重要，防止 Reality 验证失败)
echo -e "${BLUE}▶ 同步系统时间...${NC}"
apt install -y ntpdate >/dev/null 2>&1
ntpdate pool.ntp.org >/dev/null 2>&1

# 安装依赖
echo -e "${BLUE}▶ 安装必要工具...${NC}"
apt update -y >/dev/null 2>&1
apt install -y curl wget unzip jq uuid-runtime openssl coreutils >/dev/null 2>&1

# ==========================================
# 2. 下载并安装 Xray
# ==========================================
echo -e "${YELLOW}⬇️ [2/5] 下载 Xray 核心...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) FILE_ARCH="64" ;;
    aarch64|arm64) FILE_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}❌ 不支持架构: $ARCH${NC}"; exit 1 ;;
esac

# 下载核心
curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
unzip -o xray.zip >/dev/null
if [ ! -f "xray" ]; then
    echo -e "${RED}❌ 解压失败，未找到 xray 文件。${NC}"
    exit 1
fi

install -m 755 xray "$XRAY_BIN"
rm xray.zip

# 验证版本
VER_INFO=$("$XRAY_BIN" version 2>&1)
if [[ "$VER_INFO" != *"Xray"* ]]; then
    echo -e "${RED}❌ 核心安装失败！请检查 VPS 是否支持 AVX 指令集。${NC}"
    exit 1
fi
echo -e "${GREEN}✔ Xray 安装成功!${NC}"

# ==========================================
# 3. 生成公私钥 (已修复逻辑)
# ==========================================
echo -e "${BLUE}🔑 [3/5] 生成密钥对 (Debug模式)...${NC}"

# 尝试生成并打印原始输出，方便调试
KEY_OUTPUT=$("$XRAY_BIN" x25519)
echo -e "--- 核心返回原始内容 ---\n$KEY_OUTPUT\n------------------------"

# 使用更精准的 awk 提取
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/Private key:/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/Public key:/ {print $3}')

# 如果提取为空，尝试备用提取方式 (应对不同版本格式差异)
if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}')
fi

# 去除可能的空格
PRIVATE_KEY=$(echo $PRIVATE_KEY | xargs)
PUBLIC_KEY=$(echo $PUBLIC_KEY | xargs)

if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥生成失败。获取到的私钥为: [${PRIVATE_KEY}]${NC}"
    exit 1
fi
echo -e "${GREEN}✔ 密钥生成成功!${NC}"

# ==========================================
# 4. 循环生成 10 个节点配置
# ==========================================
echo -e "${BLUE}⚡ [4/5] 正在生成 10 个节点配置...${NC}"

INBOUNDS="["
LINKS=""
# 获取 IP，增加备用源
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb || curl -s4 ifconfig.me)
SERVER_NAME="www.microsoft.com"

for ((i=1; i<=10; i++)); do
    PORT=$(shuf -i 20000-59999 -n 1)
    UUID=$(uuidgen)
    SID=$(openssl rand -hex 4)
    
    if [ $i -gt 1 ]; then INBOUNDS+=","; fi
    
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
    LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Node-${i}-${PORT}"
    LINKS+="${LINK}\n"
done

INBOUNDS+="]"

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
echo -e "${GREEN}✔ 10个节点部署成功！${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${YELLOW}请复制下方所有链接批量导入客户端：${NC}"
echo -e "${BLUE}$LINKS${NC}"
