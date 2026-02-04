#!/usr/bin/env bash
# reality-us-optimized.sh
# 专为美国 VPS 优化的 Xray Reality (Vision + BBR) 一键脚本

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ================= 配置区域 =================
# 端口：强烈建议使用 443，这是最像正常流量的端口
PORT=443

# 伪装域名 (SNI)：针对美国 VPS，微软或亚马逊最稳
# 备选: www.amazon.com, itunes.apple.com
SERVER_NAME="learn.microsoft.com"

# 伪装指纹
FP="chrome"
# ===========================================

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
CONF="${XRAY_DIR}/config.json"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 错误：请用 root 用户运行此脚本！${NC}" && exit 1

echo -e "${YELLOW}▶ 正在准备环境 (清理旧版本 + 同步时间)...${NC}"

# 1. 停止服务并清理旧文件
systemctl stop xray 2>/dev/null
systemctl disable xray 2>/dev/null
rm -f /etc/systemd/system/xray.service
pkill -9 xray 2>/dev/null
rm -rf "$XRAY_DIR" "$XRAY_BIN"

# 2. 安装依赖 & 同步时间 (解决掉线重要因素)
apt update -y
apt install -y curl jq uuid-runtime qrencode unzip ufw ntpdate

echo -e "${BLUE}▶ 正在同步服务器时间...${NC}"
ntpdate pool.ntp.org
# 再次检查时间
TIME_GAP=$(date +%z)
echo -e "当前时区偏移: $TIME_GAP (时间已同步)"

# 3. 架构检测与下载 Xray
ARCH=$(uname -m)
echo -e "${BLUE}▶ 检测系统架构: ${ARCH}${NC}"

case $ARCH in
    x86_64)  DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
    aarch64) DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

echo -e "${BLUE}▶ 下载并安装 Xray-core...${NC}"
curl -L -o xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查网络连通性${NC}"
    exit 1
fi
unzip -o xray.zip > /dev/null
install -m 755 xray "$XRAY_BIN"
mkdir -p "$XRAY_DIR"
rm -f xray.zip geoip.dat geosite.dat LICENSE README.md

# 获取公网 IP
PUBLIC_IP=$(curl -s4 https://api.ipify.org)
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -s4 ip.sb)
fi

# 4. 生成密钥和 ID
echo -e "${BLUE}▶ 生成 Reality 密钥...${NC}"
REALITY_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/Private key/ {print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/Public key/ {print $3}')
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 4)

# 5. 写入配置 (开启 Vision 流控)
# 注意：flow: xtls-rprx-vision 是防断连的关键
cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$SERVER_NAME:443",
        "serverNames": ["$SERVER_NAME"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# 6. 配置 Systemd 服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS REALITY (Vision Optimized)
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $CONF
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务 & 设置防火墙
systemctl daemon-reload
systemctl enable --now xray

echo -e "${BLUE}▶ 配置防火墙 (开放 443 和 SSH)...${NC}"
if command -v ufw >/dev/null 2>&1; then
  ufw allow ssh >/dev/null 2>&1
  ufw allow $PORT/tcp >/dev/null 2>&1
  # 不强制 reset，避免误伤
  ufw --force enable >/dev/null 2>&1
fi

# 8. 开启 BBR (美国 VPS 必备)
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "${BLUE}▶ 检测到未开启 BBR，正在开启...${NC}"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    echo -e "${GREEN}✔ BBR 已开启${NC}"
else
    echo -e "${GREEN}✔ BBR 已经开启，跳过${NC}"
fi

# 9. 生成分享链接
# 格式化链接，确保包含 flow=xtls-rprx-vision
LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#US-Vision-${PORT}"

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}      🚀 Reality (Vision+BBR) 部署成功      ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "地址 (Address): ${PUBLIC_IP}"
echo -e "端口 (Port)   : ${PORT}"
echo -e "用户ID (UUID) : ${UUID}"
echo -e "流控 (Flow)   : ${YELLOW}xtls-rprx-vision${NC} (客户端必须开启此选项!)"
echo -e "伪装域名 (SNI): ${SERVER_NAME}"
echo -e "${BLUE}----------------------------------------------${NC}"
echo -e "${YELLOW}⚠️  客户端要求：Xray 内核版本必须 >= 1.8.0${NC}"
echo -e "${YELLOW}⚠️  如果连不上，请检查客户端是否开启了 Vision${NC}"
echo -e "${BLUE}----------------------------------------------${NC}"
echo -e "${BLUE}▶ 复制以下链接导入客户端:${NC}"
echo -e "$LINK"
echo -e "${BLUE}----------------------------------------------${NC}"
echo -e "${BLUE}▶ 二维码:${NC}"
qrencode -t ANSIUTF8 "$LINK"
