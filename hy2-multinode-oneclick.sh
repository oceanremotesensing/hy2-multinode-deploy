#!/bin/bash
# 最终修复版 - 直接操作 Xray 二进制文件
# 1. 设置变量
XRAY_BIN="/usr/local/bin/xray"
CONF="/etc/xray/config.json"

# 2. 再次确认版本 (确保万无一失)
echo "--------------------------------"
echo "正在检查 Xray 版本..."
if ! "$XRAY_BIN" version >/dev/null 2>&1; then
    echo "❌ 错误：找不到 xray 文件，请确认 /usr/local/bin/xray 存在"
    exit 1
fi
echo "✔ Xray 核心正常"

# 3. 真正生成 Xray 密钥 (正确的格式应该是 Private key 和 Public key)
echo "正在生成密钥..."
KEY_OUTPUT=$("$XRAY_BIN" x25519)
echo "原始输出如下 (用于调试):"
echo "$KEY_OUTPUT"

# 提取密钥 (兼容多种格式)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "Private" | awk '{print $NF}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "Public" | awk '{print $NF}' | tr -d ' \r\n')

# 4. 严谨检查
if [[ ${#PRIVATE_KEY} -ne 43 && ${#PRIVATE_KEY} -ne 44 ]]; then
    echo "--------------------------------"
    echo "❌ 严重错误：生成的私钥格式不对！"
    echo "拿到的私钥: $PRIVATE_KEY"
    echo "长度: ${#PRIVATE_KEY}"
    echo "请手动运行: /usr/local/bin/xray x25519 看看输出什么"
    exit 1
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "❌ 错误：未找到公钥 (Public Key)！无法继续。"
    exit 1
fi

# 5. 生成配置
UUID=$(uuidgen)
PORT=$(shuf -i 20000-59999 -n 1)
SID=$(openssl rand -hex 4)
MY_IP=$(curl -s4 https://api.ipify.org || curl -s4 ip.sb)

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

# 6. 重启服务
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

systemctl daemon-reload
systemctl enable --now xray
sleep 2

# 7. 检查运行状态
if systemctl is-active --quiet xray; then
    LINK="vless://${UUID}@${MY_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}#Reality-Final"
    
    echo -e "\n\033[32m✔ 部署大功告成！\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "UUID: $UUID"
    echo -e "端口: $PORT"
    echo -e "公钥: $PUBLIC_KEY"
    echo -e "--------------------------------------------------"
    echo -e "\033[34m$LINK\033[0m"
    echo -e "--------------------------------------------------"
else
    echo "❌ 服务启动失败，请检查日志: journalctl -u xray -n 20"
fi
