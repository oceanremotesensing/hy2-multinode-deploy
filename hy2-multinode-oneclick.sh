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
NC='\033[0m'

[ "$(id -u)" -ne 0 ] && echo "请用 root 运行" && exit 1

# ================= 安装依赖 =================
apt update -y
apt install -y curl openssl ca-certificates

# ================= 下载 Hysteria2 =================
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "不支持架构"; exit 1 ;;
esac

if [ ! -f "$HY_BIN" ]; then
  curl -L -o "$HY_BIN" \
    https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}
  chmod +x "$HY_BIN"
fi

# ================= 生成证书 =================
mkdir -p "$HY_DIR"
if [ ! -f "$CERT" ]; then
  IP=$(curl -s4 https://api.ipify.org)
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY" -out "$CERT" -days 3650 \
    -subj "/CN=${IP}"
fi

# ================= 生成密码 =================
PASSWORD=$(openssl rand -hex 16)
OBFS=$(openssl rand -hex 8)

# ================= 写配置 =================
cat > "$CFG" <<EOF
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
EOF

# ================= systemd =================
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
systemctl enable --now hysteria2

# ================= 输出链接 =================
IP=$(curl -s4 https://api.ipify.org)

echo -e "\n${GREEN}Hysteria2 已启动${NC}"
echo "----------------------------------------"
echo "hy2://${PASSWORD}@${IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS}#Hysteria2-Stable"
echo "----------------------------------------"
echo "客户端：Sing-box / Clash.Meta / Hiddify"
