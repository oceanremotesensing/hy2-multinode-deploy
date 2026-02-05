#!/bin/bash
# reality-finish-setup.sh
# 既然 Xray 已经装好，这个脚本只负责生成配置和链接

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
XRAY_BIN="/usr/local/bin/xray"
CONF="/etc/xray/config.json"

echo -e "${BLUE}▶ 正在利用现有 Xray 生成密钥...${NC}"

# 1. 生成密钥 (使用最稳健的 awk 写法，无视空格数量)
KEY_OUTPUT=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $NF}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $NF}' | tr -d ' \r\n')

# 调试信息：如果这里打印出来是空的，那是玄学问题
echo -e "调试私钥: ${PRIVATE_KEY:0:10}..."

if [[ ${#PRIVATE_KEY} -lt 40 ]]; then
    echo -e "${RED}❌ 密钥提取依然失败，请手动截图给 AI 分析：${NC}"
    echo "$KEY_OUTPUT"
    exit 1
fi

echo -e "${GREEN}✔ 密钥获取成功！${NC}"

# 2. 准备变量
UUID=$(uuidgen)
# 使用 shuf 生成真正的随机端口 (20000-59999)
PORT=$(shuf -i 20000-59999 -n 1)
SID=$(openssl rand -hex 4)
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)

# 3. 写入配置 (开启 Vision 流控)
mkdir -p /etc/xray
cat > "$CONF" <<EOF
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
        "dest": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 4. 写入系统服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $CONF
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 5. 启动
systemctl daemon-reload
systemctl enable --now xray

# 6. 生成链接
LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-Vision-${PORT}"

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}✔ 部署成功！(使用已安装的 Xray 核心)${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${YELLOW}端口: ${PORT}${NC}"
echo -e "${YELLOW}UUID: ${UUID}${NC}"
echo -e "${BLUE}复制下面的链接到客户端：${NC}"
echo -e "\n${LINK}\n"
