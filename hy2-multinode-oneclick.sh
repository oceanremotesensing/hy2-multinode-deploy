cat > /root/hy2_10.sh << 'EOF'
#!/usr/bin/env bash
set -e

# ================= 基础配置 =================
BASE_PORT=20000
NODE_COUNT=10
END_PORT=20009

HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria2"
CFG="${HY_DIR}/config.yaml"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
LINKS_FILE="${HY_DIR}/nodes.txt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

[ "$(id -u)" -ne 0 ] && echo -e "${RED}请用 root 运行此脚本！${NC}" && exit 1

# ================= 1. 安装依赖 =================
apt update -y >/dev/null 2>&1
apt install -y curl openssl ca-certificates iptables >/dev/null 2>&1

# ================= 2. 下载 Hysteria2 =================
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

if [ ! -s "$HY_BIN" ]; then
  echo -e "${YELLOW}正在下载 Hysteria2...${NC}"
  curl -L -o "$HY_BIN" https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}
  chmod +x "$HY_BIN"
fi

# ================= 3. 生成证书 =================
mkdir -p "$HY_DIR"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=www.bing.com" >/dev/null 2>&1

# ================= 4. 生成配置与 10 个节点链接 =================
OBFS=$(openssl rand -hex 8)
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

cat > "$CFG" <<CFG_EOF
listen: :${BASE_PORT}

tls:
  cert: ${CERT}
  key: ${KEY}

obfs:
  type: salamander
  salamander:
    password: "${OBFS}"

auth:
  type: userpass
  userpass:
CFG_EOF

# 清空旧的节点文件
> "$LINKS_FILE"

# 直接使用简单的数字列表循环，兼容所有 shell，边写配置边存链接
for i in 1 2 3 4 5 6 7 8 9 10; do
  PASS=$(openssl rand -hex 8)
  PORT=$((BASE_PORT + i - 1))
  
  # 写入密码到配置文件
  echo "    user${i}: \"${PASS}\"" >> "$CFG"
  
  # 写入链接到文件
  echo "hy2://user${i}:${PASS}@${IP}:${PORT}/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS}#Hy2-Node-${i}" >> "$LINKS_FILE"
done

# ================= 5. 配置防火墙与端口映射 =================
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${BASE_PORT}:${END_PORT}/udp >/dev/null 2>&1 || true
fi

iptables -I INPUT -p udp --dport ${BASE_PORT}:${END_PORT} -j ACCEPT 2>/dev/null || true
iptables -t nat -D PREROUTING -p udp --dport 20001:${END_PORT} -j REDIRECT --to-ports ${BASE_PORT} 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport 20001:${END_PORT} -j REDIRECT --to-ports ${BASE_PORT}

# ================= 6. 启动服务 =================
cat > /etc/systemd/system/hysteria2.service <<SYS_EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=${HY_BIN} server -c ${CFG}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYS_EOF

systemctl daemon-reload
systemctl enable hysteria2 >/dev/null 2>&1
systemctl restart hysteria2

# ================= 7. 打印输出 =================
echo -e "\n${GREEN}✅ 部署完成！以下是为你生成的 10 个独立节点：${NC}"
echo "================================================================================"
cat "$LINKS_FILE"
echo "================================================================================"
echo -e "${YELLOW}提示：所有节点也已保存在 ${LINKS_FILE}，随时可用 cat ${LINKS_FILE} 查看。${NC}"
echo -e "${YELLOW}请确保云服务器网页后台的【安全组/防火墙】已放行 UDP 端口：20000-20009${NC}"
EOF
bash /root/hy2_10.sh
