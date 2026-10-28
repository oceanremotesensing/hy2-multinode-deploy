cat > /root/hy2_443.sh << 'EOF'
#!/usr/bin/env bash
set -e

# ================= 基础配置 =================
PORT=443
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

# ================= 4. 生成 443 端口配置与 10 个节点 =================
OBFS=$(openssl rand -hex 8)
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

cat > "$CFG" <<CFG_EOF
listen: :${PORT}

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

> "$LINKS_FILE"

# 准备 10 个不同的伪装域名，防止客户端软件导入时因为都是 443 端口而合并去重
SNI_LIST=("www.bing.com" "www.apple.com" "www.microsoft.com" "www.yahoo.com" "www.amazon.com" "www.cloudflare.com" "www.github.com" "www.wikipedia.org" "www.netflix.com" "www.spotify.com")

for i in 1 2 3 4 5 6 7 8 9 10; do
  PASS=$(openssl rand -hex 8)
  idx=$((i - 1))
  SNI=${SNI_LIST[$idx]}
  
  # 写入第 i 个用户的密码
  echo "    user${i}: \"${PASS}\"" >> "$CFG"
  
  # 生成固定 443 端口的节点链接
  echo "hy2://user${i}:${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}&obfs=salamander&obfs-password=${OBFS}#Hy2-Node-${i}" >> "$LINKS_FILE"
done

# ================= 5. 配置防火墙 (放行 443 并清理旧规则) =================
# 清理之前 20000 端口的转发规则
iptables -t nat -D PREROUTING -p udp --dport 20001:20009 -j REDIRECT --to-ports 20000 2>/dev/null || true

# 放行 443 UDP 和 TCP
if command -v ufw >/dev/null 2>&1; then
  ufw allow 443/udp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi
iptables -I INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true

# ================= 6. 启动并检查服务 =================
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

sleep 2
if ! systemctl is-active --quiet hysteria2; then
  echo -e "${RED}❌ Hysteria2 启动失败！可能是 443 端口被其他程序占用，错误日志如下：${NC}"
  journalctl -u hysteria2 -n 15 --no-pager
  exit 1
fi

# ================= 7. 打印 10 个节点 =================
echo -e "\n${GREEN}✅ 部署成功！全部使用 443 端口，共 10 个独立账号节点：${NC}"
echo "================================================================================"
cat -n "$LINKS_FILE"
echo "================================================================================"
echo -e "${YELLOW}注：为了方便你看清行号，上面带了编号 1~10。复制导入时如果带了编号无法识别，可运行下面这行命令查看纯链接：${NC}"
echo -e "${GREEN}cat ${LINKS_FILE}${NC}\n"
EOF
bash /root/hy2_443.sh
