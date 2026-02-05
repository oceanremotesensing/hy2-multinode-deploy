#!/bin/bash
# Xray-Reality-10-Nodes-Fixed-Final.sh
# 完整修复版：稳定生成密钥，10节点 Reality Vision TCP，多 SNI，多端口

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
XRAY_BIN="/usr/local/bin/xray"
CONF_FILE="/etc/xray/config.json"
KEY_FILE="/etc/xray/reality.key"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${NC}" && exit 1

echo -e "${YELLOW}🧹 Step1: 清理旧环境${NC}"
systemctl stop xray >/dev/null 2>&1
pkill -9 xray >/dev/null 2>&1
rm -rf /etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service

echo -e "${BLUE}▶ 同步时间${NC}"
apt update -y >/dev/null
apt install -y ntpdate curl wget unzip jq uuid-runtime openssl >/dev/null
ntpdate pool.ntp.org >/dev/null

echo -e "${YELLOW}⬇️ Step2: 下载 Xray 核心${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) FILE_ARCH="64" ;;
    aarch64|arm64) FILE_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}❌ 不支持架构 $ARCH${NC}"; exit 1 ;;
esac

curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${FILE_ARCH}.zip"
unzip -o xray.zip >/dev/null
install -m 755 xray "$XRAY_BIN"
rm xray.zip

VER_INFO=$("$XRAY_BIN" version 2>&1)
if [[ "$VER_INFO" != *"Xray"* ]]; then
    echo -e "${RED}❌ 核心安装失败${NC}"; exit 1
fi
echo -e "${GREEN}✔ Xray 核心安装成功${NC}"

# ==========================================
# Step3: 生成 Reality 密钥
# ==========================================
mkdir -p /etc/xray
if [ -f "$KEY_FILE" ]; then
    echo -e "${GREEN}🔑 读取已有密钥${NC}"
    PRIVATE_KEY=$(grep -i "PrivateKey" "$KEY_FILE" | sed 's/.*: //')
    PUBLIC_KEY=$(grep -i "PublicKey" "$KEY_FILE" | sed 's/.*: //')
else
    echo -e "${BLUE}🔑 生成新密钥...${NC}"
    for i in {1..5}; do
        KEY_OUT=$("$XRAY_BIN" x25519 2>/dev/null)
        PRIVATE_KEY=$(echo "$KEY_OUT" | grep -i "PrivateKey" | sed 's/.*: //')
        PUBLIC_KEY=$(echo "$KEY_OUT" | grep -i "PublicKey" | sed 's/.*: //')
        if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
            echo "$KEY_OUT" > "$KEY_FILE"
            break
        fi
        sleep 1
    done
fi

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}❌ 密钥生成失败，请检查 Xray 核心${NC}"
    exit 1
fi
echo -e "${GREEN}✔ 密钥生成成功!${NC}"

# ==========================================
# Step4: 生成 10 个节点
# ==========================================
echo -e "${BLUE}⚡ 生成 10 个节点配置${NC}"

SERVER_NAMES=("learn.microsoft.com" "www.microsoft.com" "www.bing.com" "www.cloudflare.com")
INBOUNDS="["
LINKS=""
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb || curl -s4 ifconfig.me)

for ((i=1;i<=10;i++)); do
    PORT=$(shuf -i 20000-59999 -n 1)
    UUID=$(uuidgen)
    SID=$(openssl rand -hex 4)
    SERVER_NAME=${SERVER_NAMES[$RANDOM % ${#SERVER_NAMES[@]}]}

    [ $i -gt 1 ] && INBOUNDS+=","
    INBOUNDS+=$(cat <<EOF
{
    "listen":"0.0.0.0",
    "port":$PORT,
    "protocol":"vless",
    "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"$SERVER_NAME:443","serverNames":["$SERVER_NAME"],"privateKey":"$PRIVATE_KEY","shortIds":["$SID"]}}
}
EOF
)
    LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Node-${i}-${PORT}"
    LINKS+="${LINK}\n"
done

INBOUNDS+="]"

cat > "$CONF_FILE" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":$INBOUNDS,
  "outbounds":[{"protocol":"freedom"}]
}
EOF

# ==========================================
# Step5: 启动 Xray 服务
# ==========================================
echo -e "${BLUE}🚀 启动 Xray 服务${NC}"
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

echo -e "${GREEN}✅ 10 个节点部署成功！${NC}"
echo -e "${YELLOW}请复制以下链接导入客户端:${NC}"
echo -e "${BLUE}$LINKS${NC}"
