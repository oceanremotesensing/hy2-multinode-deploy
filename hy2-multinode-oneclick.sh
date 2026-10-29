#!/usr/bin/env bash
set -e

# ================= 基础配置 =================
PORT=443          # Hysteria2 监听端口 (UDP)
SUB_PORT=25880    # 订阅服务监听端口 (TCP)
NODE_COUNT=10     # 生成节点数量

HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria2"
SUB_DIR="${HY_DIR}/sub"
CFG="${HY_DIR}/config.yaml"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
SNI="www.bing.com"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[ "$(id -u)" -ne 0 ] && echo -e "${RED}请用 root 运行此脚本！${NC}" && exit 1

# ================= 1. 安装依赖 =================
echo -e "${YELLOW}正在安装依赖...${NC}"
apt update -y
apt install -y curl openssl ca-certificates iptables python3

# ================= 2. 下载 Hysteria2 =================
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

if [ ! -s "$HY_BIN" ]; then
  echo -e "${YELLOW}正在下载 Hysteria2...${NC}"
  curl -L -o "$HY_BIN" \
    https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}
  chmod +x "$HY_BIN"
fi

# ================= 3. 生成伪装证书 =================
mkdir -p "$HY_DIR" "$SUB_DIR"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1

# ================= 4. 生成 10 个节点配置 =================
OBFS=$(openssl rand -hex 8)
SUB_TOKEN=$(openssl rand -hex 12) # 订阅安全Token

declare -a PASSWORDS
for i in $(seq 1 $NODE_COUNT); do
  PASSWORDS[$i]=$(openssl rand -hex 8)
done

# 写入 Hysteria2 配置文件 (使用 userpass 多用户模式生成10个节点)
cat > "$CFG" <<EOF
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
EOF

for i in $(seq 1 $NODE_COUNT); do
  echo "    user${i}: \"${PASSWORDS[$i]}\"" >> "$CFG"
done

# ================= 5. 生成 Clash 与 v2rayN 订阅文件 =================
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

RAW_LINKS_FILE="${SUB_DIR}/links.txt"
V2RAY_SUB_FILE="${SUB_DIR}/${SUB_TOKEN}_v2ray"
CLASH_SUB_FILE="${SUB_DIR}/${SUB_TOKEN}_clash.yaml"

> "$RAW_LINKS_FILE"

# 初始化 Clash 配置文件头部
cat > "$CLASH_SUB_FILE" <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
proxies:
EOF

# 循环写入 10 个节点到 v2ray 列表和 Clash 配置中
for i in $(seq 1 $NODE_COUNT); do
  USER="user${i}"
  PASS="${PASSWORDS[$i]}"
  NODE_NAME="Hy2-Node-${i}"
  
  # 1. 记录单条 URI (注意: userpass 模式下密码格式为 username:password)
  URI="hy2://${USER}:${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}&obfs=salamander&obfs-password=${OBFS}#${NODE_NAME}"
  echo "$URI" >> "$RAW_LINKS_FILE"

  # 2. 写入 Clash proxies 块
  cat >> "$CLASH_SUB_FILE" <<EOF
  - name: "${NODE_NAME}"
    type: hysteria2
    server: ${IP}
    port: ${PORT}
    password: "${USER}:${PASS}"
    obfs: salamander
    obfs-password: "${OBFS}"
    sni: ${SNI}
    skip-cert-verify: true
EOF
done

# 将 10 条链接进行 Base64 编码，生成标准 v2rayN 订阅格式
base64 -w 0 "$RAW_LINKS_FILE" > "$V2RAY_SUB_FILE"

# 补充 Clash 策略组和规则
cat >> "$CLASH_SUB_FILE" <<EOF

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "⚡ 自动选择"
EOF

for i in $(seq 1 $NODE_COUNT); do
  echo "      - \"Hy2-Node-${i}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<EOF
  - name: "⚡ 自动选择"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
EOF

for i in $(seq 1 $NODE_COUNT); do
  echo "      - \"Hy2-Node-${i}\"" >> "$CLASH_SUB_FILE"
done

cat >> "$CLASH_SUB_FILE" <<EOF

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF

# ================= 6. 配置网络与防火墙 =================
echo -e "${YELLOW}正在配置防火墙放行 ${PORT}(UDP) 和 ${SUB_PORT}(TCP) 端口...${NC}"

if command -v ufw >/dev/null 2>&1; then
  ufw allow ${PORT}/udp >/dev/null 2>&1 || true
  ufw allow ${SUB_PORT}/tcp >/dev/null 2>&1 || true
fi

# 放行 Hysteria2 UDP 端口
iptables -D INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true

# 放行 订阅服务 TCP 端口
iptables -D INPUT -p tcp --dport ${SUB_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport ${SUB_PORT} -j ACCEPT 2>/dev/null || true

# ================= 7. 配置并启动 Systemd 服务 =================
# 1. Hysteria2 主服务
cat > /etc/systemd/system/hysteria2.service <<EOF
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
EOF

# 2. Python 轻量级订阅 HTTP 服务
cat > /etc/systemd/system/hy2-sub.service <<EOF
[Unit]
Description=Hysteria2 Subscription HTTP Server
After=network.target

[Service]
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria2 hy2-sub >/dev/null 2>&1
systemctl restart hysteria2 hy2-sub

sleep 2
if ! systemctl is-active --quiet hysteria2; then
  echo -e "${RED}Hysteria2 启动失败！请运行 journalctl -u hysteria2 -n 20 查看报错日志。${NC}"
  exit 1
fi

# ================= 8. 输出结果 =================
echo -e "\n${GREEN}✅ Hysteria2 及订阅服务已成功启动！${NC}"
echo "================================================================================"
echo -e "${CYAN}【10 个独立节点链接 (可直接全选复制导入 v2rayN / NekoBox)】${NC}"
cat "$RAW_LINKS_FILE"
echo "================================================================================"
echo -e "${CYAN}【客户端订阅链接】${NC}"
echo -e "👉 ${GREEN}v2rayN / 通用 Base64 订阅链接：${NC}"
echo "   http://${IP}:${SUB_PORT}/${SUB_TOKEN}_v2ray"
echo ""
echo -e "👉 ${GREEN}Clash (Mihomo / Clash Verge) 订阅链接：${NC}"
echo "   http://${IP}:${SUB_PORT}/${SUB_TOKEN}_clash.yaml"
echo "================================================================================"
echo -e "${YELLOW}⚠️ 重要提醒：${NC}"
echo -e "1. 节点连接走的是 UDP 协议，请确保云服务器后台【安全组/防火墙】放行了 ${RED}UDP ${PORT}${NC} 端口！"
echo -e "2. 订阅链接走的是 TCP 协议，如果订阅无法更新，请确保后台放行了 ${RED}TCP ${SUB_PORT}${NC} 端口！"
echo -e "3. Clash 订阅需要内核支持 Hysteria2 (如 Clash Verge Rev、Mihomo Party、Flclash 等)。"
