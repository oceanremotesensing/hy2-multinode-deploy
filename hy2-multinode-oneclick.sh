cat > /root/hy2_single.sh << 'EOF'
#!/usr/bin/env bash
set -e

# ================= 基础配置 =================
PORT=443
HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria2"
CFG="${HY_DIR}/config.yaml"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

[ "$(id -u)" -ne 0 ] && echo "请用 root 运行" && exit 1

# ================= 安装依赖 =================
apt update -y >/dev/null 2>&1
apt install -y curl openssl ca-certificates iptables >/dev/null 2>&1

# ================= 下载 Hysteria2 =================
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "不支持架构"; exit 1 ;;
esac

if [ ! -s "$HY_BIN" ]; then
  curl -L -o "$HY_BIN" \
    https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}
  chmod +x "$HY_BIN"
fi

# ================= 生成证书 =================
mkdir -p "$HY_DIR"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=www.bing.com" >/dev/null 2>&1

# ================= 生成密码 =================
PASSWORD=$(openssl rand -hex 16)
OBFS=$(openssl rand -hex 8)

# ================= 写配置 =================
cat > "$CFG" <<CFG_EOF
listen: :${PORT}

tls:
  cert: ${CERT}
  key: ${KEY}

auth:
  type: password
  password: "${PASSWORD}"

obfs:
  type: salamander
  salamander:
    password: "${OBFS}"
CFG_EOF

# ================= 放行防火墙 (关键修复) =================
# 清理之前残留的规则
iptables -t nat -D PREROUTING -p udp --dport 20001:20009 -j REDIRECT --to-ports 20000 2>/dev/null || true

# 放行 443 UDP
if command -v ufw >/dev/null 2>&1; then
  ufw allow 443/udp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi
iptables -I INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true

# ================= systemd =================
cat > /etc/systemd/system/hysteria2.service <<SYS_EOF
[Unit]
Description=Hysteria2 Stable Server
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

# ================= 输出链接 =================
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

echo -e "\n${GREEN}Hysteria2 已启动 (单节点 443 端口)${NC}"
echo "----------------------------------------"
echo "hy2://${PASSWORD}@${IP}:${PORT}/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS}#Hysteria2-Stable"
echo "----------------------------------------"
echo -e "${YELLOW}注意：如果导入后还是连不上网，请去购买服务器的网页后台 -> 防火墙/安全组，确认 443 端口开启了 UDP 协议（很多服务器默认只开了 TCP 443）。${NC}"
EOF
bash /root/hy2_single.sh
