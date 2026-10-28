#!/usr/bin/env bash
set -e

# ================= 基础配置 =================
BASE_PORT=20000   # 起始端口 (将生成 20000 ~ 20009 共10个端口的节点)
NODE_COUNT=10     # 节点数量
END_PORT=$((BASE_PORT + NODE_COUNT - 1))

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
# 重新生成伪装成 bing.com 的证书，提高客户端兼容性
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -subj "/CN=${SNI}" >/dev/null 2>&1

# ================= 4. 生成 10 个账号与配置 =================
OBFS=$(openssl rand -hex 8)
declare -a PASSWORDS

cat > "$CFG" <<EOF
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
EOF

# 循环生成 10 个独立密码并写入配置
for i in $(seq 1 $NODE_COUNT); do
  PASS=$(openssl rand -hex 8)
  PASSWORDS[$i]=$PASS
  echo "    user${i}: \"${PASS}\"" >> "$CFG"
done

# ================= 5. 配置网络与防火墙 (关键修复) =================
echo -e "${YELLOW}正在配置防火墙与多端口映射...${NC}"

# 放行 UFW (如果系统启用了的话)
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${BASE_PORT}:${END_PORT}/udp >/dev/null 2>&1 || true
fi

# 放行 iptables UDP 端口
iptables -I INPUT -p udp --dport ${BASE_PORT}:${END_PORT} -j ACCEPT 2>/dev/null || true

# 将其余 9 个端口的流量转发到主端口 (实现单进程监听 10 个端口)
iptables -t nat -D PREROUTING -p udp --dport $((BASE_PORT+1)):${END_PORT} -j REDIRECT --to-ports ${BASE_PORT} 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport $((BASE_PORT+1)):${END_PORT} -j REDIRECT --to-ports ${BASE_PORT}

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
systemctl restart hysteria2  # 使用 restart 确保每次运行脚本配置都能立即生效

# 检查服务是否成功启动
sleep 2
if ! systemctl is-active --quiet hysteria2; then
  echo -e "${RED}Hysteria2 启动失败！请运行 journalctl -u hysteria2 -n 20 查看报错日志。${NC}"
  exit 1
fi

# ================= 7. 输出 10 个节点链接 =================
IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)

echo -e "\n${GREEN}✅ Hysteria2 已成功启动！共生成 ${NODE_COUNT} 个独立节点：${NC}"
echo "--------------------------------------------------------------------------------"
for i in $(seq 1 $NODE_COUNT); do
  PORT=$((BASE_PORT + i - 1))
  PASS=${PASSWORDS[$i]}
  # userpass 模式下认证格式为 username:password
  echo "hy2://user${i}:${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}&obfs=salamander&obfs-password=${OBFS}#Hy2-Node${i}-${PORT}"
done
echo "--------------------------------------------------------------------------------"
echo -e "${YELLOW}⚠️ 重要提醒：如果依然连不上，请务必去你的【云服务器后台网页 -> 安全组/防火墙】中，放行 UDP 端口范围：${BASE_PORT}-${END_PORT}${NC}"
