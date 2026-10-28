#!/usr/bin/env bash
set -e

# ================= 基础配置 =================
PORT=443          # 仅使用 443 端口

HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria2"
CFG="${HY_DIR}/config.yaml"
CERT="${HY_DIR}/cert.pem"
KEY="${HY_DIR}/key.pem"
SNI="www.bing.com"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

[ "$(id -u)" -ne 0 ] && echo -e "${RED}请用 root 运行此脚本！${NC}" && exit 1

# ================= 1. 安装依赖 =================
echo -e "${YELLOW}正在安装依赖...${NC}"
apt update -y
apt install -y curl openssl ca-certificates iptables

# ================= 2. 下载 Hysteria2 =================
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 检查文件是否存在且体积正常（防止之前下载了空文件）
if [ ! -s "$HY_BIN" ]; then
  echo -e "${YELLOW}正在下载 Hysteria2...${NC}"
  curl -L -o "$HY_BIN" \
    https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}
  chmod +x "$HY_BIN"
fi

# ================= 3. 生成伪装证书 =================
mkdir -p "$HY_DIR"
# 生成伪装成 bing.com 的自签名证书
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1

# ================= 4. 生成单节点配置 =================
OBFS=$(openssl rand -hex 8)
PASS=$(openssl rand -hex 8)

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
  type: password
  password: "${PASS}"
EOF

# ================= 5. 配置网络与防火墙 =================
echo -e "${YELLOW}正在配置防火墙放行 ${PORT} 端口...${NC}"

# 放行 UFW (如果系统启用了的话)
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${PORT}/udp >/dev/null 2>&1 || true
fi

# 放行 iptables UDP 443 端口 (先尝试删除旧规则防止重复堆叠)
iptables -D INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true

# ================= 6. 配置并重启 systemd 服务 =================
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

systemctl daemon-reload
systemctl enable hysteria2 >/dev/null 2>&1
systemctl restart hysteria2

# 检查服务是否成功启动
sleep 2
if ! systemctl is-active --quiet hysteria2; then
  echo -e "${RED}Hysteria2 启动失败！请运行 journalctl -u hysteria2 -n 20 查看报错日志。${NC}"
  exit 1
fi

# ================= 7. 输出节点链接 =================
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

echo -e "\n${GREEN}✅ Hysteria2 已成功启动！节点链接如下：${NC}"
echo "--------------------------------------------------------------------------------"
echo "hy2://${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}&obfs=salamander&obfs-password=${OBFS}#Hy2-Node-${PORT}"
echo "--------------------------------------------------------------------------------"
echo -e "${YELLOW}⚠️ 重要提醒：Hysteria2 使用的是 UDP 协议！如果连不上，请务必检查你的【云服务器后台安全组/防火墙】，确保放行了 UDP 的 443 端口（很多服务器默认只放行了 TCP 443）！${NC}"
